import SwiftUI
import Photos
import os

let logger = Logger(subsystem: "com.blockdeep.memorable", category: "app")

@main
struct MemorableApp: App {
    @StateObject private var appState = AppState()

    init() {
        PhotoLibrary.cleanupAllQuickLookFiles()
    }

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

    init() {
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
        indexingService?.cancelEnrichmentForMemoryPressure()
        searchEngine?.dropIndex()
        indexingService?.isReady = false
        readiness.markIndexUnavailable()
        semanticRuntime.markIndexUnavailable()
    }

    func retrySemanticWarmup() {
        errorMessage = nil
        semanticRuntime.startUserInitiatedWarmup()
    }

    private func warmCoreSearch(priority: SemanticWarmupPriority) async throws {
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
                semanticRuntime.markSemanticModelReady()
            } else {
                loadingStatus = "Warming search..."
                semanticRuntime.markSemanticModelWarming()

                async let imageTask: ImageEncoder = Task.detached {
                    try ImageEncoder()
                }.value
                async let textTask: TextEncoder = Task.detached {
                    try TextEncoder()
                }.value

                let imgEncoder = try await imageTask
                let txtEncoder = try await textTask
                search = await Task.detached {
                    SearchEngine(textEncoder: txtEncoder)
                }.value
                indexing = IndexingService(imageEncoder: imgEncoder, searchEngine: search)

                imageEncoder = imgEncoder
                textEncoder = txtEncoder
                searchEngine = search
                indexingService = indexing
                wireIndexingCallbacks(indexing)
                semanticRuntime.markSemanticModelReady()

                // Wire up refund handler: trim index to free tier limit
                ProManager.shared.onProRevoked = { [weak self] in
                    do {
                        try AppDatabase.shared.trimToLimit(FreeTier.maxIndexedMedia)
                        try search.loadIndex()
                        self?.indexingService?.indexVersion += 1
                    } catch {
                        logger.error("Failed to trim index after refund: \(error.localizedDescription)")
                    }
                }

                // ProManager.init() fires verifyEntitlement on launch to detect
                // refunds, but that Task may complete before the callback above
                // is set, losing the trim. Re-verify now that the callback is
                // wired so a refunded user always gets their index trimmed.
                await ProManager.shared.verifyEntitlement()
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

            #if DEBUG
            PerformanceMetrics.shared.end(PerformancePhase.indexLoad)
            #endif

            if loadedIndex {
                if let txtEncoder = textEncoder {
                    Task { @MainActor in
                        await self.captionService.prepare(textEncoder: txtEncoder)
                    }
                }
            }

            #if DEBUG
            PerformanceMetrics.shared.end(PerformancePhase.semanticWarmup)
            #endif
        } catch {
            logger.error("Model loading failed: \(error.localizedDescription)")
            semanticRuntime.markFailure(error.localizedDescription)
            errorMessage = error.localizedDescription
            throw error
        }
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
