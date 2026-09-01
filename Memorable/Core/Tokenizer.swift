import Foundation
import os

/// SentencePiece BPE tokenizer for SigLIP2 (Gemma tokenizer).
/// Loads a standard SentencePiece .model protobuf and performs BPE tokenization
/// with byte fallback for unknown characters.
final class CLIPTokenizer: Sendable {
    struct ParsedPiece: Equatable, Sendable {
        let text: String
        let score: Float
        let typeRawValue: Int
    }

    struct ParsedModel: Equatable, Sendable {
        let pieces: [ParsedPiece]
        let eosID: Int32
        let padID: Int32
    }

    private struct Piece: Sendable {
        let id: Int
        let score: Float
    }

    private struct ProtobufReader {
        let bytes: [UInt8]
        private(set) var offset: Int
        let endOffset: Int

        init(data: Data) throws {
            guard data.count <= CLIPTokenizer.maximumModelBytes else {
                throw TokenizerError.invalidModel
            }
            let bytes = [UInt8](data)
            self.init(bytes: bytes, range: bytes.startIndex..<bytes.endIndex)
        }

        init(bytes: [UInt8], range: Range<Int>) {
            self.bytes = bytes
            self.offset = range.lowerBound
            self.endOffset = range.upperBound
        }

        var isAtEnd: Bool { offset == endOffset }

        mutating func readKey() throws -> (fieldNumber: Int, wireType: Int) {
            let key = try readVarint()
            let fieldNumber = Int(key >> 3)
            guard fieldNumber > 0 else { throw TokenizerError.invalidModel }
            return (fieldNumber, Int(key & 0x7))
        }

        mutating func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < endOffset else { throw TokenizerError.invalidModel }
                let byte = bytes[offset]
                offset += 1
                if shift == 63, byte > 1 { throw TokenizerError.invalidModel }
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte & 0x80 == 0 { return value }
            }
            throw TokenizerError.invalidModel
        }

        mutating func readFixed32() throws -> UInt32 {
            guard endOffset - offset >= 4 else { throw TokenizerError.invalidModel }
            let value = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return value
        }

        mutating func readLengthDelimitedRange() throws -> Range<Int> {
            let rawLength = try readVarint()
            guard rawLength <= UInt64(Int.max) else { throw TokenizerError.invalidModel }
            let length = Int(rawLength)
            guard length >= 0, length <= endOffset - offset else {
                throw TokenizerError.invalidModel
            }
            let range = offset..<(offset + length)
            offset += length
            return range
        }

        mutating func skip(wireType: Int) throws {
            switch wireType {
            case 0:
                _ = try readVarint()
            case 1:
                guard endOffset - offset >= 8 else { throw TokenizerError.invalidModel }
                offset += 8
            case 2:
                _ = try readLengthDelimitedRange()
            case 5:
                _ = try readFixed32()
            default:
                throw TokenizerError.invalidModel
            }
        }
    }

    private let contextLength: Int
    private let pieces: [String: Piece]
    private let byteFallbackTokens: [UInt8: Int]
    private let eosId: Int32
    private let padId: Int32
    private let cache = OSAllocatedUnfairLock(initialState: [String: [Int]]())
    private let maxCacheSize = 1000
    private static let maximumModelBytes = 16 * 1_024 * 1_024
    private static let maximumPieceCount = 300_000
    private static let maximumPieceUTF8Bytes = 4_096

    enum TokenizerError: Error {
        case filesNotFound
        case invalidModel
    }

    init(contextLength: Int = 64) throws {
        self.contextLength = contextLength

        guard let modelURL = Bundle.main.url(forResource: "tokenizer", withExtension: "model") else {
            throw TokenizerError.filesNotFound
        }
        #if DEBUG || STARTUP_METRICS
        let fileReadStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let data = try Data(contentsOf: modelURL)
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerFileRead,
            durationSeconds: CFAbsoluteTimeGetCurrent() - fileReadStartedAt
        )
        let protoDecodeStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let model = try Self.parseModel(data)
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerProtoDecode,
            durationSeconds: CFAbsoluteTimeGetCurrent() - protoDecodeStartedAt
        )
        #endif

        self.eosId = model.eosID
        // SentencePiece proto defaults pad_id to -1; SigLIP2/Gemma uses 0 (<pad>)
        self.padId = model.padID >= 0 ? model.padID : 0

        var pieces: [String: Piece] = [:]
        pieces.reserveCapacity(model.pieces.count)
        var byteTokens: [UInt8: Int] = [:]
        byteTokens.reserveCapacity(256)
        #if DEBUG || STARTUP_METRICS
        let tableBuildStartedAt = CFAbsoluteTimeGetCurrent()
        #endif

        for (i, piece) in model.pieces.enumerated() {
            pieces[piece.text] = Piece(id: i, score: piece.score)
            if piece.typeRawValue == 6 {
                // Byte fallback tokens are formatted as <0xNN>
                if let byteVal = Self.parseByteToken(piece.text) {
                    byteTokens[byteVal] = i
                }
            }
        }

        self.pieces = pieces
        self.byteFallbackTokens = byteTokens
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerTableBuild,
            durationSeconds: CFAbsoluteTimeGetCurrent() - tableBuildStartedAt
        )
        #endif
    }

    static func parseModel(_ data: Data) throws -> ParsedModel {
        var reader = try ProtobufReader(data: data)
        var pieces: [ParsedPiece] = []
        pieces.reserveCapacity(256_000)
        var eosID: Int32 = 2
        var padID: Int32 = -1

        while !reader.isAtEnd {
            let key = try reader.readKey()
            switch (key.fieldNumber, key.wireType) {
            case (1, 2):
                guard pieces.count < maximumPieceCount else {
                    throw TokenizerError.invalidModel
                }
                let range = try reader.readLengthDelimitedRange()
                pieces.append(try parsePiece(bytes: reader.bytes, range: range))
            case (2, 2):
                let range = try reader.readLengthDelimitedRange()
                let ids = try parseTrainerSpec(bytes: reader.bytes, range: range)
                eosID = ids.eosID
                padID = ids.padID
            default:
                try reader.skip(wireType: key.wireType)
            }
        }

        guard !pieces.isEmpty else { throw TokenizerError.invalidModel }
        return ParsedModel(pieces: pieces, eosID: eosID, padID: padID)
    }

    private static func parsePiece(
        bytes: [UInt8],
        range: Range<Int>
    ) throws -> ParsedPiece {
        var reader = ProtobufReader(bytes: bytes, range: range)
        var text = ""
        var score: Float = 0
        var typeRawValue = 1

        while !reader.isAtEnd {
            let key = try reader.readKey()
            switch (key.fieldNumber, key.wireType) {
            case (1, 2):
                let textRange = try reader.readLengthDelimitedRange()
                guard textRange.count <= maximumPieceUTF8Bytes else {
                    throw TokenizerError.invalidModel
                }
                let sourceBytes = reader.bytes[textRange]
                let decoded = String(decoding: sourceBytes, as: UTF8.self)
                guard decoded.utf8.elementsEqual(sourceBytes) else {
                    throw TokenizerError.invalidModel
                }
                text = decoded
            case (2, 5):
                score = Float(bitPattern: try reader.readFixed32())
            case (3, 0):
                let rawType = try reader.readVarint()
                guard rawType <= UInt64(Int.max) else {
                    throw TokenizerError.invalidModel
                }
                typeRawValue = Int(rawType)
            default:
                try reader.skip(wireType: key.wireType)
            }
        }
        return ParsedPiece(text: text, score: score, typeRawValue: typeRawValue)
    }

    private static func parseTrainerSpec(
        bytes: [UInt8],
        range: Range<Int>
    ) throws -> (eosID: Int32, padID: Int32) {
        var reader = ProtobufReader(bytes: bytes, range: range)
        var eosID: Int32 = 2
        var padID: Int32 = -1
        while !reader.isAtEnd {
            let key = try reader.readKey()
            switch (key.fieldNumber, key.wireType) {
            case (42, 0):
                eosID = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            case (43, 0):
                padID = Int32(bitPattern: UInt32(truncatingIfNeeded: try reader.readVarint()))
            default:
                try reader.skip(wireType: key.wireType)
            }
        }
        return (eosID, padID)
    }

    func tokenize(text: String, maxLength: Int? = nil) -> [Int32] {
        let len = maxLength ?? contextLength
        let cleaned = preprocess(text)

        var tokens: [Int32] = []
        let words = splitIntoWords(cleaned)
        for word in words {
            let ids = encode(word)
            tokens.append(contentsOf: ids.map { Int32($0) })
        }
        tokens.append(eosId)

        if tokens.count > len {
            tokens = Array(tokens.prefix(len - 1)) + [eosId]
        }
        while tokens.count < len {
            tokens.append(padId)
        }

        return tokens
    }

    // MARK: - Text Preprocessing (SigLIP2 pipeline)

    /// SigLIP2 preprocessing: lowercase and collapse whitespace.
    /// Punctuation is preserved -- the tokenizer encodes it as separate tokens,
    /// matching the model's training data.
    private func preprocess(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Word Splitting

    /// SentencePiece treats whitespace as part of the token by replacing spaces
    /// with U+2581. With add_dummy_prefix=false (SigLIP2/Gemma), the first word
    /// does NOT get the prefix. Only subsequent words get it.
    private func splitIntoWords(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let separator = "\u{2581}"
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        return parts.enumerated().map { (i, word) in
            i == 0 ? String(word) : separator + String(word)
        }
    }

    // MARK: - BPE Encoding

    private func encode(_ word: String) -> [Int] {
        let cached = cache.withLock { $0[word] }
        if let cached { return cached }

        // Start with individual characters (or byte fallback for unknowns)
        var symbols = initialTokens(for: word)
        if symbols.count <= 1 {
            let ids = symbols.map { tokenId(for: $0) }
            store(ids, for: word)
            return ids
        }

        // Iteratively merge the highest-scoring adjacent pair
        while symbols.count > 1 {
            var bestIdx = -1
            var bestScore: Float = -.infinity
            var bestMerged = ""

            for i in 0..<(symbols.count - 1) {
                let merged = symbols[i] + symbols[i + 1]
                if let score = pieces[merged]?.score, score > bestScore {
                    bestScore = score
                    bestIdx = i
                    bestMerged = merged
                }
            }

            guard bestIdx >= 0, pieces[bestMerged] != nil else { break }

            var newSymbols: [String] = []
            var i = 0
            while i < symbols.count {
                if i == bestIdx {
                    newSymbols.append(bestMerged)
                    i += 2
                } else {
                    newSymbols.append(symbols[i])
                    i += 1
                }
            }
            symbols = newSymbols
        }

        let ids = symbols.map { tokenId(for: $0) }
        store(ids, for: word)
        return ids
    }

    private func store(_ ids: [Int], for word: String) {
        cache.withLock { cache in
            if cache.count > maxCacheSize { cache.removeAll() }
            cache[word] = ids
        }
    }

    /// Break a word into its initial character tokens. For characters that exist
    /// in the vocab as single-char pieces, use them directly. Otherwise, fall back
    /// to UTF-8 byte tokens.
    private func initialTokens(for word: String) -> [String] {
        var tokens: [String] = []
        for char in word {
            let s = String(char)
            if pieces[s] != nil {
                tokens.append(s)
            } else {
                // Byte fallback: encode the character as UTF-8 bytes
                for byte in s.utf8 {
                    tokens.append(Self.byteTokenString(byte))
                }
            }
        }
        return tokens
    }

    private func tokenId(for piece: String) -> Int {
        if let id = pieces[piece]?.id { return id }
        // If a single byte token, use byte fallback
        if let byteVal = Self.parseByteToken(piece), let id = byteFallbackTokens[byteVal] {
            return id
        }
        // Unknown token (should not happen with byte fallback)
        return pieces["<unk>"]?.id ?? 3
    }

    // MARK: - Byte Token Helpers

    private static func byteTokenString(_ byte: UInt8) -> String {
        String(format: "<0x%02X>", byte)
    }

    private static func parseByteToken(_ token: String) -> UInt8? {
        guard token.hasPrefix("<0x") && token.hasSuffix(">") && token.count == 6 else {
            return nil
        }
        let hex = String(token.dropFirst(3).dropLast(1))
        guard let val = UInt8(hex, radix: 16) else { return nil }
        return val
    }
}
