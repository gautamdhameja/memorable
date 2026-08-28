import Foundation
import Accelerate
import CoreLocation

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

private struct SearchIndexSnapshot {
    var photos = MediaIndex(kind: .photo)
    var videos = MediaIndex(kind: .videoFrame)
    var uniqueVideoCount = 0
    var photoSimilaritySearch: SimilaritySearching?
    var videoSimilaritySearch: SimilaritySearching?
}

class SearchEngine {
    private var indexSnapshot = SearchIndexSnapshot()

    private let embeddingDim = EmbeddingConfig.dimensions
    private let minimumScoreThreshold = SearchConfig.minimumScoreThreshold

    static let maxRecommendedPhotos = IndexingConfig.largeLibraryThreshold

    private let injectedPhotoSimilaritySearch: SimilaritySearching?
    private let injectedVideoSimilaritySearch: SimilaritySearching?

    private let textEncoder: TextEmbeddingEncoding
    private let database: DatabaseProtocol
    private let lock = NSLock()

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
        self.indexSnapshot.photoSimilaritySearch = photoSimilaritySearch
        self.indexSnapshot.videoSimilaritySearch = videoSimilaritySearch
    }

    func loadIndex() throws {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        let photoIndex = try database.loadAllEmbeddings()
        let videoIndex = try database.loadAllVideoEmbeddings()
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

        lock.lock()
        defer { lock.unlock() }
        self.indexSnapshot = SearchIndexSnapshot(
            photos: photoIndex,
            videos: videoIndex,
            uniqueVideoCount: videoIndex.uniqueIDCount,
            photoSimilaritySearch: newGPUSearch,
            videoSimilaritySearch: videoIndex.count == 0 ? nil : newGPUVideoSearch
        )

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
        lock.lock()
        defer { lock.unlock() }
        return (indexSnapshot.photos.count + indexSnapshot.videos.count) * embeddingDim * MemoryLayout<Float16>.size
    }

    var isLargeLibrary: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (indexSnapshot.photos.count + indexSnapshot.videos.count) > Self.maxRecommendedPhotos
    }

    var indexSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexSnapshot.photos.count
    }

    var videoSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexSnapshot.uniqueVideoCount
    }

    var totalSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexSnapshot.photos.count + indexSnapshot.uniqueVideoCount
    }

    var isIndexLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexSnapshot.photos.count + indexSnapshot.videos.count > 0
    }

    func dropIndex() {
        lock.lock()
        defer { lock.unlock() }
        indexSnapshot = SearchIndexSnapshot()
        #if DEBUG
        logger.info("[SearchEngine] Index dropped due to memory pressure")
        #endif
    }

    // MARK: - Search

    func search(query: String) async throws -> SearchResponse {
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
        let snapshot: SearchIndexSnapshot = {
            lock.lock()
            defer { lock.unlock() }
            return indexSnapshot
        }()
        let photos = snapshot.photos
        let videos = snapshot.videos

        let ids = photos.ids
        let localIds = photos.localIdentifiers
        let photoDates = photos.dates
        let photoLats = photos.latitudes
        let photoLons = photos.longitudes
        let photoOcrTexts = photos.ocrTexts
        let pCities = photos.locationCities
        let pStates = photos.locationStates
        let pCountries = photos.locationCountries
        let pLocNames = photos.locationNames
        let photoLabels = photos.sceneLabels
        let matrix = photos.embeddings
        let count = photos.count
        let vIds = videos.ids
        let vLocalIds = videos.localIdentifiers
        let vDates = videos.dates
        let vLats = videos.latitudes
        let vLons = videos.longitudes
        let vPositions = videos.framePositions
        let vCities = videos.locationCities
        let vStates = videos.locationStates
        let vCountries = videos.locationCountries
        let vLocNames = videos.locationNames
        let vMatrix = videos.embeddings
        let vCount = videos.count
        let photoGPU = snapshot.photoSimilaritySearch
        let videoGPU = snapshot.videoSimilaritySearch

        guard count + vCount > 0 else { return SearchResponse(results: [], fallbackResults: [], filtersApplied: nil) }

        // =====================================================================
        // PHASE 1: HARD FILTERS — build candidate mask before any CLIP scoring
        // =====================================================================

        var candidateMask = [Bool](repeating: true, count: count)

        // Date filter: discard photos outside the specified date range
        if let dateRange = hints.dateRange {
            for i in 0..<count {
                if let photoDate = photoDates[i] {
                    if photoDate < dateRange.start || photoDate > dateRange.end {
                        candidateMask[i] = false
                    }
                } else {
                    // No date metadata + user specified a time → not useful
                    candidateMask[i] = false
                }
            }
        }

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
        if hints.locationHint != nil {
            // Prepare GPS fallback coordinates (only meaningful if we also
            // have a radius; the Tier 2 branch re-checks radius per photo).
            if let coord = hints.locationCoordinate, hints.locationRadiusKm != nil {
                targetLoc = CLLocation(latitude: coord.lat, longitude: coord.lon)
            }

            for i in 0..<count {
                guard candidateMask[i] else { continue }
                candidateMask[i] = mediaPassesLocationFilter(
                    hints: hints,
                    locationMatcher: locationMatcher,
                    targetLoc: targetLoc,
                    latitude: photoLats[i],
                    longitude: photoLons[i],
                    city: pCities[i],
                    state: pStates[i],
                    country: pCountries[i],
                    name: pLocNames[i]
                )
            }
        }

        let candidateCount = candidateMask.filter { $0 }.count
        var videoCandidateMask = [Bool](repeating: false, count: vCount)
        for i in 0..<vCount {
            videoCandidateMask[i] = videoPassesHardFilters(
                index: i, hints: hints, locationMatcher: locationMatcher, targetLoc: targetLoc,
                dates: vDates, latitudes: vLats, longitudes: vLons,
                cities: vCities, states: vStates, countries: vCountries, names: vLocNames
            )
        }
        let videoCandidateCount = videoCandidateMask.filter { $0 }.count

        #if DEBUG
        logger.info("[SearchEngine] Filter: \(candidateCount)/\(count) photos passed hard filters")
        if hints.locationCoordinate != nil {
            let withGPS = (0..<count).filter { photoLats[$0] != nil && photoLons[$0] != nil }.count
            logger.info("[SearchEngine] GPS stats: \(withGPS)/\(count) photos have GPS, \(candidateCount) passed all filters")
        }
        #endif

        // =====================================================================
        // PHASE 2: BRANCH ON QUERY INTENT
        // =====================================================================

        let filtersActive = hints.dateRange != nil || hints.locationHint != nil

        // Empty candidate set with active filters → provide fallback
        if candidateCount == 0 && videoCandidateCount == 0 && filtersActive {
            let fallbackResults = hints.hasVisualQuery
                ? computeFallbackResults(text: hints.textQuery, ids: ids, localIds: localIds, dates: photoDates, matrix: matrix, count: count, gpuSearch: photoGPU)
                : []
            let summary = FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: [], fallbackResults: fallbackResults, filtersApplied: summary)
        }

        // Pure-location query (explicit or auto-filled): skip CLIP ranking and
        // return every matching photo sorted by date — the user wants all of
        // them, not a CLIP-ranked top-K against a meaningless city-name embedding.
        if isPureLocationQuery(hints) {
            return locationOnlyResults(
                candidateMask: candidateMask, ids: ids, localIds: localIds,
                dates: photoDates, count: count,
                vIds: vIds, vLocalIds: vLocalIds, vDates: vDates,
                vLats: vLats, vLons: vLons, vPositions: vPositions,
                vCities: vCities, vStates: vStates, vCountries: vCountries, vLocNames: vLocNames,
                vCount: vCount,
                hints: hints, targetLoc: targetLoc
            )
        }

        // =====================================================================
        // PHASE 3: CLIP SCORING — score all, then mask out non-candidates
        // =====================================================================

        let queryEmbedding = try encodeQuery(text: hints.textQuery)
        let negativeEmbeddings = try hints.negativeTerms.map { try textEncoder.encode(text: $0) }

        var scores = scoreEmbeddings(queryEmbedding: queryEmbedding, matrix: matrix, count: count, gpuSearch: photoGPU)

        // Zero out non-candidates
        for i in 0..<count {
            if !candidateMask[i] {
                scores[i] = -1.0
            }
        }

        #if DEBUG
        // Raw CLIP score distribution BEFORE any boosts
        let rawCandidateScores = (0..<count).filter { candidateMask[$0] }.map { scores[$0] }
        if !rawCandidateScores.isEmpty {
            let sortedRaw = rawCandidateScores.sorted(by: >)
            let rawAbove020 = rawCandidateScores.filter { $0 >= 0.20 }.count
            let rawAbove015 = rawCandidateScores.filter { $0 >= 0.15 }.count
            let rawAbove012 = rawCandidateScores.filter { $0 >= 0.12 }.count
            let rawAbove010 = rawCandidateScores.filter { $0 >= 0.10 }.count
            let rawMean = rawCandidateScores.reduce(0, +) / Float(rawCandidateScores.count)
            logger.info("[RawCLIP] candidates=\(rawCandidateScores.count) top10=[\(sortedRaw.prefix(10).map { String(format: "%.4f", $0) }.joined(separator: ", "))] mean=\(String(format: "%.4f", rawMean)) >=0.20:\(rawAbove020) >=0.15:\(rawAbove015) >=0.12:\(rawAbove012) >=0.10:\(rawAbove010)")
        }
        let preBoostScores = scores
        #endif

        // =====================================================================
        // PHASE 4: SOFT BOOSTS — only on candidates that passed hard filters
        // =====================================================================

        // Location proximity boost (Tier 2 GPS matches only — Tier 1 string matches are equally "in" the location)
        if let target = targetLoc, let radiusKm = hints.locationRadiusKm {
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                guard pCities[i] == nil || pCities[i]?.isEmpty == true else { continue }
                guard let lat = photoLats[i], let lon = photoLons[i] else { continue }
                let distanceKm = target.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
                if distanceKm < radiusKm * 0.1 {
                    scores[i] += SearchConfig.locationCloseBoost
                } else if distanceKm < radiusKm * 0.3 {
                    scores[i] += SearchConfig.locationNearBoost
                }
            }
        }

        // Time-of-day boost (boost only, no penalty)
        if let timeRange = hints.timeOfDayHours {
            let calendar = Calendar.current
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                guard let photoDate = photoDates[i] else { continue }
                let hour = calendar.component(.hour, from: photoDate)
                let inRange: Bool
                if timeRange.start <= timeRange.end {
                    inRange = hour >= timeRange.start && hour < timeRange.end
                } else {
                    inRange = hour >= timeRange.start || hour < timeRange.end
                }
                if inRange { scores[i] += SearchConfig.timeOfDayMatchBoost }
            }
        }

        // Negative term penalty
        for negEmbedding in negativeEmbeddings {
            let negativeScores = scoreEmbeddings(
                queryEmbedding: negEmbedding,
                matrix: matrix,
                count: count,
                gpuSearch: photoGPU,
                candidateMask: candidateMask
            )
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                scores[i] -= negativeScores[i] * SearchConfig.negativeTermWeight
            }
        }

        // OCR text boost
        let queryWords = hints.textQuery.lowercased().split(separator: " ").map(String.init)
        if !queryWords.isEmpty {
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                guard let ocrTextOpt = photoOcrTexts[safe: i], let ocrText = ocrTextOpt else { continue }
                let text = ocrText.lowercased()
                let matchCount = queryWords.filter { text.contains($0) }.count
                if matchCount > 0 {
                    scores[i] += SearchConfig.ocrBoostPerWord * Float(matchCount) / Float(queryWords.count)
                }
            }
        }

        // Scene label boost (with synonym expansion)
        if !queryWords.isEmpty {
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                guard let labelsStr = photoLabels[safe: i], let labels = labelsStr else { continue }
                let labelSet = Set(SceneClassifier.stringToLabels(labels))

                var matchScore: Float = 0
                for word in queryWords {
                    var wordScore: Float = 0
                    if labelSet.contains(word) {
                        wordScore += SearchConfig.sceneLabelBoostPerMatch
                    }
                    if let synonyms = SceneLabelConfig.synonyms[word] {
                        let hits = synonyms
                            .subtracting([word])
                            .intersection(labelSet)
                            .count
                        if hits > 0 {
                            wordScore += SearchConfig.sceneLabelBoostPerMatch * 0.5 * Float(hits)
                        }
                    }
                    matchScore += wordScore / Float(queryWords.count)
                }
                if matchScore > 0 {
                    scores[i] += matchScore
                }
            }
        }

        #if DEBUG
        // Score distribution AFTER boosts
        let candidateScores = (0..<count).filter { candidateMask[$0] }.map { scores[$0] }
        if !candidateScores.isEmpty {
            let sortedCS = candidateScores.sorted(by: >)
            let above020 = candidateScores.filter { $0 >= 0.20 }.count
            let above015 = candidateScores.filter { $0 >= 0.15 }.count
            let above012 = candidateScores.filter { $0 >= 0.12 }.count
            let above010 = candidateScores.filter { $0 >= 0.10 }.count
            let mean = candidateScores.reduce(0, +) / Float(candidateScores.count)
            logger.info("[BoostedCLIP] top10=[\(sortedCS.prefix(10).map { String(format: "%.4f", $0) }.joined(separator: ", "))] mean=\(String(format: "%.4f", mean)) >=0.20:\(above020) >=0.15:\(above015) >=0.12:\(above012) >=0.10:\(above010)")

            // Show boost breakdown for top 20 candidates
            let topIndices = (0..<count)
                .filter { candidateMask[$0] }
                .sorted { scores[$0] > scores[$1] }
                .prefix(20)
            for (rank, i) in topIndices.enumerated() {
                let raw = preBoostScores[i]
                let boosted = scores[i]
                let boostTotal = boosted - raw
                let dateStr = photoDates[i].map { ISO8601DateFormatter().string(from: $0) } ?? "no-date"
                logger.info("[BoostDetail #\(rank+1)] raw=\(String(format: "%.4f", raw)) boosted=\(String(format: "%.4f", boosted)) boost=\(String(format: "%+.4f", boostTotal)) date=\(dateStr) id=\(localIds[i].prefix(12))")
            }
        }
        #endif

        // =====================================================================
        // PHASE 5: VIDEO SCORING
        // =====================================================================

        var videoScoreMap: [String: (score: Float, localId: String, date: Date?, framePosition: Double)] = [:]

        if vCount > 0 {
            let videoScores = scoreEmbeddings(queryEmbedding: queryEmbedding, matrix: vMatrix, count: vCount, gpuSearch: videoGPU)
            let negativeVideoScores = negativeEmbeddings.map {
                scoreEmbeddings(
                    queryEmbedding: $0,
                    matrix: vMatrix,
                    count: vCount,
                    gpuSearch: videoGPU,
                    candidateMask: videoCandidateMask
                )
            }

            #if DEBUG
            let sortedVS = videoScores.enumerated().sorted { $0.element > $1.element }
            let vAbove020 = videoScores.filter { $0 >= 0.20 }.count
            let vAbove015 = videoScores.filter { $0 >= 0.15 }.count
            let vAbove010 = videoScores.filter { $0 >= 0.10 }.count
            let vMean = videoScores.reduce(0, +) / Float(vCount)
            logger.info("[ScoreDist] Videos: top5=[\(sortedVS.prefix(5).map { String(format: "%.3f", $0.element) }.joined(separator: ", "))] mean=\(String(format: "%.4f", vMean)) >=0.20:\(vAbove020) >=0.15:\(vAbove015) >=0.10:\(vAbove010) total:\(vCount)")
            #endif

            for i in 0..<vCount {
                var frameScore = videoScores[i]
                guard frameScore > 0 else { continue }
                guard videoCandidateMask[i] else { continue }

                for negativeScores in negativeVideoScores {
                    frameScore -= negativeScores[i] * SearchConfig.negativeTermWeight
                }

                if let timeRange = hints.timeOfDayHours, let videoDate = vDates[i] {
                    let hour = Calendar.current.component(.hour, from: videoDate)
                    let inRange = timeRange.start <= timeRange.end
                        ? hour >= timeRange.start && hour < timeRange.end
                        : hour >= timeRange.start || hour < timeRange.end
                    if inRange { frameScore += SearchConfig.timeOfDayMatchBoost }
                }

                // Videos don't get scene-label, OCR, or location-name boosts
                // that photos receive because those features aren't indexed
                // per video frame. Compensate so a genuinely relevant video
                // isn't outranked by boost-inflated photos.
                frameScore += SearchConfig.videoRelevanceCompensation
                guard frameScore > 0 else { continue }

                let vid = vIds[i]
                guard frameScore >= minimumScoreThreshold else { continue }
                guard let framePosition = vPositions[i] else {
                    throw SearchEngineError.corruptedIndex
                }

                if let existing = videoScoreMap[vid] {
                    if frameScore > existing.score {
                        videoScoreMap[vid] = (frameScore, vLocalIds[i], vDates[i], framePosition)
                    }
                } else {
                    videoScoreMap[vid] = (frameScore, vLocalIds[i], vDates[i], framePosition)
                }
            }

        }

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
        let photoResults = sorted.filter { $0.element >= effectiveThreshold }.map { (index, score) in
            SearchResult(id: ids[index], score: score, localIdentifier: localIds[index], creationDate: photoDates[index], isVideo: false, bestFramePosition: nil)
        }

        let videoResults = videoScoreMap.map { (videoId, data) in
            SearchResult(id: videoId, score: data.score, localIdentifier: data.localId, creationDate: data.date, isVideo: true, bestFramePosition: data.framePosition)
        }

        var allResults = photoResults + videoResults
        // Sort by score descending. For near-identical scores (within 1%),
        // prefer more recent results. SigLIP2's sigmoid loss produces a narrow
        // score range, so the tolerance must be tight to preserve relevance ranking.
        allResults.sort { a, b in
            let scoreDiff = abs(a.score - b.score)
            let maxScore = max(a.score, b.score)
            if maxScore > 0 && scoreDiff / maxScore < 0.01 {
                return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }
            return a.score > b.score
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
                let dateStr = photoDates[index].map { dateFormatter.string(from: $0) } ?? "no-date"
                let passed = candidateMask[index]
                logger.info("[NearMiss] score=\(String(format: "%.4f", score)) passedFilter=\(passed) date=\(dateStr)")
            }
            if vCount > 0 {
                let topVideo = videoScoreMap.sorted { $0.value.score > $1.value.score }.prefix(3)
                if topVideo.isEmpty {
                    logger.info("[NearMiss] No video frames passed threshold")
                }
                for (vid, data) in topVideo {
                    logger.info("[NearMiss] VIDEO score=\(String(format: "%.4f", data.score)) vid=\(vid.prefix(12)) frame=\(String(format: "%.2f", data.framePosition))")
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
            var candidateResults: [SearchResult] = []
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                candidateResults.append(SearchResult(
                    id: ids[i],
                    score: scores[i],
                    localIdentifier: localIds[i],
                    creationDate: photoDates[i],
                    isVideo: false,
                    bestFramePosition: nil
                ))
            }

            // Also include video candidates if they passed filters
            let fallbackVideoResults = videoScoreMap
                .filter { $0.value.score > 0 }
                .map { (videoId, data) in
                    SearchResult(id: videoId, score: data.score,
                        localIdentifier: data.localId, creationDate: data.date,
                        isVideo: true, bestFramePosition: data.framePosition)
                }
            candidateResults.append(contentsOf: fallbackVideoResults)

            // Sort by CLIP score descending. All candidates get ranked by visual
            // relevance, even those below the normal threshold.
            candidateResults.sort { $0.score > $1.score }
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
                .filter { $0.element > 0 && candidateMask[$0.offset] }
                .prefix(SearchConfig.topK)
                .map { (index, score) in
                    SearchResult(id: ids[index], score: score, localIdentifier: localIds[index],
                                 creationDate: photoDates[index], isVideo: false, bestFramePosition: nil)
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
        candidateMask: [Bool], ids: [String], localIds: [String],
        dates: [Date?], count: Int,
        vIds: [String], vLocalIds: [String], vDates: [Date?],
        vLats: [Double?], vLons: [Double?], vPositions: [Double?],
        vCities: [String?], vStates: [String?], vCountries: [String?], vLocNames: [String?],
        vCount: Int,
        hints: QueryHints, targetLoc: CLLocation?
    ) -> SearchResponse {
        var results: [SearchResult] = []

        for i in 0..<count {
            guard candidateMask[i] else { continue }
            results.append(SearchResult(
                id: ids[i], score: 1.0, localIdentifier: localIds[i],
                creationDate: dates[i], isVideo: false, bestFramePosition: nil
            ))
        }

        let locationMatcher: LocationMatcher.Matcher? = hints.locationHint.map { locationQuery in
            LocationMatcher.makeMatcher(
                queryLower: locationQuery.lowercased(),
                locality: hints.locationLocality,
                adminArea: hints.locationAdminArea,
                country: hints.locationCountryName
            )
        }

        var seenVideoIds = Set<String>()
        for i in 0..<vCount {
            guard videoPassesHardFilters(
                index: i, hints: hints, locationMatcher: locationMatcher, targetLoc: targetLoc,
                dates: vDates, latitudes: vLats, longitudes: vLons,
                cities: vCities, states: vStates, countries: vCountries, names: vLocNames
            ) else { continue }
            let vid = vIds[i]
            guard !seenVideoIds.contains(vid) else { continue }
            seenVideoIds.insert(vid)
            results.append(SearchResult(
                id: vid, score: 1.0, localIdentifier: vLocalIds[i],
                creationDate: vDates[i], isVideo: true, bestFramePosition: vPositions[i]
            ))
        }

        results.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }

        #if DEBUG
        logger.info("[SearchEngine] locationOnlyResults: returning \(results.count) results")
        #endif

        return SearchResponse(results: results, fallbackResults: [], filtersApplied: nil)
    }

    private func computeFallbackResults(
        text: String, ids: [String], localIds: [String],
        dates: [Date?], matrix: [Float16], count: Int,
        gpuSearch: SimilaritySearching?
    ) -> [SearchResult] {
        guard let queryEmbedding = try? encodeQuery(text: text) else { return [] }
        let scores = scoreEmbeddings(queryEmbedding: queryEmbedding, matrix: matrix, count: count, gpuSearch: gpuSearch)

        let sorted = scores.enumerated().sorted { $0.element > $1.element }
        return sorted.prefix(5)
            .filter { $0.element >= minimumScoreThreshold }
            .map { (index, score) in
                SearchResult(id: ids[index], score: score, localIdentifier: localIds[index],
                             creationDate: dates[index], isVideo: false, bestFramePosition: nil)
            }
    }

    // MARK: - Similar Photos

    func findSimilar(photoId: String, topK: Int = 50) -> [SearchResult] {
        let snapshot: SearchIndexSnapshot = {
            lock.lock()
            defer { lock.unlock() }
            return indexSnapshot
        }()
        let photos = snapshot.photos
        let ids = photos.ids
        let localIds = photos.localIdentifiers
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
            SearchResult(id: ids[index], score: score, localIdentifier: localIds[index], creationDate: photoDates[index], isVideo: false, bestFramePosition: nil)
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

    private func videoPassesHardFilters(
        index: Int,
        hints: QueryHints,
        locationMatcher: LocationMatcher.Matcher?,
        targetLoc: CLLocation?,
        dates: [Date?],
        latitudes: [Double?],
        longitudes: [Double?],
        cities: [String?],
        states: [String?],
        countries: [String?],
        names: [String?]
    ) -> Bool {
        if let dateRange = hints.dateRange {
            guard let videoDate = dates[index], videoDate >= dateRange.start && videoDate <= dateRange.end else {
                return false
            }
        }

        return mediaPassesLocationFilter(
            hints: hints,
            locationMatcher: locationMatcher,
            targetLoc: targetLoc,
            latitude: latitudes[index],
            longitude: longitudes[index],
            city: cities[index],
            state: states[index],
            country: countries[index],
            name: names[index]
        )
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
