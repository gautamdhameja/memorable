import Foundation
import Accelerate
import CoreLocation

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
    private var videoFramePositions: [Double] = []
    private var videoEmbeddingMatrix: [Float16] = []
    private var videoFrameCount: Int = 0
    private var uniqueVideoCount: Int = 0

    private let embeddingDim = EmbeddingConfig.dimensions
    private let minimumScoreThreshold: Float = 0.18

    static let maxRecommendedPhotos = 100_000

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

    func search(query: String, topK: Int = 50) async throws -> [SearchResult] {
        if !isIndexLoaded {
            try loadIndex()
        }

        #if DEBUG
        let searchStart = CFAbsoluteTimeGetCurrent()
        logger.info("[SearchEngine] Search query: '\(query)', topK: \(topK)")
        #endif

        var hints = await QueryParser.parse(query: query)

        // Geocode location hint if present
        if let locationName = hints.locationHint {
            hints.locationCoordinate = await geocodeLocation(locationName)
        }

        let results = try hybridSearch(hints: hints, topK: topK)

        #if DEBUG
        logger.info("[SearchEngine] Search completed in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - searchStart))s, \(results.count) results")
        #endif

        return results
    }


    func hybridSearch(hints: QueryHints, topK: Int = 50) throws -> [SearchResult] {
        let (ids, localIds, photoDates, photoLats, photoLons, photoOcrTexts, matrix, count,
             vIds, vLocalIds, vDates, vPositions, vMatrix, vCount): ([String], [String], [Date?], [Double?], [Double?], [String?], [Float16], Int, [String], [String], [Date?], [Double], [Float16], Int) = {
            lock.lock()
            defer { lock.unlock() }
            return (photoIds, localIdentifiers, dates, latitudes, longitudes, ocrTexts, embeddingMatrix, photoCount,
                    videoIds, videoLocalIds, videoDates, videoFramePositions, videoEmbeddingMatrix, videoFrameCount)
        }()

        guard count > 0 else { return [] }

        // Step 1: Multi-prompt fusion encoding
        let queryEmbedding = try encodeQueryWithFusion(text: hints.textQuery)

        // Step 2: Compute dot products (GPU with CPU fallback)
        var scores: [Float]
        if let gpuScores = gpuSearch?.search(queryEmbedding: queryEmbedding), gpuScores.count == count {
            scores = gpuScores
            #if DEBUG
            logger.info("[SearchEngine] Using GPU path for \(count) photos")
            #endif
        } else {
            #if DEBUG
            logger.info("[SearchEngine] Using CPU fallback for \(count) photos")
            #endif
            // CPU fallback — convert Float16 rows to Float32 for vDSP
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

        // Save raw CLIP scores before boosts — used for visual relevance threshold
        let rawScores = scores

        // Step 3: Date boost — when user specifies a time range, strongly prefer matches
        if let dateRange = hints.dateRange {
            for i in 0..<count {
                guard let photoDate = photoDates[i] else { continue }
                if photoDate >= dateRange.start && photoDate <= dateRange.end {
                    scores[i] *= 1.5       // Strong boost for in-range
                } else {
                    // Graduated penalty based on distance from the range
                    let distStart = abs(photoDate.timeIntervalSince(dateRange.start)) / 86400
                    let distEnd = abs(photoDate.timeIntervalSince(dateRange.end)) / 86400
                    let daysDiff = min(distStart, distEnd)

                    if daysDiff < 7 {
                        scores[i] *= 0.9   // Within a week — mild penalty
                    } else if daysDiff < 30 {
                        scores[i] *= 0.6   // Within a month — moderate penalty
                    } else if daysDiff < 180 {
                        scores[i] *= 0.4   // Within 6 months — heavy penalty
                    } else {
                        scores[i] *= 0.2   // Older than 6 months — near-elimination
                    }
                }
            }
        }

        // Step 3b: Time-of-day boost
        if let timeRange = hints.timeOfDayHours {
            let calendar = Calendar.current
            for i in 0..<count {
                guard let photoDate = photoDates[i] else { continue }
                let hour = calendar.component(.hour, from: photoDate)

                let inRange: Bool
                if timeRange.start <= timeRange.end {
                    inRange = hour >= timeRange.start && hour < timeRange.end
                } else {
                    // Wraps midnight, e.g. (20, 4)
                    inRange = hour >= timeRange.start || hour < timeRange.end
                }

                if inRange {
                    scores[i] *= 1.3
                } else {
                    scores[i] *= 0.7
                }
            }
        }

        // Step 4: Location proximity boost
        if let target = hints.locationCoordinate {
            let targetLoc = CLLocation(latitude: target.lat, longitude: target.lon)
            for i in 0..<count {
                guard let lat = photoLats[i], let lon = photoLons[i] else { continue }
                let photoLoc = CLLocation(latitude: lat, longitude: lon)
                let distanceKm = targetLoc.distance(from: photoLoc) / 1000.0

                if distanceKm < 5 {
                    scores[i] *= 1.5       // Within 5km — strong boost
                } else if distanceKm < 25 {
                    scores[i] *= 1.3       // Within 25km — moderate boost
                } else if distanceKm < 100 {
                    scores[i] *= 1.1       // Within 100km — slight boost
                }
                // No penalty for far away — visual similarity still matters
            }
        }

        // Step 5: Negative term penalty (use GPU if available)
        for negTerm in hints.negativeTerms {
            let negEmbedding = try textEncoder.encode(text: "a photo of " + negTerm)
            if let negScores = gpuSearch?.search(queryEmbedding: negEmbedding), negScores.count == count {
                for i in 0..<count { scores[i] -= negScores[i] * 0.3 }
            } else {
                var rowBuf = [Float](repeating: 0, count: embeddingDim)
                for i in 0..<count {
                    let offset = i * embeddingDim
                    for j in 0..<embeddingDim { rowBuf[j] = Float(matrix[offset + j]) }
                    var negDot: Float = 0
                    vDSP_dotpr(negEmbedding, 1, rowBuf, 1, &negDot, vDSP_Length(embeddingDim))
                    scores[i] -= negDot * 0.3
                }
            }
        }

        // Step 6: OCR text boost for screenshots
        let queryWords = hints.textQuery.lowercased().split(separator: " ").map(String.init)
        if !queryWords.isEmpty {
            for i in 0..<count {
                guard let ocrTextOpt = photoOcrTexts[safe: i], let ocrText = ocrTextOpt else { continue }
                let text = ocrText.lowercased()
                let matchCount = queryWords.filter { text.contains($0) }.count
                if matchCount > 0 {
                    let ocrBoost: Float = 0.15 * Float(matchCount) / Float(queryWords.count)
                    scores[i] += ocrBoost
                }
            }
        }

        // Step 7: Compute video frame scores (GPU with CPU fallback)
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

            // Negative term penalty for videos
            var adjustedVideoScores = videoScores
            for negTerm in hints.negativeTerms {
                let negEmbedding = try textEncoder.encode(text: "a photo of " + negTerm)
                if let negScores = gpuVideoSearch?.search(queryEmbedding: negEmbedding), negScores.count == vCount {
                    for i in 0..<vCount { adjustedVideoScores[i] -= negScores[i] * 0.3 }
                } else {
                    var vRowBuf = [Float](repeating: 0, count: embeddingDim)
                    for i in 0..<vCount {
                        let offset = i * embeddingDim
                        for j in 0..<embeddingDim { vRowBuf[j] = Float(vMatrix[offset + j]) }
                        var negDot: Float = 0
                        vDSP_dotpr(negEmbedding, 1, vRowBuf, 1, &negDot, vDSP_Length(embeddingDim))
                        adjustedVideoScores[i] -= negDot * 0.3
                    }
                }
            }

            let rawVideoScores = adjustedVideoScores
            let calendar = Calendar.current

            for i in 0..<vCount {
                let rawScore = rawVideoScores[i]
                // Skip frames that don't visually match the query
                guard rawScore >= minimumScoreThreshold else { continue }

                var frameScore = rawScore

                // Date boost
                if let dateRange = hints.dateRange, let videoDate = vDates[i] {
                    if videoDate >= dateRange.start && videoDate <= dateRange.end {
                        frameScore *= 1.5
                    } else {
                        let distStart = abs(videoDate.timeIntervalSince(dateRange.start)) / 86400
                        let distEnd = abs(videoDate.timeIntervalSince(dateRange.end)) / 86400
                        let daysDiff = min(distStart, distEnd)
                        if daysDiff < 7 { frameScore *= 0.9 }
                        else if daysDiff < 30 { frameScore *= 0.6 }
                        else if daysDiff < 180 { frameScore *= 0.4 }
                        else { frameScore *= 0.2 }
                    }
                }

                // Time-of-day boost
                if let timeRange = hints.timeOfDayHours, let videoDate = vDates[i] {
                    let hour = calendar.component(.hour, from: videoDate)
                    let inRange: Bool
                    if timeRange.start <= timeRange.end {
                        inRange = hour >= timeRange.start && hour < timeRange.end
                    } else {
                        inRange = hour >= timeRange.start || hour < timeRange.end
                    }
                    frameScore *= inRange ? 1.3 : 0.7
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

        // Step 8: Combine photo + video results, sort, threshold, return
        // Filter on raw CLIP score first (visual relevance), then on boosted score (contextual relevance)
        let sorted = scores.enumerated().sorted { $0.element > $1.element }
        let photoResults = sorted.prefix(topK).filter { rawScores[$0.offset] >= minimumScoreThreshold && $0.element >= minimumScoreThreshold }.map { (index, score) in
            SearchResult(id: ids[index], score: score, localIdentifier: localIds[index], creationDate: photoDates[index], isVideo: false, bestFramePosition: nil)
        }

        let videoResults = videoScoreMap.map { (videoId, data) in
            SearchResult(id: videoId, score: data.score, localIdentifier: data.localId, creationDate: data.date, isVideo: true, bestFramePosition: data.framePosition)
        }

        var allResults = photoResults + videoResults
        allResults.sort { $0.score > $1.score }
        let finalResults = Array(allResults.filter { $0.score >= minimumScoreThreshold }.prefix(topK))

        return finalResults
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

    private func geocodeLocation(_ name: String) async -> (lat: Double, lon: Double)? {
        await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(name) { placemarks, error in
                if let location = placemarks?.first?.location {
                    continuation.resume(returning: (location.coordinate.latitude, location.coordinate.longitude))
                } else {
                    continuation.resume(returning: nil)
                }
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
