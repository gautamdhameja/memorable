import AVFoundation
import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryIndexingWorker {
    final class Session {
        let videoAssets: [PHAsset]
        let alreadyIndexedVideos: Set<String>
        let isPro: Bool
        let startedAt: CFAbsoluteTime
        var newlyIndexed: Int
        var hitFreeLimit: Bool

        init(
            videoAssets: [PHAsset],
            alreadyIndexedVideos: Set<String>,
            isPro: Bool,
            startedAt: CFAbsoluteTime,
            newlyIndexed: Int,
            hitFreeLimit: Bool = false
        ) {
            self.videoAssets = videoAssets
            self.alreadyIndexedVideos = alreadyIndexedVideos
            self.isPro = isPro
            self.startedAt = startedAt
            self.newlyIndexed = newlyIndexed
            self.hitFreeLimit = hitFreeLimit
        }
    }

    struct Callbacks {
        let searchableCount: () -> Int
        let rebuildRequired: () -> Bool
        let completeRequiredRebuild: () -> Void
        let currentProgress: () -> IndexingProgress
        let setProgress: (IndexingProgress) -> Void
        let setHitFreeLimit: (Bool) -> Void
        let reloadSearchIndex: () async -> Bool
    }

    private struct LoadedPhotoBatch {
        let assets: [PHAsset]
        let loadedImages: [(asset: PHAsset, image: UIImage)]
    }

    private let imageEncoder: ImageEncoder
    private let database: DatabaseProtocol
    private let batchSize: Int
    private let callbacks: Callbacks

    init(
        imageEncoder: ImageEncoder,
        database: DatabaseProtocol,
        batchSize: Int = IndexingConfig.batchInsertSize,
        callbacks: Callbacks
    ) {
        self.imageEncoder = imageEncoder
        self.database = database
        self.batchSize = batchSize
        self.callbacks = callbacks
    }

    func indexPhotos() async -> Session {
        let allAssets = await Task.detached(priority: .userInitiated) {
            PhotoLibrary.fetchAllMedia()
        }.value
        let total = allAssets.count
        callbacks.setHitFreeLimit(false)

        #if DEBUG
        logger.info("[IndexingService] Starting indexing: \(total) total assets in library")
        #endif
        let startedAt = CFAbsoluteTimeGetCurrent()

        let indexedIdentifiers: IndexedMediaIdentifiers
        do {
            let db = database
            indexedIdentifiers = try await Task.detached(priority: .userInitiated) {
                try db.allIndexedMediaIdentifiers()
            }.value
        } catch {
            logger.error("Failed to load indexed media identifiers: \(error.localizedDescription)")
            indexedIdentifiers = IndexedMediaIdentifiers(photos: [], videos: [])
        }
        let alreadyIndexed = indexedIdentifiers.photos
        let alreadyIndexedVideos = indexedIdentifiers.videos
        let isPro = ProManager.shared.isPro
        var indexed = 0
        var photoAssets: [PHAsset] = []
        var videoAssets: [PHAsset] = []
        for i in 0..<total {
            let asset = allAssets[i]
            if asset.mediaType == .video {
                videoAssets.append(asset)
            } else {
                photoAssets.append(asset)
            }
        }

        let populatedSession = Session(
            videoAssets: videoAssets,
            alreadyIndexedVideos: alreadyIndexedVideos,
            isPro: isPro,
            startedAt: startedAt,
            newlyIndexed: alreadyIndexed.count + alreadyIndexedVideos.count
        )

        #if DEBUG
        logger.info("[IndexingService] Library breakdown: \(photoAssets.count) photos, \(videoAssets.count) videos, \(alreadyIndexed.count) photos and \(alreadyIndexedVideos.count) videos already indexed")
        #endif

        var currentProgress = IndexingProgress(
            total: photoAssets.count,
            completed: 0,
            isRunning: true,
            phase: .photos,
            searchableCount: callbacks.searchableCount()
        )
        callbacks.setProgress(currentProgress)

        var assetsToIndex: [PHAsset] = []
        for asset in photoAssets {
            if alreadyIndexed.contains(asset.localIdentifier) {
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
            } else {
                assetsToIndex.append(asset)
            }
        }
        currentProgress.rateBaselineCompleted = indexed
        currentProgress.phaseStartedAt = Date()
        callbacks.setProgress(currentProgress)

        let checkpointInterval = searchableCheckpointInterval(forLibrarySize: total)
        var nextSearchableReloadCount = nextSearchableCheckpoint(
            after: alreadyIndexed.count + alreadyIndexedVideos.count,
            isPro: isPro,
            interval: checkpointInterval
        )
        var lastProgressiveReloadAt: Date?
        var batchCursor = IndexingBatchCursor(items: assetsToIndex, batchSize: IndexingConfig.batchEncodeSize)
        var nextLoadTask: Task<LoadedPhotoBatch, Never>?
        var batch: [IndexedPhoto] = []
        let prefetchEnabled = isPro && IndexingConfig.prefetchBatchCapacity > 0

        func makeBatch() -> [PHAsset] {
            guard !isPro else { return batchCursor.nextBatch() }
            let remainingAllowed = max(0, FreeTier.maxIndexedMedia - populatedSession.newlyIndexed)
            return batchCursor.nextBatch(maxCount: remainingAllowed)
        }

        let firstBatch = makeBatch()
        if !firstBatch.isEmpty {
            nextLoadTask = loadPhotoBatchTask(assets: firstBatch)
        }

        while nextLoadTask != nil || batchCursor.hasRemaining {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: populatedSession.newlyIndexed, isPro: isPro) {
                populatedSession.hitFreeLimit = true
                callbacks.setHitFreeLimit(true)
                break
            }

            let loadTask: Task<LoadedPhotoBatch, Never>
            if let prefetchedTask = nextLoadTask {
                loadTask = prefetchedTask
                nextLoadTask = nil
            } else {
                let batchToLoad = makeBatch()
                guard !batchToLoad.isEmpty else { break }
                loadTask = loadPhotoBatchTask(assets: batchToLoad)
            }

            if prefetchEnabled {
                let nextBatch = makeBatch()
                nextLoadTask = nextBatch.isEmpty ? nil : loadPhotoBatchTask(assets: nextBatch)
            }

            let loadedBatch = await loadTask.value
            let batchAssets = loadedBatch.assets
            let loadedImages = loadedBatch.loadedImages

            guard !loadedImages.isEmpty else {
                indexed += batchAssets.count
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }

            do {
                let images = loadedImages.map(\.image)
                let encoder = imageEncoder
                let embeddings = try await Task.detached(priority: .userInitiated) {
                    if images.count > 1 {
                        return try encoder.encodeBatch(images: images)
                    }
                    return [try encoder.encode(image: images[0])]
                }.value

                for (i, loadedImage) in loadedImages.enumerated() {
                    guard i < embeddings.count else { break }
                    guard FreeTier.canIndexMore(indexedMediaCount: populatedSession.newlyIndexed, isPro: isPro) else {
                        populatedSession.hitFreeLimit = true
                        callbacks.setHitFreeLimit(true)
                        break
                    }
                    let asset = loadedImage.asset
                    batch.append(makeIndexedPhoto(asset: asset, embedding: embeddings[i]))
                    populatedSession.newlyIndexed += 1
                }
            } catch {
                logger.error("Batch encoding failed: \(error.localizedDescription)")
                for loadedImage in loadedImages {
                    guard FreeTier.canIndexMore(indexedMediaCount: populatedSession.newlyIndexed, isPro: isPro) else {
                        populatedSession.hitFreeLimit = true
                        callbacks.setHitFreeLimit(true)
                        break
                    }
                    do {
                        let encoder = imageEncoder
                        let embedding = try await Task.detached(priority: .userInitiated) {
                            try encoder.encode(image: loadedImage.image)
                        }.value
                        batch.append(makeIndexedPhoto(asset: loadedImage.asset, embedding: embedding))
                        populatedSession.newlyIndexed += 1
                    } catch {
                        logger.error("Single encode fallback failed for \(loadedImage.asset.localIdentifier): \(error.localizedDescription)")
                    }
                }
            }

            if batch.count >= batchSize {
                await persistPhotoBatch(batch)
                batch.removeAll(keepingCapacity: true)
                let checkpoint = await reloadSearchIndexIfNeeded(
                    indexedMediaCount: populatedSession.newlyIndexed,
                    nextCheckpoint: nextSearchableReloadCount,
                    lastReloadAt: lastProgressiveReloadAt,
                    interval: checkpointInterval
                )
                nextSearchableReloadCount = checkpoint.nextCheckpoint
                lastProgressiveReloadAt = checkpoint.lastReloadAt
                currentProgress.searchableCount = callbacks.searchableCount()
            }

            indexed += batchAssets.count
            currentProgress.completed = indexed
            callbacks.setProgress(currentProgress)
            await Task.yield()
        }

        if !batch.isEmpty {
            await persistPhotoBatch(batch)
        }
        _ = await callbacks.reloadSearchIndex()
        currentProgress.searchableCount = callbacks.searchableCount()
        currentProgress.photosComplete = true
        callbacks.setProgress(currentProgress)

        #if DEBUG
        logger.info("[IndexingService] Photo indexing complete: \(populatedSession.newlyIndexed) newly indexed")
        #endif
        return populatedSession
    }

    func indexVideos(session: Session) async {
        let videoAssetsToIndex = session.videoAssets.filter {
            !session.alreadyIndexedVideos.contains($0.localIdentifier)
        }
        var indexed = session.videoAssets.count - videoAssetsToIndex.count
        var currentProgress = callbacks.currentProgress()
        if !session.videoAssets.isEmpty && !Task.isCancelled && !session.hitFreeLimit {
            currentProgress = IndexingProgress(
                total: session.videoAssets.count,
                completed: indexed,
                isRunning: true,
                phase: .videos,
                photosComplete: true,
                searchableCount: callbacks.searchableCount(),
                rateBaselineCompleted: indexed,
                phaseStartedAt: Date()
            )
            callbacks.setProgress(currentProgress)
        }

        for asset in videoAssetsToIndex {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: session.newlyIndexed, isPro: session.isPro) {
                session.hitFreeLimit = true
                callbacks.setHitFreeLimit(true)
                break
            }
            if await indexVideo(asset: asset) {
                callbacks.completeRequiredRebuild()
            }
            session.newlyIndexed += 1
            indexed += 1
            currentProgress.completed = indexed
            callbacks.setProgress(currentProgress)
            if indexed % 10 == 0 { await Task.yield() }
        }

        if !session.videoAssets.isEmpty {
            _ = await callbacks.reloadSearchIndex()
        }
        currentProgress.searchableCount = callbacks.searchableCount()
        currentProgress.isRunning = false
        callbacks.setProgress(currentProgress)

        #if DEBUG
        logger.info("[IndexingService] Indexing complete in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - session.startedAt))s")
        #endif
    }

    private func makeIndexedPhoto(asset: PHAsset, embedding: [Float]) -> IndexedPhoto {
        IndexedPhoto(
            id: UUID().uuidString,
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            embedding: embedding.toFloat16Data(),
            indexedAt: Date()
        )
    }

    private func persistPhotoBatch(_ photos: [IndexedPhoto]) async {
        do {
            let db = database
            let shouldCompleteRequiredRebuild = callbacks.rebuildRequired()
            let completedRequiredRebuild = try await Task.detached(priority: .utility) {
                try db.insertPhotos(
                    photos,
                    completingRequiredRebuild: shouldCompleteRequiredRebuild
                )
            }.value
            if completedRequiredRebuild {
                callbacks.completeRequiredRebuild()
            }
        } catch {
            logger.error("Failed to insert photo batch: \(error.localizedDescription), retrying individually")
            for photo in photos {
                do {
                    let db = database
                    let shouldCompleteRequiredRebuild = callbacks.rebuildRequired()
                    let completedRequiredRebuild = try await Task.detached(priority: .utility) {
                        try db.insertPhotos(
                            [photo],
                            completingRequiredRebuild: shouldCompleteRequiredRebuild
                        )
                    }.value
                    if completedRequiredRebuild {
                        callbacks.completeRequiredRebuild()
                    }
                } catch {
                    logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadPhotoBatchTask(assets: [PHAsset]) -> Task<LoadedPhotoBatch, Never> {
        Task {
            let loadedImages = await loadImagesForIndexing(assets: assets)
            return LoadedPhotoBatch(assets: assets, loadedImages: loadedImages)
        }
    }

    private func loadImagesForIndexing(assets: [PHAsset]) async -> [(asset: PHAsset, image: UIImage)] {
        var loadedImages: [(asset: PHAsset, image: UIImage)] = []
        await withTaskGroup(of: (PHAsset, UIImage?).self) { group in
            for asset in assets {
                group.addTask {
                    let image = await PhotoLibrary.loadImageForIndexing(for: asset)
                    return (asset, image)
                }
            }
            for await (asset, image) in group {
                if let image {
                    loadedImages.append((asset, image))
                }
            }
        }
        return loadedImages
    }

    private func firstSearchableCheckpoint(isPro: Bool) -> Int {
        isPro ? IndexingConfig.firstSearchableCheckpoint : min(IndexingConfig.firstSearchableCheckpoint, FreeTier.maxIndexedMedia)
    }

    private func searchableCheckpointInterval(forLibrarySize librarySize: Int) -> Int {
        librarySize >= IndexingConfig.largeLibraryProgressiveReloadThreshold
            ? IndexingConfig.largeLibrarySearchableCheckpointInterval
            : IndexingConfig.searchableCheckpointInterval
    }

    private func nextSearchableCheckpoint(after indexedMediaCount: Int, isPro: Bool, interval: Int) -> Int {
        let first = firstSearchableCheckpoint(isPro: isPro)
        return indexedMediaCount >= first ? indexedMediaCount + interval : first
    }

    private func reloadSearchIndexIfNeeded(
        indexedMediaCount: Int,
        nextCheckpoint: Int,
        lastReloadAt: Date?,
        interval: Int
    ) async -> (nextCheckpoint: Int, lastReloadAt: Date?) {
        guard indexedMediaCount >= nextCheckpoint else { return (nextCheckpoint, lastReloadAt) }
        if let lastReloadAt,
           Date().timeIntervalSince(lastReloadAt) < IndexingConfig.minSearchReloadIntervalSeconds {
            return (nextCheckpoint, lastReloadAt)
        }
        let didLoad = await callbacks.reloadSearchIndex()
        return (indexedMediaCount + interval, didLoad ? Date() : lastReloadAt)
    }

    /// Returns whether the first persisted video embeddings completed a required rebuild.
    private func indexVideo(asset: PHAsset) async -> Bool {
        let db = database
        let localIdentifier = asset.localIdentifier
        let alreadyIndexed = await Task.detached(priority: .utility) {
            (try? db.isVideoIndexed(localIdentifier: localIdentifier)) == true
        }.value
        guard !alreadyIndexed else { return false }
        guard let avAsset = await VideoFrameExtractor.loadAVAsset(from: asset) else { return false }
        guard let duration = try? await avAsset.load(.duration) else { return false }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { return false }

        let positions = VideoFrameExtractor.framePositions(
            count: VideoFrameExtractor.frameCount(forDuration: durationSeconds)
        )
        let frames = await VideoFrameExtractor.extractFrames(from: avAsset, positions: positions)
        guard !frames.isEmpty else { return false }

        let videoId = UUID().uuidString
        let video = IndexedVideo(
            id: videoId,
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            duration: durationSeconds,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            frameCount: frames.count,
            indexedAt: Date()
        )

        do {
            let images = frames.map(\.image)
            let encoder = imageEncoder
            let embeddings = try await Task.detached(priority: .userInitiated) {
                images.count > 1
                    ? try encoder.encodeBatch(images: images)
                    : [try encoder.encode(image: images[0])]
            }.value
            var frameRecords: [IndexedVideoFrame] = []
            for (i, frame) in frames.enumerated() where i < embeddings.count {
                frameRecords.append(IndexedVideoFrame(
                    id: UUID().uuidString,
                    videoId: videoId,
                    framePosition: frame.position,
                    embedding: embeddings[i].toFloat16Data(),
                    indexedAt: Date()
                ))
            }
            let db = database
            let shouldCompleteRequiredRebuild = callbacks.rebuildRequired()
            return try await Task.detached(priority: .utility) {
                try db.insertVideo(
                    video,
                    frameRecords,
                    completingRequiredRebuild: shouldCompleteRequiredRebuild
                )
            }.value
        } catch {
            logger.error("Failed to persist indexed video: \(error.localizedDescription)")
            return false
        }
    }
}
