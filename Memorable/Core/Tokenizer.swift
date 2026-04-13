import Foundation

/// SentencePiece BPE tokenizer for SigLIP2 (Gemma tokenizer).
/// Loads a standard SentencePiece .model protobuf and performs BPE tokenization
/// with byte fallback for unknown characters.
class CLIPTokenizer {
    private let contextLength: Int
    private let vocab: [String: Int]
    private let scores: [String: Float]
    private let byteFallbackTokens: [UInt8: Int]
    private let bosId: Int32
    private let eosId: Int32
    private let padId: Int32
    private var cache: [String: [Int]] = [:]
    private let maxCacheSize = 1000

    enum TokenizerError: Error {
        case filesNotFound
        case invalidModel
    }

    init(contextLength: Int = 64) throws {
        self.contextLength = contextLength

        guard let modelURL = Bundle.main.url(forResource: "tokenizer", withExtension: "model") else {
            throw TokenizerError.filesNotFound
        }
        let data = try Data(contentsOf: modelURL)
        let proto = try Sentencepiece_ModelProto(serializedBytes: data)

        let spec = proto.trainerSpec
        self.bosId = spec.bosID
        self.eosId = spec.eosID
        self.padId = spec.padID

        var v: [String: Int] = [:]
        var s: [String: Float] = [:]
        var byteTokens: [UInt8: Int] = [:]

        for (i, piece) in proto.pieces.enumerated() {
            v[piece.piece] = i
            s[piece.piece] = piece.score
            if piece.type == .byte {
                // Byte fallback tokens are formatted as <0xNN>
                if let byteVal = Self.parseByteToken(piece.piece) {
                    byteTokens[byteVal] = i
                }
            }
        }

        self.vocab = v
        self.scores = s
        self.byteFallbackTokens = byteTokens
    }

    func tokenize(text: String, maxLength: Int? = nil) -> [Int32] {
        let len = maxLength ?? contextLength
        let cleaned = preprocess(text)

        var tokens: [Int32] = [bosId]
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

    private func preprocess(_ text: String) -> String {
        var result = text.lowercased()
        result.unicodeScalars.removeAll { CharacterSet.punctuationCharacters.contains($0) }
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return result
    }

    // MARK: - Word Splitting

    /// SentencePiece treats whitespace as part of the token by prefixing words
    /// with the Unicode block character U+2581 (lower one eighth block).
    /// The first word in a sentence also gets this prefix (no dummy prefix = false
    /// means we still prefix all words with the separator, we just don't add an
    /// extra leading space to the input).
    private func splitIntoWords(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let separator = "\u{2581}"
        return text.split(separator: " ", omittingEmptySubsequences: true)
            .map { separator + String($0) }
    }

    // MARK: - BPE Encoding

    private func encode(_ word: String) -> [Int] {
        if cache.count > maxCacheSize { cache.removeAll() }
        if let cached = cache[word] { return cached }

        // Start with individual characters (or byte fallback for unknowns)
        var symbols = initialTokens(for: word)
        if symbols.count <= 1 {
            let ids = symbols.map { tokenId(for: $0) }
            cache[word] = ids
            return ids
        }

        // Iteratively merge the highest-scoring adjacent pair
        while symbols.count > 1 {
            var bestIdx = -1
            var bestScore: Float = -.infinity
            var bestMerged = ""

            for i in 0..<(symbols.count - 1) {
                let merged = symbols[i] + symbols[i + 1]
                if let score = scores[merged], score > bestScore {
                    bestScore = score
                    bestIdx = i
                    bestMerged = merged
                }
            }

            guard bestIdx >= 0, vocab[bestMerged] != nil else { break }

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
        cache[word] = ids
        return ids
    }

    /// Break a word into its initial character tokens. For characters that exist
    /// in the vocab as single-char pieces, use them directly. Otherwise, fall back
    /// to UTF-8 byte tokens.
    private func initialTokens(for word: String) -> [String] {
        var tokens: [String] = []
        for char in word {
            let s = String(char)
            if vocab[s] != nil {
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
        if let id = vocab[piece] { return id }
        // If a single byte token, use byte fallback
        if let byteVal = Self.parseByteToken(piece), let id = byteFallbackTokens[byteVal] {
            return id
        }
        // Unknown token (should not happen with byte fallback)
        return vocab["<unk>"] ?? 3
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
