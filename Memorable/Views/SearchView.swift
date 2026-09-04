import SwiftUI
import Photos
import AVKit
import Combine

struct SearchView: View {
    @ObservedObject var indexingService: IndexingService
    let searchEngine: SearchEngine
    @ObservedObject var semanticRuntime: SemanticSearchRuntime
    let captionService: PhotoCaptionService
    let surpriseRequestID: Int
    let searchHomeRequestID: Int

    @StateObject private var viewModel: SearchViewModel
    @State private var selectedPhoto: SearchResult?
    @State private var showUpgrade = false
    @State private var showSaveAlbum = false
    @State private var albumName = ""
    @ObservedObject private var proManager = ProManager.shared
    @Environment(\.database) private var database
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var smartAlbums: [SmartAlbum] = []
    @State private var todayMemory: OnThisDaySummary?
    @State private var isTodayMemoryResolved = false
    @State private var todayMemoryLoadTask: Task<Void, Never>?
    @State private var todayMemoryRefreshState = TodayMemoryRefreshState()
    @State private var isViewVisible = false
    @State private var totalLibraryCount: Int = 0
    @State private var placeholderIndex: Int = 0
    @State private var placeholderTimer: Task<Void, Never>?
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
        captionService: PhotoCaptionService,
        surpriseRequestID: Int,
        searchHomeRequestID: Int
    ) {
        self.indexingService = indexingService
        self.searchEngine = searchEngine
        self.semanticRuntime = semanticRuntime
        self.captionService = captionService
        self.surpriseRequestID = surpriseRequestID
        self.searchHomeRequestID = searchHomeRequestID
        _viewModel = StateObject(wrappedValue: SearchViewModel(dependencies: .init(
            prioritizeUserSearch: { indexingService.prioritizeUserSearch() },
            isSemanticSearchReady: { semanticRuntime.readiness.isSemanticSearchReady },
            isIndexReady: { indexingService.isReady },
            isIndexLoaded: { searchEngine.isIndexLoaded },
            isMaintenanceWorkIdle: { !indexingService.progress.isRunning },
            prepareForSearch: { try await semanticRuntime.prepareForSearch() },
            search: { query in
                try await searchEngine.search(
                    query: query,
                    featurePolicy: SearchFeaturePolicy(isPro: ProManager.shared.isPro)
                )
            },
            searchForHistoryPreview: { query in
                try await searchEngine.search(
                    query: query,
                    featurePolicy: SearchFeaturePolicy(isPro: ProManager.shared.isPro),
                    recordsUserTiming: false
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
            addHistory: {
                SearchHistory.add(
                    query: $0,
                    previewResult: $1,
                    resultCount: $2
                )
            },
            backfillHistoryPreviews: { SearchHistory.backfill(previews: $0) },
            loadHistory: { SearchHistory.load() },
            loadHistoryPreviews: { SearchHistory.loadPreviews() },
            clearHistory: { SearchHistory.clear() },
            removeHistory: { SearchHistory.remove(at: $0) },
            now: { CFAbsoluteTimeGetCurrent() }
        )))
    }

    var body: some View {
        let filteredSearchResults = viewModel.filteredResults(viewModel.results)
        // Erase the large navigation subtree before attaching presentation and
        // lifecycle observers so Swift can type-check each graph independently.
        let navigationContent = AnyView(NavigationStack {
            ZStack {
                CelestialBackdrop()

                VStack(spacing: 0) {
                    searchHeader

                    if !indexingService.shouldShowInitialIndexingExperience {
                        // Search stays out of the first indexing experience so
                        // the unfinished index never looks ready for use.
                        searchBar
                            .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
                            .padding(.top, 20)
                            .padding(.bottom, Celestial.Spacing.stackedContainerGap)
                    }

                    // Database warning
                    if AppDatabase.isInMemoryFallback {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Celestial.Colors.error)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Indexing is unavailable")
                                    .font(Celestial.Typography.supportingEmphasized)
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                Text("Memorable could not open its local search database. Free storage, then close and reopen the app.")
                                    .font(Celestial.Typography.caption)
                                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            }
                            }
                            Button(storageResetScheduled ? "Reset scheduled for next launch" : "Reset local search data") {
                                showStorageResetConfirm = true
                            }
                            .font(Celestial.Typography.captionStrong)
                            .foregroundStyle(Celestial.Colors.primaryDim)
                            .disabled(storageResetScheduled)
                        }
                        .padding(Celestial.Spacing.surfaceContentInset)
                        .modifier(GlassPanelModifier(cornerRadius: 16))
                        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
                        .padding(.bottom, Celestial.Spacing.stackedContainerGap)
                    }

                    // Sticky controls panel (above scroll)
                    if !indexingService.shouldShowInitialIndexingExperience,
                       !viewModel.queryText.isEmpty,
                       !viewModel.results.isEmpty,
                       !viewModel.isSearching {
                        controlsPanel(filteredCount: filteredSearchResults.count)
                    }

                    ScrollView {
                        if indexingService.shouldShowInitialIndexingExperience {
                            initialIndexingExperience
                        } else {
                            VStack(spacing: 0) {
                                // Indexing banners
                                if indexingService.progress.isRunning
                                    || indexingService.isThermallyPaused
                                    || indexingService.backgroundExecutionState == .pausedAwaitingForeground {
                                    IndexingBannerView(indexingService: indexingService)
                                        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
                                        .padding(.bottom, Celestial.Spacing.stackedContainerGap)
                                }

                                // Memory warning
                                if searchEngine.isLargeLibrary {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(Celestial.Colors.error)
                                            .font(Celestial.Typography.footnote)
                                        Text("Large library (\(searchEngine.indexSize) photos)")
                                            .font(Celestial.Typography.footnote)
                                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                                    }
                                    .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
                                    .padding(.bottom, 8)
                                }

                                // Deferred reverse-geocoding progress
                                if let geo = indexingService.geocodingProgress,
                                   !indexingService.progress.isRunning {
                                    geocodingProgressStrip(geo)
                                }

                                if let restriction = viewModel.restrictionSummary,
                                   !viewModel.isSearching {
                                    searchRestrictionStrip(restriction)
                                }

                                // Content
                                if semanticRuntime.isCheckingIndexAvailability {
                                    indexReadinessCheckingState
                                } else if viewModel.isSearching {
                                    searchingState
                                } else if let error = viewModel.searchError {
                                    errorState(error)
                                } else if viewModel.hasNoResultsForCurrentQuery {
                                    noResultsState
                                } else if !viewModel.queryText.isEmpty {
                                    resultsGrid(
                                        results: viewModel.results,
                                        filteredResults: filteredSearchResults
                                    )
                                } else if !viewModel.lastResults.isEmpty {
                                    lastResultsView
                                } else if viewModel.results.isEmpty,
                                          viewModel.queryText.isEmpty {
                                    if hasHomeContent {
                                        homeView
                                    } else {
                                        emptyState
                                    }
                                }
                            }
                            .padding(.bottom, 40)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollBounceBehavior(.basedOnSize)
                } // VStack
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
        })

        let presentedContent = navigationContent
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

        let lifecycleContent = presentedContent
            .onAppear {
                isViewVisible = true
                viewModel.setSortMode(rawValue: sortModeRaw)
                if indexingService.isReady {
                    startPlaceholderRotation()
                }
                requestTodayMemoryRefresh()
            }
            .task {
                // Load DB-backed data off the main thread's critical path so
                // the search bar is tappable immediately on appear.
                async let savedData = Task.detached(priority: .utility) {
                    let history = SearchHistory.load()
                    return (
                        albums: SmartAlbumStore.load(),
                        history: history,
                        previews: SearchHistory.loadPreviews()
                    )
                }.value
                async let libraryCount = Task.detached(priority: .utility) {
                    PhotoLibrary.fetchAllMedia().count
                }.value
                let data = await savedData
                guard !Task.isCancelled else { return }
                smartAlbums = data.albums
                viewModel.applyInitialSearchHistory(
                    data.history,
                    previews: data.previews
                )
                viewModel.startRecentSearchPreviewBackfill()
                requestTodayMemoryRefresh()

                let count = await libraryCount
                guard !Task.isCancelled else { return }
                totalLibraryCount = count
            }
            .onDisappear {
                isViewVisible = false
                placeholderTimer?.cancel()
                cancelFindSimilar()
                cancelPendingVideoPlayerPresentation()
                viewModel.cancelRecentSearchPreviewBackfill()
                todayMemoryLoadTask?.cancel()
                todayMemoryRefreshState.cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                cancelFindSimilar()
                viewModel.handleMemoryPressure()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                    .merge(with: NotificationCenter.default.publisher(
                        for: UIApplication.significantTimeChangeNotification
                    ))
            ) { _ in
                todayMemory = nil
                isTodayMemoryResolved = false
                requestTodayMemoryRefresh()
            }

        let searchObservationContent = lifecycleContent
            .onChange(of: sortModeRaw) { _, newValue in
                viewModel.setSortMode(rawValue: newValue)
            }
            .onChange(of: viewModel.queryText) { _, query in
                if query.isEmpty {
                    requestTodayMemoryRefresh()
                } else {
                    todayMemoryLoadTask?.cancel()
                }
            }
            .onChange(of: proManager.isPro) { _, isPro in
                guard !isPro else { return }
                viewModel.handleProEntitlementRevoked()
                cancelFindSimilar()
                if let selectedPhoto,
                   !FolderResultAccessPolicy.allows(
                       sourceId: selectedPhoto.sourceId,
                       isPro: false
                   ) {
                    self.selectedPhoto = nil
                }
                if let todayMemory,
                   !FolderResultAccessPolicy.allows(
                       sourceId: todayMemory.heroPhoto.sourceId,
                       isPro: false
                   ) {
                    self.todayMemory = nil
                    isTodayMemoryResolved = true
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
                    viewModel.startRecentSearchPreviewBackfill()
                    requestTodayMemoryRefresh()
                }
            }
            .onChange(of: indexingService.progress.isRunning) { _, isRunning in
                if !isRunning {
                    viewModel.startRecentSearchPreviewBackfill()
                    requestTodayMemoryRefresh()
                }
            }
            .onChange(of: semanticRuntime.readiness.isSemanticSearchReady) { _, isReady in
                if isReady {
                    viewModel.startRecentSearchPreviewBackfill()
                }
            }

        searchObservationContent
            .onChange(of: indexingService.indexVersion) { oldValue, newValue in
                #if DEBUG
                logger.info("[SearchView] indexVersion changed \(oldValue) -> \(newValue); activeSearchID=\(viewModel.activeSearchID.map(String.init) ?? "nil"), results=\(viewModel.results.count), lastResults=\(viewModel.lastResults.count)")
                #endif
                // SearchEngine snapshots under lock, so an in-flight submitted
                // search can safely finish against its snapshot. Do not clear
                // visible results here: background enrichment/reloads can advance
                // indexVersion without invalidating the user's current UI.
                viewModel.validateVisibleResults(reason: "indexVersion changed")
                requestTodayMemoryRefresh()
            }
            .onChange(of: surpriseRequestID) { _, _ in
                performSurpriseSearch()
            }
            .onChange(of: searchHomeRequestID) { _, _ in
                cancelFindSimilar()
                viewModel.setQueryText("")
                requestTodayMemoryRefresh()
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
                    viewModel.startRecentSearchPreviewBackfill()
                    requestTodayMemoryRefresh()
                } else {
                    viewModel.cancelRecentSearchPreviewBackfill()
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
        }
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
        .padding(.top, 8)
        .fixedSize(horizontal: false, vertical: true)
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
                .font(Celestial.Typography.body)
                .foregroundStyle(Celestial.Colors.onSurface)
                .submitLabel(.search)
                .onSubmit {
                    performSearch(saveToHistory: true)
                }
                .accessibilityLabel("Search photos")
            if !viewModel.queryText.isEmpty {
                Button(action: { viewModel.setQueryText("") }) {
                    Image(systemName: "xmark")
                        .font(Celestial.Typography.captionStrong)
                        .foregroundStyle(Celestial.Colors.outline)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
        .frame(minHeight: 52)
        .modifier(GlassSearchBarModifier(cornerRadius: 13))
        .opacity(searchEngine.isIndexLoaded || !viewModel.queryText.isEmpty ? 1.0 : 0.85)
        .disabled(!semanticRuntime.readiness.isSemanticSearchReady)
        .accessibilityHint(
            semanticRuntime.readiness.isSemanticSearchReady
                ? ""
                : searchPreparationStatusText
        )
    }

    private var initialIndexingExperience: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("YOUR LIBRARY IS COMING TO LIFE")
                .font(Celestial.Typography.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Celestial.Colors.amber)

            Text("While we build your search, revisit a few moments.")
                .font(Celestial.Typography.compactMemoryCaption)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .lineSpacing(3)
                .padding(.top, 8)

            IndexingSlideshowView(
                captionService: captionService,
                presentation: .initialIndexing
            )
            .padding(.top, 20)

            IndexingBannerView(indexingService: indexingService)
                .padding(.top, 16)
        }
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
        .padding(.top, 18)
        .padding(.bottom, 40)
    }

    private var searchPlaceholder: String {
        guard semanticRuntime.readiness.isSemanticSearchReady else {
            return Self.placeholders[0]
        }
        return Self.placeholders[placeholderIndex]
    }

    private var searchPreparationStatusText: String {
        switch semanticRuntime.phase {
        case .failed(let message):
            return message
        default:
            return "Preparing search..."
        }
    }

    // MARK: - Banners

    private var upgradeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(Celestial.Typography.supporting)
                .foregroundStyle(Celestial.Colors.amber)
            Text("Searching \(searchEngine.totalSize) of \(totalLibraryCount) photos & videos")
                .font(Celestial.Typography.supporting)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            Spacer()
            Button("Unlock full library") {
                showUpgrade = true
            }
            .font(Celestial.Typography.supportingEmphasized)
            .foregroundStyle(Celestial.Colors.primary)
            Button {
                viewModel.dismissUpgradeBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.outline)
                    .padding(6)
            }
            .accessibilityLabel("Dismiss upgrade banner")
        }
        .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
        .padding(.vertical, 10)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 12,
                tint: Celestial.Colors.amber.opacity(0.09)
            )
        )
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
    }

    // MARK: - Home (Albums + History)

    private var canShowValidatedSuggestions: Bool {
        indexingService.canShowValidatedSearchSuggestions
    }

    private var hasHomeContent: Bool {
        guard !indexingService.progress.isRunning, indexingService.isReady else { return false }
        return (canShowValidatedSuggestions && viewModel.shouldShowDiscoverySuggestions)
            || !smartAlbums.isEmpty
            || !viewModel.searchHistory.isEmpty
            || todayMemory != nil
            || !isTodayMemoryResolved
    }

    private var homeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let primarySections = SearchHomeLayoutPolicy.primarySections(
                isTodayMemoryResolved: isTodayMemoryResolved,
                hasTodayMemory: todayMemory != nil,
                hasRecentSearches: !viewModel.searchHistory.isEmpty
            )
            ForEach(primarySections, id: \.self) { section in
                primaryHomeSection(section)
                    .padding(
                        .top,
                        section == primarySections.first ? 0 : Celestial.Spacing.sectionGap
                    )
            }
            if canShowValidatedSuggestions && viewModel.shouldShowDiscoverySuggestions {
                validatedSuggestionsView
                    .padding(.top, primarySections.isEmpty ? 0 : Celestial.Spacing.sectionGap)
            }
            if !smartAlbums.isEmpty {
                smartAlbumsView
            }
            if indexingService.hitFreeLimit
                && totalLibraryCount > searchEngine.totalSize {
                Text("Search your \(searchEngine.totalSize) of \(totalLibraryCount) photos & videos")
                    .font(Celestial.Typography.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                resumeIndexingButton
            } else if searchEngine.totalSize > 0 {
                Text("Search your \(searchEngine.totalSize) photos & videos")
                    .font(Celestial.Typography.footnote)
                    .foregroundStyle(Celestial.Colors.outline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
        }
    }

    @ViewBuilder
    private func primaryHomeSection(_ section: SearchHomePrimarySection) -> some View {
        switch section {
        case .todayMemoryLoading:
            todayMemoryLoadingView
        case .todayMemory:
            if let todayMemory {
                todayMemoryView(todayMemory)
            }
        case .recentSearches:
            searchHistoryView
                .allowsHitTesting(isTodayMemoryResolved)
                .accessibilityHidden(!isTodayMemoryResolved)
        }
    }

    private var todayMemoryLoadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today in Your Memories")
                .font(Celestial.Typography.bodyEmphasized)
                .foregroundStyle(Celestial.Colors.onSurface)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Celestial.Colors.surfaceContainerLow.opacity(0.48))
                    .frame(height: SearchHomeCardMetrics.memoryPreviewHeight)
                    .overlay {
                        ProgressView()
                            .tint(Celestial.Colors.primaryDim)
                            .accessibilityLabel("Looking for today's memories")
                    }
                Color.clear
                    .frame(height: SearchHomeCardMetrics.captionHeight)
            }
            .background(Celestial.Colors.surfaceContainerLow.opacity(0.74))
            .clipShape(SearchHomeCardMetrics.cardShape)
        }
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
    }

    private var validatedSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MATCHED IN YOUR LIBRARY")
                .font(Celestial.Typography.eyebrow)
                .tracking(0.6)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(indexingService.validatedSearchSuggestions.prefix(3), id: \.self) { suggestion in
                    Button {
                        viewModel.setQueryText(suggestion)
                        performSearch(saveToHistory: true)
                    } label: {
                        HStack(spacing: 12) {
                            Text(suggestion)
                                .font(Celestial.Typography.body)
                                .foregroundStyle(Celestial.Colors.secondary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(Celestial.Typography.caption)
                                .foregroundStyle(Celestial.Colors.outlineVariant)
                        }
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    CelestialHairline()
                }
            }
            .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
            .modifier(GlassPanelModifier(cornerRadius: 18))
        }
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
    }

    private func performSurpriseSearch() {
        guard canShowValidatedSuggestions,
              let suggestion = indexingService.validatedSearchSuggestions.randomElement() else { return }
        Haptics.medium()
        viewModel.setQueryText(suggestion)
        performSearch()
    }

    // Persistent progress card shown while reverse geocoding is queued,
    // running, or waiting to resume. Location-filtered searches depend on the
    // metadata this task populates, so incomplete work must remain visible.
    private func geocodingProgressStrip(_ state: GeocodingProgressState) -> some View {
        let remaining = max(0, state.total - state.completed)
        let detail: String
        switch state.phase {
        case .queued:
            detail = state.total > 0
                ? "\(remaining.formatted()) items waiting for a quiet moment"
                : "Preparing location details"
        case .running:
            detail = "\(state.completed.formatted()) of \(state.total.formatted()) complete"
        case .waitingToResume:
            detail = "\(remaining.formatted()) items will continue when Memorable is active"
        case .paused:
            detail = "\(remaining.formatted()) items will retry the next time Memorable becomes active"
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.primaryFixedDim)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finishing photo locations")
                        .font(Celestial.Typography.captionStrong)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text(detail)
                        .font(Celestial.Typography.micro)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                }
                Spacer()
            }
            if state.total > 0 {
                ProgressView(value: Double(state.completed), total: Double(state.total))
                    .accessibilityLabel(
                        "Finishing photo locations: \(state.completed) of \(state.total) complete"
                    )
            } else {
                ProgressView()
                    .accessibilityLabel("Preparing photo location processing")
            }
        }
        .tint(Celestial.Colors.primaryFixedDim)
        .padding(Celestial.Spacing.surfaceContentInset)
        .modifier(GlassPanelModifier(cornerRadius: 14))
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
        .padding(.bottom, Celestial.Spacing.stackedContainerGap)
    }

    private func searchRestrictionStrip(_ summary: SearchRestrictionSummary) -> some View {
        Button {
            showUpgrade = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.amber)
                    .accessibilityHidden(true)
                Text(summary.message)
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text("Upgrade")
                    .font(Celestial.Typography.captionStrong)
                    .foregroundStyle(Celestial.Colors.primaryDim)
            }
            .padding(.horizontal, Celestial.Spacing.surfaceContentInset)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 16,
                tint: Celestial.Colors.surfaceContainerLow.opacity(0.30)
            )
        )
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
        .padding(.bottom, Celestial.Spacing.stackedContainerGap)
        .accessibilityLabel("\(summary.message) Upgrade to Pro")
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
                    .font(Celestial.Typography.supportingEmphasized)
            }
            .celestialSecondaryButtonStyle()
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
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.primaryDim)
            }
            .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
            .padding(.top, Celestial.Spacing.sectionGap)
            .padding(.bottom, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(smartAlbums) { album in
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
                                        .font(Celestial.Typography.caption)
                                        .foregroundStyle(Celestial.Colors.primary)
                                        .padding(8)
                                }
                                Text(album.name)
                                    .font(Celestial.Typography.eyebrow)
                                    .foregroundStyle(Celestial.Colors.onSurface)
                                    .lineLimit(1)
                                    .frame(width: 108, alignment: .leading)
                            }
                            .padding(8)
                        }
                        .celestialGlassCardButtonStyle(
                            cornerRadius: 14,
                            tint: Celestial.Colors.primaryDim.opacity(0.08)
                        )
                        .accessibilityLabel("Search smart album, \(album.name)")
                        .accessibilityHint("Runs the saved search: \(album.query)")
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
                .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
            }
        }
    }

    // MARK: - Recent Queries

    private func todayMemoryView(_ memory: OnThisDaySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today in Your Memories")
                    .font(Celestial.Typography.bodyEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Spacer()
                Text("View memories")
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
            }
            .padding(.horizontal, 2)

            NavigationLink {
                OnThisDayView(captionService: captionService)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    SearchHomePhotoImage(
                        result: memory.heroPhoto.searchResult,
                        targetSize: SearchHomeCardMetrics.memoryPreviewTargetSize,
                        fillsBackdrop: true
                    )
                    .frame(height: SearchHomeCardMetrics.memoryPreviewHeight)
                    .clipped()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(memoryTitle(memory))
                                .font(Celestial.Typography.bodyStrong)
                                .foregroundStyle(Celestial.Colors.onSurface)
                            Text(memorySummary(memory))
                                .font(Celestial.Typography.caption)
                                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.right")
                            .font(Celestial.Typography.microStrong)
                            .foregroundStyle(Celestial.Colors.outlineVariant)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: SearchHomeCardMetrics.captionHeight)
                    .padding(.horizontal, 16)
                }
                .background(Celestial.Colors.surfaceContainerLow.opacity(0.74))
                .clipShape(SearchHomeCardMetrics.cardShape)
                .overlay {
                    SearchHomeCardMetrics.cardShape
                        .stroke(Celestial.Colors.hairline, lineWidth: 0.8)
                }
                .contentShape(SearchHomeCardMetrics.cardShape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Today in Your Memories, \(memoryTitle(memory))")
            .accessibilityHint("Opens memories from this day")
        }
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
    }

    private var searchHistoryView: some View {
        let items = RecentSearchHomePolicy.items(
            history: viewModel.searchHistory,
            previews: viewModel.recentSearchPreviews
        )

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Searches")
                    .font(Celestial.Typography.bodyEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Spacer()
                Menu {
                    Button("Clear recent searches", role: .destructive) {
                        viewModel.clearSearchHistory()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(Celestial.Typography.supportingEmphasized)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Recent search options")
            }
            .padding(.leading, 2)
            .padding(.bottom, 8)

            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    recentSearchTimelineRow(
                        item,
                        isFirst: item.id == items.first?.id,
                        isLast: item.id == items.last?.id
                    )
                }
            }
        }
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
    }

    private func recentSearchTimelineRow(
        _ item: RecentSearchHomeItem,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        Button {
            viewModel.setQueryText(item.query)
            performSearch(saveToHistory: true)
        } label: {
            HStack(spacing: 12) {
                RecentSearchTimelineRail(isFirst: isFirst, isLast: isLast)

                Group {
                    if let preview = item.preview,
                       FolderResultAccessPolicy.allows(
                           sourceId: preview.result.sourceId,
                           isPro: proManager.isPro
                       ) {
                        SearchHomePhotoImage(
                            result: preview.result,
                            targetSize: CGSize(
                                width: SearchHomeCardMetrics.recentThumbnailWidth * displayScale,
                                height: SearchHomeCardMetrics.recentThumbnailHeight * displayScale
                            )
                        )
                    } else {
                        RecentSearchPlaceholder()
                    }
                }
                .frame(
                    width: SearchHomeCardMetrics.recentThumbnailWidth,
                    height: SearchHomeCardMetrics.recentThumbnailHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.query)
                        .font(Celestial.Typography.supportingEmphasized)
                        .foregroundStyle(Celestial.Colors.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let metadata = recentSearchMetadata(item) {
                        Text(metadata)
                            .font(Celestial.Typography.micro)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(Celestial.Typography.microStrong)
                    .foregroundStyle(Celestial.Colors.outlineVariant)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                viewModel.removeSearchHistory(at: item.historyIndex)
            } label: {
                Label("Delete recent search", systemImage: "trash")
            }
        }
        .accessibilityLabel("Search again for \(item.query)")
        .accessibilityHint("Runs this recent search")
    }

    private func recentSearchMetadata(_ item: RecentSearchHomeItem) -> String? {
        guard let preview = item.preview else { return nil }
        var parts: [String] = []
        if let searchedAt = preview.searchedAt {
            parts.append(relativeSearchDate(searchedAt))
        }
        if preview.resultCount > 0 {
            parts.append(
                "\(preview.resultCount.formatted()) \(preview.resultCount == 1 ? "result" : "results")"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Last Results (when search cleared)

    private var lastResultsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Celestial.Typography.footnote)
                    .foregroundStyle(Celestial.Colors.tertiaryDim)
                Text("Results for \"\(viewModel.lastQuery)\"")
                    .font(Celestial.Typography.eyebrow)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                Spacer()
                Button("Dismiss") {
                    viewModel.dismissLastResults()
                }
                .font(Celestial.Typography.captionStrong)
                .foregroundStyle(Celestial.Colors.primaryFixedDim)
            }
            .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
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
                .font(Celestial.Typography.supporting)
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
                .font(Celestial.Typography.supporting)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var noResultsState: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = viewModel.filterSummary {
                Text(SearchResultsPresentation.noResultsTitle(
                    summary: summary,
                    geocodingProgress: indexingService.geocodingProgress
                ))
                    .font(Celestial.Typography.interfaceTitle)
                    .foregroundStyle(Celestial.Colors.onSurface)

                Text(SearchResultsPresentation.noResultsExplanation(
                    summary: summary,
                    geocodingProgress: indexingService.geocodingProgress
                ))
                    .font(Celestial.Typography.body)
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
                .padding(.top, Celestial.Spacing.sectionGap)

                if !viewModel.fallbackResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CLOSE TO WHAT YOU DESCRIBED")
                            .font(Celestial.Typography.eyebrow)
                            .tracking(0.6)
                            .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                            .padding(.top, Celestial.Spacing.sectionGap)

                        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(viewModel.fallbackResults) { result in
                                Button {
                                    if result.isVideo {
                                        if let asset = PhotoLibrary.getAsset(by: result.localIdentifier) {
                                            presentVideoPlayer(for: asset)
                                        }
                                    } else {
                                        // Use fallback results for the viewer since main results are empty.
                                        viewModel.useFallbackResultsForViewer()
                                        selectedPhoto = result
                                    }
                                } label: {
                                    FallbackThumbnail(result: result)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(result.isVideo ? "Video result" : "Photo result")
                            }
                        }
                    }
                }
            } else {
                Text("No matching photos")
                    .font(Celestial.Typography.interfaceTitle)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Text("Try a broader description or remove a detail.")
                    .font(Celestial.Typography.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
        .padding(.top, Celestial.Spacing.sectionGap)
    }

    private func relaxationButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Celestial.Typography.bodyEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(Celestial.Typography.caption)
                    .foregroundStyle(Celestial.Colors.outline)
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .overlay(alignment: .top) { CelestialHairline() }
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

    private var indexReadinessCheckingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Celestial.Colors.primaryDim)
            Text(searchPreparationStatusText)
                .font(Celestial.Typography.supporting)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 52)
        .accessibilityElement(children: .combine)
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
                        .font(Celestial.Typography.interfaceTitle3)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    resumeIndexingButton
                } else {
                    Text("Search your \(searchEngine.totalSize) photos & videos")
                        .font(Celestial.Typography.interfaceTitle3)
                        .foregroundStyle(Celestial.Colors.onSurface)
                }
                Text("Describe what you're looking for")
                    .font(Celestial.Typography.body)
                    .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                    .padding(.top, 10)
            } else {
                if indexingService.indexRebuildRequired {
                    Text("Update the search index")
                        .font(Celestial.Typography.interfaceTitle)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("Memorable improved how it understands image orientation. Rebuild once to keep search results accurate.")
                        .font(Celestial.Typography.body)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .lineSpacing(4)
                        .padding(.top, 12)
                    Button(action: { indexingService.rebuildRequiredIndex() }) {
                        Label("Rebuild Search Index", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .celestialPrimaryButtonStyle()
                    .padding(.top, 24)
                    .accessibilityHint("Clears the incompatible search index and rebuilds it on this device")
                    .disabled(!database.allowsIndexingWrites)
                } else {
                    Text("Make your library searchable")
                        .font(Celestial.Typography.interfaceTitle)
                        .foregroundStyle(Celestial.Colors.onSurface)
                    Text("A one-time scan runs on this iPhone. Photos become searchable as it goes.")
                        .font(Celestial.Typography.body)
                        .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                        .lineSpacing(4)
                        .padding(.top, 12)
                    Button(action: { indexingService.startIndexing() }) {
                        Text("Build Search Index")
                            .frame(maxWidth: .infinity)
                    }
                    .celestialPrimaryButtonStyle()
                    .padding(.top, 24)
                    .accessibilityHint("Scans your photo library and builds a searchable index")
                    .disabled(!database.allowsIndexingWrites)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Celestial.Spacing.pageHorizontalInset)
        .padding(.top, 46)
    }

    // MARK: - Results Grid (Masonry Layout)

    private func controlsPanel(filteredCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !proManager.isPro && indexingService.hitFreeLimit && viewModel.hasCompletedFirstSearch && !viewModel.upgradeBannerDismissed {
                upgradeBanner
            }

            HStack(spacing: 10) {
                Text("\(filteredCount) \(filteredCount == 1 ? "result" : "results")")
                    .font(Celestial.Typography.supportingEmphasized)
                    .foregroundStyle(Celestial.Colors.onSurface)
                    .contentTransition(.numericText())
                    .lineLimit(1)

                Spacer(minLength: 8)

                Menu {
                    ForEach(SearchMediaFilter.allCases, id: \.self) { filter in
                        Button {
                            Haptics.selection()
                            viewModel.setMediaFilter(filter)
                        } label: {
                            if viewModel.mediaFilter == filter {
                                Label(filter.label, systemImage: "checkmark")
                            } else {
                                Text(filter.label)
                            }
                        }
                    }
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(
                            viewModel.mediaFilter.label,
                            systemImage: "line.3.horizontal.decrease"
                        )
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .font(Celestial.Typography.captionStrong)
                }
                .celestialGlassCapsuleButtonStyle(
                    tint: Celestial.Colors.surfaceContainerHigh.opacity(0.22),
                    foreground: Celestial.Colors.onSurfaceVariant
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Filter results by media type: \(viewModel.mediaFilter.label)")

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
                    ViewThatFits(in: .horizontal) {
                        Label(
                            viewModel.sortMode == .relevance ? "Relevance" : "Recent",
                            systemImage: "arrow.up.arrow.down"
                        )
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .font(Celestial.Typography.captionStrong)
                }
                .celestialGlassCapsuleButtonStyle(
                    tint: Celestial.Colors.primaryDim.opacity(0.14),
                    foreground: Celestial.Colors.primaryDim
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    "Sort results by \(viewModel.sortMode == .relevance ? "relevance" : "recent")"
                )

                if !smartAlbums.contains(where: { $0.query.lowercased() == viewModel.queryText.lowercased() }) {
                    Button {
                        albumName = viewModel.queryText
                        showSaveAlbum = true
                    } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .celestialGlassCircleButtonStyle(
                        tint: Celestial.Colors.amber.opacity(0.16),
                        foreground: Celestial.Colors.amber
                    )
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Circle())
                    .accessibilityLabel("Save search as an album")
                }
            }

            if let summary = viewModel.filterSummary {
                interpretedQueryFacets(summary)
            }
        }
        .padding(Celestial.Spacing.surfaceContentInset)
        .modifier(
            GlassPanelModifier(
                cornerRadius: 16,
                tint: Celestial.Colors.surfaceContainerLow.opacity(0.30)
            )
        )
        .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
        .padding(.bottom, Celestial.Spacing.stackedContainerGap)
    }

    private func interpretedQueryFacets(_ summary: FilterSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !summary.visualQuery.isEmpty {
                    queryFacet(
                        summary.visualQuery,
                        systemImage: "photo",
                        accent: Celestial.Colors.primaryDim
                    )
                }
                if let location = summary.locationDescription {
                    queryFacet(
                        location,
                        systemImage: "location.fill",
                        accent: Celestial.Colors.emerald
                    )
                }
                if let date = summary.dateDescription {
                    queryFacet(
                        date,
                        systemImage: "calendar",
                        accent: Celestial.Colors.amber
                    )
                }
            }
        }
        .accessibilityLabel("Search details")
    }

    private func queryFacet(
        _ label: String,
        systemImage: String,
        accent: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(label)
                .foregroundStyle(Celestial.Colors.onSurfaceVariant)
                .lineLimit(1)
        }
        .font(Celestial.Typography.caption)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .modifier(
            GlassCapsuleModifier(
                tint: accent.opacity(0.10)
            )
        )
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
                            .font(Celestial.Typography.footnote)
                            .foregroundStyle(Celestial.Colors.outline)
                    }
                    .padding(.horizontal, Celestial.Spacing.surfaceHorizontalInset)
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
                        .font(Celestial.Typography.button)
                        .foregroundStyle(Celestial.Colors.primary)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }

            if !visible.isEmpty {
                Text(AppCopy.aiDisclaimer)
                    .font(Celestial.Typography.micro)
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
        Button {
            handleResultTap(result)
        } label: {
            PhotoThumbnailView(result: result)
        }
            .buttonStyle(.plain)
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
    }

    // MARK: - Actions

    private func startFindSimilar(photoID: String) {
        guard proManager.isPro else {
            showUpgrade = true
            return
        }
        let engine = searchEngine
        let featurePolicy = ProFeatureAccessPolicy(isPro: proManager.isPro)
        viewModel.submitSimilaritySearch {
            await SimilaritySearchOperation.run {
                engine.findSimilar(photoId: photoID, featurePolicy: featurePolicy)
            }
        }
    }

    private func cancelFindSimilar() {
        viewModel.cancelSimilaritySearch()
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

    private func memoryTitle(_ memory: OnThisDaySummary) -> String {
        let currentYear = Calendar.current.component(.year, from: Date())
        let yearsAgo = max(1, currentYear - memory.mostRecentYear)
        return "\(yearsAgo) \(yearsAgo == 1 ? "year" : "years") ago today"
    }

    private func memorySummary(_ memory: OnThisDaySummary) -> String {
        let photos = "\(memory.photoCount.formatted()) \(memory.photoCount == 1 ? "photo" : "photos")"
        guard memory.yearCount > 1 else { return photos }
        return "\(photos) across \(memory.yearCount.formatted()) years"
    }

    private func relativeSearchDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func requestTodayMemoryRefresh() {
        let canStart = todayMemoryLoadTask == nil
            && isViewVisible
            && indexingService.isReady
            && !indexingService.progress.isRunning
            && viewModel.queryText.isEmpty
            && viewModel.results.isEmpty
            && viewModel.lastResults.isEmpty
        guard todayMemoryRefreshState.request(canStart: canStart) else { return }

        let database = database
        todayMemoryLoadTask = Task { @MainActor in
            var wasCancelled = false
            do {
                let summary = try await CancellableDetachedOperation.run {
                    try database.onThisDaySummary()
                }
                wasCancelled = Task.isCancelled
                if !wasCancelled {
                    if let summary,
                       FolderResultAccessPolicy.allows(
                           sourceId: summary.heroPhoto.sourceId,
                           isPro: proManager.isPro
                       ) {
                        todayMemory = summary
                    } else {
                        todayMemory = nil
                    }
                    isTodayMemoryResolved = true
                }
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                logger.error("Failed to refresh today's memories: \(error.safeDiagnosticCode)")
                isTodayMemoryResolved = true
            }
            todayMemoryLoadTask = nil
            if todayMemoryRefreshState.finish(wasCancelled: wasCancelled) {
                requestTodayMemoryRefresh()
            }
        }
    }

    private func performSearch(saveToHistory: Bool = false) {
        guard !viewModel.normalizedQuery.isEmpty else { return }
        Haptics.light()
        viewModel.submitSearch(saveToHistory: saveToHistory)
    }

}

private enum SearchHomeCardMetrics {
    static let memoryPreviewHeight: CGFloat = 156
    static let memoryPreviewTargetSize = CGSize(width: 1_024, height: 1_024)
    static let captionHeight: CGFloat = 62
    static let cornerRadius: CGFloat = 20
    static let recentThumbnailWidth: CGFloat = 64
    static let recentThumbnailHeight: CGFloat = 48

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

enum MemoryCardLayout {
    static let minimumAspectRatio: CGFloat = 3.0 / 4.0
    static let maximumAspectRatio: CGFloat = 16.0 / 9.0
    static let fallbackAspectRatio: CGFloat = 4.0 / 3.0
    static let targetWidth: CGFloat = 1_024

    static func aspectRatio(for photo: IndexedPhotoReference) -> CGFloat {
        guard photo.pixelWidth > 0, photo.pixelHeight > 0 else {
            return fallbackAspectRatio
        }
        let aspectRatio = CGFloat(photo.pixelWidth) / CGFloat(photo.pixelHeight)
        return min(max(aspectRatio, minimumAspectRatio), maximumAspectRatio)
    }

    static func targetSize(
        for photo: IndexedPhotoReference,
        width: CGFloat = targetWidth
    ) -> CGSize {
        CGSize(width: width, height: width / aspectRatio(for: photo))
    }
}

private struct RecentSearchTimelineRail: View {
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Celestial.Colors.primaryDim.opacity(0.24))
                Rectangle()
                    .fill(isLast ? Color.clear : Celestial.Colors.primaryDim.opacity(0.24))
            }
            .frame(width: 1)
            Circle()
                .fill(Celestial.Colors.primaryDim)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle()
                        .stroke(Celestial.Colors.background, lineWidth: 2)
                }
        }
        .frame(width: 10, height: 68)
        .accessibilityHidden(true)
    }
}

private struct SearchHomePhotoImage: View {
    let result: SearchResult
    let targetSize: CGSize
    var fillsBackdrop = false
    @State private var image: UIImage?
    @State private var imageLoadGeneration: UInt = 0
    @State private var imageLoadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RecentSearchPlaceholder()

            if let image {
                if fillsBackdrop {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 20)
                        .scaleEffect(1.08)
                        .opacity(0.55)
                        .accessibilityHidden(true)
                }

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: result.id) {
            imageLoadTask?.cancel()
            let task = Task { @MainActor in
                imageLoadGeneration &+= 1
                let generation = imageLoadGeneration
                image = nil
                let loaded = await PhotoLibrary.loadPreviewImage(
                    for: result,
                    targetSize: targetSize
                )
                guard ImageLoadGenerationPolicy.acceptsCompletion(
                    startedGeneration: generation,
                    currentGeneration: imageLoadGeneration,
                    isCancelled: Task.isCancelled
                ) else { return }
                image = loaded
            }
            imageLoadTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            imageLoadTask?.cancel()
            imageLoadTask = nil
            imageLoadGeneration &+= 1
            MemoryPressureReleasePolicy.release(&image)
        }
        .accessibilityHidden(true)
    }
}

private struct RecentSearchPlaceholder: View {
    var body: some View {
        LinearGradient(
            colors: [
                Celestial.Colors.surfaceBright,
                Celestial.Colors.secondaryContainer,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(Celestial.Colors.primaryFixedDim.opacity(0.58))
        }
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

enum SearchResultsPresentation {
    static func noResultsTitle(
        summary: FilterSummary,
        geocodingProgress: GeocodingProgressState?
    ) -> String {
        if summary.locationDescription != nil, geocodingProgress != nil {
            return "Still resolving photo locations"
        }
        return "Nothing matches all of that"
    }

    static func noResultsExplanation(
        summary: FilterSummary,
        geocodingProgress: GeocodingProgressState?
    ) -> String {
        var details = [summary.visualQuery.isEmpty ? "matching photos" : "\(summary.visualQuery) photos"]
        if let location = summary.locationDescription { details.append("near \(location)") }
        if let date = summary.dateDescription { details.append("from \(date)") }
        let searchDescription = details.joined(separator: " ")

        guard summary.locationDescription != nil, let progress = geocodingProgress else {
            return "Looked for \(searchDescription). Try relaxing one detail."
        }

        let progressDescription: String
        switch progress.phase {
        case .queued:
            progressDescription = "Location processing is queued"
        case .running:
            progressDescription = "Location processing is \(progress.completed) of \(progress.total) complete"
        case .waitingToResume:
            progressDescription = "Location processing will continue when Memorable is active"
        case .paused:
            progressDescription = "Location processing is paused and will retry the next time Memorable becomes active"
        }
        return "No verified matches for \(searchDescription) yet. \(progressDescription), so more results may appear as it finishes."
    }
}
