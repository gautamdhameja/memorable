import Foundation
import NaturalLanguage

struct OCRTextMatch: Equatable, Sendable {
    enum Kind: Int, Sendable {
        case truncatedWord = 1
        case completePhrase = 2
    }

    let kind: Kind
    let before: String
    let phrase: String
    let after: String

    var excerpt: String { before + phrase + after }
}

/// Uses Apple's word boundaries. The only tolerated OCR error is one missing
/// final letter in a word of at least six letters, with two exact word anchors.
/// This deliberately does not perform spelling correction or general fuzzy search.
struct OCRTextMatcher {
    private let tokenizer = NLTokenizer(unit: .word)
    private let queryWords: [String]

    init(query: String) {
        tokenizer.string = query
        queryWords = tokenizer.tokens(for: query.startIndex..<query.endIndex)
            .map { Self.normalized(String(query[$0])) }
    }

    // Create one matcher per scoring call; NLTokenizer is not shared across tasks.
    func match(in text: String) -> OCRTextMatch? {
        guard !queryWords.isEmpty else { return nil }
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard ranges.count >= queryWords.count else { return nil }
        let words = ranges.map { Self.normalized(String(text[$0])) }
        var truncatedRange: Range<String.Index>?
        for start in 0...(words.count - queryWords.count) {
            var missingLetters = 0
            var accepted = true
            for offset in queryWords.indices {
                let expected = queryWords[offset]
                let actual = words[start + offset]
                if expected == actual { continue }
                guard queryWords.count >= 3, missingLetters == 0,
                      expected.count >= 6, expected.allSatisfy(\.isLetter),
                      actual == String(expected.dropLast()) else {
                    accepted = false
                    break
                }
                missingLetters += 1
            }
            guard accepted else { continue }
            let range = ranges[start].lowerBound..<ranges[start + queryWords.count - 1].upperBound
            if missingLetters == 0 {
                return excerpt(in: text, range: range, kind: .completePhrase)
            }
            if truncatedRange == nil { truncatedRange = range }
        }
        return truncatedRange.map { excerpt(in: text, range: $0, kind: .truncatedWord) }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    private func excerpt(
        in text: String, range: Range<String.Index>, kind: OCRTextMatch.Kind
    ) -> OCRTextMatch {
        let prefix = text[..<range.lowerBound]
        let phrase = text[range]
        let suffix = text[range.upperBound...]
        return OCRTextMatch(
            kind: kind,
            before: (prefix.count > 35 ? "…" : "") + prefix.suffix(35),
            phrase: String(phrase.prefix(120)),
            after: phrase.count > 120 ? "…" : String(suffix.prefix(45)) + (suffix.count > 45 ? "…" : "")
        )
    }
}
