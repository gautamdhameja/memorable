import Foundation
import Photos
import UIKit
import os

private let hitFreeLimitKey = "indexing.hitFreeLimit"

final class PhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let callback = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(
        initialState: nil
    )

    var onNewPhotosDetected: (@MainActor @Sendable () -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    func startObserving() {
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let callback = callback.withLock { $0 }
        DispatchQueue.main.async {
            callback?()
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
    private let changeObserver = PhotoChangeObserver()
    private let batchSize = IndexingConfig.batchInsertSize
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let reverseGeocoder = ReverseGeocoder()
    private let jobQueue = IndexingJobQueue()
    private var librarySession: PhotoLibraryIndexingWorker.Session?
    private var isObservingPhotoChanges = false
    private var launchLibraryCountSnapshot: Int?

    var onIndexReady: (() -> Void)?
    var onIndexUnavailable: (() -> Void)?

    private lazy var libraryWorker = PhotoLibraryIndexingWorker(
        imageEncoder: imageEncoder,
        database: database,
        batchSize: batchSize,
        callbacks: PhotoLibraryIndexingWorker.Callbacks(
            searchableCount: { [weak self] in self?.searchEngine.totalSize ?? 0 },
            rebuildRequired: { [weak self] in self?.indexRebuildRequired == true },
            completeRequiredRebuild: { [weak self] in self?.indexRebuildRequired = false },
            currentProgress: { [weak self] in
                self?.progress ?? IndexingProgress(total: 0, completed: 0, isRunning: false)
            },
            setProgress: { [weak self] in self?.progress = $0 },
            setHitFreeLimit: { [weak self] in self?.hitFreeLimit = $0 },
            reloadSearchIndex: { [weak self] in await self?.reloadSearchIndex() == true }
        )
    )

    private lazy var folderWorker = FolderIndexingWorker(
        imageEncoder: imageEncoder,
        database: database,
        batchSize: batchSize,
        callbacks: FolderIndexingWorker.Callbacks(
            searchableCount: { [weak self] in self?.searchEngine.totalSize ?? 0 },
            setProgress: { [weak self] in self?.progress = $0 },
            reloadSearchIndex: { [weak self] in _ = await self?.reloadSearchIndex() }
        )
    )

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
            enqueueLibraryIndexing(
                autoResumeLibraryCount: launchLibraryCountSnapshot,
                isAutoResume: true,
                delayAfterDependencies: IndexingConfig.postLaunchAutoResumeDelaySeconds,
                enqueueLaunchEnrichment: true
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
                    await enqueueAndWaitForOrphanCleanup(allMedia: allMedia)
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
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        SurpriseQueries.clearValidated()
        enqueueLibraryIndexing()
    }

    func indexNewPhotosOnly() {
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        newPhotosAvailable = false
        enqueueLibraryIndexing()
    }

    func rebuildRequiredIndex() {
        searchEngine.resumeAfterMemoryPressure()
        guard indexRebuildRequired else {
            startIndexing()
            return
        }

        stopIndexing()
        guard markRunningIfIdle() else { return }
        SurpriseQueries.clearValidated()
        enqueueLibraryIndexing(rebuildRequired: true)
    }

    func stopIndexing() {
        jobQueue.cancelAll()
        librarySession = nil
        geocodingProgress = nil
        progress.isRunning = false
        endBackgroundTask()
    }

    func deferEnrichmentForUserSearch() {
        guard jobQueue.contains(.enrichPhotos) else { return }
        jobQueue.cancel(.enrichPhotos)
        enqueueEnrichment(
            workflowID: UUID(),
            delayAfterDependencies: IndexingConfig.surpriseValidationDelaySeconds
        )
    }

    func cancelAllWorkForMemoryPressure() {
        jobQueue.cancelAll()
        librarySession = nil
        geocodingProgress = nil
        progress.isRunning = false
        isReady = false
        endBackgroundTask()
        searchEngine.suspendForMemoryPressure()
        onIndexUnavailable?()
    }

    func indexFolder(url: URL, name: String) {
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        let workflowID = UUID()
        let shouldResumeGeocoding = jobQueue.contains(.geocodeMedia)
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexFolder,
            priority: .userInitiated
        ) { [weak self] in
            guard let self else { return .cancelled }
            self.beginBackgroundTask()
            defer {
                self.endBackgroundTask()
                self.progress.isRunning = false
            }
            await self.folderWorker.index(url: url, name: name)
            guard !Task.isCancelled else { return .cancelled }
            self.enqueueEnrichment(workflowID: workflowID)
            if shouldResumeGeocoding {
                self.enqueueGeocoding(workflowID: workflowID)
            }
            return .completed
        })
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
        Task.detached {
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
                        await MainActor.run {
                            self.enqueueLightweightOrphanCleanup(
                                orphanedPhotoIDs: orphaned,
                                database: db,
                                searchEngine: engine
                            )
                        }
                    }
                }
            } catch {
                logger.error("Error checking for photo changes: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private func reloadSearchIndex() async -> Bool {
        guard !searchEngine.isMemoryPressureSuspended, !Task.isCancelled else {
            isReady = false
            onIndexUnavailable?()
            return false
        }
        do {
            #if DEBUG
            logger.info("[IndexingService] reloadSearchIndex start; previousIndexVersion=\(self.indexVersion), progressPhase=\(String(describing: self.progress.phase)), progressRunning=\(self.progress.isRunning)")
            #endif
            let didLoad = try await Task.detached(priority: .userInitiated) { [searchEngine] in
                try searchEngine.loadIndex()
                return searchEngine.isIndexLoaded
            }.value
            guard !searchEngine.isMemoryPressureSuspended, !Task.isCancelled else {
                isReady = false
                onIndexUnavailable?()
                return false
            }
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

    private enum AutoResumeDecision {
        case noIndex
        case complete
        case resume
    }

    private func enqueueLibraryIndexing(
        rebuildRequired: Bool = false,
        autoResumeLibraryCount: Int? = nil,
        isAutoResume: Bool = false,
        delayAfterDependencies: TimeInterval = 0,
        enqueueLaunchEnrichment: Bool = false
    ) {
        let workflowID = UUID()
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexPhotos,
            priority: .userInitiated,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self else { return .cancelled }
            if isAutoResume {
                switch await self.autoResumeDecision(totalInLibrary: autoResumeLibraryCount) {
                case .noIndex:
                    return .completed
                case .complete:
                    self.enqueueGeocoding(workflowID: workflowID)
                    return .completed
                case .resume:
                    self.cancelEnrichmentWork()
                    guard self.markRunningIfIdle() else { return .cancelled }
                    self.newPhotosAvailable = false
                }
            }

            if rebuildRequired {
                do {
                    let db = self.database
                    try await Task.detached(priority: .utility) {
                        try db.deleteAll()
                    }.value
                } catch {
                    logger.error("Failed to clear incompatible index before rebuild: \(error.localizedDescription)")
                    self.progress.isRunning = false
                    return .cancelled
                }
                self.searchEngine.dropIndex()
                self.isReady = false
            }

            self.beginBackgroundTask()
            self.librarySession = await self.libraryWorker.indexPhotos()
            if Task.isCancelled {
                self.librarySession = nil
                self.endBackgroundTask()
                self.progress.isRunning = false
                return .cancelled
            }
            return .completed
        })

        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexVideos,
            priority: .userInitiated,
            dependencies: [.indexPhotos]
        ) { [weak self] in
            guard let self else { return .cancelled }
            guard let session = self.librarySession else { return .completed }
            defer {
                self.librarySession = nil
                self.endBackgroundTask()
            }
            await self.libraryWorker.indexVideos(session: session)
            guard !Task.isCancelled else {
                self.progress.isRunning = false
                return .cancelled
            }
            if Self.shouldCompleteEmptyRequiredRebuild(
                rebuildRequired: self.indexRebuildRequired,
                hasMediaCandidates: session.hasMediaCandidates
            ) {
                do {
                    let db = self.database
                    try await Task.detached(priority: .utility) {
                        try db.clearIndexRebuildRequired()
                    }.value
                    self.indexRebuildRequired = false
                } catch {
                    logger.error("Failed to complete empty index rebuild: \(error.localizedDescription)")
                }
            }
            self.enqueuePostIndexingJobs(workflowID: workflowID)
            return .completed
        })

        if enqueueLaunchEnrichment {
            enqueueEnrichment(
                workflowID: workflowID,
                dependencies: [.indexPhotos],
                delayAfterDependencies: IndexingConfig.surpriseValidationDelaySeconds
            )
        }
    }

    static func shouldCompleteEmptyRequiredRebuild(
        rebuildRequired: Bool,
        hasMediaCandidates: Bool
    ) -> Bool {
        rebuildRequired && !hasMediaCandidates
    }

    private func enqueuePostIndexingJobs(workflowID: UUID) {
        jobQueue.cancel(.enrichPhotos)
        enqueueEnrichment(workflowID: workflowID, dependencies: [.indexVideos])
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .validateSurpriseQueries,
            priority: .maintenance,
            dependencies: [.indexVideos],
            delayAfterDependencies: IndexingConfig.surpriseValidationDelaySeconds
        ) { [weak self] in
            guard let self, self.searchEngine.isIndexLoaded else { return .cancelled }
            await SurpriseQueries.validateQueries(using: self.searchEngine)
            return Task.isCancelled ? .cancelled : .completed
        })
        enqueueGeocoding(workflowID: workflowID, dependencies: [.indexVideos])
    }

    private func enqueueEnrichment(
        workflowID: UUID,
        dependencies: Set<IndexingJobKind> = [],
        delayAfterDependencies: TimeInterval = 0
    ) {
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .enrichPhotos,
            priority: .enrichment,
            dependencies: dependencies,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self, !self.progress.isRunning else { return .cancelled }
            await self.performPhotoEnrichment()
            if self.progress.phase == .enrichment {
                self.progress.isRunning = false
            }
            return Task.isCancelled ? .cancelled : .completed
        })
    }

    private func enqueueGeocoding(
        workflowID: UUID,
        dependencies: Set<IndexingJobKind> = []
    ) {
        guard !jobQueue.contains(.geocodeMedia) else { return }
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .geocodeMedia,
            priority: .background,
            dependencies: dependencies
        ) { [weak self] in
            guard let self else { return .cancelled }
            await self.geocodeIndexedMedia()
            return Task.isCancelled ? .cancelled : .completed
        })
    }

    private func enqueueAndWaitForOrphanCleanup(allMedia: PHFetchResult<PHAsset>) async {
        let workflowID = UUID()
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .cleanOrphans,
            priority: .maintenance
        ) { [weak self] in
            guard let self else { return .cancelled }
            await self.cleanOrphanedEmbeddings(allMedia: allMedia)
            return Task.isCancelled ? .cancelled : .completed
        })
        await jobQueue.waitUntilIdle()
    }

    private func enqueueLightweightOrphanCleanup(
        orphanedPhotoIDs: Set<String>,
        database: DatabaseProtocol,
        searchEngine: SearchEngine
    ) {
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .cleanOrphans,
            priority: .maintenance
        ) { [weak self] in
            guard let self else { return .cancelled }
            do {
                try await Task.detached(priority: .utility) {
                    try database.deleteOrphanedPhotos(localIdentifiers: orphanedPhotoIDs)
                    try searchEngine.loadIndex()
                }.value
                self.indexVersion += 1
                return Task.isCancelled ? .cancelled : .completed
            } catch {
                logger.error("Error cleaning orphaned photos: \(error.localizedDescription)")
                return .cancelled
            }
        })
    }

    private func cancelEnrichmentWork() {
        jobQueue.cancel(.enrichPhotos)
        if progress.phase == .enrichment {
            progress.isRunning = false
        }
    }

    /// Checks whether interrupted indexing should resume after launch.
    private func autoResumeDecision(totalInLibrary providedTotal: Int? = nil) async -> AutoResumeDecision {
        let totalInLibrary = providedTotal ?? PhotoLibrary.fetchAllMedia().count

        let counts: IndexedMediaCounts
        do {
            let db = database
            counts = try await Task.detached(priority: .utility) {
                try db.indexedMediaCounts()
            }.value
        } catch {
            logger.error("Failed to check index completeness: \(error.localizedDescription)")
            return .noIndex
        }

        let totalIndexed = counts.total
        guard totalIndexed > 0 else { return .noIndex }
        let unindexedCount = totalInLibrary - totalIndexed

        if unindexedCount <= 0 {
            return .complete
        }

        #if DEBUG
        logger.info("[IndexingService] Incomplete index detected: \(totalIndexed)/\(totalInLibrary) indexed, \(unindexedCount) remaining. Auto-resuming.")
        #endif

        return .resume
    }

    // MARK: - Photo Enrichment

    private func performPhotoEnrichment() async {
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
                let batchUpdates = updates
                try await Task.detached(priority: .utility) {
                    try db.updatePhotoEnrichment(batchUpdates)
                }.value
                completed += batchUpdates.count
                progress.completed = min(completed, progress.total)
            } catch {
                logger.error("Failed to update photo enrichment batch: \(error.localizedDescription)")
                return
            }
        }

        if completed > 0, !Task.isCancelled {
            _ = await reloadSearchIndex()
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
            Task { @MainActor [weak self] in
                self?.handleBackgroundTaskExpiration()
            }
        }
    }

    func handleBackgroundTaskExpiration() {
        #if DEBUG
        logger.warning("[IndexingService] Background time expired; cancelling active indexing workflow")
        #endif
        stopIndexing()
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

}
