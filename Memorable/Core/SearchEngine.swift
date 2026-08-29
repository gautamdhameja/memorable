import Foundation
import Accelerate
import CoreLocation
import os

struct SearchResponse {
    let results: [SearchResult]
    let fallbackResults: [SearchResult]
    let filtersApplied: FilterSummary?
}

struct FilterSummary {
    let dateDescription: String?
    let locationDescription: String?
    let visualQuery: String
}

private enum SearchQueryEmbeddingContext {
    @TaskLocal static var embeddings: [String: [Float]] = [:]
}

/// Ensures that overlapping callers share one complete replacement attempt,
/// so waiters never build or retain their own database copy.
private final class IndexLoadCoordinator: @unchecked Sendable {
    private final class Flight: @unchecked Sendable {
        let completion = DispatchGroup()
        var error: Error?

        init() {
            completion.enter()
        }
    }

    private let lock = NSLock()
    private var activeFlight: Flight?

    func run(_ operation: () throws -> Void) throws {
        let flight: Flight
        let isLeader: Bool

        lock.lock()
        if let activeFlight {
            flight = activeFlight
            isLeader = false
        } else {
            flight = Flight()
            activeFlight = flight
            isLeader = true
        }
        lock.unlock()

        guard isLeader else {
            while flight.completion.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            lock.lock()
            let error = flight.error
            lock.unlock()
            if let error { throw error }
            return
        }

        do {
            try operation()
            finish(flight, error: nil)
        } catch {
            finish(flight, error: error)
            throw error
        }
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

/// Coordinates immutable snapshot readers with replacement construction.
/// Reloads wait for current readers, prevent new readers, and release the old
/// snapshot before allocating its replacement so steady-state index memory is
/// never intentionally doubled.
private final class SearchActivityCoordinator: @unchecked Sendable {
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

        do {
            let result = try operation()
            finishSearch()
            return result
        } catch {
            finishSearch()
            throw error
        }
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

        let result = operation()
        finishSearch()
        return result
    }

    func withExclusiveReload(_ operation: () throws -> Void) throws {
        condition.lock()
        reloadInProgress = true
        while activeSearches > 0 {
            condition.wait()
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

final class SearchEngine: Sendable {
    private let indexSnapshot: OSAllocatedUnfairLock<SearchIndexSnapshot>
    private let indexLoadCoordinator = IndexLoadCoordinator()
    private let searchActivity = SearchActivityCoordinator()

    private let embeddingDim = EmbeddingConfig.dimensions
    private let minimumScoreThreshold = SearchConfig.minimumScoreThreshold

    static let maxRecommendedPhotos = IndexingConfig.largeLibraryThreshold
    /// The UI progressively reveals results, but retaining every match can
    /// exhaust memory for large Pro libraries. Keep a generous, deterministic
    /// window instead.
    static let maximumRetainedResults = SearchResultRanking.maximumRetainedResults

    private let injectedPhotoSimilaritySearch: SimilaritySearching?
    private let injectedVideoSimilaritySearch: SimilaritySearching?

    private let textEncoder: TextEmbeddingEncoding
    private let database: DatabaseProtocol
    init(
        textEncoder: TextEmbeddingEncoding,
        database: DatabaseProtocol = AppDatabase.shared,
        photoSimilaritySearch: SimilaritySearching? = nil,
        videoSimilaritySearch: SimilaritySearching? = nil
    ) {
        self.textEncoder = textEncoder
        self.database = database
        self.injectedPhotoSimilaritySearch = photoSimilaritySearch
        self.injectedVideoSimilaritySearch = videoSimilaritySearch
        self.indexSnapshot = OSAllocatedUnfairLock(
            initialState: SearchIndexSnapshot(
                photoSimilaritySearch: photoSimilaritySearch,
                videoSimilaritySearch: videoSimilaritySearch
            )
        )
    }

    func loadIndex() throws {
        guard !isMemoryPressureSuspended else { return }
        try indexLoadCoordinator.run { [self] in
            try searchActivity.withExclusiveReload {
                guard !isMemoryPressureSuspended else { return }
                try loadIndexOnce()
            }
        }
    }

    private func loadIndexOnce() throws {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        // The safety-first reload contract deliberately gives up serving the
        // previous index if construction fails. Keeping it here would double
        // the largest allocation on every reload and can terminate the app on
        // memory-constrained devices. A later reload repopulates the index.
        let canLoad = indexSnapshot.withLock { snapshot in
            guard !snapshot.isMemoryPressureSuspended else { return false }
            snapshot = SearchIndexSnapshot()
            return true
        }
        guard canLoad else { return }

        try Task.checkCancellation()
        let photoIndex = try database.loadAllEmbeddings()
        try Task.checkCancellation()
        guard !isMemoryPressureSuspended else { return }
        let videoIndex = try database.loadAllVideoEmbeddings()
        try Task.checkCancellation()
        guard !isMemoryPressureSuspended else { return }
        guard photoIndex.kind == .photo, videoIndex.kind == .videoFrame else {
            logger.error("[SearchEngine] Persisted index has unexpected media kinds")
            throw SearchEngineError.corruptedIndex
        }

        let newGPUSearch: SimilaritySearching?
        let newGPUVideoSearch: SimilaritySearching?
        #if targetEnvironment(simulator)
        newGPUSearch = injectedPhotoSimilaritySearch
        newGPUVideoSearch = injectedVideoSimilaritySearch
        #else
        // Build into fresh production scorers so an in-flight search can keep
        // using the previous immutable index until the locked swap below.
        newGPUSearch = injectedPhotoSimilaritySearch ?? GPUSimilaritySearch()
        newGPUVideoSearch = injectedVideoSimilaritySearch ?? GPUSimilaritySearch()
        #endif
        try Task.checkCancellation()
        guard !isMemoryPressureSuspended else { return }
        newGPUSearch?.buildIndex(embeddings: photoIndex.embeddings, count: photoIndex.count)
        try Task.checkCancellation()
        if videoIndex.count > 0 {
            guard !isMemoryPressureSuspended else { return }
            newGPUVideoSearch?.buildIndex(embeddings: videoIndex.embeddings, count: videoIndex.count)
        }
        try Task.checkCancellation()

        indexSnapshot.withLock {
            guard !$0.isMemoryPressureSuspended else { return }
            let memoryPressureGeneration = $0.memoryPressureGeneration
            $0 = SearchIndexSnapshot(
                photos: photoIndex,
                videos: videoIndex,
                uniqueVideoCount: videoIndex.uniqueIDCount,
                photoSimilaritySearch: newGPUSearch,
                videoSimilaritySearch: videoIndex.count == 0 ? nil : newGPUVideoSearch,
                memoryPressureGeneration: memoryPressureGeneration
            )
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

    var isLargeLibrary: Bool {
        indexSnapshot.withLock {
            ($0.photos.count + $0.videos.count) > Self.maxRecommendedPhotos
        }
    }

    var indexSize: Int {
        indexSnapshot.withLock { $0.photos.count }
    }

    var videoSize: Int {
        indexSnapshot.withLock { $0.uniqueVideoCount }
    }

    var totalSize: Int {
        indexSnapshot.withLock { $0.photos.count + $0.uniqueVideoCount }
    }

    var isIndexLoaded: Bool {
        indexSnapshot.withLock { $0.photos.count + $0.videos.count > 0 }
    }

    var isMemoryPressureSuspended: Bool {
        indexSnapshot.withLock { $0.isMemoryPressureSuspended }
    }

    func dropIndex() {
        indexSnapshot.withLock {
            let suspended = $0.isMemoryPressureSuspended
            $0 = SearchIndexSnapshot(isMemoryPressureSuspended: suspended)
        }
        #if DEBUG
        logger.info("[SearchEngine] Index dropped due to memory pressure")
        #endif
    }

    func suspendForMemoryPressure() {
        indexSnapshot.withLock {
            $0 = SearchIndexSnapshot(
                isMemoryPressureSuspended: true,
                memoryPressureGeneration: $0.memoryPressureGeneration &+ 1
            )
        }
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
        featurePolicy: SearchFeaturePolicy = .basic
    ) async throws -> SearchResponse {
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
        let searchStart = CFAbsoluteTimeGetCurrent()
        logger.info("[SearchEngine] Search started")
        #endif

        let hints = await QueryParser.parse(query: query, featurePolicy: featurePolicy)
        try checkSearchGeneration(memoryPressureGeneration)
        let effectiveHints = featurePolicy.enforcing(hints)
        var precomputedEmbeddings: [String: [Float]] = [:]
        if effectiveHints.hasVisualQuery && !isPureLocationQuery(effectiveHints) {
            var texts = [effectiveHints.textQuery]
            texts.append(contentsOf: effectiveHints.negativeTerms)
            for text in texts where precomputedEmbeddings[text] == nil {
                try checkSearchGeneration(memoryPressureGeneration)
                let embedding = try await textEncoder.encodeCancellable(text: text)
                try checkSearchGeneration(memoryPressureGeneration)
                guard embedding.count == embeddingDim else {
                    throw SearchEngineError.invalidEmbedding
                }
                precomputedEmbeddings[text] = embedding
            }
        }

        let response = try SearchQueryEmbeddingContext.$embeddings.withValue(
            precomputedEmbeddings
        ) {
            try hybridSearch(
                hints: effectiveHints,
                featurePolicy: featurePolicy,
                memoryPressureGeneration: memoryPressureGeneration
            )
        }
        try checkSearchGeneration(memoryPressureGeneration)

        #if DEBUG
        logger.info("[SearchEngine] Search completed in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - searchStart))s, main=\(response.results.count), fallback=\(response.fallbackResults.count), filters=\(response.filtersApplied != nil)")
        #endif

        return response
    }

    /// A "pure location" query is one whose entire meaning is the place name:
    /// either the parser explicitly flagged it non-visual, or the parser's
    /// fallback auto-filled the visual query from the location name (so
    /// `textQuery == locationHint.lowercased()`). In either case we skip CLIP
    /// ranking entirely and return every matching photo sorted by date, which
    /// is what the user actually wants for "San Diego", "California", etc.
    private func isPureLocationQuery(_ hints: QueryHints) -> Bool {
        if !hints.hasVisualQuery { return true }
        if let loc = hints.locationHint?.lowercased(), hints.textQuery == loc {
            return true
        }
        return false
    }

    func hybridSearch(
        hints: QueryHints,
        featurePolicy: SearchFeaturePolicy = .basic
    ) throws -> SearchResponse {
        let memoryPressureGeneration = indexSnapshot.withLock { $0.memoryPressureGeneration }
        return try hybridSearch(
            hints: hints,
            featurePolicy: featurePolicy,
            memoryPressureGeneration: memoryPressureGeneration
        )
    }

    private func hybridSearch(
        hints: QueryHints,
        featurePolicy: SearchFeaturePolicy,
        memoryPressureGeneration: UInt
    ) throws -> SearchResponse {
        try searchActivity.withSearch {
            try SearchCancellation.$additionalCheck.withValue({ [weak self] in
                guard let self else { throw CancellationError() }
                try self.checkSearchGeneration(memoryPressureGeneration)
            }) {
                try SearchCancellation.checkNow()
                return try performHybridSearch(hints: featurePolicy.enforcing(hints))
            }
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

    private func performHybridSearch(hints: QueryHints) throws -> SearchResponse {
        try SearchCancellation.checkNow()
        let snapshot = indexSnapshot.withLock { $0 }
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

        // Location filter: local-only matching. Query-derived location text is
        // never sent to CLGeocoder; it matches stored reverse-geocoded strings,
        // with GPS fallback only when trusted coordinates already exist in hints.
        var targetLoc: CLLocation?
        let locationMatcher: LocationMatcher.Matcher? = hints.locationHint.map { locationQuery in
            LocationMatcher.makeMatcher(
                queryLower: locationQuery.lowercased(),
                locality: hints.locationLocality,
                adminArea: hints.locationAdminArea,
                country: hints.locationCountryName
            )
        }
        if let coord = hints.locationCoordinate,
           hints.locationHint != nil,
           hints.locationRadiusKm != nil {
            targetLoc = CLLocation(latitude: coord.lat, longitude: coord.lon)
        }

        let photoCandidateMask = try candidateMask(
            for: photos,
            hints: hints,
            locationMatcher: locationMatcher,
            targetLoc: targetLoc
        )
        let videoCandidateMask = try candidateMask(
            for: videos,
            hints: hints,
            locationMatcher: locationMatcher,
            targetLoc: targetLoc
        )
        let candidateCount = try trueCount(in: photoCandidateMask)
        let videoCandidateCount = try trueCount(in: videoCandidateMask)

        #if DEBUG
        logger.info("[SearchEngine] Filter: \(candidateCount)/\(photos.count) photos and \(videoCandidateCount)/\(videos.count) video frames passed hard filters")
        if hints.locationCoordinate != nil {
            let withGPS = (0..<photos.count).filter {
                photos.latitudes[$0] != nil && photos.longitudes[$0] != nil
            }.count
            logger.info("[SearchEngine] GPS stats: \(withGPS)/\(photos.count) photos have GPS, \(candidateCount) passed all filters")
        }
        #endif

        // =====================================================================
        // PHASE 2: BRANCH ON QUERY INTENT
        // =====================================================================

        let filtersActive = hints.dateRange != nil || hints.locationHint != nil

        // Empty candidate set with active filters → provide fallback
        if candidateCount == 0 && videoCandidateCount == 0 && filtersActive {
            let fallbackResults = hints.hasVisualQuery
                ? try computeFallbackResults(text: hints.textQuery, index: photos, gpuSearch: photoGPU)
                : []
            let summary = FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: [], fallbackResults: fallbackResults, filtersApplied: summary)
        }

        // Pure-location query (explicit or auto-filled): skip CLIP ranking and
        // return every matching media item sorted by date — the user wants all
        // of them, not a CLIP-ranked top-K against a meaningless city embedding.
        if isPureLocationQuery(hints) {
            return try SearchResultRanking.locationOnlyResults(media: [
                (index: photos, candidateMask: photoCandidateMask),
                (index: videos, candidateMask: videoCandidateMask),
            ])
        }

        // =====================================================================
        // PHASE 3: CLIP SCORING — score all, then mask out non-candidates
        // =====================================================================

        try SearchCancellation.checkNow()
        let queryEmbedding = try encodeQuery(text: hints.textQuery)
        var negativeEmbeddings: [[Float]] = []
        negativeEmbeddings.reserveCapacity(hints.negativeTerms.count)
        for negativeTerm in hints.negativeTerms {
            try SearchCancellation.checkNow()
            negativeEmbeddings.append(try encodeQuery(text: negativeTerm))
        }

        let photoScoring = try scoreMedia(
            photos,
            candidateMask: photoCandidateMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: negativeEmbeddings,
            hints: hints,
            targetLoc: targetLoc,
            gpuSearch: photoGPU
        )
        let videoScoring = try scoreMedia(
            videos,
            candidateMask: videoCandidateMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: negativeEmbeddings,
            hints: hints,
            targetLoc: targetLoc,
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

        let topScoredRows = try BoundedTopK.rows(
            count: scores.count,
            limit: SearchConfig.topK,
            isPreferred: { lhs, rhs in
                if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
                return lhs < rhs
            },
            cancellationCheck: SearchCancellation.check
        )

        // Adaptive thresholding for abstract/compound queries.
        // When no filters are active and zero candidates pass the hard
        // threshold, check whether the top candidates form a meaningful
        // cluster just below it (e.g. "family vacation" scoring 0.08-0.11).
        // If so, use a relaxed threshold derived from the top score so the
        // cluster lands in the main grid instead of near-miss fallback.
        var effectiveThreshold = minimumScoreThreshold
        if !filtersActive {
            let aboveThreshold = topScoredRows.filter { scores[$0] >= minimumScoreThreshold }.count
            if aboveThreshold == 0, let firstRow = topScoredRows.first, scores[firstRow] >= 0.06 {
                let topScore = scores[firstRow]
                let clusterCount = topScoredRows.filter { scores[$0] >= topScore * 0.8 }.count
                if clusterCount >= 3 {
                    effectiveThreshold = topScore * 0.6
                }
            }
        }

        // No topK cap here — return every above-threshold candidate. The UI
        // layer windows to an initial visible count and lets the user expand.
        let photoResults = try SearchResultRanking.results(
            for: photos,
            scores: scores,
            threshold: effectiveThreshold
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
        logger.info("[Results] \(photoResultCount) photos + \(videoResultCount) videos = \(allResults.count) total (threshold=\(String(format: "%.2f", thresholdVal)))")

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

        // Sparse CLIP fallback: merge location results when CLIP matched very few candidates
        // Threshold: fewer than 5 results AND less than 10% of candidates matched
        // Skip when CLIP is confident (top score well above threshold) — the small
        // result count is genuine, not a scoring artifact.
        let topResultScore = allResults.first?.score ?? 0
        let clipIsConfident = topResultScore >= minimumScoreThreshold * 1.25
        let clipMatchedTooFew = allResults.count < SearchConfig.sparseClipMinResults && candidateCount > 0
            && Double(allResults.count) / Double(candidateCount) < SearchConfig.sparseClipMaxRatio
        if clipMatchedTooFew && filtersActive && !clipIsConfident {
            // All candidates have CLIP scores from the GPU matmul.
            // Retain the best bounded candidate window by CLIP score, including
            // candidates below the normal threshold.
            // This way "old town" photos that scored 0.16 rank above random
            // San Diego photos that scored 0.08.
            let photoCandidateRows = try BoundedTopK.rows(
                count: photos.count,
                limit: SearchConfig.locationResultsCap,
                includes: { photoCandidateMask[$0] },
                isPreferred: { lhs, rhs in
                    if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
                    if photos.localIdentifiers[lhs] != photos.localIdentifiers[rhs] {
                        return photos.localIdentifiers[lhs] < photos.localIdentifiers[rhs]
                    }
                    return lhs < rhs
                },
                cancellationCheck: SearchCancellation.check
            )
            var candidateResults = photoCandidateRows.map { i in
                SearchResult(
                    id: photos.ids[i],
                    score: scores[i],
                    localIdentifier: photos.localIdentifiers[i],
                    creationDate: photos.dates[i],
                    isVideo: false,
                    bestFramePosition: nil,
                    sourceId: photos.sourceIds[i],
                    filePath: photos.filePaths[i]
                )
            }

            // Also include the best frame for each video candidate, including
            // positive scores below the normal result threshold.
            candidateResults.append(contentsOf: try makeVideoNearMissResults())

            // Keep the top bounded CLIP-ranked candidates, including results
            // below the normal threshold.
            let merged = try BoundedTopK.select(
                from: candidateResults,
                limit: SearchConfig.locationResultsCap,
                isPreferred: SearchResultRanking.isPreferred,
                cancellationCheck: SearchCancellation.check
            )

            let summary = FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )

            // If the best candidate score is too low, the visual concept simply
            // doesn't exist in this location. Demote to fallback instead of
            // filling the main grid with irrelevant photos.
            let topScore = merged.first?.score ?? 0
            if topScore < SearchConfig.sparseClipMinScore {
                return SearchResponse(results: [], fallbackResults: merged, filtersApplied: summary)
            }
            return SearchResponse(results: merged, fallbackResults: [], filtersApplied: summary)
        }

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

    // MARK: - Helper Methods

    private func computeFallbackResults(
        text: String,
        index mediaIndex: MediaIndex,
        gpuSearch: SimilaritySearching?
    ) throws -> [SearchResult] {
        let queryEmbedding: [Float]
        do {
            queryEmbedding = try encodeQuery(text: text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
        let scores = try scoreEmbeddings(
            queryEmbedding: queryEmbedding,
            matrix: mediaIndex.embeddings,
            count: mediaIndex.count,
            gpuSearch: gpuSearch
        )

        let rows = try BoundedTopK.rows(
            count: scores.count,
            limit: 5,
            includes: { scores[$0] >= minimumScoreThreshold },
            isPreferred: { lhs, rhs in
                if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
                return lhs < rhs
            },
            cancellationCheck: SearchCancellation.check
        )
        return rows.map { row in
            SearchResult(id: mediaIndex.ids[row], score: scores[row],
                         localIdentifier: mediaIndex.localIdentifiers[row],
                         creationDate: mediaIndex.dates[row], isVideo: false,
                         bestFramePosition: nil,
                         sourceId: mediaIndex.sourceIds[row],
                         filePath: mediaIndex.filePaths[row])
        }
    }

    // MARK: - Similar Photos

    func findSimilar(photoId: String, topK: Int = 50) -> [SearchResult] {
        searchActivity.withSearchUnlessCancelled {
            performFindSimilar(photoId: photoId, topK: topK)
        } ?? []
    }

    private func performFindSimilar(photoId: String, topK: Int) -> [SearchResult] {
        guard !Task.isCancelled else { return [] }
        let snapshot = indexSnapshot.withLock { $0 }
        let photos = snapshot.photos
        let ids = photos.ids
        let localIds = photos.localIdentifiers
        let sourceIds = photos.sourceIds
        let filePaths = photos.filePaths
        let photoDates = photos.dates
        let matrix = photos.embeddings
        let count = photos.count
        let photoGPU = snapshot.photoSimilaritySearch

        guard let sourceIndex = ids.firstIndex(of: photoId) else { return [] }

        // Extract source embedding as Float32 for GPU query
        let offset = sourceIndex * embeddingDim
        var sourceEmbedding = [Float](repeating: 0, count: embeddingDim)
        for j in 0..<embeddingDim {
            if j.isMultiple(of: SearchCancellation.checkInterval), Task.isCancelled { return [] }
            sourceEmbedding[j] = Float(matrix[offset + j])
        }

        // GPU search with CPU fallback
        var scores: [Float]
        if let gpuScores = photoGPU?.search(queryEmbedding: sourceEmbedding), gpuScores.count == count {
            guard !Task.isCancelled else { return [] }
            scores = gpuScores
            scores[sourceIndex] = 0 // exclude self
        } else {
            scores = [Float](repeating: 0, count: count)
            var rowBuf = [Float](repeating: 0, count: embeddingDim)
            for i in 0..<count {
                if i.isMultiple(of: SearchCancellation.checkInterval), Task.isCancelled { return [] }
                if i == sourceIndex { continue }
                let rowOffset = i * embeddingDim
                for j in 0..<embeddingDim { rowBuf[j] = Float(matrix[rowOffset + j]) }
                var dot: Float = 0
                vDSP_dotpr(sourceEmbedding, 1, rowBuf, 1, &dot, vDSP_Length(embeddingDim))
                scores[i] = dot
            }
        }

        guard !Task.isCancelled else { return [] }
        guard let topRows = try? BoundedTopK.rows(
            count: scores.count,
            limit: topK,
            includes: { scores[$0] >= minimumScoreThreshold },
            isPreferred: { lhs, rhs in
                if scores[lhs] != scores[rhs] { return scores[lhs] > scores[rhs] }
                return lhs < rhs
            },
            cancellationCheck: SearchCancellation.check
        ) else { return [] }

        return topRows.map { index in
            let score = scores[index]
            return SearchResult(
                id: ids[index],
                score: score,
                localIdentifier: localIds[index],
                creationDate: photoDates[index],
                isVideo: false,
                bestFramePosition: nil,
                sourceId: sourceIds[index],
                filePath: filePaths[index]
            )
        }
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
        locationMatcher: LocationMatcher.Matcher?,
        targetLoc: CLLocation?
    ) throws -> [Bool] {
        var mask = [Bool](repeating: true, count: index.count)
        for row in 0..<index.count {
            try SearchCancellation.check(row)
            if let dateRange = hints.dateRange {
                guard let date = index.dates[row],
                      date >= dateRange.start,
                      date <= dateRange.end else {
                    mask[row] = false
                    continue
                }
            }

            mask[row] = mediaPassesLocationFilter(
                hints: hints,
                locationMatcher: locationMatcher,
                targetLoc: targetLoc,
                latitude: index.latitudes[row],
                longitude: index.longitudes[row],
                city: index.locationCities[row],
                state: index.locationStates[row],
                country: index.locationCountries[row],
                name: index.locationNames[row]
            )
        }
        return mask
    }

    private func scoreMedia(
        _ index: MediaIndex,
        candidateMask: [Bool],
        queryEmbedding: [Float],
        negativeEmbeddings: [[Float]],
        hints: QueryHints,
        targetLoc: CLLocation?,
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
            } else {
                score += photoLocationBoost(
                    index: index,
                    row: row,
                    hints: hints,
                    targetLoc: targetLoc
                )
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
                score += photoOCRBoost(index: index, row: row, queryWords: queryWords)
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

        return ScoredMedia(rawScores: rawScores, scores: scores)
    }

    private func trueCount(in values: [Bool]) throws -> Int {
        var count = 0
        for (index, value) in values.enumerated() {
            try SearchCancellation.check(index)
            if value { count += 1 }
        }
        return count
    }

    private func photoLocationBoost(
        index: MediaIndex,
        row: Int,
        hints: QueryHints,
        targetLoc: CLLocation?
    ) -> Float {
        guard let targetLoc, let radiusKm = hints.locationRadiusKm else { return 0 }
        guard index.locationCities[row] == nil || index.locationCities[row]?.isEmpty == true else {
            return 0
        }
        guard let latitude = index.latitudes[row], let longitude = index.longitudes[row] else {
            return 0
        }

        let distanceKm = targetLoc.distance(
            from: CLLocation(latitude: latitude, longitude: longitude)
        ) / 1000
        if distanceKm < radiusKm * 0.1 {
            return SearchConfig.locationCloseBoost
        }
        if distanceKm < radiusKm * 0.3 {
            return SearchConfig.locationNearBoost
        }
        return 0
    }

    private func photoOCRBoost(
        index: MediaIndex,
        row: Int,
        queryWords: [String]
    ) -> Float {
        guard !queryWords.isEmpty else { return 0 }
        guard let ocrText = index.ocrTexts[row] else { return 0 }
        let text = ocrText.lowercased()
        let matchCount = queryWords.filter { text.contains($0) }.count
        guard matchCount > 0 else { return 0 }
        return SearchConfig.ocrBoostPerWord
            * Float(matchCount) / Float(queryWords.count)
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

    private func mediaPassesLocationFilter(
        hints: QueryHints,
        locationMatcher: LocationMatcher.Matcher?,
        targetLoc: CLLocation?,
        latitude: Double?,
        longitude: Double?,
        city: String?,
        state: String?,
        country: String?,
        name: String?
    ) -> Bool {
        guard hints.locationHint != nil else { return true }

        if let city, !city.isEmpty {
            if locationMatcher?(city, state, country, name) == true {
                return true
            }

            // Rescue cross-language city-name mismatches with the same tight
            // coordinate cap for photos and videos.
            guard let target = targetLoc, let latitude, let longitude else {
                return false
            }
            let distanceKm = target.distance(
                from: CLLocation(latitude: latitude, longitude: longitude)
            ) / 1000.0
            return distanceKm <= 50.0
        }

        if let target = targetLoc, let radiusKm = hints.locationRadiusKm {
            guard let latitude, let longitude else { return false }
            let distanceKm = target.distance(
                from: CLLocation(latitude: latitude, longitude: longitude)
            ) / 1000.0
            return distanceKm <= radiusKm
        }

        // Without trusted query coordinates, locally unverifiable media stays
        // in the candidate pool so reverse-geocoding lag does not exclude it.
        return true
    }

    private func formatDateRange(_ range: DateRange) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let daysBetween = calendar.dateComponents([.day], from: range.start, to: range.end).day ?? 0

        if daysBetween <= 1 {
            formatter.dateStyle = .medium
            return formatter.string(from: range.start)
        } else if daysBetween <= 35 {
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: range.start)
        } else if daysBetween > 350 && daysBetween < 380 {
            formatter.dateFormat = "yyyy"
            return formatter.string(from: range.start)
        } else {
            formatter.dateStyle = .medium
            return "\(formatter.string(from: range.start)) to \(formatter.string(from: range.end))"
        }
    }

    private func encodeQuery(text: String) throws -> [Float] {
        let embedding: [Float]
        if let precomputed = SearchQueryEmbeddingContext.embeddings[text] {
            embedding = precomputed
        } else {
            embedding = try textEncoder.encode(text: text)
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
