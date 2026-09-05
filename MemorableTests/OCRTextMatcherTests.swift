import XCTest
@testable import Memorable

final class OCRTextMatcherTests: XCTestCase {
    func testSingleAndTwoWordQueriesRequireCompleteWords() {
        XCTAssertNil(OCRTextMatcher(query: "centre").match(in: "Centr"))
        XCTAssertNil(OCRTextMatcher(query: "heart centre").match(in: "Heart Centr"))
        XCTAssertNotNil(OCRTextMatcher(query: "centre").match(in: "Heart Centre"))
    }

    func testNumbersCannotBeTruncated() {
        XCTAssertNil(OCRTextMatcher(query: "order number 123456").match(in: "Order number 12345"))
    }

    func testExcerptPreservesOriginalTextAndFindsLaterCompleteMatch() throws {
        let match = try XCTUnwrap(OCRTextMatcher(query: "pulse heart centre").match(
            in: "Pulse Heart Centr. Welcome to PULSE\nHEART CENTRE!"
        ))
        XCTAssertEqual(match.kind, .completePhrase)
        XCTAssertEqual(match.phrase, "PULSE\nHEART CENTRE")
        XCTAssertTrue(match.excerpt.hasSuffix("!"))
    }

    func testLongExcerptIsBoundedAndKeepsMatchVisible() throws {
        let text = String(repeating: "前 ", count: 1_000) + "ＰＵＬＳＥ HEART CENTRE" + String(repeating: " 後", count: 1_000)
        let match = try XCTUnwrap(OCRTextMatcher(query: "pulse heart centre").match(in: text))
        XCTAssertEqual(match.kind, .completePhrase)
        XCTAssertEqual(match.phrase, "ＰＵＬＳＥ HEART CENTRE")
        XCTAssertLessThanOrEqual(match.excerpt.count, 202)
        XCTAssertTrue(match.before.hasPrefix("…"))
        XCTAssertTrue(match.after.hasSuffix("…"))
    }
}
