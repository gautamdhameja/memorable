import SwiftUI
import Photos
import os

let logger = Logger(subsystem: "com.blockdeep.memorable", category: "app")

@main
struct MemorableApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    #if DEBUG
                    logger.warning("[App] Memory warning received, dropping search index")
                    #endif
                    appState.handleMemoryWarning()
                }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var readiness = AppReadiness()
    @Published var errorMessage: String?
    @Published var loadingStatus: String = "Preparing your experience..."

    var imageEncoder: ImageEncoder?
    var textEncoder: TextEncoder?
    var searchEngine: SearchEngine?
    var indexingService: IndexingService?
    let semanticRuntime = SemanticSearchRuntime()
    let captionService = PhotoCaptionService()
    private var isInitializing = false
    private var isCoreWarmupRunning = false
    private var currentWarmupPriority: SemanticWarmupPriority = .postPaint
    private var captionPreparationTask: Task<Void, Never>?

    init() {
        SurpriseQueryCache.migrateLegacyDefaults()
        semanticRuntime.setWarmupLoader { [weak self] priority in
            try await self?.warmCoreSearch(priority: priority)
        }
        semanticRuntime.setPromotionHandler { [weak self] in
            self?.currentWarmupPriority = .userInitiatedSearch
        }
    }

    func initialize() async {
        guard !isInitializing && !readiness.isShellReady else { return }
        isInitializing = true
        defer { isInitializing = false }
        #if DEBUG
        PerformanceMetrics.shared.start(PerformancePhase.launchToShell)
        logger.info("[AppState] initialize() started")
        #endif

        authorizationStatus = await PhotoLibrary.requestAuthorization()

        #if DEBUG
        logger.info("[AppState] Photo auth status: \(String(describing: self.authorizationStatus))")
        #endif

        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            if authorizationStatus == .denied || authorizationStatus == .restricted {
                return
            }
            errorMessage = "Photo library access is required to search your photos."
            return
        }

        readiness.markShellReady()
        semanticRuntime.markShellReady()
        loadingStatus = "Preparing search..."

        #if DEBUG
        PerformanceMetrics.shared.end(PerformancePhase.launchToShell)
        #endif
        semanticRuntime.startPostPaintWarmup()
    }

    func handleMemoryWarning() {
        VideoPlaybackCoordinator.shared.cancelForMemoryPressure()
        semanticRuntime.cancelWarmupForMemoryPressure()
        captionPreparationTask?.cancel()
        captionPreparationTask = nil
        indexingService?.cancelAllWorkForMemoryPressure()
        searchEngine?.suspendForMemoryPressure()
        indexingService?.isReady = false
        ProManager.shared.onFreeTierReconciliationNeeded = nil
        captionService.releaseMemory()
        MemoryPressureReleasePolicy.release(&indexingService)
        MemoryPressureReleasePolicy.release(&searchEngine)
        MemoryPressureReleasePolicy.release(&imageEncoder)
        MemoryPressureReleasePolicy.release(&textEncoder)
        readiness.markIndexUnavailable()
        semanticRuntime.markIndexUnavailable()
    }

    func retrySemanticWarmup() {
        errorMessage = nil
        semanticRuntime.startUserInitiatedWarmup()
    }

    private func warmCoreSearch(priority: SemanticWarmupPriority) async throws {
        try Task.checkCancellation()
        guard !isCoreWarmupRunning else { return }
        isCoreWarmupRunning = true
        currentWarmupPriority = priority
        defer { isCoreWarmupRunning = false }

        #if DEBUG
        PerformanceMetrics.shared.start(PerformancePhase.semanticWarmup)
        logger.info("[AppState] Core semantic warmup started, priority=\(String(describing: priority))")
        #endif

        do {
            let search: SearchEngine
            let indexing: IndexingService

            if let existingSearch = searchEngine, let existingIndexing = indexingService {
                search = existingSearch
                indexing = existingIndexing
                Self.resumeExistingSearchForWarmup(search)
                semanticRuntime.markSemanticModelReady()
            } else {
                loadingStatus = "Warming search..."
                semanticRuntime.markSemanticModelWarming()

                // Core ML's async loader cooperates with task cancellation.
                // Avoid wrapping the synchronous initializer in a detached
                // task: that work continues allocating after memory pressure.
                let imgEncoder = try await ImageEncoder()
                try Task.checkCancellation()

                let txtEncoder = try await TextEncoder()
                try Task.checkCancellation()
                search = SearchEngine(textEncoder: txtEncoder)
                indexing = IndexingService(imageEncoder: imgEncoder, searchEngine: search)

                imageEncoder = imgEncoder
                textEncoder = txtEncoder
                searchEngine = search
                indexingService = indexing
                wireIndexingCallbacks(indexing)
                semanticRuntime.markSemanticModelReady()

                // Reconcile local Pro-only state on every verified free-tier
                // launch, including refunds processed while the app was not
                // running or while its semantic stack was suspended.
                ProManager.shared.onFreeTierReconciliationNeeded = { [weak indexing] in
                    await indexing?.reconcileFreeTier()
                }

                // Verify after wiring the callback so a refunded user always
                // has an oversized local index trimmed to the free-tier limit.
                await ProManager.shared.verifyEntitlement()
                try Task.checkCancellation()
            }

            loadingStatus = "Loading searchable memories..."
            let effectivePriority = currentWarmupPriority
            let alreadyPromoted: Bool
            if case .warmingCore(let promoted) = semanticRuntime.phase {
                alreadyPromoted = promoted
            } else {
                alreadyPromoted = false
            }
            semanticRuntime.markIndexWarming(promoted: effectivePriority == .userInitiatedSearch || alreadyPromoted)
            readiness.markSemanticModelReady()
            readiness.markIndexWarming()

            #if DEBUG
            PerformanceMetrics.shared.start(PerformancePhase.indexLoad)
            #endif

            let loadedIndex = await indexing.checkAndLoadExistingIndex(
                scheduleAutoResume: true,
                cleanOrphans: effectivePriority != .userInitiatedSearch,
                loadPriority: effectivePriority == .userInitiatedSearch ? .userInitiated : .utility
            )
            try Task.checkCancellation()
            startPendingOnboardingIndexIfNeeded(using: indexing)

            #if DEBUG
            PerformanceMetrics.shared.end(PerformancePhase.indexLoad)
            #endif

            if loadedIndex {
                if let txtEncoder = textEncoder {
                    startCaptionPreparation(textEncoder: txtEncoder)
                }
            }

            #if DEBUG
            PerformanceMetrics.shared.end(PerformancePhase.semanticWarmup)
            #endif
        } catch is CancellationError {
            #if DEBUG
            logger.info("Semantic warmup cancelled")
            #endif
            throw CancellationError()
        } catch {
            logger.error("Model loading failed: \(error.safeDiagnosticCode)")
            semanticRuntime.markFailure(error.localizedDescription)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    static func resumeExistingSearchForWarmup(_ searchEngine: SearchEngine) {
        searchEngine.resumeAfterMemoryPressure()
    }

    private func startCaptionPreparation(textEncoder: TextEncoder) {
        captionPreparationTask?.cancel()
        captionPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await captionService.prepare(textEncoder: textEncoder)
            guard !Task.isCancelled else { return }
            captionPreparationTask = nil
        }
    }

    private func startPendingOnboardingIndexIfNeeded(using indexing: IndexingService) {
        guard Self.mayConsumePendingOnboardingRequest(isCancelled: Task.isCancelled) else {
            return
        }
        guard UserDefaults.standard.bool(forKey: AppKeys.startIndexAfterOnboarding) else { return }
        UserDefaults.standard.set(false, forKey: AppKeys.startIndexAfterOnboarding)
        guard !indexing.isReady && !indexing.progress.isRunning else { return }
        indexing.startIndexing()
    }

    nonisolated static func mayConsumePendingOnboardingRequest(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    private func wireIndexingCallbacks(_ indexing: IndexingService) {
        indexing.onIndexReady = { [weak self] in
            self?.readiness.markIndexReady()
            self?.semanticRuntime.markIndexReady()
        }
        indexing.onIndexUnavailable = { [weak self] in
            self?.readiness.markIndexUnavailable()
            self?.semanticRuntime.markIndexUnavailable()
        }
    }
}
