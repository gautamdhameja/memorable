import XCTest
@testable import Memorable

final class TokenizerModelParserTests: XCTestCase {
    func testFocusedParserMatchesSwiftProtobufSourceModel() throws {
        let modelURL = try XCTUnwrap(
            Bundle.main.url(forResource: "tokenizer", withExtension: "model")
        )
        let data = try Data(contentsOf: modelURL)
        let focused = try CLIPTokenizer.parseModel(data)
        let reference = try Sentencepiece_ModelProto(serializedBytes: data)

        XCTAssertEqual(focused.pieces.count, reference.pieces.count)
        XCTAssertEqual(focused.eosID, reference.trainerSpec.eosID)
        XCTAssertEqual(focused.padID, reference.trainerSpec.padID)

        for (focusedPiece, referencePiece) in zip(focused.pieces, reference.pieces) {
            XCTAssertEqual(focusedPiece.text, referencePiece.piece)
            XCTAssertEqual(focusedPiece.score, referencePiece.score)
            XCTAssertEqual(focusedPiece.typeRawValue, referencePiece.type.rawValue)
        }
    }

    func testFocusedParserRejectsTruncatedModel() throws {
        let modelURL = try XCTUnwrap(
            Bundle.main.url(forResource: "tokenizer", withExtension: "model")
        )
        let data = try Data(contentsOf: modelURL)

        XCTAssertThrowsError(try CLIPTokenizer.parseModel(data.dropLast()))
    }

    func testFocusedParserRejectsEmptyInput() {
        XCTAssertThrowsError(try CLIPTokenizer.parseModel(Data()))
    }
}
