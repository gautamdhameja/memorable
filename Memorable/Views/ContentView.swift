import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppKeys.onboardingComplete) private var onboardingComplete: Bool = false
    @AppStorage(AppKeys.startIndexAfterOnboarding) private var startIndexAfterOnboarding = false

    var body: some View {
        ZStack {
            CelestialBackdrop()

            if !onboardingComplete {
                OnboardingView(
                    isComplete: $onboardingComplete,
                    startIndexAfterCompletion: onboardingIndexRequestBinding
                )
            } else if appState.authorizationStatus == .denied || appState.authorizationStatus == .restricted {
                photoAccessDeniedView
            } else if appState.readiness.isShellReady {
                MainTabView(
                    indexingService: appState.indexingService,
                    searchEngine: appState.searchEngine,
                    semanticRuntime: appState.semanticRuntime,
                    captionService: appState.captionService,
                    retrySemanticWarmup: appState.retrySemanticWarmup
                )
            } else if let error = appState.errorMessage {
                errorView(message: error)
            } else {
                launchShell
            }
        }
        .preferredColorScheme(.dark)
        .task(id: onboardingComplete) {
            if onboardingComplete {
                appState.setApplicationActive(scenePhase == .active)
                await initializeIfNeeded()
            } else {
                // Let the first onboarding frame paint before Core ML begins
                // loading the bundled models in the background.
                await Task.yield()
                guard !Task.isCancelled else { return }
                updateOnboardingModelPrewarm(for: scenePhase)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if !onboardingComplete {
                if newPhase != .active {
                    appState.recordOnboardingIndexRequest(false, isForeground: false)
                }
                updateOnboardingModelPrewarm(for: newPhase)
                return
            }
            appState.setApplicationActive(newPhase == .active)
            guard newPhase == .active else { return }
            Task { await appState.refreshPhotoAuthorization() }
        }
    }

    // MARK: - Subviews

    private var photoAccessDeniedView: some View {
        VStack(alignment: .leading, spacing: Celestial.Spacing.contentGap) {
            Spacer()
            CelestialGlassIcon(
                systemName: "photo.badge.exclamationmark",
                size: 64
            )
            Text("Photo access is required")
                .font(Celestial.Typography.interfaceTitle)
                .foregroundStyle(Celestial.Colors.onSurface)
            Text("Memorable processes photo and search content on your device. If a photo includes GPS coordinates, Apple may receive those coordinates to return a place name.")
                .font(Celestial.Typography.body)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .celestialPrimaryButtonStyle()
            Spacer()
        }
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: Celestial.Spacing.contentGap) {
            Spacer()
            CelestialGlassIcon(
                systemName: "exclamationmark.triangle",
                tint: Celestial.Colors.error,
                size: 64
            )
            Text("Something went wrong")
                .font(Celestial.Typography.interfaceTitle)
                .foregroundStyle(Celestial.Colors.onSurface)
            Text(message)
                .font(Celestial.Typography.body)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Button("Try Again") {
                appState.errorMessage = nil
                Task { await initializeIfNeeded() }
            }
            .celestialPrimaryButtonStyle()
            Spacer()
        }
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
    }

    /// A static first frame aligned with the home header. Startup authorization
    /// and dependency checks must not resemble photo indexing.
    private var launchShell: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memorable")
                    .font(Celestial.Typography.brand)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Spacer()
            }
            .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
            .padding(.top, 8)

            Spacer()
        }
        .accessibilityHidden(true)
    }

    private func initializeIfNeeded() async {
        guard onboardingComplete else { return }
        if !appState.readiness.isShellReady && appState.errorMessage == nil {
            await appState.initialize()
        }
    }

    private var onboardingIndexRequestBinding: Binding<Bool> {
        Binding(
            get: { startIndexAfterOnboarding },
            set: { requested in
                startIndexAfterOnboarding = requested
                appState.recordOnboardingIndexRequest(
                    requested,
                    isForeground: scenePhase == .active
                )
            }
        )
    }

    private func updateOnboardingModelPrewarm(for phase: ScenePhase) {
        switch OnboardingModelPrewarmPolicy.action(
            onboardingComplete: onboardingComplete,
            sceneIsActive: phase == .active
        ) {
        case .start:
            appState.startOnboardingModelPrewarm()
        case .cancel:
            appState.cancelOnboardingModelPrewarm()
        case .none:
            break
        }
    }
}
