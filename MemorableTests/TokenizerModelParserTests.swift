import XCTest
@testable import Memorable

final class TokenizerModelParserTests: XCTestCase {
    func testTokenizationMatchesBundledSentencePieceForUnicodeScalars() throws {
        let tokenizer = try CLIPTokenizer()
        // Golden IDs from SentencePiece 0.2.1 with the bundled tokenizer.model.
        // Its identity normalizer preserves composed/decomposed distinctions.
        let cases: [(String, [Int32])] = [
            ("", []),
            ("dog", [12240]),
            ("DOG\t  on\n a beach!", [12240, 611, 476, 8318, 235341]),
            ("a\u{0000}b", [235250, 217, 235268]),
            ("<bos>hello<eos>", [235322, 14084, 235313, 17534, 235322, 96396, 235313]),
            ("<pad>", [235322, 8939, 235313]),
            ("foo▁bar", [14214, 2333]),
            ("北京的照片", [35354, 153681]),
            ("İSTANBUL", [235252, 241780, 38980]),
            ("Straße", [30539]),
            ("a\u{00A0}b\u{2028}c", [235250, 518, 498]),
            ("a\u{001C}b\u{001F}c", [235250, 518, 498]),
            ("red-haired dog, blue ball.", [854, 235290, 82220, 5929, 235269, 3868, 5744, 235265]),
            ("👩🏽‍🚀 🚀", [241355, 239518, 235879, 239304, 167340]),
            ("x\u{200B}y", [235297, 235421, 235267]),
            ("line\r\nnext", [703, 2351]),
            ("café", [81453]),
            ("cafe\u{0301}", [51344, 236703]),
            ("फ़ोटो", [135447, 217708]),
            ("हिन्दी", [89753, 52234, 235557]),
            ("hello 👨‍👩‍👧‍👦", [17534, 235248, 241568, 235879, 241355, 235879, 244355, 235879, 244670]),
            ("한글", [236511, 239334]),
            ("\u{1FAE9}", [457, 376, 388, 386]),
        ]
        for (text, expected) in cases + cases.reversed() {
            let tokens = try tokenizer.tokenize(text: text)
            XCTAssertEqual(Array(tokens.prefix(expected.count + 1)), expected + [1], text)
            XCTAssertTrue(tokens.dropFirst(expected.count + 1).allSatisfy { $0 == 0 })
        }
    }

    func testEmptyInputAndContextBoundariesKeepEOSAndPadding() throws {
        let tokenizer = try CLIPTokenizer()
        XCTAssertEqual(try tokenizer.tokenize(text: " \t\n"), [1] + Array(repeating: 0, count: 63))
        XCTAssertEqual(try tokenizer.tokenize(text: "dog", maxLength: 1), [1])
        XCTAssertEqual(try tokenizer.tokenize(text: "dog", maxLength: 2), [12240, 1])
        XCTAssertEqual(try tokenizer.tokenize(text: "dog", maxLength: 4), [12240, 1, 0, 0])
        let longQuery = Array(repeating: "dog", count: 100).joined(separator: " ")
        // Upstream reference: first word 12240, subsequent words 5929.
        XCTAssertEqual(
            try tokenizer.tokenize(text: longQuery),
            [12240] + Array(repeating: 5929, count: 62) + [1]
        )
    }

    func testInvalidLengthsThrowInsteadOfTrappingOrAllocatingUnboundedOutput() throws {
        let tokenizer = try CLIPTokenizer(contextLength: 4)
        for length in [-1, 0, 5, Int.max] {
            XCTAssertThrowsError(try tokenizer.tokenize(text: "dog", maxLength: length))
        }
        for length in [-1, 0, 65, Int.max] {
            XCTAssertThrowsError(try CLIPTokenizer(contextLength: length))
        }
    }

    func testNativeProcessorRejectsMalformedModels() throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "tokenizer", withExtension: "model"))
        let data = try Data(contentsOf: modelURL)
        for malformed in [Data(), Data("not a model".utf8), Data(data.dropLast())] {
            XCTAssertThrowsError(try CLIPTokenizer(modelData: malformed))
        }
    }

    func testNativeProcessorRequiresModelEOSAndPadding() throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "tokenizer", withExtension: "model"))
        let original = try Sentencepiece_ModelProto(serializedBytes: Data(contentsOf: modelURL))
        var withoutPadding = original
        // SentencePiece resolves special IDs by piece names at inference time;
        // changing the training-only numeric ID does not remove the token.
        withoutPadding.trainerSpec.padPiece = "<missing_padding>"
        XCTAssertThrowsError(try CLIPTokenizer(modelData: withoutPadding.serializedData()))
        var withoutEOS = original
        withoutEOS.trainerSpec.eosPiece = "<missing_eos>"
        XCTAssertThrowsError(try CLIPTokenizer(modelData: withoutEOS.serializedData()))
    }

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
