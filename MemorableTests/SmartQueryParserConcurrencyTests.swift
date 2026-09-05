import XCTest
@testable import Memorable

@available(iOS 26.0, *)
final class SmartQueryParserConcurrencyTests: XCTestCase {
    private actor PromptCapture {
        private(set) var prompt: String?

        func record(_ prompt: String) {
            self.prompt = prompt
        }
    }

    private struct CapturingResponder: SmartQueryResponding {
        let capture: PromptCapture

        func respond(to prompt: String) async throws -> ParsedQuery {
            await capture.record(prompt)
            return ParsedQuery(
                visualDescription: "dog",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: []
            )
        }
    }

    private struct OversizedResponder: SmartQueryResponding {
        func respond(to prompt: String) async throws -> ParsedQuery {
            ParsedQuery(
                visualDescription: String(repeating: "v", count: 5_000),
                startDate: String(repeating: "1", count: 5_000),
                endDate: String(repeating: "2", count: 5_000),
                locationName: String(repeating: "l", count: 5_000),
                negativeTerms: (0..<100).map { _ in String(repeating: "n", count: 1_000) }
            )
        }
    }

    private struct NullSentinelLocationResponder: SmartQueryResponding {
        func respond(to prompt: String) async throws -> ParsedQuery {
            ParsedQuery(
                visualDescription: "bavaria",
                startDate: nil,
                endDate: nil,
                locationName: "null",
                negativeTerms: []
            )
        }
    }

    private struct FixedParsedQueryResponder: SmartQueryResponding {
        let parsedQuery: ParsedQuery

        func respond(to prompt: String) async throws -> ParsedQuery {
            parsedQuery
        }
    }

    func testSuccessfulSmartParsingDoesNotTreatNegativeTimeAsPositiveIntent() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "dog",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: ["night"]
            ))
        }
        let hints = await parser.parse(query: "dog -night")
        XCTAssertNil(hints.timeOfDayHours)
        XCTAssertEqual(hints.negativeTerms, ["night"])
    }

    func testSuccessfulModelParsePreservesDeterministicAdministrativeIntent() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "CA",
                startDate: nil,
                endDate: nil,
                locationName: "CA",
                negativeTerms: []
            ))
        }

        let hints = await parser.parse(query: "CA")

        XCTAssertEqual(hints.locationHint, "CA")
        XCTAssertEqual(hints.locationAdminArea, "CA")
        XCTAssertEqual(hints.locationCountryName, "united states")
    }

    func testModelCannotInventExclusionsForPositiveQuery() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "mountains and rivers",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: ["mountains", "rivers"]
            ))
        }

        let hints = await parser.parse(query: "mountains and rivers")

        XCTAssertTrue(hints.negativeTerms.isEmpty)
    }

    func testTextMatchingPreservesLiteralWordsWhenModelRewritesVisualQuery() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "hospital sign",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: []
            ))
        }

        let hints = await parser.parse(query: "pulse heart centre -night")

        XCTAssertEqual(hints.textQuery, "hospital sign")
        XCTAssertEqual(hints.textMatchQuery, "pulse heart centre")
        XCTAssertEqual(hints.negativeTerms, ["night"])
    }

    func testExplicitExclusionsSurviveModelOmissionOrReplacement() async {
        for modelTerms in [[], ["dog"]] {
            let parser = SmartQueryParser(isAvailable: true) {
                FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                    visualDescription: "dog",
                    startDate: nil,
                    endDate: nil,
                    locationName: nil,
                    negativeTerms: modelTerms
                ))
            }

            let hints = await parser.parse(query: "dog -night")

            XCTAssertEqual(hints.negativeTerms, ["night"])
        }
    }

    private actor ConcurrencyProbe {
        private var activeByResponder: [UUID: Int] = [:]
        private var responderIDs: Set<UUID> = []
        private(set) var maximumConcurrentCallsOnOneResponder = 0

        func respond(responderID: UUID) async -> ParsedQuery {
            responderIDs.insert(responderID)
            activeByResponder[responderID, default: 0] += 1
            maximumConcurrentCallsOnOneResponder = max(
                maximumConcurrentCallsOnOneResponder,
                activeByResponder[responderID, default: 0]
            )

            try? await Task.sleep(nanoseconds: 5_000_000)
            activeByResponder[responderID, default: 0] -= 1

            return ParsedQuery(
                visualDescription: "dog",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: []
            )
        }

        var uniqueResponderCount: Int { responderIDs.count }
    }

    private struct ProbeResponder: SmartQueryResponding {
        let id: UUID
        let probe: ConcurrencyProbe

        func respond(to prompt: String) async throws -> ParsedQuery {
            await probe.respond(responderID: id)
        }
    }

    private actor TimeoutProbe {
        private(set) var callCount = 0

        func respond() async throws -> ParsedQuery {
            callCount += 1
            try await Task.sleep(for: .seconds(5))
            return ParsedQuery(
                visualDescription: "model result",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: []
            )
        }
    }

    private struct TimeoutResponder: SmartQueryResponding {
        let probe: TimeoutProbe

        func respond(to prompt: String) async throws -> ParsedQuery {
            try await probe.respond()
        }
    }

    private actor CancellationIgnoringProbe {
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var blockedContinuation: CheckedContinuation<Void, Never>?
        private(set) var callCount = 0

        func respond() async -> ParsedQuery {
            callCount += 1
            let callNumber = callCount
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume() }

            if callNumber == 1 {
                await withCheckedContinuation { continuation in
                    blockedContinuation = continuation
                }
            }

            return ParsedQuery(
                visualDescription: "model result",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: []
            )
        }

        func waitUntilStarted() async {
            guard callCount == 0 else { return }
            await withCheckedContinuation { continuation in
                startedWaiters.append(continuation)
            }
        }

        func releaseBlockedResponse() {
            blockedContinuation?.resume()
            blockedContinuation = nil
        }
    }

    private struct CancellationIgnoringResponder: SmartQueryResponding {
        let probe: CancellationIgnoringProbe

        func respond(to prompt: String) async throws -> ParsedQuery {
            await probe.respond()
        }
    }

    private actor ImmediateResponseProbe {
        private(set) var callCount = 0

        func respond() -> ParsedQuery {
            callCount += 1
            return ParsedQuery(
                visualDescription: "model result",
                startDate: nil,
                endDate: nil,
                locationName: nil,
                negativeTerms: []
            )
        }
    }

    private struct ImmediateResponder: SmartQueryResponding {
        let probe: ImmediateResponseProbe

        func respond(to prompt: String) async throws -> ParsedQuery {
            await probe.respond()
        }
    }

    func testConcurrentParsesUseIndependentResponders() async {
        let probe = ConcurrencyProbe()
        let parser = SmartQueryParser(isAvailable: true) {
            ProbeResponder(id: UUID(), probe: probe)
        }
        let requestCount = 20
        var results: [String] = []

        await withTaskGroup(of: String.self) { group in
            for index in 0..<requestCount {
                group.addTask {
                    await parser.parse(query: "dog \(index)").textQuery
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        XCTAssertEqual(results, Array(repeating: "dog", count: requestCount))
        let uniqueResponderCount = await probe.uniqueResponderCount
        let maximumConcurrentCallsOnOneResponder = await probe.maximumConcurrentCallsOnOneResponder
        XCTAssertEqual(uniqueResponderCount, requestCount)
        XCTAssertEqual(maximumConcurrentCallsOnOneResponder, 1)
    }

    func testTimedOutResponderFallsBackAndOpensCircuit() async {
        let probe = TimeoutProbe()
        let parser = SmartQueryParser(
            isAvailable: true,
            responseTimeoutSeconds: 0.02
        ) {
            TimeoutResponder(probe: probe)
        }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let firstHints = await parser.parse(query: "dog")
        let firstDuration = startedAt.duration(to: clock.now)
        let secondHints = await parser.parse(query: "sunset")

        XCTAssertEqual(firstHints.textQuery, "dog")
        XCTAssertEqual(secondHints.textQuery, "sunset")
        XCTAssertLessThan(firstDuration, .milliseconds(500))
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testParentCancellationReturnsPromptlyWithoutOpeningCircuit() async {
        let probe = CancellationIgnoringProbe()
        let parser = SmartQueryParser(
            isAvailable: true,
            responseTimeoutSeconds: 5
        ) {
            CancellationIgnoringResponder(probe: probe)
        }

        let parseTask = Task {
            await parser.parse(query: "dog")
        }
        await probe.waitUntilStarted()

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        parseTask.cancel()
        let cancelledHints = await parseTask.value
        let cancellationDuration = cancelledAt.duration(to: clock.now)

        let nextHints = await parser.parse(query: "sunset")
        let callCountWhileCancelledResponseWasActive = await probe.callCount
        await probe.releaseBlockedResponse()

        let recoveryDeadline = clock.now.advanced(by: .milliseconds(500))
        var didRecoverSmartParsing = false
        while clock.now < recoveryDeadline {
            let recoveryHints = await parser.parse(query: "beach")
            if recoveryHints.textQuery == "model result" {
                didRecoverSmartParsing = true
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(cancelledHints.textQuery, "dog")
        XCTAssertLessThan(cancellationDuration, .milliseconds(500))
        XCTAssertEqual(nextHints.textQuery, "sunset")
        XCTAssertEqual(callCountWhileCancelledResponseWasActive, 1)
        XCTAssertTrue(didRecoverSmartParsing)
        let finalCallCount = await probe.callCount
        XCTAssertEqual(finalCallCount, 2)
    }

    func testCancelledResponderThatOutlivesDeadlineOpensCircuit() async throws {
        let probe = CancellationIgnoringProbe()
        let parser = SmartQueryParser(
            isAvailable: true,
            responseTimeoutSeconds: 0.02
        ) {
            CancellationIgnoringResponder(probe: probe)
        }

        let parseTask = Task {
            await parser.parse(query: "dog")
        }
        await probe.waitUntilStarted()
        parseTask.cancel()
        _ = await parseTask.value

        try await Task.sleep(for: .milliseconds(50))
        await probe.releaseBlockedResponse()
        let nextHints = await parser.parse(query: "sunset")

        XCTAssertEqual(nextHints.textQuery, "sunset")
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testSuccessfulResponseCancelsTimeoutWithoutOpeningCircuit() async throws {
        let probe = ImmediateResponseProbe()
        let parser = SmartQueryParser(
            isAvailable: true,
            responseTimeoutSeconds: 0.02
        ) {
            ImmediateResponder(probe: probe)
        }

        let firstHints = await parser.parse(query: "dog")
        try await Task.sleep(for: .milliseconds(50))
        let secondHints = await parser.parse(query: "sunset")

        XCTAssertEqual(firstHints.textQuery, "model result")
        XCTAssertEqual(secondHints.textQuery, "model result")
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testSmartParserBoundsQueryBeforeBuildingPrompt() async {
        let capture = PromptCapture()
        let parser = SmartQueryParser(isAvailable: true) {
            CapturingResponder(capture: capture)
        }
        let oversizedQuery = String(repeating: "x", count: QueryInputPolicy.maximumCharacterCount + 50)

        _ = await parser.parse(query: oversizedQuery)

        let prompt = await capture.prompt
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains(String(repeating: "x", count: QueryInputPolicy.maximumCharacterCount)) == true)
        XCTAssertFalse(prompt?.contains(oversizedQuery) == true)
    }

    func testSmartParserBoundsGeneratedFields() async {
        let parser = SmartQueryParser(isAvailable: true) { OversizedResponder() }

        let hints = await parser.parse(query: "x")

        XCTAssertLessThanOrEqual(hints.textQuery.count, SmartQueryOutputPolicy.maximumVisualCharacters)
        XCTAssertLessThanOrEqual(hints.locationHint?.count ?? 0, SmartQueryOutputPolicy.maximumLocationCharacters)
        XCTAssertTrue(hints.negativeTerms.isEmpty)
    }

    func testLiteralNullLocationFallsBackToLocalLocationParsing() async {
        let parser = SmartQueryParser(isAvailable: true) {
            NullSentinelLocationResponder()
        }

        let hints = await parser.parse(query: "Bavaria")

        XCTAssertEqual(hints.locationHint?.lowercased(), "bavaria")
        XCTAssertNotEqual(hints.locationHint?.lowercased(), "null")
    }

    func testModelCannotAddDateFilterWhenQueryHasNoTemporalIntent() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "new york",
                startDate: "2026-09-02T00:00:00Z",
                endDate: "2026-09-02T23:59:59Z",
                locationName: "New York",
                negativeTerms: []
            ))
        }

        let hints = await parser.parse(query: "New York")

        XCTAssertNil(hints.dateRange)
    }

    func testModelCannotInventHardLocationForVisualOrPersonQuery() async {
        let partyParser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "party",
                startDate: nil,
                endDate: nil,
                locationName: "party",
                negativeTerms: []
            ))
        }
        let personParser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "Paris Hilton",
                startDate: nil,
                endDate: nil,
                locationName: "Paris Hilton",
                negativeTerms: []
            ))
        }

        let party = await partyParser.parse(query: "party")
        let person = await personParser.parse(query: "Paris Hilton")

        XCTAssertNil(party.locationHint)
        XCTAssertEqual(party.textQuery, "party")
        XCTAssertNil(person.locationHint)
        XCTAssertEqual(person.textQuery, "paris hilton")
    }

    func testDeterministicYearRangeOverridesModelSingleDayGuess() async throws {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "",
                startDate: "2022-09-02T00:00:00Z",
                endDate: "2022-09-02T23:59:59Z",
                locationName: "California",
                negativeTerms: []
            ))
        }

        let hints = await parser.parse(query: "California 2022")
        let range = try XCTUnwrap(hints.dateRange)
        let calendar = Calendar.current

        XCTAssertEqual(calendar.component(.year, from: range.start), 2022)
        XCTAssertEqual(calendar.component(.month, from: range.start), 1)
        XCTAssertEqual(calendar.component(.day, from: range.start), 1)
        XCTAssertEqual(calendar.component(.year, from: range.end), 2023)
        XCTAssertEqual(calendar.component(.month, from: range.end), 1)
        XCTAssertEqual(calendar.component(.day, from: range.end), 1)
        XCTAssertTrue(range.endIsExclusive)
    }

    func testGenericPhotosDoNotBecomeSmartVisualContent() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "photos",
                startDate: "2022-01-01T00:00:00Z",
                endDate: "2022-12-31T23:59:59Z",
                locationName: "Berlin",
                negativeTerms: []
            ))
        }

        let hints = await parser.parse(query: "photos from Berlin in 2022")

        XCTAssertEqual(hints.textQuery, "berlin")
        XCTAssertEqual(hints.locationHint?.lowercased(), "berlin")
    }

    func testDeterministicFiltersRemoveModelRetainedFilterTokensFromVisualQuery() async {
        let parser = SmartQueryParser(isAvailable: true) {
            FixedParsedQueryResponder(parsedQuery: ParsedQuery(
                visualDescription: "ca 2022",
                startDate: "2022-01-01T00:00:00Z",
                endDate: "2022-12-31T23:59:59Z",
                locationName: "CA",
                negativeTerms: []
            ))
        }

        let hints = await parser.parse(query: "CA 2022")

        XCTAssertEqual(hints.textQuery, "ca")
        XCTAssertEqual(hints.locationHint, "CA")
        XCTAssertNotNil(hints.dateRange)
    }

    func testQueryInputPolicyBoundsCombiningMarkPayloadByScalarsAndBytes() {
        let payload = "a" + String(repeating: "\u{0301}", count: 100_000)

        let bounded = QueryInputPolicy.bounded(payload)

        XCTAssertLessThanOrEqual(
            bounded.unicodeScalars.count,
            QueryInputPolicy.maximumCharacterCount
        )
        XCTAssertLessThanOrEqual(
            bounded.utf8.count,
            QueryInputPolicy.maximumUTF8ByteCount
        )
        XCTAssertEqual(bounded.unicodeScalars.first?.value, 0x61)
    }
}
