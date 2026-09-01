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
        let prepareForSearch: () async throws -> Void
        let search: (String) async throws -> SearchResponse
        let detectScreenshotIDs: ([SearchResult]) async -> Set<String>
        let validResultIDs: ([SearchResult]) async -> Set<String>
        let addHistory: (String) -> Void
        let loadHistory: () -> [String]
        let clearHistory: () -> Void
        let removeHistory: (Int) -> Void
        let now: () -> TimeInterval
    }

    @Published private(set) var queryText = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var fallbackResults: [SearchResult] = []
    @Published private(set) var filterSummary: FilterSummary?
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    @Published private(set) var lastSearchedQuery: String?
    @Published private(set) var screenshotIDs: Set<String> = []
    @Published private(set) var mediaFilter: SearchMediaFilter = .all
    @Published private(set) var sortMode: SearchSortMode = .relevance
    @Published private(set) var visibleCount = SearchViewModel.initialVisibleCount
    @Published private(set) var searchTimeMs = 0
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var isSearchHistoryLoaded = false
    @Published private(set) var lastQuery = ""
    @Published private(set) var lastResults: [SearchResult] = []
    @Published private(set) var hasCompletedFirstSearch = false
    @Published private(set) var searchesSinceDismiss = 0
    @Published private(set) var upgradeBannerDismissed = false

    private(set) var activeSearchID: Int?

    private let dependencies: Dependencies
    private var searchSequence = 0
    private var validationSequence = 0
    private var screenshotSequence = 0
    private var searchTask: Task<Void, Never>?
    private var visibleResultValidationTask: Task<Void, Never>?
    private var screenshotDetectionTask: Task<Void, Never>?

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
        searchError = nil
        lastSearchedQuery = nil
        lastResults = []
        isSearching = false
        activeSearchID = nil
        searchTask = nil
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
        setSearchHistory(dependencies.loadHistory())
    }

    func setSearchHistory(_ history: [String]) {
        searchHistory = history
        isSearchHistoryLoaded = true
    }

    func clearSearchHistory() {
        dependencies.clearHistory()
        setSearchHistory([])
        dismissLastResults()
    }

    func removeSearchHistory(at index: Int) {
        dependencies.removeHistory(index)
        setSearchHistory(dependencies.loadHistory())
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
        searchTask = nil
        visibleResultValidationTask = nil
        screenshotDetectionTask = nil
        activeSearchID = nil
        isSearching = false
        results = []
        fallbackResults = []
        lastResults = []
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

    func applySimilarResults(_ similarResults: [SearchResult]) {
        results = similarResults
        queryText = "Similar to selected photo"
        lastSearchedQuery = queryText
    }

    func useFallbackResultsForViewer() {
        lastResults = fallbackResults.filter { !$0.isVideo }
    }

    func submitSearch(saveToHistory: Bool = false) {
        let query = normalizedQuery
        guard !query.isEmpty else { return }

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
            mediaFilter = .all
            searchTimeMs = Int((dependencies.now() - startTime) * 1_000)
            startScreenshotDetection(for: response.results)

            if !response.results.isEmpty {
                if saveToHistory {
                    dependencies.addHistory(query)
                    setSearchHistory(dependencies.loadHistory())
                }
                lastQuery = query
                lastResults = response.results
                recordSuccessfulSearch()
            }
        } catch {
            logger.error("[SearchViewModel #\(searchID)] Search failed: \(error.safeDiagnosticCode)")
            if activeSearchID == searchID {
                searchError = "Search failed: \(error.localizedDescription)"
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
        task.cancel()
    }

    private static func normalize(_ value: String) -> String {
        QueryInputPolicy.bounded(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
