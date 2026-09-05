import Foundation
import NaturalLanguage

enum QueryInputPolicy {
    static let maximumCharacterCount = 500
    static let maximumUTF8ByteCount = 2_000
    static let maximumNegativeTerms = 8
    static let maximumNegativeTermScalars = 100

    static func bounded(_ query: String) -> String {
        bounded(
            query,
            maximumUnicodeScalars: maximumCharacterCount,
            maximumUTF8Bytes: maximumUTF8ByteCount
        )
    }

    static func bounded(
        _ value: String,
        maximumUnicodeScalars: Int,
        maximumUTF8Bytes: Int
    ) -> String {
        let scalarLimit = max(0, maximumUnicodeScalars)
        let byteLimit = max(0, maximumUTF8Bytes)
        guard scalarLimit > 0, byteLimit > 0 else { return "" }

        var output = String.UnicodeScalarView()
        output.reserveCapacity(min(scalarLimit, byteLimit))
        var scalarCount = 0
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let width: Int
            switch scalar.value {
            case 0...0x7f: width = 1
            case 0x80...0x7ff: width = 2
            case 0x800...0xffff: width = 3
            default: width = 4
            }
            guard scalarCount < scalarLimit, byteCount + width <= byteLimit else { break }
            output.append(scalar)
            scalarCount += 1
            byteCount += width
        }
        return String(output)
    }
}

/// Enforces entitlement-sensitive search behavior at the parser and ranking
/// boundaries. Callers that do not provide a policy receive basic search.
struct SearchFeaturePolicy: Equatable, Sendable {
    let allowsAdvancedQueryFeatures: Bool
    let allowsFolderResults: Bool

    static let basic = SearchFeaturePolicy(
        allowsAdvancedQueryFeatures: false,
        allowsFolderResults: false
    )
    static let pro = SearchFeaturePolicy(
        allowsAdvancedQueryFeatures: true,
        allowsFolderResults: true
    )

    init(isPro: Bool) {
        allowsAdvancedQueryFeatures = isPro
        allowsFolderResults = isPro
    }

    private init(
        allowsAdvancedQueryFeatures: Bool,
        allowsFolderResults: Bool
    ) {
        self.allowsAdvancedQueryFeatures = allowsAdvancedQueryFeatures
        self.allowsFolderResults = allowsFolderResults
    }

    func enforcing(_ hints: QueryHints) -> QueryHints {
        guard allowsAdvancedQueryFeatures else {
            return QueryHints(
                textQuery: hints.textQuery,
                dateRange: nil,
                locationHint: nil,
                locationLocality: nil,
                locationSubAdmin: nil,
                locationAdminArea: nil,
                locationCountryName: nil,
                seasonHint: nil,
                negativeTerms: [],
                timeOfDayHours: nil,
                hasVisualQuery: true
            )
        }
        var bounded = hints
        bounded.textQuery = QueryInputPolicy.bounded(hints.textQuery)
        bounded.textMatchQuery = hints.textMatchQuery.map { QueryInputPolicy.bounded($0) }
        bounded.negativeTerms = Array(hints.negativeTerms
            .prefix(QueryInputPolicy.maximumNegativeTerms)
            .map {
                QueryInputPolicy.bounded(
                    $0,
                    maximumUnicodeScalars: QueryInputPolicy.maximumNegativeTermScalars,
                    maximumUTF8Bytes: QueryInputPolicy.maximumNegativeTermScalars * 4
                )
            }
            .filter { !$0.isEmpty })
        return bounded
    }

    func restrictionSummary(for hints: QueryHints) -> SearchRestrictionSummary? {
        guard !allowsAdvancedQueryFeatures else { return nil }
        var features = Set<RestrictedSearchFeature>()
        if hints.locationHint != nil { features.insert(.location) }
        if hints.dateRange != nil || hints.seasonHint != nil { features.insert(.date) }
        if !hints.negativeTerms.isEmpty { features.insert(.exclusions) }
        if hints.timeOfDayHours != nil { features.insert(.timeOfDay) }
        guard !features.isEmpty else { return nil }
        return SearchRestrictionSummary(features: features)
    }

    func enforcing(_ response: SearchResponse) -> SearchResponse {
        guard !allowsFolderResults else { return response }
        let isPhotoLibraryResult: (SearchResult) -> Bool = {
            $0.sourceId == PhotoSourceType.photokit.rawValue
        }
        return SearchResponse(
            results: response.results.filter(isPhotoLibraryResult),
            fallbackResults: response.fallbackResults.filter(isPhotoLibraryResult),
            filtersApplied: response.filtersApplied,
            restrictionSummary: response.restrictionSummary
        )
    }
}

struct QueryHints {
    var textQuery: String
    var dateRange: DateRange?
    var locationHint: String?
    // Optional canonical location fields. Search does not forward-geocode
    // query text; these remain nil unless a local parser can supply them.
    var locationLocality: String?
    var locationSubAdmin: String?
    var locationAdminArea: String?
    var locationCountryName: String?
    var seasonHint: Season?
    var negativeTerms: [String] = []
    var timeOfDayHours: (start: Int, end: Int)?
    var hasVisualQuery: Bool = true
    // Preserve literal search words when the smart parser rewrites visual text.
    // nil uses textQuery; an empty string disables literal matching.
    var textMatchQuery: String? = nil
}

struct DateRange {
    var start: Date
    var end: Date
    // Direct callers retain closed-range semantics; calendar parsing uses the
    // start of the next period as an exclusive upper boundary.
    var endIsExclusive = false

    func contains(_ date: Date) -> Bool {
        date >= start && (endIsExclusive ? date < end : date <= end)
    }
}

enum Season: String {
    case spring, summer, autumn, winter
}

// MARK: - Lightweight regex fallback (for devices without Foundation Models)

enum QueryParserFallback {

    static func parse(
        query: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> QueryHints {
        let trimmed = QueryInputPolicy.bounded(query)
        var text = trimmed.lowercased()
        var locationHint: String?
        var negTerms: [String] = []

        // 1. Extract negative terms
        let words = text.split(separator: " ").map(String.init)
        var positiveWords: [String] = []
        for word in words {
            if word.hasPrefix("-") && word.count > 1 {
                if negTerms.count < QueryInputPolicy.maximumNegativeTerms {
                    let term = QueryInputPolicy.bounded(
                        String(word.dropFirst()),
                        maximumUnicodeScalars: QueryInputPolicy.maximumNegativeTermScalars,
                        maximumUTF8Bytes: QueryInputPolicy.maximumNegativeTermScalars * 4
                    )
                    if !term.isEmpty { negTerms.append(term) }
                }
            } else {
                positiveWords.append(word)
            }
        }
        text = positiveWords.joined(separator: " ")

        // 2. Time-of-day detection from meal/activity keywords
        let timeOfDayHours = TimeOfDayConfig.detect(in: text)

        // 3. Extract temporal phrases (dates, seasons, holidays, relative periods)
        let temporal = TemporalParser.extract(from: text, now: now, cal: calendar)
        let dateRange = temporal.dateRange
        text = temporal.cleanedText

        // 4. Location extraction via NLTagger
        extractLocation(from: trimmed, text: &text, locationHint: &locationHint)
        var locationAdminArea: String?
        var locationCountryName: String?
        let originalLocationCode: String? = locationHint.flatMap { hint -> String? in
            guard hint.split(whereSeparator: \Character.isWhitespace).count == 1 else {
                return nil
            }
            return trimmed
                .split(whereSeparator: \Character.isWhitespace)
                .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
                .first(where: {
                    $0.caseInsensitiveCompare(hint) == .orderedSame
                        && AdministrativeRegionAliases.isKnownUppercaseCode($0)
                })
        }
        if let locationHint,
           locationHint.split(whereSeparator: \Character.isWhitespace).count == 1,
           let originalCode = originalLocationCode,
           let alias = AdministrativeRegionAliases.alias(
               forCode: originalCode.lowercased()
           ) {
                locationAdminArea = originalCode
                locationCountryName = alias.canonicalCountry
        }

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

        // Preserve a bare place name in textQuery as an explicit marker for
        // SearchEngine's pure-filter classification. The engine recognizes
        // textQuery == locationHint and returns every verified location match
        // by date without applying a meaningless place-name embedding rank.
        if cleanedText.isEmpty && locationHint != nil {
            cleanedText = locationHint!.lowercased()
        }

        let hasVisual = !cleanedText.isEmpty

        #if DEBUG
        logger.info("[QueryParser] Parsed query; visual=\(hasVisual), location=\(locationHint != nil), date=\(dateRange != nil), time=\(timeOfDayHours != nil), exclusions=\(negTerms.count)")
        #endif

        return QueryHints(
            textQuery: hasVisual ? cleanedText : "a photo",
            dateRange: dateRange,
            locationHint: locationHint,
            locationAdminArea: locationAdminArea,
            locationCountryName: locationCountryName,
            negativeTerms: negTerms,
            timeOfDayHours: timeOfDayHours,
            hasVisualQuery: hasVisual
        )
    }

    private static let visualWords: Set<String> = [
        // Photographic subjects and scenes
        "sunset", "sunrise", "beach", "mountain", "food", "dog", "cat",
        "car", "tree", "flower", "snow", "rain", "night", "morning",
        "selfie", "people", "baby", "wedding", "birthday", "christmas",
        "halloween", "lake", "river", "ocean", "forest", "park", "garden",
        "pool", "sky", "clouds", "street", "market", "lunch", "dinner",
        "breakfast", "coffee",
        // Common venue/scene nouns (appear after prepositions but are not locations)
        "home", "house", "room", "kitchen", "balcony", "rooftop", "terrace",
        "school", "office", "work", "gym", "hospital", "studio",
        "restaurant", "cafe", "bar", "pub", "hotel", "resort", "mall", "shop",
        "playground", "yard", "backyard",
        "trip", "vacation",
        "party", "concert", "festival", "event",
    ]

    private static let temporalWords: Set<String> = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
        "spring", "summer", "autumn", "fall", "winter",
        "yesterday", "today", "tomorrow", "tonight",
        "last", "this", "next", "recent", "recently",
        "week", "weekend", "month", "year",
        "christmas", "easter", "halloween", "thanksgiving",
        "valentines", "xmas",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    private static func extractLocation(from original: String, text: inout String, locationHint: inout String?) {
        var landmarkGuardTriggered = false
        let textBeforeExtraction = text

        // Exact uppercase administrative codes carry useful intent while their
        // lowercase forms are often ordinary words (IN, OR, ME). Preserve that
        // casing signal before the rest of the parser operates on lowercase text.
        let remainingWords = text.split(separator: " ")
        if remainingWords.count == 1,
           let originalCode = original.split(separator: " ")
            .map(String.init)
            .first(where: { $0.lowercased() == remainingWords[0].lowercased() }),
           AdministrativeRegionAliases.isKnownUppercaseCode(originalCode) {
            locationHint = originalCode
            text = ""
            return
        }

        // Strategy 1: NLTagger on original text (works when user types proper case)
        if let place = extractPlaceViaTagger(original),
           !temporalWords.contains(place.lowercased()),
           !visualWords.contains(place.lowercased()) {
            let remaining = text.replacingOccurrences(of: place.lowercased(), with: "")
                .trimmingCharacters(in: .whitespaces)

            // Guard: if removing the "place" leaves behind just 1 short word,
            // NLTagger probably split a compound proper noun like "Hoover Dam"
            // or "Eiffel Tower". The whole query is likely a landmark name,
            // not a location + visual descriptor.
            if !isLikelyLandmarkFragment(remaining: remaining, original: original) {
                locationHint = place
                text = remaining
                // Don't return — let Strategy 2 try to override with a
                // higher-confidence preposition-based match.
            } else {
                landmarkGuardTriggered = true
            }
        }

        // Strategy 2: Location preposition pattern — "in/at/near/from <words>"
        // Take words after the preposition until we hit another preposition or temporal word.
        // Always search the pre-Strategy-1 text so NLTagger's word removal doesn't
        // hide a preposition pattern (e.g. "lunar eclipse in berlin" must remain
        // intact for "in berlin" to match).
        let lowered = textBeforeExtraction
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

            // Single visual or temporal words after a preposition are not
            // locations. "dog in park" is a scene, "photos from easter"
            // is temporal. Multi-word locations ("in San Diego") are fine.
            if locationWords.count == 1 {
                let word = locationWords[0].lowercased()
                if visualWords.contains(word) || temporalWords.contains(word) {
                    continue
                }
            }

            locationHint = locationWords.joined(separator: " ")
            // Remove "prep + location" from the original text (not the
            // NLTagger-modified one) so we preserve all visual query words.
            let locationPhrase = prep + locationWords.joined(separator: " ")
            text = lowered.replacingOccurrences(of: locationPhrase, with: "")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return
        }

        // If Strategy 1 already found a location, use it.
        if locationHint != nil { return }

        // Strategy 3: Bare location fallback. Every candidate must be present
        // in a bundled gazetteer; capitalization alone cannot distinguish a
        // place from a person's name.
        // Local metadata matching validates the hint. If nothing matches, the
        // search proceeds as normal visual search.
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

                // Filter out any temporal words that survived into the
                // candidate list. The temporal parser already consumed them
                // from `text`, but `nonTemporalOriginalWords` is derived
                // from the original input and may still contain them.
                let candidates = nonTemporalOriginalWords.filter {
                    !temporalWords.contains($0.lowercased())
                }

                if allCapitalized && !candidates.isEmpty {
                    // Single capitalized words are too ambiguous (pet names,
                    // people names, brand names). Only treat them as locations
                    // if they match a known city name AND are not a common
                    // visual/photographic term. "Sunrise" is a city in Florida
                    // but users almost always mean the visual concept.
                    if candidates.count == 1 {
                        let word = candidates[0].lowercased()
                        let isKnownLocation = KnownCities.singleWord.contains(word)
                            || KnownRegions.singleWord.contains(word)
                        if isKnownLocation && !visualWords.contains(word) {
                            locationHint = candidates.joined(separator: " ")
                            text = ""
                        }
                    } else {
                        let phrase = candidates.joined(separator: " ").lowercased()
                        if KnownMultiwordLocations.names.contains(phrase) {
                            locationHint = candidates.joined(separator: " ")
                            text = ""
                        }
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

    static func extract(from text: String, now: Date, cal: Calendar) -> Result {
        var cleaned = text.replacingOccurrences(of: "'s", with: "")

        // A complete explicit date must win over its month or year fragment.
        // Invalid explicit dates remain visual text rather than becoming a
        // silently different month/year filter through the fallback stages.
        if let explicit = extractExplicitDate(from: cleaned, cal: cal) {
            return explicit
        }

        // Phase 1: Pattern table (longest first)
        let explicitYears = Set(cleaned.matches(of: /\b([0-9]{4})\b/)
            .compactMap { Int($0.1) }.filter { $0 > 0 })
        let patterns = buildPatterns(now: now, cal: cal, explicitYears: explicitYears)
        let sorted = patterns.sorted { $0.phrase.count > $1.phrase.count }

        for pattern in sorted {
            if let range = matchPhrase(pattern.phrase, in: cleaned) {
                if var dateRange = pattern.resolve() {
                    dateRange.endIsExclusive = true
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
                    dateRange = DateRange(start: date, end: date.addingTimeInterval(match.duration), endIsExclusive: true)
                } else {
                    let dayStart = cal.startOfDay(for: date)
                    let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                    dateRange = DateRange(start: dayStart, end: dayEnd, endIsExclusive: true)
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

    private static let monthNames: [(full: String, abbr: String, num: Int)] = [
        ("january", "jan", 1), ("february", "feb", 2), ("march", "mar", 3),
        ("april", "apr", 4), ("may", "may", 5), ("june", "jun", 6),
        ("july", "jul", 7), ("august", "aug", 8), ("september", "sep", 9),
        ("october", "oct", 10), ("november", "nov", 11), ("december", "dec", 12),
    ]

    private static func extractExplicitDate(from text: String, cal: Calendar) -> Result? {
        func resolve(year: Int, month: Int, day: Int, range: Range<String.Index>) -> Result {
            let components = DateComponents(year: year, month: month, day: day)
            guard year > 0, let start = cal.date(from: components),
                  cal.component(.year, from: start) == year,
                  cal.component(.month, from: start) == month,
                  cal.component(.day, from: start) == day,
                  let end = cal.date(byAdding: .day, value: 1, to: start) else {
                return Result(dateRange: nil, cleanedText: text)
            }
            var cleaned = text
            cleaned.replaceSubrange(range, with: "")
            cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return Result(dateRange: DateRange(start: start, end: end, endIsExclusive: true), cleanedText: cleaned)
        }
        if let match = text.firstMatch(of: /\b([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})\b/),
           let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) {
            return resolve(year: year, month: month, day: day, range: match.range)
        }
        if let match = text.firstMatch(of: /\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|october|oct|november|nov|december|dec)\.?\s+([0-9]{1,2})(?:st|nd|rd|th)?(?:,)?\s+([0-9]{4})\b/),
           let month = monthNames.first(where: { $0.full == match.1 || $0.abbr == match.1 })?.num,
           let day = Int(match.2), let year = Int(match.3) {
            return resolve(year: year, month: month, day: day, range: match.range)
        }
        if let match = text.firstMatch(of: /\b([0-9]{1,2})(?:st|nd|rd|th)?\s+(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|october|oct|november|nov|december|dec)\.?(?:,)?\s+([0-9]{4})\b/),
           let day = Int(match.1),
           let month = monthNames.first(where: { $0.full == match.2 || $0.abbr == match.2 })?.num,
           let year = Int(match.3) {
            return resolve(year: year, month: month, day: day, range: match.range)
        }
        return nil
    }

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
        let pattern = /\b([0-9]{4})\b/
        guard let match = text.firstMatch(of: pattern),
              let year = Int(match.1), year > 0 else { return nil }
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = cal.date(byAdding: .year, value: 1, to: start)
        else { return nil }
        return (DateRange(start: start, end: end, endIsExclusive: true), match.range)
    }

    // MARK: - Pattern table

    private struct TemporalPattern {
        let phrase: String
        let resolve: () -> DateRange?
    }

    private static func buildPatterns(now: Date, cal: Calendar, explicitYears: Set<Int>) -> [TemporalPattern] {
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
            let end = cal.date(byAdding: .year, value: 1, to: start) ?? start
            return DateRange(start: start, end: end)
        }
        func seasonRange(year: Int, startMonth: Int, endMonth: Int) -> DateRange {
            if startMonth == 12 {
                let febEnd = cal.date(from: DateComponents(year: year, month: 3, day: 0)) ?? makeDate(year, 2, 28)
                return DateRange(start: makeDate(year - 1, 12, 1), end: dayEnd(febEnd))
            }
            let start = makeDate(year, startMonth, 1)
            let endDate = cal.date(from: DateComponents(year: year, month: endMonth + 1, day: 0)) ?? start
            return DateRange(start: start, end: dayEnd(endDate))
        }
        func startOfWeek(weeksBack: Int) -> Date {
            let components = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            let weekStart = cal.date(from: components) ?? today
            return cal.date(byAdding: .day, value: -(weeksBack * 7), to: weekStart) ?? today
        }
        func weekdayOfWeek(_ weekday: Int, weeksBack: Int) -> Date {
            let weekStart = startOfWeek(weeksBack: weeksBack)
            let weekdayOffset = (weekday - cal.component(.weekday, from: weekStart) + 7) % 7
            return cal.date(byAdding: .day, value: weekdayOffset, to: weekStart) ?? today
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
            let start = startOfWeek(weeksBack: 2)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return DateRange(start: dayStart(start), end: dayEnd(end))
        })
        patterns.append(TemporalPattern(phrase: "past few days") { DateRange(start: daysAgo(5), end: now) })
        patterns.append(TemporalPattern(phrase: "few days ago") { DateRange(start: daysAgo(5), end: now) })
        patterns.append(TemporalPattern(phrase: "couple days ago") { DateRange(start: daysAgo(3), end: daysAgo(1)) })
        patterns.append(TemporalPattern(phrase: "last week") {
            let start = startOfWeek(weeksBack: 1)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            return DateRange(start: dayStart(start), end: dayEnd(end))
        })
        patterns.append(TemporalPattern(phrase: "this week") {
            return DateRange(start: startOfWeek(weeksBack: 0), end: now)
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
            return DateRange(start: s, end: now)
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
        for year in explicitYears.sorted() {
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

        for year in explicitYears.sorted() {
            // Consume the year with every recognized holiday, so the bare
            // holiday cannot silently replace an explicit historical date.
            let holidays: [(names: [String], month: Int, start: Int, endMonth: Int, end: Int)] = [
                (["christmas", "xmas"], 12, 23, 12, 27),
                (["christmas eve"], 12, 23, 12, 25),
                (["christmas day"], 12, 25, 12, 25),
                (["halloween"], 10, 29, 11, 1),
                (["thanksgiving"], 11, 20, 11, 30),
                (["valentines", "valentines day", "valentine day"], 2, 13, 2, 15),
                (["easter"], 3, 15, 4, 30),
            ]
            for holiday in holidays {
                for name in holiday.names {
                    patterns.append(TemporalPattern(phrase: "\(name) \(year)") {
                        DateRange(
                            start: makeDate(year, holiday.month, holiday.start),
                            end: dayEnd(makeDate(year, holiday.endMonth, holiday.end))
                        )
                    })
                }
            }
            for name in ["new year", "new years"] {
                patterns.append(TemporalPattern(phrase: "\(name) \(year)") {
                    DateRange(start: makeDate(year - 1, 12, 30), end: dayEnd(makeDate(year, 1, 2)))
                })
            }
            for name in ["new years eve", "new year eve"] {
                patterns.append(TemporalPattern(phrase: "\(name) \(year)") {
                    DateRange(start: makeDate(year, 12, 31), end: dayEnd(makeDate(year + 1, 1, 1)))
                })
            }
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

        for alias in ["new years eve", "new year eve"] {
            patterns.append(TemporalPattern(phrase: alias) {
                let year = currentMonth > 1 || cal.component(.day, from: now) >= 2 ? currentYear : currentYear - 1
                return DateRange(start: makeDate(year - 1, 12, 31), end: dayEnd(makeDate(year, 1, 1)))
            })
        }
        patterns.append(TemporalPattern(phrase: "last new year") {
            return DateRange(start: makeDate(currentYear - 1, 12, 30), end: dayEnd(makeDate(currentYear, 1, 2)))
        })
        for alias in ["new year", "new years"] {
            patterns.append(TemporalPattern(phrase: alias) {
                let year = currentMonth > 1 || cal.component(.day, from: now) >= 3 ? currentYear : currentYear - 1
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
        for (full, abbr, month) in monthNames {
            // "january 2023", "jan 2023"
            for year in explicitYears.sorted() {
                for name in [full, abbr] {
                    patterns.append(TemporalPattern(phrase: "\(name) \(year)") {
                        monthRange(year: year, month: month)
                    })
                }
            }
            // "january last year", "jan last year"
            for name in [full, abbr] {
                patterns.append(TemporalPattern(phrase: "\(name) last year") {
                    monthRange(year: currentYear - 1, month: month)
                })
                patterns.append(TemporalPattern(phrase: "\(name) this year") {
                    monthRange(year: currentYear, month: month)
                })
                patterns.append(TemporalPattern(phrase: "last \(name)") {
                    let year = (currentMonth > month) ? currentYear : currentYear - 1
                    return monthRange(year: year, month: month)
                })
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
