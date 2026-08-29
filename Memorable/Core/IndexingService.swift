import Foundation
import Photos
import UIKit
import os

private let hitFreeLimitKey = "indexing.hitFreeLimit"
private let reachedDeviceIndexLimitKey = "indexing.reachedDeviceIndexLimit"

private enum PhotoLibraryChangeScanResult: Sendable {
    case none
    case newPhotos
    case orphanedPhotos(Set<String>)
}

enum ThermalIndexingEffect: Equatable {
    case none
    case cancelWork
    case restartWork
}

struct ThermalIndexingState: Equatable {
    var isPaused = false
    var resumeWhenCool = false
}

enum ThermalSafetyPolicy {
    static func shouldPause(for state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    static func transition(
        from current: ThermalIndexingState,
        thermalState: ProcessInfo.ThermalState,
        hasActiveWork: Bool
    ) -> (state: ThermalIndexingState, effect: ThermalIndexingEffect) {
        if shouldPause(for: thermalState) {
            guard current.isPaused || current.resumeWhenCool || hasActiveWork else {
                return (current, .none)
            }
            return (
                ThermalIndexingState(
                    isPaused: true,
                    resumeWhenCool: current.resumeWhenCool || hasActiveWork
                ),
                hasActiveWork ? .cancelWork : .none
            )
        }
        guard current.isPaused else { return (current, .none) }
        return (
            ThermalIndexingState(),
            current.resumeWhenCool ? .restartWork : .none
        )
    }
}

private final class NotificationObservation: @unchecked Sendable {
    private let token: OSAllocatedUnfairLock<NSObjectProtocol?>

    init(token: NSObjectProtocol) {
        self.token = OSAllocatedUnfairLock(uncheckedState: token)
    }

    func cancel() {
        let token = token.withLockUnchecked { stored in
            defer { stored = nil }
            return stored
        }
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}

enum ProRevocationOperation {
    static func run<Result: Sendable>(
        trim: @escaping @Sendable () throws -> Result,
        reload: @MainActor @escaping (Result) async -> Void
    ) async throws {
        let trimTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try trim()
        }
        let result = try await withTaskCancellationHandler {
            try await trimTask.value
        } onCancel: {
            trimTask.cancel()
        }
        try Task.checkCancellation()
        await reload(result)
    }
}

@MainActor
enum IndexingStorageMutation {
    static func run(
        waitForIdle: () async -> Void,
        mutation: @escaping @Sendable () throws -> Void,
        completion: () async throws -> Void
    ) async throws {
        await waitForIdle()
        try Task.checkCancellation()
        try await CancellableDetachedOperation.run(priority: .userInitiated, mutation)
        try Task.checkCancellation()
        try await completion()
    }
}

enum PhotoEnrichmentTask {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let task = Task.detached(priority: .utility) { () -> Value? in
            guard !Task.isCancelled else { return nil }
            let value = await operation()
            guard !Task.isCancelled else { return nil }
            return value
        }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return Task.isCancelled ? nil : value
    }
}

@MainActor
enum ProFolderIndexingOperation {
    static func run(
        isEntitled: () -> Bool,
        operation: () async -> Void
    ) async -> IndexingJobOutcome {
        guard isEntitled() else { return .cancelled }
        await operation()
        return Task.isCancelled ? .cancelled : .completed
    }
}

protocol PhotoChangeObservationRegistrar: AnyObject {
    func register(_ observer: PHPhotoLibraryChangeObserver)
    func unregister(_ observer: PHPhotoLibraryChangeObserver)
}

private final class SystemPhotoChangeObservationRegistrar: PhotoChangeObservationRegistrar {
    func register(_ observer: PHPhotoLibraryChangeObserver) {
        PHPhotoLibrary.shared().register(observer)
    }

    func unregister(_ observer: PHPhotoLibraryChangeObserver) {
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
    }
}

final class PhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let callback = OSAllocatedUnfairLock<(@MainActor @Sendable () -> Void)?>(
        initialState: nil
    )
    private let observing = OSAllocatedUnfairLock(initialState: false)
    private let registrar: PhotoChangeObservationRegistrar

    override convenience init() {
        self.init(registrar: SystemPhotoChangeObservationRegistrar())
    }

    init(registrar: PhotoChangeObservationRegistrar) {
        self.registrar = registrar
        super.init()
    }

    var onNewPhotosDetected: (@MainActor @Sendable () -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    func startObserving() {
        let shouldRegister = observing.withLock { isObserving in
            guard !isObserving else { return false }
            isObserving = true
            return true
        }
        guard shouldRegister else { return }
        registrar.register(self)
    }

    func stopObserving() {
        let shouldUnregister = observing.withLock { isObserving in
            guard isObserving else { return false }
            isObserving = false
            return true
        }
        callback.withLock { $0 = nil }
        guard shouldUnregister else { return }
        registrar.unregister(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let callback = callback.withLock { $0 }
        DispatchQueue.main.async {
            callback?()
        }
    }

    deinit {
        stopObserving()
    }
}

struct IndexingBatchCursor<Item> {
    private let items: [Item]
    private let batchSize: Int
    private var nextIndex = 0

    init(items: [Item], batchSize: Int) {
        self.items = items
        self.batchSize = max(1, batchSize)
    }

    var hasRemaining: Bool {
        nextIndex < items.count
    }

    mutating func nextBatch(maxCount: Int? = nil) -> [Item] {
        guard hasRemaining else { return [] }
        let requestedCount = maxCount.map { min(batchSize, max(0, $0)) } ?? batchSize
        guard requestedCount > 0 else { return [] }
        let batchEnd = min(nextIndex + requestedCount, items.count)
        let batch = Array(items[nextIndex..<batchEnd])
        nextIndex = batchEnd
        return batch
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
    @Published var reachedDeviceIndexLimit: Bool = UserDefaults.standard.bool(forKey: reachedDeviceIndexLimitKey) {
        didSet {
            UserDefaults.standard.set(reachedDeviceIndexLimit, forKey: reachedDeviceIndexLimitKey)
        }
    }
    @Published private(set) var isThermallyPaused = false
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
    private var photoChangeCheckTask: Task<Void, Never>?
    private var proRevocationTask: Task<Void, Never>?
    private var activeProReconciliationID: UUID?
    private var storageMutationTask: Task<Void, Error>?
    private var activeStorageMutationID: UUID?
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
            setReachedDeviceIndexLimit: { [weak self] in self?.reachedDeviceIndexLimit = $0 },
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
            setReachedDeviceIndexLimit: { [weak self] in self?.reachedDeviceIndexLimit = $0 },
            reloadSearchIndex: { [weak self] in _ = await self?.reloadSearchIndex() }
        )
    )

    init(imageEncoder: ImageEncoder, searchEngine: SearchEngine, database: DatabaseProtocol = AppDatabase.shared) {
        self.imageEncoder = imageEncoder
        self.searchEngine = searchEngine
        self.database = database
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
        guard !Task.isCancelled else { return false }
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

                if cleanOrphans {
                    let allMedia = try await CancellableDetachedOperation.run(priority: loadPriority) {
                        PhotoLibrary.fetchAllMedia()
                    }
                    launchLibraryCountSnapshot = allMedia.count
                    await enqueueAndWaitForOrphanCleanup(allMedia: allMedia)
                    try Task.checkCancellation()
                }

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
        photoChangeCheckTask?.cancel()
        photoChangeCheckTask = nil
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
        storageMutationTask?.cancel()
        stopObservingPhotoChanges()
        proRevocationTask?.cancel()
        proRevocationTask = nil
        activeProReconciliationID = nil
        photoChangeCheckTask?.cancel()
        photoChangeCheckTask = nil
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
            }
            return await ProFolderIndexingOperation.run(
                isEntitled: { ProManager.shared.isPro }
            ) {
                self.beginBackgroundTask()
                defer {
                    self.endBackgroundTask()
                    self.progress.isRunning = false
                }
                await self.folderWorker.index(url: url, name: name)
                guard !Task.isCancelled else { return }
                self.enqueueEnrichment(workflowID: workflowID)
                if shouldResumeGeocoding {
                    self.enqueueGeocoding(workflowID: workflowID)
                }
            }
        })
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
                mutation: { try db.deleteAll() },
                completion: {
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
        proRevocationTask?.cancel()
        let reconciliationID = UUID()
        activeProReconciliationID = reconciliationID
        let task = Task { [weak self] in
            guard let self else { return }
            jobQueue.cancelAll()
            await jobQueue.waitUntilIdle()
            let db = database
            do {
                try await ProRevocationOperation.run(
                    trim: {
                        try db.reconcileFreeTier(FreeTier.maxIndexedMedia)
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
                        self.reachedDeviceIndexLimit = false
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
        changeObserver.onNewPhotosDetected = { [weak self] in
            Task { @MainActor in self?.checkForNewPhotos() }
        }
        changeObserver.startObserving()
        isObservingPhotoChanges = true
    }

    private func stopObservingPhotoChanges() {
        guard isObservingPhotoChanges else { return }
        changeObserver.stopObserving()
        isObservingPhotoChanges = false
    }

    private func checkForNewPhotos() {
        guard !progress.isRunning, photoChangeCheckTask == nil else { return }
        let db = database
        let engine = searchEngine
        photoChangeCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { photoChangeCheckTask = nil }
            let scanTask = Task.detached(priority: .utility) {
                let totalIndexed = try db.photoLibraryIndexedMediaCounts().total
                let allMedia = PhotoLibrary.fetchAllMedia()
                let totalInLibrary = allMedia.count

                if totalInLibrary > totalIndexed {
                    return PhotoLibraryChangeScanResult.newPhotos
                }
                guard totalInLibrary < totalIndexed else { return .none }
                guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .limited else {
                    return .none
                }

                var orphaned = try db.allIndexedIdentifiers()
                for index in 0..<allMedia.count {
                    if index.isMultiple(of: 256) { try Task.checkCancellation() }
                    orphaned.remove(allMedia.object(at: index).localIdentifier)
                }
                guard !orphaned.isEmpty, orphaned.count < totalIndexed / 2 else { return .none }
                return .orphanedPhotos(orphaned)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await scanTask.value
                } onCancel: {
                    scanTask.cancel()
                }
                guard !Task.isCancelled else { return }
                switch result {
                case .none:
                    break
                case .newPhotos:
                    newPhotosAvailable = true
                case .orphanedPhotos(let orphaned):
                    enqueueLightweightOrphanCleanup(
                        orphanedPhotoIDs: orphaned,
                        database: db,
                        searchEngine: engine
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
                        try db.deleteAll()
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
        _ = searchEngine
        jobQueue.enqueue(IndexingJob(
            workflowID: UUID(),
            kind: .cleanOrphans,
            priority: .maintenance
        ) { [weak self] in
            guard let self else { return .cancelled }
            do {
                let deleteTask = Task.detached(priority: .utility) {
                    try database.deleteOrphanedPhotos(localIdentifiers: orphanedPhotoIDs)
                }
                try await withTaskCancellationHandler {
                    try await deleteTask.value
                } onCancel: {
                    deleteTask.cancel()
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
        let totalInLibrary = providedTotal ?? PhotoLibrary.fetchAllMedia().count

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
            return await FolderImageLoadOperation.run {
                FolderScanner.loadImageFromBookmarkedSource(
                    filePath: filePath,
                    sourceId: candidate.sourceId,
                    targetSize: targetSize
                )
            }
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
            let db = database
            let indexedIdentifiers = try await CancellableDetachedOperation.run {
                try db.allIndexedMediaIdentifiers()
            }
            try Task.checkCancellation()
            let scanTask = Task.detached(priority: .utility) {
                var orphanedPhotos = indexedIdentifiers.photos
                var orphanedVideos = indexedIdentifiers.videos
                let media = allMedia ?? PhotoLibrary.fetchAllMedia()
                for i in 0..<media.count {
                    if i.isMultiple(of: 256) { try Task.checkCancellation() }
                    let identifier = media[i].localIdentifier
                    orphanedPhotos.remove(identifier)
                    orphanedVideos.remove(identifier)
                    if orphanedPhotos.isEmpty && orphanedVideos.isEmpty { break }
                }
                return (orphanedPhotos, orphanedVideos)
            }
            let (orphanedPhotos, orphanedVideos) = try await withTaskCancellationHandler {
                try await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            try Task.checkCancellation()
            let indexedPhotoIds = indexedIdentifiers.photos
            let indexedVideoIds = indexedIdentifiers.videos

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
                try Task.checkCancellation()
                let photoIDsToDelete = orphanedPhotos
                let photoDeleteCount = photoIDsToDelete.count
                try await CancellableDetachedOperation.run {
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
                    try db.deleteOrphanedVideos(localIdentifiers: videoIDsToDelete)
                }
                try Task.checkCancellation()
                #if DEBUG
                logger.info("Cleaned \(videoDeleteCount) orphaned video embeddings")
                #endif
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("Orphan cleanup failed: \(error.safeDiagnosticCode)")
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
            counts = try await CancellableDetachedOperation.run {
                try db.geocodingCounts()
            }
        } catch is CancellationError {
            geocodingProgress = nil
            return
        } catch {
            logger.error("[Geocoder] Failed to load geocoding counts: \(error.safeDiagnosticCode)")
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
                try await CancellableDetachedOperation.run {
                    try db.photosNeedingLocationBackfill(limit: 500)
                }
            },
            updateLocation: { localIdentifier, location in
                try await CancellableDetachedOperation.run {
                    try db.updatePhotoLocationStrings(
                        localIdentifier: localIdentifier,
                        city: location.city,
                        state: location.state,
                        country: location.country,
                        name: location.name
                    )
                }
            }
        )
        if photoResult.cancelled { return }

        let videoResult = await geocodeMediaSource(
            label: "videos",
            progressBase: alreadyGeocoded + photoResult.completed,
            fetchBatch: {
                try await CancellableDetachedOperation.run {
                    try db.videosNeedingLocationBackfill(limit: 500)
                }
            },
            updateLocation: { localIdentifier, location in
                try await CancellableDetachedOperation.run {
                    try db.updateVideoLocationStrings(
                        localIdentifier: localIdentifier,
                        city: location.city,
                        state: location.state,
                        country: location.country,
                        name: location.name
                    )
                }
            }
        )
        if videoResult.cancelled { return }
        let totalGeocoded = photoResult.completed + videoResult.completed

        #if DEBUG
        logger.info("[Geocoder] Completed: \(totalGeocoded) media items geocoded")
        #endif
        if totalGeocoded > 0 {
            _ = await reloadSearchIndex()
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
            } catch is CancellationError {
                return (completed, true)
            } catch {
                logger.error("[Geocoder] Failed to fetch \(label) backfill batch: \(error.safeDiagnosticCode)")
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
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return (completed, true)
                } catch {
                    failedIdentifiers.insert(candidate.localIdentifier)
                    logger.error("[Geocoder] Failed to update a \(label) location: \(error.safeDiagnosticCode)")
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
                    logger.info("[Geocoder] Completed \(label) item #\(completed)")
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
