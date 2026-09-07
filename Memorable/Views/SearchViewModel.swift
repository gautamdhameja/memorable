import Foundation
import Combine

enum SearchSortMode: String {
    case relevance
    case recent
}

enum SearchMediaFilter: String, CaseIterable {
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

@MainActor
final class SearchViewModel: ObservableObject {
    static let sortModeStorageKey = "searchSortMode"
    static let initialVisibleCount = 50

    struct Dependencies {
        let prioritizeUserSearch: () -> Void
        let isSemanticSearchReady: () -> Bool
        let isIndexReady: () -> Bool
        let isIndexLoaded: () -> Bool
        let isMaintenanceWorkIdle: () -> Bool
        let prepareForSearch: () async throws -> Void
        let search: (String) async throws -> SearchResponse
        let searchForHistoryPreview: (String) async throws -> SearchResponse
        let detectScreenshotIDs: ([SearchResult]) async -> Set<String>
        let validResultIDs: ([SearchResult]) async -> Set<String>
        let addHistory: (String, SearchResult, Int) async -> Void
        let backfillHistoryPreviews: ([RecentSearchPreview]) async -> Bool
        let loadHistory: () async -> [String]
        let loadHistoryPreviews: () async -> [RecentSearchPreview]
        let clearHistory: () async -> Void
        let removeHistory: (Int) async -> Void
        let now: () -> TimeInterval
        var searchActivityChanged: (Bool) -> Void = { _ in }
    }

    @Published private(set) var queryText = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var fallbackResults: [SearchResult] = []
    @Published private(set) var filterSummary: FilterSummary?
    @Published private(set) var restrictionSummary: SearchRestrictionSummary?
    @Published private(set) var isSearching = false {
        didSet {
            if isSearching != oldValue {
                dependencies.searchActivityChanged(isSearching)
            }
        }
    }
    @Published private(set) var searchError: String?
    @Published private(set) var lastSearchedQuery: String?
    @Published private(set) var screenshotIDs: Set<String> = []
    @Published private(set) var mediaFilter: SearchMediaFilter = .all
    @Published private(set) var sortMode: SearchSortMode = .relevance
    @Published private(set) var visibleCount = SearchViewModel.initialVisibleCount
    @Published private(set) var searchTimeMs = 0
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var recentSearchPreviews: [RecentSearchPreview] = []
    @Published private(set) var isSearchHistoryLoaded = false
    @Published private(set) var lastQuery = ""
    @Published private(set) var lastResults: [SearchResult] = []
    @Published private(set) var hasCompletedFirstSearch = false
    @Published private(set) var searchesSinceDismiss = 0
    @Published private(set) var upgradeBannerDismissed = false

    private(set) var activeSearchID: Int?

    private let dependencies: Dependencies
    private var isIndexResetting = false
    private var searchSequence = 0
    private var validationSequence = 0
    private var screenshotSequence = 0
    private var searchTask: Task<Void, Never>?
    private var isSimilaritySearch = false
    private var visibleResultValidationTask: Task<Void, Never>?
    private var screenshotDetectionTask: Task<Void, Never>?
    private var recentSearchPreviewBackfillTask: Task<Void, Never>?
    private var recentSearchPreviewBackfillSequence = 0
    private var recentSearchPreviewNoResultQueries = Set<String>()
    private var historyUpdateTask: Task<Void, Never>?
    private var historyUpdateID = 0
    private var historyGeneration = 0
    private var hasRequestedHistoryUpdate = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var normalizedQuery: String {
        Self.normalize(queryText)
    }

    var hasNoResultsForCurrentQuery: Bool {
        !normalizedQuery.isEmpty
            && results.isEmpty
            && !isSearching
            && lastSearchedQuery == normalizedQuery
    }

    var currentDisplayedResults: [SearchResult] {
        if !results.isEmpty { return results }
        if !lastResults.isEmpty { return lastResults }
        return []
    }

    var shouldShowDiscoverySuggestions: Bool {
        isSearchHistoryLoaded && searchHistory.isEmpty
    }

    func setQueryText(_ value: String) {
        queryText = QueryInputPolicy.bounded(value)
        if !normalizedQuery.isEmpty {
            cancelRecentSearchPreviewBackfill()
        }
        guard normalizedQuery.isEmpty else { return }

        #if DEBUG
        logger.info("[SearchViewModel] Clearing search state because query text is empty")
        #endif
        cancelActiveSearch(reason: "searchText cleared")
        visibleResultValidationTask?.cancel()
        screenshotDetectionTask?.cancel()
        validationSequence += 1
        screenshotSequence += 1
        results = []
        fallbackResults = []
        filterSummary = nil
        restrictionSummary = nil
        searchError = nil
        lastSearchedQuery = nil
        lastResults = []
        isSearching = false
        activeSearchID = nil
        searchTask = nil
        startRecentSearchPreviewBackfill()
    }

    func setSortMode(rawValue: String) {
        selectSortMode(SearchSortMode(rawValue: rawValue) ?? .relevance)
    }

    func selectSortMode(_ mode: SearchSortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
    }

    func setMediaFilter(_ filter: SearchMediaFilter) {
        mediaFilter = filter
        visibleCount = Self.initialVisibleCount
    }

    func filteredResults(_ input: [SearchResult]) -> [SearchResult] {
        let sorted: [SearchResult]
        switch sortMode {
        case .relevance:
            sorted = input
        case .recent:
            sorted = input.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
        }

        switch mediaFilter {
        case .all:
            return sorted
        case .photos:
            return sorted.filter { !$0.isVideo && !screenshotIDs.contains($0.id) }
        case .videos:
            return sorted.filter(\.isVideo)
        case .screenshots:
            return sorted.filter { screenshotIDs.contains($0.id) }
        }
    }

    func showAllResults(count: Int) {
        visibleCount = count
    }

    func loadSearchHistory() {
        enqueueHistoryUpdate {}
    }

    func setSearchHistory(
        _ history: [String],
        previews: [RecentSearchPreview] = []
    ) {
        searchHistory = history
        recentSearchPreviews = previews
        isSearchHistoryLoaded = true
    }

    func applyInitialSearchHistory(
        _ history: [String],
        previews: [RecentSearchPreview]
    ) {
        guard !isSearchHistoryLoaded, !hasRequestedHistoryUpdate else { return }
        setSearchHistory(history, previews: previews)
    }

    func beginIndexReset() {
        isIndexResetting = true
        historyGeneration += 1
        setQueryText("")
        cancelRecentSearchPreviewBackfill()
        dismissLastResults()
    }

    func finishIndexReset(didReset: Bool) {
        if didReset {
            setSearchHistory([])
        }
        isIndexResetting = false
    }

    func clearSearchHistory() {
        guard !isIndexResetting else { return }
        cancelRecentSearchPreviewBackfill()
        enqueueHistoryUpdate { [dependencies] in await dependencies.clearHistory() }
        dismissLastResults()
    }

    func removeSearchHistory(at index: Int) {
        guard !isIndexResetting, searchHistory.indices.contains(index) else { return }
        let query = searchHistory[index]
        enqueueHistoryUpdate { [dependencies] in
            let current = await dependencies.loadHistory()
            if let currentIndex = current.firstIndex(of: query) {
                await dependencies.removeHistory(currentIndex)
            }
        }
    }

    /// Keep accepted writes ordered without making the UI wait on SQLite.
    /// Reset invalidates queued writes and drains any already-started write
    /// before deleting history in the index-reset transaction.
    @discardableResult
    private func enqueueHistoryUpdate(
        _ mutation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = historyUpdateTask
        let generation = historyGeneration
        historyUpdateID += 1
        let updateID = historyUpdateID
        hasRequestedHistoryUpdate = true
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if historyUpdateID == updateID { historyUpdateTask = nil }
            }
            guard generation == historyGeneration, !isIndexResetting else { return }
            await mutation()
            guard generation == historyGeneration, !isIndexResetting else { return }
            let history = await dependencies.loadHistory()
            let previews = await dependencies.loadHistoryPreviews()
            guard generation == historyGeneration, !isIndexResetting else { return }
            setSearchHistory(history, previews: previews)
        }
        historyUpdateTask = task
        return task
    }

    func waitForHistoryUpdates() async {
        await historyUpdateTask?.value
    }

    func dismissLastResults() {
        lastResults = []
        lastQuery = ""
    }

    func dismissUpgradeBanner() {
        upgradeBannerDismissed = true
        searchesSinceDismiss = 0
    }

    func handleMemoryPressure() {
        searchSequence += 1
        validationSequence += 1
        screenshotSequence += 1
        searchTask?.cancel()
        visibleResultValidationTask?.cancel()
        screenshotDetectionTask?.cancel()
        cancelRecentSearchPreviewBackfill()
        searchTask = nil
        visibleResultValidationTask = nil
        screenshotDetectionTask = nil
        activeSearchID = nil
        isSearching = false
        results = []
        fallbackResults = []
        lastResults = []
        restrictionSummary = nil
        screenshotIDs = []
    }

    /// Invalidates the active search generation before cancelling so a search
    /// implementation that finishes cooperatively cannot publish Pro results
    /// after StoreKit revokes the entitlement.
    func handleProEntitlementRevoked() {
        searchSequence += 1
        searchTask?.cancel()
        searchTask = nil
        activeSearchID = nil
        isSearching = false
    }

    /// Similarity and text requests share the same generation and task so
    /// clearing, a newer request, or entitlement revocation invalidates both.
    func submitSimilaritySearch(operation: @escaping () async -> [SearchResult]) {
        guard !isIndexResetting else { return }
        let searchID = beginSearch(isSimilarity: true)
        let startTime = dependencies.now()
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if activeSearchID == searchID {
                    isSearching = false
                    activeSearchID = nil
                    searchTask = nil
                }
            }
            let similar = await operation()
            guard !Task.isCancelled, activeSearchID == searchID else { return }
            queryText = "Similar to selected photo"
            results = similar
            lastSearchedQuery = queryText
            fallbackResults = []
            filterSummary = nil
            restrictionSummary = nil
            searchError = nil
            mediaFilter = .all
            screenshotIDs = []
            lastQuery = queryText
            lastResults = similar
            searchTimeMs = Int((dependencies.now() - startTime) * 1_000)
            startScreenshotDetection(for: similar)
        }
    }

    func cancelSimilaritySearch() {
        guard isSimilaritySearch else { return }
        cancelActiveSearch(reason: "similarity dismissed")
    }

    func useFallbackResultsForViewer() {
        lastResults = fallbackResults.filter { !$0.isVideo }
    }

    func submitSearch(saveToHistory: Bool = false) {
        let query = normalizedQuery
        guard !isIndexResetting, !query.isEmpty else { return }

        let searchID = beginSearch(isSimilarity: false)
        let startTime = dependencies.now()

        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.runSearch(
                query: query,
                searchID: searchID,
                saveToHistory: saveToHistory,
                startTime: startTime
            )
        }
    }

    private func beginSearch(isSimilarity: Bool) -> Int {
        cancelRecentSearchPreviewBackfill()
        cancelActiveSearch(reason: "new search submitted")
        validationSequence += 1
        visibleResultValidationTask?.cancel()
        screenshotSequence += 1
        screenshotDetectionTask?.cancel()
        isSearching = true
        searchError = nil
        visibleCount = Self.initialVisibleCount
        searchSequence += 1
        let searchID = searchSequence
        activeSearchID = searchID
        isSimilaritySearch = isSimilarity
        return searchID
    }

    func validateVisibleResults(reason: String) {
        let currentResults = results
        let currentLastResults = lastResults
        guard !currentResults.isEmpty || !currentLastResults.isEmpty else {
            #if DEBUG
            logger.info("[SearchViewModel] visible-result validation skipped reason='\(reason)' because no visible results exist")
            #endif
            return
        }

        validationSequence += 1
        let validationID = validationSequence
        let resultIDs = Set(currentResults.map(\.id))
        let lastResultIDs = Set(currentLastResults.map(\.id))
        var seenCandidateIDs = Set<String>()
        let candidates = (currentResults + currentLastResults).filter {
            seenCandidateIDs.insert($0.id).inserted
        }

        visibleResultValidationTask?.cancel()
        visibleResultValidationTask = Task { [weak self] in
            guard let self else { return }
            let validIDs = await dependencies.validResultIDs(candidates)
            guard !Task.isCancelled,
                  validationID == validationSequence,
                  Set(results.map(\.id)) == resultIDs,
                  Set(lastResults.map(\.id)) == lastResultIDs else {
                #if DEBUG
                logger.info("[SearchViewModel] visible-result validation skipped reason='\(reason)' because results changed")
                #endif
                return
            }

            let updatedResults = currentResults.filter { validIDs.contains($0.id) }
            let updatedLastResults = currentLastResults.filter { validIDs.contains($0.id) }
            if updatedResults != currentResults || updatedLastResults != currentLastResults {
                results = updatedResults
                lastResults = updatedLastResults
            }
        }
    }

    func waitForCurrentSearch() async {
        await searchTask?.value
    }

    func startRecentSearchPreviewBackfill() {
        guard !isIndexResetting else { return }
        guard recentSearchPreviewBackfillTask == nil,
              normalizedQuery.isEmpty,
              isSearchHistoryLoaded,
              dependencies.isSemanticSearchReady(),
              dependencies.isIndexReady(),
              dependencies.isMaintenanceWorkIdle() else { return }

        let missingQueries = missingRecentSearchPreviewQueries().filter {
            !recentSearchPreviewNoResultQueries.contains($0)
        }
        guard !missingQueries.isEmpty else { return }

        recentSearchPreviewBackfillSequence += 1
        let backfillID = recentSearchPreviewBackfillSequence
        recentSearchPreviewBackfillTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await backfillMissingRecentSearchPreviews(missingQueries, backfillID: backfillID)
        }
    }

    func waitForRecentSearchPreviewBackfill() async {
        await recentSearchPreviewBackfillTask?.value
    }

    func cancelRecentSearchPreviewBackfill() {
        // Retain the handle until the task's defer clears it so a
        // non-cooperative search cannot overlap a replacement backfill.
        recentSearchPreviewBackfillTask?.cancel()
    }

    private func missingRecentSearchPreviewQueries() -> [String] {
        RecentSearchHomePolicy.missingPreviewQueries(
            history: searchHistory,
            previews: recentSearchPreviews
        )
    }

    private func backfillMissingRecentSearchPreviews(
        _ missingQueries: [String],
        backfillID: Int
    ) async {
        defer {
            if recentSearchPreviewBackfillSequence == backfillID {
                recentSearchPreviewBackfillTask = nil
            }
        }
        var previews: [RecentSearchPreview] = []
        previews.reserveCapacity(missingQueries.count)
        for query in missingQueries {
            guard !Task.isCancelled, normalizedQuery.isEmpty else { return }
            do {
                let response = try await dependencies.searchForHistoryPreview(query)
                guard !Task.isCancelled, normalizedQuery.isEmpty else { return }
                guard let previewResult = response.results.first else {
                    recentSearchPreviewNoResultQueries.insert(query)
                    continue
                }
                previews.append(RecentSearchPreview(
                    query: query,
                    result: previewResult,
                    resultCount: response.results.count
                ))
            } catch is CancellationError {
                return
            } catch {
                logger.error("Failed to backfill recent search preview: \(error.safeDiagnosticCode)")
            }
        }
        guard !Task.isCancelled,
              normalizedQuery.isEmpty,
              recentSearchPreviewBackfillSequence == backfillID else { return }
        let completedPreviews = previews
        await enqueueHistoryUpdate { [dependencies] in
            _ = await dependencies.backfillHistoryPreviews(completedPreviews)
        }.value
    }

    func waitForVisibleResultValidation() async {
        await visibleResultValidationTask?.value
    }

    func waitForScreenshotDetection() async {
        await screenshotDetectionTask?.value
    }

    private func runSearch(
        query: String,
        searchID: Int,
        saveToHistory: Bool,
        startTime: TimeInterval
    ) async {
        #if DEBUG
        logger.info("[SearchViewModel #\(searchID)] start saveToHistory=\(saveToHistory)")
        #endif
        defer {
            if activeSearchID == searchID {
                isSearching = false
                activeSearchID = nil
                searchTask = nil
            }
        }

        do {
            dependencies.prioritizeUserSearch()
            if !dependencies.isSemanticSearchReady() || !dependencies.isIndexReady() {
                try await dependencies.prepareForSearch()
            }

            guard dependencies.isIndexReady() || dependencies.isIndexLoaded() else {
                if activeSearchID == searchID {
                    searchError = "Index your photos before searching."
                }
                return
            }
            guard activeSearchID == searchID else { return }

            let response = try await dependencies.search(query)
            guard !Task.isCancelled, activeSearchID == searchID else { return }

            results = response.results
            lastSearchedQuery = query
            fallbackResults = response.fallbackResults
            filterSummary = response.filtersApplied
            restrictionSummary = response.restrictionSummary
            mediaFilter = .all
            searchTimeMs = Int((dependencies.now() - startTime) * 1_000)
            startScreenshotDetection(for: response.results)

            if !response.results.isEmpty {
                lastQuery = query
                lastResults = response.results
                recordSuccessfulSearch()
                if saveToHistory {
                    await enqueueHistoryUpdate { [dependencies] in
                        await dependencies.addHistory(query, response.results[0], response.results.count)
                    }.value
                }
            }
        } catch {
            logger.error("[SearchViewModel #\(searchID)] Search failed: \(error.safeDiagnosticCode)")
            if activeSearchID == searchID {
                searchError = UserFacingErrorMessage.message(
                    for: error,
                    fallback: "Search couldn't be completed. Try again."
                )
                results = []
            }
        }
    }

    private func startScreenshotDetection(for searchResults: [SearchResult]) {
        screenshotSequence += 1
        let detectionID = screenshotSequence
        let resultIDs = Set(searchResults.map(\.id))
        let photoResults = searchResults.filter { !$0.isVideo }

        screenshotDetectionTask?.cancel()
        screenshotDetectionTask = Task { [weak self] in
            guard let self else { return }
            let detected = await dependencies.detectScreenshotIDs(photoResults)
            guard !Task.isCancelled,
                  detectionID == screenshotSequence,
                  Set(results.map(\.id)) == resultIDs else { return }
            screenshotIDs = detected
        }
    }

    private func recordSuccessfulSearch() {
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

    private func cancelActiveSearch(reason: String) {
        guard let task = searchTask else {
            #if DEBUG
            logger.info("[SearchViewModel] cancel skipped reason='\(reason)' activeSearchID=\(self.activeSearchID.map(String.init) ?? "nil")")
            #endif
            return
        }
        searchSequence += 1
        activeSearchID = nil
        searchTask = nil
        isSearching = false
        task.cancel()
    }

    private static func normalize(_ value: String) -> String {
        QueryInputPolicy.bounded(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
