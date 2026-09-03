import Foundation
import os

/// SentencePiece BPE tokenizer for SigLIP2 (Gemma tokenizer).
/// Loads a standard SentencePiece .model protobuf and performs BPE tokenization
/// with byte fallback for unknown characters.
final class CLIPTokenizer: Sendable {
    private struct Piece: Sendable {
        let id: Int
        let score: Float
    }

    private let contextLength: Int
    private let pieces: [String: Piece]
    private let byteFallbackTokens: [UInt8: Int]
    private let eosId: Int32
    private let padId: Int32
    private let cache = OSAllocatedUnfairLock(initialState: [String: [Int]]())
    private let maxCacheSize = 1000

    enum TokenizerError: LocalizedError {
        case filesNotFound

        var errorDescription: String? {
            "The search vocabulary is missing. Reinstall Memorable and try again."
        }
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
        let model = try Sentencepiece_ModelProto(serializedBytes: data)
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerProtoDecode,
            durationSeconds: CFAbsoluteTimeGetCurrent() - protoDecodeStartedAt
        )
        #endif

        self.eosId = model.trainerSpec.eosID
        // SentencePiece proto defaults pad_id to -1; SigLIP2/Gemma uses 0 (<pad>)
        self.padId = model.trainerSpec.padID >= 0 ? model.trainerSpec.padID : 0

        var pieces: [String: Piece] = [:]
        pieces.reserveCapacity(model.pieces.count)
        var byteTokens: [UInt8: Int] = [:]
        byteTokens.reserveCapacity(256)
        #if DEBUG || STARTUP_METRICS
        let tableBuildStartedAt = CFAbsoluteTimeGetCurrent()
        #endif

        for (i, piece) in model.pieces.enumerated() {
            pieces[piece.piece] = Piece(id: i, score: piece.score)
            if piece.type == .byte {
                // Byte fallback tokens are formatted as <0xNN>
                if let byteVal = Self.parseByteToken(piece.piece) {
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
