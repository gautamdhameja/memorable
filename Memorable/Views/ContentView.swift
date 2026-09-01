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
                    startIndexAfterCompletion: $startIndexAfterOnboarding
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
                loadingView
            }
        }
        .preferredColorScheme(.dark)
        .task(id: onboardingComplete) {
            if onboardingComplete {
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
                updateOnboardingModelPrewarm(for: newPhase)
                return
            }
            guard newPhase == .active, onboardingComplete else { return }
            Task { await appState.refreshPhotoAuthorization() }
        }
    }

    // MARK: - Subviews

    private var photoAccessDeniedView: some View {
        VStack(alignment: .leading, spacing: 18) {
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
            .buttonStyle(CelestialButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 26)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
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
            .buttonStyle(CelestialButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 26)
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Celestial.Colors.primaryDim.opacity(0.18), lineWidth: 1)
                    .frame(width: 142, height: 142)
                Circle()
                    .stroke(Celestial.Colors.primaryDim, lineWidth: 2)
                    .frame(width: 48, height: 48)
                Capsule()
                    .fill(Celestial.Colors.primaryDim)
                    .frame(width: 32, height: 3)
                    .rotationEffect(.degrees(45))
                    .offset(x: 28, y: 28)
                Circle()
                    .fill(Celestial.Colors.amber)
                    .frame(width: 6, height: 6)
                    .offset(x: 71)
            }
            .modifier(
                GlassCircleModifier(
                    tint: Celestial.Colors.primaryDim.opacity(0.08),
                    interactive: false
                )
            )

            Text("Memorable")
                .font(Celestial.Typography.display)
                .foregroundStyle(Celestial.Colors.onSurface)

            Spacer()

            ProgressView()
                .tint(Celestial.Colors.primaryDim)
                .controlSize(.regular)

            Text(appState.loadingStatus)
                .font(Celestial.Typography.footnote)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .animation(.easeInOut(duration: 0.2), value: appState.loadingStatus)

            Spacer().frame(height: 40)
        }
    }

    private func initializeIfNeeded() async {
        guard onboardingComplete else { return }
        if !appState.readiness.isShellReady && appState.errorMessage == nil {
            await appState.initialize()
        }
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
