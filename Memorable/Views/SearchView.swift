import SwiftUI
import Photos
import AVKit

struct SearchView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let captionService: PhotoCaptionService

    @StateObject private var viewModel: SearchViewModel
    @State private var selectedPhoto: SearchResult?
    @State private var showUpgrade = false
    @State private var showSaveAlbum = false
    @State private var albumName = ""
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var smartAlbums: [SmartAlbum] = []
    @State private var totalLibraryCount: Int = 0
    @State private var placeholderIndex: Int = 0
    @State private var placeholderTimer: Task<Void, Never>?

    // Keep the existing persisted key stable. SearchViewModel owns the runtime
    // sort state; this wrapper is the SwiftUI persistence adapter.
    @AppStorage(SearchViewModel.sortModeStorageKey) private var sortModeRaw: String = SearchSortMode.relevance.rawValue

    private static let placeholders = [
        "Search for your moment...",
        "Describe your memory...",
        "What are you looking for?",
        "Try \"sunset at the beach\"...",
        "Try \"birthday cake\"...",
    ]

    init(
        indexingService: IndexingService,
        searchEngine: SearchEngine,
        semanticRuntime: SemanticSearchRuntime,
        captionService: PhotoCaptionService
    ) {
        self.indexingService = indexingService
        self.searchEngine = searchEngine
        self.semanticRuntime = semanticRuntime
        self.captionService = captionService
        _viewModel = StateObject(wrappedValue: SearchViewModel(dependencies: .init(
            deferEnrichmentForUserSearch: { indexingService.deferEnrichmentForUserSearch() },
            isSemanticSearchReady: { semanticRuntime.readiness.isSemanticSearchReady },
            isIndexReady: { indexingService.isReady },
            isIndexLoaded: { searchEngine.isIndexLoaded },
            prepareForSearch: { try await semanticRuntime.prepareForSearch() },
            search: { query in try await searchEngine.search(query: query) },
            detectScreenshotIDs: { searchResults in
                let task = Task.detached {
                    guard !Task.isCancelled else { return Set<String>() }
                    let identifiers = searchResults.map(\.localIdentifier)
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                    var screenshotIdentifiers = Set<String>()
                    assets.enumerateObjects { asset, _, _ in
                        if asset.mediaSubtypes.contains(.photoScreenshot) {
                            screenshotIdentifiers.insert(asset.localIdentifier)
                        }
                    }
                    return Set(searchResults.compactMap { result in
                        screenshotIdentifiers.contains(result.localIdentifier) ? result.id : nil
                    })
                }
                return await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            },
            validResultIDs: { candidates in
                let task = Task.detached {
                    guard !Task.isCancelled else { return Set<String>() }
                    let identifiers = candidates.map(\.localIdentifier)
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                    var validIdentifiers = Set<String>()
                    assets.enumerateObjects { asset, _, _ in
                        validIdentifiers.insert(asset.localIdentifier)
                    }
                    return Set(candidates.compactMap { result in
                        validIdentifiers.contains(result.localIdentifier) ? result.id : nil
                    })
                }
                return await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            },
            addHistory: { SearchHistory.add(query: $0) },
            loadHistory: { SearchHistory.load() },
            clearHistory: { SearchHistory.clear() },
            removeHistory: { SearchHistory.remove(at: $0) },
            now: { CFAbsoluteTimeGetCurrent() }
        )))
    }

    var body: some View {
        let filteredSearchResults = viewModel.filteredResults(viewModel.results)
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
                    if !viewModel.queryText.isEmpty && !viewModel.results.isEmpty && !viewModel.isSearching {
                        controlsPanel(filteredCount: filteredSearchResults.count)
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
                        if viewModel.isSearching {
                            searchingState
                        } else if let error = viewModel.searchError {
                            errorState(error)
                        } else if viewModel.hasNoResultsForCurrentQuery {
                            noResultsState
                        } else if !viewModel.queryText.isEmpty {
                            resultsGrid(results: viewModel.results, filteredResults: filteredSearchResults)
                        } else if !viewModel.lastResults.isEmpty {
                            lastResultsView
                        } else if indexingService.progress.isRunning && viewModel.queryText.isEmpty && !indexingService.progress.photosComplete {
                            // Slideshow while indexing
                            IndexingSlideshowView(captionService: captionService)
                                .padding(.top, 8)
                        } else if viewModel.results.isEmpty && viewModel.queryText.isEmpty && (!indexingService.progress.isRunning || indexingService.progress.photosComplete) {
                            if indexingService.isReady && (!viewModel.searchHistory.isEmpty || !smartAlbums.isEmpty) {
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
                    if !viewModel.results.isEmpty && !smartAlbums.contains(where: { $0.query.lowercased() == viewModel.queryText.lowercased() }) {
                        Button(action: {
                            albumName = viewModel.queryText
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
                        allResults: viewModel.currentDisplayedResults.filter { !$0.isVideo },
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
                    if !albumName.isEmpty && !viewModel.queryText.isEmpty {
                        SmartAlbumStore.add(name: albumName, query: viewModel.queryText)
                        smartAlbums = SmartAlbumStore.load()
                        albumName = ""
                    }
                }
                Button("Cancel", role: .cancel) { albumName = "" }
            } message: {
                Text("This album will auto-update when new matching photos are indexed.")
            }
            .onAppear {
                viewModel.setSortMode(rawValue: sortModeRaw)
                if indexingService.isReady {
                    startPlaceholderRotation()
                }
            }
            .task {
                // Load DB-backed data off the main thread's critical path so
                // the search bar is tappable immediately on appear.
                let albums = SmartAlbumStore.load()
                viewModel.loadSearchHistory()
                smartAlbums = albums

                let count = await Task.detached {
                    PhotoLibrary.fetchAllMedia().count
                }.value
                totalLibraryCount = count
            }
            .onDisappear {
                placeholderTimer?.cancel()
            }
            .onChange(of: sortModeRaw) { _, newValue in
                viewModel.setSortMode(rawValue: newValue)
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
                logger.info("[SearchView] indexVersion changed \(oldValue) -> \(newValue); activeSearchID=\(viewModel.activeSearchID.map(String.init) ?? "nil"), results=\(viewModel.results.count), lastResults=\(viewModel.lastResults.count), searchText='\(viewModel.queryText)'")
                #endif
                // SearchEngine snapshots under lock, so an in-flight submitted
                // search can safely finish against its snapshot. Do not clear
                // visible results here: background enrichment/reloads can advance
                // indexVersion without invalidating the user's current UI.
                viewModel.validateVisibleResults(reason: "indexVersion changed")
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

                    viewModel.validateVisibleResults(reason: "foreground return")
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
            TextField(searchPlaceholder, text: Binding(
                get: { viewModel.queryText },
                set: { viewModel.setQueryText($0) }
            ))
                .font(.body)
                .foregroundStyle(Celestial.Colors.onSurface)
                .onSubmit {
                    performSearch(saveToHistory: true)
                }
                .accessibilityLabel("Search photos")
            if !viewModel.queryText.isEmpty {
                Button(action: { viewModel.setQueryText("") }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Celestial.Colors.outlineVariant)
                }
                .accessibilityLabel("Clear search")
            }
            if indexingService.isReady {
                Button(action: {
                    let surprise = SurpriseQueries.random()
                    viewModel.setQueryText(surprise)
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
        .opacity(searchEngine.isIndexLoaded || !viewModel.queryText.isEmpty ? 1.0 : 0.85)
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
                viewModel.dismissUpgradeBanner()
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
            if !viewModel.searchHistory.isEmpty {
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
                    viewModel.setQueryText(album.query)
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
                    viewModel.clearSearchHistory()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(Array(viewModel.searchHistory.enumerated()), id: \.offset) { index, query in
                Button {
                    viewModel.setQueryText(query)
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
                        viewModel.removeSearchHistory(at: index)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }

                if index < viewModel.searchHistory.count - 1 {
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
                Text("Results for \"\(viewModel.lastQuery)\"")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Spacer()
                Button("Dismiss") {
                    viewModel.dismissLastResults()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            resultsGrid(results: viewModel.lastResults)
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

            if let summary = viewModel.filterSummary {
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

                if !viewModel.fallbackResults.isEmpty {
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
                            ForEach(viewModel.fallbackResults) { result in
                                FallbackThumbnail(result: result)
                                    .onTapGesture {
                                        if result.isVideo {
                                            if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                                                presentVideoPlayer(for: asset)
                                            }
                                        } else {
                                            // Use fallback results for the viewer since main results are empty.
                                            viewModel.useFallbackResultsForViewer()
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
                    viewModel.setQueryText(surprise)
                    performSearch()
                }) {
                    Label("Surprise Me", systemImage: "sparkles")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(Celestial.Colors.primaryDim)
                .padding(.top, 12)
            } else {
                if indexingService.indexRebuildRequired {
                    Text("Search index update required")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    Text("Memorable improved how it understands image orientation. Rebuild once to keep search results accurate.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Celestial.Colors.outline)
                        .padding(.horizontal, 32)
                    Button(action: { indexingService.rebuildRequiredIndex() }) {
                        Label("Rebuild Search Index", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Celestial.Colors.onPrimaryContainer)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 14)
                            .background(Celestial.Colors.primaryContainer)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 6)
                    .accessibilityHint("Clears the incompatible search index and rebuilds it on this device")
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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Results Grid (Masonry Layout)

    private func controlsPanel(filteredCount: Int) -> some View {
        VStack(spacing: 0) {
            // Location fallback banner
            if let summary = viewModel.filterSummary {
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
            if !proManager.isPro && indexingService.hitFreeLimit && viewModel.hasCompletedFirstSearch && !viewModel.upgradeBannerDismissed {
                upgradeBanner
                    .padding(.bottom, 10)
            }

            // Result summary + sort toggle
            HStack {
                Text("\(filteredCount) \(filteredCount == 1 ? "result" : "results")")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                if viewModel.searchTimeMs > 0 {
                    Text("in \(viewModel.searchTimeMs)ms")
                        .font(.caption)
                        .foregroundStyle(Celestial.Colors.outline)
                }
                Spacer()
                Picker("Sort", selection: Binding(
                    get: { viewModel.sortMode },
                    set: {
                        viewModel.selectSortMode($0)
                        sortModeRaw = $0.rawValue
                    }
                )) {
                    Text("Relevance").tag(SearchSortMode.relevance)
                    Text("Recent").tag(SearchSortMode.recent)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Media filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchMediaFilter.allCases, id: \.self) { filter in
                        let isActive = viewModel.mediaFilter == filter
                        Button {
                            Haptics.selection()
                            viewModel.setMediaFilter(filter)
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

    private func resultsGrid(
        results: [SearchResult],
        filteredResults: [SearchResult]? = nil
    ) -> some View {
        let filtered = filteredResults ?? viewModel.filteredResults(results)
        let visible = Array(filtered.prefix(viewModel.visibleCount))
        let hasMore = filtered.count > visible.count
        return VStack(alignment: .leading, spacing: 0) {
            if viewModel.sortMode == .recent {
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
                    viewModel.showAllResults(count: filtered.count)
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
                        viewModel.applySimilarResults(similar)
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

    private func startPlaceholderRotation() {
        placeholderTimer?.cancel()
        placeholderIndex = Int.random(in: 0..<Self.placeholders.count)
        placeholderTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { break }
                if viewModel.queryText.isEmpty {
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
        guard !viewModel.normalizedQuery.isEmpty else { return }
        Haptics.light()
        viewModel.submitSearch(saveToHistory: saveToHistory)
    }

}
