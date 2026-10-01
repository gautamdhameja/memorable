import Foundation
import FoundationModels
import os

enum SmartQueryOutputPolicy {
    static let maximumVisualCharacters = QueryInputPolicy.maximumCharacterCount
    static let maximumLocationCharacters = 200
    static let maximumDateCharacters = 64
    private static let genericMediaNouns: Set<String> = [
        "image", "images", "photo", "photos", "photograph", "photographs",
        "picture", "pictures",
    ]

    static func bounded(_ value: String, maximumCharacters: Int) -> String {
        QueryInputPolicy.bounded(
            value,
            maximumUnicodeScalars: maximumCharacters,
            maximumUTF8Bytes: maximumCharacters * 4
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func boundedOptional(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value else { return nil }
        let boundedValue = bounded(value, maximumCharacters: maximumCharacters)
        guard !boundedValue.isEmpty, boundedValue.lowercased() != "null" else { return nil }
        return boundedValue
    }

    static func removingGenericMediaNouns(from value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace)
            .filter { token in
                let normalized = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
                return !genericMediaNouns.contains(normalized)
            }
            .joined(separator: " ")
    }
}

enum SmartQueryPerformancePolicy {
    static let responseTimeoutSeconds: TimeInterval = 1.5
}

// Structured output from the on-device language model
@available(iOS 26.0, *)
@Generable
struct ParsedQuery: Sendable {
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
protocol SmartQueryResponding: Sendable {
    func respond(to prompt: String) async throws -> ParsedQuery
}

@available(iOS 26.0, *)
private struct LanguageModelSmartQueryResponder: SmartQueryResponding {
    private let session = LanguageModelSession()

    func respond(to prompt: String) async throws -> ParsedQuery {
        try await session.respond(to: prompt, generating: ParsedQuery.self).content
    }
}

@available(iOS 26.0, *)
private final class SmartQueryCircuitBreaker: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var cancelledRequestCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var permitsRequest: Bool {
        state.withLock { !$0.isOpen && $0.cancelledRequestCount == 0 }
    }

    func open() {
        state.withLock { $0.isOpen = true }
    }

    func beginCancelledRequest() {
        state.withLock { $0.cancelledRequestCount += 1 }
    }

    func finishCancelledRequest(timedOut: Bool) {
        state.withLock { state in
            state.cancelledRequestCount = max(0, state.cancelledRequestCount - 1)
            if timedOut {
                state.isOpen = true
            }
        }
    }
}

@available(iOS 26.0, *)
/// Private control-flow error consumed by `parse`. It is converted to a local
/// fallback or a diagnostic code and never crosses a user-presentation boundary.
private enum SmartQueryResponseError: Error, Sendable {
    case cancelled
    case responder(String)
    case timedOut
}

@available(iOS 26.0, *)
private final class SmartQueryResponseController: Sendable {
    typealias Response = Result<ParsedQuery, SmartQueryResponseError>

    private struct State: Sendable {
        var continuation: ContinuationGuard<Response>?
        var responseTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var isCallerCancelled = false
        var isCancellationSuspended = false
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let circuitBreaker: SmartQueryCircuitBreaker

    init(circuitBreaker: SmartQueryCircuitBreaker) {
        self.circuitBreaker = circuitBreaker
    }

    @discardableResult
    func installContinuation(_ continuation: ContinuationGuard<Response>) -> Bool {
        let didInstall = state.withLock { state in
            guard !state.isFinished, !state.isCallerCancelled else { return false }
            state.continuation = continuation
            return true
        }
        if !didInstall {
            continuation.resume(returning: .failure(.cancelled))
        }
        return didInstall
    }

    @discardableResult
    func startResponse(
        _ operation: @escaping @Sendable () async -> Response
    ) -> Bool {
        state.withLock { state in
            guard !state.isFinished, !state.isCallerCancelled else { return false }
            let task = Task { [self] in
                finish(await operation())
            }
            state.responseTask = task
            return true
        }
    }

    func registerTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { state in
            guard !state.isFinished else { return true }
            state.timeoutTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func finish(_ response: Response) {
        guard let completion = takeCompletion() else { return }
        completion.timeoutTask?.cancel()
        if completion.wasCancellationSuspended {
            circuitBreaker.finishCancelledRequest(timedOut: false)
        }
        completion.continuation?.resume(returning: response)
    }

    func timeOut() {
        guard let completion = takeCompletion() else { return }
        completion.responseTask?.cancel()
        if completion.wasCancellationSuspended {
            circuitBreaker.finishCancelledRequest(timedOut: true)
        } else {
            circuitBreaker.open()
        }
        completion.continuation?.resume(returning: .failure(.timedOut))
    }

    func cancel() {
        let cancellation = state.withLock { state -> (
            continuation: ContinuationGuard<Response>?,
            responseTask: Task<Void, Never>?
        )? in
            guard !state.isFinished, !state.isCallerCancelled else { return nil }
            state.isCallerCancelled = true
            if state.responseTask != nil {
                state.isCancellationSuspended = true
                circuitBreaker.beginCancelledRequest()
            }
            defer { state.continuation = nil }
            return (state.continuation, state.responseTask)
        }
        guard let cancellation else { return }
        cancellation.responseTask?.cancel()
        cancellation.continuation?.resume(returning: .failure(.cancelled))
    }

    private func takeCompletion() -> (
        continuation: ContinuationGuard<Response>?,
        responseTask: Task<Void, Never>?,
        timeoutTask: Task<Void, Never>?,
        wasCancellationSuspended: Bool
    )? {
        state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            defer {
                state.continuation = nil
                state.responseTask = nil
                state.timeoutTask = nil
            }
            return (
                state.continuation,
                state.responseTask,
                state.timeoutTask,
                state.isCancellationSuspended
            )
        }
    }
}

@available(iOS 26.0, *)
struct SmartQueryParser: Sendable {
    private let responderFactory: @Sendable () -> any SmartQueryResponding
    private let responseTimeoutSeconds: TimeInterval
    private let circuitBreaker = SmartQueryCircuitBreaker()
    let isAvailable: Bool

    init(
        isAvailable: Bool = SystemLanguageModel.default.isAvailable,
        responseTimeoutSeconds: TimeInterval = SmartQueryPerformancePolicy.responseTimeoutSeconds,
        responderFactory: @escaping @Sendable () -> any SmartQueryResponding = {
            LanguageModelSmartQueryResponder()
        }
    ) {
        self.isAvailable = isAvailable
        self.responseTimeoutSeconds = max(0, responseTimeoutSeconds)
        self.responderFactory = responderFactory
    }

    func parse(query: String) async -> QueryHints {
        let query = QueryInputPolicy.bounded(query)
        guard isAvailable else {
            return QueryParserFallback.parse(query: query)
        }
        guard circuitBreaker.permitsRequest else {
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
            let parsed = try await boundedResponse(to: prompt)
            let fallbackHints = QueryParserFallback.parse(query: query)

            // Date filters are hard constraints, so use the deterministic local
            // parser instead of trusting model-generated dates that may invent a
            // date or collapse a requested year into a single day.
            let dateRange = fallbackHints.dateRange

            // Sanity check: if the original query is short and FM split it
            // across visual + location, it likely misunderstood a compound
            // proper noun (e.g. "Hoover Dam" -> visual="dam", location="Hoover")
            var visualDesc = SmartQueryOutputPolicy.bounded(
                parsed.visualDescription,
                maximumCharacters: SmartQueryOutputPolicy.maximumVisualCharacters
            )
            visualDesc = SmartQueryOutputPolicy.removingGenericMediaNouns(from: visualDesc)
            var locName = SmartQueryOutputPolicy.boundedOptional(
                parsed.locationName,
                maximumCharacters: SmartQueryOutputPolicy.maximumLocationCharacters
            )
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
                    if !KnownCities.singleWord.contains(currentLoc.lowercased()) {
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

            let fallbackHasStructuredIntent = fallbackHints.dateRange != nil
                || fallbackHints.locationHint != nil
            if fallbackHasStructuredIntent {
                visualDesc = fallbackHints.hasVisualQuery
                    ? SmartQueryOutputPolicy.removingGenericMediaNouns(from: fallbackHints.textQuery)
                    : ""
            } else if visualDesc.isEmpty, fallbackHints.hasVisualQuery {
                // A valid model response can still omit the subject. Preserve
                // the user's local visual query instead of disabling search.
                visualDesc = fallbackHints.textQuery
            }

            var visual = visualDesc.isEmpty ? "" : visualDesc.lowercased()

            // If FM returned empty visual but detected a location, use location as visual query too
            if visual.trimmingCharacters(in: .whitespaces).isEmpty,
               let loc = locName, !loc.isEmpty {
                visual = loc.lowercased()
            }

            let hasVisual = !visual.trimmingCharacters(in: .whitespaces).isEmpty

            // Time-of-day detection (Foundation Models doesn't extract this)
            let timeOfDayHours = fallbackHints.timeOfDayHours

            // Locations are hard constraints, so only the deterministic local
            // parser may create one. Model-only locations can be hallucinated
            // from visual concepts or names (for example, "party" or
            // "Paris Hilton") and must remain ordinary visual search text.
            var locationHint = landmarkRecombined ? nil : fallbackHints.locationHint
            locationHint = SmartQueryOutputPolicy.boundedOptional(
                locationHint,
                maximumCharacters: SmartQueryOutputPolicy.maximumLocationCharacters
            )

            #if DEBUG
            logger.info("[SmartParser] Parsed query; visual=\(hasVisual), location=\(locationHint != nil), date=\(dateRange != nil)")
            #endif

            // Exclusions change result eligibility. Only explicit user terms
            // may penalize results; the model can invent or omit exclusions.
            let negativeTerms = fallbackHints.negativeTerms

            return QueryHints(
                textQuery: hasVisual ? visual : "a photo",
                dateRange: dateRange,
                locationHint: locationHint,
                locationLocality: locationHint == nil ? nil : fallbackHints.locationLocality,
                locationSubAdmin: locationHint == nil ? nil : fallbackHints.locationSubAdmin,
                locationAdminArea: locationHint == nil ? nil : fallbackHints.locationAdminArea,
                locationCountryName: locationHint == nil ? nil : fallbackHints.locationCountryName,
                negativeTerms: negativeTerms,
                timeOfDayHours: timeOfDayHours,
                hasVisualQuery: hasVisual,
                textMatchQuery: fallbackHints.hasVisualQuery ? fallbackHints.textQuery : ""
            )
        } catch {
            switch error {
            case .cancelled:
                break
            case .timedOut:
                logger.error("Foundation model parse timed out after \(responseTimeoutSeconds)s; disabling smart parsing for this launch")
            case .responder(let diagnosticCode):
                logger.error("Foundation model parse failed: \(diagnosticCode), falling back to regex")
            }
            return QueryParserFallback.parse(query: query)
        }
    }

    private func boundedResponse(to prompt: String) async throws(SmartQueryResponseError) -> ParsedQuery {
        let responder = responderFactory()
        let controller = SmartQueryResponseController(circuitBreaker: circuitBreaker)

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<ParsedQuery, SmartQueryResponseError>, Never>) in
                guard controller.installContinuation(ContinuationGuard(continuation)) else {
                    return
                }

                guard controller.startResponse({
                    let response: Result<ParsedQuery, SmartQueryResponseError>
                    do {
                        response = .success(try await responder.respond(to: prompt))
                    } catch {
                        response = .failure(.responder(error.safeDiagnosticCode))
                    }
                    return response
                }) else {
                    return
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: .seconds(responseTimeoutSeconds))
                    } catch {
                        return
                    }
                    controller.timeOut()
                }
                controller.registerTimeoutTask(timeoutTask)
            }
        } onCancel: {
            controller.cancel()
        }

        return try result.get()
    }
}

// MARK: - Unified entry point

enum QueryParser {
    @available(iOS 26.0, *)
    private static let smartParser = SmartQueryParser()

    static func parse(
        query: String,
        featurePolicy: SearchFeaturePolicy = .basic
    ) async -> QueryHints {
        let query = QueryInputPolicy.bounded(query)
        guard featurePolicy.allowsAdvancedQueryFeatures else {
            let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return QueryHints(textQuery: text.isEmpty ? "a photo" : text, hasVisualQuery: !text.isEmpty)
        }
        if #available(iOS 26.0, *),
           smartParser.isAvailable {
            return await smartParser.parse(query: query)
        }
        return QueryParserFallback.parse(query: query)
    }

}
