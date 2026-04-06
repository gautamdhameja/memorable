import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var modelDownloader = ModelDownloader()
    @State private var onboardingComplete = UserDefaults.standard.bool(forKey: AppKeys.onboardingComplete)

    var body: some View {
        ZStack {
            Celestial.Colors.background.ignoresSafeArea()

            if !onboardingComplete {
                OnboardingView(isComplete: $onboardingComplete)
            } else if !modelDownloader.isDownloaded {
                modelDownloadView
            } else if appState.authorizationStatus == .denied || appState.authorizationStatus == .restricted {
                photoAccessDeniedView
            } else if appState.isModelLoaded, let indexingService = appState.indexingService,
                      let searchEngine = appState.searchEngine {
                MainTabView(indexingService: indexingService, searchEngine: searchEngine, captionService: appState.captionService)
            } else if let error = appState.errorMessage {
                errorView(message: error)
            } else {
                loadingView
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            modelDownloader.checkAndDownloadModels()
        }
        .onChange(of: modelDownloader.isDownloaded) {
            if modelDownloader.isDownloaded {
                Task {
                    await appState.initialize()
                }
            }
        }
    }

    // MARK: - Subviews

    private var modelDownloadView: some View {
        VStack(spacing: 24) {
            if let error = modelDownloader.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(Celestial.Colors.error)
                    .accessibilityHidden(true)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .padding(.horizontal)
                Button("Retry Download") {
                    modelDownloader.errorMessage = nil
                    modelDownloader.checkAndDownloadModels()
                }
                .buttonStyle(CelestialButtonStyle())
            } else {
                Spacer()
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 56, weight: .thin))
                    .foregroundStyle(Celestial.Colors.primaryDim)
                    .accessibilityHidden(true)
                Text("Downloading AI Models")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text("One-time download (~300 MB)")
                    .font(.subheadline)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                ProgressView(value: modelDownloader.downloadProgress)
                    .tint(Celestial.Colors.primaryFixedDim)
                    .padding(.horizontal, 48)
                    .padding(.top, 8)
                Text("\(Int(modelDownloader.downloadProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .accessibilityLabel("Download progress: \(Int(modelDownloader.downloadProgress * 100)) percent")
                Spacer()
            }
        }
    }

    private var photoAccessDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Celestial.Colors.primaryDim)
                .accessibilityHidden(true)
            Text("Photo Access Required")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Celestial.Colors.onSurface)
            Text("Memorable needs access to your photos to build a searchable index. All processing happens on your device.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(CelestialButtonStyle())
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Celestial.Colors.error)
                .accessibilityHidden(true)
            Text("Something Went Wrong")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(Celestial.Colors.onSurface)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .padding(.horizontal, 32)
            Button("Try Again") {
                appState.errorMessage = nil
                Task { await appState.initialize() }
            }
            .buttonStyle(CelestialButtonStyle())
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 10) {
                Image("AppIconTransparent")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 150, height: 150)

                Text("Memorable")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Celestial.Colors.onSurface)

                Text("Every moment, one search away")
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(Celestial.Colors.amber)
            }

            Spacer()

            ProgressView()
                .tint(Celestial.Colors.primaryDim)
                .controlSize(.regular)

            Text("Preparing your experience...")
                .font(.footnote)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)

            Spacer()
                .frame(height: 60)
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
            .padding(.vertical, 12)
            .background(Celestial.Colors.primaryContainer)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
