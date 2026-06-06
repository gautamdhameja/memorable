import XCTest
@testable import Memorable

final class SemanticSearchRuntimeTests: XCTestCase {

    @MainActor
    func testPostPaintWarmupCallsLoaderOnceAcrossConcurrentWaiters() async throws {
        let runtime = SemanticSearchRuntime()
        var loadCount = 0
        runtime.setWarmupLoader { _ in
            loadCount += 1
            try await Task.sleep(nanoseconds: 10_000_000)
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        runtime.startPostPaintWarmup()
        let first = Task { @MainActor in try await runtime.prepareForSearch() }
        let second = Task { @MainActor in try await runtime.prepareForSearch() }
        try await first.value
        try await second.value

        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(runtime.readiness.isSemanticSearchReady)
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testPrepareForSearchPromotesWarmup() async throws {
        let runtime = SemanticSearchRuntime()
        var priorities: [SemanticWarmupPriority] = []
        runtime.setWarmupLoader { priority in
            priorities.append(priority)
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        try await runtime.prepareForSearch()

        XCTAssertEqual(priorities, [.userInitiatedSearch])
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testPrepareForSearchPromotesExistingPostPaintWarmup() async throws {
        let runtime = SemanticSearchRuntime()
        var didPromote = false
        runtime.setPromotionHandler {
            didPromote = true
        }
        runtime.setWarmupLoader { _ in
            try await Task.sleep(nanoseconds: 10_000_000)
            runtime.markSemanticModelReady()
            runtime.markIndexReady()
        }

        runtime.startPostPaintWarmup()
        try await runtime.prepareForSearch()

        XCTAssertTrue(didPromote)
        XCTAssertEqual(runtime.phase, .ready)
    }

    @MainActor
    func testModelReadyWithoutIndexWaitsForIndex() async throws {
        let runtime = SemanticSearchRuntime()
        runtime.setWarmupLoader { _ in
            runtime.markSemanticModelReady()
            runtime.markIndexUnavailable()
        }

        runtime.startPostPaintWarmup()
        try await runtime.prepareForSearch()

        XCTAssertTrue(runtime.readiness.isSemanticModelReady)
        XCTAssertFalse(runtime.readiness.isSemanticSearchReady)
        XCTAssertEqual(runtime.phase, .waitingForIndex)
    }
}
