import SwiftUI

struct MainTabView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    let captionService: PhotoCaptionService

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            SearchView(indexingService: indexingService, searchEngine: searchEngine, captionService: captionService)
                .tabItem {
                    Label("Search", systemImage: "sparkle.magnifyingglass")
                }
                .tag(0)

            OnThisDayView(captionService: captionService)
                .tabItem {
                    Label("Memories", systemImage: "memories")
                }
                .tag(1)

            MoreView(indexingService: indexingService, searchEngine: searchEngine)
                .tabItem {
                    Label("More", systemImage: "square.grid.2x2")
                }
                .tag(2)
        }
        .tint(Celestial.Colors.primaryDim)
        .preferredColorScheme(.dark)
    }
}
