import SwiftUI
import Photos
import os

let logger = Logger(subsystem: "com.blockdeep.memorable", category: "app")

@main
struct MemorableApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isDeviceSupported {
                    ContentView()
                } else {
                    UnsupportedDeviceView()
                }
            }
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

private struct UnsupportedDeviceView: View {
    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                Image(systemName: "iphone.slash")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Celestial.Colors.error)
                    .accessibilityHidden(true)
                Text("This iPhone is not supported")
                    .font(.title.bold())
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text(DeviceCompatibility.unsupportedMessage)
                    .font(.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Text("The app does not start photo access, indexing, or AI models on this device.")
                    .font(.subheadline)
                    .foregroundStyle(Celestial.Colors.outline)
                Spacer()
            }
            .padding(.horizontal, 26)
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
class AppState: ObservableObject {
    private struct PrewarmedModels {
        let imageEncoder: ImageEncoder
        let textEncoder: TextEncoder
    }

    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var readiness = AppReadiness()
    @Published var errorMessage: String?
    @Published var loadingStatus: String = "Preparing your experience..."
    @Published private(set) var isDeviceSupported: Bool

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
    private var modelPrewarmTask: Task<PrewarmedModels, Error>?
    private var modelPrewarmGeneration: UInt64 = 0
    private let requestPhotoAuthorization: () async -> PHAuthorizationStatus
    private let currentPhotoAuthorization: () -> PHAuthorizationStatus
    private let deviceSupportProvider: () -> Bool

    init(
        shareItemCleanup: @escaping @Sendable () -> Void = { PhotoLibrary.cleanupShareItems() },
        requestPhotoAuthorization: @escaping () async -> PHAuthorizationStatus = {
            await PhotoLibrary.requestAuthorization()
        },
        currentPhotoAuthorization: @escaping () -> PHAuthorizationStatus = {
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        },
        isDeviceSupported: @escaping () -> Bool = {
            DeviceCompatibility.isCurrentDeviceSupported
        }
    ) {
        MainThreadResponsivenessMonitor.shared.start()
        self.requestPhotoAuthorization = requestPhotoAuthorization
        self.currentPhotoAuthorization = currentPhotoAuthorization
        self.deviceSupportProvider = isDeviceSupported
        self.isDeviceSupported = isDeviceSupported()
        Task.detached(priority: .background) {
            shareItemCleanup()
            SurpriseQueryCache.migrateLegacyDefaults()
        }
        semanticRuntime.setWarmupLoader { [weak self] priority in
            try await self?.warmCoreSearch(priority: priority)
        }
        semanticRuntime.setPromotionHandler { [weak self] in
            self?.currentWarmupPriority = .userInitiatedSearch
        }
    }

    func initialize() async {
        await initialize(knownAuthorizationStatus: nil)
    }

    func refreshPhotoAuthorization() async {
        guard isDeviceSupported else { return }
        let refreshedStatus = currentPhotoAuthorization()
        if authorizationStatus != refreshedStatus {
            authorizationStatus = refreshedStatus
        }
        guard PhotoAuthorizationRecoveryPolicy.shouldInitialize(
            authorizationStatus: refreshedStatus,
            isShellReady: readiness.isShellReady,
            isInitializing: isInitializing
        ) else { return }
        await initialize(knownAuthorizationStatus: refreshedStatus)
    }

    private func initialize(knownAuthorizationStatus: PHAuthorizationStatus?) async {
        guard !isInitializing && !readiness.isShellReady else { return }
        isDeviceSupported = deviceSupportProvider()
        guard isDeviceSupported else { return }
        isInitializing = true
        defer { isInitializing = false }
        #if DEBUG
        PerformanceMetrics.shared.start(PerformancePhase.launchToShell)
        logger.info("[AppState] initialize() started")
        #endif

        if let knownAuthorizationStatus {
            authorizationStatus = knownAuthorizationStatus
        } else {
            authorizationStatus = await requestPhotoAuthorization()
        }

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
        PhotoLibrary.clearAssetCache()
        semanticRuntime.cancelWarmupForMemoryPressure()
        cancelModelPrewarm()
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

    /// Starts loading only the two bundled Core ML models. This intentionally
    /// avoids Photos authorization, StoreKit, database access, and indexing so
    /// it is safe to run behind the first onboarding screen.
    func startOnboardingModelPrewarm() {
        guard isDeviceSupported,
              imageEncoder == nil,
              textEncoder == nil,
              modelPrewarmTask == nil else { return }

        modelPrewarmGeneration &+= 1
        let generation = modelPrewarmGeneration
        let task = Task { @MainActor in
            async let imageEncoder = ImageEncoder()
            async let textEncoder = TextEncoder()
            let models = try await (imageEncoder, textEncoder)
            try Task.checkCancellation()
            return PrewarmedModels(
                imageEncoder: models.0,
                textEncoder: models.1
            )
        }
        modelPrewarmTask = task

        Task { @MainActor [weak self] in
            do {
                let models = try await task.value
                guard let self,
                      self.modelPrewarmGeneration == generation,
                      !Task.isCancelled else { return }
                self.installPrewarmedModels(models)
                self.modelPrewarmTask = nil
                #if DEBUG
                logger.info("[AppState] Onboarding model prewarm completed")
                #endif
            } catch is CancellationError {
                guard let self, self.modelPrewarmGeneration == generation else { return }
                self.modelPrewarmTask = nil
                #if DEBUG
                logger.info("[AppState] Onboarding model prewarm cancelled")
                #endif
            } catch {
                guard let self, self.modelPrewarmGeneration == generation else { return }
                self.modelPrewarmTask = nil
                logger.error("[AppState] Onboarding model prewarm failed: \(error.safeDiagnosticCode)")
            }
        }
    }

    /// Called only while onboarding is incomplete. If prewarming already
    /// finished, release those models as well so backgrounding first run does
    /// not retain a large cache the user has not committed to using yet.
    func cancelOnboardingModelPrewarm() {
        guard searchEngine == nil, indexingService == nil else { return }
        cancelModelPrewarm()
        MemoryPressureReleasePolicy.release(&imageEncoder)
        MemoryPressureReleasePolicy.release(&textEncoder)
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

                async let modelsTask = prewarmedModelsForSearch()
                async let databaseTask = CancellableDetachedOperation.run(priority: .userInitiated) {
                    AppDatabase.shared as any DatabaseProtocol
                }
                let (models, database) = try await (modelsTask, databaseTask)
                try Task.checkCancellation()
                let imgEncoder = models.imageEncoder
                let txtEncoder = models.textEncoder
                search = SearchEngine(textEncoder: txtEncoder, database: database)
                indexing = IndexingService(
                    imageEncoder: imgEncoder,
                    searchEngine: search,
                    database: database
                )

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
                scheduleOrphanCleanup: effectivePriority != .userInitiatedSearch,
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

    private func prewarmedModelsForSearch() async throws -> PrewarmedModels {
        if let imageEncoder, let textEncoder {
            return PrewarmedModels(imageEncoder: imageEncoder, textEncoder: textEncoder)
        }

        startOnboardingModelPrewarm()
        guard let task = modelPrewarmTask else { throw CancellationError() }
        let models = try await task.value
        try Task.checkCancellation()
        installPrewarmedModels(models)
        return models
    }

    private func installPrewarmedModels(_ models: PrewarmedModels) {
        imageEncoder = models.imageEncoder
        textEncoder = models.textEncoder
    }

    private func cancelModelPrewarm() {
        modelPrewarmGeneration &+= 1
        modelPrewarmTask?.cancel()
        modelPrewarmTask = nil
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
