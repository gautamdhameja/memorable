import SwiftUI

struct MainTabView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    let captionService: PhotoCaptionService

    @State private var selectedTab = 0

    init(indexingService: IndexingService, searchEngine: SearchEngine, captionService: PhotoCaptionService) {
        self.indexingService = indexingService
        self.searchEngine = searchEngine
        self.captionService = captionService
        UITabBarItem.appearance().badgeColor = UIColor(Celestial.Colors.emerald)
    }

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
                .badge(indexingService.newPhotosAvailable ? "" : nil)
        }
        .tint(Celestial.Colors.primaryDim)
        .preferredColorScheme(.dark)
    }
}
