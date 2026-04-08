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

class SearchEngine {
    private var photoIds: [String] = []
    private var localIdentifiers: [String] = []
    private var dates: [Date?] = []
    private var latitudes: [Double?] = []
    private var longitudes: [Double?] = []
    private var ocrTexts: [String?] = []
    private var embeddingMatrix: [Float16] = []
    private var photoCount: Int = 0

    // Video frame embeddings
    private var videoIds: [String] = []
    private var videoLocalIds: [String] = []
    private var videoDates: [Date?] = []
    private var videoLatitudes: [Double?] = []
    private var videoLongitudes: [Double?] = []
    private var videoFramePositions: [Double] = []
    private var videoEmbeddingMatrix: [Float16] = []
    private var videoFrameCount: Int = 0
    private var uniqueVideoCount: Int = 0

    private let embeddingDim = EmbeddingConfig.dimensions
    private let minimumScoreThreshold = SearchConfig.minimumScoreThreshold

    static let maxRecommendedPhotos = IndexingConfig.largeLibraryThreshold

    // GPU-accelerated search
    private var gpuSearch: GPUSimilaritySearch?
    private var gpuVideoSearch: GPUSimilaritySearch?

    private let textEncoder: TextEncoder
    private let database: DatabaseProtocol
    private let lock = NSLock()
    private let geocoder = CLGeocoder()

    init(textEncoder: TextEncoder, database: DatabaseProtocol = AppDatabase.shared) {
        self.textEncoder = textEncoder
        self.database = database
        #if !targetEnvironment(simulator)
        self.gpuSearch = GPUSimilaritySearch()
        self.gpuVideoSearch = GPUSimilaritySearch()
        #endif
    }

    func loadIndex() throws {
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif

        let data = try database.loadAllEmbeddings()
        let videoData = try database.loadAllVideoEmbeddings()

        lock.lock()
        defer { lock.unlock() }
        self.photoIds = data.ids
        self.localIdentifiers = data.localIdentifiers
        self.dates = data.dates
        self.latitudes = data.latitudes
        self.longitudes = data.longitudes
        self.ocrTexts = data.ocrTexts
        self.embeddingMatrix = data.embeddings
        self.photoCount = data.ids.count

        self.videoIds = videoData.videoIds
        self.videoLocalIds = videoData.localIdentifiers
        self.videoDates = videoData.dates
        self.videoLatitudes = videoData.latitudes
        self.videoLongitudes = videoData.longitudes
        self.videoFramePositions = videoData.framePositions
        self.videoEmbeddingMatrix = videoData.embeddings
        self.videoFrameCount = videoData.videoIds.count
        self.uniqueVideoCount = Set(videoData.videoIds).count

        // Build GPU search indices
        gpuSearch?.buildIndex(embeddings: data.embeddings, count: data.ids.count)
        if videoData.videoIds.count > 0 {
            gpuVideoSearch?.buildIndex(embeddings: videoData.embeddings, count: videoData.videoIds.count)
        }

        let count = data.ids.count
        let memoryMB = (count + videoFrameCount) * embeddingDim * MemoryLayout<Float16>.size / 1_048_576
        #if DEBUG
        if count > Self.maxRecommendedPhotos {
            logger.warning("Large library: \(count) photos, ~\(memoryMB)MB.")
        }
        #endif

        #if DEBUG
        let vFrameCount = self.videoFrameCount
        logger.info("[SearchEngine] Index loaded: \(count) photos, \(vFrameCount) video frames, ~\(memoryMB)MB in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart))s")
        #endif
    }

    var estimatedMemoryUsage: Int {
        (photoCount + videoFrameCount) * embeddingDim * MemoryLayout<Float16>.size
    }

    var isLargeLibrary: Bool {
        (photoCount + videoFrameCount) > Self.maxRecommendedPhotos
    }

    var indexSize: Int { photoCount }
    var videoSize: Int { uniqueVideoCount }
    var totalSize: Int { photoCount + uniqueVideoCount }

    var isIndexLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return photoCount > 0
    }

    func dropIndex() {
        lock.lock()
        defer { lock.unlock() }
        photoIds.removeAll()
        localIdentifiers.removeAll()
        dates.removeAll()
        latitudes.removeAll()
        longitudes.removeAll()
        ocrTexts.removeAll()
        embeddingMatrix.removeAll()
        photoCount = 0
        videoIds.removeAll()
        videoLocalIds.removeAll()
        videoDates.removeAll()
        videoLatitudes.removeAll()
        videoLongitudes.removeAll()
        videoFramePositions.removeAll()
        videoEmbeddingMatrix.removeAll()
        videoFrameCount = 0
        uniqueVideoCount = 0
        gpuSearch = nil
        gpuVideoSearch = nil
        #if DEBUG
        logger.info("[SearchEngine] Index dropped due to memory pressure")
        #endif
    }

    // MARK: - Search

    func search(query: String, topK: Int = 50) async throws -> SearchResponse {
        if !isIndexLoaded {
            try loadIndex()
        }

        #if DEBUG
        let searchStart = CFAbsoluteTimeGetCurrent()
        logger.info("[SearchEngine] Search query: '\(query)', topK: \(topK)")
        #endif

        var hints = await QueryParser.parse(query: query)

        // Geocode location hint if present — ONLY the extracted location name, never modified
        if let locationName = hints.locationHint {
            if let geo = await geocodeLocation(locationName) {
                hints.locationCoordinate = (geo.lat, geo.lon)
                hints.locationRadiusKm = geo.radiusKm
                #if DEBUG
                logger.info("[SearchEngine] Geocoded '\(locationName)' → \(geo.lat), \(geo.lon), radius: \(geo.radiusKm)km")
                #endif
            }
        }

        let response = try hybridSearch(hints: hints, topK: topK)

        #if DEBUG
        logger.info("[SearchEngine] Search completed in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - searchStart))s, \(response.results.count) results")
        #endif

        return response
    }


    func hybridSearch(hints: QueryHints, topK: Int = 50) throws -> SearchResponse {
        let (ids, localIds, photoDates, photoLats, photoLons, photoOcrTexts, matrix, count,
             vIds, vLocalIds, vDates, vLats, vLons, vPositions, vMatrix, vCount): ([String], [String], [Date?], [Double?], [Double?], [String?], [Float16], Int, [String], [String], [Date?], [Double?], [Double?], [Double], [Float16], Int) = {
            lock.lock()
            defer { lock.unlock() }
            return (photoIds, localIdentifiers, dates, latitudes, longitudes, ocrTexts, embeddingMatrix, photoCount,
                    videoIds, videoLocalIds, videoDates, videoLatitudes, videoLongitudes, videoFramePositions, videoEmbeddingMatrix, videoFrameCount)
        }()

        guard count > 0 else { return SearchResponse(results: [], fallbackResults: [], filtersApplied: nil) }

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

        // Location filter: discard photos outside the radius AND photos without GPS.
        // When the user specifies a location, we need GPS proof that the photo was there.
        var targetLoc: CLLocation?
        if let coord = hints.locationCoordinate, let radiusKm = hints.locationRadiusKm {
            let target = CLLocation(latitude: coord.lat, longitude: coord.lon)
            targetLoc = target
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                if let lat = photoLats[i], let lon = photoLons[i] {
                    let distanceKm = target.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
                    if distanceKm > radiusKm {
                        candidateMask[i] = false
                    }
                } else {
                    // No GPS data — can't verify location, exclude
                    candidateMask[i] = false
                }
            }
        }

        let candidateCount = candidateMask.filter { $0 }.count

        #if DEBUG
        logger.info("[SearchEngine] Filter: \(candidateCount)/\(count) photos passed hard filters")
        if hints.locationCoordinate != nil {
            let withGPS = (0..<count).filter { photoLats[$0] != nil && photoLons[$0] != nil }.count
            let passedDate = hints.dateRange == nil ? count : (0..<count).filter { candidateMask[$0] || photoLats[$0] == nil }.count
            logger.info("[SearchEngine] GPS stats: \(withGPS)/\(count) photos have GPS, \(candidateCount) passed all filters")
        }
        #endif

        // =====================================================================
        // PHASE 2: BRANCH ON QUERY INTENT
        // =====================================================================

        let filtersActive = hints.dateRange != nil || hints.locationCoordinate != nil

        // Empty candidate set with active filters → provide fallback
        if candidateCount == 0 && filtersActive {
            let fallbackResults = hints.hasVisualQuery
                ? computeFallbackResults(text: hints.textQuery, ids: ids, localIds: localIds, dates: photoDates, count: count)
                : []
            let summary = FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: [], fallbackResults: fallbackResults, filtersApplied: summary)
        }

        // No visual content → return all candidates sorted by date
        if !hints.hasVisualQuery {
            return locationOnlyResults(
                candidateMask: candidateMask, ids: ids, localIds: localIds,
                dates: photoDates, count: count,
                vIds: vIds, vLocalIds: vLocalIds, vDates: vDates,
                vLats: vLats, vLons: vLons, vPositions: vPositions, vCount: vCount,
                hints: hints
            )
        }

        // =====================================================================
        // PHASE 3: CLIP SCORING — score all, then mask out non-candidates
        // =====================================================================

        let queryEmbedding = try encodeQueryWithFusion(text: hints.textQuery)

        var scores: [Float]
        if let gpuScores = gpuSearch?.search(queryEmbedding: queryEmbedding), gpuScores.count == count {
            scores = gpuScores
        } else {
            scores = [Float](repeating: 0, count: count)
            var rowBuf = [Float](repeating: 0, count: embeddingDim)
            for i in 0..<count {
                let offset = i * embeddingDim
                for j in 0..<embeddingDim { rowBuf[j] = Float(matrix[offset + j]) }
                var dot: Float = 0
                vDSP_dotpr(queryEmbedding, 1, rowBuf, 1, &dot, vDSP_Length(embeddingDim))
                scores[i] = dot
            }
        }

        // Zero out non-candidates
        for i in 0..<count {
            if !candidateMask[i] {
                scores[i] = -1.0
            }
        }

        // =====================================================================
        // PHASE 4: SOFT BOOSTS — only on candidates that passed hard filters
        // =====================================================================

        // Location proximity boost
        if let target = targetLoc, let radiusKm = hints.locationRadiusKm {
            for i in 0..<count {
                guard candidateMask[i] else { continue }
                guard let lat = photoLats[i], let lon = photoLons[i] else { continue }
                let distanceKm = target.distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
                if distanceKm < radiusKm * 0.1 {
                    scores[i] *= SearchConfig.locationCloseBoost
                } else if distanceKm < radiusKm * 0.3 {
                    scores[i] *= SearchConfig.locationNearBoost
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
                if inRange { scores[i] *= SearchConfig.timeOfDayMatchBoost }
            }
        }

        // Negative term penalty
        for negTerm in hints.negativeTerms {
            let negEmbedding = try textEncoder.encode(text: "a photo of " + negTerm)
            if let negScores = gpuSearch?.search(queryEmbedding: negEmbedding), negScores.count == count {
                for i in 0..<count {
                    guard candidateMask[i] else { continue }
                    scores[i] -= negScores[i] * SearchConfig.negativeTermWeight
                }
            } else {
                var rowBuf = [Float](repeating: 0, count: embeddingDim)
                for i in 0..<count {
                    guard candidateMask[i] else { continue }
                    let offset = i * embeddingDim
                    for j in 0..<embeddingDim { rowBuf[j] = Float(matrix[offset + j]) }
                    var negDot: Float = 0
                    vDSP_dotpr(negEmbedding, 1, rowBuf, 1, &negDot, vDSP_Length(embeddingDim))
                    scores[i] -= negDot * SearchConfig.negativeTermWeight
                }
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

        // =====================================================================
        // PHASE 5: VIDEO SCORING
        // =====================================================================

        var videoScoreMap: [String: (score: Float, localId: String, date: Date?, framePosition: Double)] = [:]

        if vCount > 0 {
            let videoScores: [Float]
            if let gpuVScores = gpuVideoSearch?.search(queryEmbedding: queryEmbedding), gpuVScores.count == vCount {
                videoScores = gpuVScores
            } else {
                var cpuScores = [Float](repeating: 0, count: vCount)
                var vRowBuf = [Float](repeating: 0, count: embeddingDim)
                for i in 0..<vCount {
                    let offset = i * embeddingDim
                    for j in 0..<embeddingDim { vRowBuf[j] = Float(vMatrix[offset + j]) }
                    var dot: Float = 0
                    vDSP_dotpr(queryEmbedding, 1, vRowBuf, 1, &dot, vDSP_Length(embeddingDim))
                    cpuScores[i] = dot
                }
                videoScores = cpuScores
            }

            for i in 0..<vCount {
                var frameScore = videoScores[i]
                guard frameScore >= minimumScoreThreshold else { continue }

                if let dateRange = hints.dateRange {
                    guard let videoDate = vDates[i], videoDate >= dateRange.start && videoDate <= dateRange.end else { continue }
                }
                if let coord = hints.locationCoordinate, let radiusKm = hints.locationRadiusKm {
                    guard let lat = vLats[i], let lon = vLons[i] else { continue }
                    let distanceKm = CLLocation(latitude: coord.lat, longitude: coord.lon)
                        .distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
                    guard distanceKm <= radiusKm else { continue }
                }

                for negTerm in hints.negativeTerms {
                    let negEmbedding = try textEncoder.encode(text: "a photo of " + negTerm)
                    if let negScores = gpuVideoSearch?.search(queryEmbedding: negEmbedding), negScores.count == vCount {
                        frameScore -= negScores[i] * SearchConfig.negativeTermWeight
                    }
                }

                if let timeRange = hints.timeOfDayHours, let videoDate = vDates[i] {
                    let hour = Calendar.current.component(.hour, from: videoDate)
                    let inRange = timeRange.start <= timeRange.end
                        ? hour >= timeRange.start && hour < timeRange.end
                        : hour >= timeRange.start || hour < timeRange.end
                    if inRange { frameScore *= SearchConfig.timeOfDayMatchBoost }
                }

                guard frameScore >= minimumScoreThreshold else { continue }

                let vid = vIds[i]
                if let existing = videoScoreMap[vid] {
                    if frameScore > existing.score {
                        videoScoreMap[vid] = (frameScore, vLocalIds[i], vDates[i], vPositions[i])
                    }
                } else {
                    videoScoreMap[vid] = (frameScore, vLocalIds[i], vDates[i], vPositions[i])
                }
            }
        }

        // =====================================================================
        // PHASE 6: RANK AND RETURN
        // =====================================================================

        let sorted = scores.enumerated().sorted { $0.element > $1.element }
        let photoResults = sorted.prefix(topK).filter { $0.element >= minimumScoreThreshold }.map { (index, score) in
            SearchResult(id: ids[index], score: score, localIdentifier: localIds[index], creationDate: photoDates[index], isVideo: false, bestFramePosition: nil)
        }

        let videoResults = videoScoreMap.map { (videoId, data) in
            SearchResult(id: videoId, score: data.score, localIdentifier: data.localId, creationDate: data.date, isVideo: true, bestFramePosition: data.framePosition)
        }

        var allResults = photoResults + videoResults
        allResults.sort { a, b in
            let scoreDiff = abs(a.score - b.score)
            let maxScore = max(a.score, b.score)
            if maxScore > 0 && scoreDiff / maxScore < 0.05 {
                return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }
            return a.score > b.score
        }
        let finalResults = Array(allResults.prefix(topK))

        #if DEBUG
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        for (rank, r) in finalResults.enumerated() {
            let dateStr = r.creationDate.map { dateFormatter.string(from: $0) } ?? "no-date"
            let type = r.isVideo ? "VIDEO" : "PHOTO"
            logger.info("[Result #\(rank + 1)] \(type) id=\(r.id) local=\(r.localIdentifier) score=\(String(format: "%.3f", r.score)) date=\(dateStr)")
        }
        if finalResults.isEmpty {
            let nearMisses = sorted.prefix(5)
            for (index, score) in nearMisses {
                let dateStr = photoDates[index].map { dateFormatter.string(from: $0) } ?? "no-date"
                let hasGPS = photoLats[index] != nil
                let passed = candidateMask[index]
                logger.info("[NearMiss] id=\(ids[index]) score=\(String(format: "%.3f", score)) date=\(dateStr) gps=\(hasGPS) passedFilter=\(passed)")
            }
        }
        #endif

        // Sparse CLIP fallback: merge location results when CLIP matched very few candidates
        // Threshold: fewer than 5 results AND less than 10% of candidates matched
        let clipMatchedTooFew = finalResults.count < 5 && candidateCount > 0
            && Double(finalResults.count) / Double(candidateCount) < 0.1
        if clipMatchedTooFew && filtersActive {
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
            let merged = Array(candidateResults.prefix(topK))

            let summary = FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            return SearchResponse(results: merged, fallbackResults: [], filtersApplied: summary)
        }

        let appliedSummary: FilterSummary? = filtersActive
            ? FilterSummary(
                dateDescription: hints.dateRange.map { formatDateRange($0) },
                locationDescription: hints.locationHint,
                visualQuery: hints.textQuery
            )
            : nil
        return SearchResponse(results: finalResults, fallbackResults: [], filtersApplied: appliedSummary)
    }

    // MARK: - Helper Methods

    private func locationOnlyResults(
        candidateMask: [Bool], ids: [String], localIds: [String],
        dates: [Date?], count: Int,
        vIds: [String], vLocalIds: [String], vDates: [Date?],
        vLats: [Double?], vLons: [Double?], vPositions: [Double], vCount: Int,
        hints: QueryHints
    ) -> SearchResponse {
        var results: [SearchResult] = []

        for i in 0..<count {
            guard candidateMask[i] else { continue }
            results.append(SearchResult(
                id: ids[i], score: 1.0, localIdentifier: localIds[i],
                creationDate: dates[i], isVideo: false, bestFramePosition: nil
            ))
        }

        var seenVideoIds = Set<String>()
        for i in 0..<vCount {
            if let dateRange = hints.dateRange {
                guard let videoDate = vDates[i], videoDate >= dateRange.start && videoDate <= dateRange.end else { continue }
            }
            if let coord = hints.locationCoordinate, let radiusKm = hints.locationRadiusKm {
                guard let lat = vLats[i], let lon = vLons[i] else { continue }
                let distKm = CLLocation(latitude: coord.lat, longitude: coord.lon)
                    .distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
                guard distKm <= radiusKm else { continue }
            }
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
        logger.info("[SearchEngine] locationOnlyResults: \(results.count) total before cap, returning \(min(results.count, 500))")
        #endif

        let capped = Array(results.prefix(500))

        return SearchResponse(results: capped, fallbackResults: [], filtersApplied: nil)
    }

    private func computeFallbackResults(
        text: String, ids: [String], localIds: [String],
        dates: [Date?], count: Int
    ) -> [SearchResult] {
        guard let queryEmbedding = try? encodeQueryWithFusion(text: text) else { return [] }
        guard let gpuScores = gpuSearch?.search(queryEmbedding: queryEmbedding), gpuScores.count == count else { return [] }

        let sorted = gpuScores.enumerated().sorted { $0.element > $1.element }
        return sorted.prefix(5)
            .filter { $0.element >= minimumScoreThreshold }
            .map { (index, score) in
                SearchResult(id: ids[index], score: score, localIdentifier: localIds[index],
                             creationDate: dates[index], isVideo: false, bestFramePosition: nil)
            }
    }

    // MARK: - Similar Photos

    func findSimilar(photoId: String, topK: Int = 50) -> [SearchResult] {
        let (ids, localIds, photoDates, matrix, count) = {
            lock.lock()
            defer { lock.unlock() }
            return (photoIds, localIdentifiers, dates, embeddingMatrix, photoCount)
        }()

        guard let sourceIndex = ids.firstIndex(of: photoId) else { return [] }

        // Extract source embedding as Float32 for GPU query
        let offset = sourceIndex * embeddingDim
        var sourceEmbedding = [Float](repeating: 0, count: embeddingDim)
        for j in 0..<embeddingDim { sourceEmbedding[j] = Float(matrix[offset + j]) }

        // GPU search with CPU fallback
        var scores: [Float]
        if let gpuScores = gpuSearch?.search(queryEmbedding: sourceEmbedding), gpuScores.count == count {
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

    private func geocodeLocation(_ name: String) async -> (lat: Double, lon: Double, radiusKm: Double)? {
        await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(name) { placemarks, error in
                guard let placemark = placemarks?.first, let location = placemark.location else {
                    continuation.resume(returning: nil)
                    return
                }

                // Determine minimum radius from placemark hierarchy
                let hierarchyRadiusKm: Double
                if placemark.subLocality != nil {
                    hierarchyRadiusKm = 10.0     // Neighborhood
                } else if placemark.locality != nil {
                    hierarchyRadiusKm = 50.0     // City
                } else if placemark.subAdministrativeArea != nil {
                    hierarchyRadiusKm = 100.0    // County/district
                } else if placemark.administrativeArea != nil {
                    hierarchyRadiusKm = 300.0    // State/province/island
                } else if placemark.country != nil {
                    hierarchyRadiusKm = 800.0    // Country
                } else {
                    hierarchyRadiusKm = 100.0    // Unknown
                }

                // Use CLCircularRegion if available, but never go below the hierarchy minimum
                var radiusKm: Double
                if let region = placemark.region as? CLCircularRegion {
                    radiusKm = max(region.radius / 1000.0, hierarchyRadiusKm)
                } else {
                    radiusKm = hierarchyRadiusKm
                }

                continuation.resume(returning: (location.coordinate.latitude, location.coordinate.longitude, radiusKm))
            }
        }
    }

    private func encodeQueryWithFusion(text: String) throws -> [Float] {
        let variations = [text, "a photo of " + text, "a picture of " + text]

        var sum = [Float](repeating: 0, count: embeddingDim)
        for variation in variations {
            let emb = try textEncoder.encode(text: variation)
            for i in 0..<embeddingDim { sum[i] += emb[i] }
        }

        var count = Float(variations.count)
        vDSP_vsdiv(sum, 1, &count, &sum, 1, vDSP_Length(embeddingDim))

        sum.l2Normalize()

        return sum
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
