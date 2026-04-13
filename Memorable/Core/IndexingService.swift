import Foundation
import Photos
import AVFoundation
import UIKit

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
    @Published var hitFreeLimit = false

    private let imageEncoder: ImageEncoder
    let searchEngine: SearchEngine
    private let database: DatabaseProtocol
    private var indexingTask: Task<Void, Never>?
    private let changeObserver = PhotoChangeObserver()
    private let batchSize = 20
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var surpriseValidationTask: Task<Void, Never>?
    private let reverseGeocoder = ReverseGeocoder()
    private var geocodingTask: Task<Void, Never>?

    init(imageEncoder: ImageEncoder, searchEngine: SearchEngine, database: DatabaseProtocol = AppDatabase.shared) {
        self.imageEncoder = imageEncoder
        self.searchEngine = searchEngine
        self.database = database
    }

    func checkAndLoadExistingIndex() async {
        do {
            let count = try database.indexedCount()

            // Fetch library once — shared across orphan cleanup and incomplete check
            let allMedia = PhotoLibrary.fetchAllMedia()

            if count > 0 {
                #if DEBUG
                logger.info("[IndexingService] Found \(count) indexed photos, loading index")
                #endif

                await cleanOrphanedEmbeddings(allMedia: allMedia)

                try searchEngine.loadIndex()
                isReady = true
                let videoCount: Int
                do {
                    videoCount = try database.videoIndexedCount()
                } catch {
                    logger.error("Failed to count indexed videos: \(error.localizedDescription)")
                    videoCount = 0
                }
                progress = IndexingProgress(total: count + videoCount, completed: count + videoCount, isRunning: false)

                #if DEBUG
                logger.info("[IndexingService] Index ready: \(count) photos, \(videoCount) videos")
                #endif
            }
            startObservingPhotoChanges()

            await checkForIncompleteIndex(allMedia: allMedia)
        } catch {
            logger.error("Failed to load existing index: \(error.localizedDescription)")
        }
    }

    func startIndexing() {
        guard !progress.isRunning else { return }
        progress.isRunning = true
        SurpriseQueries.clearValidated()
        indexingTask = Task { await performIndexing() }
    }

    func indexNewPhotosOnly() {
        guard !progress.isRunning else { return }
        progress.isRunning = true
        newPhotosAvailable = false
        indexingTask = Task { await performIndexing() }
    }

    func stopIndexing() {
        indexingTask?.cancel()
        indexingTask = nil
        surpriseValidationTask?.cancel()
        surpriseValidationTask = nil
        geocodingTask?.cancel()
        geocodingTask = nil
        progress.isRunning = false
    }

    func indexFolder(url: URL, name: String) {
        guard !progress.isRunning else { return }
        indexingTask = Task { await performFolderIndexing(url: url, name: name) }
    }

    // MARK: - Private

    private func startObservingPhotoChanges() {
        changeObserver.onNewPhotosDetected = { [weak self] in
            Task { @MainActor in self?.checkForNewPhotos() }
        }
        changeObserver.startObserving()
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
        var newlyIndexed = alreadyIndexed.count
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
        logger.info("[IndexingService] Library breakdown: \(photoAssets.count) photos, \(videoAssets.count) videos, \(alreadyIndexed.count) already indexed")
        #endif

        // Pass 1: Index all photos first (batch Core ML encoding)
        let encodeBatchSize = 16
        progress = IndexingProgress(total: photoAssets.count, completed: 0, isRunning: true, phase: .photos)

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

        // Process in batches
        for batchStart in stride(from: 0, to: assetsToIndex.count, by: encodeBatchSize) {
            if Task.isCancelled { break }
            if !isPro && newlyIndexed >= FreeTier.maxPhotos {
                hitFreeLimit = true
                break
            }

            let batchEnd = min(batchStart + encodeBatchSize, assetsToIndex.count)
            let batchAssets = Array(assetsToIndex[batchStart..<batchEnd])

            // Phase 1: Load images in parallel
            var loadedImages: [(asset: PHAsset, image: UIImage)] = []
            await withTaskGroup(of: (PHAsset, UIImage?).self) { group in
                for asset in batchAssets {
                    group.addTask {
                        let image = await PhotoLibrary.loadImage(for: asset)
                        return (asset, image)
                    }
                }
                for await (asset, image) in group {
                    if let image {
                        loadedImages.append((asset, image))
                    }
                }
            }

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

                // Phase 3: Post-process each result (OCR, sharpness, face detection)
                for (i, (asset, image)) in loadedImages.enumerated() {
                    guard i < embeddings.count else { break }

                    var ocrText: String?
                    // Tier 1: Fast OCR on 224x224 thumbnail (catches large text: signs, menus, whiteboards)
                    let quickOcr = await Task.detached {
                        OCRService.extractTextFast(from: image)
                    }.value

                    if OCRService.isLikelyScreenshot(width: asset.pixelWidth, height: asset.pixelHeight) {
                        // Tier 2: Full-res OCR for screenshots (catches small UI text, capped at 2048px)
                        let ocrWidth = min(asset.pixelWidth, 2048)
                        let ocrHeight = min(asset.pixelHeight, 2048)
                        if let fullImage = await PhotoLibrary.loadImage(
                            for: asset,
                            targetSize: CGSize(width: CGFloat(ocrWidth), height: CGFloat(ocrHeight))
                        ) {
                            ocrText = await Task.detached { OCRService.extractText(from: fullImage) }.value
                        }
                    }

                    // Use full-res result if available, otherwise use quick result
                    if ocrText == nil || (ocrText?.isEmpty ?? true) {
                        ocrText = quickOcr
                    }

                    // Filter out very short OCR results (likely noise from photo artifacts)
                    if let text = ocrText, text.count < 3 {
                        ocrText = nil
                    }

                    // Compute sharpness score (runs on the already-loaded image)
                    let sharpness = await Task.detached {
                        BlurDetector.sharpnessScore(for: image)
                    }.value

                    // Scene classification (runs on Neural Engine, ~5-15ms)
                    let sceneLabels = await Task.detached {
                        SceneClassifier.classify(image: image)
                    }.value
                    let sceneLabelsString = SceneClassifier.labelsToString(sceneLabels)

                    batch.append(IndexedPhoto(
                        id: UUID().uuidString,
                        localIdentifier: asset.localIdentifier,
                        creationDate: asset.creationDate,
                        latitude: asset.location?.coordinate.latitude,
                        longitude: asset.location?.coordinate.longitude,
                        pixelWidth: asset.pixelWidth,
                        pixelHeight: asset.pixelHeight,
                        embedding: embeddings[i].toFloat16Data(),
                        indexedAt: Date(),
                        ocrText: ocrText,
                        sharpnessScore: sharpness,
                        sceneLabels: sceneLabelsString
                    ))

                    newlyIndexed += 1
                }
            } catch {
                logger.error("Batch encoding failed: \(error.localizedDescription)")
                // Fallback: encode individually
                for (asset, image) in loadedImages {
                    do {
                        let embedding = try imageEncoder.encode(image: image)

                        // Fast OCR on 224x224 thumbnail
                        var fallbackOcr: String?
                        let quickOcrFallback = await Task.detached {
                            OCRService.extractTextFast(from: image)
                        }.value

                        if OCRService.isLikelyScreenshot(width: asset.pixelWidth, height: asset.pixelHeight) {
                            let ocrWidth = min(asset.pixelWidth, 2048)
                            let ocrHeight = min(asset.pixelHeight, 2048)
                            if let fullImage = await PhotoLibrary.loadImage(
                                for: asset,
                                targetSize: CGSize(width: CGFloat(ocrWidth), height: CGFloat(ocrHeight))
                            ) {
                                fallbackOcr = await Task.detached { OCRService.extractText(from: fullImage) }.value
                            }
                        }
                        if fallbackOcr == nil || (fallbackOcr?.isEmpty ?? true) {
                            fallbackOcr = quickOcrFallback
                        }
                        if let text = fallbackOcr, text.count < 3 {
                            fallbackOcr = nil
                        }

                        let fallbackSharpness = await Task.detached {
                            BlurDetector.sharpnessScore(for: image)
                        }.value

                        let fallbackLabels = await Task.detached {
                            SceneClassifier.classify(image: image)
                        }.value
                        let fallbackLabelsString = SceneClassifier.labelsToString(fallbackLabels)

                        batch.append(IndexedPhoto(
                            id: UUID().uuidString,
                            localIdentifier: asset.localIdentifier,
                            creationDate: asset.creationDate,
                            latitude: asset.location?.coordinate.latitude,
                            longitude: asset.location?.coordinate.longitude,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight,
                            embedding: embedding.toFloat16Data(),
                            indexedAt: Date(),
                            ocrText: fallbackOcr,
                            sharpnessScore: fallbackSharpness,
                            sceneLabels: fallbackLabelsString
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
            }

            indexed += batchAssets.count
            progress.completed = indexed
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

        // Photos done — make searchable immediately
        await reloadSearchIndex()
        progress.photosComplete = true

        #if DEBUG
        logger.info("[IndexingService] Photo indexing complete: \(newlyIndexed) newly indexed")
        #endif

        // Validate surprise queries against actual library content
        surpriseValidationTask?.cancel()
        surpriseValidationTask = Task.detached(priority: .utility) { [searchEngine] in
            await SurpriseQueries.validateQueries(using: searchEngine)
        }

        // Pass 2: Index videos in background
        if !videoAssets.isEmpty && !Task.isCancelled && !hitFreeLimit {
            indexed = 0
            progress = IndexingProgress(total: videoAssets.count, completed: 0, isRunning: true, phase: .videos, photosComplete: true)
        }
        for asset in videoAssets {
            if Task.isCancelled { break }
            if !isPro && newlyIndexed >= FreeTier.maxPhotos {
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
            launchGeocoding()
        }
    }

    private func performFolderIndexing(url: URL, name: String) async {
        beginBackgroundTask()
        defer { endBackgroundTask() }

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
        progress = IndexingProgress(total: imageURLs.count, completed: 0, isRunning: true)

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
        progress.isRunning = false
    }

    private func reloadSearchIndex() async {
        do {
            try searchEngine.loadIndex()
            isReady = true
            indexVersion += 1
        } catch {
            logger.error("Failed to reload search index: \(error.localizedDescription)")
        }
    }

    /// Check if there are unindexed photos/videos remaining from an interrupted indexing session.
    /// If found, automatically resume indexing in the background.
    private func checkForIncompleteIndex(allMedia: PHFetchResult<PHAsset>? = nil) async {
        let media = allMedia ?? PhotoLibrary.fetchAllMedia()
        let totalInLibrary = media.count

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
        guard !progress.isRunning else { return }
        progress.isRunning = true
        newPhotosAvailable = false
        indexingTask = Task { await performIndexing() }
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

        #if DEBUG
        let photosToGeocode = (try? database.photosNeedingLocationBackfill(limit: 10000).count) ?? 0
        let videosToGeocode = (try? database.videosNeedingLocationBackfill(limit: 10000).count) ?? 0
        let totalPhotos = (try? database.indexedCount()) ?? 0
        let totalVideos = (try? database.videoIndexedCount()) ?? 0
        logger.info("[Geocoder] Starting: \(photosToGeocode)/\(totalPhotos) photos need geocoding, \(videosToGeocode)/\(totalVideos) videos need geocoding")
        #endif

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
