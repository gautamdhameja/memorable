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
    private let assets: PHFetchResult<PHAsset>
    private let batchSize: Int
    private var nextIndex = 0

    init(
        assets: PHFetchResult<PHAsset>,
        batchSize: Int
    ) {
        self.assets = assets
        self.batchSize = max(1, batchSize)
    }

    var hasRemaining: Bool { nextIndex < assets.count }

    mutating func nextBatch(maxCount: Int? = nil) -> [PHAsset] {
        let limit = min(batchSize, maxCount.map { max(0, $0) } ?? batchSize)
        guard limit > 0 else { return [] }

        var selected: [PHAsset] = []
        selected.reserveCapacity(limit)
        while nextIndex < assets.count && selected.count < limit {
            let asset = assets.object(at: nextIndex)
            nextIndex += 1
            selected.append(asset)
        }
        return selected
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
    ) -> Int? {
        guard !isPro else { return nil }
        return max(
            0,
            FreeTier.maxIndexedMedia - confirmedCount - pendingCount - reservedAssetCount
        )
    }

    nonisolated static func shouldFinalizePhotoPass(
        isCancelled: Bool,
        wasInterrupted: Bool
    ) -> Bool {
        !isCancelled && !wasInterrupted
    }

    nonisolated static func shouldFinalizeVideoPass(
        isCancelled: Bool,
        wasInterrupted: Bool
    ) -> Bool {
        !isCancelled && !wasInterrupted
    }

    nonisolated static func shouldContinuePhotoFallback(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    nonisolated static func shouldInterruptBeforeNextBatch(canStartNextBatch: Bool) -> Bool {
        !canStartNextBatch
    }

    static func persistInterruptedPhotoBatch(
        _ photos: [IndexedPhoto],
        using persist: ([IndexedPhoto]) async -> Int
    ) async -> Int {
        guard !photos.isEmpty else { return 0 }
        return await persist(photos)
    }

    final class Session {
        let videoAssets: PHFetchResult<PHAsset>
        let isPro: Bool
        let startedAt: CFAbsoluteTime
        let hasMediaCandidates: Bool
        var indexedMediaCount: Int
        var hitFreeLimit: Bool
        var wasInterrupted = false

        init(
            videoAssets: PHFetchResult<PHAsset>,
            isPro: Bool,
            startedAt: CFAbsoluteTime,
            hasMediaCandidates: Bool,
            indexedMediaCount: Int,
            hitFreeLimit: Bool = false
        ) {
            self.videoAssets = videoAssets
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
        let shouldStartNextBatch: () -> Bool
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
        let db = database
        async let indexedCountFetch: Result<Int, Error> = Task.detached(priority: .userInitiated) {
            Result { try db.indexedMediaCounts().total }
        }.value
        let (photoAssets, videoAssets, persistedIndexedMediaCount) = await (
            photoFetch,
            videoFetch,
            indexedCountFetch
        )
        let total = photoAssets.count + videoAssets.count
        callbacks.setHitFreeLimit(false)

        #if DEBUG
        logger.info("[IndexingService] Starting indexing: \(total) total assets in library")
        #endif
        let startedAt = CFAbsoluteTimeGetCurrent()

        let indexedMediaCount: Int
        switch persistedIndexedMediaCount {
        case let .success(count):
            indexedMediaCount = count
        case let .failure(error):
            logger.error("Failed to load indexed media count: \(error.safeDiagnosticCode)")
            indexedMediaCount = ProManager.shared.isPro ? 0 : FreeTier.maxIndexedMedia
        }
        let isPro = ProManager.shared.isPro
        var indexed = 0
        let populatedSession = Session(
            videoAssets: videoAssets,
            isPro: isPro,
            startedAt: startedAt,
            hasMediaCandidates: photoAssets.count > 0 || videoAssets.count > 0,
            indexedMediaCount: indexedMediaCount
        )

        #if DEBUG
        logger.info("[IndexingService] Library breakdown: \(photoAssets.count) photos, \(videoAssets.count) videos, \(indexedMediaCount) media already indexed")
        #endif

        var currentProgress = IndexingProgress(
            total: photoAssets.count,
            completed: 0,
            isRunning: true,
            phase: .photos,
            searchableCount: callbacks.searchableCount()
        )
        var progressPublisher = IndexingProgressPublisher()
        progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)

        let checkpointInterval = searchableCheckpointInterval(forLibrarySize: total)
        var nextSearchableReloadCount = nextSearchableCheckpoint(
            after: indexedMediaCount,
            isPro: isPro,
            interval: checkpointInterval
        )
        var lastProgressiveReloadAt: Date?
        var batchCursor = PhotoAssetBatchCursor(
            assets: photoAssets,
            batchSize: IndexingConfig.batchEncodeSize
        )
        var nextLoadTask: Task<LoadedPhotoBatch, Never>?
        defer { nextLoadTask?.cancel() }
        var batch: [IndexedPhoto] = []
        var reservedAssetCount = 0
        let prefetchEnabled = isPro && IndexingConfig.prefetchBatchCapacity > 0

        func makeBatch() async -> [PHAsset] {
            let remainingAllowed = Self.remainingPhotoCapacity(
                confirmedCount: populatedSession.indexedMediaCount,
                pendingCount: batch.count,
                reservedAssetCount: reservedAssetCount,
                isPro: isPro
            )
            let selection = batchCursor.nextBatch(maxCount: remainingAllowed)
            guard !selection.isEmpty else { return [] }
            let identifiers = selection.map(\.localIdentifier)
            let screenshotIdentifiers = Set(selection.compactMap { asset in
                asset.mediaSubtypes.contains(.photoScreenshot) ? asset.localIdentifier : nil
            })
            let existing: Set<String>
            do {
                let db = database
                let screenshots = screenshotIdentifiers
                existing = try await Task.detached(priority: .utility) {
                    let existing = try db.existingPhotoIdentifiers(in: identifiers)
                    try db.markPhotoScreenshots(
                        localIdentifiers: screenshots.intersection(existing)
                    )
                    return existing
                }.value
            } catch {
                logger.error("Failed to check indexed photo batch: \(error.safeDiagnosticCode)")
                return []
            }
            let assets = selection.filter { !existing.contains($0.localIdentifier) }
            reservedAssetCount += assets.count
            let skippedCount = selection.count - assets.count
            if skippedCount > 0 {
                indexed += skippedCount
                currentProgress.completed = indexed
                progressPublisher.publish(currentProgress, using: callbacks.setProgress)
            }
            return assets
        }

        guard !Self.shouldInterruptBeforeNextBatch(
            canStartNextBatch: callbacks.shouldStartNextBatch()
        ) else {
            populatedSession.wasInterrupted = true
            return populatedSession
        }
        let firstBatch = await makeBatch()
        currentProgress.rateBaselineCompleted = indexed
        currentProgress.phaseStartedAt = Date()
        progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)
        if !firstBatch.isEmpty {
            nextLoadTask = loadPhotoBatchTask(assets: firstBatch)
        }

        while nextLoadTask != nil || batchCursor.hasRemaining {
            if Task.isCancelled { break }
            guard !Self.shouldInterruptBeforeNextBatch(
                canStartNextBatch: callbacks.shouldStartNextBatch()
            ) else {
                populatedSession.wasInterrupted = true
                break
            }
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
                let batchToLoad = await makeBatch()
                if batchToLoad.isEmpty { continue }
                loadTask = loadPhotoBatchTask(assets: batchToLoad)
            }

            if prefetchEnabled {
                let nextBatch = await makeBatch()
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
                progressPublisher.publish(currentProgress, using: callbacks.setProgress)
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
                    progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)
                    break
                }
            }

            indexed += batchAssets.count
            currentProgress.completed = indexed
            progressPublisher.publish(currentProgress, using: callbacks.setProgress)
            await Task.yield()
        }

        if populatedSession.wasInterrupted {
            let persistedCount = await Self.persistInterruptedPhotoBatch(batch) { [self] photos in
                await persistPhotoBatch(photos)
            }
            populatedSession.indexedMediaCount = Self.updatedMediaCount(
                current: populatedSession.indexedMediaCount,
                persistedPhotoCount: persistedCount
            )
            return populatedSession
        }
        guard Self.shouldFinalizePhotoPass(
            isCancelled: Task.isCancelled,
            wasInterrupted: populatedSession.wasInterrupted
        ) else {
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
        progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)

        #if DEBUG
        logger.info("[IndexingService] Photo indexing complete: \(populatedSession.indexedMediaCount) total indexed media")
        #endif
        return populatedSession
    }

    func indexVideos(session: Session) async {
        var indexed = 0
        var currentProgress = callbacks.currentProgress()
        var progressPublisher = IndexingProgressPublisher()
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
            progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)
        }

        var existingVideos: Set<String> = []
        for index in 0..<session.videoAssets.count {
            if Task.isCancelled { break }
            guard !Self.shouldInterruptBeforeNextBatch(
                canStartNextBatch: callbacks.shouldStartNextBatch()
            ) else {
                session.wasInterrupted = true
                break
            }
            if index.isMultiple(of: SearchIndexLimits.databasePageMediaItems) {
                let end = min(
                    session.videoAssets.count,
                    index + SearchIndexLimits.databasePageMediaItems
                )
                var identifiers: [String] = []
                identifiers.reserveCapacity(end - index)
                for batchIndex in index..<end {
                    identifiers.append(session.videoAssets.object(at: batchIndex).localIdentifier)
                }
                do {
                    let db = database
                    existingVideos = try await Task.detached(priority: .utility) {
                        try db.existingVideoIdentifiers(in: identifiers)
                    }.value
                } catch {
                    logger.error("Failed to check indexed video batch: \(error.safeDiagnosticCode)")
                    return
                }
            }
            let asset = session.videoAssets.object(at: index)
            if existingVideos.contains(asset.localIdentifier) {
                indexed += 1
                currentProgress.completed = indexed
                progressPublisher.publish(currentProgress, using: callbacks.setProgress)
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
            progressPublisher.publish(currentProgress, using: callbacks.setProgress)
            if indexed % 10 == 0 { await Task.yield() }
        }

        guard Self.shouldFinalizeVideoPass(
            isCancelled: Task.isCancelled,
            wasInterrupted: session.wasInterrupted
        ) else { return }
        if session.videoAssets.count > 0 {
            _ = await callbacks.reloadSearchIndex()
        }
        guard Self.shouldFinalizeVideoPass(
            isCancelled: Task.isCancelled,
            wasInterrupted: session.wasInterrupted
        ) else { return }
        currentProgress.searchableCount = callbacks.searchableCount()
        currentProgress.isRunning = false
        progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)

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
            indexedAt: Date(),
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
                || MemoryContentPolicy.isLikelyScreenshotDimensions(
                    width: asset.pixelWidth,
                    height: asset.pixelHeight
                )
        )
    }

    private func markIndexLimitReached(isPro: Bool) {
        callbacks.setHitFreeLimit(!isPro)
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
        return try await CancellableDetachedOperation.run(priority: .utility) {
            try db.insertPhotos(
                photos,
                completingRequiredRebuild: shouldCompleteRequiredRebuild
            )
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

    /// Separates successful persistence from the optional rebuild-state transition.
    private func indexVideo(asset: PHAsset) async -> VideoIndexingOutcome {
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
