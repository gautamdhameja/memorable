import SwiftUI
import Photos
import AVKit

private enum SortMode: String {
    case relevance
    case recent
}

private enum MediaFilter: String, CaseIterable {
    case all
    case photos
    case videos
    case screenshots

    var label: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .screenshots: return "Screenshots"
        }
    }
}

struct SearchView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let captionService: PhotoCaptionService

    @State private var searchText = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var selectedPhoto: SearchResult?
    @State private var searchError: String?
    // Tracks the query string that produced the current `results`. Used so the
    // "no results" view only appears after a search has actually completed for
    // the text currently in the field, not while the user is mid-typing.
    @State private var lastSearchedQuery: String?
    @State private var showUpgrade = false
    @State private var showSaveAlbum = false
    @State private var albumName = ""
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchHistory: [String] = []
    @State private var smartAlbums: [SmartAlbum] = []
    @State private var totalLibraryCount: Int = 0
    @State private var searchTimeMs: Int = 0
    @State private var fallbackResults: [SearchResult] = []
    @State private var filterSummary: FilterSummary?
    @State private var placeholderIndex: Int = 0
    @State private var placeholderTimer: Task<Void, Never>?
    @State private var searchSequence: Int = 0
    @State private var activeSearchID: Int?

    // Persisted sort mode. Stored as rawValue because @AppStorage doesn't
    // support RawRepresentable enums directly.
    @AppStorage("searchSortMode") private var sortModeRaw: String = SortMode.relevance.rawValue
    private var sortMode: SortMode {
        SortMode(rawValue: sortModeRaw) ?? .relevance
    }

    // Progressive reveal: engine returns every matching result, UI windows to
    // `initialVisibleCount` until the user taps "Show all N matching results".
    private let initialVisibleCount = 50
    @State private var visibleCount: Int = 50

    // Tracks the in-flight submitted search. Text edits do not cancel a submitted
    // query; only a newer submitted query supersedes an older one.
    @State private var searchTask: Task<Void, Never>?

    // Media type filter (All / Photos / Videos / Screenshots)
    @State private var mediaFilter: MediaFilter = .all
    @State private var screenshotIds: Set<String> = []

    // Post-search upgrade flow (free tier)
    @State private var hasCompletedFirstSearch = false
    @State private var searchesSinceDismiss = 0
    @State private var upgradeBannerDismissed = false

    private static let placeholders = [
        "Search for your moment...",
        "Describe your memory...",
        "What are you looking for?",
        "Try \"sunset at the beach\"...",
        "Try \"birthday cake\"...",
    ]

    // Last successful search — shown when search box is cleared
    @State private var lastQuery: String = ""
    @State private var lastResults: [SearchResult] = []

    private var currentDisplayedResults: [SearchResult] {
        if !results.isEmpty { return results }
        if !lastResults.isEmpty { return lastResults }
        return []
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Celestial.Colors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar pinned at top
                    searchBar
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 14)

                    // Database warning
                    if AppDatabase.isInMemoryFallback {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Celestial.Colors.error)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Storage issue")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                Text("Your search index won't be saved between sessions. Free up device storage.")
                                    .font(.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                        }
                        .padding(16)
                        .modifier(GlassPanelModifier(cornerRadius: 16))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }

                    // Sticky controls panel (above scroll)
                    if !searchText.isEmpty && !results.isEmpty && !isSearching {
                        let filtered = applyMediaFilter(applySort(results, mode: sortMode))
                        #if DEBUG
                        let _ = debugLogControlsPanel(filteredCount: filtered.count)
                        #endif
                        controlsPanel(filteredCount: filtered.count)
                    }

                    ScrollView {
                    VStack(spacing: 0) {
                        // Indexing banners
                        if indexingService.progress.isRunning {
                            IndexingBannerView(indexingService: indexingService)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }

                        // Memory warning
                        if searchEngine.isLargeLibrary {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Celestial.Colors.error)
                                    .font(.footnote)
                                Text("Large library (\(searchEngine.indexSize) photos)")
                                    .font(.footnote)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                        }

                        // Background reverse-geocoding progress
                        if let geo = indexingService.geocodingProgress, !indexingService.progress.isRunning {
                            geocodingProgressStrip(completed: geo.completed, total: geo.total)
                        }

                        // Content
                        #if DEBUG
                        let _ = debugLogContentBranch()
                        #endif
                        if isSearching {
                            searchingState
                        } else if let error = searchError {
                            errorState(error)
                        } else if !searchText.isEmpty && results.isEmpty && !isSearching && lastSearchedQuery == normalizedSearchQuery(searchText) {
                            noResultsState
                        } else if !searchText.isEmpty {
                            resultsGrid(results: results)
                        } else if !lastResults.isEmpty {
                            lastResultsView
                        } else if indexingService.progress.isRunning && searchText.isEmpty && !indexingService.progress.photosComplete {
                            // Slideshow while indexing
                            IndexingSlideshowView(captionService: captionService)
                                .padding(.top, 8)
                        } else if results.isEmpty && searchText.isEmpty && (!indexingService.progress.isRunning || indexingService.progress.photosComplete) {
                            if indexingService.isReady && (!searchHistory.isEmpty || !smartAlbums.isEmpty) {
                                homeView
                            } else {
                                emptyState
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
                } // VStack
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 10) {
                        Image("AppIconTransparent")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                        Text("Memorable")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(Celestial.Colors.onSurface)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !results.isEmpty && !smartAlbums.contains(where: { $0.query.lowercased() == searchText.lowercased() }) {
                        Button(action: {
                            albumName = searchText
                            showSaveAlbum = true
                        }) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 16))
                                .foregroundStyle(Celestial.Colors.primaryDim)
                        }
                        .accessibilityLabel("Save as smart album")
                    }
                }
            }
            .preferredColorScheme(.dark)
            .fullScreenCover(item: $selectedPhoto) { result in
                if result.isVideo {
                    Color.clear.onAppear {
                        selectedPhoto = nil
                        if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                            presentVideoPlayer(for: asset)
                        }
                    }
                } else {
                    SearchResultsViewer(
                        initialResult: result,
                        allResults: currentDisplayedResults.filter { !$0.isVideo },
                        searchEngine: searchEngine
                    )
                }
            }
            .sheet(isPresented: $showUpgrade) {
                UpgradeView()
            }
            .alert("Save as Smart Album", isPresented: $showSaveAlbum) {
                TextField("Album name", text: $albumName)
                Button("Save") {
                    if !albumName.isEmpty && !searchText.isEmpty {
                        SmartAlbumStore.add(name: albumName, query: searchText)
                        smartAlbums = SmartAlbumStore.load()
                        albumName = ""
                    }
                }
                Button("Cancel", role: .cancel) { albumName = "" }
            } message: {
                Text("This album will auto-update when new matching photos are indexed.")
            }
            .onAppear {
                if indexingService.isReady {
                    startPlaceholderRotation()
                }
            }
            .task {
                // Load DB-backed data off the main thread's critical path so
                // the search bar is tappable immediately on appear.
                let history = SearchHistory.load()
                let albums = SmartAlbumStore.load()
                searchHistory = history
                smartAlbums = albums

                let count = await Task.detached {
                    PhotoLibrary.fetchAllMedia().count
                }.value
                totalLibraryCount = count
            }
            .onDisappear {
                placeholderTimer?.cancel()
            }
            .onChange(of: indexingService.isReady) { oldValue, newValue in
                #if DEBUG
                logger.info("[SearchView] indexingService.isReady changed \(oldValue) -> \(newValue); indexLoaded=\(searchEngine.isIndexLoaded), totalSize=\(searchEngine.totalSize), indexVersion=\(indexingService.indexVersion)")
                #endif
                if indexingService.isReady {
                    startPlaceholderRotation()
                }
            }
            .onChange(of: indexingService.indexVersion) { oldValue, newValue in
                #if DEBUG
                logger.info("[SearchView] indexVersion changed \(oldValue) -> \(newValue); activeSearchID=\(activeSearchID.map(String.init) ?? "nil"), results=\(results.count), lastResults=\(lastResults.count), searchText='\(searchText)'")
                #endif
                // SearchEngine snapshots under lock, so an in-flight submitted
                // search can safely finish against its snapshot. Do not clear
                // visible results here: background enrichment/reloads can advance
                // indexVersion without invalidating the user's current UI.
                validateVisibleResults(reason: "indexVersion changed")
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    // Reload search index if it was dropped due to memory pressure
                    if !searchEngine.isIndexLoaded {
                        Task {
                            do {
                                try await semanticRuntime.prepareForSearch()
                                #if DEBUG
                                logger.info("[SearchView] Reloaded search index after foreground return")
                                #endif
                            } catch {
                                logger.error("Failed to reload index on foreground: \(error.localizedDescription)")
                            }
                        }
                    }

                    validateVisibleResults(reason: "foreground return")
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
                .accessibilityHidden(true)
            TextField(searchPlaceholder, text: $searchText)
                .font(.body)
                .foregroundStyle(Celestial.Colors.onSurface)
                .onChange(of: searchText) { oldValue, newValue in
                    #if DEBUG
                    logger.info("[SearchView] searchText changed activeSearchID=\(activeSearchID.map(String.init) ?? "nil") old={\(debugTextMetadata(oldValue))} new={\(debugTextMetadata(newValue))} equalsLast=\(newValue == (lastSearchedQuery ?? "")) trimEqualOldNew=\(oldValue.trimmingCharacters(in: .whitespacesAndNewlines) == newValue.trimmingCharacters(in: .whitespacesAndNewlines)) lastSearched={\(debugTextMetadata(lastSearchedQuery ?? ""))}")
                    #endif
                    if normalizedSearchQuery(newValue).isEmpty {
                        #if DEBUG
                        logger.info("[SearchView] Clearing search state because searchText is empty")
                        #endif
                        cancelActiveSearch(reason: "searchText cleared", details: "old={\(debugTextMetadata(oldValue))} new={\(debugTextMetadata(newValue))}")
                        results = []
                        fallbackResults = []
                        filterSummary = nil
                        searchError = nil
                        lastSearchedQuery = nil
                        lastResults = []
                        isSearching = false
                        activeSearchID = nil
                        searchTask = nil
                    }
                }
                .onSubmit {
                    #if DEBUG
                    logger.info("[SearchView] onSubmit searchText={\(debugTextMetadata(searchText))} activeSearchID=\(activeSearchID.map(String.init) ?? "nil")")
                    #endif
                    performSearch(saveToHistory: true)
                }
                .accessibilityLabel("Search photos")
            if !searchText.isEmpty {
                Button(action: { searchText = ""; results = []; searchError = nil; lastSearchedQuery = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Celestial.Colors.outlineVariant)
                }
                .accessibilityLabel("Clear search")
            }
            if indexingService.isReady {
                Button(action: {
                    let surprise = SurpriseQueries.random()
                    searchText = surprise
                    performSearch()
                }) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Celestial.Colors.amber)
                }
                .accessibilityLabel("Surprise me with a random search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .modifier(GlassSearchBarModifier())
        .opacity(searchEngine.isIndexLoaded || !searchText.isEmpty ? 1.0 : 0.85)
    }

    private var searchPlaceholder: String {
        if indexingService.isReady {
            return Self.placeholders[placeholderIndex]
        }
        switch semanticRuntime.phase {
        case .warmingCore(let promoted):
            return promoted ? "Prioritizing search..." : "Warming search..."
        case .waitingForIndex:
            return "Index your photos to search..."
        case .failed:
            return "Search setup failed"
        default:
            return "Preparing search..."
        }
    }

    // MARK: - Banners

    private var upgradeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.amber)
            Text("Searching \(searchEngine.totalSize) of \(totalLibraryCount) photos & videos")
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Spacer()
            Button("Unlock full library") {
                showUpgrade = true
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Celestial.Colors.primary)
            Button {
                upgradeBannerDismissed = true
                searchesSinceDismiss = 0
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Celestial.Colors.outline)
                    .padding(6)
            }
            .accessibilityLabel("Dismiss upgrade banner")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Celestial.Colors.surfaceVariant.opacity(0.5))
        .cornerRadius(10)
        .padding(.horizontal, 16)
    }

    // MARK: - Home (Albums + History)

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !smartAlbums.isEmpty {
                smartAlbumsView
            }
            if !searchHistory.isEmpty {
                searchHistoryView
            }
            if indexingService.hitFreeLimit && totalLibraryCount > searchEngine.totalSize {
                Text("Search your \(searchEngine.totalSize) of \(totalLibraryCount) photos & videos")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                resumeIndexingButton
            } else if searchEngine.totalSize > 0 {
                Text("Search your \(searchEngine.totalSize) photos & videos")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
        }
    }

    // Slim one-line progress strip shown while reverse-geocoding photos in the
    // background. Location-filtered searches depend on city/state/country
    // strings that this task populates, so surfacing progress explains why a
    // location query may initially return incomplete results.
    private func geocodingProgressStrip(completed: Int, total: Int) -> some View {
        let progress = total > 0 ? Double(completed) / Double(total) : 0
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "location.circle")
                    .font(.caption2)
                    .foregroundStyle(Celestial.Colors.outline)
                Text("Finding photo locations  \(completed) / \(total)")
                    .font(.caption2)
                    .foregroundStyle(Celestial.Colors.outline)
                Spacer()
            }
            ProgressView(value: progress)
                .tint(Celestial.Colors.primaryFixedDim)
                .scaleEffect(y: 0.5)
                .accessibilityLabel("Finding photo locations: \(completed) of \(total) complete")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // Shown after the "Search your N of M photos & videos" hint once the user upgrades,
    // so they can resume indexing the remaining library without having to
    // re-scan already-indexed photos (startIndexing() skips those).
    @ViewBuilder
    private var resumeIndexingButton: some View {
        if proManager.isPro {
            Button(action: {
                Haptics.medium()
                indexingService.startIndexing()
            }) {
                Label("Index remaining media", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(Celestial.Colors.primaryDim)
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
            .accessibilityHint("Resumes indexing for media that was skipped under the free tier")
        }
    }

    // MARK: - Smart Albums

    private var smartAlbumsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SMART ALBUMS")
                .font(.caption.weight(.medium))
                .tracking(1.5)
                .foregroundStyle(Celestial.Colors.amber)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ForEach(Array(smartAlbums.enumerated()), id: \.element.id) { index, album in
                Button {
                    searchText = album.query
                    performSearch(saveToHistory: true)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.fill")
                            .font(.subheadline)
                            .foregroundStyle(Celestial.Colors.primaryDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name)
                                .font(.subheadline)
                                .foregroundStyle(Celestial.Colors.onSurface)
                            Text(album.query)
                                .font(.footnote)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(Celestial.Colors.outlineVariant)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        SmartAlbumStore.delete(id: album.id)
                        smartAlbums = SmartAlbumStore.load()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                if index < smartAlbums.count - 1 {
                    Divider()
                        .background(Celestial.Colors.outlineVariant.opacity(0.2))
                        .padding(.leading, 48)
                }
            }
        }
    }

    // MARK: - Recent Queries

    private var searchHistoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT SEARCHES")
                    .font(.caption.weight(.medium))
                    .tracking(1.5)
                    .foregroundStyle(Celestial.Colors.amber)
                Spacer()
                Button("Clear All") {
                    SearchHistory.clear()
                    searchHistory = []
                    lastResults = []
                    lastQuery = ""
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(Array(searchHistory.enumerated()), id: \.offset) { index, query in
                Button {
                    searchText = query
                    performSearch(saveToHistory: true)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.subheadline)
                            .foregroundStyle(Celestial.Colors.tertiaryDim)
                        Text(query)
                            .font(.subheadline)
                            .foregroundStyle(Celestial.Colors.onSurface)
                        Spacer()
                        Image(systemName: "arrow.up.left")
                            .font(.footnote)
                            .foregroundStyle(Celestial.Colors.outlineVariant)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        SearchHistory.remove(at: index)
                        searchHistory = SearchHistory.load()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                if index < searchHistory.count - 1 {
                    Divider()
                        .background(Celestial.Colors.outlineVariant.opacity(0.2))
                        .padding(.leading, 48)
                }
            }
        }
    }

    // MARK: - Last Results (when search cleared)

    private var lastResultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.tertiaryDim)
                Text("Results for \"\(lastQuery)\"")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Spacer()
                Button("Dismiss") {
                    lastResults = []
                    lastQuery = ""
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            resultsGrid(results: lastResults)
        }
    }

    // MARK: - States

    private var searchingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Celestial.Colors.primaryDim)
            Text(searchingStateText)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var searchingStateText: String {
        if !semanticRuntime.readiness.isSemanticSearchReady {
            return "Getting search ready..."
        }
        return "Searching..."
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(Celestial.Colors.error)
                .accessibilityHidden(true)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(Celestial.Colors.outlineVariant)
                .accessibilityHidden(true)

            if let summary = filterSummary {
                VStack(spacing: 6) {
                    Text("No photos found")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)

                    let constraints = [summary.locationDescription.map { "near \($0)" },
                                       summary.dateDescription].compactMap { $0 }
                    if !constraints.isEmpty {
                        Text("for \"\(summary.visualQuery)\" \(constraints.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(Celestial.Colors.outline)
                            .multilineTextAlignment(.center)
                    }
                }

                if !fallbackResults.isEmpty {
                    VStack(spacing: 10) {
                        HStack {
                            Text(fallbackTitle(summary: summary))
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Celestial.Colors.amber)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(fallbackResults) { result in
                                FallbackThumbnail(result: result)
                                    .onTapGesture {
                                        if result.isVideo {
                                            if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                                                presentVideoPlayer(for: asset)
                                            }
                                        } else {
                                            // Use fallbackResults for the viewer since main results are empty
                                            lastResults = fallbackResults.filter { !$0.isVideo }
                                            selectedPhoto = result
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            } else {
                Text("No matching photos found")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Text("Try a different description")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private struct FallbackThumbnail: View {
        let result: SearchResult
        @State private var image: UIImage?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                } else {
                    Color(Celestial.Colors.surfaceContainer)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .task {
                if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                    image = await PhotoLibrary.loadThumbnail(for: asset)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(Celestial.Colors.outlineVariant)
                .accessibilityHidden(true)
            if indexingService.isReady && searchEngine.totalSize > 0 {
                if indexingService.hitFreeLimit && totalLibraryCount > searchEngine.totalSize {
                    Text("Search your \(searchEngine.totalSize) of \(totalLibraryCount) photos & videos")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    resumeIndexingButton
                } else {
                    Text("Search your \(searchEngine.totalSize) photos & videos")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                Text("Describe what you're looking for")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                Button(action: {
                    Haptics.medium()
                    let surprise = SurpriseQueries.random()
                    searchText = surprise
                    performSearch()
                }) {
                    Label("Surprise Me", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(Celestial.Colors.primaryDim)
                .padding(.top, 12)
            } else {
                Text("Index your media to start searching")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Text("All processing happens on your device")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                Button(action: { indexingService.startIndexing() }) {
                    Label("Build Search Index", systemImage: "sparkles")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(Celestial.Colors.primaryContainer)
                        .clipShape(Capsule())
                }
                .padding(.top, 6)
                .accessibilityHint("Scans your photo library and builds a searchable index")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Results Grid (Masonry Layout)

    private func applyMediaFilter(_ input: [SearchResult]) -> [SearchResult] {
        switch mediaFilter {
        case .all:
            return input
        case .photos:
            return input.filter { !$0.isVideo && !screenshotIds.contains($0.id) }
        case .videos:
            return input.filter { $0.isVideo }
        case .screenshots:
            return input.filter { screenshotIds.contains($0.id) }
        }
    }

    private func controlsPanel(filteredCount: Int) -> some View {
        VStack(spacing: 0) {
            // Location fallback banner
            if let summary = filterSummary {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Celestial.Colors.amber)
                    let location = summary.locationDescription ?? ""
                    Text("Showing all relevant photos\(location.isEmpty ? "" : " near \(location)")")
                        .font(.footnote)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // Upgrade banner for free tier (after first successful search)
            if !proManager.isPro && indexingService.hitFreeLimit && hasCompletedFirstSearch && !upgradeBannerDismissed {
                upgradeBanner
                    .padding(.bottom, 10)
            }

            // Result summary + sort toggle
            HStack {
                Text("\(filteredCount) \(filteredCount == 1 ? "result" : "results")")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                if searchTimeMs > 0 {
                    Text("in \(searchTimeMs)ms")
                        .font(.caption)
                        .foregroundStyle(Celestial.Colors.outline)
                }
                Spacer()
                Picker("Sort", selection: Binding(
                    get: { sortMode },
                    set: { sortModeRaw = $0.rawValue }
                )) {
                    Text("Relevance").tag(SortMode.relevance)
                    Text("Recent").tag(SortMode.recent)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Media filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaFilter.allCases, id: \.self) { filter in
                        let isActive = mediaFilter == filter
                        Button {
                            Haptics.selection()
                            mediaFilter = filter
                            visibleCount = initialVisibleCount
                        } label: {
                            Text(filter.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isActive ? Celestial.Colors.onPrimaryContainer : Celestial.Colors.onSurfaceVariant)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(isActive ? Celestial.Colors.primaryContainer : Celestial.Colors.surfaceContainerHigh)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 14)
        .modifier(GlassPanelModifier(cornerRadius: Celestial.sharedCornerRadius))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func resultsGrid(results: [SearchResult]) -> some View {
        let sorted = applySort(results, mode: sortMode)
        let filtered = applyMediaFilter(sorted)
        let visible = Array(filtered.prefix(visibleCount))
        let hasMore = filtered.count > visible.count
        #if DEBUG
        let _ = debugLogResultsGrid(
            inputCount: results.count,
            sortedCount: sorted.count,
            filteredCount: filtered.count,
            visibleCount: visible.count,
            hasMore: hasMore
        )
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            if sortMode == .recent {
                let groups = ResultGrouper.groupByMonth(results: visible)
                ForEach(groups) { group in
                    HStack {
                        Text(group.label.uppercased())
                            .font(.caption.weight(.medium))
                            .tracking(1.5)
                            .foregroundStyle(Celestial.Colors.amber)
                        Spacer()
                        Text("\(group.results.count) \(group.results.count == 1 ? "result" : "results")")
                            .font(.footnote)
                            .foregroundStyle(Celestial.Colors.outline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                    masonryGrid(results: group.results)
                        .padding(.horizontal, 12)
                }
            } else {
                masonryGrid(results: visible)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if hasMore {
                Button {
                    Haptics.light()
                    visibleCount = filtered.count
                } label: {
                    Text("Show all \(filtered.count) matching results")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Celestial.Colors.primary)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }

            if !visible.isEmpty {
                Text(AppCopy.aiDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(Celestial.Colors.outline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, hasMore ? 0 : 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func applySort(_ input: [SearchResult], mode: SortMode) -> [SearchResult] {
        switch mode {
        case .relevance:
            return input
        case .recent:
            return input.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
        }
    }

    private func masonryGrid(results: [SearchResult]) -> some View {
        MasonryGrid(results) { result in
            resultTile(result: result)
        }
    }

    private func resultTile(result: SearchResult) -> some View {
        PhotoThumbnailView(result: result)
            .onTapGesture { handleResultTap(result) }
            .contextMenu {
                if proManager.isPro {
                    Button {
                        let similar = searchEngine.findSimilar(photoId: result.id)
                        self.results = similar
                        searchText = "Similar to selected photo"
                        lastSearchedQuery = "Similar to selected photo"
                    } label: {
                        Label("Find Similar", systemImage: "sparkle.magnifyingglass")
                    }
                } else {
                    Button {
                        showUpgrade = true
                    } label: {
                        Label("Find Similar (Pro)", systemImage: "sparkles")
                    }
                }
            }
            .accessibilityLabel(result.isVideo ? "Video result" : "Photo result")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Actions

    private func handleResultTap(_ result: SearchResult) {
        #if DEBUG
        logger.info("[SearchView] result tapped id=\(result.id) localId=\(result.localIdentifier) isVideo=\(result.isVideo) score=\(String(format: "%.4f", result.score))")
        #endif
        Haptics.selection()
        if result.isVideo {
            if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                presentVideoPlayer(for: asset)
            }
        } else {
            selectedPhoto = result
        }
    }

    private func validateVisibleResults(reason: String) {
        let currentResults = results
        let currentLast = lastResults
        guard !currentResults.isEmpty || !currentLast.isEmpty else {
            #if DEBUG
            logger.info("[SearchView] visible-result validation skipped reason='\(reason)' because no visible results exist")
            #endif
            return
        }

        let resultIds = Set(currentResults.map(\.id))
        let lastResultIds = Set(currentLast.map(\.id))
        let candidates = currentResults + currentLast

        // Run off the main thread because each getAsset call is a synchronous
        // PHFetchRequest. With many results this can otherwise block the UI.
        Task.detached {
            let validIds = Set(
                candidates
                    .filter { PhotoLibrary.getAsset(by: $0.localIdentifier) != nil }
                    .map(\.id)
            )
            await MainActor.run { [self] in
                guard Set(results.map(\.id)) == resultIds, Set(lastResults.map(\.id)) == lastResultIds else {
                    #if DEBUG
                    logger.info("[SearchView] visible-result validation skipped reason='\(reason)' because results changed")
                    #endif
                    return
                }

                let updatedResults = currentResults.filter { validIds.contains($0.id) }
                let updatedLast = currentLast.filter { validIds.contains($0.id) }
                if updatedResults.count != currentResults.count || updatedLast.count != currentLast.count {
                    #if DEBUG
                    logger.info("[SearchView] visible-result validation removed stale assets reason='\(reason)' results \(currentResults.count) -> \(updatedResults.count), last \(currentLast.count) -> \(updatedLast.count)")
                    #endif
                    results = updatedResults
                    lastResults = updatedLast
                } else {
                    #if DEBUG
                    logger.info("[SearchView] visible-result validation kept all assets reason='\(reason)' count=\(candidates.count)")
                    #endif
                }
            }
        }
    }

    private func startPlaceholderRotation() {
        placeholderTimer?.cancel()
        placeholderIndex = Int.random(in: 0..<Self.placeholders.count)
        placeholderTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { break }
                if searchText.isEmpty {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        placeholderIndex = (placeholderIndex + 1) % Self.placeholders.count
                    }
                }
            }
        }
    }

    private func fallbackTitle(summary: FilterSummary) -> String {
        let hasLocation = summary.locationDescription != nil
        let hasDate = summary.dateDescription != nil

        // When filters are active, the fallback contains filter-matched media
        // (the visual query didn't find anything in that subset).
        // Title should describe what's actually shown, not the failed visual query.
        if hasLocation || hasDate {
            let parts = [summary.locationDescription, summary.dateDescription].compactMap { $0 }
            return "Media from \(parts.joined(separator: ", "))"
        }

        // No filters: fallback is near-miss CLIP results for the visual query
        return "Other \"\(summary.visualQuery)\" matches"
    }

    private func performSearch(saveToHistory: Bool = false) {
        let submittedText = searchText
        let query = normalizedSearchQuery(submittedText)
        guard !query.isEmpty else {
            #if DEBUG
            logger.info("[SearchView] performSearch ignored because normalized searchText is empty; submitted={\(debugTextMetadata(submittedText))}")
            #endif
            return
        }
        Haptics.light()
        // Cancel any previous search so stale results can't land on top of
        // the new one (race condition when the user types quickly or when
        // the index is rebuilt mid-query).
        cancelActiveSearch(reason: "new search submitted", details: "incoming={\(debugTextMetadata(searchText))}")
        isSearching = true
        searchError = nil
        visibleCount = initialVisibleCount
        searchSequence += 1
        let searchID = searchSequence
        activeSearchID = searchID
        let startTime = CFAbsoluteTimeGetCurrent()

        searchTask = Task {
            do {
                #if DEBUG
                logger.info("[SearchView #\(searchID)] start query={\(debugTextMetadata(query))} submitted={\(debugTextMetadata(submittedText))} saveToHistory=\(saveToHistory) isReady=\(indexingService.isReady) indexLoaded=\(searchEngine.isIndexLoaded) indexVersion=\(indexingService.indexVersion) semanticReady=\(semanticRuntime.readiness.isSemanticSearchReady) progressRunning=\(indexingService.progress.isRunning)")
                #endif
                defer {
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] finish; activeSearchID=\(activeSearchID.map(String.init) ?? "nil"), results=\(results.count), fallback=\(fallbackResults.count), lastSearched='\(lastSearchedQuery ?? "nil")'")
                    #endif
                    if activeSearchID == searchID {
                        isSearching = false
                        activeSearchID = nil
                        searchTask = nil
                    }
                }
                indexingService.deferEnrichmentForUserSearch()
                if !semanticRuntime.readiness.isSemanticSearchReady || !indexingService.isReady {
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] preparing semantic search; semanticReady=\(semanticRuntime.readiness.isSemanticSearchReady) isReady=\(indexingService.isReady)")
                    #endif
                    try await semanticRuntime.prepareForSearch()
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] semantic prepare complete; semanticReady=\(semanticRuntime.readiness.isSemanticSearchReady) isReady=\(indexingService.isReady) indexLoaded=\(searchEngine.isIndexLoaded)")
                    #endif
                }
                guard indexingService.isReady || searchEngine.isIndexLoaded else {
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] abort: index unavailable after prepare; isReady=\(indexingService.isReady) indexLoaded=\(searchEngine.isIndexLoaded)")
                    #endif
                    if activeSearchID == searchID {
                        searchError = "Index your photos before searching."
                    }
                    return
                }
                guard activeSearchID == searchID else {
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] abort before engine: superseded by activeSearchID=\(activeSearchID.map(String.init) ?? "nil")")
                    #endif
                    return
                }
                #if DEBUG
                logger.info("[SearchView #\(searchID)] calling SearchEngine.search query='\(query)'")
                #endif
                let response = try await searchEngine.search(query: query)
                #if DEBUG
                logger.info("[SearchView #\(searchID)] engine returned main=\(response.results.count) fallback=\(response.fallbackResults.count) filters=\(response.filtersApplied != nil)")
                #endif
                if Task.isCancelled || activeSearchID != searchID {
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] abort after engine: canceledOrSuperseded taskCancelled=\(Task.isCancelled), activeSearchID=\(activeSearchID.map(String.init) ?? "nil")")
                    #endif
                    return
                }
                results = response.results
                lastSearchedQuery = query
                fallbackResults = response.fallbackResults
                filterSummary = response.filtersApplied
                mediaFilter = .all
                searchTimeMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
                #if DEBUG
                let first = response.results.first
                logger.info("[SearchView #\(searchID)] applied response: results=\(results.count), fallback=\(fallbackResults.count), firstId=\(first?.localIdentifier ?? "nil"), firstIsVideo=\(first?.isVideo ?? false), mediaFilter=\(mediaFilter.rawValue), searchTimeMs=\(searchTimeMs)")
                #endif

                // Detect screenshots in background for the media filter
                let resultIDs = Set(response.results.map(\.id))
                let photoResults = response.results.filter { !$0.isVideo }
                Task.detached {
                    #if DEBUG
                    logger.info("[SearchView #\(searchID)] screenshot detection started for photoResults=\(photoResults.count)")
                    #endif
                    let detected = Set(
                        photoResults.compactMap { r -> String? in
                            guard let asset = PhotoLibrary.getAsset(by: r.localIdentifier),
                                  asset.mediaSubtypes.contains(.photoScreenshot) else { return nil }
                            return r.id
                        }
                    )
                    await MainActor.run {
                        guard Set(results.map(\.id)) == resultIDs else {
                            #if DEBUG
                            logger.info("[SearchView #\(searchID)] screenshot detection skipped because visible results changed")
                            #endif
                            return
                        }
                        #if DEBUG
                        logger.info("[SearchView #\(searchID)] screenshot detection applied count=\(detected.count)")
                        #endif
                        screenshotIds = detected
                    }
                }

                #if DEBUG
                logger.info("[SearchView] '\(query)': \(response.results.count) results in \(searchTimeMs)ms")
                #endif

                if !response.results.isEmpty {
                    if saveToHistory {
                        SearchHistory.add(query: query)
                        searchHistory = SearchHistory.load()
                    }
                    lastQuery = query
                    lastResults = response.results

                    // Track searches for free tier upgrade banner
                    if !hasCompletedFirstSearch {
                        hasCompletedFirstSearch = true
                    }
                    if upgradeBannerDismissed {
                        searchesSinceDismiss += 1
                        if searchesSinceDismiss >= 5 {
                            upgradeBannerDismissed = false
                            searchesSinceDismiss = 0
                        }
                    }
                }
            } catch {
                logger.error("[SearchView #\(searchID)] Search failed: \(error.localizedDescription)")
                if activeSearchID == searchID {
                    searchError = "Search failed: \(error.localizedDescription)"
                    results = []
                }
            }
        }
    }

    private func normalizedSearchQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelActiveSearch(reason: String, details: String) {
        guard let task = searchTask else {
            #if DEBUG
            logger.info("[SearchView] cancel skipped reason='\(reason)' activeSearchID=\(activeSearchID.map(String.init) ?? "nil") details=\(details)")
            #endif
            return
        }
        #if DEBUG
        logger.info("[SearchView] cancel searchTask reason='\(reason)' activeSearchID=\(activeSearchID.map(String.init) ?? "nil") isSearching=\(isSearching) searchText={\(debugTextMetadata(searchText))} lastSearched={\(debugTextMetadata(lastSearchedQuery ?? ""))} indexVersion=\(indexingService.indexVersion) details=\(details)")
        #endif
        task.cancel()
    }

    private func debugTextMetadata(_ value: String) -> String {
        #if DEBUG
        let scalars = value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: ",")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return "text='\(value)' count=\(value.count) trimmed='\(trimmed)' scalars=[\(scalars)]"
        #else
        return value
        #endif
    }

    #if DEBUG
    private func debugLogResultsGrid(
        inputCount: Int,
        sortedCount: Int,
        filteredCount: Int,
        visibleCount: Int,
        hasMore: Bool
    ) {
        logger.info("[SearchView] resultsGrid render input=\(inputCount) sorted=\(sortedCount) filtered=\(filteredCount) visible=\(visibleCount) hasMore=\(hasMore) mediaFilter=\(mediaFilter.rawValue) sort=\(sortMode.rawValue) searchText='\(searchText)' isSearching=\(isSearching)")
    }

    private func debugLogControlsPanel(filteredCount: Int) {
        logger.info("[SearchView] controlsPanel render filteredCount=\(filteredCount) rawResults=\(results.count) isSearching=\(isSearching) mediaFilter=\(mediaFilter.rawValue)")
    }

    private func debugLogContentBranch() {
        let branch: String
        if isSearching {
            branch = "searchingState"
        } else if searchError != nil {
            branch = "errorState"
        } else if !searchText.isEmpty && results.isEmpty && !isSearching && lastSearchedQuery == normalizedSearchQuery(searchText) {
            branch = "noResultsState"
        } else if !searchText.isEmpty {
            branch = "resultsGrid"
        } else if !lastResults.isEmpty {
            branch = "lastResultsView"
        } else if indexingService.progress.isRunning && searchText.isEmpty && !indexingService.progress.photosComplete {
            branch = "indexingSlideshow"
        } else if results.isEmpty && searchText.isEmpty && (!indexingService.progress.isRunning || indexingService.progress.photosComplete) {
            branch = "emptyOrHistoryState"
        } else {
            branch = "none"
        }
        logger.info("[SearchView] contentBranch=\(branch) searchTextLen=\(searchText.count) results=\(results.count) fallback=\(fallbackResults.count) lastResults=\(lastResults.count) isSearching=\(isSearching) lastSearched='\(lastSearchedQuery ?? "nil")' searchError=\(searchError ?? "nil") mediaFilter=\(mediaFilter.rawValue) indexReady=\(indexingService.isReady) indexLoaded=\(searchEngine.isIndexLoaded)")
    }
    #endif

}
