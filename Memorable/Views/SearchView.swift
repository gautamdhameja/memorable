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
    @Environment(\.database) private var database
    @Environment(\.scenePhase) private var scenePhase
    @State private var smartAlbums: [SmartAlbum] = []
    @State private var totalLibraryCount: Int = 0
    @State private var placeholderIndex: Int = 0
    @State private var placeholderTimer: Task<Void, Never>?
    @State private var findSimilarTask: Task<Void, Never>?
    @State private var findSimilarGeneration = 0
    @State private var showStorageResetConfirm = false
    @AppStorage(AppKeys.persistentStoreReset) private var storageResetScheduled = false

    // Keep the existing persisted key stable. SearchViewModel owns the runtime
    // sort state; this wrapper is the SwiftUI persistence adapter.
    @AppStorage(SearchViewModel.sortModeStorageKey) private var sortModeRaw: String = SearchSortMode.relevance.rawValue

    private static let placeholders = [
        "Search your photos...",
        "Describe what you remember...",
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
            prioritizeUserSearch: { indexingService.prioritizeUserSearch() },
            isSemanticSearchReady: { semanticRuntime.readiness.isSemanticSearchReady },
            isIndexReady: { indexingService.isReady },
            isIndexLoaded: { searchEngine.isIndexLoaded },
            prepareForSearch: { try await semanticRuntime.prepareForSearch() },
            search: { query in
                try await searchEngine.search(
                    query: query,
                    featurePolicy: SearchFeaturePolicy(isPro: ProManager.shared.isPro)
                )
            },
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
                let isPro = ProManager.shared.isPro
                let task = Task.detached {
                    guard !Task.isCancelled else { return Set<String>() }
                    let photoKitCandidates = candidates.filter {
                        $0.sourceId == PhotoSourceType.photokit.rawValue
                    }
                    let identifiers = photoKitCandidates.map(\.localIdentifier)
                    let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                    var validIdentifiers = Set<String>()
                    assets.enumerateObjects { asset, _, _ in
                        validIdentifiers.insert(asset.localIdentifier)
                    }
                    let folderCandidates = candidates.filter {
                        FolderResultAccessPolicy.allows(
                            sourceId: $0.sourceId,
                            isPro: isPro
                        ) && $0.filePath != nil
                    }
                    var accessibleFolderResultIDs = Set<String>()
                    for (sourceId, sourceCandidates) in Dictionary(
                        grouping: folderCandidates,
                        by: \SearchResult.sourceId
                    ) {
                        guard !Task.isCancelled else { return Set<String>() }
                        let accessiblePaths = FolderScanner.accessibleBookmarkedImagePaths(
                            sourceCandidates.compactMap(\.filePath),
                            sourceId: sourceId
                        )
                        accessibleFolderResultIDs.formUnion(sourceCandidates.compactMap { result in
                            guard let filePath = result.filePath,
                                  accessiblePaths.contains(filePath) else { return nil }
                            return result.id
                        })
                    }
                    return SearchResultForegroundValidator.validResultIDs(
                        candidates: candidates,
                        validPhotoKitIdentifiers: validIdentifiers,
                        isFolderResultAccessible: { result in
                            accessibleFolderResultIDs.contains(result.id)
                        }
                    )
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
                CelestialBackdrop()

                VStack(spacing: 0) {
                    searchHeader

                    // Search bar pinned at top
                    searchBar
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                        .padding(.bottom, 18)

                    // Database warning
                    if AppDatabase.isInMemoryFallback {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Celestial.Colors.error)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Indexing is unavailable")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                Text("Memorable could not open its local search database. Free storage, then close and reopen the app.")
                                    .font(.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                            }
                            Button(storageResetScheduled ? "Reset scheduled for next launch" : "Reset local search data") {
                                showStorageResetConfirm = true
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Celestial.Colors.primaryDim)
                            .disabled(storageResetScheduled)
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
                        } else if indexingService.progress.isRunning && viewModel.queryText.isEmpty {
                            // Keep suggestions hidden through both photo and video indexing.
                            IndexingSlideshowView(captionService: captionService)
                                .padding(.top, 8)
                        } else if viewModel.results.isEmpty && viewModel.queryText.isEmpty {
                            if hasHomeContent {
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
            .toolbar(.hidden, for: .navigationBar)
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
            .alert("Reset local search data?", isPresented: $showStorageResetConfirm) {
                Button("Reset on next launch", role: .destructive) {
                    AppDatabase.schedulePersistentStoreReset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Close and reopen Memorable to complete the reset. Apple Photos are not changed. The reset deletes the local search index, search history, saved albums, and folder registrations. Rebuild the index and add folders again afterward.")
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
                async let savedData = Task.detached(priority: .utility) {
                    (albums: SmartAlbumStore.load(), history: SearchHistory.load())
                }.value
                async let libraryCount = Task.detached(priority: .utility) {
                    PhotoLibrary.fetchAllMedia().count
                }.value
                let (data, count) = await (savedData, libraryCount)
                guard !Task.isCancelled else { return }
                smartAlbums = data.albums
                viewModel.setSearchHistory(data.history)
                totalLibraryCount = count
            }
            .onDisappear {
                placeholderTimer?.cancel()
                cancelFindSimilar()
                cancelPendingVideoPlayerPresentation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                cancelFindSimilar()
                viewModel.handleMemoryPressure()
            }
            .onChange(of: sortModeRaw) { _, newValue in
                viewModel.setSortMode(rawValue: newValue)
            }
            .onChange(of: proManager.isPro) { _, isPro in
                guard !isPro else { return }
                if let selectedPhoto,
                   !FolderResultAccessPolicy.allows(
                       sourceId: selectedPhoto.sourceId,
                       isPro: false
                   ) {
                    self.selectedPhoto = nil
                }
                viewModel.validateVisibleResults(reason: "Pro entitlement changed")
            }
            .onChange(of: viewModel.results.map(\.localIdentifier)) { _, identifiers in
                Task {
                    await PhotoLibrary.prefetchAssets(localIdentifiers: identifiers)
                }
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
                logger.info("[SearchView] indexVersion changed \(oldValue) -> \(newValue); activeSearchID=\(viewModel.activeSearchID.map(String.init) ?? "nil"), results=\(viewModel.results.count), lastResults=\(viewModel.lastResults.count)")
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
                                logger.error("Failed to reload index on foreground: \(error.safeDiagnosticCode)")
                            }
                        }
                    }

                    viewModel.validateVisibleResults(reason: "foreground return")
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchHeader: some View {
        HStack(alignment: .center) {
            Text("Memorable")
                .font(Celestial.Typography.brand)
                .foregroundStyle(Celestial.Colors.onSurface)
                .layoutPriority(1)
            Spacer()
            if canShowValidatedSuggestions {
                Button(action: performSurpriseSearch) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Celestial.Colors.amber)
                        .frame(width: 38, height: 38)
                        .modifier(
                            GlassCircleModifier(
                                tint: Celestial.Colors.amber.opacity(0.14)
                            )
                        )
                        .contentShape(Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Surprise me with a photo search")
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 8)
    }

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
                .submitLabel(.search)
                .onSubmit {
                    performSearch(saveToHistory: true)
                }
                .accessibilityLabel("Search photos")
            if !viewModel.queryText.isEmpty {
                Button(action: { viewModel.setQueryText("") }) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Celestial.Colors.outline)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .modifier(GlassSearchBarModifier(cornerRadius: 13))
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
        .modifier(
            GlassPanelModifier(
                cornerRadius: 12,
                tint: Celestial.Colors.amber.opacity(0.09),
                interactive: true
            )
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Home (Albums + History)

    private var canShowValidatedSuggestions: Bool {
        indexingService.canShowValidatedSearchSuggestions
    }

    private var hasHomeContent: Bool {
        guard !indexingService.progress.isRunning, indexingService.isReady else { return false }
        return canShowValidatedSuggestions
            || !smartAlbums.isEmpty
            || !viewModel.searchHistory.isEmpty
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canShowValidatedSuggestions {
                validatedSuggestionsView
            }
            if !smartAlbums.isEmpty {
                smartAlbumsView
            }
            if !viewModel.searchHistory.isEmpty {
                searchHistoryView
            }
            if indexingService.hitFreeLimit
                && totalLibraryCount > searchEngine.totalSize {
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

    private var validatedSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MATCHED IN YOUR LIBRARY")
                .font(Celestial.Typography.eyebrow)
                .tracking(0.6)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(indexingService.validatedSearchSuggestions.prefix(3), id: \.self) { suggestion in
                    Button {
                        viewModel.setQueryText(suggestion)
                        performSearch(saveToHistory: true)
                    } label: {
                        HStack(spacing: 12) {
                            Text(suggestion)
                                .font(.body)
                                .foregroundStyle(Celestial.Colors.secondary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                        }
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    CelestialHairline()
                }
            }
            .padding(.horizontal, 14)
            .modifier(GlassPanelModifier(cornerRadius: 18))
        }
        .padding(.horizontal, 16)
    }

    private func performSurpriseSearch() {
        guard canShowValidatedSuggestions,
              let suggestion = indexingService.validatedSearchSuggestions.randomElement() else { return }
        Haptics.medium()
        viewModel.setQueryText(suggestion)
        performSearch()
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
        .padding(.top, 8)
        .modifier(GlassPanelModifier(cornerRadius: 12))
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
            .buttonStyle(CelestialSecondaryButtonStyle())
            .padding(.top, 10)
            .frame(maxWidth: .infinity)
            .accessibilityHint("Resumes indexing media that was skipped before the Pro upgrade")
            .disabled(!database.allowsIndexingWrites)
        }
    }

    // MARK: - Smart Albums

    private var smartAlbumsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SMART ALBUMS")
                    .font(Celestial.Typography.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Spacer()
                Text("\(smartAlbums.count) saved")
                    .font(.caption)
                    .foregroundStyle(Celestial.Colors.primaryDim)
            }
            .padding(.horizontal, 26)
            .padding(.top, 30)
            .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(smartAlbums.prefix(6)) { album in
                        Button {
                            viewModel.setQueryText(album.query)
                            performSearch(saveToHistory: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                LinearGradient(
                                    colors: [Celestial.Colors.surfaceBright, Celestial.Colors.secondaryContainer],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .frame(width: 108, height: 82)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "rectangle.stack")
                                        .font(.caption)
                                        .foregroundStyle(Celestial.Colors.primary)
                                        .padding(8)
                                }
                                Text(album.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                    .lineLimit(1)
                                    .frame(width: 108, alignment: .leading)
                            }
                            .padding(8)
                            .modifier(
                                GlassPanelModifier(
                                    cornerRadius: 14,
                                    tint: Celestial.Colors.primaryDim.opacity(0.08),
                                    interactive: true
                                )
                            )
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                SmartAlbumStore.delete(id: album.id)
                                smartAlbums = SmartAlbumStore.load()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 26)
            }
        }
    }

    // MARK: - Recent Queries

    private var searchHistoryView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT SEARCHES")
                    .font(Celestial.Typography.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Spacer()
                Button("Clear All") {
                    viewModel.clearSearchHistory()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
            }
            .padding(.horizontal, 26)
            .padding(.top, 30)
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
                    .padding(.horizontal, 26)
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
                    CelestialHairline()
                        .padding(.horizontal, 26)
                }
            }
        }
        .padding(.bottom, 8)
        .modifier(GlassPanelModifier(cornerRadius: 18))
        .padding(.horizontal, 16)
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
        VStack(alignment: .leading, spacing: 0) {
            if let summary = viewModel.filterSummary {
                Text("Nothing matches all of that")
                    .font(Celestial.Typography.title2)
                    .foregroundStyle(Celestial.Colors.onSurface)

                Text(noResultsExplanation(summary))
                    .font(.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .lineSpacing(5)
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    if summary.dateDescription != nil {
                        relaxationButton("Try any date") {
                            runRelaxedSearch(summary: summary, dropDate: true)
                        }
                    }
                    if summary.locationDescription != nil {
                        relaxationButton("Drop the location") {
                            runRelaxedSearch(summary: summary, dropLocation: true)
                        }
                    }
                    if !summary.visualQuery.isEmpty {
                        relaxationButton("Search “\(summary.visualQuery)” only") {
                            viewModel.setQueryText(summary.visualQuery)
                            performSearch(saveToHistory: true)
                        }
                    }
                    CelestialHairline()
                }
                .padding(.top, 28)

                if !viewModel.fallbackResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CLOSE TO WHAT YOU DESCRIBED")
                            .font(Celestial.Typography.eyebrow)
                            .tracking(0.6)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            .padding(.top, 32)

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
                    }
                }
            } else {
                Text("No matching photos")
                    .font(Celestial.Typography.title2)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text("Try a broader description or remove a detail.")
                    .font(.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
        .padding(.top, 34)
    }

    private func relaxationButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Celestial.Colors.onSurface)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Celestial.Colors.outline)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .top) { CelestialHairline() }
    }

    private func noResultsExplanation(_ summary: FilterSummary) -> String {
        var details = [summary.visualQuery.isEmpty ? "matching photos" : "\(summary.visualQuery) photos"]
        if let location = summary.locationDescription { details.append("near \(location)") }
        if let date = summary.dateDescription { details.append("from \(date)") }
        return "Looked for \(details.joined(separator: " ")). Try relaxing one detail."
    }

    private func runRelaxedSearch(
        summary: FilterSummary,
        dropDate: Bool = false,
        dropLocation: Bool = false
    ) {
        var parts: [String] = summary.visualQuery.isEmpty ? [] : [summary.visualQuery]
        if !dropLocation, let location = summary.locationDescription { parts.append("in \(location)") }
        if !dropDate, let date = summary.dateDescription { parts.append(date) }
        viewModel.setQueryText(parts.joined(separator: " "))
        performSearch(saveToHistory: true)
    }

    private struct FallbackThumbnail: View {
        let result: SearchResult
        @State private var image: UIImage?
        @State private var imageLoadGeneration: UInt = 0
        @State private var imageLoadTask: Task<Void, Never>?

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
                imageLoadTask?.cancel()
                let task = Task { @MainActor in
                    imageLoadGeneration &+= 1
                    let generation = imageLoadGeneration
                    let loaded = await PhotoLibrary.loadImage(
                        for: result,
                        targetSize: CGSize(width: 400, height: 400)
                    )
                    guard ImageLoadGenerationPolicy.acceptsCompletion(
                        startedGeneration: generation,
                        currentGeneration: imageLoadGeneration,
                        isCancelled: Task.isCancelled
                    ) else { return }
                    image = loaded
                }
                imageLoadTask = task
                await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                imageLoadTask?.cancel()
                imageLoadTask = nil
                imageLoadGeneration &+= 1
                MemoryPressureReleasePolicy.release(&image)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Circle()
                    .stroke(Celestial.Colors.hairline, lineWidth: 1)
                    .frame(width: 132, height: 132)
                Circle()
                    .stroke(Celestial.Colors.primaryDim.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [2, 8]))
                    .frame(width: 94, height: 94)
                CelestialGlassIcon(
                    systemName: "magnifyingglass",
                    size: 58
                )
                Circle()
                    .fill(Celestial.Colors.amber)
                    .frame(width: 6, height: 6)
                    .offset(x: 66)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 42)

            if indexingService.isReady && searchEngine.totalSize > 0 {
                if indexingService.hitFreeLimit
                    && totalLibraryCount > searchEngine.totalSize {
                    Text("Search your \(searchEngine.totalSize) of \(totalLibraryCount) photos & videos")
                        .font(Celestial.Typography.title3)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    resumeIndexingButton
                } else {
                    Text("Search your \(searchEngine.totalSize) photos & videos")
                        .font(Celestial.Typography.title3)
                        .foregroundStyle(Celestial.Colors.onSurface)
                }
                Text("Describe what you're looking for")
                    .font(.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .padding(.top, 10)
                if canShowValidatedSuggestions {
                    Button(action: performSurpriseSearch) {
                        Label("Surprise Me", systemImage: "sparkles")
                    }
                    .buttonStyle(CelestialSecondaryButtonStyle())
                    .padding(.top, 20)
                }
            } else {
                if indexingService.indexRebuildRequired {
                    Text("Update the search index")
                        .font(Celestial.Typography.title)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("Memorable improved how it understands image orientation. Rebuild once to keep search results accurate.")
                        .font(.body)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .lineSpacing(4)
                        .padding(.top, 12)
                    Button(action: { indexingService.rebuildRequiredIndex() }) {
                        Label("Rebuild Search Index", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CelestialButtonStyle())
                    .padding(.top, 24)
                    .accessibilityHint("Clears the incompatible search index and rebuilds it on this device")
                    .disabled(!database.allowsIndexingWrites)
                } else {
                    Text("Make your library searchable")
                        .font(Celestial.Typography.title)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("A one-time scan runs on this iPhone. Photos become searchable as it goes.")
                        .font(.body)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .lineSpacing(4)
                        .padding(.top, 12)
                    Button(action: { indexingService.startIndexing() }) {
                        Text("Build Search Index")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CelestialButtonStyle())
                    .padding(.top, 24)
                    .accessibilityHint("Scans your photo library and builds a searchable index")
                    .disabled(!database.allowsIndexingWrites)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
        .padding(.top, 46)
    }

    // MARK: - Results Grid (Masonry Layout)

    private func controlsPanel(filteredCount: Int) -> some View {
        VStack(spacing: 0) {
            if let summary = viewModel.filterSummary {
                VStack(alignment: .leading, spacing: 10) {
                    structuredQuerySentence(summary)
                        .font(.body)
                        .lineSpacing(6)
                    Text("Search details understood from your description")
                        .font(.caption)
                        .foregroundStyle(Celestial.Colors.outline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
            }

            if !proManager.isPro && indexingService.hitFreeLimit && viewModel.hasCompletedFirstSearch && !viewModel.upgradeBannerDismissed {
                upgradeBanner
                    .padding(.bottom, 14)
            }

            HStack {
                Text("\(filteredCount) \(filteredCount == 1 ? "result" : "results")")
                    .font(.subheadline)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Spacer()

                Menu {
                    Button("Relevance") {
                        viewModel.selectSortMode(.relevance)
                        sortModeRaw = SearchSortMode.relevance.rawValue
                    }
                    Button("Recent") {
                        viewModel.selectSortMode(.recent)
                        sortModeRaw = SearchSortMode.recent.rawValue
                    }
                } label: {
                    Text(viewModel.sortMode == .relevance ? "Relevance" : "Recent")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Celestial.Colors.primaryDim)
                }

                if !smartAlbums.contains(where: { $0.query.lowercased() == viewModel.queryText.lowercased() }) {
                    Button("Save album") {
                        albumName = viewModel.queryText
                        showSaveAlbum = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Celestial.Colors.amber)
                }
            }
            .padding(.bottom, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(SearchMediaFilter.allCases, id: \.self) { filter in
                        let isActive = viewModel.mediaFilter == filter
                        Button {
                            Haptics.selection()
                            viewModel.setMediaFilter(filter)
                        } label: {
                            Text(filter.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(isActive ? Celestial.Colors.onSurface : Celestial.Colors.outline)
                                .padding(.bottom, 10)
                                .overlay(alignment: .bottom) {
                                    if isActive {
                                        Rectangle()
                                            .fill(Celestial.Colors.primaryDim)
                                            .frame(height: 2)
                                    }
                                }
                        }
                    }
                }
            }

            CelestialHairline()
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .modifier(GlassPanelModifier(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func structuredQuerySentence(_ summary: FilterSummary) -> Text {
        var text = Text("Showing ").foregroundColor(Celestial.Colors.onSurfaceVariant)
        text = text + Text(summary.visualQuery.isEmpty ? "matching" : summary.visualQuery)
            .foregroundColor(Celestial.Colors.onSurface)
            .bold()
        text = text + Text(" photos").foregroundColor(Celestial.Colors.onSurfaceVariant)
        if let location = summary.locationDescription {
            text = text + Text(" near ").foregroundColor(Celestial.Colors.onSurfaceVariant)
            text = text + Text(location).foregroundColor(Celestial.Colors.primary)
        }
        if let date = summary.dateDescription {
            text = text + Text(" from ").foregroundColor(Celestial.Colors.onSurfaceVariant)
            text = text + Text(date).foregroundColor(Celestial.Colors.primary)
        }
        return text + Text(".").foregroundColor(Celestial.Colors.onSurfaceVariant)
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
                            .font(Celestial.Typography.eyebrow)
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
                        .padding(.horizontal, 4)
                }
            } else {
                masonryGrid(results: visible)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
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
        MasonryGrid(results, spacing: 4) { result in
            resultTile(result: result)
        }
    }

    private func resultTile(result: SearchResult) -> some View {
        PhotoThumbnailView(result: result)
            .onTapGesture { handleResultTap(result) }
            .contextMenu {
                if result.supportsFindSimilar {
                    if proManager.isPro {
                        Button {
                            startFindSimilar(photoID: result.id)
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
            }
            .accessibilityLabel(result.isVideo ? "Video result" : "Photo result")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Actions

    private func startFindSimilar(photoID: String) {
        findSimilarTask?.cancel()
        findSimilarGeneration &+= 1
        let generation = findSimilarGeneration
        let engine = searchEngine
        findSimilarTask = Task {
            let similar = await SimilaritySearchOperation.run {
                engine.findSimilar(photoId: photoID)
            }
            guard !Task.isCancelled, generation == findSimilarGeneration else { return }
            viewModel.applySimilarResults(similar)
            findSimilarTask = nil
        }
    }

    private func cancelFindSimilar() {
        findSimilarGeneration &+= 1
        findSimilarTask?.cancel()
        findSimilarTask = nil
    }

    private func handleResultTap(_ result: SearchResult) {
        #if DEBUG
        logger.info("[SearchView] result tapped isVideo=\(result.isVideo) score=\(String(format: "%.4f", result.score))")
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

enum SearchResultForegroundValidator {
    static func validResultIDs(
        candidates: [SearchResult],
        validPhotoKitIdentifiers: Set<String>,
        isFolderResultAccessible: (SearchResult) -> Bool
    ) -> Set<String> {
        Set(candidates.compactMap { result in
            if result.sourceId == PhotoSourceType.photokit.rawValue {
                return validPhotoKitIdentifiers.contains(result.localIdentifier) ? result.id : nil
            }
            return isFolderResultAccessible(result) ? result.id : nil
        })
    }
}
