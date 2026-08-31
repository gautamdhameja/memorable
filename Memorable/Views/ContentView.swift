import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppKeys.onboardingComplete) private var onboardingComplete: Bool = false
    @AppStorage(AppKeys.startIndexAfterOnboarding) private var startIndexAfterOnboarding = false

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

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
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Celestial.Colors.primaryDim)
                .accessibilityHidden(true)
            Text("Photo access is required")
                .font(.title.bold())
                .foregroundStyle(Celestial.Colors.onSurface)
            Text("Memorable processes photo and search content on your device. If a photo includes GPS coordinates, Apple may receive those coordinates to return a place name.")
                .font(.body)
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
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Celestial.Colors.error)
                .accessibilityHidden(true)
            Text("Something went wrong")
                .font(.title.bold())
                .foregroundStyle(Celestial.Colors.onSurface)
            Text(message)
                .font(.body)
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

            Text("Memorable")
                .font(.largeTitle.bold())
                .foregroundStyle(Celestial.Colors.onSurface)

            Spacer()

            ProgressView()
                .tint(Celestial.Colors.primaryDim)
                .controlSize(.regular)

            Text(appState.loadingStatus)
                .font(.footnote)
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

// MARK: - Celestial Button Style

struct CelestialButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(Celestial.Colors.onPrimaryContainer)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Celestial.Colors.primaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
