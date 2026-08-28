import XCTest
@testable import Memorable

@available(iOS 26.0, *)
final class SmartQueryParserConcurrencyTests: XCTestCase {
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
}
