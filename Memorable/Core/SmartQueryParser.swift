import Foundation
import FoundationModels

// Structured output from the on-device language model
@available(iOS 26.0, *)
@Generable
struct ParsedQuery {
    @Guide(description: "The visual content to search for — what the photo looks like. Remove time/location words, keep only visual descriptors. Examples: 'drink', 'sunset at beach', 'dog playing', 'birthday cake'.")
    var visualDescription: String

    @Guide(description: "ISO 8601 start date if a time period is mentioned. Use the current date \(ISO8601DateFormatter().string(from: Date())) as reference. 'last summer' = previous June 1, 'yesterday' = yesterday, 'last week' = 7 days ago. Null if no time mentioned.")
    var startDate: String?

    @Guide(description: "ISO 8601 end date for the time period. For 'last summer' = previous August 31. For 'yesterday' = end of yesterday. Null if no time mentioned.")
    var endDate: String?

    @Guide(description: "Location or place name if mentioned. Just the name, e.g. 'Sitapur', 'Paris', 'the beach'. Null if no location.")
    var locationName: String?

    @Guide(description: "Terms the user wants to EXCLUDE, prefixed with - in the query. E.g. from 'dog -cat', this would be ['cat']. Empty array if none.")
    var negativeTerms: [String]
}

@available(iOS 26.0, *)
class SmartQueryParser {
    private var session: LanguageModelSession?

    init() {
        if SystemLanguageModel.default.isAvailable {
            session = LanguageModelSession()
        }
    }

    var isAvailable: Bool { session != nil }

    func parse(query: String) async -> QueryHints {
        guard let session else {
            return QueryParserFallback.parse(query: query)
        }

        let prompt = """
        Parse this photo search query into structured fields.
        Today's date: \(ISO8601DateFormatter().string(from: Date()))

        IMPORTANT RULES:
        - Landmark names are visual descriptions, NOT locations. "Hoover Dam",
          "Eiffel Tower", "Golden Gate Bridge", "Big Ben" should go in
          visualDescription, not locationName.
        - locationName is for cities, countries, regions, neighborhoods.
          Examples: "Paris", "San Diego", "Berlin", "Old Town".
        - If the query is ONLY a landmark name with no city/region, set
          locationName to null.
        - Never split a proper noun across visualDescription and locationName.
          "Hoover Dam" is one thing, not "dam" + "Hoover".

        Query: "\(query)"
        """

        do {
            let response = try await session.respond(to: prompt, generating: ParsedQuery.self)
            let parsed = response.content

            var dateRange: DateRange?
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallbackFormatter = ISO8601DateFormatter()

            if let startStr = parsed.startDate, let endStr = parsed.endDate {
                let start = isoFormatter.date(from: startStr) ?? fallbackFormatter.date(from: startStr)
                let end = isoFormatter.date(from: endStr) ?? fallbackFormatter.date(from: endStr)
                if let start, let end {
                    dateRange = DateRange(start: start, end: end)
                }
            }

            // Sanity check: if the original query is short and FM split it
            // across visual + location, it likely misunderstood a compound
            // proper noun (e.g. "Hoover Dam" -> visual="dam", location="Hoover")
            var visualDesc = parsed.visualDescription
            var locName = parsed.locationName
            var landmarkRecombined = false
            let originalWordCount = query.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").count
            if originalWordCount <= 3,
               !visualDesc.isEmpty,
               let currentLoc = locName, !currentLoc.isEmpty {
                let locWords = currentLoc.split(separator: " ").count
                // Only recombine if the "location" is a single word.
                // Real cities are often multi-word ("San Diego", "New York").
                // Misidentified name fragments are usually single words
                // ("Hoover", "Eiffel", "Golden").
                if locWords == 1 {
                    let commonCities: Set<String> = ["berlin", "paris", "london", "tokyo",
                        "rome", "madrid", "munich", "vienna", "prague", "amsterdam",
                        "barcelona", "istanbul", "dubai", "singapore", "sydney",
                        "melbourne", "chicago", "boston", "seattle", "portland",
                        "denver", "austin", "miami", "orlando", "atlanta",
                        "dallas", "houston", "phoenix", "vegas", "sacramento",
                        "brooklyn", "manhattan", "queens"]
                    if !commonCities.contains(currentLoc.lowercased()) {
                        let combined = (currentLoc + " " + visualDesc).lowercased()
                        let reversed = (visualDesc + " " + currentLoc).lowercased()
                        let queryLower = query.lowercased()
                            .trimmingCharacters(in: .whitespaces)
                        if combined == queryLower || reversed == queryLower {
                            // FM split a compound proper noun. Treat as visual only.
                            visualDesc = queryLower
                            locName = nil
                            landmarkRecombined = true
                        }
                    }
                }
            }

            var visual = visualDesc.isEmpty ? "" : visualDesc.lowercased()

            // If FM returned empty visual but detected a location, use location as visual query too
            if visual.trimmingCharacters(in: .whitespaces).isEmpty,
               let loc = locName, !loc.isEmpty {
                visual = loc.lowercased()
            }

            let hasVisual = !visual.trimmingCharacters(in: .whitespaces).isEmpty

            // Time-of-day detection (Foundation Models doesn't extract this)
            let timeOfDayHours = TimeOfDayConfig.detect(in: query.lowercased())

            // Use Foundation Models result, fill gaps with fallback only if needed
            var locationHint = locName
            if !landmarkRecombined && (locationHint == nil || locationHint?.isEmpty == true) {
                let fallbackHints = QueryParserFallback.parse(query: query)
                locationHint = fallbackHints.locationHint
            }

            #if DEBUG
            logger.info("[SmartParser] FM visual='\(hasVisual ? visual : "a photo")', location=\(locationHint ?? "nil"), dateRange=\(dateRange.map { "\($0.start)–\($0.end)" } ?? "nil"), hasVisual=\(hasVisual)")
            #endif

            return QueryHints(
                textQuery: hasVisual ? visual : "a photo",
                dateRange: dateRange,
                locationHint: locationHint,
                negativeTerms: parsed.negativeTerms,
                timeOfDayHours: timeOfDayHours,
                hasVisualQuery: hasVisual
            )
        } catch {
            logger.error("Foundation model parse failed: \(error.localizedDescription), falling back to regex")
            return QueryParserFallback.parse(query: query)
        }
    }
}

// MARK: - Unified entry point

enum QueryParser {
    private static var smartParser: Any? = {
        if #available(iOS 26.0, *) {
            return SmartQueryParser()
        }
        return nil
    }()

    static func parse(query: String) async -> QueryHints {
        if #available(iOS 26.0, *),
           let smart = smartParser as? SmartQueryParser,
           smart.isAvailable {
            return await smart.parse(query: query)
        }
        return QueryParserFallback.parse(query: query)
    }

    // Synchronous fallback for callers that can't await
    static func parseSync(query: String) -> QueryHints {
        QueryParserFallback.parse(query: query)
    }
}
