import Foundation
import Photos
import UIKit
import os
import Combine

private let hitFreeLimitKey = "indexing.hitFreeLimit"

@MainActor
class IndexingService: ObservableObject {
    @Published var progress = IndexingProgress(total: 0, completed: 0, isRunning: false) {
        didSet {
            guard oldValue.isRunning, !progress.isRunning else { return }
            if photoChangeScanState.startPendingScanIfPossible(isIndexing: false) {
                startPhotoChangeScan()
            }
        }
    }
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
    @Published private(set) var isThermallyPaused = false
    @Published private(set) var folderIndexingError: String?
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
    private let geocodingWorker: GeocodingWorker
    private let jobQueue = IndexingJobQueue()
    private var librarySession: PhotoLibraryIndexingWorker.Session?
    private var isObservingPhotoChanges = false
    private var photoChangeCheckTask: Task<Void, Never>?
    private var photoChangeScanState = PhotoChangeScanState()
    private var pendingPhotoLibraryChange = PhotoLibraryChangeEvent()
    private var proRevocationTask: Task<Void, Never>?
    private var activeProReconciliationID: UUID?
    private var storageMutationTask: Task<Void, Error>?
    private var activeStorageMutationID: UUID?
    private var proEntitlementObservation: AnyCancellable?
    private var scheduledSavedFolderSourceIDs: Set<String> = []
    private var thermalSafetyState = ThermalIndexingState()
    private var thermalObserver: NotificationObservation?
    private struct ThermalResumeIntent {
        let id: UUID
        let action: () -> Void
    }
    private var thermalResumeIntent: ThermalResumeIntent?

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
            reportError: { [weak self] in self?.folderIndexingError = $0 },
            reloadSearchIndex: { [weak self] in await self?.reloadSearchIndex() == true }
        )
    )

    init(imageEncoder: ImageEncoder, searchEngine: SearchEngine, database: DatabaseProtocol = AppDatabase.shared) {
        self.imageEncoder = imageEncoder
        self.searchEngine = searchEngine
        self.database = database
        self.geocodingWorker = GeocodingWorker(
            database: database,
            reverseGeocoder: ReverseGeocoder()
        )
        let token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleThermalStateChange(ProcessInfo.processInfo.thermalState)
            }
        }
        thermalObserver = NotificationObservation(token: token)
        proEntitlementObservation = ProManager.shared.$isPro
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isPro in
                guard isPro else { return }
                Task { @MainActor [weak self] in
                    await self?.resumeIndexingAfterProUnlock()
                }
            }
    }

    @discardableResult
    func checkAndLoadExistingIndex(
        scheduleAutoResume: Bool = true,
        scheduleOrphanCleanup: Bool = true,
        loadPriority: TaskPriority = .utility
    ) async -> Bool {
        #if DEBUG
        logger.info("[IndexingService] checkAndLoadExistingIndex start scheduleAutoResume=\(scheduleAutoResume), scheduleOrphanCleanup=\(scheduleOrphanCleanup), priority=\(String(describing: loadPriority))")
        #endif
        let loaded = await loadExistingIndexIfAvailable(loadPriority: loadPriority)
        guard !Task.isCancelled else { return false }
        startObservingPhotoChanges()
        if scheduleAutoResume && loaded {
            enqueueLibraryIndexing(
                isAutoResume: true,
                delayAfterDependencies: IndexingConfig.postLaunchAutoResumeDelaySeconds,
                enqueueLaunchEnrichment: true
            )
        }
        if scheduleOrphanCleanup && loaded {
            enqueueOrphanCleanup(
                delayAfterDependencies: IndexingConfig.postLaunchAutoResumeDelaySeconds
            )
        }
        #if DEBUG
        logger.info("[IndexingService] checkAndLoadExistingIndex finish loaded=\(loaded), isReady=\(self.isReady), indexLoaded=\(self.searchEngine.isIndexLoaded), totalSize=\(self.searchEngine.totalSize)")
        #endif
        return loaded
    }

    @discardableResult
    func loadExistingIndexIfAvailable(loadPriority: TaskPriority = .utility) async -> Bool {
        do {
            #if DEBUG
            logger.info("[IndexingService] loadExistingIndexIfAvailable start priority=\(String(describing: loadPriority))")
            #endif
            let db = database
            let rebuildRequired = try await CancellableDetachedOperation.run(priority: loadPriority) {
                try db.indexRebuildRequired()
            }
            indexRebuildRequired = rebuildRequired
            if rebuildRequired {
                searchEngine.dropIndex()
                isReady = false
                progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
                onIndexUnavailable?()
                return false
            }

            let counts = try await CancellableDetachedOperation.run(priority: loadPriority) {
                try db.indexedMediaCounts()
            }
            let photoCount = counts.photos
            let videoCount = counts.videos
            let totalIndexed = counts.total

            if totalIndexed > 0 {
                #if DEBUG
                logger.info("[IndexingService] Found \(photoCount) indexed photos and \(videoCount) indexed videos, loading index")
                #endif

                let didLoad = try await CancellableDetachedOperation.run(priority: loadPriority) { [searchEngine] in
                    try searchEngine.loadIndex()
                    return searchEngine.isIndexLoaded
                }
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
        } catch is CancellationError {
            return false
        } catch {
            logger.error("Failed to load existing index: \(error.safeDiagnosticCode)")
        }
        isReady = false
        onIndexUnavailable?()
        return false
    }

    func startIndexing() {
        let resume: () -> Void = { [weak self] in self?.startIndexing() }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        SurpriseQueries.clearValidated()
        enqueueLibraryIndexing(resumeIntentID: intent.id)
    }

    func indexNewPhotosOnly() {
        let resume: () -> Void = { [weak self] in self?.indexNewPhotosOnly() }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        newPhotosAvailable = false
        enqueueLibraryIndexing(resumeIntentID: intent.id)
    }

    func rebuildRequiredIndex() {
        let resume: () -> Void = { [weak self] in self?.rebuildRequiredIndex() }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        guard indexRebuildRequired else {
            startIndexing()
            return
        }

        stopIndexing(preserveThermalResume: true)
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        SurpriseQueries.clearValidated()
        enqueueLibraryIndexing(rebuildRequired: true, resumeIntentID: intent.id)
    }

    func stopIndexing() {
        stopIndexing(preserveThermalResume: false)
    }

    private func stopIndexing(preserveThermalResume: Bool) {
        jobQueue.cancelAll()
        scheduledSavedFolderSourceIDs.removeAll()
        librarySession = nil
        geocodingProgress = nil
        progress.isRunning = false
        endBackgroundTask()
        if !preserveThermalResume {
            thermalResumeIntent = nil
            thermalSafetyState = ThermalIndexingState()
            isThermallyPaused = false
        }
    }

    func prioritizeUserSearch() {
        if jobQueue.contains(.validateSurpriseQueries) {
            jobQueue.cancel(.validateSurpriseQueries)
            enqueueSurpriseQueryValidation(
                workflowID: UUID(),
                delayAfterDependencies: IndexingConfig.userSearchBackgroundWorkDelaySeconds,
                replacingCancelledJob: true
            )
        }

        if jobQueue.contains(.enrichPhotos) {
            jobQueue.cancel(.enrichPhotos)
            enqueueEnrichment(
                workflowID: UUID(),
                delayAfterDependencies: IndexingConfig.userSearchBackgroundWorkDelaySeconds
            )
        }

        if jobQueue.contains(.geocodeMedia) {
            jobQueue.cancel(.geocodeMedia)
            geocodingProgress = nil
            enqueueGeocoding(
                workflowID: UUID(),
                delayAfterDependencies: IndexingConfig.userSearchBackgroundWorkDelaySeconds,
                replacingCancelledJob: true
            )
        }

        if jobQueue.contains(.cleanOrphans) {
            jobQueue.cancel(.cleanOrphans)
            enqueueOrphanCleanup(
                delayAfterDependencies: IndexingConfig.userSearchBackgroundWorkDelaySeconds,
                replacingCancelledJob: true
            )
        }
    }

    func cancelAllWorkForMemoryPressure() {
        jobQueue.cancelAll()
        scheduledSavedFolderSourceIDs.removeAll()
        storageMutationTask?.cancel()
        stopObservingPhotoChanges()
        proRevocationTask?.cancel()
        proRevocationTask = nil
        activeProReconciliationID = nil
        photoChangeCheckTask?.cancel()
        photoChangeScanState.cancel()
        pendingPhotoLibraryChange = PhotoLibraryChangeEvent()
        librarySession = nil
        geocodingProgress = nil
        progress.isRunning = false
        thermalResumeIntent = nil
        thermalSafetyState = ThermalIndexingState()
        isThermallyPaused = false
        stopObservingThermalChanges()
        isReady = false
        endBackgroundTask()
        searchEngine.suspendForMemoryPressure()
        onIndexUnavailable?()
    }

    func indexFolder(url: URL, name: String) {
        guard ProManager.shared.isPro else {
            logger.error("Folder indexing requires an active Pro entitlement")
            return
        }
        let resume: () -> Void = { [weak self] in self?.indexFolder(url: url, name: name) }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        let workflowID = UUID()
        let shouldResumeGeocoding = jobQueue.contains(.geocodeMedia)
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .indexFolder,
            priority: .userInitiated
        ) { [weak self] in
            guard let self else { return .cancelled }
            defer {
                self.clearThermalResumeIntent(ifOwnedBy: intent.id)
                self.progress.isRunning = false
            }
            return await ProFolderIndexingOperation.run(
                isEntitled: { ProManager.shared.isPro }
            ) {
                self.beginBackgroundTask()
                defer {
                    self.endBackgroundTask()
                }
                let outcome = await self.folderWorker.index(url: url, name: name)
                guard outcome.didComplete, !Task.isCancelled else { return outcome }
                self.enqueueEnrichment(workflowID: workflowID)
                if shouldResumeGeocoding {
                    self.enqueueGeocoding(workflowID: workflowID)
                }
                return .completed
            }
        })
    }

    func reindexFolderSource(_ source: PhotoSource) {
        guard ProManager.shared.isPro,
              source.type == PhotoSourceType.folder.rawValue else {
            logger.error("Folder refresh requires an active Pro entitlement and folder source")
            return
        }
        let resume: () -> Void = { [weak self] in self?.reindexFolderSource(source) }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        scheduledSavedFolderSourceIDs.insert(source.id)
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexFolder,
            priority: .userInitiated
        ) { [weak self] in
            guard let self else { return .cancelled }
            defer {
                self.scheduledSavedFolderSourceIDs.remove(source.id)
                self.clearThermalResumeIntent(ifOwnedBy: intent.id)
                self.progress.isRunning = false
            }
            return await ProFolderIndexingOperation.run(
                isEntitled: { ProManager.shared.isPro }
            ) {
                self.beginBackgroundTask()
                defer { self.endBackgroundTask() }
                return await self.folderWorker.reindex(source: source)
            }
        })
    }

    func clearFolderIndexingError() {
        folderIndexingError = nil
    }

    func deleteFolderSource(id: String) async throws {
        try await runTrackedStorageMutation { [weak self] in
            guard let self else { throw CancellationError() }
            self.stopIndexing()
            let db = self.database
            try await IndexingStorageMutation.run(
                waitForIdle: { await self.jobQueue.waitUntilIdle() },
                mutation: { try db.deleteSource(id) },
                completion: {
                    // Preserve memory-pressure suspension while invalidating
                    // the deleted source's old search snapshot.
                    self.searchEngine.dropIndex()
                    self.isReady = false
                    self.onIndexUnavailable?()
                    guard !self.searchEngine.isMemoryPressureSuspended else { return }
                    _ = await self.reloadSearchIndex()
                }
            )
        }
    }

    func rebuildLibraryIndex() async throws {
        try await runTrackedStorageMutation { [weak self] in
            guard let self else { throw CancellationError() }
            self.stopIndexing()
            let db = self.database
            try await IndexingStorageMutation.run(
                waitForIdle: { await self.jobQueue.waitUntilIdle() },
                mutation: { try db.resetIndexedMedia() },
                completion: {
                    self.indexRebuildRequired = true
                    self.searchEngine.dropIndex()
                    self.isReady = false
                    self.onIndexUnavailable?()
                    guard !self.searchEngine.isMemoryPressureSuspended else {
                        throw CancellationError()
                    }
                    self.startIndexing()
                }
            )
        }
    }

    private func runTrackedStorageMutation(
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        storageMutationTask?.cancel()
        if let previous = storageMutationTask {
            _ = try? await previous.value
        }

        let operationID = UUID()
        let task = Task { @MainActor in
            try await operation()
        }
        storageMutationTask = task
        activeStorageMutationID = operationID
        defer {
            if activeStorageMutationID == operationID {
                storageMutationTask = nil
                activeStorageMutationID = nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func reconcileFreeTier() async {
        guard let reconciliationPermit = EntitlementReconciliationContext.permit,
              reconciliationPermit.isValid else { return }
        proRevocationTask?.cancel()
        let reconciliationID = UUID()
        activeProReconciliationID = reconciliationID
        let task = Task { [weak self] in
            guard let self else { return }
            jobQueue.cancelAll()
            scheduledSavedFolderSourceIDs.removeAll()
            await jobQueue.waitUntilIdle()
            let db = database
            do {
                try await ProRevocationOperation.run(
                    trim: {
                        try reconciliationPermit.withValidLease {
                            try db.reconcileFreeTier(FreeTier.maxIndexedMedia)
                        }
                    },
                    reload: { [weak self] result in
                        guard let self, !Task.isCancelled else { return }
                        self.searchEngine.suspendForMemoryPressure()
                        self.searchEngine.resumeAfterMemoryPressure()
                        self.isReady = false
                        self.onIndexUnavailable?()
                        _ = await self.reloadSearchIndex()
                        self.hitFreeLimit = FreeTierStatePolicy.hitIndexLimit(
                            previouslyHit: self.hitFreeLimit,
                            reconciliation: result
                        )
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                logger.error("Failed to apply the free-tier limit after Pro revocation: \(error.safeDiagnosticCode)")
            }
        }
        proRevocationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if activeProReconciliationID == reconciliationID {
            proRevocationTask = nil
            activeProReconciliationID = nil
        }
    }

    // MARK: - Private

    private func markRunningIfIdle() -> Bool {
        guard !progress.isRunning else { return false }
        progress.isRunning = true
        return true
    }

    private func canStartIndexing(resumeWhenCool: ThermalResumeIntent? = nil) -> Bool {
        if ThermalSafetyPolicy.shouldPause(for: ProcessInfo.processInfo.thermalState) {
            if let resumeWhenCool {
                thermalResumeIntent = resumeWhenCool
            }
            thermalSafetyState = ThermalIndexingState(isPaused: true, resumeWhenCool: true)
            isThermallyPaused = true
            return false
        }
        thermalSafetyState = ThermalIndexingState()
        isThermallyPaused = false
        guard database.allowsIndexingWrites else {
            logger.error("Indexing is unavailable while persistent storage is unavailable")
            progress.isRunning = false
            isReady = false
            onIndexUnavailable?()
            return false
        }
        return true
    }

    nonisolated static func shouldClearThermalResumeIntent(
        currentIntentID: UUID?,
        completingIntentID: UUID?,
        isThermallyPaused: Bool
    ) -> Bool {
        !isThermallyPaused
            && currentIntentID != nil
            && currentIntentID == completingIntentID
    }

    private func clearThermalResumeIntent(ifOwnedBy intentID: UUID?) {
        guard Self.shouldClearThermalResumeIntent(
            currentIntentID: thermalResumeIntent?.id,
            completingIntentID: intentID,
            isThermallyPaused: isThermallyPaused
        ) else { return }
        thermalResumeIntent = nil
    }

    private func handleThermalStateChange(_ thermalState: ProcessInfo.ThermalState) {
        let transition = ThermalSafetyPolicy.transition(
            from: thermalSafetyState,
            thermalState: thermalState,
            hasActiveWork: !jobQueue.isIdle || progress.isRunning
        )
        thermalSafetyState = transition.state
        isThermallyPaused = transition.state.isPaused

        switch transition.effect {
        case .none:
            break
        case .cancelWork:
            if thermalResumeIntent == nil {
                thermalResumeIntent = ThermalResumeIntent(
                    id: UUID(),
                    action: { [weak self] in self?.startIndexing() }
                )
            }
            stopIndexing(preserveThermalResume: true)
        case .restartWork:
            let resume = thermalResumeIntent?.action ?? { [weak self] in self?.startIndexing() }
            thermalResumeIntent = nil
            resume()
        }
    }

    private func stopObservingThermalChanges() {
        guard let thermalObserver else { return }
        thermalObserver.cancel()
        self.thermalObserver = nil
    }

    private func startObservingPhotoChanges() {
        guard !isObservingPhotoChanges else { return }
        changeObserver.onPhotoLibraryChange = { [weak self] event in
            Task { @MainActor in self?.checkForPhotoLibraryChange(event) }
        }
        changeObserver.startObserving()
        isObservingPhotoChanges = true
    }

    private func stopObservingPhotoChanges() {
        guard isObservingPhotoChanges else { return }
        changeObserver.stopObserving()
        isObservingPhotoChanges = false
    }

    private func checkForPhotoLibraryChange(_ event: PhotoLibraryChangeEvent) {
        guard event.hasWork else { return }
        pendingPhotoLibraryChange.merge(event)
        guard photoChangeScanState.requestScan(isIndexing: progress.isRunning) else { return }
        startPhotoChangeScan()
    }

    private func startPhotoChangeScan() {
        guard photoChangeCheckTask == nil, pendingPhotoLibraryChange.hasWork else { return }
        let db = database
        let event = pendingPhotoLibraryChange
        pendingPhotoLibraryChange = PhotoLibraryChangeEvent()
        photoChangeCheckTask = Task { [weak self] in
            guard let self else { return }
            defer {
                photoChangeCheckTask = nil
                if photoChangeScanState.finishScan(isIndexing: progress.isRunning) {
                    startPhotoChangeScan()
                }
            }
            let scanTask = Task.detached(priority: .utility) {
                try PhotoLibraryChangeReconciler.reconcile(
                    event,
                    database: db,
                    authorizationStatus: PHPhotoLibrary.authorizationStatus(for: .readWrite)
                )
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }
                guard !Task.isCancelled else { return }
                if result.hasNewMedia {
                    newPhotosAvailable = true
                }
                if !result.orphanedPhotoIDs.isEmpty || !result.orphanedVideoIDs.isEmpty {
                    enqueueLightweightOrphanCleanup(
                        orphanedPhotoIDs: result.orphanedPhotoIDs,
                        orphanedVideoIDs: result.orphanedVideoIDs,
                        database: db
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Error checking for photo changes: \(error.safeDiagnosticCode)")
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
            let loadTask = Task.detached(priority: .userInitiated) { [searchEngine] in
                try searchEngine.loadIndex()
                return searchEngine.isIndexLoaded
            }
            let didLoad = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
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
            logger.error("Failed to reload search index: \(error.safeDiagnosticCode)")
            isReady = searchEngine.isIndexLoaded
            if isReady {
                onIndexReady?()
            } else {
                onIndexUnavailable?()
            }
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
        enqueueLaunchEnrichment: Bool = false,
        resumeIntentID: UUID? = nil
    ) {
        guard canStartIndexing() else { return }
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
                    try await CancellableDetachedOperation.run {
                        try db.resetIndexedMedia()
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    self.progress.isRunning = false
                    self.clearThermalResumeIntent(ifOwnedBy: resumeIntentID)
                    return .cancelled
                } catch {
                    logger.error("Failed to clear incompatible index before rebuild: \(error.safeDiagnosticCode)")
                    self.progress.isRunning = false
                    self.clearThermalResumeIntent(ifOwnedBy: resumeIntentID)
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
                self.clearThermalResumeIntent(ifOwnedBy: resumeIntentID)
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
            defer {
                self.clearThermalResumeIntent(ifOwnedBy: resumeIntentID)
            }
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
                    try await CancellableDetachedOperation.run {
                        try db.clearIndexRebuildRequired()
                    }
                    self.indexRebuildRequired = false
                } catch is CancellationError {
                    self.progress.isRunning = false
                    return .cancelled
                } catch {
                    logger.error("Failed to complete empty index rebuild: \(error.safeDiagnosticCode)")
                }
            }
            self.enqueuePostIndexingJobs(workflowID: workflowID)
            await self.enqueueSavedFolderReindexingIfNeeded()
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
        enqueueSurpriseQueryValidation(
            workflowID: workflowID,
            dependencies: [.indexVideos],
            delayAfterDependencies: IndexingConfig.surpriseValidationDelaySeconds
        )
        enqueueGeocoding(workflowID: workflowID, dependencies: [.indexVideos])
    }

    private func enqueueSurpriseQueryValidation(
        workflowID: UUID,
        dependencies: Set<IndexingJobKind> = [],
        delayAfterDependencies: TimeInterval = 0,
        replacingCancelledJob: Bool = false
    ) {
        guard replacingCancelledJob || !jobQueue.contains(.validateSurpriseQueries) else { return }
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .validateSurpriseQueries,
            priority: .maintenance,
            dependencies: dependencies,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self, self.searchEngine.isIndexLoaded else { return .cancelled }
            let startedAt = CFAbsoluteTimeGetCurrent()
            defer {
                PerformanceMetrics.shared.record(
                    PerformancePhase.surpriseValidation,
                    durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
                )
            }
            await SurpriseQueries.validateQueries(using: self.searchEngine)
            return Task.isCancelled ? .cancelled : .completed
        })
    }

    private func enqueueSavedFolderReindexingIfNeeded() async {
        guard ProManager.shared.isPro,
              database.allowsIndexingWrites,
              !searchEngine.isMemoryPressureSuspended,
              !ThermalSafetyPolicy.shouldPause(for: ProcessInfo.processInfo.thermalState),
              !Task.isCancelled else { return }

        let sources: [PhotoSource]
        do {
            let db = database
            sources = try await CancellableDetachedOperation.run {
                try db.listSources()
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Failed to load saved folders for re-indexing: \(error.safeDiagnosticCode)")
            return
        }

        let candidates = SavedFolderReindexPolicy.sourcesToReindex(
            from: sources,
            isPro: ProManager.shared.isPro
        ).filter { !scheduledSavedFolderSourceIDs.contains($0.id) }

        guard !candidates.isEmpty else { return }
        let candidateIDs = Set(candidates.map(\.id))
        scheduledSavedFolderSourceIDs.formUnion(candidateIDs)
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .indexFolder,
            priority: .userInitiated
        ) { [weak self] in
            guard let self else { return .cancelled }
            defer { self.scheduledSavedFolderSourceIDs.subtract(candidateIDs) }
            return await ProFolderIndexingOperation.run(
                isEntitled: { ProManager.shared.isPro }
            ) {
                self.beginBackgroundTask()
                self.progress.isRunning = true
                defer {
                    self.endBackgroundTask()
                    self.progress.isRunning = false
                }
                var didCompleteSource = false
                for source in candidates {
                    guard ProManager.shared.isPro else { return .cancelled }
                    if Task.isCancelled {
                        if didCompleteSource {
                            _ = await self.reloadSearchIndexInFreshTask()
                        }
                        return .cancelled
                    }
                    let outcome = await self.folderWorker.reindex(
                        source: source,
                        reloadSearchIndex: false
                    )
                    if outcome.didComplete {
                        didCompleteSource = true
                        continue
                    }
                    if outcome == .cancelled || Task.isCancelled {
                        if didCompleteSource {
                            _ = await self.reloadSearchIndexInFreshTask()
                        }
                        return .cancelled
                    } else {
                        return await self.reloadSearchIndex() ? outcome : .failed
                    }
                }
                if Task.isCancelled {
                    if didCompleteSource {
                        _ = await self.reloadSearchIndexInFreshTask()
                    }
                    return .cancelled
                }
                return await self.reloadSearchIndex() ? .completed : .failed
            }
        })
    }

    private func reloadSearchIndexInFreshTask() async -> Bool {
        let task = Task { @MainActor [weak self] in
            await self?.reloadSearchIndex() == true
        }
        return await task.value
    }

    private func resumeIndexingAfterProUnlock() async {
        let hasLibraryIndexingWork = jobQueue.contains(.indexPhotos)
            || jobQueue.contains(.indexVideos)
        if ProUnlockIndexingRecoveryPolicy.shouldStartLibraryIndexing(
            isMemoryPressureSuspended: searchEngine.isMemoryPressureSuspended,
            hasLibraryIndexingWork: hasLibraryIndexingWork
        ) {
            startIndexing()
        }
        await enqueueSavedFolderReindexingIfNeeded()
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
        dependencies: Set<IndexingJobKind> = [],
        delayAfterDependencies: TimeInterval = 0,
        replacingCancelledJob: Bool = false
    ) {
        guard replacingCancelledJob || !jobQueue.contains(.geocodeMedia) else { return }
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .geocodeMedia,
            priority: .background,
            dependencies: dependencies,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self else { return .cancelled }
            await self.geocodeIndexedMedia()
            return Task.isCancelled ? .cancelled : .completed
        })
    }

    private func enqueueOrphanCleanup(
        delayAfterDependencies: TimeInterval = 0,
        replacingCancelledJob: Bool = false
    ) {
        guard replacingCancelledJob || !jobQueue.contains(.cleanOrphans) else { return }
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .cleanOrphans,
            priority: .maintenance,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self else { return .cancelled }
            let removedOrphans = await self.cleanOrphanedEmbeddings()
            guard !Task.isCancelled else { return .cancelled }
            guard removedOrphans else { return .completed }
            return await self.reloadSearchIndex() ? .completed : .cancelled
        })
    }

    private func enqueueLightweightOrphanCleanup(
        orphanedPhotoIDs: Set<String>,
        orphanedVideoIDs: Set<String>,
        database: DatabaseProtocol
    ) {
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .cleanOrphans,
            priority: .maintenance
        ) { [weak self] in
            guard let self else { return .cancelled }
            do {
                try await CancellableDetachedOperation.run {
                    if !orphanedPhotoIDs.isEmpty {
                        guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                            PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        ) else { throw CancellationError() }
                        try database.deleteOrphanedPhotos(localIdentifiers: orphanedPhotoIDs)
                    }
                    try Task.checkCancellation()
                    if !orphanedVideoIDs.isEmpty {
                        guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                            PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        ) else { throw CancellationError() }
                        try database.deleteOrphanedVideos(localIdentifiers: orphanedVideoIDs)
                    }
                }
                guard !Task.isCancelled else { return .cancelled }
                return await self.reloadSearchIndex() ? .completed : .cancelled
            } catch {
                logger.error("Error cleaning orphaned photos: \(error.safeDiagnosticCode)")
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
        let totalInLibrary: Int
        if let providedTotal {
            totalInLibrary = providedTotal
        } else {
            do {
                totalInLibrary = try await CancellableDetachedOperation.run(priority: .utility) {
                    PhotoLibrary.fetchAllMedia().count
                }
            } catch is CancellationError {
                return .noIndex
            } catch {
                logger.error("Failed to read photo library size: \(error.safeDiagnosticCode)")
                return .noIndex
            }
        }

        let counts: IndexedMediaCounts
        do {
            let db = database
            counts = try await CancellableDetachedOperation.run {
                try db.photoLibraryIndexedMediaCounts()
            }
        } catch is CancellationError {
            return .noIndex
        } catch {
            logger.error("Failed to check index completeness: \(error.safeDiagnosticCode)")
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
            remaining = try await CancellableDetachedOperation.run {
                try db.photosNeedingEnrichmentCount()
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Failed to count photos needing enrichment: \(error.safeDiagnosticCode)")
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
                candidates = try await CancellableDetachedOperation.run {
                    try db.photosNeedingEnrichment(limit: IndexingConfig.enrichmentBatchSize)
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("Failed to fetch photo enrichment batch: \(error.safeDiagnosticCode)")
                return
            }
            guard !candidates.isEmpty else { break }

            var updates: [PhotoEnrichmentUpdate] = []
            updates.reserveCapacity(candidates.count)
            for candidate in candidates {
                if Task.isCancelled { return }
                guard let update = await enrichPhoto(candidate), !Task.isCancelled else {
                    return
                }
                updates.append(update)
                await Task.yield()
            }

            guard !Task.isCancelled else { return }

            do {
                let db = database
                let batchUpdates = updates
                try await CancellableDetachedOperation.run {
                    try db.updatePhotoEnrichment(batchUpdates)
                }
                completed += batchUpdates.count
                progress.completed = min(completed, progress.total)
            } catch is CancellationError {
                return
            } catch {
                logger.error("Failed to update photo enrichment batch: \(error.safeDiagnosticCode)")
                return
            }
        }

        if completed > 0, !Task.isCancelled {
            _ = await reloadSearchIndex()
        }
    }

    private func enrichPhoto(_ candidate: PhotoEnrichmentCandidate) async -> PhotoEnrichmentUpdate? {
        let image = await loadImageForEnrichment(candidate, targetSize: CGSize(width: 224, height: 224))
        guard !Task.isCancelled else { return nil }
        guard let image else {
            return PhotoEnrichmentUpdate(
                localIdentifier: candidate.localIdentifier,
                ocrText: nil,
                sharpnessScore: nil,
                sceneLabels: nil,
                outcome: .loadFailed(at: Date())
            )
        }

        var ocrText: String?
        let quickOcr = await PhotoEnrichmentTask.run {
            await OCRService.extractTextFast(from: image)
        }
        guard !Task.isCancelled else { return nil }

        if OCRService.isLikelyScreenshot(width: candidate.pixelWidth, height: candidate.pixelHeight) {
            let ocrWidth = min(candidate.pixelWidth, 2048)
            let ocrHeight = min(candidate.pixelHeight, 2048)
            let fullImage = await loadImageForEnrichment(
                candidate,
                targetSize: CGSize(width: CGFloat(ocrWidth), height: CGFloat(ocrHeight)),
                highQuality: true
            )
            guard !Task.isCancelled else { return nil }
            if let fullImage {
                ocrText = await PhotoEnrichmentTask.run {
                    await OCRService.extractText(from: fullImage)
                } ?? nil
                guard !Task.isCancelled else { return nil }
            }
        }

        if ocrText == nil || (ocrText?.isEmpty ?? true) {
            ocrText = quickOcr ?? nil
        }
        if let text = ocrText, text.count < 3 {
            ocrText = nil
        }

        let sharpness = await PhotoEnrichmentTask.run {
            BlurDetector.sharpnessScore(for: image)
        }
        guard let sharpness, !Task.isCancelled else { return nil }

        let sceneLabels = await PhotoEnrichmentTask.run {
            await SceneClassifier.classify(image: image)
        }
        guard let sceneLabels, !Task.isCancelled else { return nil }
        let encodedSceneLabels = SceneClassifier.labelsToString(sceneLabels)

        return PhotoEnrichmentUpdate(
            localIdentifier: candidate.localIdentifier,
            ocrText: ocrText,
            sharpnessScore: sharpness,
            sceneLabels: encodedSceneLabels,
            isDocumentImage: MemoryContentPolicy.isDocumentImage(
                ocrText: ocrText,
                sceneLabels: encodedSceneLabels
            )
        )
    }

    private func loadImageForEnrichment(
        _ candidate: PhotoEnrichmentCandidate,
        targetSize: CGSize,
        highQuality: Bool = false
    ) async -> UIImage? {
        if let filePath = candidate.filePath {
            return await FolderImageLoadOperation.run {
                FolderScanner.loadImageFromBookmarkedSource(
                    filePath: filePath,
                    sourceId: candidate.sourceId,
                    targetSize: targetSize
                )
            }
        }
        guard let asset = await PhotoLibrary.resolveAsset(by: candidate.localIdentifier) else {
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

    private func cleanOrphanedEmbeddings() async -> Bool {
        do {
            guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                PHPhotoLibrary.authorizationStatus(for: .readWrite)
            ) else {
                #if DEBUG
                logger.info("[IndexingService] Skipping orphan cleanup without full Photos access")
                #endif
                return false
            }
            let db = database
            let scanTask = Task.detached(priority: .utility) {
                let photoLibraryIndexedCount = try db.photoLibraryIndexedMediaCounts().total
                var orphanedPhotos: Set<String> = []
                var orphanedVideos: Set<String> = []
                var cursor: SearchMediaPageCursor?
                repeat {
                    try Task.checkCancellation()
                    let page = try db.loadIndexedMediaIdentifierPage(
                        after: cursor,
                        limit: SearchIndexLimits.databasePageMediaItems
                    )
                    let pageIdentifiers = page.photos + page.videos
                    guard !pageIdentifiers.isEmpty else { break }
                    let existingAssets = PHAsset.fetchAssets(
                        withLocalIdentifiers: pageIdentifiers,
                        options: nil
                    )
                    var existing: Set<String> = []
                    existing.reserveCapacity(existingAssets.count)
                    existingAssets.enumerateObjects { asset, _, _ in
                        existing.insert(asset.localIdentifier)
                    }
                    orphanedPhotos.formUnion(page.photos.filter { !existing.contains($0) })
                    orphanedVideos.formUnion(page.videos.filter { !existing.contains($0) })
                    guard !OrphanCleanupSafetyPolicy.exceedsSafetyThreshold(
                        candidateRemovalCount: orphanedPhotos.count + orphanedVideos.count,
                        photoLibraryIndexedCount: photoLibraryIndexedCount
                    ) else {
                        return (Set<String>(), Set<String>(), true)
                    }
                    cursor = page.nextCursor
                } while cursor != nil
                return (orphanedPhotos, orphanedVideos, false)
            }
            let (orphanedPhotos, orphanedVideos, exceededSafetyThreshold) = try await withTaskCancellationHandler {
                try await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            try Task.checkCancellation()
            if exceededSafetyThreshold {
                logger.warning("Orphan cleanup skipped: candidate removals exceed the 20% safety threshold")
                return false
            }

            let totalOrphans = orphanedPhotos.count + orphanedVideos.count
            guard totalOrphans > 0 else { return false }

            // Safety: never auto-delete when more than 20% appear orphaned.
            // A large mismatch can reflect a transient PhotoKit visibility issue.
            let photoLibraryIndexedCount = try await CancellableDetachedOperation.run {
                try db.photoLibraryIndexedMediaCounts().total
            }
            let orphanRatio = OrphanCleanupSafetyPolicy.orphanRatio(
                candidateRemovalCount: totalOrphans,
                photoLibraryIndexedCount: photoLibraryIndexedCount
            )
            if orphanRatio > IndexingConfig.maxOrphanRatio {
                logger.warning("Orphan cleanup skipped: \(totalOrphans)/\(photoLibraryIndexedCount) (\(Int(orphanRatio * 100))%) exceeds 20% threshold")
                return false
            }

            // Delete orphaned photos
            if !orphanedPhotos.isEmpty {
                try Task.checkCancellation()
                let photoIDsToDelete = orphanedPhotos
                let photoDeleteCount = photoIDsToDelete.count
                try await CancellableDetachedOperation.run {
                    guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                        PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    ) else { throw CancellationError() }
                    try db.deleteOrphanedPhotos(localIdentifiers: photoIDsToDelete)
                }
                try Task.checkCancellation()
                #if DEBUG
                logger.info("Cleaned \(photoDeleteCount) orphaned photo embeddings")
                #endif
            }

            // Delete orphaned videos
            if !orphanedVideos.isEmpty {
                try Task.checkCancellation()
                let videoIDsToDelete = orphanedVideos
                let videoDeleteCount = videoIDsToDelete.count
                try await CancellableDetachedOperation.run {
                    guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                        PHPhotoLibrary.authorizationStatus(for: .readWrite)
                    ) else { throw CancellationError() }
                    try db.deleteOrphanedVideos(localIdentifiers: videoIDsToDelete)
                }
                try Task.checkCancellation()
                #if DEBUG
                logger.info("Cleaned \(videoDeleteCount) orphaned video embeddings")
                #endif
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.error("Orphan cleanup failed: \(error.safeDiagnosticCode)")
            return false
        }
    }

    // MARK: - Background Location Geocoding

    /// Reverse-geocodes indexed photos and videos that have GPS but no location strings yet.
    /// Runs in the background after indexing completes without blocking search.
    private func geocodeIndexedMedia() async {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            PerformanceMetrics.shared.record(
                PerformancePhase.postIndexGeocoding,
                durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
            )
        }
        let result = await geocodingWorker.run { [weak self] progress in
            self?.geocodingProgress = progress.map {
                (completed: $0.completed, total: $0.total)
            }
        }
        if result.wasCancelled {
            geocodingProgress = nil
            return
        }
        if result.changedLocations {
            _ = await reloadSearchIndex()
        }
        geocodingProgress = nil
    }

}
