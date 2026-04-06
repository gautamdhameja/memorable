import Foundation

class CLIPTokenizer {
    private let contextLength: Int
    private let vocab: [String: Int]
    private let bpeRanks: [String: Int]
    private let sotToken: Int
    private let eotToken: Int
    private let byteEncoder: [Int: Character]
    private var cache: [String: [String]] = [:]
    private let maxCacheSize = 1000

    static let vocabSize = 49408
    private static let maxMerges = vocabSize - 256 - 256 - 2 // 48894

    init(contextLength: Int = 77) throws {
        self.contextLength = contextLength

        guard let vocabURL = Bundle.main.url(forResource: "bpe_simple_vocab_16e6", withExtension: "txt") else {
            throw TokenizerError.filesNotFound
        }
        let vocabText = try String(contentsOf: vocabURL, encoding: .utf8)
        let lines = vocabText.components(separatedBy: "\n")

        var merges: [(String, String)] = []
        var ranks: [String: Int] = [:]
        for i in 1..<lines.count {
            let parts = lines[i].split(separator: " ")
            if parts.count == 2 {
                let pair = (String(parts[0]), String(parts[1]))
                merges.append(pair)
                ranks["\(pair.0) \(pair.1)"] = merges.count - 1
                if merges.count >= Self.maxMerges { break }
            }
        }
        self.bpeRanks = ranks

        var v: [String: Int] = [:]
        var idx = 0
        let be = Self.bytesToUnicode()
        self.byteEncoder = be

        for b in be.sorted(by: { $0.value < $1.value }) {
            v[String(b.value)] = idx
            idx += 1
        }
        for b in be.sorted(by: { $0.value < $1.value }) {
            v[String(b.value) + "</w>"] = idx
            idx += 1
        }
        for (a, b) in merges {
            v[a + b] = idx
            idx += 1
        }
        v["<|startoftext|>"] = idx
        v["<|endoftext|>"] = idx + 1
        self.vocab = v
        self.sotToken = idx
        self.eotToken = idx + 1
    }

    func tokenize(text: String, maxLength: Int? = nil) -> [Int32] {
        let len = maxLength ?? contextLength
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = splitIntoWords(cleaned)

        var tokens: [Int32] = [Int32(sotToken)]
        for word in words {
            for token in bpe(word) {
                if let id = vocab[token] {
                    tokens.append(Int32(id))
                }
            }
        }
        tokens.append(Int32(eotToken))

        if tokens.count > len {
            tokens = Array(tokens.prefix(len - 1)) + [Int32(eotToken)]
        }
        while tokens.count < len {
            tokens.append(0)
        }

        return tokens
    }

    // MARK: - Private

    private func splitIntoWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""

        for char in text {
            if char.isWhitespace {
                if !current.isEmpty {
                    words.append(encodeToByteString(current) + "</w>")
                    current = ""
                }
            } else if char.isPunctuation && !current.isEmpty {
                words.append(encodeToByteString(current) + "</w>")
                current = ""
                words.append(encodeToByteString(String(char)) + "</w>")
            } else if char.isPunctuation {
                words.append(encodeToByteString(String(char)) + "</w>")
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(encodeToByteString(current) + "</w>")
        }
        return words
    }

    private func encodeToByteString(_ text: String) -> String {
        String(text.utf8.compactMap { byteEncoder[Int($0)] })
    }

    private func bpe(_ token: String) -> [String] {
        if cache.count > maxCacheSize { cache.removeAll() }
        if let cached = cache[token] { return cached }

        var word: [String]
        if token.hasSuffix("</w>") {
            let base = String(token.dropLast(4))
            word = base.map { String($0) }
            if !word.isEmpty {
                word[word.count - 1] += "</w>"
            } else {
                word = ["</w>"]
            }
        } else {
            word = token.map { String($0) }
        }

        if word.count <= 1 {
            cache[token] = word
            return word
        }

        while true {
            var bestPair: (Int, String, String)?
            for i in 0..<(word.count - 1) {
                let key = "\(word[i]) \(word[i + 1])"
                if let rank = bpeRanks[key] {
                    if bestPair == nil || rank < bestPair!.0 {
                        bestPair = (rank, word[i], word[i + 1])
                        if rank == 0 { break }
                    }
                }
            }

            guard let (_, first, second) = bestPair else { break }

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
        }

        cache[token] = word
        return word
    }

    static func bytesToUnicode() -> [Int: Character] {
        var bs: [Int] = []
        bs.append(contentsOf: Array(Int(UnicodeScalar("!").value)...Int(UnicodeScalar("~").value)))
        bs.append(contentsOf: Array(Int(UnicodeScalar("\u{00A1}").value)...Int(UnicodeScalar("\u{00AC}").value)))
        bs.append(contentsOf: Array(Int(UnicodeScalar("\u{00AE}").value)...Int(UnicodeScalar("\u{00FF}").value)))
        var cs = bs.map { Character(UnicodeScalar($0)!) }
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(Character(UnicodeScalar(256 + n)!))
                n += 1
            }
        }
        var result: [Int: Character] = [:]
        for (i, b) in bs.enumerated() {
            result[b] = cs[i]
        }
        return result
    }

    enum TokenizerError: Error {
        case filesNotFound
    }
}
