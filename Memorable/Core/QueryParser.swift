import Foundation
import NaturalLanguage

struct QueryHints {
    var textQuery: String
    var dateRange: DateRange?
    var locationHint: String?
    var locationCoordinate: (lat: Double, lon: Double)?
    var seasonHint: Season?
    var negativeTerms: [String] = []
    var timeOfDayHours: (start: Int, end: Int)?  // 24h range, e.g. (18, 22) for evening
}

struct DateRange {
    var start: Date
    var end: Date
}

enum Season: String {
    case spring, summer, autumn, winter
}

// MARK: - Lightweight regex fallback (for devices without Foundation Models)

enum QueryParserFallback {

    static func parse(query: String) -> QueryHints {
        let trimmed = query.count > 500 ? String(query.prefix(500)) : query
        var text = trimmed.lowercased()
        var dateRange: DateRange?
        var locationHint: String?
        var negTerms: [String] = []

        let calendar = Calendar.current

        // Extract negative terms first
        let words = text.split(separator: " ").map(String.init)
        var positiveWords: [String] = []
        for word in words {
            if word.hasPrefix("-") && word.count > 1 {
                negTerms.append(String(word.dropFirst()))
            } else {
                positiveWords.append(word)
            }
        }
        text = positiveWords.joined(separator: " ")

        // Time-of-day detection from meal/activity keywords
        var timeOfDayHours: (start: Int, end: Int)?
        let timeKeywords: [(keywords: [String], hours: (start: Int, end: Int))] = [
            (["breakfast", "morning coffee", "morning run", "morning walk", "sunrise"], (5, 10)),
            (["brunch", "mid-morning", "late morning"], (9, 12)),
            (["lunch", "midday", "noon", "afternoon tea"], (11, 14)),
            (["afternoon", "evening walk"], (14, 18)),
            (["dinner", "supper", "evening", "sunset"], (18, 22)),
            (["night", "nighttime", "night out", "night sky", "late night", "midnight"], (20, 4)),
        ]
        for (keywords, hours) in timeKeywords {
            if keywords.contains(where: { text.contains($0) }) {
                timeOfDayHours = hours
                break
            }
        }

        // Season detection
        let seasonPatterns: [(pattern: String, months: (start: Int, end: Int), isLast: Bool)] = [
            ("last summer", (6, 8), true), ("this summer", (6, 8), false), ("in summer", (6, 8), false),
            ("last winter", (12, 2), true), ("this winter", (12, 2), false), ("in winter", (12, 2), false),
            ("last spring", (3, 5), true), ("this spring", (3, 5), false), ("in spring", (3, 5), false),
            ("last fall", (9, 11), true), ("this fall", (9, 11), false), ("in fall", (9, 11), false),
            ("last autumn", (9, 11), true), ("this autumn", (9, 11), false), ("in autumn", (9, 11), false),
        ]

        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        for (pattern, months, isLast) in seasonPatterns {
            if text.contains(pattern) {
                let year = isLast ? currentYear - 1 : currentYear

                if months.start == 12 {
                    // Winter spans Dec-Feb across year boundary
                    let decYear = isLast ? year - 1 : year
                    dateRange = DateRange(
                        start: calendar.date(from: DateComponents(year: decYear, month: 12, day: 1))!,
                        end: calendar.date(from: DateComponents(year: decYear + 1, month: 2, day: 28))!
                    )
                } else {
                    dateRange = DateRange(
                        start: calendar.date(from: DateComponents(year: year, month: months.start, day: 1))!,
                        end: calendar.date(from: DateComponents(year: year, month: months.end + 1, day: 0))!
                    )
                }
                text = text.replacingOccurrences(of: pattern, with: "").trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Relative date patterns (NSDataDetector doesn't handle these)
        if dateRange == nil {
            let relativeDatePatterns: [(pattern: String, daysBack: Int, spanDays: Int)] = [
                ("last week", 7, 7),
                ("this week", 0, 7),
                ("last month", 30, 30),
                ("this month", 0, 30),
                ("last year", 365, 365),
                ("this year", 0, 365),
                ("yesterday", 1, 1),
                ("today", 0, 1),
                ("last weekend", 7, 2),
                ("this weekend", 0, 2),
                ("few days ago", 3, 3),
                ("couple days ago", 2, 2),
                ("last night", 1, 1),
                ("last christmas", 365, 3),
                ("last new year", 365, 3),
            ]

            for (pattern, daysBack, spanDays) in relativeDatePatterns {
                if text.contains(pattern) {
                    let end = calendar.startOfDay(for: now.addingTimeInterval(-Double(daysBack) * 86400))
                    let start = end.addingTimeInterval(-Double(spanDays) * 86400)
                    // For "today"/"this week" etc., end should be now
                    if daysBack == 0 {
                        dateRange = DateRange(
                            start: calendar.date(byAdding: .day, value: -spanDays, to: now)!,
                            end: now
                        )
                    } else {
                        dateRange = DateRange(start: start, end: end.addingTimeInterval(86400))
                    }
                    text = text.replacingOccurrences(of: pattern, with: "").trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        // Date extraction via NSDataDetector (only if nothing above matched)
        if dateRange == nil {
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
                let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                if let match = matches.first, let date = match.date {
                    if match.duration > 0 {
                        dateRange = DateRange(start: date, end: date.addingTimeInterval(match.duration))
                    } else {
                        // Single date — use that day
                        let dayStart = calendar.startOfDay(for: date)
                        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                        dateRange = DateRange(start: dayStart, end: dayEnd)
                    }
                    // Remove the matched text
                    if let range = Range(match.range, in: text) {
                        text = text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // Location extraction via NLTagger
        extractLocation(from: trimmed, text: &text, locationHint: &locationHint)

        // Clean up
        text = text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        for prep in ["in", "at", "on", "from", "during", "of", "the", "my", "a"] {
            if text == prep { text = "" }
            if text.hasSuffix(" \(prep)") { text = String(text.dropLast(prep.count + 1)) }
            if text.hasPrefix("\(prep) ") { text = String(text.dropFirst(prep.count + 1)) }
        }

        if text.isEmpty { text = trimmed.lowercased() }

        return QueryHints(textQuery: text, dateRange: dateRange, locationHint: locationHint, negativeTerms: negTerms, timeOfDayHours: timeOfDayHours)
    }

    private static func extractLocation(from original: String, text: inout String, locationHint: inout String?) {
        // Use NLTagger for place name detection
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = original
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]

        tagger.enumerateTags(in: original.startIndex..<original.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if tag == .placeName {
                locationHint = String(original[range])
                text = text.replacingOccurrences(of: String(original[range]).lowercased(), with: "")
                    .trimmingCharacters(in: .whitespaces)
                return false // stop after first
            }
            return true
        }
    }
}
