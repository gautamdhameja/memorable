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

@MainActor
class IndexingService: ObservableObject {
    @Published var progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
    @Published var isReady = false
    @Published var newPhotosAvailable = false
    @Published var indexVersion: Int = 0
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
    @Published var geocodingProgress: (completed: Int, total: Int)?

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
        let loaded = await loadExistingIndexIfAvailable(cleanOrphans: cleanOrphans, loadPriority: loadPriority)
        startObservingPhotoChanges()
        if scheduleAutoResume && loaded {
            scheduleDeferredAutoResume(totalInLibrary: launchLibraryCountSnapshot)
            scheduleDeferredEnrichment(
                delaySeconds: IndexingConfig.postLaunchAutoResumeDelaySeconds
                    + IndexingConfig.surpriseValidationDelaySeconds
            )
        }
        return loaded
    }

    @discardableResult
    func loadExistingIndexIfAvailable(cleanOrphans: Bool = false, loadPriority: TaskPriority = .utility) async -> Bool {
        do {
            let photoCount = try database.indexedCount()
            let videoCount: Int
            do {
                videoCount = try database.videoIndexedCount()
            } catch {
                logger.error("Failed to count indexed videos: \(error.localizedDescription)")
                videoCount = 0
            }
            let totalIndexed = photoCount + videoCount

            if totalIndexed > 0 {
                #if DEBUG
                logger.info("[IndexingService] Found \(photoCount) indexed photos and \(videoCount) indexed videos, loading index")
                #endif

                if cleanOrphans {
                    let allMedia = PhotoLibrary.fetchAllMedia()
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
                let totalIndexed = try db.indexedCount() + db.videoIndexedCount()

                if totalInLibrary > totalIndexed {
                    await MainActor.run { self.newPhotosAvailable = true }
                } else if totalInLibrary < totalIndexed {
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

    private func performIndexing() async {
        // Request background execution time so indexing continues when app is backgrounded
        beginBackgroundTask()
        defer { endBackgroundTask() }

        let allAssets = PhotoLibrary.fetchAllMedia()
        let total = allAssets.count
        hitFreeLimit = false

        #if DEBUG
        logger.info("[IndexingService] Starting indexing: \(total) total assets in library")
        let indexingStart = CFAbsoluteTimeGetCurrent()
        #endif

        let alreadyIndexed: Set<String>
        do {
            alreadyIndexed = try database.allIndexedIdentifiers()
        } catch {
            logger.error("Failed to load indexed identifiers: \(error.localizedDescription)")
            alreadyIndexed = []
        }
        let alreadyIndexedVideos: Set<String>
        do {
            alreadyIndexedVideos = try database.allIndexedVideoIdentifiers()
        } catch {
            logger.error("Failed to load indexed video identifiers: \(error.localizedDescription)")
            alreadyIndexedVideos = []
        }
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

        let checkpointInterval = searchableCheckpointInterval(forLibrarySize: total)
        var nextSearchableReloadCount = nextSearchableCheckpoint(
            after: alreadyIndexed.count + alreadyIndexedVideos.count,
            isPro: isPro,
            interval: checkpointInterval
        )
        var lastProgressiveReloadAt: Date?
        var batchStart = 0
        var nextLoadTask: Task<LoadedPhotoBatch, Never>?
        let prefetchEnabled = isPro && IndexingConfig.prefetchBatchCapacity > 0

        func makeBatch(start: Int) -> [PHAsset] {
            guard start < assetsToIndex.count else { return [] }
            let batchEnd = min(start + encodeBatchSize, assetsToIndex.count)
            let slice = Array(assetsToIndex[start..<batchEnd])
            guard !isPro else { return slice }
            let remainingAllowed = max(0, FreeTier.maxIndexedMedia - newlyIndexed)
            return Array(slice.prefix(remainingAllowed))
        }

        let firstBatch = makeBatch(start: batchStart)
        if !firstBatch.isEmpty {
            nextLoadTask = loadPhotoBatchTask(assets: firstBatch)
            batchStart += encodeBatchSize
        }

        // Process in batches with one bounded prefetch task ahead of encoding.
        while let loadTask = nextLoadTask {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: newlyIndexed, isPro: isPro) {
                hitFreeLimit = true
                break
            }

            if prefetchEnabled {
                let nextBatch = makeBatch(start: batchStart)
                nextLoadTask = nextBatch.isEmpty ? nil : loadPhotoBatchTask(assets: nextBatch)
                if !nextBatch.isEmpty {
                    batchStart += encodeBatchSize
                }
            } else {
                nextLoadTask = nil
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
                let embeddings: [[Float]]
                if images.count > 1 {
                    embeddings = try imageEncoder.encodeBatch(images: images)
                } else {
                    embeddings = [try imageEncoder.encode(image: images[0])]
                }

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
                        let embedding = try imageEncoder.encode(image: image)

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
                do {
                    try database.insertPhotos(batch)
                } catch {
                    logger.error("Failed to insert photo batch: \(error.localizedDescription), retrying individually")
                    for photo in batch {
                        do { try database.insertPhotos([photo]) }
                        catch { logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)") }
                    }
                }
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
            if !prefetchEnabled {
                let followingBatch = makeBatch(start: batchStart)
                if !followingBatch.isEmpty {
                    nextLoadTask = loadPhotoBatchTask(assets: followingBatch)
                    batchStart += encodeBatchSize
                }
            }
            await Task.yield()
        }

        if !batch.isEmpty {
            do {
                try database.insertPhotos(batch)
            } catch {
                logger.error("Failed to flush photo batch: \(error.localizedDescription), retrying individually")
                for photo in batch {
                    do { try database.insertPhotos([photo]) }
                    catch { logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)") }
                }
            }
        }

        // Photos done; ensure the final photo checkpoint is searchable.
        await reloadSearchIndex()
        progress.photosComplete = true

        #if DEBUG
        logger.info("[IndexingService] Photo indexing complete: \(newlyIndexed) newly indexed")
        #endif

        // Pass 2: Index videos in background
        if !videoAssets.isEmpty && !Task.isCancelled && !hitFreeLimit {
            indexed = 0
            progress = IndexingProgress(
                total: videoAssets.count,
                completed: 0,
                isRunning: true,
                phase: .videos,
                photosComplete: true,
                searchableCount: searchEngine.totalSize
            )
        }
        for asset in videoAssets {
            if Task.isCancelled { break }
            if !FreeTier.canIndexMore(indexedMediaCount: newlyIndexed, isPro: isPro) {
                hitFreeLimit = true
                break
            }

            if !alreadyIndexedVideos.contains(asset.localIdentifier) {
                await indexVideo(asset: asset)
                newlyIndexed += 1
            }
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
        do { try database.insertSource(source) }
        catch { logger.error("Failed to create source: \(error.localizedDescription)"); return }

        let imageURLs = FolderScanner.scanFolder(at: url)
        progress = IndexingProgress(
            total: imageURLs.count,
            completed: 0,
            isRunning: true,
            searchableCount: searchEngine.totalSize
        )

        let alreadyIndexed = (try? database.allIndexedFilePaths()) ?? []
        var indexed = 0
        var batch: [IndexedPhoto] = []

        for imageURL in imageURLs {
            if Task.isCancelled { break }

            if alreadyIndexed.contains(imageURL.path) {
                indexed += 1
                progress.completed = indexed
                continue
            }

            guard let image = FolderScanner.loadImage(from: imageURL) else {
                indexed += 1
                progress.completed = indexed
                continue
            }

            do {
                let embedding = try imageEncoder.encode(image: image)
                let metadata = FolderScanner.extractMetadata(from: imageURL)

                // Use original image dimensions from the file, not the resized 224x224 image
                var originalWidth = 0
                var originalHeight = 0
                if let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                    originalWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                    originalHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                }
                if originalWidth == 0 || originalHeight == 0 {
                    // Fallback to UIImage size (may still be resized, but better than nothing)
                    if originalWidth == 0 { originalWidth = Int(image.size.width) }
                    if originalHeight == 0 { originalHeight = Int(image.size.height) }
                }

                batch.append(IndexedPhoto(
                    id: UUID().uuidString,
                    localIdentifier: imageURL.lastPathComponent,
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
                    try database.insertPhotos(batch)
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
                try database.insertPhotos(batch)
            } catch {
                logger.error("Failed to flush folder batch: \(error.localizedDescription), retrying individually")
                for photo in batch {
                    do { try database.insertPhotos([photo]) }
                    catch { logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)") }
                }
            }
        }

        do { try database.updateSourceStats(sourceId, photoCount: indexed) }
        catch { logger.error("Failed to update source stats: \(error.localizedDescription)") }

        await reloadSearchIndex()
        scheduleDeferredEnrichment()
    }

    @discardableResult
    private func reloadSearchIndex() async -> Bool {
        do {
            let didLoad = try await Task.detached(priority: .userInitiated) { [searchEngine] in
                try searchEngine.loadIndex()
                return searchEngine.isIndexLoaded
            }.value
            isReady = didLoad
            if didLoad {
                indexVersion += 1
                progress.searchableCount = searchEngine.totalSize
                onIndexReady?()
                return true
            } else {
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

        let indexedPhotoCount: Int
        let indexedVideoCount: Int
        do {
            indexedPhotoCount = try database.indexedCount()
            indexedVideoCount = try database.videoIndexedCount()
        } catch {
            logger.error("Failed to check index completeness: \(error.localizedDescription)")
            return
        }

        let totalIndexed = indexedPhotoCount + indexedVideoCount
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
            remaining = try database.photosNeedingEnrichmentCount()
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
                candidates = try database.photosNeedingEnrichment(limit: IndexingConfig.enrichmentBatchSize)
            } catch {
                logger.error("Failed to fetch photo enrichment batch: \(error.localizedDescription)")
                return
            }
            guard !candidates.isEmpty else { break }

            for candidate in candidates {
                if Task.isCancelled { return }
                let update = await enrichPhoto(candidate)
                do {
                    try database.updatePhotoEnrichment(update)
                    completed += 1
                    progress.completed = min(completed, progress.total)
                } catch {
                    logger.error("Failed to update enrichment for \(candidate.localIdentifier): \(error.localizedDescription)")
                    return
                }
                await Task.yield()
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
                sceneLabels: nil
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
            let media = allMedia ?? PhotoLibrary.fetchAllMedia()
            var libraryIds = Set<String>(minimumCapacity: media.count)
            for i in 0..<media.count {
                libraryIds.insert(media[i].localIdentifier)
            }

            // Find orphaned photo embeddings
            let indexedPhotoIds = try database.allIndexedIdentifiers()
            let orphanedPhotos = indexedPhotoIds.subtracting(libraryIds)

            // Find orphaned video embeddings
            let indexedVideoIds = try database.allIndexedVideoIdentifiers()
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
                try database.deleteOrphanedPhotos(localIdentifiers: orphanedPhotos)
                #if DEBUG
                logger.info("Cleaned \(orphanedPhotos.count) orphaned photo embeddings")
                #endif
            }

            // Delete orphaned videos
            if !orphanedVideos.isEmpty {
                try database.deleteOrphanedVideos(localIdentifiers: orphanedVideos)
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
        var totalGeocoded = 0

        // Absolute (library-wide) figures so the progress indicator reflects
        // total geocoding progress across the library, not just work remaining
        // in this session. Without this, the bar appears to reset to 0 on
        // every launch even though prior sessions already did most of the work.
        let totalWithGPS = ((try? database.photosWithGPSCount()) ?? 0)
            + ((try? database.videosWithGPSCount()) ?? 0)
        let remainingAtStart = ((try? database.photosNeedingLocationBackfillCount()) ?? 0)
            + ((try? database.videosNeedingLocationBackfillCount()) ?? 0)
        let alreadyGeocoded = max(0, totalWithGPS - remainingAtStart)

        #if DEBUG
        let totalPhotos = (try? database.indexedCount()) ?? 0
        let totalVideos = (try? database.videoIndexedCount()) ?? 0
        logger.info("[Geocoder] Starting: \(remainingAtStart) / \(totalWithGPS) remaining out of GPS-tagged media (\(totalPhotos) photos + \(totalVideos) videos indexed)")
        #endif

        if remainingAtStart > 0 {
            await MainActor.run {
                self.geocodingProgress = (completed: alreadyGeocoded, total: totalWithGPS)
            }
        }

        // Track failures in-memory to avoid infinite retries within this session.
        // Failed coordinates are retried on next app launch.
        var failedIds = Set<String>()

        // Photos
        while true {
            let batch: [(localIdentifier: String, lat: Double, lon: Double)]
            do {
                batch = try database.photosNeedingLocationBackfill(limit: 500)
            } catch {
                logger.error("[Geocoder] Failed to fetch photo backfill batch: \(error.localizedDescription)")
                break
            }
            if batch.isEmpty { break }
            let actionable = batch.filter { !failedIds.contains($0.localIdentifier) }
            guard !actionable.isEmpty else { break }
            for (localId, lat, lon) in actionable {
                if Task.isCancelled { return }
                if let loc = await reverseGeocoder.reverseGeocode(latitude: lat, longitude: lon) {
                    try? database.updatePhotoLocationStrings(
                        localIdentifier: localId,
                        city: loc.city, state: loc.state,
                        country: loc.country, name: loc.name
                    )
                    totalGeocoded += 1
                    let doneSnapshot = alreadyGeocoded + totalGeocoded
                    await MainActor.run {
                        if let current = self.geocodingProgress {
                            self.geocodingProgress = (completed: doneSnapshot, total: current.total)
                        }
                    }
                    #if DEBUG
                    if totalGeocoded <= 5 || totalGeocoded % 50 == 0 {
                        logger.info("[Geocoder] #\(totalGeocoded): \(loc.city ?? "?") (\(lat), \(lon))")
                    }
                    #endif
                } else {
                    failedIds.insert(localId)
                    #if DEBUG
                    logger.info("[Geocoder] Failed: \(localId) (\(lat), \(lon))")
                    #endif
                }
            }
            #if DEBUG
            logger.info("[Geocoder] Photos progress: \(totalGeocoded) geocoded, \(failedIds.count) failed")
            #endif
        }

        // Videos
        while true {
            let batch: [(localIdentifier: String, lat: Double, lon: Double)]
            do {
                batch = try database.videosNeedingLocationBackfill(limit: 500)
            } catch {
                logger.error("[Geocoder] Failed to fetch video backfill batch: \(error.localizedDescription)")
                break
            }
            if batch.isEmpty { break }
            let actionable = batch.filter { !failedIds.contains($0.localIdentifier) }
            guard !actionable.isEmpty else { break }
            for (localId, lat, lon) in actionable {
                if Task.isCancelled { return }
                if let loc = await reverseGeocoder.reverseGeocode(latitude: lat, longitude: lon) {
                    try? database.updateVideoLocationStrings(
                        localIdentifier: localId,
                        city: loc.city, state: loc.state,
                        country: loc.country, name: loc.name
                    )
                    totalGeocoded += 1
                    let doneSnapshot = alreadyGeocoded + totalGeocoded
                    await MainActor.run {
                        if let current = self.geocodingProgress {
                            self.geocodingProgress = (completed: doneSnapshot, total: current.total)
                        }
                    }
                } else {
                    failedIds.insert(localId)
                }
            }
        }

        #if DEBUG
        logger.info("[Geocoder] Completed: \(totalGeocoded) media items geocoded")
        #endif
        if totalGeocoded > 0 {
            try? searchEngine.loadIndex()
        }
        await MainActor.run {
            self.geocodingProgress = nil
        }
    }

    // MARK: - Video Indexing

    private func indexVideo(asset: PHAsset) async {
        guard (try? database.isVideoIndexed(localIdentifier: asset.localIdentifier)) != true else { return }

        guard let avAsset = await VideoFrameExtractor.loadAVAsset(from: asset) else { return }

        guard let duration = try? await avAsset.load(.duration) else { return }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { return }

        let numFrames = VideoFrameExtractor.frameCount(forDuration: durationSeconds)
        let positions = VideoFrameExtractor.framePositions(count: numFrames)

        let frames = await VideoFrameExtractor.extractFrames(from: avAsset, positions: positions)
        guard !frames.isEmpty else { return }

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

        do {
            try database.insertVideo(video)
        } catch {
            logger.error("Failed to insert video record: \(error.localizedDescription)")
            return
        }

        // Batch-encode all frames at once
        do {
            let images = frames.map { $0.image }
            let embeddings: [[Float]]
            if images.count > 1 {
                embeddings = try imageEncoder.encodeBatch(images: images)
            } else {
                embeddings = [try imageEncoder.encode(image: images[0])]
            }

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
            try database.insertVideoFrames(frameRecords)
        } catch {
            logger.error("Failed to index video frames: \(error.localizedDescription)")
        }
    }
}
