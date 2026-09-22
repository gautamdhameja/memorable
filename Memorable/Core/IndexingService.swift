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
            if isInitialIndexingExperiencePending {
                BackgroundIndexingController.shared.update(progress: progress)
            }
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
    @Published private(set) var validatedSearchSuggestions: [String] = []
    @Published private(set) var indexRebuildRequired = false
    @Published private(set) var isDeletingDuplicatePhoto = false
    @Published private(set) var isInitialIndexingExperiencePending: Bool
    @Published private(set) var isInitialLibraryIndexingActive = false
    @Published private(set) var backgroundExecutionState: IndexingBackgroundExecutionState = .foreground
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
    @Published private(set) var libraryIndexingError: String?
    @Published private(set) var indexLoadError: String?
    // Deferred reverse-geocoding state. Nil only when all eligible media is
    // complete or location work was intentionally cancelled.
    @Published private(set) var geocodingProgress: GeocodingProgressState? {
        didSet {
            #if DEBUG
            let oldText = oldValue.map { "\($0.completed)/\($0.total):\($0.phase)" } ?? "nil"
            let newText = geocodingProgress.map { "\($0.completed)/\($0.total):\($0.phase)" } ?? "nil"
            if oldText != newText {
                logger.info("[IndexingService] geocodingProgress changed \(oldText) -> \(newText)")
            }
            #endif
        }
    }

    private let imageEncoder: ImageEncoder
    let searchEngine: SearchEngine
    private let database: DatabaseProtocol
    private let initialIndexingDefaults: UserDefaults
    private let surpriseQueryCacheLoader: @Sendable () -> SurpriseQueryCache.State
    private let searchIndexContentRevisionLoader: @Sendable () throws -> SearchIndexContentRevision
    private let geocodingRetryDelaySeconds: @Sendable (Int) -> TimeInterval
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
    private var pendingPhotoRefreshIDs: Set<String> = []
    private var pendingVideoRefreshIDs: Set<String> = []
    private var hasInvalidatedMediaReplacements = false
    private var proRevocationTask: Task<Void, Never>?
    private var activeProReconciliationID: UUID?
    private var storageMutationTask: Task<Void, Error>?
    private var activeStorageMutationID: UUID?
    private var duplicateDeletionTail: Task<Void, Never>?
    private var duplicateDeletionTailID: UUID?
    private var geocodingProgressRefreshTask: Task<Void, Never>?
    private var geocodingProgressGeneration = 0
    private var geocodingRetryTask: Task<Void, Never>?
    private var geocodingRetryAttempt = 0
    private var isApplicationActive = false
    private(set) var isUserSearchActive = false
    private let primaryUserSearchID = UUID()
    private var activeUserSearchIDs = Set<UUID>()
    private var proEntitlementObservation: AnyCancellable?
    private var scheduledSavedFolderSourceIDs: Set<String> = []
    private var thermalSafetyState = ThermalIndexingState()
    @Published private var hasKnownExistingIndex = false
    private var hasDeferredSearchIndexReload = false
    private var deferredPostIndexingWorkflowID: UUID?
    private var hasCompletedInitialIndexCheck = false
    private var allowsLifecycleAutoResume = false
    private var hasCompletedInitialIndexingExperience: Bool
    private var thermalObserver: NotificationObservation?
    private struct ThermalResumeIntent {
        let id: UUID
        let action: () -> Void
    }
    private var thermalResumeIntent: ThermalResumeIntent?

    var onIndexReady: (() -> Void)?
    var onIndexUnavailable: (() -> Void)?
    var onIndexResetStarted: (() async -> Void)?
    var onIndexResetFinished: ((Bool) -> Void)?

    var canShowValidatedSearchSuggestions: Bool {
        SearchSuggestionVisibilityPolicy.shouldShow(
            indexingProgress: progress,
            isReady: isReady,
            hasValidatedSuggestions: !validatedSearchSuggestions.isEmpty
        )
    }

    var shouldShowInitialIndexingExperience: Bool {
        InitialIndexingExperiencePolicy.shouldShow(
            isInitialLibraryWorkflowActive: isInitialLibraryIndexingActive
        )
    }

    /// A temporarily unavailable resident snapshot does not make an existing
    /// library a first-time setup. The search controls still require readiness.
    var shouldKeepSearchHomeVisible: Bool {
        IndexingHomePresentationPolicy.showsNormalHome(
            hasKnownExistingIndex: hasKnownExistingIndex || hasCompletedInitialIndexingExperience,
            isReady: isReady,
            isRunning: progress.isRunning,
            isPaused: isThermallyPaused || backgroundExecutionState == .pausedAwaitingForeground,
            rebuildRequired: indexRebuildRequired
        )
    }

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
            shouldStartNextBatch: { [weak self] in
                self?.canStartNextLibraryBatch() ?? false
            },
            reloadSearchIndex: { [weak self] in
                await self?.reloadSearchIndexFromLibraryWorker() == true
            },
            didReplaceMedia: { [weak self] identifier in
                self?.didReplaceIndexedMedia(identifier)
            }
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
            reloadSearchIndex: { [weak self] in await self?.reloadSearchIndex() == true },
            didReplaceMedia: { [weak self] identifier in
                self?.didReplaceIndexedMedia(identifier)
            }
        )
    )

    init(
        imageEncoder: ImageEncoder,
        searchEngine: SearchEngine,
        database: DatabaseProtocol = AppDatabase.shared,
        surpriseQueryCacheLoader: @escaping @Sendable () -> SurpriseQueryCache.State = {
            SurpriseQueryCache.load()
        },
        searchIndexContentRevisionLoader: (@Sendable () throws -> SearchIndexContentRevision)? = nil,
        initialIndexingDefaults: UserDefaults = .standard,
        geocodingWorker: GeocodingWorker? = nil,
        geocodingRetryDelaySeconds: @escaping @Sendable (Int) -> TimeInterval = {
            GeocodingRetryPolicy.delaySeconds(afterAttempt: $0)
        }
    ) {
        self.imageEncoder = imageEncoder
        self.searchEngine = searchEngine
        self.database = database
        self.initialIndexingDefaults = initialIndexingDefaults
        let initialIndexingExperiencePending = InitialIndexingExperienceStore.isPending(
            in: initialIndexingDefaults
        )
        self.isInitialIndexingExperiencePending = initialIndexingExperiencePending
        self.hasCompletedInitialIndexingExperience = InitialIndexingExperienceStore.isCompleted(
            in: initialIndexingDefaults
        )
        if initialIndexingExperiencePending,
           InitialIndexingInterruptionStore.wasInterrupted(in: initialIndexingDefaults) {
            self.backgroundExecutionState = .pausedAwaitingForeground
        }
        self.surpriseQueryCacheLoader = surpriseQueryCacheLoader
        self.searchIndexContentRevisionLoader = searchIndexContentRevisionLoader ?? {
            try database.searchIndexContentRevision()
        }
        self.geocodingRetryDelaySeconds = geocodingRetryDelaySeconds
        self.geocodingWorker = geocodingWorker ?? GeocodingWorker(
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
        guard indexLoadError == nil else { return false }
        startObservingPhotoChanges()
        if scheduleAutoResume, loaded, shouldUseInitialIndexingExperience() {
            activateInitialIndexingExperience(isUserInitiated: false)
        }
        if loaded {
            await refreshGeocodingProgress(
                phase: scheduleAutoResume ? .queued : .waitingToResume
            )
        }
        if InitialIndexingExperiencePolicy.shouldResumePendingRun(
            scheduleAutoResume: scheduleAutoResume,
            didLoadIndex: loaded,
            isPending: isInitialIndexingExperiencePending
        ) {
            resumeIndexingAutomatically()
        }
        if scheduleAutoResume && (loaded || hasCompletedInitialIndexingExperience) {
            enqueueLibraryIndexing(
                isAutoResume: true,
                delayAfterDependencies: IndexingConfig.postLaunchAutoResumeDelaySeconds
            )
        }
        if scheduleOrphanCleanup && loaded {
            enqueueOrphanCleanup(
                delayAfterDependencies: IndexingConfig.postLaunchMaintenanceDelaySeconds
            )
        }
        if loaded && (scheduleAutoResume || scheduleOrphanCleanup) {
            enqueueSurpriseQueryValidation(
                workflowID: UUID(),
                delayAfterDependencies: IndexingConfig.postLaunchMaintenanceDelaySeconds
            )
        }
        allowsLifecycleAutoResume = scheduleAutoResume
        hasCompletedInitialIndexCheck = true
        scheduleForegroundInitialIndexingResumeIfNeeded()
        #if DEBUG
        logger.info("[IndexingService] checkAndLoadExistingIndex finish loaded=\(loaded), isReady=\(self.isReady), indexLoaded=\(self.searchEngine.isIndexLoaded), totalSize=\(self.searchEngine.totalSize)")
        #endif
        return loaded
    }

    @discardableResult
    func loadExistingIndexIfAvailable(loadPriority: TaskPriority = .utility) async -> Bool {
        indexLoadError = nil
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
                hasCompletedInitialIndexingExperience = false
                isInitialIndexingExperiencePending = true
                InitialIndexingExperienceStore.begin(in: initialIndexingDefaults)
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
                hasKnownExistingIndex = true
                #if DEBUG
                logger.info("[IndexingService] Found \(photoCount) indexed photos and \(videoCount) indexed videos, loading index")
                #endif

                async let cachedStateTask = CancellableDetachedOperation.run(
                    priority: loadPriority
                ) { [surpriseQueryCacheLoader] in
                    surpriseQueryCacheLoader()
                }
                async let didLoadTask = CancellableDetachedOperation.run(priority: loadPriority) { [searchEngine] in
                    try searchEngine.loadIndex()
                    return searchEngine.isIndexLoaded
                }
                let cachedState = try await cachedStateTask
                let cacheCouldMatch = cachedState.couldMatch(
                    photoCount: photoCount,
                    videoCount: videoCount
                )
                async let contentRevisionTask: SearchIndexContentRevision? = CancellableDetachedOperation.run(
                    priority: loadPriority
                ) { [searchIndexContentRevisionLoader] in
                    guard cacheCouldMatch else { return nil }
                    return try searchIndexContentRevisionLoader()
                }
                let didLoad = try await didLoadTask
                guard didLoad else {
                    isReady = false
                    progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
                    onIndexUnavailable?()
                    return false
                }

                let cachedSuggestions: [String]
                do {
                    if let contentRevision = try await contentRevisionTask {
                        cachedSuggestions = SurpriseQueries.cachedQueries(
                            from: cachedState,
                            matching: contentRevision
                        )
                    } else {
                        cachedSuggestions = []
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.error(
                        "[SurpriseQueries] Cache hydration failed: \(error.safeDiagnosticCode)"
                    )
                    cachedSuggestions = []
                }
                guard !progress.isRunning else { return false }
                if validatedSearchSuggestions != cachedSuggestions {
                    validatedSearchSuggestions = cachedSuggestions
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
            indexLoadError = "Search couldn’t load. Try again to open your existing index."
        }
        isReady = false
        onIndexUnavailable?()
        return false
    }

    func startIndexing() {
        startIndexing(isUserInitiated: true)
    }

    /// Starts the persisted initial-indexing request after onboarding. The
    /// caller supplies whether this invocation is the user's explicit action,
    /// because continued-processing submission is allowed only for that case.
    func startInitialIndexingFromOnboarding(isUserInitiated: Bool) {
        startIndexing(isUserInitiated: isUserInitiated)
    }

    private func resumeIndexingAutomatically() {
        startIndexing(isUserInitiated: false)
    }

    private func startIndexing(isUserInitiated: Bool) {
        libraryIndexingError = nil
        let usesInitialExperience = shouldUseInitialIndexingExperience()
        let resume: () -> Void = { [weak self] in self?.resumeIndexingAutomatically() }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else {
            if usesInitialExperience, isThermallyPaused, !progress.isRunning {
                activateInitialIndexingExperience(isUserInitiated: false)
            }
            return
        }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        if usesInitialExperience {
            activateInitialIndexingExperience(isUserInitiated: isUserInitiated)
        }
        thermalResumeIntent = intent
        hideValidatedSearchSuggestions()
        SurpriseQueries.clearValidated()
        enqueueLibraryIndexing(resumeIntentID: intent.id)
    }

    func indexNewPhotosOnly() {
        if shouldUseInitialIndexingExperience() {
            startIndexing()
            return
        }
        libraryIndexingError = nil
        let resume: () -> Void = { [weak self] in self?.indexNewPhotosOnly() }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        newPhotosAvailable = false
        hideValidatedSearchSuggestions()
        enqueueLibraryIndexing(resumeIntentID: intent.id)
    }

    func rebuildRequiredIndex() {
        rebuildRequiredIndex(isUserInitiated: true)
    }

    private func rebuildRequiredIndex(isUserInitiated: Bool) {
        libraryIndexingError = nil
        let resume: () -> Void = { [weak self] in
            self?.rebuildRequiredIndex(isUserInitiated: false)
        }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        guard indexRebuildRequired else {
            startIndexing()
            return
        }

        stopIndexing(preserveThermalResume: true)
        guard markRunningIfIdle() else { return }
        activateInitialIndexingExperience(isUserInitiated: isUserInitiated)
        thermalResumeIntent = intent
        hideValidatedSearchSuggestions()
        SurpriseQueries.clearValidated()
        enqueueLibraryIndexing(rebuildRequired: true, resumeIntentID: intent.id)
    }

    func stopIndexing() {
        let stoppedInitialIndexing = isInitialLibraryIndexingActive
            || isInitialIndexingExperiencePending
        stopIndexing(preserveThermalResume: false)
        if stoppedInitialIndexing {
            isInitialIndexingExperiencePending = false
            hasCompletedInitialIndexingExperience = false
            backgroundExecutionState = .foreground
            InitialIndexingExperienceStore.stop(in: initialIndexingDefaults)
            InitialIndexingInterruptionStore.clear(in: initialIndexingDefaults)
            BackgroundIndexingController.shared.initialIndexingWasStopped()
        }
    }

    private func stopIndexing(preserveThermalResume: Bool) {
        jobQueue.cancelAll()
        cancelGeocodingRetry()
        scheduledSavedFolderSourceIDs.removeAll()
        if !preserveThermalResume {
            deferredPostIndexingWorkflowID = nil
        }
        librarySession = nil
        if preserveThermalResume {
            markGeocodingWaitingToResume()
        } else {
            clearGeocodingProgress()
        }
        progress.isRunning = false
        endBackgroundTask()
        if !preserveThermalResume {
            isInitialLibraryIndexingActive = false
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

    func setUserSearchActive(_ active: Bool) {
        setUserSearchActive(active, id: primaryUserSearchID)
    }

    /// Each search surface owns its pause until its operation has drained.
    /// Finishing one request must not resume maintenance under another one.
    func setUserSearchActive(_ active: Bool, id: UUID) {
        if active {
            activeUserSearchIDs.insert(id)
        } else {
            activeUserSearchIDs.remove(id)
        }
        let active = !activeUserSearchIDs.isEmpty
        guard isUserSearchActive != active else { return }
        isUserSearchActive = active
        if active {
            jobQueue.setMaintenanceSuspended(true)
        }
        // Cancel current analysis and start a fresh quiet interval when the
        // search finishes. A slow search must never outlast the pause.
        prioritizeUserSearch()
        if !active {
            jobQueue.setMaintenanceSuspended(false)
        }
    }

    /// Apple location services must not begin new reverse-geocoding requests
    /// while the app is inactive. Pending work remains visible and resumes as
    /// soon as the foreground is active again.
    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else { return }
        isApplicationActive = isActive

        if !isActive {
            if jobQueue.contains(.enrichPhotos) {
                deferPostIndexingWork(workflowID: UUID())
            }
            if isInitialIndexingExperiencePending {
                if progress.isRunning || hasLibraryIndexingWork {
                    backgroundExecutionState = .continuingInBackground
                }
            }
            cancelGeocodingRetry()
            if jobQueue.contains(.geocodeMedia) {
                jobQueue.cancel(.geocodeMedia)
            }
            markGeocodingWaitingToResume()
            return
        }

        scheduleGeocodingResumeCheck()
        Task { @MainActor [weak self] in
            await self?.enqueueDeferredPostIndexingWorkIfNeeded()
        }
        if hasDeferredSearchIndexReload {
            hasDeferredSearchIndexReload = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !(await reloadSearchIndex()) {
                    hasDeferredSearchIndexReload = true
                }
            }
        }
        scheduleForegroundInitialIndexingResumeIfNeeded()
    }

    func resumeInitialIndexingForSystemTask() async -> BackgroundIndexingLaunchResult {
        guard isInitialIndexingExperiencePending else { return .completed }
        if progress.isRunning || hasLibraryIndexingWork {
            return .running
        }

        resumeIndexingAutomatically()
        return progress.isRunning || hasLibraryIndexingWork ? .running : .retryableFailure
    }

    func handleScheduledBackgroundTaskExpiration() {
        guard ScheduledInitialIndexingExpirationPolicy.shouldInterrupt(
            isApplicationActive: isApplicationActive,
            isInitialIndexingPending: isInitialIndexingExperiencePending
        ) else { return }
        interruptInitialIndexingForSystemExpiration(notifyController: false)
    }

    func cancelAllWorkForMemoryPressure() {
        let interruptedInitialIndexing = isInitialIndexingExperiencePending
        if interruptedInitialIndexing {
            InitialIndexingInterruptionStore.markInterrupted(in: initialIndexingDefaults)
            backgroundExecutionState = .pausedAwaitingForeground
        }
        jobQueue.cancelAll()
        cancelGeocodingRetry()
        hideValidatedSearchSuggestions()
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
        clearGeocodingProgress()
        progress.isRunning = false
        isInitialLibraryIndexingActive = false
        thermalResumeIntent = nil
        thermalSafetyState = ThermalIndexingState()
        isThermallyPaused = false
        stopObservingThermalChanges()
        isReady = false
        endBackgroundTask()
        if interruptedInitialIndexing {
            BackgroundIndexingController.shared.initialIndexingWasInterrupted()
        }
        searchEngine.suspendForMemoryPressure()
        onIndexUnavailable?()
    }

    /// Deletes a confirmed duplicate from Photos, then updates every derived
    /// search surface through the same lifecycle used by other index changes.
    /// Once Photos accepts the deletion, the local reconciliation intentionally
    /// runs to completion so dismissing the sheet cannot leave stale results.
    func deleteDuplicatePhoto(
        localIdentifier: String
    ) async throws -> DuplicatePhotoDeletionOutcome {
        let previousDeletion = duplicateDeletionTail
        let operation = Task { @MainActor [weak self] in
            if let previousDeletion {
                await previousDeletion.value
            }
            guard let self else { throw CancellationError() }
            return try await self.performDuplicatePhotoDeletion(
                localIdentifier: localIdentifier
            )
        }
        let operationID = UUID()
        let tail = Task { @MainActor in
            _ = try? await operation.value
        }
        duplicateDeletionTail = tail
        duplicateDeletionTailID = operationID
        defer {
            if duplicateDeletionTailID == operationID {
                duplicateDeletionTail = nil
                duplicateDeletionTailID = nil
            }
        }
        return try await operation.value
    }

    private func performDuplicatePhotoDeletion(
        localIdentifier: String
    ) async throws -> DuplicatePhotoDeletionOutcome {
        isDeletingDuplicatePhoto = true
        defer { isDeletingDuplicatePhoto = false }

        guard !isThermallyPaused,
              !ThermalSafetyPolicy.shouldPause(
                for: ProcessInfo.processInfo.thermalState
              ) else {
            throw DuplicatePhotoDeletionError.deviceTooWarm
        }
        guard let asset = await PhotoLibrary.resolveAsset(by: localIdentifier) else {
            throw DuplicatePhotoDeletionError.assetUnavailable
        }

        try await Self.deletePhotoAsset(asset)
        let suspendedWork = duplicateDeletionWorkSnapshot()
        hideValidatedSearchSuggestions()
        invalidateSearchIndexAfterDeletion()
        stopIndexing(preserveThermalResume: true)
        await jobQueue.waitUntilIdle()

        let db = database
        let remainingMediaCount: Int
        do {
            remainingMediaCount = try await CancellableDetachedOperation.run(
                priority: .userInitiated
            ) {
                try db.deletePhoto(localIdentifier: localIdentifier)
                return try db.indexedMediaCounts().total
            }
        } catch {
            logger.error("Failed to reconcile deleted duplicate: \(error.safeDiagnosticCode)")
            await resumeWorkAfterDuplicateDeletion(
                suspendedWork,
                needsIndexRecovery: true,
                forceIndexReload: false
            )
            return .indexRefreshPending
        }

        if remainingMediaCount == 0 {
            progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
            indexVersion += 1
            await resumeWorkAfterDuplicateDeletion(suspendedWork)
            return .completed
        }

        if ThermalSafetyPolicy.shouldPause(for: ProcessInfo.processInfo.thermalState) {
            await resumeWorkAfterDuplicateDeletion(
                suspendedWork,
                needsIndexRecovery: true,
                forceIndexReload: true
            )
            return .indexRefreshPending
        }

        let didReload = await reloadSearchIndex()
        if didReload {
            await resumeWorkAfterDuplicateDeletion(suspendedWork)
            return .completed
        }

        await resumeWorkAfterDuplicateDeletion(
            suspendedWork,
            needsIndexRecovery: true,
            forceIndexReload: true
        )
        return .indexRefreshPending
    }

    private nonisolated static func deletePhotoAsset(_ asset: PHAsset) async throws {
        // PhotoKit invokes changes on its own queue, outside MainActor.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    private struct DuplicateDeletionWorkSnapshot {
        let libraryIndexing: Bool
        let enrichment: Bool
        let geocoding: Bool
        let orphanCleanup: Bool
        let folderIndexing: Bool
    }

    private func duplicateDeletionWorkSnapshot() -> DuplicateDeletionWorkSnapshot {
        DuplicateDeletionWorkSnapshot(
            libraryIndexing: jobQueue.contains(.indexPhotos)
                || jobQueue.contains(.indexVideos),
            enrichment: jobQueue.contains(.enrichPhotos),
            geocoding: jobQueue.contains(.geocodeMedia),
            orphanCleanup: jobQueue.contains(.cleanOrphans),
            folderIndexing: jobQueue.contains(.indexFolder)
        )
    }

    private func invalidateSearchIndexAfterDeletion() {
        searchEngine.dropIndex()
        isReady = false
        progress.searchableCount = 0
        onIndexUnavailable?()
    }

    private func resumeWorkAfterDuplicateDeletion(
        _ suspendedWork: DuplicateDeletionWorkSnapshot,
        needsIndexRecovery: Bool = false,
        forceIndexReload: Bool = false
    ) async {
        if ThermalSafetyPolicy.shouldPause(for: ProcessInfo.processInfo.thermalState) {
            thermalSafetyState = ThermalIndexingState(
                isPaused: true,
                resumeWhenCool: true
            )
            isThermallyPaused = true
            if thermalResumeIntent == nil {
                thermalResumeIntent = ThermalResumeIntent(
                    id: UUID(),
                    action: { [weak self] in self?.resumeIndexingAutomatically() }
                )
            }
            return
        }
        guard database.allowsIndexingWrites,
              !searchEngine.isMemoryPressureSuspended else { return }

        if suspendedWork.libraryIndexing {
            enqueueLibraryIndexing(isAutoResume: true)
        } else if suspendedWork.enrichment {
            enqueueEnrichment(workflowID: UUID())
        }

        if suspendedWork.geocoding {
            enqueueGeocoding(
                workflowID: UUID(),
                replacingCancelledJob: true
            )
        }
        if suspendedWork.orphanCleanup || needsIndexRecovery {
            enqueueOrphanCleanup(
                replacingCancelledJob: true,
                forceIndexReload: forceIndexReload
            )
        }
        if suspendedWork.folderIndexing {
            await enqueueSavedFolderReindexingIfNeeded()
        }
        if !needsIndexRecovery, searchEngine.isIndexLoaded {
            enqueueSurpriseQueryValidation(
                workflowID: UUID(),
                replacingCancelledJob: true
            )
        }
    }

    func indexFolder(url: URL, name: String) {
        guard ProManager.shared.isPro else {
            logger.error("Folder indexing requires an active Pro entitlement")
            return
        }
        // Indexing can start while the system folder picker is open.
        // Report the rejected selection instead of silently discarding it.
        guard !progress.isRunning || progress.phase == .enrichment else {
            folderIndexingError = "Search is updating. Wait for it to finish, then add the folder again."
            logger.error("Folder selection could not be added while indexing is running")
            return
        }
        let resume: () -> Void = { [weak self] in self?.indexFolder(url: url, name: name) }
        let intent = ThermalResumeIntent(id: UUID(), action: resume)
        guard canStartIndexing(resumeWhenCool: intent) else { return }
        searchEngine.resumeAfterMemoryPressure()
        cancelEnrichmentWork()
        guard markRunningIfIdle() else { return }
        thermalResumeIntent = intent
        hideValidatedSearchSuggestions()
        let workflowID = UUID()
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
                await self.reloadCommittedMediaReplacementsIfNeeded()
                guard outcome.didComplete, !Task.isCancelled else { return outcome }
                self.enqueueSurpriseQueryValidation(
                    workflowID: workflowID,
                    replacingCancelledJob: true
                )
                self.enqueueEnrichment(workflowID: workflowID)
                self.enqueueGeocoding(workflowID: workflowID)
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
        hideValidatedSearchSuggestions()
        scheduledSavedFolderSourceIDs.insert(source.id)
        let workflowID = UUID()
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
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
                let outcome = await self.folderWorker.reindex(source: source)
                await self.reloadCommittedMediaReplacementsIfNeeded()
                guard outcome.didComplete, !Task.isCancelled else { return outcome }
                self.enqueueSurpriseQueryValidation(
                    workflowID: workflowID,
                    replacingCancelledJob: true
                )
                self.enqueueEnrichment(workflowID: workflowID)
                self.enqueueGeocoding(workflowID: workflowID)
                return .completed
            }
        })
    }

    func clearFolderIndexingError() {
        folderIndexingError = nil
    }

    func deleteFolderSource(id: String) async throws {
        try await runTrackedStorageMutation { [weak self] in
            guard let self else { throw CancellationError() }
            self.stopIndexing(preserveThermalResume: false)
            self.hideValidatedSearchSuggestions()
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
                    guard await self.reloadSearchIndex() else { return }
                    self.enqueueSurpriseQueryValidation(
                        workflowID: UUID(),
                        replacingCancelledJob: true
                    )
                }
            )
        }
    }

    func rebuildLibraryIndex() async throws {
        try await runTrackedStorageMutation { [weak self] in
            guard let self else { throw CancellationError() }
            self.stopIndexing(preserveThermalResume: false)
            await self.jobQueue.waitUntilIdle()
            try await self.resetMediaIndex()
            try Task.checkCancellation()
            guard !self.searchEngine.isMemoryPressureSuspended else {
                throw CancellationError()
            }
            self.startIndexing()
        }
    }

    private func resetMediaIndex() async throws {
        try Task.checkCancellation()
        await onIndexResetStarted?()
        var didReset = false
        defer { onIndexResetFinished?(didReset) }
        let db = database
        // Once the transaction starts, drain it and publish its outcome even
        // if the caller is cancelled. History and the index must agree.
        try await Task.detached(priority: .userInitiated) {
            try db.resetIndexedMedia()
        }.value
        didReset = true
        indexRebuildRequired = true
        hasCompletedInitialIndexingExperience = false
        isInitialIndexingExperiencePending = true
        InitialIndexingExperienceStore.begin(in: initialIndexingDefaults)
        searchEngine.dropIndex()
        isReady = false
        onIndexUnavailable?()
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
            markGeocodingWaitingToResume()
            self.isInitialLibraryIndexingActive = false
            scheduledSavedFolderSourceIDs.removeAll()
            hideValidatedSearchSuggestions()
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
                        guard await self.reloadSearchIndex() else { return }
                        self.enqueueSurpriseQueryValidation(
                            workflowID: UUID(),
                            replacingCancelledJob: true
                        )
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

    private var hasLibraryIndexingWork: Bool {
        jobQueue.contains(.indexPhotos) || jobQueue.contains(.indexVideos)
    }

    private func reloadSearchIndexFromLibraryWorker() async -> Bool {
        guard isApplicationActive else {
            hasDeferredSearchIndexReload = true
            return false
        }
        return await reloadSearchIndex()
    }

    private func scheduleForegroundInitialIndexingResumeIfNeeded() {
        guard InitialIndexingForegroundResumePolicy.shouldSchedule(
                isApplicationActive: isApplicationActive,
                hasCompletedInitialIndexCheck: hasCompletedInitialIndexCheck,
                allowsAutoResume: allowsLifecycleAutoResume,
                isPending: isInitialIndexingExperiencePending,
                progressIsRunning: progress.isRunning,
                hasLibraryWork: hasLibraryIndexingWork
              ) else {
            if isApplicationActive,
               isInitialIndexingExperiencePending,
               progress.isRunning || hasLibraryIndexingWork {
                backgroundExecutionState = .foreground
            }
            return
        }

        resumeIndexingAutomatically()
        if progress.isRunning || hasLibraryIndexingWork {
            backgroundExecutionState = .foreground
        }
    }

    private func canStartNextLibraryBatch() -> Bool {
        guard isInitialIndexingExperiencePending else { return true }
        return IndexingBackgroundTimePolicy.canStartNextBatch(
            isApplicationActive: isApplicationActive,
            hasScheduledTaskAssertion: BackgroundIndexingController.shared.hasActiveSystemTask,
            backgroundTimeRemaining: UIApplication.shared.backgroundTimeRemaining
        )
    }

    private func interruptInitialIndexingForSystemExpiration(notifyController: Bool = true) {
        guard isInitialIndexingExperiencePending else { return }
        InitialIndexingInterruptionStore.markInterrupted(in: initialIndexingDefaults)
        backgroundExecutionState = .pausedAwaitingForeground
        stopIndexing(preserveThermalResume: false)
        if notifyController {
            BackgroundIndexingController.shared.initialIndexingWasInterrupted()
        }
    }

    private func markRunningIfIdle() -> Bool {
        guard !progress.isRunning else { return false }
        progress.isRunning = true
        return true
    }

    private func shouldUseInitialIndexingExperience() -> Bool {
        indexRebuildRequired || isInitialIndexingExperiencePending || InitialIndexingExperiencePolicy.shouldBegin(
            hasCompletedInitialExperience: hasCompletedInitialIndexingExperience
        )
    }

    private func activateInitialIndexingExperience(isUserInitiated: Bool) {
        isInitialLibraryIndexingActive = true
        backgroundExecutionState = isApplicationActive ? .foreground : .continuingInBackground
        hasCompletedInitialIndexingExperience = false
        isInitialIndexingExperiencePending = true
        InitialIndexingExperienceStore.begin(in: initialIndexingDefaults)
        InitialIndexingInterruptionStore.clear(in: initialIndexingDefaults)
        BackgroundIndexingController.shared.initialIndexingDidStart(
            isApplicationActive: isApplicationActive,
            isUserInitiated: isUserInitiated
        )
    }

    private func completeInitialIndexingExperience() {
        isInitialLibraryIndexingActive = false
        guard isInitialIndexingExperiencePending || !hasCompletedInitialIndexingExperience else {
            return
        }
        isInitialIndexingExperiencePending = false
        hasCompletedInitialIndexingExperience = true
        backgroundExecutionState = .foreground
        InitialIndexingExperienceStore.complete(in: initialIndexingDefaults)
        InitialIndexingInterruptionStore.clear(in: initialIndexingDefaults)
        BackgroundIndexingController.shared.initialIndexingDidComplete()
    }

    private func dismissInterruptedInitialPresentationIfNeeded() {
        guard !isThermallyPaused else { return }
        isInitialLibraryIndexingActive = false
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
            hasActiveWork: ThermalWorkActivityPolicy.hasActiveWork(
                isJobQueueIdle: jobQueue.isIdle,
                isProgressRunning: progress.isRunning,
                hasDeferredPostIndexingWorkflow: deferredPostIndexingWorkflowID != nil
            )
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
                    action: { [weak self] in self?.resumeIndexingAutomatically() }
                )
            }
            stopIndexing(preserveThermalResume: true)
        case .restartWork:
            let resume = thermalResumeIntent?.action ?? {
                [weak self] in self?.resumeIndexingAutomatically()
            }
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
        if event.requiresFullReconciliation || !event.changedPhotoIDs.isEmpty || !event.changedVideoIDs.isEmpty {
            PhotoLibrary.clearAssetCache()
        }
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
                self.pendingPhotoRefreshIDs.formUnion(result.changedPhotoIDs)
                self.pendingVideoRefreshIDs.formUnion(result.changedVideoIDs)
                self.pendingPhotoRefreshIDs.subtract(event.removedPhotoIDs)
                self.pendingVideoRefreshIDs.subtract(event.removedVideoIDs)
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
        guard !Task.isCancelled else { return false }
        guard !searchEngine.isMemoryPressureSuspended else {
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
            guard !Task.isCancelled else { return false }
            guard !searchEngine.isMemoryPressureSuspended else {
                isReady = false
                onIndexUnavailable?()
                return false
            }
            isReady = didLoad
            if didLoad {
                indexLoadError = nil
                hasInvalidatedMediaReplacements = false
                hasKnownExistingIndex = true
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
        } catch is CancellationError {
            return false
        } catch {
            logger.error("Failed to reload search index: \(error.safeDiagnosticCode)")
            indexLoadError = "Search couldn’t refresh. Try again to load your latest index."
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
        case unavailable
    }

    /// A forced refresh only ever replaces media that is already indexed. An
    /// identifier that never reached the index cannot be refreshed, and once
    /// the free tier's cap is reached it cannot be inserted either, so leaving
    /// it queued would ask for a resume on every launch forever.
    private func pruneUnrefreshablePendingMedia() async {
        guard !pendingPhotoRefreshIDs.isEmpty || !pendingVideoRefreshIDs.isEmpty else { return }
        let db = database
        let photoIDs = Array(pendingPhotoRefreshIDs)
        let videoIDs = Array(pendingVideoRefreshIDs)
        do {
            let indexed = try await CancellableDetachedOperation.run {
                (
                    photos: Set(try db.indexedPhotoVersions(in: photoIDs).keys),
                    videos: Set(try db.indexedVideoVersions(in: videoIDs).keys)
                )
            }
            pendingPhotoRefreshIDs.formIntersection(indexed.photos)
            pendingVideoRefreshIDs.formIntersection(indexed.videos)
        } catch {
            // Leave the queue untouched; the next decision retries the prune.
            return
        }
    }

    private func didReplaceIndexedMedia(_ identifier: String) {
        PhotoLibrary.clearAssetCache()
        pendingPhotoRefreshIDs.remove(identifier)
        pendingVideoRefreshIDs.remove(identifier)
        hideValidatedSearchSuggestions()
        SurpriseQueries.clearValidated()
        hasInvalidatedMediaReplacements = true
        hasDeferredSearchIndexReload = true
        searchEngine.dropIndex()
        isReady = false
        onIndexUnavailable?()
    }

    private func reloadCommittedMediaReplacementsIfNeeded() async {
        guard hasInvalidatedMediaReplacements, isApplicationActive,
              !searchEngine.isMemoryPressureSuspended else { return }
        if await reloadSearchIndexInFreshTask() {
            hasDeferredSearchIndexReload = false
        }
    }

    private func enqueueLibraryIndexing(
        rebuildRequired: Bool = false,
        autoResumeLibraryCount: Int? = nil,
        isAutoResume: Bool = false,
        delayAfterDependencies: TimeInterval = 0,
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
                case .unavailable:
                    guard !Task.isCancelled else { return .cancelled }
                    self.pauseAfterLibraryIndexingFailure()
                    return .cancelled
                case .noIndex:
                    guard self.isInitialIndexingExperiencePending || self.hasCompletedInitialIndexingExperience else { return .completed }
                    self.cancelEnrichmentWork()
                    guard self.markRunningIfIdle() else { return .cancelled }
                    if self.shouldUseInitialIndexingExperience() {
                        self.activateInitialIndexingExperience(isUserInitiated: false)
                    }
                case .complete:
                    await self.completeBaseIndexingAndSchedulePostIndexingWork(
                        workflowID: workflowID
                    )
                    return .completed
                case .resume:
                    self.cancelEnrichmentWork()
                    guard self.markRunningIfIdle() else { return .cancelled }
                    if self.shouldUseInitialIndexingExperience() {
                        self.activateInitialIndexingExperience(isUserInitiated: false)
                    }
                    self.newPhotosAvailable = false
                }
            }

            if rebuildRequired {
                do {
                    try await self.resetMediaIndex()
                    try Task.checkCancellation()
                } catch is CancellationError {
                    self.progress.isRunning = false
                    self.dismissInterruptedInitialPresentationIfNeeded()
                    self.clearThermalResumeIntent(ifOwnedBy: resumeIntentID)
                    return .cancelled
                } catch {
                    logger.error("Failed to clear incompatible index before rebuild: \(error.safeDiagnosticCode)")
                    self.progress.isRunning = false
                    self.dismissInterruptedInitialPresentationIfNeeded()
                    self.clearThermalResumeIntent(ifOwnedBy: resumeIntentID)
                    return .cancelled
                }
            }

            self.beginBackgroundTask()
            self.librarySession = await self.libraryWorker.indexPhotos(
                forcedPhotoRefreshIDs: self.pendingPhotoRefreshIDs,
                forcedVideoRefreshIDs: self.pendingVideoRefreshIDs
            )
            await self.reloadCommittedMediaReplacementsIfNeeded()
            if self.librarySession?.wasInterrupted == true {
                self.librarySession = nil
                self.interruptInitialIndexingForSystemExpiration()
                return .cancelled
            }
            if Task.isCancelled {
                self.librarySession = nil
                self.endBackgroundTask()
                self.progress.isRunning = false
                self.dismissInterruptedInitialPresentationIfNeeded()
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
            await self.reloadCommittedMediaReplacementsIfNeeded()
            if session.wasInterrupted {
                self.interruptInitialIndexingForSystemExpiration()
                return .cancelled
            }
            guard !Task.isCancelled else {
                self.progress.isRunning = false
                self.dismissInterruptedInitialPresentationIfNeeded()
                return .cancelled
            }
            guard !session.hasRetryableFailure else {
                self.pauseAfterLibraryIndexingFailure()
                return .cancelled
            }
            self.progress.isRunning = false
            if self.indexRebuildRequired {
                do {
                    let db = self.database
                    try await CancellableDetachedOperation.run {
                        try db.clearIndexRebuildRequired()
                    }
                    self.indexRebuildRequired = false
                } catch is CancellationError {
                    self.progress.isRunning = false
                    self.dismissInterruptedInitialPresentationIfNeeded()
                    return .cancelled
                } catch {
                    logger.error("Failed to complete empty index rebuild: \(error.safeDiagnosticCode)")
                    self.pauseAfterLibraryIndexingFailure()
                    return .cancelled
                }
            }
            await self.completeBaseIndexingAndSchedulePostIndexingWork(workflowID: workflowID)
            return .completed
        })
    }

    private func pauseAfterLibraryIndexingFailure() {
        progress.isRunning = false
        dismissInterruptedInitialPresentationIfNeeded()
        libraryIndexingError = "Some items couldn’t be indexed. Your indexed photos and videos are still available."
        if isInitialIndexingExperiencePending {
            InitialIndexingInterruptionStore.markInterrupted(in: initialIndexingDefaults)
            backgroundExecutionState = .pausedAwaitingForeground
            BackgroundIndexingController.shared.initialIndexingWasInterrupted()
        }
    }

    private func enqueuePostIndexingJobs(
        workflowID: UUID,
        dependencies: Set<IndexingJobKind>
    ) {
        jobQueue.cancel(.enrichPhotos)
        enqueueEnrichment(workflowID: workflowID, dependencies: dependencies)
        enqueueSurpriseQueryValidation(
            workflowID: workflowID,
            dependencies: dependencies,
            delayAfterDependencies: IndexingConfig.surpriseValidationDelaySeconds
        )
        enqueueGeocoding(workflowID: workflowID, dependencies: dependencies)
    }

    private func deferPostIndexingWork(workflowID: UUID) {
        // No maintenance may survive the base pass while inactive. In
        // particular, this removes the launch-time enrichment job that was
        // queued behind photos before the base run reached this decision.
        jobQueue.cancel(.enrichPhotos)
        if deferredPostIndexingWorkflowID == nil {
            deferredPostIndexingWorkflowID = workflowID
        }
    }

    private func completeBaseIndexingAndSchedulePostIndexingWork(
        workflowID: UUID
    ) async {
        let defersPostIndexingWork = PostIndexingContinuationPolicy.shouldDeferUntilForeground(
            isApplicationActive: isApplicationActive
        )
        if defersPostIndexingWork {
            // Record the continuation before completing a scheduled task: its
            // completion may let iOS suspend the process immediately.
            deferPostIndexingWork(workflowID: workflowID)
        }
        completeInitialIndexingExperience()
        if !defersPostIndexingWork {
            await enqueuePostIndexingWork(workflowID: workflowID)
        }
    }

    private func enqueuePostIndexingWork(workflowID: UUID) async {
        // Folder work is user initiated and preempts enrichment. Queue it
        // first, then enqueue maintenance so cancellation cannot leave the
        // base run without another enrichment pass.
        await enqueueSavedFolderReindexingIfNeeded()
        guard canScheduleAutomaticMaintenance() else {
            preservePostIndexingDeferralIfBackgrounded(workflowID: workflowID)
            return
        }
        // A thermal interruption can leave an earlier deferred workflow
        // behind. This successful continuation supersedes it.
        deferredPostIndexingWorkflowID = nil
        enqueuePostIndexingJobs(
            workflowID: workflowID,
            dependencies: PostIndexingContinuationPolicy.dependencies(
                isDeferredUntilAfterBaseCompletion: false
            )
        )
    }

    private func enqueueDeferredPostIndexingWorkIfNeeded() async {
        guard let workflowID = deferredPostIndexingWorkflowID,
              canScheduleAutomaticMaintenance() else { return }
        // Discover and queue saved folders before maintenance. Folder jobs are
        // user initiated and therefore preempt enrichment by design.
        await enqueueSavedFolderReindexingIfNeeded()
        guard canScheduleAutomaticMaintenance(),
              deferredPostIndexingWorkflowID == workflowID else { return }
        // Do not clear the marker until every await and eligibility check has
        // passed. Thermal cancellation then retains a recoverable workflow.
        deferredPostIndexingWorkflowID = nil
        enqueuePostIndexingJobs(
            workflowID: workflowID,
            dependencies: PostIndexingContinuationPolicy.dependencies(
                isDeferredUntilAfterBaseCompletion: true
            )
        )
    }

    private func canScheduleAutomaticMaintenance() -> Bool {
        AutomaticMaintenanceEligibilityPolicy.canSchedule(
            isApplicationActive: isApplicationActive,
            allowsIndexingWrites: database.allowsIndexingWrites,
            isMemoryPressureSuspended: searchEngine.isMemoryPressureSuspended,
            isThermallySafe: !ThermalSafetyPolicy.shouldPause(
                for: ProcessInfo.processInfo.thermalState
            ),
            isTaskCancelled: Task.isCancelled
        )
    }

    private func preservePostIndexingDeferralIfBackgrounded(workflowID: UUID) {
        guard PostIndexingContinuationPolicy.shouldDeferUntilForeground(
            isApplicationActive: isApplicationActive
        ), !Task.isCancelled else { return }
        deferPostIndexingWork(workflowID: workflowID)
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
            let revision: SearchIndexContentRevision
            do {
                let db = self.database
                revision = try await CancellableDetachedOperation.run {
                    try db.searchIndexContentRevision()
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                logger.error("[SurpriseQueries] Revision load failed: \(error.safeDiagnosticCode)")
                return .cancelled
            }
            let validated = await SurpriseQueries.validateQueries(
                using: self.searchEngine,
                contentRevision: revision
            )
            guard !Task.isCancelled else { return .cancelled }
            if self.validatedSearchSuggestions != validated {
                self.validatedSearchSuggestions = validated
            }
            return .completed
        })
    }

    private func hideValidatedSearchSuggestions() {
        jobQueue.cancel(.validateSurpriseQueries)
        if !validatedSearchSuggestions.isEmpty {
            validatedSearchSuggestions = []
        }
    }

    private func enqueueSavedFolderReindexingIfNeeded() async {
        guard ProManager.shared.isPro,
              canScheduleAutomaticMaintenance() else { return }

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

        guard canScheduleAutomaticMaintenance() else { return }

        let candidates = SavedFolderReindexPolicy.sourcesToReindex(
            from: sources,
            isPro: ProManager.shared.isPro
        ).filter { !scheduledSavedFolderSourceIDs.contains($0.id) }

        guard !candidates.isEmpty else { return }
        hideValidatedSearchSuggestions()
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
                    await self.reloadCommittedMediaReplacementsIfNeeded()
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
                        guard await self.reloadSearchIndex() else { return .failed }
                        self.enqueueSurpriseQueryValidation(
                            workflowID: UUID(),
                            replacingCancelledJob: true
                        )
                        return outcome
                    }
                }
                if Task.isCancelled {
                    if didCompleteSource {
                        _ = await self.reloadSearchIndexInFreshTask()
                    }
                    return .cancelled
                }
                guard await self.reloadSearchIndex() else { return .failed }
                self.enqueueSurpriseQueryValidation(
                    workflowID: UUID(),
                    replacingCancelledJob: true
                )
                return .completed
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
        if ProUnlockIndexingRecoveryPolicy.shouldStartLibraryIndexing(
            isMemoryPressureSuspended: searchEngine.isMemoryPressureSuspended,
            hasLibraryIndexingWork: hasLibraryIndexingWork
        ) {
            resumeIndexingAutomatically()
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
            delayAfterDependencies: max(
                delayAfterDependencies,
                IndexingConfig.postLaunchMaintenanceDelaySeconds
            )
        ) { [weak self] in
            guard let self, !self.progress.isRunning else { return .cancelled }
            guard self.canScheduleAutomaticMaintenance(), !self.isUserSearchActive else {
                self.deferPostIndexingWork(workflowID: workflowID)
                return .cancelled
            }
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
        guard isApplicationActive else {
            markGeocodingWaitingToResume()
            return
        }
        guard replacingCancelledJob || !jobQueue.contains(.geocodeMedia) else { return }
        cancelGeocodingRetry()
        markGeocodingQueued()
        jobQueue.enqueue(IndexingJob(
            workflowID: workflowID,
            kind: .geocodeMedia,
            priority: .background,
            dependencies: dependencies,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self, self.isApplicationActive else { return .cancelled }
            await self.geocodeIndexedMedia()
            return Task.isCancelled ? .cancelled : .completed
        })
    }

    private func enqueueOrphanCleanup(
        delayAfterDependencies: TimeInterval = 0,
        replacingCancelledJob: Bool = false,
        forceIndexReload: Bool = false
    ) {
        guard replacingCancelledJob || !jobQueue.contains(.cleanOrphans) else { return }
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .cleanOrphans,
            priority: .maintenance,
            delayAfterDependencies: delayAfterDependencies
        ) { [weak self] in
            guard let self else { return .cancelled }
            let cleanup = await self.cleanOrphanedEmbeddings()
            if cleanup.changedIndex || forceIndexReload {
                let reloaded = Task.isCancelled
                    ? await self.reloadSearchIndexInFreshTask()
                    : await self.reloadSearchIndex()
                guard reloaded else { return .cancelled }
            }
            guard !Task.isCancelled else { return .cancelled }
            guard cleanup.invalidatedSuggestions || forceIndexReload else {
                return .completed
            }
            self.enqueueSurpriseQueryValidation(
                workflowID: UUID(),
                replacingCancelledJob: true
            )
            return .completed
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
            guard !orphanedPhotoIDs.isEmpty || !orphanedVideoIDs.isEmpty else {
                return .completed
            }
            let mutationState = OSAllocatedUnfairLock(initialState: false)
            self.hideValidatedSearchSuggestions()
            do {
                try await CancellableDetachedOperation.run {
                    if !orphanedPhotoIDs.isEmpty {
                        guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                            PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        ) else { throw CancellationError() }
                        try database.deleteOrphanedPhotos(localIdentifiers: orphanedPhotoIDs)
                        mutationState.withLock { $0 = true }
                    }
                    try Task.checkCancellation()
                    if !orphanedVideoIDs.isEmpty {
                        guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                            PHPhotoLibrary.authorizationStatus(for: .readWrite)
                        ) else { throw CancellationError() }
                        try database.deleteOrphanedVideos(localIdentifiers: orphanedVideoIDs)
                        mutationState.withLock { $0 = true }
                    }
                }
                if Task.isCancelled {
                    if mutationState.withLock({ $0 }) {
                        _ = await self.reloadSearchIndexInFreshTask()
                    }
                    return .cancelled
                }
                guard await self.reloadSearchIndex() else { return .cancelled }
                self.enqueueSurpriseQueryValidation(
                    workflowID: UUID(),
                    replacingCancelledJob: true
                )
                return .completed
            } catch is CancellationError {
                if mutationState.withLock({ $0 }) {
                    _ = await self.reloadSearchIndexInFreshTask()
                }
                return .cancelled
            } catch {
                logger.error("Error cleaning orphaned photos: \(error.safeDiagnosticCode)")
                if mutationState.withLock({ $0 }) {
                    guard await self.reloadSearchIndex() else { return .cancelled }
                }
                if !Task.isCancelled {
                    self.enqueueSurpriseQueryValidation(
                        workflowID: UUID(),
                        replacingCancelledJob: true
                    )
                }
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
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            return .unavailable
        }
        let totalInLibrary: Int
        if let providedTotal {
            totalInLibrary = providedTotal
        } else {
            do {
                totalInLibrary = try await CancellableDetachedOperation.run(priority: .utility) {
                    PhotoLibrary.fetchAllMedia().count
                }
            } catch is CancellationError {
                return .unavailable
            } catch {
                logger.error("Failed to read photo library size: \(error.safeDiagnosticCode)")
                return .unavailable
            }
        }

        let counts: IndexedMediaCounts
        // The free tier's cap counts every indexed row, including folder
        // sources, so the cap check must use the same total the worker applies.
        let allIndexedMediaCount: Int
        do {
            let db = database
            let snapshot = try await CancellableDetachedOperation.run {
                (
                    library: try db.photoLibraryIndexedMediaCounts(),
                    allMedia: try db.indexedMediaCounts().total
                )
            }
            counts = snapshot.library
            allIndexedMediaCount = snapshot.allMedia
        } catch is CancellationError {
            return .unavailable
        } catch {
            logger.error("Failed to check index completeness: \(error.safeDiagnosticCode)")
            return .unavailable
        }

        let totalIndexed = counts.total
        guard totalIndexed > 0 else { return .noIndex }
        // Once a free library reaches the cap, media beyond it can never be
        // indexed. Counting it as outstanding work asked every launch to resume
        // a pass that could only scan the library and index nothing.
        let canAddMedia = FreeTier.canIndexMore(
            indexedMediaCount: allIndexedMediaCount,
            isPro: ProManager.shared.isPro
        )
        let unindexedCount = LibraryIndexingCompletenessPolicy.outstandingMediaCount(
            totalInLibrary: totalInLibrary,
            totalIndexed: totalIndexed,
            canAddMedia: canAddMedia
        )

        if unindexedCount <= 0 {
            await pruneUnrefreshablePendingMedia()
            if !pendingPhotoRefreshIDs.isEmpty || !pendingVideoRefreshIDs.isEmpty {
                return .resume
            }
            do {
                let db = database
                let needsIndexing = try await CancellableDetachedOperation.run {
                    try PhotoLibraryChangeReconciler.hasUnindexedOrModifiedMedia(
                        database: db,
                        canAddMedia: canAddMedia
                    )
                }
                return needsIndexing ? .resume : .complete
            } catch is CancellationError {
                return .unavailable
            } catch {
                logger.error("Failed to reconcile indexed asset versions: \(error.safeDiagnosticCode)")
                return .unavailable
            }
        }

        #if DEBUG
        logger.info("[IndexingService] Incomplete index detected: \(totalIndexed)/\(totalInLibrary) indexed, \(unindexedCount) remaining. Auto-resuming.")
        #endif

        return .resume
    }

    // MARK: - Photo Enrichment

    // Aggregate stage durations include overlapping work from two photos.
    private var enrichmentStageSeconds: [String: TimeInterval] = [:]
    private var hasUnpublishedEnrichment = false

    private func measureEnrichment<Value>(
        _ stage: String,
        operation: () async -> Value
    ) async -> Value {
        let start = CFAbsoluteTimeGetCurrent()
        defer { enrichmentStageSeconds[stage, default: 0] += CFAbsoluteTimeGetCurrent() - start }
        return await operation()
    }

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
        guard remaining > 0 else {
            await publishEnrichmentIfNeeded()
            return
        }

        progress = IndexingProgress(
            total: remaining,
            completed: 0,
            isRunning: true,
            phase: .enrichment,
            photosComplete: true,
            searchableCount: searchEngine.totalSize
        )

        var completed = 0
        var lastReload = Date()
        enrichmentStageSeconds = [:]
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            PerformanceMetrics.shared.record(
                "enrichment.elapsed",
                durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
            )
            for (stage, seconds) in enrichmentStageSeconds.sorted(by: { $0.key < $1.key }) {
                PerformanceMetrics.shared.record("enrichment.\(stage)", durationSeconds: seconds)
            }
            logger.info("[Enrichment] Saved \(completed) photo updates; concurrency=\(IndexingConfig.enrichmentConcurrency)")
        }
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

            guard let updates = await PhotoEnrichmentBatchOperation.run(
                candidates: candidates,
                prefetchPhotoKitAssets: { identifiers in
                    await PhotoLibrary.prefetchAssets(localIdentifiers: identifiers)
                },
                enrich: { [weak self] candidate in
                    await self?.enrichPhoto(candidate)
                }
            ) else { return }

            do {
                let db = database
                let batchUpdates = updates
                // Finish this bounded commit even if search cancelled analysis.
                // The indexing queue retains ownership until the commit ends;
                // destructive maintenance waits for that queue to drain.
                let commit = Task.detached(priority: .utility) {
                    try db.updatePhotoEnrichment(batchUpdates)
                }
                try await commit.value
                completed += batchUpdates.count
                hasUnpublishedEnrichment = hasUnpublishedEnrichment
                    || batchUpdates.contains { $0.outcome == .completed }
                guard !Task.isCancelled else { return }
                progress.completed = min(completed, progress.total)
                if Date().timeIntervalSince(lastReload) >= IndexingConfig.enrichmentSearchReloadIntervalSeconds {
                    await publishEnrichmentIfNeeded()
                    lastReload = Date()
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("Failed to update photo enrichment batch: \(error.safeDiagnosticCode)")
                return
            }
        }

        await publishEnrichmentIfNeeded()
    }

    private func publishEnrichmentIfNeeded() async {
        guard hasUnpublishedEnrichment, !Task.isCancelled else { return }
        if await reloadSearchIndex() {
            hasUnpublishedEnrichment = false
        }
    }

    private func enrichPhoto(_ candidate: PhotoEnrichmentCandidate) async -> PhotoEnrichmentUpdate? {
        let image = await measureEnrichment("image_load") {
            await loadImageForEnrichment(candidate, targetSize: CGSize(width: 224, height: 224))
        }
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

        let isScreenshot: Bool
        if candidate.sourceId == PhotoSourceType.photokit.rawValue {
            let asset = await PhotoLibrary.resolveAsset(by: candidate.localIdentifier)
            isScreenshot = asset?.mediaSubtypes.contains(.photoScreenshot) == true
        } else {
            isScreenshot = OCRService.isLikelyScreenshot(
                width: candidate.pixelWidth, height: candidate.pixelHeight
            )
        }
        guard !Task.isCancelled else { return nil }
        var ocrText: String?
        if isScreenshot {
            let fullImage = await measureEnrichment("image_load") {
                await loadImageForEnrichment(
                    candidate,
                    targetSize: CGSize(
                        width: CGFloat(min(candidate.pixelWidth, 2048)),
                        height: CGFloat(min(candidate.pixelHeight, 2048))
                    ),
                    highQuality: true
                )
            }
            guard !Task.isCancelled else { return nil }
            if let fullImage {
                ocrText = await measureEnrichment("accurate_ocr") {
                    await OCRService.extractText(from: fullImage)
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        // Accurate screenshot OCR replaces the quick pass when successful.
        // Other photos share one Vision handler for OCR and classification.
        let analysis = await measureEnrichment("thumbnail_vision") {
            await OCRService.analyzePhoto(image, recognizeText: ocrText?.isEmpty != false)
        }
        guard !Task.isCancelled else { return nil }
        if ocrText?.isEmpty != false { ocrText = analysis.ocrText }
        if let text = ocrText, text.count < 3 { ocrText = nil }

        let sharpness = await measureEnrichment("sharpness") {
            await PhotoEnrichmentTask.run { BlurDetector.sharpnessScore(for: image) }
        }
        guard let sharpness, !Task.isCancelled else { return nil }
        let encodedSceneLabels = SceneClassifier.labelsToString(analysis.sceneLabels)

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
        if BackgroundIndexingController.shared.hasActiveSystemTask {
            #if DEBUG
            logger.info("[IndexingService] UIKit background time expired; scheduled task continues indexing")
            #endif
            // The longer-lived BackgroundTasks assertion now owns execution.
            // End only UIKit's finite transition allowance.
            endBackgroundTask()
        } else if isInitialIndexingExperiencePending {
            #if DEBUG
            logger.warning("[IndexingService] Background time expired; checkpointing initial indexing")
            #endif
            interruptInitialIndexingForSystemExpiration()
        } else {
            #if DEBUG
            logger.warning("[IndexingService] Background time expired; cancelling active indexing workflow")
            #endif
            stopIndexing(preserveThermalResume: false)
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Orphan Cleanup

    private struct OrphanCleanupResult {
        var changedIndex = false
        var invalidatedSuggestions = false
    }

    private func cleanOrphanedEmbeddings() async -> OrphanCleanupResult {
        let mutationState = OSAllocatedUnfairLock(initialState: false)
        var invalidatedSuggestions = false
        do {
            guard PhotoLibraryOrphanCleanupAuthorizationPolicy.allowsCleanup(
                PHPhotoLibrary.authorizationStatus(for: .readWrite)
            ) else {
                #if DEBUG
                logger.info("[IndexingService] Skipping orphan cleanup without full Photos access")
                #endif
                return OrphanCleanupResult()
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
                return OrphanCleanupResult()
            }

            let totalOrphans = orphanedPhotos.count + orphanedVideos.count
            guard totalOrphans > 0 else { return OrphanCleanupResult() }

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
                return OrphanCleanupResult()
            }

            hideValidatedSearchSuggestions()
            invalidatedSuggestions = true

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
                    mutationState.withLock { $0 = true }
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
                    mutationState.withLock { $0 = true }
                }
                try Task.checkCancellation()
                #if DEBUG
                logger.info("Cleaned \(videoDeleteCount) orphaned video embeddings")
                #endif
            }
            return OrphanCleanupResult(
                changedIndex: mutationState.withLock { $0 },
                invalidatedSuggestions: invalidatedSuggestions
            )
        } catch is CancellationError {
            return OrphanCleanupResult(
                changedIndex: mutationState.withLock { $0 },
                invalidatedSuggestions: invalidatedSuggestions
            )
        } catch {
            logger.error("Orphan cleanup failed: \(error.safeDiagnosticCode)")
            return OrphanCleanupResult(
                changedIndex: mutationState.withLock { $0 },
                invalidatedSuggestions: invalidatedSuggestions
            )
        }
    }

    // MARK: - Deferred Location Geocoding

    private func markGeocodingQueued() {
        let current = geocodingProgress
        if let current {
            if current.phase != .queued {
                geocodingProgress = GeocodingProgressState(
                    completed: current.completed,
                    total: current.total,
                    phase: .queued
                )
            }
            return
        }
        geocodingProgress = GeocodingProgressState(
            completed: 0,
            total: 0,
            phase: .queued
        )
        scheduleGeocodingProgressRefresh(phase: .queued)
    }

    private func scheduleGeocodingProgressRefresh(phase: GeocodingProgressPhase) {
        geocodingProgressRefreshTask?.cancel()
        geocodingProgressGeneration += 1
        let generation = geocodingProgressGeneration
        geocodingProgressRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadAndPublishGeocodingProgress(
                phase: phase,
                generation: generation
            )
            if self.geocodingProgressGeneration == generation {
                self.geocodingProgressRefreshTask = nil
            }
        }
    }

    private func refreshGeocodingProgress(phase: GeocodingProgressPhase) async {
        geocodingProgressRefreshTask?.cancel()
        geocodingProgressRefreshTask = nil
        geocodingProgressGeneration += 1
        let generation = geocodingProgressGeneration
        await loadAndPublishGeocodingProgress(phase: phase, generation: generation)
    }

    private func loadAndPublishGeocodingProgress(
        phase: GeocodingProgressPhase,
        generation: Int
    ) async {
        let db = database
        do {
            // This count drives visible completion state. Keep the query off the
            // main actor, but do not let utility work starve it while indexing
            // and model tasks are saturating the device.
            let counts = try await CancellableDetachedOperation.run(priority: .userInitiated) {
                try db.geocodingCounts()
            }
            guard !Task.isCancelled,
                  geocodingProgressGeneration == generation else { return }
            if phase == .queued, geocodingProgress?.phase == .running {
                return
            }
            geocodingProgress = GeocodingProgressState(counts: counts, phase: phase)
        } catch is CancellationError {
            return
        } catch {
            logger.error("[IndexingService] Failed to load geocoding progress: \(error.safeDiagnosticCode)")
        }
    }

    private func publishRunningGeocodingProgress(_ progress: GeocodingProgressSnapshot) {
        geocodingProgressRefreshTask?.cancel()
        geocodingProgressRefreshTask = nil
        geocodingProgressGeneration += 1
        if progress.total > 0, progress.completed >= progress.total {
            clearGeocodingProgress()
            return
        }
        geocodingProgress = GeocodingProgressState(
            completed: progress.completed,
            total: progress.total,
            phase: .running
        )
    }

    private func markGeocodingWaitingToResume() {
        guard let current = geocodingProgress else { return }
        geocodingProgressRefreshTask?.cancel()
        geocodingProgressRefreshTask = nil
        geocodingProgressGeneration += 1
        geocodingProgress = GeocodingProgressState(
            completed: current.completed,
            total: current.total,
            phase: .waitingToResume
        )
    }

    private func clearGeocodingProgress() {
        geocodingProgressRefreshTask?.cancel()
        geocodingProgressRefreshTask = nil
        geocodingProgressGeneration += 1
        cancelGeocodingRetry()
        geocodingRetryAttempt = 0
        geocodingProgress = nil
    }

    private func scheduleGeocodingResumeCheck() {
        cancelGeocodingRetry()
        geocodingRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshGeocodingProgress(phase: .queued)
            guard !Task.isCancelled,
                  self.isApplicationActive,
                  self.geocodingProgress != nil else { return }
            self.geocodingRetryTask = nil
            self.enqueueGeocoding(
                workflowID: UUID(),
                replacingCancelledJob: true
            )
        }
    }

    private func scheduleGeocodingRetry() {
        guard isApplicationActive,
              geocodingProgress != nil,
              geocodingRetryTask == nil else { return }
        guard GeocodingRetryPolicy.allowsAutomaticRetry(
            afterAttempt: geocodingRetryAttempt
        ) else {
            if let current = geocodingProgress {
                geocodingProgress = GeocodingProgressState(
                    completed: current.completed,
                    total: current.total,
                    phase: .paused
                )
            }
            return
        }
        let delay = geocodingRetryDelaySeconds(geocodingRetryAttempt)
        geocodingRetryAttempt += 1
        geocodingRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return
            } catch {
                logger.error("[Geocoder] Retry delay failed: \(error.safeDiagnosticCode)")
                return
            }
            guard let self, self.isApplicationActive else { return }
            self.geocodingRetryTask = nil
            self.enqueueGeocoding(
                workflowID: UUID(),
                replacingCancelledJob: true
            )
        }
    }

    private func cancelGeocodingRetry() {
        geocodingRetryTask?.cancel()
        geocodingRetryTask = nil
    }

    /// Reverse-geocodes indexed photos and videos that have GPS but no location strings yet.
    /// Runs at background priority while the app is active, without blocking search.
    private func geocodeIndexedMedia() async {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            PerformanceMetrics.shared.record(
                PerformancePhase.postIndexGeocoding,
                durationSeconds: CFAbsoluteTimeGetCurrent() - startedAt
            )
        }
        let engine = searchEngine
        let result = await geocodingWorker.run(
            progress: { [weak self] progress in
                self?.publishRunningGeocodingProgress(progress)
            },
            locationsUpdated: { updates in
                engine.applyLocationUpdates(updates)
            }
        )
        if result.wasCancelled {
            return
        }
        if result.changedLocations {
            geocodingRetryAttempt = 0
        }
        await refreshGeocodingProgress(
            phase: isApplicationActive ? .queued : .waitingToResume
        )
        if isApplicationActive, geocodingProgress != nil {
            scheduleGeocodingRetry()
        }
    }

}

enum DuplicatePhotoDeletionError: LocalizedError {
    case assetUnavailable
    case deviceTooWarm

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return "This photo is no longer available in your library."
        case .deviceTooWarm:
            return "Let this iPhone cool down before deleting duplicates."
        }
    }
}

enum DuplicatePhotoDeletionOutcome: Equatable {
    case completed
    case indexRefreshPending
}
