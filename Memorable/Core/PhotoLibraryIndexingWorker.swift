import AVFoundation
import Foundation
import Photos
import UIKit

enum VideoIndexingOutcome: Equatable, Sendable {
    case notPersisted
    case persisted(completedRequiredRebuild: Bool)

    var persisted: Bool {
        if case .persisted = self { return true }
        return false
    }

    var completedRequiredRebuild: Bool {
        guard case let .persisted(completed) = self else { return false }
        return completed
    }
}

enum VideoPersistenceOperation {
    static func run(
        _ persistence: @escaping @Sendable () throws -> Bool
    ) async throws -> Bool {
        try await CancellableDetachedOperation.run(
            priority: .utility,
            persistence
        )
    }
}

private struct PhotoAssetBatchCursor {
    struct Selection {
        let assets: [PHAsset]
        let skippedCount: Int
    }

    private let assets: PHFetchResult<PHAsset>
    private let excludedIdentifiers: Set<String>
    private let batchSize: Int
    private var nextIndex = 0

    init(
        assets: PHFetchResult<PHAsset>,
        excludedIdentifiers: Set<String>,
        batchSize: Int
    ) {
        self.assets = assets
        self.excludedIdentifiers = excludedIdentifiers
        self.batchSize = max(1, batchSize)
    }

    var hasRemaining: Bool { nextIndex < assets.count }

    mutating func nextBatch(maxCount: Int? = nil) -> Selection {
        let limit = min(batchSize, maxCount.map { max(0, $0) } ?? batchSize)
        guard limit > 0 else { return Selection(assets: [], skippedCount: 0) }

        var selected: [PHAsset] = []
        selected.reserveCapacity(limit)
        var skippedCount = 0
        while nextIndex < assets.count && selected.count < limit {
            let asset = assets.object(at: nextIndex)
            nextIndex += 1
            if excludedIdentifiers.contains(asset.localIdentifier) {
                skippedCount += 1
            } else {
                selected.append(asset)
            }
        }
        return Selection(assets: selected, skippedCount: skippedCount)
    }
}

@MainActor
final class PhotoLibraryIndexingWorker {
    nonisolated static func updatedMediaCount(current: Int, videoPersisted: Bool) -> Int {
        videoPersisted ? current + 1 : current
    }

    nonisolated static func updatedMediaCount(current: Int, persistedPhotoCount: Int) -> Int {
        current + max(0, persistedPhotoCount)
    }

    nonisolated static func remainingPhotoCapacity(
        confirmedCount: Int,
        pendingCount: Int,
        reservedAssetCount: Int,
        isPro: Bool
    ) -> Int {
        max(
            0,
            FreeTier.indexLimit(isPro: isPro)
                - confirmedCount
                - pendingCount
                - reservedAssetCount
        )
    }

    nonisolated static func shouldFinalizePhotoPass(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    nonisolated static func shouldFinalizeVideoPass(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    nonisolated static func shouldContinuePhotoFallback(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    final class Session {
        let videoAssets: PHFetchResult<PHAsset>
        let alreadyIndexedVideos: Set<String>
        let isPro: Bool
        let startedAt: CFAbsoluteTime
        let hasMediaCandidates: Bool
        var indexedMediaCount: Int
        var hitFreeLimit: Bool

        init(
            videoAssets: PHFetchResult<PHAsset>,
            alreadyIndexedVideos: Set<String>,
            isPro: Bool,
            startedAt: CFAbsoluteTime,
            hasMediaCandidates: Bool,
            indexedMediaCount: Int,
            hitFreeLimit: Bool = false
        ) {
            self.videoAssets = videoAssets
            self.alreadyIndexedVideos = alreadyIndexedVideos
            self.isPro = isPro
            self.startedAt = startedAt
            self.hasMediaCandidates = hasMediaCandidates
            self.indexedMediaCount = indexedMediaCount
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
        let setReachedDeviceIndexLimit: (Bool) -> Void
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
        async let photoFetch = Task.detached(priority: .userInitiated) {
            PhotoLibrary.fetchMedia(ofType: .image)
        }.value
        async let videoFetch = Task.detached(priority: .userInitiated) {
            PhotoLibrary.fetchMedia(ofType: .video)
        }.value
        let (photoAssets, videoAssets) = await (photoFetch, videoFetch)
        let total = photoAssets.count + videoAssets.count
        callbacks.setHitFreeLimit(false)
        callbacks.setReachedDeviceIndexLimit(false)

        #if DEBUG
        logger.info("[IndexingService] Starting indexing: \(total) total assets in library")
        #endif
        let startedAt = CFAbsoluteTimeGetCurrent()

        let indexedIdentifiers: IndexedMediaIdentifiers
        let indexedMediaCount: Int
        do {
            let db = database
            let state = try await Task.detached(priority: .userInitiated) {
                (
                    identifiers: try db.allIndexedMediaIdentifiers(),
                    count: try db.indexedMediaCounts().total
                )
            }.value
            indexedIdentifiers = state.identifiers
            indexedMediaCount = state.count
        } catch {
            logger.error("Failed to load indexed media identifiers: \(error.safeDiagnosticCode)")
            indexedIdentifiers = IndexedMediaIdentifiers(photos: [], videos: [])
            indexedMediaCount = FreeTier.indexLimit(isPro: ProManager.shared.isPro)
        }
        let alreadyIndexed = indexedIdentifiers.photos
        let alreadyIndexedVideos = indexedIdentifiers.videos
        let isPro = ProManager.shared.isPro
        var indexed = 0
        let populatedSession = Session(
            videoAssets: videoAssets,
            alreadyIndexedVideos: alreadyIndexedVideos,
            isPro: isPro,
            startedAt: startedAt,
            hasMediaCandidates: photoAssets.count > 0 || videoAssets.count > 0,
            indexedMediaCount: indexedMediaCount
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

        let checkpointInterval = searchableCheckpointInterval(forLibrarySize: total)
        var nextSearchableReloadCount = nextSearchableCheckpoint(
            after: alreadyIndexed.count + alreadyIndexedVideos.count,
            isPro: isPro,
            interval: checkpointInterval
        )
        var lastProgressiveReloadAt: Date?
        var batchCursor = PhotoAssetBatchCursor(
            assets: photoAssets,
            excludedIdentifiers: alreadyIndexed,
            batchSize: IndexingConfig.batchEncodeSize
        )
        var nextLoadTask: Task<LoadedPhotoBatch, Never>?
        defer { nextLoadTask?.cancel() }
        var batch: [IndexedPhoto] = []
        var reservedAssetCount = 0
        let prefetchEnabled = isPro && IndexingConfig.prefetchBatchCapacity > 0

        func makeBatch() -> [PHAsset] {
            let remainingAllowed = Self.remainingPhotoCapacity(
                confirmedCount: populatedSession.indexedMediaCount,
                pendingCount: batch.count,
                reservedAssetCount: reservedAssetCount,
                isPro: isPro
            )
            let selection = batchCursor.nextBatch(maxCount: remainingAllowed)
            reservedAssetCount += selection.assets.count
            if selection.skippedCount > 0 {
                indexed += selection.skippedCount
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
            }
            return selection.assets
        }

        let firstBatch = makeBatch()
        currentProgress.rateBaselineCompleted = indexed
        currentProgress.phaseStartedAt = Date()
        callbacks.setProgress(currentProgress)
        if !firstBatch.isEmpty {
            nextLoadTask = loadPhotoBatchTask(assets: firstBatch)
        }

        while nextLoadTask != nil || batchCursor.hasRemaining {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: populatedSession.indexedMediaCount, isPro: isPro) {
                populatedSession.hitFreeLimit = true
                markIndexLimitReached(isPro: isPro)
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

            let loadedBatch = await withTaskCancellationHandler {
                await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            guard !Task.isCancelled else { break }
            let batchAssets = loadedBatch.assets
            let loadedImages = loadedBatch.loadedImages
            reservedAssetCount = max(0, reservedAssetCount - batchAssets.count)

            guard !loadedImages.isEmpty else {
                indexed += batchAssets.count
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }

            do {
                let images = loadedImages.map(\.image)
                let encoder = imageEncoder
                let embeddings = try await encoder.encodeBatchCancellable(images: images)

                for (i, loadedImage) in loadedImages.enumerated() {
                    guard i < embeddings.count else { break }
                    guard FreeTier.canIndexMore(
                        indexedMediaCount: populatedSession.indexedMediaCount + batch.count,
                        isPro: isPro
                    ) else {
                        populatedSession.hitFreeLimit = true
                        markIndexLimitReached(isPro: isPro)
                        break
                    }
                    let asset = loadedImage.asset
                    batch.append(makeIndexedPhoto(asset: asset, embedding: embeddings[i]))
                }
            } catch is CancellationError {
                break
            } catch {
                logger.error("Batch encoding failed: \(error.safeDiagnosticCode)")
                for loadedImage in loadedImages {
                    guard Self.shouldContinuePhotoFallback(isCancelled: Task.isCancelled) else {
                        break
                    }
                    guard FreeTier.canIndexMore(
                        indexedMediaCount: populatedSession.indexedMediaCount + batch.count,
                        isPro: isPro
                    ) else {
                        populatedSession.hitFreeLimit = true
                        markIndexLimitReached(isPro: isPro)
                        break
                    }
                    do {
                        let encoder = imageEncoder
                        let embedding = try await encoder.encodeCancellable(
                            image: loadedImage.image
                        )
                        try Task.checkCancellation()
                        batch.append(makeIndexedPhoto(asset: loadedImage.asset, embedding: embedding))
                    } catch is CancellationError {
                        break
                    } catch {
                        logger.error("Single photo encode fallback failed: \(error.safeDiagnosticCode)")
                    }
                }
            }

            guard !Task.isCancelled else { break }

            let pendingFillsCapacity = !FreeTier.canIndexMore(
                indexedMediaCount: populatedSession.indexedMediaCount + batch.count,
                isPro: isPro
            )
            if batch.count >= batchSize || pendingFillsCapacity {
                let persistedCount = await persistPhotoBatch(batch)
                populatedSession.indexedMediaCount = Self.updatedMediaCount(
                    current: populatedSession.indexedMediaCount,
                    persistedPhotoCount: persistedCount
                )
                batch.removeAll(keepingCapacity: true)
                let checkpoint = await reloadSearchIndexIfNeeded(
                    indexedMediaCount: populatedSession.indexedMediaCount,
                    nextCheckpoint: nextSearchableReloadCount,
                    lastReloadAt: lastProgressiveReloadAt,
                    interval: checkpointInterval
                )
                nextSearchableReloadCount = checkpoint.nextCheckpoint
                lastProgressiveReloadAt = checkpoint.lastReloadAt
                currentProgress.searchableCount = callbacks.searchableCount()
                if !FreeTier.canIndexMore(
                    indexedMediaCount: populatedSession.indexedMediaCount,
                    isPro: isPro
                ) {
                    populatedSession.hitFreeLimit = true
                    markIndexLimitReached(isPro: isPro)
                    indexed += batchAssets.count
                    currentProgress.completed = indexed
                    callbacks.setProgress(currentProgress)
                    break
                }
            }

            indexed += batchAssets.count
            currentProgress.completed = indexed
            callbacks.setProgress(currentProgress)
            await Task.yield()
        }

        guard Self.shouldFinalizePhotoPass(isCancelled: Task.isCancelled) else {
            return populatedSession
        }
        if !batch.isEmpty {
            let persistedCount = await persistPhotoBatch(batch)
            populatedSession.indexedMediaCount = Self.updatedMediaCount(
                current: populatedSession.indexedMediaCount,
                persistedPhotoCount: persistedCount
            )
        }
        _ = await callbacks.reloadSearchIndex()
        currentProgress.searchableCount = callbacks.searchableCount()
        currentProgress.photosComplete = true
        callbacks.setProgress(currentProgress)

        #if DEBUG
        logger.info("[IndexingService] Photo indexing complete: \(populatedSession.indexedMediaCount) total indexed media")
        #endif
        return populatedSession
    }

    func indexVideos(session: Session) async {
        var indexed = 0
        var currentProgress = callbacks.currentProgress()
        if session.videoAssets.count > 0 && !Task.isCancelled && !session.hitFreeLimit {
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

        for index in 0..<session.videoAssets.count {
            if Task.isCancelled { break }
            let asset = session.videoAssets.object(at: index)
            if session.alreadyIndexedVideos.contains(asset.localIdentifier) {
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }
            if !FreeTier.canIndexMore(indexedMediaCount: session.indexedMediaCount, isPro: session.isPro) {
                session.hitFreeLimit = true
                markIndexLimitReached(isPro: session.isPro)
                break
            }
            let outcome = await indexVideo(asset: asset)
            if outcome.completedRequiredRebuild {
                callbacks.completeRequiredRebuild()
            }
            session.indexedMediaCount = Self.updatedMediaCount(
                current: session.indexedMediaCount,
                videoPersisted: outcome.persisted
            )
            indexed += 1
            currentProgress.completed = indexed
            callbacks.setProgress(currentProgress)
            if indexed % 10 == 0 { await Task.yield() }
        }

        guard Self.shouldFinalizeVideoPass(isCancelled: Task.isCancelled) else { return }
        if session.videoAssets.count > 0 {
            _ = await callbacks.reloadSearchIndex()
        }
        guard Self.shouldFinalizeVideoPass(isCancelled: Task.isCancelled) else { return }
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

    private func markIndexLimitReached(isPro: Bool) {
        callbacks.setHitFreeLimit(!isPro)
        callbacks.setReachedDeviceIndexLimit(isPro)
    }

    private func persistPhotoBatch(_ photos: [IndexedPhoto]) async -> Int {
        do {
            let completedRequiredRebuild = try await persistPhotos(photos)
            if completedRequiredRebuild {
                callbacks.completeRequiredRebuild()
            }
            return photos.count
        } catch is CancellationError {
            return 0
        } catch {
            logger.error("Failed to insert photo batch: \(error.safeDiagnosticCode), retrying individually")
            var persistedCount = 0
            for photo in photos {
                guard Self.shouldContinuePhotoFallback(isCancelled: Task.isCancelled) else {
                    break
                }
                do {
                    let completedRequiredRebuild = try await persistPhotos([photo])
                    if completedRequiredRebuild {
                        callbacks.completeRequiredRebuild()
                    }
                    persistedCount += 1
                } catch is CancellationError {
                    break
                } catch {
                    logger.error("Failed to insert a photo: \(error.safeDiagnosticCode)")
                }
            }
            return persistedCount
        }
    }

    private func persistPhotos(_ photos: [IndexedPhoto]) async throws -> Bool {
        try Task.checkCancellation()
        let db = database
        let shouldCompleteRequiredRebuild = callbacks.rebuildRequired()
        let persistTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try db.insertPhotos(
                photos,
                completingRequiredRebuild: shouldCompleteRequiredRebuild
            )
        }
        let completedRequiredRebuild = try await withTaskCancellationHandler {
            try await persistTask.value
        } onCancel: {
            persistTask.cancel()
        }
        try Task.checkCancellation()
        return completedRequiredRebuild
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

    /// Separates successful persistence from the optional rebuild-state transition.
    private func indexVideo(asset: PHAsset) async -> VideoIndexingOutcome {
        let db = database
        let localIdentifier = asset.localIdentifier
        let alreadyIndexed = await Task.detached(priority: .utility) {
            (try? db.isVideoIndexed(localIdentifier: localIdentifier)) == true
        }.value
        guard !alreadyIndexed else { return .notPersisted }
        let durationSeconds = asset.duration
        guard durationSeconds > 0 else { return .notPersisted }

        let positions = VideoFrameExtractor.framePositions(
            count: VideoFrameExtractor.frameCount(forDuration: durationSeconds)
        )
        guard let frames = await PhotoLibrary.loadVideoFrames(for: asset, positions: positions) else {
            return .notPersisted
        }
        guard !Task.isCancelled, !frames.isEmpty else { return .notPersisted }

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
            let embeddings = try await encoder.encodeBatchCancellable(images: images)
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let db = database
            let shouldCompleteRequiredRebuild = callbacks.rebuildRequired()
            let persistedFrames = frameRecords
            let completedRequiredRebuild = try await VideoPersistenceOperation.run {
                return try db.insertVideo(
                    video,
                    persistedFrames,
                    completingRequiredRebuild: shouldCompleteRequiredRebuild
                )
            }
            return .persisted(
                completedRequiredRebuild: completedRequiredRebuild
            )
        } catch is CancellationError {
            return .notPersisted
        } catch {
            logger.error("Failed to persist indexed video: \(error.safeDiagnosticCode)")
            return .notPersisted
        }
    }
}
