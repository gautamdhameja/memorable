import XCTest
@testable import Memorable

final class SearchViewModelTests: XCTestCase {
    private enum ExpectedError: LocalizedError {
        case failure

        var errorDescription: String? { "expected failure" }
    }

    @MainActor
    func testEditingTextDoesNotCancelSubmittedSearch() async throws {
        let searcher = ControlledSearcher()
        let model = makeModel(search: searcher.search)

        model.setQueryText("cats")
        model.submitSearch()
        await searcher.waitUntilCalled(with: "cats")

        model.setQueryText("dogs")
        await searcher.complete(query: "cats", with: response(id: "cat-result"))
        await model.waitForCurrentSearch()

        XCTAssertEqual(model.queryText, "dogs")
        XCTAssertEqual(model.results.map(\.id), ["cat-result"])
        XCTAssertEqual(model.lastSearchedQuery, "cats")
        XCTAssertFalse(model.isSearching)
    }

    @MainActor
    func testPastedQueryIsBoundedBeforeItCanBeStoredOrSearched() {
        let model = makeModel(search: { _ in Self.response(ids: []) })
        let oversized = String(repeating: "x", count: QueryInputPolicy.maximumCharacterCount + 1_000)

        model.setQueryText(oversized)

        XCTAssertEqual(model.queryText.count, QueryInputPolicy.maximumCharacterCount)
        XCTAssertEqual(model.normalizedQuery.count, QueryInputPolicy.maximumCharacterCount)
    }

    @MainActor
    func testOnlyNewerSubmittedSearchSupersedesOlderSearch() async throws {
        let searcher = ControlledSearcher()
        let model = makeModel(search: searcher.search)

        model.setQueryText("first")
        model.submitSearch()
        await searcher.waitUntilCalled(with: "first")

        model.setQueryText("second")
        model.submitSearch()
        await searcher.waitUntilCalled(with: "second")

        await searcher.complete(query: "second", with: response(id: "second-result"))
        await model.waitForCurrentSearch()
        XCTAssertEqual(model.results.map(\.id), ["second-result"])

        // The controlled search intentionally ignores task cancellation. Identity
        // checks must still prevent the older result from replacing the newer one.
        await searcher.complete(query: "first", with: response(id: "first-result"))
        await Task.yield()

        XCTAssertEqual(model.results.map(\.id), ["second-result"])
        XCTAssertEqual(model.lastSearchedQuery, "second")
    }

    @MainActor
    func testMemoryPressureCancelsSearchAndRejectsLateResults() async throws {
        let searcher = ControlledSearcher()
        let model = makeModel(search: searcher.search)
        model.setQueryText("large search")
        model.submitSearch()
        await searcher.waitUntilCalled(with: "large search")

        model.handleMemoryPressure()
        await searcher.complete(query: "large search", with: response(id: "late-result"))
        await Task.yield()

        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.activeSearchID)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.lastResults.isEmpty)
    }

    @MainActor
    func testIndexVersionChangeKeepsResultsVisibleUntilValidationCompletes() async throws {
        let validator = ControlledValidator()
        let model = makeModel(
            search: { _ in Self.response(ids: ["kept", "removed"]) },
            validate: validator.validate
        )
        model.setQueryText("mountains")
        model.submitSearch()
        await model.waitForCurrentSearch()

        model.validateVisibleResults(reason: "indexVersion changed")
        await validator.waitUntilCalled()

        XCTAssertEqual(model.results.map(\.id), ["kept", "removed"])

        await validator.complete(validIDs: ["kept"])
        await model.waitForVisibleResultValidation()

        XCTAssertEqual(model.results.map(\.id), ["kept"])
    }

    @MainActor
    func testStaleIndexValidationCannotOverwriteNewerSearchResults() async throws {
        let validator = ControlledValidator()
        let model = makeModel(
            search: { query in Self.response(ids: ["\(query)-result"]) },
            validate: validator.validate
        )

        model.setQueryText("first")
        model.submitSearch()
        await model.waitForCurrentSearch()
        model.validateVisibleResults(reason: "indexVersion changed")
        await validator.waitUntilCalled()

        model.setQueryText("second")
        model.submitSearch()
        await model.waitForCurrentSearch()

        await validator.complete(validIDs: ["first-result"])
        await model.waitForVisibleResultValidation()

        XCTAssertEqual(model.results.map(\.id), ["second-result"])
    }

    @MainActor
    func testFilteringSortingAndProgressiveRevealAreModelState() async throws {
        let recent = Date(timeIntervalSince1970: 2)
        let older = Date(timeIntervalSince1970: 1)
        let model = makeModel(search: { _ in
            SearchResponse(
                results: [
                    Self.result(id: "older", date: older),
                    Self.result(id: "video", date: recent, isVideo: true),
                    Self.result(id: "screenshot", date: recent),
                ],
                fallbackResults: [],
                filtersApplied: nil
            )
        }, detectScreenshots: { _ in ["screenshot"] })

        model.setQueryText("trip")
        model.submitSearch()
        await model.waitForCurrentSearch()
        await model.waitForScreenshotDetection()

        model.selectSortMode(.recent)
        model.setMediaFilter(.photos)

        let filtered = model.filteredResults(model.results)
        XCTAssertEqual(filtered.map(\.id), ["older"])
        XCTAssertEqual(Array(filtered.prefix(model.visibleCount)).map(\.id), ["older"])
    }

    @MainActor
    func testSortModeStorageKeyRemainsStable() {
        XCTAssertEqual(SearchViewModel.sortModeStorageKey, "searchSortMode")
    }

    @MainActor
    func testSubmittedSearchPrioritizesUserWorkBeforeSearching() async {
        var events: [String] = []
        let model = makeModel(
            prioritizeUserSearch: { events.append("prioritize") },
            search: { _ in
                events.append("search")
                return Self.response(ids: [])
            }
        )

        model.setQueryText("cats")
        model.submitSearch()
        await model.waitForCurrentSearch()

        XCTAssertEqual(events, ["prioritize", "search"])
    }

    func testForegroundValidationPartitionsPhotoKitAndFolderResults() {
        let candidates = [
            Self.result(id: "photo-valid"),
            Self.result(id: "photo-missing"),
            Self.folderResult(id: "folder-valid", sourceId: "folder-a"),
            Self.folderResult(id: "folder-missing", sourceId: "folder-b"),
        ]
        var checkedFolderIDs: [String] = []

        let validIDs = SearchResultForegroundValidator.validResultIDs(
            candidates: candidates,
            validPhotoKitIdentifiers: ["photo-valid"],
            isFolderResultAccessible: { result in
                checkedFolderIDs.append(result.id)
                return result.id == "folder-valid"
            }
        )

        XCTAssertEqual(validIDs, ["photo-valid", "folder-valid"])
        XCTAssertEqual(checkedFolderIDs, ["folder-valid", "folder-missing"])
    }

    @MainActor
    func testPreparationFailureResetsSearchLifecycle() async {
        let model = SearchViewModel(dependencies: .init(
            prioritizeUserSearch: {},
            isSemanticSearchReady: { false },
            isIndexReady: { false },
            isIndexLoaded: { false },
            prepareForSearch: { throw ExpectedError.failure },
            search: { _ in XCTFail("Search should not run"); return Self.response(ids: []) },
            detectScreenshotIDs: { _ in [] },
            validResultIDs: { _ in [] },
            addHistory: { _ in },
            loadHistory: { [] },
            clearHistory: {},
            removeHistory: { _ in },
            now: { 1 }
        ))

        model.setQueryText("cats")
        model.submitSearch()
        await model.waitForCurrentSearch()

        XCTAssertEqual(model.searchError, "Search failed: expected failure")
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.activeSearchID)
        XCTAssertTrue(model.results.isEmpty)
    }

    @MainActor
    func testUnavailableIndexResetsSearchLifecycle() async {
        let model = SearchViewModel(dependencies: .init(
            prioritizeUserSearch: {},
            isSemanticSearchReady: { false },
            isIndexReady: { false },
            isIndexLoaded: { false },
            prepareForSearch: {},
            search: { _ in XCTFail("Search should not run"); return Self.response(ids: []) },
            detectScreenshotIDs: { _ in [] },
            validResultIDs: { _ in [] },
            addHistory: { _ in },
            loadHistory: { [] },
            clearHistory: {},
            removeHistory: { _ in },
            now: { 1 }
        ))

        model.setQueryText("cats")
        model.submitSearch()
        await model.waitForCurrentSearch()

        XCTAssertEqual(model.searchError, "Index your photos before searching.")
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.activeSearchID)
        XCTAssertTrue(model.results.isEmpty)
    }

    @MainActor
    private func makeModel(
        prioritizeUserSearch: @escaping () -> Void = {},
        search: @escaping (String) async throws -> SearchResponse,
        validate: @escaping ([SearchResult]) async -> Set<String> = { results in Set(results.map(\.id)) },
        detectScreenshots: @escaping ([SearchResult]) async -> Set<String> = { _ in [] }
    ) -> SearchViewModel {
        SearchViewModel(dependencies: .init(
            prioritizeUserSearch: prioritizeUserSearch,
            isSemanticSearchReady: { true },
            isIndexReady: { true },
            isIndexLoaded: { true },
            prepareForSearch: {},
            search: search,
            detectScreenshotIDs: detectScreenshots,
            validResultIDs: validate,
            addHistory: { _ in },
            loadHistory: { [] },
            clearHistory: {},
            removeHistory: { _ in },
            now: { 1 }
        ))
    }

    private static func response(ids: [String]) -> SearchResponse {
        SearchResponse(results: ids.map { result(id: $0) }, fallbackResults: [], filtersApplied: nil)
    }

    private func response(id: String) -> SearchResponse {
        Self.response(ids: [id])
    }

    private static func result(
        id: String,
        date: Date? = nil,
        isVideo: Bool = false
    ) -> SearchResult {
        SearchResult(
            id: id,
            score: 0.9,
            localIdentifier: id,
            creationDate: date,
            isVideo: isVideo,
            bestFramePosition: nil
        )
    }

    private static func folderResult(id: String, sourceId: String) -> SearchResult {
        SearchResult(
            id: id,
            score: 0.9,
            localIdentifier: "folder:\(sourceId):\(id).jpg",
            creationDate: nil,
            isVideo: false,
            bestFramePosition: nil,
            sourceId: sourceId,
            filePath: "/selected/\(id).jpg"
        )
    }
}

private actor ControlledSearcher {
    private var calls: [String] = []
    private var continuations: [String: CheckedContinuation<SearchResponse, Error>] = [:]
    private var callWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func search(query: String) async throws -> SearchResponse {
        calls.append(query)
        callWaiters.removeValue(forKey: query)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[query] = continuation
        }
    }

    func complete(query: String, with response: SearchResponse) {
        continuations.removeValue(forKey: query)?.resume(returning: response)
    }

    func waitUntilCalled(with query: String) async {
        guard !calls.contains(query) else { return }
        await withCheckedContinuation { continuation in
            callWaiters[query, default: []].append(continuation)
        }
    }
}

private actor ControlledValidator {
    private var wasCalled = false
    private var continuation: CheckedContinuation<Set<String>, Never>?
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    func validate(_ results: [SearchResult]) async -> Set<String> {
        wasCalled = true
        callWaiters.forEach { $0.resume() }
        callWaiters = []
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(validIDs: Set<String>) {
        continuation?.resume(returning: validIDs)
        continuation = nil
    }

    func waitUntilCalled() async {
        guard !wasCalled else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }
}
