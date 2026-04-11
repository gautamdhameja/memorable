import SwiftUI
import Photos
import AVKit

private enum SortMode: String {
    case relevance
    case recent
}

struct SearchView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    let captionService: PhotoCaptionService

    @State private var searchText = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var selectedPhoto: SearchResult?
    @State private var searchError: String?
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

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Celestial.Colors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar pinned at top
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

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

                        // Content
                        if isSearching {
                            searchingState
                        } else if let error = searchError {
                            errorState(error)
                        } else if !searchText.isEmpty && results.isEmpty && !isSearching {
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
                searchHistory = SearchHistory.load()
                smartAlbums = SmartAlbumStore.load()
                Task.detached {
                    let count = PhotoLibrary.fetchAllMedia().count
                    await MainActor.run {
                        totalLibraryCount = count
                    }
                }
                if indexingService.isReady {
                    startPlaceholderRotation()
                }
            }
            .onDisappear {
                placeholderTimer?.cancel()
            }
            .onChange(of: indexingService.isReady) {
                if indexingService.isReady {
                    startPlaceholderRotation()
                }
            }
            .onChange(of: indexingService.indexVersion) {
                // Index changed (e.g., photos deleted) — clear stale results
                if !results.isEmpty {
                    results = []
                    lastResults = []
                    searchText = ""
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    // Reload search index if it was dropped due to memory pressure
                    if !searchEngine.isIndexLoaded {
                        Task {
                            do {
                                try searchEngine.loadIndex()
                                #if DEBUG
                                logger.info("[SearchView] Reloaded search index after foreground return")
                                #endif
                            } catch {
                                logger.error("Failed to reload index on foreground: \(error.localizedDescription)")
                            }
                        }
                    }

                    // Remove any results pointing to deleted assets
                    if !results.isEmpty {
                        let cleaned = results.filter { PhotoLibrary.getAsset(by: $0.localIdentifier) != nil }
                        if cleaned.count != results.count {
                            results = cleaned
                            lastResults = cleaned
                        }
                    }
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
            TextField(indexingService.isReady ? Self.placeholders[placeholderIndex] : "Indexing your photos...", text: $searchText)
                .font(.body)
                .foregroundStyle(Celestial.Colors.onSurface)
                .onChange(of: searchText) { _, newValue in
                    if newValue.isEmpty {
                        results = []
                        searchError = nil
                    }
                }
                .onSubmit {
                    performSearch(saveToHistory: true)
                }
                .disabled(!indexingService.isReady)
                .accessibilityLabel("Search photos")
            if !searchText.isEmpty {
                Button(action: { searchText = ""; results = []; searchError = nil }) {
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
        .opacity(indexingService.isReady ? 1.0 : 0.5)
    }

    // MARK: - Banners

    private var upgradeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.footnote)
                .foregroundStyle(Celestial.Colors.amber)
            Text("Searching \(searchEngine.totalSize) of \(totalLibraryCount) photos")
                .font(.footnote)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Spacer()
            Button("Unlock full library") {
                showUpgrade = true
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Celestial.Colors.primary)
            Button {
                upgradeBannerDismissed = true
                searchesSinceDismiss = 0
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(Celestial.Colors.outline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Celestial.Colors.surfaceVariant.opacity(0.5))
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
                Text("Search your \(searchEngine.totalSize) of \(totalLibraryCount) photos")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            } else if searchEngine.totalSize > 0 {
                Text("Search your \(searchEngine.totalSize) photos & videos")
                    .font(.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
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
            Text("Searching...")
                .font(.subheadline)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
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
                            Text("Other \"\(summary.visualQuery)\" photos")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Celestial.Colors.amber)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        let columns = [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8),
                        ]
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
                    Text("Search your \(searchEngine.totalSize) of \(totalLibraryCount) photos")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
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

    private func resultsGrid(results: [SearchResult]) -> some View {
        let sorted = applySort(results, mode: sortMode)
        let visible = Array(sorted.prefix(visibleCount))
        let hasMore = results.count > visible.count
        return VStack(alignment: .leading, spacing: 0) {
            // Location fallback banner
            if let summary = filterSummary, !sorted.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Celestial.Colors.amber)
                    let location = summary.locationDescription ?? ""
                    Text("Showing all photos\(location.isEmpty ? "" : " near \(location)")")
                        .font(.footnote)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }

            // Upgrade banner for free tier (after first successful search)
            if !proManager.isPro && indexingService.hitFreeLimit && hasCompletedFirstSearch && !upgradeBannerDismissed {
                upgradeBanner
            }

            // Result summary + sort toggle
            HStack {
                Text("\(results.count) \(results.count == 1 ? "result" : "results")")
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
            .padding(.top, 4)
            .padding(.bottom, 8)

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
                    visibleCount = results.count
                } label: {
                    Text("Show all \(results.count) matching results")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Celestial.Colors.primary)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }

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
            .accessibilityLabel("Photo, \(Int(result.score * 100)) percent match")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Actions

    private func handleResultTap(_ result: SearchResult) {
        Haptics.selection()
        if result.isVideo {
            if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                presentVideoPlayer(for: asset)
            }
        } else {
            selectedPhoto = result
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

    private func performSearch(saveToHistory: Bool = false) {
        guard !searchText.isEmpty, indexingService.isReady else { return }
        Haptics.light()
        isSearching = true
        searchError = nil
        visibleCount = initialVisibleCount
        let query = searchText
        let startTime = CFAbsoluteTimeGetCurrent()

        Task {
            do {
                let response = try await searchEngine.search(query: query)
                results = response.results
                fallbackResults = response.fallbackResults
                filterSummary = response.filtersApplied
                searchTimeMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

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
                logger.error("Search failed: \(error.localizedDescription)")
                searchError = "Search failed: \(error.localizedDescription)"
                results = []
            }
            isSearching = false
        }
    }

}

