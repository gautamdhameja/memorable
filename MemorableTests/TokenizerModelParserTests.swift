import XCTest
@testable import Memorable

final class TokenizerModelParserTests: XCTestCase {
    func testSwiftProtobufRejectsTruncatedModel() throws {
        let modelURL = try XCTUnwrap(
            Bundle.main.url(forResource: "tokenizer", withExtension: "model")
        )
        let data = try Data(contentsOf: modelURL)

        XCTAssertThrowsError(
            try Sentencepiece_ModelProto(serializedBytes: data.dropLast())
        )
    }
}
