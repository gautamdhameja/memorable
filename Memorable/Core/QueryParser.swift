import Foundation
import NaturalLanguage

struct QueryHints {
    var textQuery: String
    var dateRange: DateRange?
    var locationHint: String?
    var locationCoordinate: (lat: Double, lon: Double)?
    var locationRadiusKm: Double?
    var seasonHint: Season?
    var negativeTerms: [String] = []
    var timeOfDayHours: (start: Int, end: Int)?
    var hasVisualQuery: Bool = true
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
        var locationHint: String?
        var negTerms: [String] = []

        // 1. Extract negative terms
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

        // 2. Time-of-day detection from meal/activity keywords
        let timeOfDayHours = TimeOfDayConfig.detect(in: text)

        // 3. Extract temporal phrases (dates, seasons, holidays, relative periods)
        let temporal = TemporalParser.extract(from: text)
        let dateRange = temporal.dateRange
        text = temporal.cleanedText

        // 4. Location extraction via NLTagger
        extractLocation(from: trimmed, text: &text, locationHint: &locationHint)

        // 5. Clean up — loop to strip chained prepositions (e.g., "car service in" → "car service")
        text = text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        let preps = ["in", "at", "on", "to", "from", "near", "during", "of", "the", "my", "a", "an", "for", "with"]
        var changed = true
        while changed {
            changed = false
            for prep in preps {
                if text == prep { text = ""; changed = true; break }
                if text.hasSuffix(" \(prep)") {
                    text = String(text.dropLast(prep.count + 1))
                    changed = true
                }
                if text.hasPrefix("\(prep) ") {
                    text = String(text.dropFirst(prep.count + 1))
                    changed = true
                }
            }
        }

        var cleanedText = text.trimmingCharacters(in: .whitespaces)

        // If location extraction consumed the entire query, the place name itself
        // is a visual concept (e.g. "Hoover Dam", "Eiffel Tower", "Berlin").
        // Use it as both location filter AND visual query so CLIP can match by
        // appearance, not just GPS coordinates.
        if cleanedText.isEmpty && locationHint != nil {
            cleanedText = locationHint!.lowercased()
        }

        let hasVisual = !cleanedText.isEmpty

        #if DEBUG
        logger.info("[QueryParser] input='\(trimmed)' → textQuery='\(hasVisual ? cleanedText : "a photo")', location=\(locationHint ?? "nil"), dateRange=\(dateRange.map { "\($0.start)–\($0.end)" } ?? "nil"), timeOfDay=\(timeOfDayHours.map { "\($0.start)-\($0.end)" } ?? "nil"), hasVisual=\(hasVisual)")
        #endif

        return QueryHints(
            textQuery: hasVisual ? cleanedText : "a photo",
            dateRange: dateRange,
            locationHint: locationHint,
            negativeTerms: negTerms,
            timeOfDayHours: timeOfDayHours,
            hasVisualQuery: hasVisual
        )
    }

    private static func extractLocation(from original: String, text: inout String, locationHint: inout String?) {
        var landmarkGuardTriggered = false

        // Strategy 1: NLTagger on original text (works when user types proper case)
        if let place = extractPlaceViaTagger(original) {
            let remaining = text.replacingOccurrences(of: place.lowercased(), with: "")
                .trimmingCharacters(in: .whitespaces)

            // Guard: if removing the "place" leaves behind just 1 short word,
            // NLTagger probably split a compound proper noun like "Hoover Dam"
            // or "Eiffel Tower". The whole query is likely a landmark name,
            // not a location + visual descriptor.
            if !isLikelyLandmarkFragment(remaining: remaining, original: original) {
                locationHint = place
                text = remaining
                return
            } else {
                landmarkGuardTriggered = true
            }
        }

        // Strategy 2: Location preposition pattern — "in/at/near/from <words>"
        // Take words after the preposition until we hit another preposition or temporal word
        let lowered = text
        let locationPreps = ["in ", "at ", "near ", "from "]
        let stopWords = Set(["in", "at", "on", "from", "near", "during", "last", "this", "yesterday",
                             "today", "summer", "winter", "spring", "fall", "autumn"])
        let nonLocationStarters = Set(["the", "my", "a", "an", "this", "that", "last",
                                       "summer", "winter", "spring", "fall", "autumn"])

        for prep in locationPreps {
            // Match preposition at word boundary only (avoid "berl*in* sunset")
            guard let prepRange = lowered.range(of: prep) else { continue }
            guard prepRange.upperBound < lowered.endIndex else { continue }
            // Ensure the preposition starts at a word boundary
            if prepRange.lowerBound != lowered.startIndex {
                let charBefore = lowered[lowered.index(before: prepRange.lowerBound)]
                if charBefore.isLetter { continue }
            }

            let afterPrep = String(lowered[prepRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !afterPrep.isEmpty else { continue }

            let firstWord = afterPrep.split(separator: " ").first.map(String.init) ?? ""
            if nonLocationStarters.contains(firstWord) { continue }
            // Skip if it looks like a year (e.g., "in 2021")
            if firstWord.count == 4, Int(firstWord) != nil { continue }

            // Take words until we hit a stop word or a year
            var locationWords: [String] = []
            for word in afterPrep.split(separator: " ").map(String.init) {
                if stopWords.contains(word) { break }
                if word.count == 4, Int(word) != nil { break }
                locationWords.append(word)
            }
            guard !locationWords.isEmpty else { continue }

            locationHint = locationWords.joined(separator: " ")
            // Remove "prep + location" from text, keep the rest
            let locationPhrase = prep + locationWords.joined(separator: " ")
            text = lowered.replacingOccurrences(of: locationPhrase, with: "")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return
        }

        // Strategy 3: Bare multi-word proper noun fallback
        // If the entire remaining text is 1-4 capitalized words with no obvious
        // visual content words, treat it as a potential location.
        // The geocoder in SearchEngine will validate. If it fails to geocode,
        // the search proceeds as normal CLIP search.
        // Skip if Strategy 1's landmark guard triggered — the query is a landmark
        // name (e.g. "Hoover Dam"), not a city.
        if !landmarkGuardTriggered {
            let remainingWords = text.split(separator: " ").map(String.init)
            if remainingWords.count >= 1 && remainingWords.count <= 4 && locationHint == nil {
                let originalWords = original.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").map(String.init)
                // Filter out words consumed by temporal parser
                let nonTemporalOriginalWords = originalWords.filter { word in
                    text.localizedCaseInsensitiveContains(word)
                }
                let allCapitalized = nonTemporalOriginalWords.allSatisfy { word in
                    guard let first = word.first else { return false }
                    return first.isUppercase
                }

                if allCapitalized && !nonTemporalOriginalWords.isEmpty {
                    let visualWords: Set<String> = ["sunset", "sunrise", "beach", "mountain",
                        "food", "dog", "cat", "car", "tree", "flower", "snow",
                        "rain", "night", "morning", "selfie", "people", "baby",
                        "wedding", "birthday", "christmas", "halloween"]
                    let isLikelyVisual = nonTemporalOriginalWords.allSatisfy {
                        visualWords.contains($0.lowercased())
                    }

                    // Landmark indicator words — if any word in the query is a
                    // landmark noun, treat the whole thing as visual, not location.
                    // "Hoover Dam", "Eiffel Tower", "Golden Gate Bridge", "Niagara Falls"
                    let landmarkWords: Set<String> = ["dam", "tower", "bridge", "falls",
                        "monument", "palace", "castle", "gate", "wall", "square",
                        "plaza", "temple", "cathedral", "pyramid", "statue",
                        "lighthouse", "canyon", "reef", "volcano", "glacier",
                        "arch", "museum", "fountain", "church", "dome",
                        "fort", "ruins", "peak", "bay", "harbor"]
                    let hasLandmarkWord = nonTemporalOriginalWords.contains {
                        landmarkWords.contains($0.lowercased())
                    }

                    if !isLikelyVisual && !hasLandmarkWord {
                        locationHint = nonTemporalOriginalWords.joined(separator: " ")
                        text = ""
                    }
                }
            }
        }
    }

    /// Returns true if the remaining text after place extraction looks like a
    /// landmark fragment (e.g. "dam", "tower", "bridge") rather than a
    /// standalone visual query (e.g. "sunset", "food", "dog").
    private static func isLikelyLandmarkFragment(remaining: String, original: String) -> Bool {
        let remainingWords = remaining.split(separator: " ")
        let originalWords = original.trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
        guard remainingWords.count == 1, originalWords.count <= 3 else { return false }

        let commonVisualWords: Set<String> = ["sunset", "sunrise", "beach",
            "mountain", "food", "dog", "cat", "car", "tree", "flower",
            "snow", "rain", "night", "morning", "selfie", "people",
            "lunch", "dinner", "breakfast", "wedding", "birthday",
            "park", "lake", "river", "ocean", "sea", "forest",
            "street", "market", "garden", "pool", "sky", "clouds"]
        let word = String(remainingWords[0]).lowercased()
        return !commonVisualWords.contains(word)
    }

    private static func extractPlaceViaTagger(_ input: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = input
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation]

        var placeWords: [String] = []
        var lastEnd: String.Index?

        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if tag == .placeName {
                if let prevEnd = lastEnd {
                    let gap = input[prevEnd..<range.lowerBound]
                    if gap.allSatisfy({ $0 == " " }) {
                        placeWords.append(String(input[range]))
                    } else {
                        if !placeWords.isEmpty { return false }
                        placeWords.append(String(input[range]))
                    }
                } else {
                    placeWords.append(String(input[range]))
                }
                lastEnd = range.upperBound
            } else if !placeWords.isEmpty {
                return false
            }
            return true
        }

        return placeWords.isEmpty ? nil : placeWords.joined(separator: " ")
    }
}

// MARK: - Temporal Parser

private enum TemporalParser {

    struct Result {
        let dateRange: DateRange?
        let cleanedText: String
    }

    static func extract(from text: String) -> Result {
        var cleaned = text.replacingOccurrences(of: "'s", with: "")
        let now = Date()
        let cal = Calendar.current

        // Phase 1: Pattern table (longest first)
        let patterns = buildPatterns(now: now, cal: cal)
        let sorted = patterns.sorted { $0.phrase.count > $1.phrase.count }

        for pattern in sorted {
            if let range = matchPhrase(pattern.phrase, in: cleaned) {
                if let dateRange = pattern.resolve() {
                    cleaned.replaceSubrange(range, with: "")
                    cleaned = cleaned.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
                    return Result(dateRange: dateRange, cleanedText: cleaned)
                }
            }
        }

        // Phase 1b: Bare year (e.g., "vacation 2023")
        if let (yearRange, yearStringRange) = extractBareYear(from: cleaned, cal: cal) {
            cleaned.replaceSubrange(yearStringRange, with: "")
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            return Result(dateRange: yearRange, cleanedText: cleaned)
        }

        // Phase 2: NSDataDetector fallback
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let matches = detector.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            if let match = matches.first, let date = match.date {
                let dateRange: DateRange
                if match.duration > 0 {
                    dateRange = DateRange(start: date, end: date.addingTimeInterval(match.duration))
                } else {
                    let dayStart = cal.startOfDay(for: date)
                    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                    dateRange = DateRange(start: dayStart, end: dayEnd)
                }
                if let range = Range(match.range, in: cleaned) {
                    cleaned.replaceSubrange(range, with: "")
                    cleaned = cleaned.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
                }
                return Result(dateRange: dateRange, cleanedText: cleaned)
            }
        }

        return Result(dateRange: nil, cleanedText: cleaned)
    }

    // MARK: - Word boundary matching

    private static func matchPhrase(_ phrase: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let beforeOK = range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == " "
            let afterOK = range.upperBound == text.endIndex || text[range.upperBound] == " "
            if beforeOK && afterOK { return range }
            searchStart = range.upperBound
        }
        return nil
    }

    // MARK: - Bare year extraction

    private static func extractBareYear(from text: String, cal: Calendar) -> (DateRange, Range<String.Index>)? {
        let pattern = /\b(20\d{2})\b/
        guard let match = text.firstMatch(of: pattern),
              let year = Int(match.1) else { return nil }
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        else { return nil }
        return (DateRange(start: start, end: end), match.range)
    }

    // MARK: - Pattern table

    private struct TemporalPattern {
        let phrase: String
        let resolve: () -> DateRange?
    }

    private static func buildPatterns(now: Date, cal: Calendar) -> [TemporalPattern] {
        let today = cal.startOfDay(for: now)
        let currentYear = cal.component(.year, from: now)
        let currentMonth = cal.component(.month, from: now)

        // Safe calendar helpers — use ?? today as fallback (should never trigger with valid inputs)
        func dayStart(_ date: Date) -> Date { cal.startOfDay(for: date) }
        func dayEnd(_ date: Date) -> Date { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date)) ?? date }
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today) ?? today }
        func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d)) ?? today
        }
        func monthRange(year: Int, month: Int) -> DateRange {
            let start = makeDate(year, month, 1)
            let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
            return DateRange(start: start, end: dayEnd(end))
        }
        func fullYear(_ y: Int) -> DateRange {
            let start = makeDate(y, 1, 1)
            let end = cal.date(from: DateComponents(year: y, month: 12, day: 31, hour: 23, minute: 59, second: 59)) ?? start
            return DateRange(start: start, end: end)
        }
        func seasonRange(year: Int, startMonth: Int, endMonth: Int) -> DateRange {
            if startMonth == 12 {
                return DateRange(start: makeDate(year - 1, 12, 1), end: dayEnd(makeDate(year, 2, 28)))
            }
            let start = makeDate(year, startMonth, 1)
            let endDate = cal.date(from: DateComponents(year: year, month: endMonth + 1, day: 0)) ?? start
            return DateRange(start: start, end: dayEnd(endDate))
        }
        func mostRecentPast(month: Int, dayStart: Int, dayEnd de: Int) -> DateRange {
            let thisYear = makeDate(currentYear, month, de)
            let year = thisYear <= now ? currentYear : currentYear - 1
            return DateRange(
                start: makeDate(year, month, dayStart),
                end: TemporalParser.dayEndHelper(makeDate(year, month, de), cal: cal)
            )
        }
        func weekdayOfWeek(_ weekday: Int, weeksBack: Int) -> Date {
            let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            let monday = cal.date(from: components) ?? today
            return cal.date(byAdding: .day, value: -(weeksBack * 7) + (weekday - 2), to: monday) ?? today
        }

        var patterns: [TemporalPattern] = []

        // --- Relative days ---
        patterns.append(TemporalPattern(phrase: "day before yesterday") { DateRange(start: daysAgo(2), end: dayEnd(daysAgo(2))) })
        patterns.append(TemporalPattern(phrase: "the other day") { DateRange(start: daysAgo(3), end: now) })
        patterns.append(TemporalPattern(phrase: "yesterday") { DateRange(start: daysAgo(1), end: dayEnd(daysAgo(1))) })
        patterns.append(TemporalPattern(phrase: "today") { DateRange(start: today, end: now) })

        // --- Relative weeks ---
        patterns.append(TemporalPattern(phrase: "last weekend") {
            let lastSat = weekdayOfWeek(7, weeksBack: 1)
            let lastSun = cal.date(byAdding: .day, value: 1, to: lastSat) ?? lastSat
            return DateRange(start: dayStart(lastSat), end: dayEnd(lastSun))
        })
        patterns.append(TemporalPattern(phrase: "this weekend") {
            let thisSat = weekdayOfWeek(7, weeksBack: 0)
            let thisSun = cal.date(byAdding: .day, value: 1, to: thisSat) ?? thisSat
            return DateRange(start: dayStart(thisSat), end: dayEnd(thisSun))
        })
        patterns.append(TemporalPattern(phrase: "two weeks ago") {
            let start = weekdayOfWeek(2, weeksBack: 2)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return DateRange(start: dayStart(start), end: dayEnd(end))
        })
        patterns.append(TemporalPattern(phrase: "past few days") { DateRange(start: daysAgo(5), end: now) })
        patterns.append(TemporalPattern(phrase: "few days ago") { DateRange(start: daysAgo(5), end: now) })
        patterns.append(TemporalPattern(phrase: "couple days ago") { DateRange(start: daysAgo(3), end: daysAgo(1)) })
        patterns.append(TemporalPattern(phrase: "last week") {
            let start = weekdayOfWeek(2, weeksBack: 1)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return DateRange(start: dayStart(start), end: dayEnd(end))
        })
        patterns.append(TemporalPattern(phrase: "this week") {
            let monday = weekdayOfWeek(2, weeksBack: 0)
            return DateRange(start: dayStart(monday), end: now)
        })
        patterns.append(TemporalPattern(phrase: "recently") { DateRange(start: daysAgo(14), end: now) })
        patterns.append(TemporalPattern(phrase: "last night") { DateRange(start: daysAgo(1), end: dayEnd(daysAgo(1))) })

        // --- Relative months ---
        patterns.append(TemporalPattern(phrase: "a couple months ago") {
            let s = cal.date(byAdding: .month, value: -3, to: today) ?? today
            let e = cal.date(byAdding: .month, value: -1, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "couple months ago") {
            let s = cal.date(byAdding: .month, value: -3, to: today) ?? today
            let e = cal.date(byAdding: .month, value: -1, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "past few months") {
            DateRange(start: cal.date(byAdding: .month, value: -3, to: today) ?? today, end: now)
        })
        patterns.append(TemporalPattern(phrase: "few months ago") {
            DateRange(start: cal.date(byAdding: .month, value: -3, to: today) ?? today, end: now)
        })
        patterns.append(TemporalPattern(phrase: "two months ago") {
            let start = cal.date(byAdding: .month, value: -2, to: today) ?? today
            return monthRange(year: cal.component(.year, from: start), month: cal.component(.month, from: start))
        })
        patterns.append(TemporalPattern(phrase: "a month ago") {
            let s = cal.date(byAdding: .day, value: -37, to: today) ?? today
            let e = cal.date(byAdding: .day, value: -23, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "earlier this year") {
            let s = makeDate(currentYear, 1, 1)
            let e = cal.date(byAdding: .month, value: -3, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "last month") {
            let prevMonth = cal.date(byAdding: .month, value: -1, to: today) ?? today
            return monthRange(year: cal.component(.year, from: prevMonth), month: cal.component(.month, from: prevMonth))
        })
        patterns.append(TemporalPattern(phrase: "this month") {
            DateRange(start: makeDate(currentYear, currentMonth, 1), end: now)
        })

        // --- Relative years ---
        patterns.append(TemporalPattern(phrase: "a few years ago") {
            let s = cal.date(byAdding: .year, value: -4, to: today) ?? today
            let e = cal.date(byAdding: .year, value: -2, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "few years ago") {
            let s = cal.date(byAdding: .year, value: -4, to: today) ?? today
            let e = cal.date(byAdding: .year, value: -2, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "a year ago") {
            let s = cal.date(byAdding: .day, value: -380, to: today) ?? today
            let e = cal.date(byAdding: .day, value: -350, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "years ago") {
            let s = cal.date(byAdding: .year, value: -5, to: today) ?? today
            let e = cal.date(byAdding: .year, value: -2, to: today) ?? today
            return DateRange(start: s, end: e)
        })
        patterns.append(TemporalPattern(phrase: "two years ago") { fullYear(currentYear - 2) })
        patterns.append(TemporalPattern(phrase: "last year") { fullYear(currentYear - 1) })
        patterns.append(TemporalPattern(phrase: "this year") {
            DateRange(start: makeDate(currentYear, 1, 1), end: now)
        })

        // --- Seasons with year ---
        for year in (currentYear - 5)...currentYear {
            let ys = String(year)
            patterns.append(TemporalPattern(phrase: "summer \(ys)") { seasonRange(year: year, startMonth: 6, endMonth: 8) })
            patterns.append(TemporalPattern(phrase: "winter \(ys)") { seasonRange(year: year, startMonth: 12, endMonth: 2) })
            patterns.append(TemporalPattern(phrase: "spring \(ys)") { seasonRange(year: year, startMonth: 3, endMonth: 5) })
            patterns.append(TemporalPattern(phrase: "fall \(ys)") { seasonRange(year: year, startMonth: 9, endMonth: 11) })
            patterns.append(TemporalPattern(phrase: "autumn \(ys)") { seasonRange(year: year, startMonth: 9, endMonth: 11) })
        }

        // --- Seasons relative ---
        patterns.append(TemporalPattern(phrase: "last summer") { seasonRange(year: currentYear - 1, startMonth: 6, endMonth: 8) })
        patterns.append(TemporalPattern(phrase: "this summer") { seasonRange(year: currentYear, startMonth: 6, endMonth: 8) })
        patterns.append(TemporalPattern(phrase: "in summer") { seasonRange(year: currentYear - 1, startMonth: 6, endMonth: 8) })

        patterns.append(TemporalPattern(phrase: "last winter") { seasonRange(year: currentYear - 1, startMonth: 12, endMonth: 2) })
        patterns.append(TemporalPattern(phrase: "this winter") { seasonRange(year: currentYear, startMonth: 12, endMonth: 2) })
        patterns.append(TemporalPattern(phrase: "in winter") { seasonRange(year: currentYear - 1, startMonth: 12, endMonth: 2) })

        patterns.append(TemporalPattern(phrase: "last spring") { seasonRange(year: currentYear - 1, startMonth: 3, endMonth: 5) })
        patterns.append(TemporalPattern(phrase: "this spring") { seasonRange(year: currentYear, startMonth: 3, endMonth: 5) })
        patterns.append(TemporalPattern(phrase: "in spring") { seasonRange(year: currentYear - 1, startMonth: 3, endMonth: 5) })

        patterns.append(TemporalPattern(phrase: "last fall") { seasonRange(year: currentYear - 1, startMonth: 9, endMonth: 11) })
        patterns.append(TemporalPattern(phrase: "last autumn") { seasonRange(year: currentYear - 1, startMonth: 9, endMonth: 11) })
        patterns.append(TemporalPattern(phrase: "this fall") { seasonRange(year: currentYear, startMonth: 9, endMonth: 11) })
        patterns.append(TemporalPattern(phrase: "this autumn") { seasonRange(year: currentYear, startMonth: 9, endMonth: 11) })
        patterns.append(TemporalPattern(phrase: "in fall") { seasonRange(year: currentYear - 1, startMonth: 9, endMonth: 11) })
        patterns.append(TemporalPattern(phrase: "in autumn") { seasonRange(year: currentYear - 1, startMonth: 9, endMonth: 11) })

        // --- Holidays ---
        patterns.append(TemporalPattern(phrase: "christmas eve") {
            let year = currentMonth == 12 && cal.component(.day, from: now) >= 24 ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year, 12, 23), end: dayEnd(makeDate(year, 12, 25)))
        })
        patterns.append(TemporalPattern(phrase: "christmas day") {
            let year = currentMonth == 12 && cal.component(.day, from: now) >= 26 ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year, 12, 25), end: dayEnd(makeDate(year, 12, 25)))
        })

        for year in (currentYear - 5)...currentYear {
            patterns.append(TemporalPattern(phrase: "christmas \(year)") {
                DateRange(start: makeDate(year, 12, 23), end: dayEnd(makeDate(year, 12, 27)))
            })
            patterns.append(TemporalPattern(phrase: "new year \(year)") {
                DateRange(start: makeDate(year - 1, 12, 30), end: dayEnd(makeDate(year, 1, 2)))
            })
        }

        patterns.append(TemporalPattern(phrase: "last christmas") {
            let year = currentMonth == 12 && cal.component(.day, from: now) >= 27 ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year, 12, 23), end: dayEnd(makeDate(year, 12, 27)))
        })
        for alias in ["christmas", "xmas"] {
            patterns.append(TemporalPattern(phrase: alias) {
                let year = currentMonth == 12 && cal.component(.day, from: now) >= 27 ? currentYear : currentYear - 1
                return DateRange(start: makeDate(year, 12, 23), end: dayEnd(makeDate(year, 12, 27)))
            })
        }

        patterns.append(TemporalPattern(phrase: "new years eve") {
            let year = currentMonth >= 1 && cal.component(.day, from: now) >= 2 ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year - 1, 12, 31), end: dayEnd(makeDate(year, 1, 1)))
        })
        patterns.append(TemporalPattern(phrase: "last new year") {
            return DateRange(start: makeDate(currentYear - 1, 12, 30), end: dayEnd(makeDate(currentYear, 1, 2)))
        })
        for alias in ["new year", "new years"] {
            patterns.append(TemporalPattern(phrase: alias) {
                let year = currentMonth >= 1 && cal.component(.day, from: now) >= 3 ? currentYear : currentYear - 1
                return DateRange(start: makeDate(year - 1, 12, 30), end: dayEnd(makeDate(year, 1, 2)))
            })
        }

        patterns.append(TemporalPattern(phrase: "halloween") {
            let year = currentMonth >= 11 ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year, 10, 29), end: dayEnd(makeDate(year, 11, 1)))
        })

        patterns.append(TemporalPattern(phrase: "thanksgiving") {
            let year = currentMonth == 12 || (currentMonth == 11 && cal.component(.day, from: now) >= 28) ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year, 11, 20), end: dayEnd(makeDate(year, 11, 30)))
        })

        for alias in ["valentines", "valentine's day", "valentines day"] {
            patterns.append(TemporalPattern(phrase: alias) {
                let year = currentMonth > 2 || (currentMonth == 2 && cal.component(.day, from: now) >= 15) ? currentYear : currentYear - 1
                return DateRange(start: makeDate(year, 2, 13), end: dayEnd(makeDate(year, 2, 15)))
            })
        }

        patterns.append(TemporalPattern(phrase: "easter") {
            let year = currentMonth >= 5 ? currentYear : currentYear - 1
            return DateRange(start: makeDate(year, 3, 15), end: dayEnd(makeDate(year, 4, 30)))
        })

        // --- Named months (with year variants) ---
        let monthNames: [(full: String, abbr: String, num: Int)] = [
            ("january", "jan", 1), ("february", "feb", 2), ("march", "mar", 3),
            ("april", "apr", 4), ("may", "may", 5), ("june", "jun", 6),
            ("july", "jul", 7), ("august", "aug", 8), ("september", "sep", 9),
            ("october", "oct", 10), ("november", "nov", 11), ("december", "dec", 12),
        ]

        for (full, abbr, month) in monthNames {
            // "january 2023", "jan 2023"
            for year in (currentYear - 5)...currentYear {
                for name in [full, abbr] {
                    patterns.append(TemporalPattern(phrase: "\(name) \(year)") {
                        monthRange(year: year, month: month)
                    })
                }
            }
            // Bare month name: "january" -> most recent past January
            for name in [full, abbr] {
                patterns.append(TemporalPattern(phrase: name) {
                    let year = (currentMonth > month) ? currentYear : currentYear - 1
                    return monthRange(year: year, month: month)
                })
            }
        }

        return patterns
    }

    private static func dayEndHelper(_ date: Date, cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date)) ?? date
    }
}
