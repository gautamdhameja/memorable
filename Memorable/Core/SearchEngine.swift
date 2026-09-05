import Foundation
import NaturalLanguage
import Accelerate
import os

struct SearchResponse {
    let results: [SearchResult]
    let fallbackResults: [SearchResult]
    let filtersApplied: FilterSummary?
    let restrictionSummary: SearchRestrictionSummary?

    init(
        results: [SearchResult],
        fallbackResults: [SearchResult],
        filtersApplied: FilterSummary?,
        restrictionSummary: SearchRestrictionSummary? = nil
    ) {
        self.results = results
        self.fallbackResults = fallbackResults
        self.filtersApplied = filtersApplied
        self.restrictionSummary = restrictionSummary
    }
}

struct FilterSummary {
    let dateDescription: String?
    let locationDescription: String?
    let visualQuery: String
}

enum RestrictedSearchFeature: Hashable, Sendable {
    case location
    case date
    case exclusions
    case timeOfDay
}

struct SearchRestrictionSummary: Equatable, Sendable {
    let features: Set<RestrictedSearchFeature>

    var message: String {
        if features == [.location] {
            return "Place filters are part of Pro. Showing visual matches instead."
        }
        if features == [.date] {
            return "Date filters are part of Pro. Showing visual matches instead."
        }
        if features == [.location, .date] {
            return "Place and date filters are part of Pro. Showing visual matches instead."
        }
        return "Advanced search filters are part of Pro. Showing visual matches instead."
    }
}

/// Ensures that overlapping callers share one complete replacement attempt,
/// so waiters never build or retain their own database copy.
private final class IndexLoadCoordinator: @unchecked Sendable {
    private final class Flight: @unchecked Sendable {
        let completion = DispatchGroup()
        let generation: UInt
        var error: Error?

        init(generation: UInt) {
            self.generation = generation
            completion.enter()
        }
    }

    private let lock = NSLock()
    private var activeFlight: Flight?

    func run(generation: UInt, _ operation: () throws -> Void) throws {
        while true {
            if try runFlight(generation: generation, operation) { return }
        }
    }

    private func runFlight(generation: UInt, _ operation: () throws -> Void) throws -> Bool {
        let flight: Flight
        let isLeader: Bool

        lock.lock()
        if let activeFlight {
            flight = activeFlight
            isLeader = false
        } else {
            flight = Flight(generation: generation)
            activeFlight = flight
            isLeader = true
        }
        lock.unlock()

        guard isLeader else {
            while flight.completion.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            // A caller after invalidation needs a fresh load, not the obsolete
            // flight's success or failure. Serialize it behind that flight.
            guard flight.generation == generation else { return false }
            lock.lock()
            let error = flight.error
            lock.unlock()
            if let error { throw error }
            return true
        }

        do {
            try operation()
            finish(flight, error: nil)
        } catch {
            finish(flight, error: error)
            throw error
        }
        return true
    }

    private func finish(_ flight: Flight, error: Error?) {
        lock.lock()
        flight.error = error
        flight.completion.leave()
        if activeFlight === flight {
            activeFlight = nil
        }
        lock.unlock()
    }
}

/// Keeps snapshot installation and tail-cache invalidation exclusive with
/// searches. Replacement construction happens before this short transition;
/// waiters remain cancelable while existing searches finish.
private final class SearchIndexAccessCoordinator: @unchecked Sendable {
    private let condition = NSCondition()
    private var reloadInProgress = false
    private var activeSearches = 0

    func withSearch<T>(_ operation: () throws -> T) throws -> T {
        condition.lock()
        while reloadInProgress {
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
            do {
                try Task.checkCancellation()
            } catch {
                condition.unlock()
                throw error
            }
        }
        activeSearches += 1
        condition.unlock()

        defer { finishSearch() }
        return try operation()
    }

    func withSearchUnlessCancelled<T>(_ operation: () -> T) -> T? {
        condition.lock()
        while reloadInProgress {
            if Task.isCancelled {
                condition.unlock()
                return nil
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
        }
        activeSearches += 1
        condition.unlock()

        defer { finishSearch() }
        return operation()
    }

    func withExclusiveReload(_ operation: () throws -> Void) throws {
        condition.lock()
        reloadInProgress = true
        while activeSearches > 0 {
            _ = condition.wait(until: Date().addingTimeInterval(0.025))
            do {
                try Task.checkCancellation()
            } catch {
                reloadInProgress = false
                condition.broadcast()
                condition.unlock()
                throw error
            }
        }
        condition.unlock()

        defer {
            condition.lock()
            reloadInProgress = false
            condition.broadcast()
            condition.unlock()
        }
        try operation()
    }

    private func finishSearch() {
        condition.lock()
        activeSearches -= 1
        if activeSearches == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}

/// Retains decoded continuation pages across searches. The cache never evicts
/// during a generation (which would make sequential full scans thrash); once
/// its conservative byte budget is full, later pages simply remain uncached.
final class SearchTailPageCache: @unchecked Sendable {
    private struct State: Sendable {
        var pages: [SearchMediaPageCursor: SearchMediaPage] = [:]
        var retainedBytes = 0
        var isFull = false
        var generation: UInt = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maximumBytes: Int

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let minimum = 16 * 1_048_576
        let maximum = 64 * 1_048_576
        maximumBytes = max(minimum, min(maximum, Int(physicalMemory / 128)))
    }

    init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    var retainedBytes: Int { state.withLock { $0.retainedBytes } }

    func page(after cursor: SearchMediaPageCursor, generation: UInt) -> SearchMediaPage? {
        state.withLock { $0.generation == generation ? $0.pages[cursor] : nil }
    }

    func insert(_ page: SearchMediaPage, after cursor: SearchMediaPageCursor, generation: UInt) {
        guard state.withLock({
            $0.generation == generation && !$0.isFull && $0.pages[cursor] == nil
        }) else { return }
        let cost = Self.estimatedBytes(for: page)
        state.withLock { state in
            guard state.generation == generation,
                  !state.isFull, state.pages[cursor] == nil else { return }
            guard state.retainedBytes + cost <= maximumBytes else {
                state.isFull = true
                return
            }
            state.pages[cursor] = page
            state.retainedBytes += cost
        }
    }

    func invalidate(generation: UInt) {
        state.withLock { $0 = State(generation: generation) }
    }

    static func estimatedBytes(for page: SearchMediaPage) -> Int {
        // Include allocated array storage and each string's payload. Charging
        // shared/inline strings separately deliberately overestimates ownership.
        func arrayBytes<T>(_ values: [T]) -> Int {
            64 + values.capacity * MemoryLayout<T>.stride
        }
        func stringBytes(_ value: String) -> Int {
            32 + max(value.utf8.count, value.utf16.count * 2)
        }
        func indexBytes(_ index: MediaIndex) -> Int {
            var bytes = arrayBytes(index.embeddings)
                + arrayBytes(index.dates) + arrayBytes(index.latitudes)
                + arrayBytes(index.longitudes) + arrayBytes(index.framePositions)
            for values in [index.ids, index.localIdentifiers, index.sourceIds] {
                bytes += arrayBytes(values)
                for value in values { bytes += stringBytes(value) }
            }
            for values in [index.filePaths, index.ocrTexts, index.sceneLabels,
                           index.locationCities, index.locationStates,
                           index.locationCountries, index.locationNames] {
                bytes += arrayBytes(values)
                for value in values {
                    if let value { bytes += stringBytes(value) }
                }
            }
            return bytes
        }
        return 256 + indexBytes(page.photos) + indexBytes(page.videos)
    }
}

enum SearchIndexReloadPhase: Equatable, Sendable {
    case idle
    case loadingResidentData
    case buildingAccelerators
}

struct SearchIndexMemoryState: Equatable, Sendable {
    let reloadPhase: SearchIndexReloadPhase
    let residentMediaCount: Int
    let ownsPhotoAccelerator: Bool
    let ownsVideoAccelerator: Bool
}

final class SearchEngine: Sendable {
    private let indexSnapshot: OSAllocatedUnfairLock<SearchIndexSnapshot>
    private let indexLoadCoordinator = IndexLoadCoordinator()
    private let indexAccessCoordinator = SearchIndexAccessCoordinator()
    private let tailPageCache = SearchTailPageCache()
    private let indexReloadPhase = OSAllocatedUnfairLock(
        initialState: SearchIndexReloadPhase.idle
    )
    private let hasRecordedFirstQuery = OSAllocatedUnfairLock(initialState: false)
    private let locationMetadataOverlay = OSAllocatedUnfairLock(
        initialState: [String: LocationStrings]()
    )

    private let embeddingDim = EmbeddingConfig.dimensions
    private let minimumScoreThreshold = SearchConfig.minimumScoreThreshold
    private let residentMediaLimit: Int

    static let maxRecommendedPhotos = IndexingConfig.largeLibraryThreshold
    /// The UI progressively reveals results, but retaining every match can
    /// exhaust memory for large Pro libraries. Keep a generous, deterministic
    /// window instead.
    static let maximumRetainedResults = SearchResultRanking.maximumRetainedResults

    private let injectedPhotoSimilaritySearch: SimilaritySearching?
    private let injectedVideoSimilaritySearch: SimilaritySearching?

    private let textEncoder: OSAllocatedUnfairLock<(any TextEmbeddingEncoding)?>
    private let database: DatabaseProtocol
    private let locationGazetteer: OfflineLocationGazetteer
    init(
        textEncoder: TextEmbeddingEncoding? = nil,
        database: DatabaseProtocol = AppDatabase.shared,
        photoSimilaritySearch: SimilaritySearching? = nil,
        videoSimilaritySearch: SimilaritySearching? = nil,
        residentMediaLimit: Int = SearchIndexLimits.residentMediaItems,
        locationGazetteer: OfflineLocationGazetteer = .shared
    ) {
        self.textEncoder = OSAllocatedUnfairLock(initialState: textEncoder)
        self.database = database
        self.locationGazetteer = locationGazetteer
        self.injectedPhotoSimilaritySearch = photoSimilaritySearch
        self.injectedVideoSimilaritySearch = videoSimilaritySearch
        self.residentMediaLimit = max(
            1,
            min(residentMediaLimit, SearchIndexLimits.maximumResidentMediaItems)
        )
        self.indexSnapshot = OSAllocatedUnfairLock(
            initialState: SearchIndexSnapshot(
                photoSimilaritySearch: photoSimilaritySearch,
                videoSimilaritySearch: videoSimilaritySearch
            )
        )
    }

    func installTextEncoder(_ encoder: TextEmbeddingEncoding) {
        textEncoder.withLock { $0 = encoder }
    }

    private func currentTextEncoder() throws -> TextEmbeddingEncoding {
        guard let encoder = textEncoder.withLock({ $0 }) else {
            throw SearchEngineError.textEncoderUnavailable
        }
        return encoder
    }

    func loadIndex() throws {
        let generation = indexSnapshot.withLock {
            $0.isMemoryPressureSuspended ? nil : $0.memoryPressureGeneration
        }
        guard let generation else { return }
        try indexLoadCoordinator.run(generation: generation) { [self] in
            guard isSearchGenerationActive(generation) else { return }
            try loadIndexOnce(generation: generation)
        }
    }

    private func loadIndexOnce(generation loadGeneration: UInt) throws {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        indexReloadPhase.withLock { $0 = .loadingResidentData }
        defer { indexReloadPhase.withLock { $0 = .idle } }

        try Task.checkCancellation()
        let residentPage = try database.loadSearchMediaPage(after: nil, limit: residentMediaLimit)
        let photoIndex = residentPage.photos
        let videoIndex = residentPage.videos
        try Task.checkCancellation()
        guard isSearchGenerationActive(loadGeneration) else { return }
        guard photoIndex.kind == .photo, videoIndex.kind == .videoFrame else {
            logger.error("[SearchEngine] Persisted index has unexpected media kinds")
            throw SearchEngineError.corruptedIndex
        }

        indexReloadPhase.withLock { $0 = .buildingAccelerators }
        try Task.checkCancellation()

        let newGPUSearch: SimilaritySearching?
        let newGPUVideoSearch: SimilaritySearching?
        #if targetEnvironment(simulator)
        newGPUSearch = injectedPhotoSimilaritySearch
        newGPUVideoSearch = injectedVideoSimilaritySearch
        #else
        // Fresh production scorers keep the serving snapshot immutable while
        // its replacement is constructed.
        newGPUSearch = injectedPhotoSimilaritySearch ?? GPUSimilaritySearch()
        newGPUVideoSearch = injectedVideoSimilaritySearch ?? GPUSimilaritySearch()
        #endif
        try Task.checkCancellation()
        guard isSearchGenerationActive(loadGeneration) else { return }
        newGPUSearch?.buildIndex(embeddings: photoIndex.embeddings, count: photoIndex.count)
        try Task.checkCancellation()
        if videoIndex.count > 0 {
            guard isSearchGenerationActive(loadGeneration) else { return }
            newGPUVideoSearch?.buildIndex(embeddings: videoIndex.embeddings, count: videoIndex.count)
        }
        try Task.checkCancellation()

        let replacement = SearchIndexSnapshot(
            photos: photoIndex,
            videos: videoIndex,
            uniqueVideoCount: videoIndex.uniqueIDCount,
            persistedPhotoCount: residentPage.totalPhotoCount,
            persistedVideoCount: residentPage.totalVideoCount,
            nextPageCursor: residentPage.nextCursor,
            photoSimilaritySearch: newGPUSearch,
            videoSimilaritySearch: videoIndex.count == 0 ? nil : newGPUVideoSearch,
            memoryPressureGeneration: loadGeneration
        )
        try Task.checkCancellation()
        guard isSearchGenerationActive(loadGeneration) else { return }

        // The expensive database and accelerator work happens while searches
        // continue using the previous immutable snapshot. Only the final swap
        // is exclusive, so cancellation or failure leaves the old generation
        // fully accelerated and usable.
        try indexAccessCoordinator.withExclusiveReload {
            try Task.checkCancellation()
            indexSnapshot.withLock { snapshot in
                guard !snapshot.isMemoryPressureSuspended,
                      snapshot.memoryPressureGeneration == loadGeneration else { return }
                snapshot = replacement
                tailPageCache.invalidate(generation: loadGeneration)
            }
        }

        let count = photoIndex.count
        let videoFrameCount = videoIndex.count
        let memoryMB = (count + videoFrameCount) * embeddingDim * MemoryLayout<Float16>.size / 1_048_576
        #if DEBUG
        if count > Self.maxRecommendedPhotos {
            logger.warning("Large library: \(count) photos, ~\(memoryMB)MB.")
        }
        #endif

        #if DEBUG
        let vFrameCount = videoFrameCount
        logger.info("[SearchEngine] Index loaded: \(count) photos, \(vFrameCount) video frames, ~\(memoryMB)MB in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart))s")
        #endif
    }

    var estimatedMemoryUsage: Int {
        indexSnapshot.withLock {
            ($0.photos.count + $0.videos.count) * embeddingDim * MemoryLayout<Float16>.size
        }
    }

    var cachedTailPageBytes: Int { tailPageCache.retainedBytes }

    var indexMemoryState: SearchIndexMemoryState {
        let phase = indexReloadPhase.withLock { $0 }
        return indexSnapshot.withLock {
            SearchIndexMemoryState(
                reloadPhase: phase,
                residentMediaCount: $0.photos.count + $0.videos.count,
                ownsPhotoAccelerator: $0.photoSimilaritySearch != nil,
                ownsVideoAccelerator: $0.videoSimilaritySearch != nil
            )
        }
    }

    var isLargeLibrary: Bool {
        indexSnapshot.withLock {
            ($0.persistedPhotoCount + $0.persistedVideoCount) > Self.maxRecommendedPhotos
        }
    }

    var indexSize: Int {
        indexSnapshot.withLock { $0.persistedPhotoCount }
    }

    var videoSize: Int {
        indexSnapshot.withLock { $0.persistedVideoCount }
    }

    var totalSize: Int {
        indexSnapshot.withLock { $0.persistedPhotoCount + $0.persistedVideoCount }
    }

    var residentSize: Int {
        indexSnapshot.withLock { $0.photos.count + $0.uniqueVideoCount }
    }

    var isIndexLoaded: Bool {
        indexSnapshot.withLock { $0.persistedPhotoCount + $0.persistedVideoCount > 0 }
    }

    var isMemoryPressureSuspended: Bool {
        indexSnapshot.withLock { $0.isMemoryPressureSuspended }
    }

    /// Makes newly reverse-geocoded labels searchable immediately without
    /// rebuilding embeddings or GPU accelerators. The database remains the
    /// source of truth; this overlay only bridges the current process lifetime.
    func applyLocationUpdates(_ updates: [LocationBackfillUpdate]) {
        guard !updates.isEmpty else { return }
        locationMetadataOverlay.withLock { overlay in
            for update in updates {
                overlay[update.localIdentifier] = update.location
            }
        }
    }

    /// Invalidates serving data and any work started before a storage change.
    /// Memory-pressure suspension remains in force until explicitly resumed.
    func dropIndex() {
        indexSnapshot.withLock {
            let suspended = $0.isMemoryPressureSuspended
            let generation = $0.memoryPressureGeneration &+ 1
            $0 = SearchIndexSnapshot(
                isMemoryPressureSuspended: suspended,
                memoryPressureGeneration: generation
            )
            tailPageCache.invalidate(generation: generation)
        }
        locationMetadataOverlay.withLock { $0.removeAll(keepingCapacity: false) }
        #if DEBUG
        logger.info("[SearchEngine] Index invalidated")
        #endif
    }

    func suspendForMemoryPressure() {
        indexSnapshot.withLock {
            $0 = SearchIndexSnapshot(
                isMemoryPressureSuspended: true,
                memoryPressureGeneration: $0.memoryPressureGeneration &+ 1
            )
            tailPageCache.invalidate(generation: $0.memoryPressureGeneration)
        }
        locationMetadataOverlay.withLock { $0.removeAll(keepingCapacity: false) }
        #if DEBUG
        logger.info("[SearchEngine] Index suspended due to memory pressure")
        #endif
    }

    func resumeAfterMemoryPressure() {
        indexSnapshot.withLock { $0.isMemoryPressureSuspended = false }
    }

    // MARK: - Search

    func search(
        query: String,
        featurePolicy: SearchFeaturePolicy = .basic,
        recordsUserTiming: Bool = true
    ) async throws -> SearchResponse {
        let searchStartedAt = CFAbsoluteTimeGetCurrent()
        let totalMetric: String? = recordsUserTiming
            ? hasRecordedFirstQuery.withLock { hasRecorded in
                if hasRecorded { return PerformancePhase.warmQuery }
                hasRecorded = true
                return PerformancePhase.firstQuery
            }
            : nil
        defer {
            if let totalMetric {
                PerformanceMetrics.shared.record(
                    totalMetric,
                    durationSeconds: CFAbsoluteTimeGetCurrent() - searchStartedAt
                )
            }
        }
        let memoryPressureGeneration = indexSnapshot.withLock { $0.memoryPressureGeneration }
        guard isSearchGenerationActive(memoryPressureGeneration) else {
            return SearchResponse(results: [], fallbackResults: [], filtersApplied: nil)
        }
        if !isIndexLoaded {
            let loadTask = Task.detached(priority: .userInitiated) { [self] in
                try loadIndex()
            }
            try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
        }

        #if DEBUG
        logger.info("[SearchEngine] Search started")
        #endif

        let parsingStartedAt = CFAbsoluteTimeGetCurrent()
        let hints = await QueryParser.parse(query: query, featurePolicy: featurePolicy)
        let restrictionHints = featurePolicy.allowsAdvancedQueryFeatures
            ? hints
            : QueryParserFallback.parse(query: query)
        let restrictionSummary = featurePolicy.restrictionSummary(for: restrictionHints)
        if recordsUserTiming {
            PerformanceMetrics.shared.record(
                PerformancePhase.queryParsing,
                durationSeconds: CFAbsoluteTimeGetCurrent() - parsingStartedAt
            )
        }
        try checkSearchGeneration(memoryPressureGeneration)
        let effectiveHints = scoringHints(featurePolicy.enforcing(hints))
        var precomputedEmbeddings: [String: [Float]] = [:]
        if hasSearchIntent(hints)
            && hasSearchIntent(effectiveHints)
            && !isPureLocationQuery(effectiveHints) {
            let encodingStartedAt = CFAbsoluteTimeGetCurrent()
            defer {
                if recordsUserTiming {
                    PerformanceMetrics.shared.record(
                        PerformancePhase.textEncoding,
                        durationSeconds: CFAbsoluteTimeGetCurrent() - encodingStartedAt
                    )
                }
            }
            var texts = [effectiveHints.textQuery]
            texts.append(contentsOf: effectiveHints.negativeTerms)
            for text in texts where precomputedEmbeddings[text] == nil {
                try checkSearchGeneration(memoryPressureGeneration)
                let embedding = try await currentTextEncoder().encodeCancellable(text: text)
                try checkSearchGeneration(memoryPressureGeneration)
                guard embedding.count == embeddingDim else {
                    throw SearchEngineError.invalidEmbedding
                }
                precomputedEmbeddings[text] = embedding
            }
        }

        let response = try hybridSearch(
            hints: hints,
            featurePolicy: featurePolicy,
            memoryPressureGeneration: memoryPressureGeneration,
            precomputedEmbeddings: precomputedEmbeddings,
            recordsPerformanceMetrics: recordsUserTiming,
            restrictionSummary: restrictionSummary
        )
        try checkSearchGeneration(memoryPressureGeneration)

        #if DEBUG
        logger.info("[SearchEngine] Search completed in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - searchStartedAt))s, main=\(response.results.count), fallback=\(response.fallbackResults.count), filters=\(response.filtersApplied != nil)")
        #endif

        return response
    }

    /// A pure-filter query has a real date/location constraint but no visual
    /// subject, or is a bare place name backfilled by the fallback parser.
    /// Exclusion-only and empty queries are not filters and must never enter
    /// the unscored path that returns every candidate.
    private func isPureLocationQuery(_ hints: QueryHints) -> Bool {
        hints.negativeTerms.isEmpty && hasPureFilterIntent(hints)
    }

    private func hasPureFilterIntent(_ hints: QueryHints) -> Bool {
        if !hints.hasVisualQuery {
            return hints.locationHint != nil || hints.dateRange != nil
        }
        if let loc = hints.locationHint?.lowercased(), hints.textQuery == loc {
            return true
        }
        return false
    }

    private func scoringHints(_ hints: QueryHints) -> QueryHints {
        guard !hints.negativeTerms.isEmpty, hasPureFilterIntent(hints) else { return hints }
        var scoring = hints
        scoring.textQuery = "a photo"
        scoring.hasVisualQuery = false
        return scoring
    }

    private func hasSearchIntent(_ hints: QueryHints) -> Bool {
        hints.hasVisualQuery
            || hints.dateRange != nil
            || hints.locationHint != nil
            || hints.seasonHint != nil
            || !hints.negativeTerms.isEmpty
            || hints.timeOfDayHours != nil
    }

    func hybridSearch(
        hints: QueryHints,
        featurePolicy: SearchFeaturePolicy = .basic
    ) throws -> SearchResponse {
        let memoryPressureGeneration = indexSnapshot.withLock { $0.memoryPressureGeneration }
        return try hybridSearch(
            hints: hints,
            featurePolicy: featurePolicy,
            memoryPressureGeneration: memoryPressureGeneration,
            precomputedEmbeddings: [:],
            recordsPerformanceMetrics: false,
            restrictionSummary: featurePolicy.restrictionSummary(for: hints)
        )
    }

    private func hybridSearch(
        hints: QueryHints,
        featurePolicy: SearchFeaturePolicy,
        memoryPressureGeneration: UInt,
        precomputedEmbeddings: [String: [Float]],
        recordsPerformanceMetrics: Bool,
        restrictionSummary: SearchRestrictionSummary?
    ) throws -> SearchResponse {
        guard hasSearchIntent(hints) else {
            return SearchResponse(
                results: [],
                fallbackResults: [],
                filtersApplied: nil,
                restrictionSummary: restrictionSummary
            )
        }
        return try indexAccessCoordinator.withSearch {
            try checkSearchGeneration(memoryPressureGeneration)
            let response = try performHybridSearch(
                hints: scoringHints(featurePolicy.enforcing(hints)),
                precomputedEmbeddings: precomputedEmbeddings,
                recordsPerformanceMetrics: recordsPerformanceMetrics
            )
            try checkSearchGeneration(memoryPressureGeneration)
            let allowedResponse = featurePolicy.enforcing(response)
            return SearchResponse(
                results: allowedResponse.results,
                fallbackResults: allowedResponse.fallbackResults,
                filtersApplied: allowedResponse.filtersApplied,
                restrictionSummary: restrictionSummary
            )
        }
    }

    private func isSearchGenerationActive(_ generation: UInt) -> Bool {
        indexSnapshot.withLock {
            !$0.isMemoryPressureSuspended && $0.memoryPressureGeneration == generation
        }
    }

    private func checkSearchGeneration(_ generation: UInt) throws {
        try Task.checkCancellation()
        guard isSearchGenerationActive(generation) else {
            throw CancellationError()
        }
    }

    private func performHybridSearch(
        hints: QueryHints,
        precomputedEmbeddings: [String: [Float]],
        recordsPerformanceMetrics: Bool
    ) throws -> SearchResponse {
        try SearchCancellation.checkNow()
        guard hasSearchIntent(hints) else {
            return SearchResponse(results: [], fallbackResults: [], filtersApplied: nil)
        }
        let snapshot = indexSnapshot.withLock { $0 }
        if snapshot.nextPageCursor != nil {
            return try performWholeLibrarySearch(
                hints: hints,
                residentSnapshot: snapshot,
                precomputedEmbeddings: precomputedEmbeddings,
                recordsPerformanceMetrics: recordsPerformanceMetrics
            )
        }
        let residentStartedAt = CFAbsoluteTimeGetCurrent()
        defer {
            if recordsPerformanceMetrics {
                PerformanceMetrics.shared.record(
                    PerformancePhase.residentScoring,
                    durationSeconds: CFAbsoluteTimeGetCurrent() - residentStartedAt
                )
            }
        }
        let photos = snapshot.photos
        let videos = snapshot.videos

        let photoGPU = snapshot.photoSimilaritySearch
        let videoGPU = snapshot.videoSimilaritySearch

        guard photos.count + videos.count > 0 else {
            return SearchResponse(results: [], fallbackResults: [], filtersApplied: nil)
        }

        // =====================================================================
        // PHASE 1: HARD FILTERS — build candidate mask before any CLIP scoring
        // =====================================================================

        let locationFilter = makeLocationFilter(hints: hints)
        let photoCandidateMask = try candidateMask(
            for: photos,
            hints: hints,
            locationFilter: locationFilter
        )
        let videoCandidateMask = try candidateMask(
            for: videos,
            hints: hints,
            locationFilter: locationFilter
        )
        let candidateCount = try trueCount(in: photoCandidateMask)
        let videoCandidateCount = try trueCount(in: videoCandidateMask)

        #if DEBUG
        logger.info("[SearchEngine] Filter: \(candidateCount)/\(photos.count) photos and \(videoCandidateCount)/\(videos.count) video frames passed hard filters")
        #endif

        // =====================================================================
        // PHASE 2: BRANCH ON QUERY INTENT
        // =====================================================================

        let filtersActive = hints.dateRange != nil || hints.locationHint != nil

        // Pure date/location constraint (including an auto-filled bare place
        // name): skip CLIP ranking and return every matching media item sorted
        // by date, instead of ranking against a meaningless filter embedding.
        if isPureLocationQuery(hints) {
            let locationResponse = try SearchResultRanking.locationOnlyResults(media: [
                (index: photos, candidateMask: photoCandidateMask),
                (index: videos, candidateMask: videoCandidateMask),
            ])
            return SearchResponse(
                results: locationResponse.results,
                fallbackResults: [],
                filtersApplied: FilterSummary(
                    dateDescription: hints.dateRange.map { formatDateRange($0) },
                    locationDescription: hints.locationHint,
                    visualQuery: ""
                )
            )
        }

        // Empty candidate set with active filters. A near-miss outside a hard
        // place or date constraint is not a valid fallback; the relaxation
        // controls let the user explicitly broaden the search instead.
        if candidateCount == 0 && videoCandidateCount == 0 && filtersActive {
            let summary = FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: [], fallbackResults: [], filtersApplied: summary)
        }

        // =====================================================================
        // PHASE 3: CLIP SCORING — score all, then mask out non-candidates
        // =====================================================================

        try SearchCancellation.checkNow()
        let queryEmbedding = try encodeQuery(
            text: hints.textQuery,
            precomputedEmbeddings: precomputedEmbeddings
        )
        var negativeEmbeddings: [[Float]] = []
        negativeEmbeddings.reserveCapacity(hints.negativeTerms.count)
        for negativeTerm in hints.negativeTerms {
            try SearchCancellation.checkNow()
            negativeEmbeddings.append(try encodeQuery(
                text: negativeTerm,
                precomputedEmbeddings: precomputedEmbeddings
            ))
        }

        let photoScoring = try scoreMedia(
            photos,
            candidateMask: photoCandidateMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: negativeEmbeddings,
            hints: hints,
            gpuSearch: photoGPU
        )
        let videoScoring = try scoreMedia(
            videos,
            candidateMask: videoCandidateMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: negativeEmbeddings,
            hints: hints,
            gpuSearch: videoGPU
        )
        let scores = photoScoring.scores
        let videoScores = videoScoring.scores
        try SearchCancellation.checkNow()

        #if DEBUG
        // Raw CLIP score distribution BEFORE any boosts
        let rawCandidateScores = (0..<photos.count)
            .filter { photoCandidateMask[$0] }
            .map { photoScoring.rawScores[$0] }
        if !rawCandidateScores.isEmpty {
            let sortedRaw = rawCandidateScores.sorted(by: >)
            let rawAbove020 = rawCandidateScores.filter { $0 >= 0.20 }.count
            let rawAbove015 = rawCandidateScores.filter { $0 >= 0.15 }.count
            let rawAbove012 = rawCandidateScores.filter { $0 >= 0.12 }.count
            let rawAbove010 = rawCandidateScores.filter { $0 >= 0.10 }.count
            let rawMean = rawCandidateScores.reduce(0, +) / Float(rawCandidateScores.count)
            logger.info("[RawCLIP] candidates=\(rawCandidateScores.count) top10=[\(sortedRaw.prefix(10).map { String(format: "%.4f", $0) }.joined(separator: ", "))] mean=\(String(format: "%.4f", rawMean)) >=0.20:\(rawAbove020) >=0.15:\(rawAbove015) >=0.12:\(rawAbove012) >=0.10:\(rawAbove010)")
        }
        #endif

        // =====================================================================
        // PHASE 4: SOFT BOOSTS — applied by scoreMedia for both media kinds
        // =====================================================================

        #if DEBUG
        // Score distribution AFTER boosts
        let candidateScores = (0..<photos.count).filter { photoCandidateMask[$0] }.map { scores[$0] }
        if !candidateScores.isEmpty {
            let sortedCS = candidateScores.sorted(by: >)
            let above020 = candidateScores.filter { $0 >= 0.20 }.count
            let above015 = candidateScores.filter { $0 >= 0.15 }.count
            let above012 = candidateScores.filter { $0 >= 0.12 }.count
            let above010 = candidateScores.filter { $0 >= 0.10 }.count
            let mean = candidateScores.reduce(0, +) / Float(candidateScores.count)
            logger.info("[BoostedCLIP] top10=[\(sortedCS.prefix(10).map { String(format: "%.4f", $0) }.joined(separator: ", "))] mean=\(String(format: "%.4f", mean)) >=0.20:\(above020) >=0.15:\(above015) >=0.12:\(above012) >=0.10:\(above010)")

            // Show boost breakdown for top 20 candidates
            let topIndices = (0..<photos.count)
                .filter { photoCandidateMask[$0] }
                .sorted { scores[$0] > scores[$1] }
                .prefix(20)
            for (rank, i) in topIndices.enumerated() {
                let raw = photoScoring.rawScores[i]
                let boosted = scores[i]
                let boostTotal = boosted - raw
                logger.info("[BoostDetail #\(rank+1)] raw=\(String(format: "%.4f", raw)) boosted=\(String(format: "%.4f", boosted)) boost=\(String(format: "%+.4f", boostTotal))")
            }
        }
        if !videoScoring.rawScores.isEmpty {
            let sortedVS = videoScores.enumerated().sorted { $0.element > $1.element }
            let vAbove020 = videoScores.filter { $0 >= 0.20 }.count
            let vAbove015 = videoScores.filter { $0 >= 0.15 }.count
            let vAbove010 = videoScores.filter { $0 >= 0.10 }.count
            let vMean = videoScores.reduce(0, +) / Float(videos.count)
            logger.info("[ScoreDist] Videos: top5=[\(sortedVS.prefix(5).map { String(format: "%.3f", $0.element) }.joined(separator: ", "))] mean=\(String(format: "%.4f", vMean)) >=0.20:\(vAbove020) >=0.15:\(vAbove015) >=0.10:\(vAbove010) total:\(videos.count)")
        }
        #endif

        // =====================================================================
        // PHASE 6: RANK AND RETURN
        // =====================================================================

        #if DEBUG
        let topScoredRows = try BoundedTopK.rows(
            count: scores.count,
            limit: SearchConfig.topK,
            isPreferred: { lhs, rhs in
                if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
                return lhs < rhs
            },
            cancellationCheck: SearchCancellation.check
        )
        #endif

        // Text matches qualify independently of visual scores. Keep both in
        // the bounded result set; the UI displays each photo in one section.
        let photoResults = try SearchResultRanking.results(
            for: photos,
            scores: scores,
            threshold: minimumScoreThreshold,
            textMatches: photoScoring.textMatches
        )
        let videoResults = try SearchResultRanking.results(
            for: videos,
            scores: videoScores,
            threshold: minimumScoreThreshold
        )
        let makeVideoNearMissResults: () throws -> [SearchResult] = {
            var maskedScores = videoScores
            for row in 0..<maskedScores.count {
                try SearchCancellation.check(row)
                if !videoCandidateMask[row] { maskedScores[row] = -.infinity }
            }
            return try SearchResultRanking.results(
                for: videos,
                scores: maskedScores,
                threshold: Float.leastNonzeroMagnitude
            )
        }

        let allResults = try BoundedTopK.select(
            from: photoResults + videoResults,
            limit: Self.maximumRetainedResults,
            isPreferred: SearchResultRanking.isPreferred,
            cancellationCheck: SearchCancellation.check
        )

        #if DEBUG
        let photoResultCount = photoResults.count
        let videoResultCount = videoResults.count
        let thresholdVal = self.minimumScoreThreshold
        let textResultCount = allResults.filter(\.isTextMatch).count
        logger.info("[Results] \(photoResultCount) photos + \(videoResultCount) videos = \(allResults.count) total (visual threshold=\(String(format: "%.2f", thresholdVal)), text matches=\(textResultCount))")

        // Top 10 results with type and score
        for (rank, r) in allResults.prefix(10).enumerated() {
            let type = r.isVideo ? "VIDEO" : "PHOTO"
            logger.info("[Result #\(rank + 1)] \(type) score=\(String(format: "%.4f", r.score))")
        }

        // Score range of returned results
        if !allResults.isEmpty {
            let resultScores = allResults.map { $0.score }
            logger.info("[Results] Score range: \(String(format: "%.4f", resultScores.min()!)) - \(String(format: "%.4f", resultScores.max()!)) (spread=\(String(format: "%.4f", resultScores.max()! - resultScores.min()!)))")
        }

        // Near-miss diagnostics when results are empty or sparse
        if allResults.count < 5 {
            let nearMissCount = min(5, topScoredRows.count)
            logger.info("[NearMiss] Top \(nearMissCount) photo scores (below threshold or filtered):")
            for index in topScoredRows.prefix(nearMissCount) {
                let score = scores[index]
                let passed = photoCandidateMask[index]
                logger.info("[NearMiss] score=\(String(format: "%.4f", score)) passedFilter=\(passed)")
            }
            if videos.count > 0 {
                let topVideo = videoResults.sorted { $0.score > $1.score }.prefix(3)
                if topVideo.isEmpty {
                    logger.info("[NearMiss] No video frames passed threshold")
                }
                for result in topVideo {
                    logger.info("[NearMiss] VIDEO score=\(String(format: "%.4f", result.score)) frame=\(String(format: "%.2f", result.bestFramePosition ?? 0))")
                }
            }
        }
        #endif

        let appliedSummary: FilterSummary? = filtersActive
            ? FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            : nil

        // When no results pass the threshold, show the top near-miss results as
        // fallback so the user sees "closest matches" instead of an empty screen.
        if allResults.isEmpty && hints.hasVisualQuery {
            let nearMissRows = try BoundedTopK.rows(
                count: photos.count,
                limit: SearchConfig.topK,
                includes: { scores[$0] > 0 && photoCandidateMask[$0] },
                isPreferred: { lhs, rhs in
                    if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
                    return lhs < rhs
                },
                cancellationCheck: SearchCancellation.check
            )
            let photoNearMissResults = nearMissRows.map { index in
                SearchResult(id: photos.ids[index], score: scores[index],
                             localIdentifier: photos.localIdentifiers[index],
                             creationDate: photos.dates[index], isVideo: false,
                             bestFramePosition: nil,
                             sourceId: photos.sourceIds[index],
                             filePath: photos.filePaths[index])
            }
            let nearMissResults = try BoundedTopK.select(
                from: photoNearMissResults + makeVideoNearMissResults(),
                limit: SearchConfig.topK,
                isPreferred: SearchResultRanking.isPreferred,
                cancellationCheck: SearchCancellation.check
            )
            let fallbackSummary = FilterSummary(
                dateDescription: appliedSummary?.dateDescription,
                locationDescription: appliedSummary?.locationDescription,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: [], fallbackResults: nearMissResults, filtersApplied: fallbackSummary)
        }

        return SearchResponse(results: allResults, fallbackResults: [], filtersApplied: appliedSummary)
    }

    private struct WholeLibrarySearchPlan {
        let hints: QueryHints
        let locationFilter: LocationSearchFilter?
        let queryEmbedding: [Float]?
        let negativeEmbeddings: [[Float]]
    }

    private struct LocationSearchFilter {
        let metadataMatcher: LocationMatcher.Matcher
        let coordinateMatcher: OfflineLocationGazetteer.Matcher?
        let metadataOverlay: [String: LocationStrings]

        func matches(
            localIdentifier: String,
            latitude: Double?,
            longitude: Double?,
            city: String?,
            state: String?,
            country: String?,
            name: String?
        ) -> Bool {
            let overlay = metadataOverlay[localIdentifier]
            return metadataMatcher(
                overlay?.city ?? city,
                overlay?.state ?? state,
                overlay?.country ?? country,
                overlay?.name ?? name
            ) || coordinateMatcher?(latitude, longitude) == true
        }
    }

    private struct WholeLibrarySearchPage {
        let photos: MediaIndex
        let videos: MediaIndex
        let photoGPU: SimilaritySearching?
        let videoGPU: SimilaritySearching?
    }

    private struct WholeLibrarySearchAccumulator {
        var photoCandidates: [SearchResult] = []
        var videoCandidates: [SearchResult] = []
        var locationCandidates: [SearchResult] = []
        var photoCandidateCount = 0
        var videoCandidateFrameCount = 0

        mutating func retainPhoto(_ result: SearchResult) {
            BoundedTopK.insert(
                result,
                into: &photoCandidates,
                limit: SearchEngine.maximumRetainedResults,
                isPreferred: SearchResultRanking.isPreferred
            )
        }

        mutating func retainVideo(_ result: SearchResult) {
            BoundedTopK.insert(
                result,
                into: &videoCandidates,
                limit: SearchEngine.maximumRetainedResults,
                isPreferred: SearchResultRanking.isPreferred
            )
        }

        mutating func retainLocation(_ result: SearchResult) {
            BoundedTopK.insert(
                result,
                into: &locationCandidates,
                limit: SearchEngine.maximumRetainedResults,
                isPreferred: SearchResultRanking.isPreferredLocation
            )
        }

    }

    /// Searches the persisted library a bounded page at a time. Threshold and
    /// sparse-fallback decisions are deferred until every page has contributed,
    /// so page boundaries cannot change global ranking semantics.
    private func performWholeLibrarySearch(
        hints: QueryHints,
        residentSnapshot: SearchIndexSnapshot,
        precomputedEmbeddings: [String: [Float]],
        recordsPerformanceMetrics: Bool
    ) throws -> SearchResponse {
        var accumulator = WholeLibrarySearchAccumulator()
        let locationFilter = makeLocationFilter(hints: hints)
        let queryEmbedding = isPureLocationQuery(hints)
            ? nil
            : try encodeQuery(
                text: hints.textQuery,
                precomputedEmbeddings: precomputedEmbeddings
            )
        var negativeEmbeddings: [[Float]] = []
        if queryEmbedding != nil {
            for negativeTerm in hints.negativeTerms {
                try SearchCancellation.checkNow()
                negativeEmbeddings.append(try encodeQuery(
                    text: negativeTerm,
                    precomputedEmbeddings: precomputedEmbeddings
                ))
            }
        }
        let plan = WholeLibrarySearchPlan(
            hints: hints,
            locationFilter: locationFilter,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: negativeEmbeddings
        )

        let residentStartedAt = CFAbsoluteTimeGetCurrent()
        try accumulateSearchPage(
            WholeLibrarySearchPage(
                photos: residentSnapshot.photos,
                videos: residentSnapshot.videos,
                photoGPU: residentSnapshot.photoSimilaritySearch,
                videoGPU: residentSnapshot.videoSimilaritySearch
            ),
            plan: plan,
            accumulator: &accumulator
        )
        if recordsPerformanceMetrics {
            PerformanceMetrics.shared.record(
                PerformancePhase.residentScoring,
                durationSeconds: CFAbsoluteTimeGetCurrent() - residentStartedAt
            )
        }

        var cursor = residentSnapshot.nextPageCursor
        var previousCursor: SearchMediaPageCursor?
        var tailLoadingDuration: TimeInterval = 0
        var tailScoringDuration: TimeInterval = 0
        while let currentCursor = cursor {
            try checkSearchGeneration(residentSnapshot.memoryPressureGeneration)
            guard currentCursor != previousCursor else {
                throw SearchEngineError.corruptedIndex
            }
            let loadStartedAt = CFAbsoluteTimeGetCurrent()
            let page = try loadTailPage(
                after: currentCursor,
                generation: residentSnapshot.memoryPressureGeneration
            )
            tailLoadingDuration += CFAbsoluteTimeGetCurrent() - loadStartedAt
            guard page.mediaCount > 0 else {
                throw SearchEngineError.corruptedIndex
            }
            let scoringStartedAt = CFAbsoluteTimeGetCurrent()
            try accumulateSearchPage(
                WholeLibrarySearchPage(
                    photos: page.photos,
                    videos: page.videos,
                    photoGPU: nil,
                    videoGPU: nil
                ),
                plan: plan,
                accumulator: &accumulator
            )
            tailScoringDuration += CFAbsoluteTimeGetCurrent() - scoringStartedAt
            previousCursor = currentCursor
            cursor = page.nextCursor
        }

        if recordsPerformanceMetrics {
            PerformanceMetrics.shared.record(
                PerformancePhase.tailPageLoading,
                durationSeconds: tailLoadingDuration
            )
            PerformanceMetrics.shared.record(
                PerformancePhase.tailPageScoring,
                durationSeconds: tailScoringDuration
            )
        }

        return try finalizeWholeLibrarySearch(accumulator, hints: hints)
    }

    private func loadTailPage(
        after cursor: SearchMediaPageCursor,
        generation: UInt
    ) throws -> SearchMediaPage {
        try checkSearchGeneration(generation)
        let page: SearchMediaPage
        if let cached = tailPageCache.page(after: cursor, generation: generation) {
            page = cached
        } else {
            page = try database.loadSearchMediaPage(
                after: cursor,
                limit: SearchIndexLimits.databasePageMediaItems
            )
            try checkSearchGeneration(generation)
            tailPageCache.insert(page, after: cursor, generation: generation)
        }
        try checkSearchGeneration(generation)
        return page
    }

    private func accumulateSearchPage(
        _ page: WholeLibrarySearchPage,
        plan: WholeLibrarySearchPlan,
        accumulator: inout WholeLibrarySearchAccumulator
    ) throws {
        let hints = plan.hints
        let photoMask = try candidateMask(
            for: page.photos,
            hints: hints,
            locationFilter: plan.locationFilter
        )
        let videoMask = try candidateMask(
            for: page.videos,
            hints: hints,
            locationFilter: plan.locationFilter
        )
        accumulator.photoCandidateCount += try trueCount(in: photoMask)
        accumulator.videoCandidateFrameCount += try trueCount(in: videoMask)

        if isPureLocationQuery(hints) {
            let response = try SearchResultRanking.locationOnlyResults(media: [
                (index: page.photos, candidateMask: photoMask),
                (index: page.videos, candidateMask: videoMask),
            ])
            for result in response.results { accumulator.retainLocation(result) }
            return
        }

        guard let queryEmbedding = plan.queryEmbedding else { return }
        let photoScoring = try scoreMedia(
            page.photos,
            candidateMask: photoMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: plan.negativeEmbeddings,
            hints: hints,
            gpuSearch: page.photoGPU
        )
        let videoScoring = try scoreMedia(
            page.videos,
            candidateMask: videoMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: plan.negativeEmbeddings,
            hints: hints,
            gpuSearch: page.videoGPU
        )

        for row in 0..<page.photos.count {
            try SearchCancellation.check(row)
            if photoMask[row] {
                accumulator.retainPhoto(try SearchResultRanking.result(
                    for: page.photos,
                    row: row,
                    score: photoScoring.scores[row],
                    isTextMatch: photoScoring.textMatches[row]
                ))
            }
        }

        var maskedVideoScores = videoScoring.scores
        for row in 0..<maskedVideoScores.count where !videoMask[row] {
            try SearchCancellation.check(row)
            maskedVideoScores[row] = -.infinity
        }
        let bestVideoFrames = try SearchResultRanking.results(
            for: page.videos,
            scores: maskedVideoScores,
            threshold: Float.leastNonzeroMagnitude
        )
        for result in bestVideoFrames { accumulator.retainVideo(result) }
    }

    private func finalizeWholeLibrarySearch(
        _ accumulator: WholeLibrarySearchAccumulator,
        hints: QueryHints
    ) throws -> SearchResponse {
        if isPureLocationQuery(hints) {
            return SearchResponse(
                results: BoundedTopK.sorted(
                    accumulator.locationCandidates,
                    isPreferred: SearchResultRanking.isPreferredLocation
                ),
                fallbackResults: [],
                filtersApplied: FilterSummary(
                    dateDescription: hints.dateRange.map { formatDateRange($0) },
                    locationDescription: hints.locationHint,
                    visualQuery: ""
                )
            )
        }

        let filtersActive = hints.dateRange != nil || hints.locationHint != nil
        let summary = FilterSummary(
            dateDescription: hints.dateRange.map { formatDateRange($0) },
            locationDescription: hints.locationHint,
            visualQuery: hints.textQuery
        )
        if filtersActive,
           accumulator.photoCandidateCount + accumulator.videoCandidateFrameCount == 0 {
            return SearchResponse(
                results: [],
                fallbackResults: [],
                filtersApplied: summary
            )
        }

        let sortedPhotos = BoundedTopK.sorted(
            accumulator.photoCandidates,
            isPreferred: SearchResultRanking.isPreferred
        )
        let sortedVideos = BoundedTopK.sorted(
            accumulator.videoCandidates,
            isPreferred: SearchResultRanking.isPreferred
        )
        let main = try BoundedTopK.select(
            from: sortedPhotos.filter { $0.isTextMatch || $0.score >= minimumScoreThreshold }
                + sortedVideos.filter { $0.score >= minimumScoreThreshold },
            limit: Self.maximumRetainedResults,
            isPreferred: SearchResultRanking.isPreferred,
            cancellationCheck: SearchCancellation.check
        )

        if main.isEmpty && hints.hasVisualQuery {
            let nearMiss = try BoundedTopK.select(
                from: sortedPhotos.filter { $0.score > 0 } + sortedVideos,
                limit: SearchConfig.topK,
                isPreferred: SearchResultRanking.isPreferred,
                cancellationCheck: SearchCancellation.check
            )
            return SearchResponse(results: [], fallbackResults: nearMiss, filtersApplied: summary)
        }

        return SearchResponse(
            results: main,
            fallbackResults: [],
            filtersApplied: filtersActive ? summary : nil
        )
    }

    // MARK: - Helper Methods

    // MARK: - Similar Photos

    func findSimilar(
        photoId: String,
        topK: Int = 50,
        featurePolicy: ProFeatureAccessPolicy = .free
    ) -> [SearchResult] {
        guard featurePolicy.allowsFindSimilar else { return [] }
        let generation = indexSnapshot.withLock { $0.memoryPressureGeneration }
        guard !Task.isCancelled else { return [] }
        return indexAccessCoordinator.withSearchUnlessCancelled {
            performFindSimilar(photoId: photoId, topK: topK, generation: generation)
        } ?? []
    }

    private func performFindSimilar(photoId: String, topK: Int, generation: UInt) -> [SearchResult] {
        guard !Task.isCancelled else { return [] }
        let snapshot = indexSnapshot.withLock { $0 }
        let sourceIndex = snapshot.photos.ids.firstIndex(of: photoId)
        let sourceMedia: MediaIndex
        let sourceRow: Int
        if let sourceIndex {
            sourceMedia = snapshot.photos
            sourceRow = sourceIndex
        } else {
            do {
                guard let loaded = try database.loadPhotoEmbedding(id: photoId),
                      loaded.count == 1 else { return [] }
                sourceMedia = loaded
                sourceRow = 0
            } catch {
                logger.error("[SearchEngine] Failed to load the Find Similar source: \(error.safeDiagnosticCode)")
                return []
            }
        }

        let offset = sourceRow * embeddingDim
        var sourceEmbedding = [Float](repeating: 0, count: embeddingDim)
        for j in 0..<embeddingDim {
            if j.isMultiple(of: SearchCancellation.checkInterval), Task.isCancelled { return [] }
            sourceEmbedding[j] = Float(sourceMedia.embeddings[offset + j])
        }
        var retained: [SearchResult] = []
        do {
            try retainSimilarResults(
                in: snapshot.photos,
                sourceID: photoId,
                sourceEmbedding: sourceEmbedding,
                gpuSearch: snapshot.photoSimilaritySearch,
                limit: topK,
                retained: &retained,
                generation: generation
            )
            var cursor = snapshot.nextPageCursor
            var previousCursor: SearchMediaPageCursor?
            while let currentCursor = cursor {
                try checkSearchGeneration(generation)
                guard currentCursor != previousCursor else {
                    throw SearchEngineError.corruptedIndex
                }
                let page = try loadTailPage(after: currentCursor, generation: generation)
                guard page.mediaCount > 0 else { throw SearchEngineError.corruptedIndex }
                try retainSimilarResults(
                    in: page.photos,
                    sourceID: photoId,
                    sourceEmbedding: sourceEmbedding,
                    gpuSearch: nil,
                    limit: topK,
                    retained: &retained,
                    generation: generation
                )
                previousCursor = currentCursor
                cursor = page.nextCursor
            }
            return BoundedTopK.sorted(retained, isPreferred: SearchResultRanking.isPreferred)
        } catch is CancellationError {
            return []
        } catch {
            logger.error("[SearchEngine] Find Similar failed: \(error.safeDiagnosticCode)")
            return []
        }
    }

    private func retainSimilarResults(
        in photos: MediaIndex,
        sourceID: String,
        sourceEmbedding: [Float],
        gpuSearch: SimilaritySearching?,
        limit: Int,
        retained: inout [SearchResult],
        generation: UInt
    ) throws {
        try checkSearchGeneration(generation)
        var scores = try scoreEmbeddings(
            queryEmbedding: sourceEmbedding,
            matrix: photos.embeddings,
            count: photos.count,
            gpuSearch: gpuSearch
        )
        for row in 0..<photos.count {
            try SearchCancellation.check(row)
            if photos.ids[row] == sourceID { scores[row] = -.infinity }
            guard scores[row] >= minimumScoreThreshold else { continue }
            BoundedTopK.insert(
                try SearchResultRanking.result(for: photos, row: row, score: scores[row]),
                into: &retained,
                limit: limit,
                isPreferred: SearchResultRanking.isPreferred
            )
        }
        try checkSearchGeneration(generation)
    }

    // MARK: - Private

    private func scoreEmbeddings(
        queryEmbedding: [Float],
        matrix: [Float16],
        count: Int,
        gpuSearch: SimilaritySearching?,
        candidateMask: [Bool]? = nil
    ) throws -> [Float] {
        try SearchCancellation.checkNow()
        guard count > 0 else { return [] }

        if let gpuScores = gpuSearch?.search(queryEmbedding: queryEmbedding), gpuScores.count == count {
            try SearchCancellation.checkNow()
            return gpuScores
        }

        var scores = [Float](repeating: 0, count: count)
        var rowBuf = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<count {
            try SearchCancellation.check(i)
            if let candidateMask, !candidateMask[i] { continue }
            scores[i] = scoreEmbedding(
                queryEmbedding: queryEmbedding,
                matrix: matrix,
                row: i,
                rowBuffer: &rowBuf
            )
        }
        return scores
    }

    private func scoreEmbedding(
        queryEmbedding: [Float],
        matrix: [Float16],
        row: Int,
        rowBuffer: inout [Float]
    ) -> Float {
        let offset = row * embeddingDim
        for j in 0..<embeddingDim {
            rowBuffer[j] = Float(matrix[offset + j])
        }
        var dot: Float = 0
        vDSP_dotpr(queryEmbedding, 1, rowBuffer, 1, &dot, vDSP_Length(embeddingDim))
        return dot
    }

    private func candidateMask(
        for index: MediaIndex,
        hints: QueryHints,
        locationFilter: LocationSearchFilter?
    ) throws -> [Bool] {
        var mask = [Bool](repeating: true, count: index.count)
        for row in 0..<index.count {
            try SearchCancellation.check(row)
            if let dateRange = hints.dateRange {
                guard let date = index.dates[row],
                      dateRange.contains(date) else {
                    mask[row] = false
                    continue
                }
            }

            if let locationFilter {
                mask[row] = locationFilter.matches(
                    localIdentifier: index.localIdentifiers[row],
                    latitude: index.latitudes[row],
                    longitude: index.longitudes[row],
                    city: index.locationCities[row],
                    state: index.locationStates[row],
                    country: index.locationCountries[row],
                    name: index.locationNames[row]
                )
            }
        }
        return mask
    }

    private func scoreMedia(
        _ index: MediaIndex,
        candidateMask: [Bool],
        queryEmbedding: [Float],
        negativeEmbeddings: [[Float]],
        hints: QueryHints,
        gpuSearch: SimilaritySearching?
    ) throws -> ScoredMedia {
        let rawScores = try scoreEmbeddings(
            queryEmbedding: queryEmbedding,
            matrix: index.embeddings,
            count: index.count,
            gpuSearch: gpuSearch
        )
        var negativeScoreSets: [[Float]] = []
        negativeScoreSets.reserveCapacity(negativeEmbeddings.count)
        for negativeEmbedding in negativeEmbeddings {
            try SearchCancellation.checkNow()
            negativeScoreSets.append(try scoreEmbeddings(
                queryEmbedding: negativeEmbedding,
                matrix: index.embeddings,
                count: index.count,
                gpuSearch: gpuSearch,
                candidateMask: candidateMask
            ))
        }
        let queryWords = hints.textQuery.lowercased().split(separator: " ").map(String.init)
        // Local to this scoring call: NLTokenizer must not be shared across threads.
        let wordTokenizer = NLTokenizer(unit: .word)
        let phraseQuery = hints.textMatchQuery ?? (hints.hasVisualQuery ? hints.textQuery : "")
        let phraseWords = searchWords(in: phraseQuery, tokenizer: wordTokenizer)
        var textMatches = [Bool](repeating: false, count: index.count)
        let calendar = Calendar.current
        var scores = rawScores

        for row in 0..<index.count {
            try SearchCancellation.check(row)
            guard candidateMask[row] else {
                scores[row] = -1
                continue
            }

            var score = rawScores[row]
            if index.kind == .videoFrame {
                // Preserve the historical video eligibility boundary: a frame
                // with non-positive raw similarity cannot be rescued by boosts.
                guard score > 0 else {
                    scores[row] = -1
                    continue
                }
                for negativeScores in negativeScoreSets {
                    score -= negativeScores[row] * SearchConfig.negativeTermWeight
                }
            }

            if let timeRange = hints.timeOfDayHours,
               let date = index.dates[row],
               hour(calendar.component(.hour, from: date), isIn: timeRange) {
                score += SearchConfig.timeOfDayMatchBoost
            }

            switch index.kind {
            case .photo:
                for negativeScores in negativeScoreSets {
                    score -= negativeScores[row] * SearchConfig.negativeTermWeight
                }
                if !phraseWords.isEmpty, let text = index.ocrTexts[row] {
                    let words = searchWords(in: text, tokenizer: wordTokenizer)
                    textMatches[row] = words.indices.contains { words[$0...].starts(with: phraseWords) }
                }
                score += photoSceneLabelBoost(index: index, row: row, queryWords: queryWords)

            case .videoFrame:
                // Video frames still lack OCR, scene-label, and location-name
                // enrichment. Keep this compensation explicit until those
                // features are indexed for videos too.
                score += SearchConfig.videoRelevanceCompensation
                if score <= 0 { score = -1 }
            }

            scores[row] = score
        }

        return ScoredMedia(rawScores: rawScores, scores: scores, textMatches: textMatches)
    }

    private func trueCount(in values: [Bool]) throws -> Int {
        var count = 0
        for (index, value) in values.enumerated() {
            try SearchCancellation.check(index)
            if value { count += 1 }
        }
        return count
    }

    private func searchWords(in text: String, tokenizer: NLTokenizer) -> [String] {
        guard !text.isEmpty else { return [] }
        let normalized = text.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        tokenizer.string = normalized
        return tokenizer.tokens(for: normalized.startIndex..<normalized.endIndex)
            .map { String(normalized[$0]) }
    }

    private func photoSceneLabelBoost(
        index: MediaIndex,
        row: Int,
        queryWords: [String]
    ) -> Float {
        guard !queryWords.isEmpty, let sceneLabels = index.sceneLabels[row] else { return 0 }
        let labelSet = Set(SceneClassifier.stringToLabels(sceneLabels))
        var boost: Float = 0
        for word in queryWords {
            var wordScore: Float = labelSet.contains(word)
                ? SearchConfig.sceneLabelBoostPerMatch
                : 0
            if let synonyms = SceneLabelConfig.synonyms[word] {
                let hits = synonyms.subtracting([word]).intersection(labelSet).count
                if hits > 0 {
                    wordScore += SearchConfig.sceneLabelBoostPerMatch * 0.5 * Float(hits)
                }
            }
            boost += wordScore / Float(queryWords.count)
        }
        return boost
    }

    private func hour(_ hour: Int, isIn range: (start: Int, end: Int)) -> Bool {
        if range.start <= range.end {
            return hour >= range.start && hour < range.end
        }
        return hour >= range.start || hour < range.end
    }

    private func makeLocationFilter(hints: QueryHints) -> LocationSearchFilter? {
        guard let locationQuery = hints.locationHint else { return nil }
        return LocationSearchFilter(
            metadataMatcher: LocationMatcher.makeMatcher(
                queryLower: locationQuery.lowercased(),
                locality: hints.locationLocality,
                adminArea: hints.locationAdminArea,
                country: hints.locationCountryName
            ),
            coordinateMatcher: locationGazetteer.makeMatcher(
                query: locationQuery,
                locality: hints.locationLocality,
                adminArea: hints.locationAdminArea,
                country: hints.locationCountryName
            ),
            metadataOverlay: locationMetadataOverlay.withLock { $0 }
        )
    }

    private func formatDateRange(_ range: DateRange) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        formatter.calendar = calendar
        func precedingInstant(_ date: Date) -> Date {
            Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextDown)
        }
        // Date-only labels must show the previous calendar day for an exclusive
        // midnight. Avoid subsecond subtraction that formatters may round back
        // up to midnight, while preserving non-midnight ends on their own day.
        let displayEnd: Date
        if range.endIsExclusive, range.end > range.start,
           calendar.startOfDay(for: range.end) == range.end {
            displayEnd = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.start
        } else {
            displayEnd = range.end
        }
        func isComplete(_ component: Calendar.Component) -> Bool {
            guard let interval = calendar.dateInterval(of: component, for: range.start),
                  range.start == interval.start else { return false }
            return range.endIsExclusive
                ? range.end == interval.end
                : range.end == precedingInstant(interval.end)
        }

        if isComplete(.year) {
            formatter.dateFormat = "yyyy"
            return formatter.string(from: range.start)
        }
        if isComplete(.month) {
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: range.start)
        }
        formatter.dateStyle = .medium
        if calendar.isDate(range.start, inSameDayAs: displayEnd) {
            return formatter.string(from: range.start)
        }
        return "\(formatter.string(from: range.start)) to \(formatter.string(from: displayEnd))"
    }

    private func encodeQuery(
        text: String,
        precomputedEmbeddings: [String: [Float]] = [:]
    ) throws -> [Float] {
        let embedding: [Float]
        if let precomputed = precomputedEmbeddings[text] {
            embedding = precomputed
        } else {
            embedding = try currentTextEncoder().encode(text: text)
        }
        guard embedding.count == embeddingDim else {
            throw SearchEngineError.invalidEmbedding
        }
        return embedding
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
