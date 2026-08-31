import SwiftUI

struct MainTabView: View {
    var indexingService: IndexingService?
    var searchEngine: SearchEngine?
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let captionService: PhotoCaptionService
    let retrySemanticWarmup: () -> Void

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            if let indexingService, let searchEngine {
                SearchView(
                    indexingService: indexingService,
                    searchEngine: searchEngine,
                    semanticRuntime: semanticRuntime,
                    captionService: captionService
                )
                .tabItem {
                    Label("Search", systemImage: "sparkle.magnifyingglass")
                }
                .tag(0)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tabItem {
                        Label("Search", systemImage: "sparkle.magnifyingglass")
                    }
                    .tag(0)
            }

            if indexingService != nil, searchEngine != nil {
                OnThisDayView(captionService: captionService)
                    .tabItem {
                        Label("Memories", systemImage: "calendar")
                    }
                    .tag(1)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tabItem {
                        Label("Memories", systemImage: "calendar")
                    }
                    .tag(1)
            }

            if let indexingService, let searchEngine {
                MoreView(indexingService: indexingService, searchEngine: searchEngine)
                    .tabItem {
                        Label("More", systemImage: "ellipsis")
                    }
                    .tag(2)
                    .badge(indexingService.newPhotosAvailable ? "" : nil)
            } else {
                SemanticWarmupView(semanticRuntime: semanticRuntime, retry: retrySemanticWarmup)
                    .tabItem {
                        Label("More", systemImage: "ellipsis")
                    }
                    .tag(2)
            }
        }
        .tint(Celestial.Colors.primaryDim)
        .preferredColorScheme(.dark)
        .onAppear {
            UITabBarItem.appearance().badgeColor = UIColor(Celestial.Colors.emerald)
        }
    }
}

private struct SemanticWarmupView: View {
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let retry: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Celestial.Colors.background.ignoresSafeArea()
                VStack(spacing: 16) {
                    if case .failed = semanticRuntime.phase {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32, weight: .thin))
                            .foregroundStyle(Celestial.Colors.error)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .tint(Celestial.Colors.primaryDim)
                    }
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    if case .failed = semanticRuntime.phase {
                        Button("Try Again", action: retry)
                            .buttonStyle(CelestialButtonStyle())
                    }
                }
                .padding(.horizontal, 24)
            }
            .navigationTitle("Memorable")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusText: String {
        switch semanticRuntime.phase {
        case .idle:
            return "Preparing search..."
        case .warmingCore(let promoted):
            return promoted ? "Prioritizing search..." : "Warming search..."
        case .waitingForIndex:
            return "Ready to index your photos"
        case .ready:
            return "Search is ready"
        case .failed(let message):
            return message
        }
    }
}
