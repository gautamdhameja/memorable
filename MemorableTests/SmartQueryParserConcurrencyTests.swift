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
        XCTAssertEqual(hints.negativeTerms.count, SmartQueryOutputPolicy.maximumNegativeTerms)
        XCTAssertTrue(hints.negativeTerms.allSatisfy {
            $0.count <= SmartQueryOutputPolicy.maximumNegativeTermCharacters
        })
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
