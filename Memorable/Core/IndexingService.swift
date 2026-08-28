import Foundation
import Photos
import AVFoundation
import UIKit

private let hitFreeLimitKey = "indexing.hitFreeLimit"

class PhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    var onNewPhotosDetected: (() -> Void)?

    func startObserving() {
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.onNewPhotosDetected?()
        }
    }
}

struct IndexingBatchCursor<Item> {
    private let items: [Item]
    private let batchSize: Int
    private var nextIndex = 0

    init(items: [Item], batchSize: Int) {
        precondition(batchSize > 0)
        self.items = items
        self.batchSize = batchSize
    }

    var hasRemaining: Bool {
        nextIndex < items.count
    }

    mutating func nextBatch(maxCount: Int? = nil) -> [Item] {
        guard hasRemaining else { return [] }
        let batchEnd = min(nextIndex + batchSize, items.count)
        let batch = Array(items[nextIndex..<batchEnd])
        nextIndex = batchEnd
        guard let maxCount else { return batch }
        return Array(batch.prefix(max(0, maxCount)))
    }
}

@MainActor
class IndexingService: ObservableObject {
    @Published var progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
    @Published var isReady = false {
        didSet {
            #if DEBUG
            if oldValue != isReady {
                logger.info("[IndexingService] isReady changed \(oldValue) -> \(self.isReady); indexVersion=\(self.indexVersion), searchIndexLoaded=\(self.searchEngine.isIndexLoaded), totalSize=\(self.searchEngine.totalSize)")
            }
            #endif
        }
    }
    @Published var newPhotosAvailable = false
    @Published private(set) var indexRebuildRequired = false
    @Published var indexVersion: Int = 0 {
        didSet {
            #if DEBUG
            logger.info("[IndexingService] indexVersion changed \(oldValue) -> \(self.indexVersion); isReady=\(self.isReady), searchIndexLoaded=\(self.searchEngine.isIndexLoaded), totalSize=\(self.searchEngine.totalSize)")
            #endif
        }
    }
    // Persisted so the "Search your N of M photos" hint and the post-upgrade
    // resume button survive app relaunches. Without this, a user who upgrades
    // and relaunches before re-indexing would lose the signal that there are
    // still unindexed photos in their library.
    @Published var hitFreeLimit: Bool = UserDefaults.standard.bool(forKey: hitFreeLimitKey) {
        didSet {
            UserDefaults.standard.set(hitFreeLimit, forKey: hitFreeLimitKey)
        }
    }
    // Background reverse-geocoding progress. Nil when idle or finished.
    @Published var geocodingProgress: (completed: Int, total: Int)? {
        didSet {
            #if DEBUG
            let oldText = oldValue.map { "\($0.completed)/\($0.total)" } ?? "nil"
            let newText = geocodingProgress.map { "\($0.completed)/\($0.total)" } ?? "nil"
            if oldText != newText {
                logger.info("[IndexingService] geocodingProgress changed \(oldText) -> \(newText)")
            }
            #endif
        }
    }

    private let imageEncoder: ImageEncoder
    let searchEngine: SearchEngine
    private let database: DatabaseProtocol
    private var indexingTask: Task<Void, Never>?
    private let changeObserver = PhotoChangeObserver()
    private let batchSize = IndexingConfig.batchInsertSize
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var surpriseValidationTask: Task<Void, Never>?
    private var autoResumeTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var enrichmentTaskGeneration = 0
    private let reverseGeocoder = ReverseGeocoder()
    private var geocodingTask: Task<Void, Never>?
    private var isObservingPhotoChanges = false
    private var launchLibraryCountSnapshot: Int?

    var onIndexReady: (() -> Void)?
    var onIndexUnavailable: (() -> Void)?

    private struct LoadedPhotoBatch {
        let assets: [PHAsset]
        let loadedImages: [(asset: PHAsset, image: UIImage)]
    }

    init(imageEncoder: ImageEncoder, searchEngine: SearchEngine, database: DatabaseProtocol = AppDatabase.shared) {
        self.imageEncoder = imageEncoder
        self.searchEngine = searchEngine
        self.database = database
    }

    @discardableResult
    func checkAndLoadExistingIndex(
        scheduleAutoResume: Bool = true,
        cleanOrphans: Bool = true,
        loadPriority: TaskPriority = .utility
    ) async -> Bool {
        #if DEBUG
        logger.info("[IndexingService] checkAndLoadExistingIndex start scheduleAutoResume=\(scheduleAutoResume), cleanOrphans=\(cleanOrphans), priority=\(String(describing: loadPriority))")
        #endif
        let loaded = await loadExistingIndexIfAvailable(cleanOrphans: cleanOrphans, loadPriority: loadPriority)
        startObservingPhotoChanges()
        if scheduleAutoResume && loaded {
            scheduleDeferredAutoResume(totalInLibrary: launchLibraryCountSnapshot)
            scheduleDeferredEnrichment(
                delaySeconds: IndexingConfig.postLaunchAutoResumeDelaySeconds
                    + IndexingConfig.surpriseValidationDelaySeconds
            )
        }
        #if DEBUG
        logger.info("[IndexingService] checkAndLoadExistingIndex finish loaded=\(loaded), isReady=\(self.isReady), indexLoaded=\(self.searchEngine.isIndexLoaded), totalSize=\(self.searchEngine.totalSize)")
        #endif
        return loaded
    }

    @discardableResult
    func loadExistingIndexIfAvailable(cleanOrphans: Bool = false, loadPriority: TaskPriority = .utility) async -> Bool {
        do {
            #if DEBUG
            logger.info("[IndexingService] loadExistingIndexIfAvailable start cleanOrphans=\(cleanOrphans), priority=\(String(describing: loadPriority))")
            #endif
            let db = database
            let rebuildRequired = try await Task.detached(priority: loadPriority) {
                try db.indexRebuildRequired()
            }.value
            indexRebuildRequired = rebuildRequired
            if rebuildRequired {
                searchEngine.dropIndex()
                isReady = false
                progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
                onIndexUnavailable?()
                return false
            }

            let counts = try await Task.detached(priority: loadPriority) {
                try db.indexedMediaCounts()
            }.value
            let photoCount = counts.photos
            let videoCount = counts.videos
            let totalIndexed = counts.total

            if totalIndexed > 0 {
                #if DEBUG
                logger.info("[IndexingService] Found \(photoCount) indexed photos and \(videoCount) indexed videos, loading index")
                #endif

                if cleanOrphans {
                    let allMedia = await Task.detached(priority: loadPriority) {
                        PhotoLibrary.fetchAllMedia()
                    }.value
                    launchLibraryCountSnapshot = allMedia.count
                    await cleanOrphanedEmbeddings(allMedia: allMedia)
                }

                let didLoad = try await Task.detached(priority: loadPriority) { [searchEngine] in
                    try searchEngine.loadIndex()
                    return searchEngine.isIndexLoaded
                }.value
                guard didLoad else {
                    isReady = false
                    progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
                    onIndexUnavailable?()
                    return false
                }

                isReady = true
                let loadedTotal = searchEngine.totalSize
                progress = IndexingProgress(
                    total: loadedTotal,
                    completed: loadedTotal,
                    isRunning: false,
                    searchableCount: loadedTotal
                )
                onIndexReady?()

                #if DEBUG
                logger.info("[IndexingService] Index ready: \(self.searchEngine.indexSize) photos, \(self.searchEngine.videoSize) videos")
                #endif
                return true
            }
        } catch {
            logger.error("Failed to load existing index: \(error.localizedDescription)")
        }
        isReady = false
        onIndexUnavailable?()
        return false
    }

    func startIndexing() {
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        SurpriseQueries.clearValidated()
        indexingTask = Task { await performIndexing() }
    }

    func indexNewPhotosOnly() {
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        newPhotosAvailable = false
        indexingTask = Task { await performIndexing() }
    }

    func rebuildRequiredIndex() {
        guard indexRebuildRequired else {
            startIndexing()
            return
        }

        stopIndexing()
        guard markRunningIfIdle() else { return }
        SurpriseQueries.clearValidated()
        indexingTask = Task {
            do {
                let db = database
                try await Task.detached(priority: .utility) {
                    try db.deleteAll()
                }.value
            } catch {
                logger.error("Failed to clear incompatible index before rebuild: \(error.localizedDescription)")
                progress.isRunning = false
                return
            }

            searchEngine.dropIndex()
            isReady = false
            await performIndexing()
            guard !Task.isCancelled, indexRebuildRequired else { return }

            do {
                let db = database
                try await Task.detached(priority: .utility) {
                    try db.clearIndexRebuildRequired()
                }.value
                indexRebuildRequired = false
            } catch {
                logger.error("Failed to complete empty index rebuild: \(error.localizedDescription)")
            }
        }
    }

    func stopIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        surpriseValidationTask?.cancel()
        surpriseValidationTask = nil
        autoResumeTask?.cancel()
        autoResumeTask = nil
        cancelEnrichmentTask()
        geocodingTask?.cancel()
        geocodingTask = nil
        geocodingProgress = nil
        progress.isRunning = false
    }

    func deferEnrichmentForUserSearch() {
        guard enrichmentTask != nil else { return }
        cancelEnrichmentWork()
        scheduleDeferredEnrichment(delaySeconds: IndexingConfig.surpriseValidationDelaySeconds)
    }

    func cancelEnrichmentForMemoryPressure() {
        cancelEnrichmentWork()
    }

    func indexFolder(url: URL, name: String) {
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        indexingTask = Task { await performFolderIndexing(url: url, name: name) }
    }

    // MARK: - Private

    private func markRunningIfIdle() -> Bool {
        guard !progress.isRunning else { return false }
        progress.isRunning = true
        return true
    }

    private func startObservingPhotoChanges() {
        guard !isObservingPhotoChanges else { return }
        changeObserver.onNewPhotosDetected = { [weak self] in
            Task { @MainActor in self?.checkForNewPhotos() }
        }
        changeObserver.startObserving()
        isObservingPhotoChanges = true
    }

    private func checkForNewPhotos() {
        guard !progress.isRunning else { return }
        let db = database
        let engine = searchEngine
        // Strong [self] capture is safe because IndexingService is
        // @MainActor-isolated (implicitly Sendable in Swift 6). The task is
        // short-lived (single library fetch + DB query) so there is no
        // lifetime concern; explicit capture silences Swift 6 strict
        // concurrency diagnostics about implicit self across a detached
        // task boundary.
        Task.detached { [self] in
            let allMedia = PhotoLibrary.fetchAllMedia()
            let totalInLibrary = allMedia.count

            do {
                let totalIndexed = try db.indexedMediaCounts().total

                if totalInLibrary > totalIndexed {
                    await MainActor.run { self.newPhotosAvailable = true }
                } else if totalInLibrary < totalIndexed {
                    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited else {
                        #if DEBUG
                        logger.info("[IndexingService] Ignoring lower visible PhotoKit count under limited Photos access")
                        #endif
                        return
                    }
                    // Photos were deleted. Run lightweight orphan cleanup.
                    var currentIds = Set<String>()
                    for i in 0..<allMedia.count {
                        currentIds.insert(allMedia.object(at: i).localIdentifier)
                    }
                    let indexedPhotoIds = try db.allIndexedIdentifiers()
                    let orphaned = indexedPhotoIds.subtracting(currentIds)
                    if !orphaned.isEmpty && orphaned.count < indexedPhotoIds.count / 2 {
                        try db.deleteOrphanedPhotos(localIdentifiers: orphaned)
                        try engine.loadIndex()
                        await MainActor.run { self.indexVersion += 1 }
                    }
                }
            } catch {
                logger.error("Error checking for photo changes: \(error.localizedDescription)")
            }
        }
    }

    private func persistPhotoBatch(_ photos: [IndexedPhoto]) async {
        do {
            let db = database
            let shouldCompleteRequiredRebuild = indexRebuildRequired
            let completedRequiredRebuild = try await Task.detached(priority: .utility) {
                try db.insertPhotos(
                    photos,
                    completingRequiredRebuild: shouldCompleteRequiredRebuild
                )
            }.value
            if completedRequiredRebuild {
                indexRebuildRequired = false
            }
        } catch {
            logger.error("Failed to insert photo batch: \(error.localizedDescription), retrying individually")
            for photo in photos {
                do {
                    let db = database
                    let shouldCompleteRequiredRebuild = indexRebuildRequired
                    let completedRequiredRebuild = try await Task.detached(priority: .utility) {
                        try db.insertPhotos(
                            [photo],
                            completingRequiredRebuild: shouldCompleteRequiredRebuild
                        )
                    }.value
                    if completedRequiredRebuild {
                        indexRebuildRequired = false
                    }
                } catch {
                    logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)")
                }
            }
        }
    }

    private func performIndexing() async {
        // Request background execution time so indexing continues when app is backgrounded
        beginBackgroundTask()
        defer { endBackgroundTask() }

        let allAssets = await Task.detached(priority: .userInitiated) {
            PhotoLibrary.fetchAllMedia()
        }.value
        let total = allAssets.count
        hitFreeLimit = false

        #if DEBUG
        logger.info("[IndexingService] Starting indexing: \(total) total assets in library")
        let indexingStart = CFAbsoluteTimeGetCurrent()
        #endif

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
        var newlyIndexed = alreadyIndexed.count + alreadyIndexedVideos.count
        var batch: [IndexedPhoto] = []

        // Separate photos and videos
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

        #if DEBUG
        logger.info("[IndexingService] Library breakdown: \(photoAssets.count) photos, \(videoAssets.count) videos, \(alreadyIndexed.count) photos and \(alreadyIndexedVideos.count) videos already indexed")
        #endif

        // Pass 1: Index all photos first with only base embeddings and metadata.
        // OCR, blur scoring, and scene labels run later as deferred enrichment.
        let encodeBatchSize = IndexingConfig.batchEncodeSize
        progress = IndexingProgress(
            total: photoAssets.count,
            completed: 0,
            isRunning: true,
            phase: .photos,
            searchableCount: searchEngine.totalSize
        )

        // Collect assets to index (skip already indexed)
        var assetsToIndex: [PHAsset] = []
        for asset in photoAssets {
            if alreadyIndexed.contains(asset.localIdentifier) {
                indexed += 1
                progress.completed = indexed
            } else {
                assetsToIndex.append(asset)
            }
        }
        progress.rateBaselineCompleted = indexed
        progress.phaseStartedAt = Date()

        let checkpointInterval = searchableCheckpointInterval(forLibrarySize: total)
        var nextSearchableReloadCount = nextSearchableCheckpoint(
            after: alreadyIndexed.count + alreadyIndexedVideos.count,
            isPro: isPro,
            interval: checkpointInterval
        )
        var lastProgressiveReloadAt: Date?
        var batchCursor = IndexingBatchCursor(items: assetsToIndex, batchSize: encodeBatchSize)
        var nextLoadTask: Task<LoadedPhotoBatch, Never>?
        let prefetchEnabled = isPro && IndexingConfig.prefetchBatchCapacity > 0

        func makeBatch() -> [PHAsset] {
            guard !isPro else { return batchCursor.nextBatch() }
            let remainingAllowed = max(0, FreeTier.maxIndexedMedia - newlyIndexed)
            return batchCursor.nextBatch(maxCount: remainingAllowed)
        }

        let firstBatch = makeBatch()
        if !firstBatch.isEmpty {
            nextLoadTask = loadPhotoBatchTask(assets: firstBatch)
        }

        // Process in batches with one bounded prefetch task ahead of encoding.
        while nextLoadTask != nil || batchCursor.hasRemaining {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: newlyIndexed, isPro: isPro) {
                hitFreeLimit = true
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
                progress.completed = indexed
                continue
            }

            // Phase 2: Batch Core ML encoding
            do {
                let images = loadedImages.map { $0.image }
                let encoder = imageEncoder
                let embeddings = try await Task.detached(priority: .userInitiated) {
                    if images.count > 1 {
                        return try encoder.encodeBatch(images: images)
                    }
                    return [try encoder.encode(image: images[0])]
                }.value

                for (i, (asset, _)) in loadedImages.enumerated() {
                    guard i < embeddings.count else { break }
                    guard FreeTier.canIndexMore(indexedMediaCount: newlyIndexed, isPro: isPro) else {
                        hitFreeLimit = true
                        break
                    }

                    batch.append(IndexedPhoto(
                        id: UUID().uuidString,
                        localIdentifier: asset.localIdentifier,
                        creationDate: asset.creationDate,
                        latitude: asset.location?.coordinate.latitude,
                        longitude: asset.location?.coordinate.longitude,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        embedding: embeddings[i].toFloat16Data(),
                        indexedAt: Date()
                    ))

                    newlyIndexed += 1
                }
            } catch {
                logger.error("Batch encoding failed: \(error.localizedDescription)")
                // Fallback: encode individually
                for (asset, image) in loadedImages {
                    guard FreeTier.canIndexMore(indexedMediaCount: newlyIndexed, isPro: isPro) else {
                        hitFreeLimit = true
                        break
                    }
                    do {
                        let encoder = imageEncoder
                        let embedding = try await Task.detached(priority: .userInitiated) {
                            try encoder.encode(image: image)
                        }.value

                        batch.append(IndexedPhoto(
                            id: UUID().uuidString,
                            localIdentifier: asset.localIdentifier,
                            creationDate: asset.creationDate,
                            latitude: asset.location?.coordinate.latitude,
                            longitude: asset.location?.coordinate.longitude,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            embedding: embedding.toFloat16Data(),
                            indexedAt: Date()
                        ))
                        newlyIndexed += 1
                    } catch {
                        logger.error("Single encode fallback failed for \(asset.localIdentifier): \(error.localizedDescription)")
                    }
                }
            }

            // Flush DB batches (outside encoding try block)
            if batch.count >= batchSize {
                await persistPhotoBatch(batch)
                batch.removeAll(keepingCapacity: true)
                let checkpoint = await reloadSearchIndexIfNeeded(
                    indexedMediaCount: newlyIndexed,
                    nextCheckpoint: nextSearchableReloadCount,
                    lastReloadAt: lastProgressiveReloadAt,
                    interval: checkpointInterval
                )
                nextSearchableReloadCount = checkpoint.nextCheckpoint
                lastProgressiveReloadAt = checkpoint.lastReloadAt
            }

            indexed += batchAssets.count
            progress.completed = indexed
            await Task.yield()
        }

        if !batch.isEmpty {
            await persistPhotoBatch(batch)
        }

        // Photos done; ensure the final photo checkpoint is searchable.
        await reloadSearchIndex()
        progress.photosComplete = true

        #if DEBUG
        logger.info("[IndexingService] Photo indexing complete: \(newlyIndexed) newly indexed")
        #endif

        // Pass 2: Index videos in background
        let videoAssetsToIndex = videoAssets.filter {
            !alreadyIndexedVideos.contains($0.localIdentifier)
        }
        if !videoAssets.isEmpty && !Task.isCancelled && !hitFreeLimit {
            indexed = videoAssets.count - videoAssetsToIndex.count
            progress = IndexingProgress(
                total: videoAssets.count,
                completed: indexed,
                isRunning: true,
                phase: .videos,
                photosComplete: true,
                searchableCount: searchEngine.totalSize,
                rateBaselineCompleted: indexed,
                phaseStartedAt: Date()
            )
        }
        for asset in videoAssetsToIndex {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: newlyIndexed, isPro: isPro) {
                hitFreeLimit = true
                break
            }

            if await indexVideo(asset: asset) {
                indexRebuildRequired = false
            }
            newlyIndexed += 1
            indexed += 1
            progress.completed = indexed
            if indexed % 10 == 0 { await Task.yield() }
        }

        // Reload again to include videos
        if !videoAssets.isEmpty {
            await reloadSearchIndex()
        }
        progress.isRunning = false

        #if DEBUG
        logger.info("[IndexingService] Indexing complete in \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - indexingStart))s")
        #endif

        // Geocode location strings in background (doesn't block search)
        if !Task.isCancelled {
            scheduleDeferredEnrichment()
            scheduleSurpriseValidation()
            launchGeocoding()
        }
    }

    private func performFolderIndexing(url: URL, name: String) async {
        beginBackgroundTask()
        defer { endBackgroundTask() }
        defer { progress.isRunning = false }

        // Bail out if we can't acquire the security-scoped resource. Continuing
        // without access would fail later with confusing permission errors.
        let hasAccess = url.startAccessingSecurityScopedResource()
        guard hasAccess else {
            logger.error("[IndexingService] Could not acquire security-scoped access for folder: \(url.lastPathComponent)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let sourceId = UUID().uuidString

        if let bookmarkData = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmarkData, forKey: AppKeys.folderBookmark(sourceId: sourceId))
        }

        let source = PhotoSource(
            id: sourceId, type: PhotoSourceType.folder.rawValue, path: url.path, name: name,
            addedAt: Date(), lastIndexedAt: nil, photoCount: 0
        )
        do {
            let db = database
            try await Task.detached(priority: .utility) {
                try db.insertSource(source)
            }.value
        }
        catch { logger.error("Failed to create source: \(error.localizedDescription)"); return }

        let imageURLs = await Task.detached(priority: .utility) {
            FolderScanner.scanFolder(at: url)
        }.value
        progress = IndexingProgress(
            total: imageURLs.count,
            completed: 0,
            isRunning: true,
            searchableCount: searchEngine.totalSize
        )

        let db = database
        let alreadyIndexed = await Task.detached(priority: .utility) {
            (try? db.allIndexedFilePaths()) ?? []
        }.value
        var indexed = 0
        var batch: [IndexedPhoto] = []

        for imageURL in imageURLs {
            if Task.isCancelled { break }

            if alreadyIndexed.contains(imageURL.path) {
                indexed += 1
                progress.completed = indexed
                continue
            }

            let loadedImage = await Task.detached(priority: .utility) {
                FolderScanner.loadImage(from: imageURL)
            }.value
            guard let image = loadedImage else {
                indexed += 1
                progress.completed = indexed
                continue
            }

            do {
                let encoder = imageEncoder
                let embedding = try await Task.detached(priority: .userInitiated) {
                    try encoder.encode(image: image)
                }.value
                let metadata = await Task.detached(priority: .utility) {
                    FolderScanner.extractMetadata(from: imageURL)
                }.value

                // Use original image dimensions from the file, not the resized 224x224 image
                var (originalWidth, originalHeight) = await Task.detached(priority: .utility) {
                    var width = 0
                    var height = 0
                    if let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                        width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                        height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                    }
                    return (width, height)
                }.value
                if originalWidth == 0 || originalHeight == 0 {
                    // Fallback to UIImage size (may still be resized, but better than nothing)
                    if originalWidth == 0 { originalWidth = Int(image.size.width) }
                    if originalHeight == 0 { originalHeight = Int(image.size.height) }
                }

                batch.append(IndexedPhoto(
                    id: UUID().uuidString,
                    localIdentifier: FolderScanner.localIdentifier(for: imageURL, within: url, sourceId: sourceId),
                    creationDate: metadata.date,
                    latitude: metadata.latitude,
                    longitude: metadata.longitude,
                    pixelWidth: originalWidth,
                    pixelHeight: originalHeight,
                    embedding: embedding.toFloat16Data(),
                    indexedAt: Date(),
                    sourceId: sourceId,
                    filePath: imageURL.path
                ))

                if batch.count >= batchSize {
                    let db = database
                    let photosToInsert = batch
                    try await Task.detached(priority: .utility) {
                        _ = try db.insertPhotos(
                            photosToInsert,
                            completingRequiredRebuild: false
                        )
                    }.value
                    batch.removeAll(keepingCapacity: true)
                }
            } catch {
                logger.error("Failed to index \(imageURL.lastPathComponent): \(error.localizedDescription)")
            }

            indexed += 1
            progress.completed = indexed
            if indexed % 10 == 0 { await Task.yield() }
        }

        if !batch.isEmpty {
            do {
                let db = database
                let photosToInsert = batch
                try await Task.detached(priority: .utility) {
                    _ = try db.insertPhotos(
                        photosToInsert,
                        completingRequiredRebuild: false
                    )
                }.value
            } catch {
                logger.error("Failed to flush folder batch: \(error.localizedDescription), retrying individually")
                for photo in batch {
                    do {
                        let db = database
                        try await Task.detached(priority: .utility) {
                            _ = try db.insertPhotos(
                                [photo],
                                completingRequiredRebuild: false
                            )
                        }.value
                    }
                    catch { logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)") }
                }
            }
        }

        do {
            let db = database
            try await Task.detached(priority: .utility) {
                try db.updateSourceStats(sourceId, photoCount: indexed)
            }.value
        }
        catch { logger.error("Failed to update source stats: \(error.localizedDescription)") }

        await reloadSearchIndex()
        scheduleDeferredEnrichment()
    }

    @discardableResult
    private func reloadSearchIndex() async -> Bool {
        do {
            #if DEBUG
            logger.info("[IndexingService] reloadSearchIndex start; previousIndexVersion=\(self.indexVersion), progressPhase=\(String(describing: self.progress.phase)), progressRunning=\(self.progress.isRunning)")
            #endif
            let didLoad = try await Task.detached(priority: .userInitiated) { [searchEngine] in
                try searchEngine.loadIndex()
                return searchEngine.isIndexLoaded
            }.value
            isReady = didLoad
            if didLoad {
                indexVersion += 1
                progress.searchableCount = searchEngine.totalSize
                onIndexReady?()
                #if DEBUG
                logger.info("[IndexingService] reloadSearchIndex success; indexVersion=\(self.indexVersion), totalSize=\(self.searchEngine.totalSize), photos=\(self.searchEngine.indexSize), videos=\(self.searchEngine.videoSize)")
                #endif
                return true
            } else {
                #if DEBUG
                logger.info("[IndexingService] reloadSearchIndex did not load an index; indexVersion=\(self.indexVersion)")
                #endif
                onIndexUnavailable?()
            }
        } catch {
            logger.error("Failed to reload search index: \(error.localizedDescription)")
            isReady = false
            onIndexUnavailable?()
        }
        return false
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
        if isPro { return IndexingConfig.firstSearchableCheckpoint }
        return min(IndexingConfig.firstSearchableCheckpoint, FreeTier.maxIndexedMedia)
    }

    private func searchableCheckpointInterval(forLibrarySize librarySize: Int) -> Int {
        if librarySize >= IndexingConfig.largeLibraryProgressiveReloadThreshold {
            return IndexingConfig.largeLibrarySearchableCheckpointInterval
        }
        return IndexingConfig.searchableCheckpointInterval
    }

    private func nextSearchableCheckpoint(after indexedMediaCount: Int, isPro: Bool, interval: Int) -> Int {
        let first = firstSearchableCheckpoint(isPro: isPro)
        guard indexedMediaCount >= first else { return first }
        return indexedMediaCount + interval
    }

    private func reloadSearchIndexIfNeeded(
        indexedMediaCount: Int,
        nextCheckpoint: Int,
        lastReloadAt: Date?,
        interval: Int
    ) async -> (nextCheckpoint: Int, lastReloadAt: Date?) {
        guard indexedMediaCount >= nextCheckpoint else {
            return (nextCheckpoint, lastReloadAt)
        }
        if let lastReloadAt {
            let elapsed = Date().timeIntervalSince(lastReloadAt)
            guard elapsed >= IndexingConfig.minSearchReloadIntervalSeconds else {
                return (nextCheckpoint, lastReloadAt)
            }
        }
        let didLoad = await reloadSearchIndex()
        let reloadDate = didLoad ? Date() : lastReloadAt
        let followingCheckpoint = indexedMediaCount + interval
        return (followingCheckpoint, reloadDate)
    }

    private func scheduleDeferredAutoResume(totalInLibrary: Int?) {
        autoResumeTask?.cancel()
        autoResumeTask = Task { [weak self] in
            let delay = UInt64(IndexingConfig.postLaunchAutoResumeDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.checkForIncompleteIndex(totalInLibrary: totalInLibrary)
            self?.autoResumeTask = nil
        }
    }

    private func scheduleDeferredEnrichment(delaySeconds: TimeInterval = 0) {
        cancelEnrichmentTask()
        enrichmentTaskGeneration += 1
        let generation = enrichmentTaskGeneration
        enrichmentTask = Task { [weak self] in
            if delaySeconds > 0 {
                let delay = UInt64(delaySeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self, !self.progress.isRunning else { return }
            await self.performPhotoEnrichment(generation: generation)
        }
    }

    private func cancelEnrichmentTask() {
        enrichmentTaskGeneration += 1
        enrichmentTask?.cancel()
        enrichmentTask = nil
    }

    private func cancelEnrichmentWork() {
        cancelEnrichmentTask()
        if progress.phase == .enrichment {
            progress.isRunning = false
        }
    }

    private func scheduleSurpriseValidation() {
        surpriseValidationTask?.cancel()
        surpriseValidationTask = Task.detached(priority: .utility) { [searchEngine] in
            let delay = UInt64(IndexingConfig.surpriseValidationDelaySeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, searchEngine.isIndexLoaded else { return }
            await SurpriseQueries.validateQueries(using: searchEngine)
        }
    }

    /// Check if there are unindexed photos/videos remaining from an interrupted indexing session.
    /// If found, automatically resume indexing in the background.
    private func checkForIncompleteIndex(totalInLibrary providedTotal: Int? = nil) async {
        let totalInLibrary = providedTotal ?? PhotoLibrary.fetchAllMedia().count

        let counts: IndexedMediaCounts
        do {
            let db = database
            counts = try await Task.detached(priority: .utility) {
                try db.indexedMediaCounts()
            }.value
        } catch {
            logger.error("Failed to check index completeness: \(error.localizedDescription)")
            return
        }

        let totalIndexed = counts.total
        guard totalIndexed > 0 else { return }
        let unindexedCount = totalInLibrary - totalIndexed

        if unindexedCount <= 0 {
            // Everything indexed — launch geocoding directly
            launchGeocoding()
            return
        }

        #if DEBUG
        logger.info("[IndexingService] Incomplete index detected: \(totalIndexed)/\(totalInLibrary) indexed, \(unindexedCount) remaining. Auto-resuming.")
        #endif

        // Auto-resume indexing for the remaining items
        // performIndexing will launch geocoding when it finishes
        if progress.phase == .enrichment {
            cancelEnrichmentWork()
        }
        guard markRunningIfIdle() else { return }
        newPhotosAvailable = false
        indexingTask = Task { await performIndexing() }
    }

    // MARK: - Photo Enrichment

    private func performPhotoEnrichment(generation: Int) async {
        defer {
            if enrichmentTaskGeneration == generation {
                enrichmentTask = nil
                if progress.phase == .enrichment {
                    progress.isRunning = false
                }
            }
        }

        let remaining: Int
        do {
            let db = database
            remaining = try await Task.detached(priority: .utility) {
                try db.photosNeedingEnrichmentCount()
            }.value
        } catch {
            logger.error("Failed to count photos needing enrichment: \(error.localizedDescription)")
            return
        }
        guard remaining > 0 else { return }

        progress = IndexingProgress(
            total: remaining,
            completed: 0,
            isRunning: true,
            phase: .enrichment,
            photosComplete: true,
            searchableCount: searchEngine.totalSize
        )

        var completed = 0
        while !Task.isCancelled {
            let candidates: [PhotoEnrichmentCandidate]
            do {
                let db = database
                candidates = try await Task.detached(priority: .utility) {
                    try db.photosNeedingEnrichment(limit: IndexingConfig.enrichmentBatchSize)
                }.value
            } catch {
                logger.error("Failed to fetch photo enrichment batch: \(error.localizedDescription)")
                return
            }
            guard !candidates.isEmpty else { break }

            var updates: [PhotoEnrichmentUpdate] = []
            updates.reserveCapacity(candidates.count)
            for candidate in candidates {
                if Task.isCancelled { return }
                updates.append(await enrichPhoto(candidate))
                await Task.yield()
            }

            do {
                let db = database
                try await Task.detached(priority: .utility) {
                    try db.updatePhotoEnrichment(updates)
                }.value
                completed += updates.count
                progress.completed = min(completed, progress.total)
            } catch {
                logger.error("Failed to update photo enrichment batch: \(error.localizedDescription)")
                return
            }
        }

        if completed > 0, !Task.isCancelled, enrichmentTaskGeneration == generation {
            await reloadSearchIndex()
        }
    }

    private func enrichPhoto(_ candidate: PhotoEnrichmentCandidate) async -> PhotoEnrichmentUpdate {
        guard let image = await loadImageForEnrichment(candidate, targetSize: CGSize(width: 224, height: 224)) else {
            return PhotoEnrichmentUpdate(
                localIdentifier: candidate.localIdentifier,
                ocrText: nil,
                sharpnessScore: nil,
                sceneLabels: nil,
                outcome: .loadFailed(at: Date())
            )
        }

        var ocrText: String?
        let quickOcr = await Task.detached {
            OCRService.extractTextFast(from: image)
        }.value

        if OCRService.isLikelyScreenshot(width: candidate.pixelWidth, height: candidate.pixelHeight) {
            let ocrWidth = min(candidate.pixelWidth, 2048)
            let ocrHeight = min(candidate.pixelHeight, 2048)
            if let fullImage = await loadImageForEnrichment(
                candidate,
                targetSize: CGSize(width: CGFloat(ocrWidth), height: CGFloat(ocrHeight)),
                highQuality: true
            ) {
                ocrText = await Task.detached { OCRService.extractText(from: fullImage) }.value
            }
        }

        if ocrText == nil || (ocrText?.isEmpty ?? true) {
            ocrText = quickOcr
        }
        if let text = ocrText, text.count < 3 {
            ocrText = nil
        }

        let sharpness = await Task.detached {
            BlurDetector.sharpnessScore(for: image)
        }.value

        let sceneLabels = await Task.detached {
            SceneClassifier.classify(image: image)
        }.value

        return PhotoEnrichmentUpdate(
            localIdentifier: candidate.localIdentifier,
            ocrText: ocrText,
            sharpnessScore: sharpness,
            sceneLabels: SceneClassifier.labelsToString(sceneLabels)
        )
    }

    private func loadImageForEnrichment(
        _ candidate: PhotoEnrichmentCandidate,
        targetSize: CGSize,
        highQuality: Bool = false
    ) async -> UIImage? {
        if let filePath = candidate.filePath {
            return FolderScanner.loadImageFromBookmarkedSource(
                filePath: filePath,
                sourceId: candidate.sourceId,
                targetSize: targetSize
            )
        }
        guard let asset = PhotoLibrary.getAsset(by: candidate.localIdentifier) else {
            return nil
        }
        if highQuality {
            return await PhotoLibrary.loadImage(for: asset, targetSize: targetSize)
        }
        return await PhotoLibrary.loadImageForIndexing(for: asset, targetSize: targetSize)
    }

    // MARK: - Background Task

    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Indexing") { [weak self] in
            // iOS is about to suspend — save progress and end task
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Orphan Cleanup

    private func cleanOrphanedEmbeddings(allMedia: PHFetchResult<PHAsset>? = nil) async {
        do {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited else {
                #if DEBUG
                logger.info("[IndexingService] Skipping orphan cleanup under limited Photos access")
                #endif
                return
            }
            let media: PHFetchResult<PHAsset>
            if let allMedia {
                media = allMedia
            } else {
                media = await Task.detached(priority: .utility) {
                    PhotoLibrary.fetchAllMedia()
                }.value
            }
            var libraryIds = Set<String>(minimumCapacity: media.count)
            for i in 0..<media.count {
                libraryIds.insert(media[i].localIdentifier)
            }

            let db = database
            let indexedIdentifiers = try await Task.detached(priority: .utility) {
                try db.allIndexedMediaIdentifiers()
            }.value
            let indexedPhotoIds = indexedIdentifiers.photos
            let orphanedPhotos = indexedPhotoIds.subtracting(libraryIds)

            let indexedVideoIds = indexedIdentifiers.videos
            let orphanedVideos = indexedVideoIds.subtracting(libraryIds)

            let totalOrphans = orphanedPhotos.count + orphanedVideos.count
            guard totalOrphans > 0 else { return }

            // Safety: skip if more than 20% are orphaned (likely a permissions issue, not real deletions).
            // But force cleanup after 3 consecutive skips so the index doesn't stay stale forever.
            let totalIndexed = indexedPhotoIds.count + indexedVideoIds.count
            let orphanRatio = Double(totalOrphans) / Double(max(totalIndexed, 1))
            let skipKey = "orphanCleanupConsecutiveSkips"
            if orphanRatio > IndexingConfig.maxOrphanRatio {
                let consecutiveSkips = UserDefaults.standard.integer(forKey: skipKey) + 1
                if consecutiveSkips < 3 {
                    UserDefaults.standard.set(consecutiveSkips, forKey: skipKey)
                    logger.warning("Orphan cleanup skipped (\(consecutiveSkips)/3): \(totalOrphans)/\(totalIndexed) (\(Int(orphanRatio * 100))%) exceeds 20% threshold")
                    return
                }
                logger.info("Forcing orphan cleanup after \(consecutiveSkips) consecutive skips: \(totalOrphans)/\(totalIndexed) orphaned")
            }
            UserDefaults.standard.set(0, forKey: skipKey)

            // Delete orphaned photos
            if !orphanedPhotos.isEmpty {
                try await Task.detached(priority: .utility) {
                    try db.deleteOrphanedPhotos(localIdentifiers: orphanedPhotos)
                }.value
                #if DEBUG
                logger.info("Cleaned \(orphanedPhotos.count) orphaned photo embeddings")
                #endif
            }

            // Delete orphaned videos
            if !orphanedVideos.isEmpty {
                try await Task.detached(priority: .utility) {
                    try db.deleteOrphanedVideos(localIdentifiers: orphanedVideos)
                }.value
                #if DEBUG
                logger.info("Cleaned \(orphanedVideos.count) orphaned video embeddings")
                #endif
            }
        } catch {
            logger.error("Orphan cleanup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Background Location Geocoding

    private func launchGeocoding() {
        guard geocodingTask == nil else { return }
        // Strong [self] capture is safe here because IndexingService is
        // @MainActor-isolated (implicitly Sendable), and the retain cycle
        // (self → task → self) is broken at the end when we nil the task.
        // Strong capture also avoids Swift 6's ban on capturing a mutable
        // `weak var self` across a @Sendable concurrency boundary.
        geocodingTask = Task.detached(priority: .utility) { [self] in
            await geocodeIndexedMedia()
            await MainActor.run {
                self.geocodingTask = nil
            }
        }
    }

    /// Reverse-geocodes indexed photos and videos that have GPS but no location strings yet.
    /// Runs in the background after indexing completes without blocking search.
    private func geocodeIndexedMedia() async {
        // Absolute (library-wide) figures so the progress indicator reflects
        // total geocoding progress across the library, not just work remaining
        // in this session. Without this, the bar appears to reset to 0 on
        // every launch even though prior sessions already did most of the work.
        let db = database
        let counts: GeocodingCounts
        do {
            counts = try await Task.detached(priority: .utility) {
                try db.geocodingCounts()
            }.value
        } catch {
            logger.error("[Geocoder] Failed to load geocoding counts: \(error.localizedDescription)")
            geocodingProgress = nil
            return
        }
        let totalWithGPS = counts.totalWithGPS
        let remainingAtStart = counts.remaining
        let alreadyGeocoded = max(0, totalWithGPS - remainingAtStart)

        #if DEBUG
        logger.info("[Geocoder] Starting: \(remainingAtStart) / \(totalWithGPS) remaining out of GPS-tagged media (\(counts.indexedPhotos) photos + \(counts.indexedVideos) videos indexed)")
        #endif

        if remainingAtStart > 0 {
            geocodingProgress = (completed: alreadyGeocoded, total: totalWithGPS)
        }

        let photoResult = await geocodeMediaSource(
            label: "photos",
            progressBase: alreadyGeocoded,
            fetchBatch: {
                try await Task.detached(priority: .utility) {
                    try db.photosNeedingLocationBackfill(limit: 500)
                }.value
            },
            updateLocation: { localIdentifier, location in
                try await Task.detached(priority: .utility) {
                    try db.updatePhotoLocationStrings(
                        localIdentifier: localIdentifier,
                        city: location.city,
                        state: location.state,
                        country: location.country,
                        name: location.name
                    )
                }.value
            }
        )
        if photoResult.cancelled { return }

        let videoResult = await geocodeMediaSource(
            label: "videos",
            progressBase: alreadyGeocoded + photoResult.completed,
            fetchBatch: {
                try await Task.detached(priority: .utility) {
                    try db.videosNeedingLocationBackfill(limit: 500)
                }.value
            },
            updateLocation: { localIdentifier, location in
                try await Task.detached(priority: .utility) {
                    try db.updateVideoLocationStrings(
                        localIdentifier: localIdentifier,
                        city: location.city,
                        state: location.state,
                        country: location.country,
                        name: location.name
                    )
                }.value
            }
        )
        if videoResult.cancelled { return }
        let totalGeocoded = photoResult.completed + videoResult.completed

        #if DEBUG
        logger.info("[Geocoder] Completed: \(totalGeocoded) media items geocoded")
        #endif
        if totalGeocoded > 0 {
            let engine = searchEngine
            do {
                try await Task.detached(priority: .utility) {
                    try engine.loadIndex()
                }.value
            } catch {
                logger.error("[Geocoder] Failed to reload search index: \(error.localizedDescription)")
            }
        }
        geocodingProgress = nil
    }

    private func geocodeMediaSource(
        label: String,
        progressBase: Int,
        fetchBatch: () async throws -> [(localIdentifier: String, lat: Double, lon: Double)],
        updateLocation: (String, LocationStrings) async throws -> Void
    ) async -> (completed: Int, cancelled: Bool) {
        var completed = 0
        // Avoid retry loops within one run. Failed coordinates and database
        // writes remain eligible on the next app launch.
        var failedIdentifiers = Set<String>()

        while true {
            let batch: [(localIdentifier: String, lat: Double, lon: Double)]
            do {
                batch = try await fetchBatch()
            } catch {
                logger.error("[Geocoder] Failed to fetch \(label) backfill batch: \(error.localizedDescription)")
                break
            }
            if batch.isEmpty { break }

            let actionable = batch.filter {
                !failedIdentifiers.contains($0.localIdentifier)
            }
            if actionable.isEmpty { break }

            for candidate in actionable {
                if Task.isCancelled { return (completed, true) }
                guard let location = await reverseGeocoder.reverseGeocode(
                    latitude: candidate.lat,
                    longitude: candidate.lon
                ) else {
                    failedIdentifiers.insert(candidate.localIdentifier)
                    continue
                }

                do {
                    try await updateLocation(candidate.localIdentifier, location)
                } catch {
                    failedIdentifiers.insert(candidate.localIdentifier)
                    logger.error("[Geocoder] Failed to update \(label) location for \(candidate.localIdentifier): \(error.localizedDescription)")
                    continue
                }

                completed += 1
                if let current = geocodingProgress {
                    geocodingProgress = (
                        completed: progressBase + completed,
                        total: current.total
                    )
                }

                #if DEBUG
                if completed <= 5 || completed % 50 == 0 {
                    logger.info("[Geocoder] \(label) #\(completed): \(location.city ?? "?") (\(candidate.lat), \(candidate.lon))")
                }
                #endif
            }

            #if DEBUG
            logger.info("[Geocoder] \(label) progress: \(completed) geocoded, \(failedIdentifiers.count) failed")
            #endif
        }

        return (completed, false)
    }

    // MARK: - Video Indexing

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

        let numFrames = VideoFrameExtractor.frameCount(forDuration: durationSeconds)
        let positions = VideoFrameExtractor.framePositions(count: numFrames)

        let frames = await VideoFrameExtractor.extractFrames(from: avAsset, positions: positions)
        guard !frames.isEmpty else { return false }

        // Reverse geocode video location
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

        // Batch-encode all frames at once
        do {
            let images = frames.map { $0.image }
            let encoder = imageEncoder
            let embeddings = try await Task.detached(priority: .userInitiated) {
                if images.count > 1 {
                    return try encoder.encodeBatch(images: images)
                }
                return [try encoder.encode(image: images[0])]
            }.value

            // Batch-insert all frames in one transaction
            var frameRecords: [IndexedVideoFrame] = []
            for (i, (position, _)) in frames.enumerated() {
                guard i < embeddings.count else { break }
                frameRecords.append(IndexedVideoFrame(
                    id: UUID().uuidString,
                    videoId: videoId,
                    framePosition: position,
                    embedding: embeddings[i].toFloat16Data(),
                    indexedAt: Date()
                ))
            }
            let db = database
            let shouldCompleteRequiredRebuild = indexRebuildRequired
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
