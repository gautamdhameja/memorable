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

private struct SearchIndexSnapshot: Sendable {
    var photos = MediaIndex(kind: .photo)
    var videos = MediaIndex(kind: .videoFrame)
    var uniqueVideoCount = 0
    var photoSimilaritySearch: SimilaritySearching?
    var videoSimilaritySearch: SimilaritySearching?
    var isMemoryPressureSuspended = false
}

private struct ScoredMedia {
    let rawScores: [Float]
    let scores: [Float]
}

final class SearchEngine: Sendable {
    private let indexSnapshot: OSAllocatedUnfairLock<SearchIndexSnapshot>

    private let embeddingDim = EmbeddingConfig.dimensions
    private let minimumScoreThreshold = SearchConfig.minimumScoreThreshold

    static let maxRecommendedPhotos = IndexingConfig.largeLibraryThreshold
    /// The UI progressively reveals results, but retaining every match can
    /// exhaust memory for large Pro libraries. Keep a generous, deterministic
    /// window instead.
    static let maximumRetainedResults = SearchConfig.locationResultsCap

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
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        let photoIndex = try database.loadAllEmbeddings()
        let videoIndex = try database.loadAllVideoEmbeddings()
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
        newGPUSearch?.buildIndex(embeddings: photoIndex.embeddings, count: photoIndex.count)
        if videoIndex.count > 0 {
            newGPUVideoSearch?.buildIndex(embeddings: videoIndex.embeddings, count: videoIndex.count)
        }

        indexSnapshot.withLock {
            guard !$0.isMemoryPressureSuspended else { return }
            $0 = SearchIndexSnapshot(
                photos: photoIndex,
                videos: videoIndex,
                uniqueVideoCount: videoIndex.uniqueIDCount,
                photoSimilaritySearch: newGPUSearch,
                videoSimilaritySearch: videoIndex.count == 0 ? nil : newGPUVideoSearch
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
        indexSnapshot.withLock { $0 = SearchIndexSnapshot(isMemoryPressureSuspended: true) }
        #if DEBUG
        logger.info("[SearchEngine] Index suspended due to memory pressure")
        #endif
    }

    func resumeAfterMemoryPressure() {
        indexSnapshot.withLock { $0.isMemoryPressureSuspended = false }
    }

    // MARK: - Search

    func search(query: String) async throws -> SearchResponse {
        guard !isMemoryPressureSuspended else {
            return SearchResponse(results: [], fallbackResults: [], filtersApplied: nil)
        }
        if !isIndexLoaded {
            try await Task.detached(priority: .userInitiated) { [self] in
                try loadIndex()
            }.value
        }

        #if DEBUG
        let searchStart = CFAbsoluteTimeGetCurrent()
        logger.info("[SearchEngine] Search query: '\(query)'")
        #endif

        let hints = await QueryParser.parse(query: query)

        let response = try hybridSearch(hints: hints)

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

    func hybridSearch(hints: QueryHints) throws -> SearchResponse {
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

        let photoCandidateMask = candidateMask(
            for: photos,
            hints: hints,
            locationMatcher: locationMatcher,
            targetLoc: targetLoc
        )
        let videoCandidateMask = candidateMask(
            for: videos,
            hints: hints,
            locationMatcher: locationMatcher,
            targetLoc: targetLoc
        )
        let candidateCount = photoCandidateMask.filter { $0 }.count
        let videoCandidateCount = videoCandidateMask.filter { $0 }.count

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
                ? computeFallbackResults(text: hints.textQuery, index: photos, gpuSearch: photoGPU)
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
            return try locationOnlyResults(media: [
                (index: photos, candidateMask: photoCandidateMask),
                (index: videos, candidateMask: videoCandidateMask),
            ])
        }

        // =====================================================================
        // PHASE 3: CLIP SCORING — score all, then mask out non-candidates
        // =====================================================================

        let queryEmbedding = try encodeQuery(text: hints.textQuery)
        let negativeEmbeddings = try hints.negativeTerms.map { try textEncoder.encode(text: $0) }

        let photoScoring = scoreMedia(
            photos,
            candidateMask: photoCandidateMask,
            queryEmbedding: queryEmbedding,
            negativeEmbeddings: negativeEmbeddings,
            hints: hints,
            targetLoc: targetLoc,
            gpuSearch: photoGPU
        )
        let videoScoring = scoreMedia(
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
                let dateStr = photos.dates[i].map { ISO8601DateFormatter().string(from: $0) } ?? "no-date"
                logger.info("[BoostDetail #\(rank+1)] raw=\(String(format: "%.4f", raw)) boosted=\(String(format: "%.4f", boosted)) boost=\(String(format: "%+.4f", boostTotal)) date=\(dateStr) id=\(photos.localIdentifiers[i].prefix(12))")
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

        let sorted = scores.enumerated().sorted { $0.element > $1.element }

        // Adaptive thresholding for abstract/compound queries.
        // When no filters are active and zero candidates pass the hard
        // threshold, check whether the top candidates form a meaningful
        // cluster just below it (e.g. "family vacation" scoring 0.08-0.11).
        // If so, use a relaxed threshold derived from the top score so the
        // cluster lands in the main grid instead of near-miss fallback.
        var effectiveThreshold = minimumScoreThreshold
        if !filtersActive {
            let aboveThreshold = sorted.prefix(50).filter { $0.element >= minimumScoreThreshold }.count
            if aboveThreshold == 0, let topScore = sorted.first?.element, topScore >= 0.06 {
                let clusterCount = sorted.prefix(50).filter { $0.element >= topScore * 0.8 }.count
                if clusterCount >= 3 {
                    effectiveThreshold = topScore * 0.6
                }
            }
        }

        // No topK cap here — return every above-threshold candidate. The UI
        // layer windows to an initial visible count and lets the user expand.
        let photoResults = try results(
            for: photos,
            scores: scores,
            threshold: effectiveThreshold
        )
        let videoResults = try results(
            for: videos,
            scores: videoScores,
            threshold: minimumScoreThreshold
        )

        var allResults = photoResults + videoResults
        // Sort by score descending. For near-identical scores (within 1%),
        // prefer more recent results. SigLIP2's sigmoid loss produces a narrow
        // score range, so the tolerance must be tight to preserve relevance ranking.
        allResults.sort(by: Self.isPreferredResult)
        if allResults.count > Self.maximumRetainedResults {
            allResults.removeSubrange(Self.maximumRetainedResults...)
        }

        #if DEBUG
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let photoResultCount = photoResults.count
        let videoResultCount = videoResults.count
        let thresholdVal = self.minimumScoreThreshold
        logger.info("[Results] \(photoResultCount) photos + \(videoResultCount) videos = \(allResults.count) total (threshold=\(String(format: "%.2f", thresholdVal)))")

        // Top 10 results with type and score
        for (rank, r) in allResults.prefix(10).enumerated() {
            let dateStr = r.creationDate.map { dateFormatter.string(from: $0) } ?? "no-date"
            let type = r.isVideo ? "VIDEO" : "PHOTO"
            logger.info("[Result #\(rank + 1)] \(type) score=\(String(format: "%.4f", r.score)) date=\(dateStr) id=\(r.localIdentifier.prefix(20))")
        }

        // Score range of returned results
        if !allResults.isEmpty {
            let resultScores = allResults.map { $0.score }
            logger.info("[Results] Score range: \(String(format: "%.4f", resultScores.min()!)) - \(String(format: "%.4f", resultScores.max()!)) (spread=\(String(format: "%.4f", resultScores.max()! - resultScores.min()!)))")
        }

        // Near-miss diagnostics when results are empty or sparse
        if allResults.count < 5 {
            let nearMissCount = min(5, sorted.count)
            logger.info("[NearMiss] Top \(nearMissCount) photo scores (below threshold or filtered):")
            for (index, score) in sorted.prefix(nearMissCount) {
                let dateStr = photos.dates[index].map { dateFormatter.string(from: $0) } ?? "no-date"
                let passed = photoCandidateMask[index]
                logger.info("[NearMiss] score=\(String(format: "%.4f", score)) passedFilter=\(passed) date=\(dateStr)")
            }
            if videos.count > 0 {
                let topVideo = videoResults.sorted { $0.score > $1.score }.prefix(3)
                if topVideo.isEmpty {
                    logger.info("[NearMiss] No video frames passed threshold")
                }
                for result in topVideo {
                    logger.info("[NearMiss] VIDEO score=\(String(format: "%.4f", result.score)) vid=\(result.id.prefix(12)) frame=\(String(format: "%.2f", result.bestFramePosition ?? 0))")
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
            // Sort ALL candidates by CLIP score (not just those above threshold).
            // This way "old town" photos that scored 0.16 rank above random
            // San Diego photos that scored 0.08.
            let photoCandidateRows = (0..<photos.count)
                .filter { photoCandidateMask[$0] }
                .sorted {
                    if scores[$0] != scores[$1] { return scores[$0] > scores[$1] }
                    return photos.localIdentifiers[$0] < photos.localIdentifiers[$1]
                }
                .prefix(SearchConfig.locationResultsCap)
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

            // Also include video candidates if they passed filters
            candidateResults.append(contentsOf: videoResults.filter { $0.score > 0 })

            // Sort by CLIP score descending. All candidates get ranked by visual
            // relevance, even those below the normal threshold.
            candidateResults.sort(by: Self.isPreferredResult)
            let merged = Array(candidateResults.prefix(SearchConfig.locationResultsCap))

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
            let nearMissResults = sorted
                .filter { $0.element > 0 && photoCandidateMask[$0.offset] }
                .prefix(SearchConfig.topK)
                .map { (index, score) in
                    SearchResult(id: photos.ids[index], score: score,
                                 localIdentifier: photos.localIdentifiers[index],
                                 creationDate: photos.dates[index], isVideo: false,
                                 bestFramePosition: nil,
                                 sourceId: photos.sourceIds[index],
                                 filePath: photos.filePaths[index])
                }
            let fallbackSummary = FilterSummary(
                dateDescription: appliedSummary?.dateDescription,
                locationDescription: appliedSummary?.locationDescription,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: [], fallbackResults: Array(nearMissResults), filtersApplied: fallbackSummary)
        }

        return SearchResponse(results: allResults, fallbackResults: [], filtersApplied: appliedSummary)
    }

    // MARK: - Helper Methods

    private func locationOnlyResults(
        media: [(index: MediaIndex, candidateMask: [Bool])]
    ) throws -> SearchResponse {
        var results: [SearchResult] = []
        for (index, mask) in media {
            let scores = mask.map { $0 ? Float(1) : -1 }
            results.append(contentsOf: try self.results(
                for: index,
                scores: scores,
                threshold: 1,
                sortByScore: false
            ))
        }

        results.sort {
            let lhsDate = $0.creationDate ?? .distantPast
            let rhsDate = $1.creationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.localIdentifier < $1.localIdentifier
        }
        if results.count > Self.maximumRetainedResults {
            results.removeSubrange(Self.maximumRetainedResults...)
        }

        #if DEBUG
        logger.info("[SearchEngine] locationOnlyResults: returning \(results.count) results")
        #endif

        return SearchResponse(results: results, fallbackResults: [], filtersApplied: nil)
    }

    private func computeFallbackResults(
        text: String,
        index mediaIndex: MediaIndex,
        gpuSearch: SimilaritySearching?
    ) -> [SearchResult] {
        guard let queryEmbedding = try? encodeQuery(text: text) else { return [] }
        let scores = scoreEmbeddings(
            queryEmbedding: queryEmbedding,
            matrix: mediaIndex.embeddings,
            count: mediaIndex.count,
            gpuSearch: gpuSearch
        )

        let sorted = scores.enumerated().sorted { $0.element > $1.element }
        return sorted.prefix(5)
            .filter { $0.element >= minimumScoreThreshold }
            .map { (row, score) in
                SearchResult(id: mediaIndex.ids[row], score: score,
                             localIdentifier: mediaIndex.localIdentifiers[row],
                             creationDate: mediaIndex.dates[row], isVideo: false,
                             bestFramePosition: nil,
                             sourceId: mediaIndex.sourceIds[row],
                             filePath: mediaIndex.filePaths[row])
            }
    }

    // MARK: - Similar Photos

    func findSimilar(photoId: String, topK: Int = 50) -> [SearchResult] {
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
        for j in 0..<embeddingDim { sourceEmbedding[j] = Float(matrix[offset + j]) }

        // GPU search with CPU fallback
        var scores: [Float]
        if let gpuScores = photoGPU?.search(queryEmbedding: sourceEmbedding), gpuScores.count == count {
            scores = gpuScores
            scores[sourceIndex] = 0 // exclude self
        } else {
            scores = [Float](repeating: 0, count: count)
            var rowBuf = [Float](repeating: 0, count: embeddingDim)
            for i in 0..<count {
                if i == sourceIndex { continue }
                let rowOffset = i * embeddingDim
                for j in 0..<embeddingDim { rowBuf[j] = Float(matrix[rowOffset + j]) }
                var dot: Float = 0
                vDSP_dotpr(sourceEmbedding, 1, rowBuf, 1, &dot, vDSP_Length(embeddingDim))
                scores[i] = dot
            }
        }

        let sorted = scores.enumerated().sorted { $0.element > $1.element }
        let topResults = sorted.prefix(topK).filter { $0.element >= minimumScoreThreshold }

        return topResults.map { (index, score) in
            SearchResult(
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
    ) -> [Float] {
        guard count > 0 else { return [] }

        if let gpuScores = gpuSearch?.search(queryEmbedding: queryEmbedding), gpuScores.count == count {
            return gpuScores
        }

        var scores = [Float](repeating: 0, count: count)
        var rowBuf = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<count {
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
    ) -> [Bool] {
        var mask = [Bool](repeating: true, count: index.count)
        for row in 0..<index.count {
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
    ) -> ScoredMedia {
        let rawScores = scoreEmbeddings(
            queryEmbedding: queryEmbedding,
            matrix: index.embeddings,
            count: index.count,
            gpuSearch: gpuSearch
        )
        let negativeScoreSets = negativeEmbeddings.map {
            scoreEmbeddings(
                queryEmbedding: $0,
                matrix: index.embeddings,
                count: index.count,
                gpuSearch: gpuSearch,
                candidateMask: candidateMask
            )
        }
        let queryWords = hints.textQuery.lowercased().split(separator: " ").map(String.init)
        let calendar = Calendar.current
        var scores = rawScores

        for row in 0..<index.count {
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

    private func results(
        for index: MediaIndex,
        scores: [Float],
        threshold: Float,
        sortByScore: Bool = true
    ) throws -> [SearchResult] {
        switch index.kind {
        case .photo:
            var rows = (0..<index.count).filter { scores[$0] >= threshold }
            if sortByScore {
                rows.sort { lhs, rhs in
                    let lhsScore = scores[lhs]
                    let rhsScore = scores[rhs]
                    let scoreDiff = abs(lhsScore - rhsScore)
                    let maxScore = max(lhsScore, rhsScore)
                    if maxScore > 0, scoreDiff / maxScore < 0.01 {
                        let lhsDate = index.dates[lhs] ?? .distantPast
                        let rhsDate = index.dates[rhs] ?? .distantPast
                        if lhsDate != rhsDate { return lhsDate > rhsDate }
                    }
                    if lhsScore != rhsScore { return lhsScore > rhsScore }
                    return index.localIdentifiers[lhs] < index.localIdentifiers[rhs]
                }
            }
            return rows.prefix(Self.maximumRetainedResults).map { row in
                SearchResult(
                    id: index.ids[row],
                    score: scores[row],
                    localIdentifier: index.localIdentifiers[row],
                    creationDate: index.dates[row],
                    isVideo: false,
                    bestFramePosition: nil,
                    sourceId: index.sourceIds[row],
                    filePath: index.filePaths[row]
                )
            }

        case .videoFrame:
            var idOrder: [String] = []
            var bestByID: [String: SearchResult] = [:]
            for row in 0..<index.count where scores[row] >= threshold {
                guard let framePosition = index.framePositions[row] else {
                    throw SearchEngineError.corruptedIndex
                }
                let id = index.ids[row]
                let result = SearchResult(
                    id: id,
                    score: scores[row],
                    localIdentifier: index.localIdentifiers[row],
                    creationDate: index.dates[row],
                    isVideo: true,
                    bestFramePosition: framePosition,
                    sourceId: index.sourceIds[row],
                    filePath: index.filePaths[row]
                )
                if let existing = bestByID[id] {
                    if result.score > existing.score { bestByID[id] = result }
                } else {
                    idOrder.append(id)
                    bestByID[id] = result
                }
            }
            return idOrder.compactMap { bestByID[$0] }
                .sorted(by: Self.isPreferredResult)
                .prefix(Self.maximumRetainedResults)
                .map { $0 }
        }
    }

    private static func isPreferredResult(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
        let scoreDiff = abs(lhs.score - rhs.score)
        let maxScore = max(lhs.score, rhs.score)
        if maxScore > 0, scoreDiff / maxScore < 0.01 {
            let lhsDate = lhs.creationDate ?? .distantPast
            let rhsDate = rhs.creationDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
        }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.localIdentifier < rhs.localIdentifier
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
        try textEncoder.encode(text: text)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
