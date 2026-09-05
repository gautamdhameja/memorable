import Foundation
import GRDB
import Accelerate

// MARK: - Constants

enum EmbeddingConfig {
    static let dimensions = 768
    static let bytesPerEmbedding = dimensions * MemoryLayout<Float16>.size // 1536
}

// MARK: - Photo Records

struct IndexedPhoto: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var localIdentifier: String
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var pixelWidth: Int
    var pixelHeight: Int
    var embedding: Data
    var indexedAt: Date
    var ocrText: String?
    var sharpnessScore: Double?
    var sourceId: String = PhotoSourceType.photokit.rawValue
    var filePath: String?
    var locationCity: String?
    var locationState: String?
    var locationCountry: String?
    var locationName: String?
    var sceneLabels: String?
    var isScreenshot: Bool = false
    var isDocumentImage: Bool = false
    var enrichmentComplete: Bool = false

    static let databaseTableName = "indexed_photos"

    var searchResult: SearchResult {
        SearchResult(
            id: id,
            score: 1,
            localIdentifier: localIdentifier,
            creationDate: creationDate,
            isVideo: false,
            bestFramePosition: nil,
            sourceId: sourceId,
            filePath: filePath
        )
    }
}

struct PhotoEnrichmentCandidate: Equatable, Sendable {
    let localIdentifier: String
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceId: String
    let filePath: String?
}

struct PhotoEnrichmentUpdate: Equatable, Sendable {
    let localIdentifier: String
    let ocrText: String?
    let sharpnessScore: Double?
    let sceneLabels: String?
    var isDocumentImage: Bool = false
    var outcome: PhotoEnrichmentOutcome = .completed
}

struct IndexedPhotoReference: Identifiable, Sendable {
    let id: String
    let localIdentifier: String
    let creationDate: Date?
    let sourceId: String
    let filePath: String?
    let pixelWidth: Int
    let pixelHeight: Int

    var searchResult: SearchResult {
        SearchResult(
            id: id,
            score: 1,
            localIdentifier: localIdentifier,
            creationDate: creationDate,
            isVideo: false,
            bestFramePosition: nil,
            sourceId: sourceId,
            filePath: filePath
        )
    }
}

struct OnThisDaySummary: Sendable {
    let heroPhoto: IndexedPhotoReference
    let mostRecentYear: Int
    let yearCount: Int
    let photoCount: Int
}

struct SlideshowPhoto: Identifiable, Sendable {
    let id: String
    let localIdentifier: String
    let creationDate: Date?
    let embedding: Data
    let sourceId: String
    let filePath: String?
    let requiresContentValidation: Bool

    init(
        id: String,
        localIdentifier: String,
        creationDate: Date?,
        embedding: Data,
        sourceId: String,
        filePath: String?,
        requiresContentValidation: Bool = false
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.embedding = embedding
        self.sourceId = sourceId
        self.filePath = filePath
        self.requiresContentValidation = requiresContentValidation
    }

    var searchResult: SearchResult {
        SearchResult(
            id: id,
            score: 1,
            localIdentifier: localIdentifier,
            creationDate: creationDate,
            isVideo: false,
            bestFramePosition: nil,
            sourceId: sourceId,
            filePath: filePath
        )
    }
}

enum MemoryContentPolicy {
    static let minimumDocumentCharacters = 120
    static let minimumDocumentWords = 18

    private static let screenshotDimensions: Set<String> = [
        "1170x2532", "2532x1170",
        "1179x2556", "2556x1179",
        "1290x2796", "2796x1290",
        "1284x2778", "2778x1284",
        "1125x2436", "2436x1125",
        "1242x2688", "2688x1242",
        "1080x1920", "1920x1080",
        "750x1334", "1334x750",
        "1668x2388", "2388x1668",
        "2048x2732", "2732x2048",
    ]

    private static let documentLabels: Set<String> = [
        "document", "receipt", "invoice", "form", "menu", "newspaper",
        "book page", "web page", "presentation", "spreadsheet",
    ]

    static func isLikelyScreenshotDimensions(width: Int, height: Int) -> Bool {
        screenshotDimensions.contains("\(width)x\(height)")
    }

    static func isDocumentImage(ocrText: String?, sceneLabels: String?) -> Bool {
        let labels = SceneClassifier.stringToLabels(sceneLabels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if labels.contains(where: { documentLabels.contains($0) }) {
            return true
        }

        guard let ocrText else { return false }
        let words = ocrText.split(whereSeparator: \Character.isWhitespace)
        let alphanumericCount = ocrText.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { count += 1 }
        }
        return words.count >= minimumDocumentWords
            && alphanumericCount >= minimumDocumentCharacters
    }

    static func isEligible(
        isMarkedScreenshot: Bool,
        isMarkedDocument: Bool = false,
        pixelWidth: Int,
        pixelHeight: Int,
        ocrText: String?,
        sceneLabels: String?
    ) -> Bool {
        !isMarkedScreenshot
            && !isMarkedDocument
            && !isLikelyScreenshotDimensions(width: pixelWidth, height: pixelHeight)
            && !isDocumentImage(ocrText: ocrText, sceneLabels: sceneLabels)
    }
}

struct MemoryDuplicateFilter {
    private var retainedEmbeddings: [[Float]] = []

    var retainedCount: Int { retainedEmbeddings.count }

    mutating func accepts(
        _ embeddingData: Data,
        threshold: Float = SearchConfig.duplicateThreshold
    ) -> Bool {
        guard let embedding = embeddingData.validatedFloat16Embedding() else { return false }
        let values = embedding.map(Float.init)

        for retained in retainedEmbeddings {
            var similarity: Float = 0
            vDSP_dotpr(
                values,
                1,
                retained,
                1,
                &similarity,
                vDSP_Length(values.count)
            )
            if similarity >= threshold { return false }
        }

        retainedEmbeddings.append(values)
        return true
    }

    mutating func reset() {
        retainedEmbeddings.removeAll(keepingCapacity: true)
    }
}

enum PhotoEnrichmentOutcome: Equatable, Sendable {
    case completed
    case loadFailed(at: Date)
}

struct PhotoSource: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: String
    var type: String // Raw value of PhotoSourceType
    var path: String?
    var name: String
    var addedAt: Date
    var lastIndexedAt: Date?
    var photoCount: Int

    static let databaseTableName = "photo_sources"
}

// MARK: - Video Records

struct IndexedVideo: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var localIdentifier: String
    var creationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var frameCount: Int
    var indexedAt: Date
    var sourceId: String = PhotoSourceType.photokit.rawValue
    var locationCity: String?
    var locationState: String?
    var locationCountry: String?
    var locationName: String?

    static let databaseTableName = "indexed_videos"
}

struct IndexedVideoFrame: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var videoId: String
    var framePosition: Double
    var embedding: Data
    var indexedAt: Date

    static let databaseTableName = "indexed_video_frames"
}

// MARK: - View Models

struct SearchResult: Identifiable, Equatable {
    let id: String
    let score: Float
    let localIdentifier: String
    let creationDate: Date?
    let isVideo: Bool
    let bestFramePosition: Double?
    let sourceId: String
    let filePath: String?
    let isTextMatch: Bool
    var supportsFindSimilar: Bool { !isVideo }

    init(
        id: String,
        score: Float,
        localIdentifier: String,
        creationDate: Date?,
        isVideo: Bool,
        bestFramePosition: Double?,
        sourceId: String = PhotoSourceType.photokit.rawValue,
        filePath: String? = nil,
        isTextMatch: Bool = false
    ) {
        self.id = id
        self.score = score
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.isVideo = isVideo
        self.bestFramePosition = bestFramePosition
        self.sourceId = sourceId
        self.filePath = filePath
        self.isTextMatch = isTextMatch
    }
}

struct SearchResultGroup: Identifiable {
    let id: String
    let label: String
    let results: [SearchResult]
}

struct SmartAlbum: Codable, Identifiable {
    var id: String
    var name: String
    var query: String
    var createdAt: Date
}

enum SmartAlbumPolicy {
    static let maximumAlbums = 100
    static let maximumNameCharacters = 100

    static func boundedName(_ value: String) -> String {
        let withoutControls = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let bounded = QueryInputPolicy.bounded(
            withoutControls.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumUnicodeScalars: maximumNameCharacters,
            maximumUTF8Bytes: maximumNameCharacters * 4
        )
        return bounded.isEmpty ? "Smart album" : bounded
    }
}

enum IndexingPhase: Equatable {
    case idle
    case photos
    case videos
    case enrichment
}

struct IndexingProgress {
    var total: Int
    var completed: Int
    var isRunning: Bool
    var phase: IndexingPhase = .idle
    var photosComplete: Bool = false
    var searchableCount: Int = 0
    var rateBaselineCompleted: Int = 0
    var phaseStartedAt: Date = Date()

    var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total) * 100
    }

    var itemsPerSecond: Double? {
        let timedCompleted = max(0, completed - rateBaselineCompleted)
        guard timedCompleted >= IndexingConfig.progressEstimateMinCompleted else { return nil }
        let elapsed = Date().timeIntervalSince(phaseStartedAt)
        guard elapsed > 0 else { return nil }
        return Double(timedCompleted) / elapsed
    }

    var estimatedSecondsRemaining: TimeInterval? {
        guard total > completed, let itemsPerSecond, itemsPerSecond > 0 else { return nil }
        return Double(total - completed) / itemsPerSecond
    }
}

// MARK: - Helpers

extension Array where Element == Float {
    func toFloat16Data() -> Data {
        var data = Data(count: count * MemoryLayout<Float16>.size)
        data.withUnsafeMutableBytes { buffer in
            let ptr = buffer.bindMemory(to: Float16.self)
            for i in 0..<count {
                ptr[i] = Float16(self[i])
            }
        }
        return data
    }
}

extension Data {
    /// Decodes one persisted embedding without relying on the database blob's
    /// alignment. Reject malformed lengths before any typed memory access.
    func validatedFloat16Embedding() -> [Float16]? {
        guard count == EmbeddingConfig.bytesPerEmbedding else { return nil }
        return withUnsafeBytes { rawBuffer in
            var squaredNorm: Float = 0
            var embedding: [Float16] = []
            embedding.reserveCapacity(EmbeddingConfig.dimensions)
            for index in 0..<EmbeddingConfig.dimensions {
                let value = rawBuffer.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float16>.size,
                    as: Float16.self
                )
                guard value.isFinite else { return nil }
                let floatValue = Float(value)
                squaredNorm += floatValue * floatValue
                guard squaredNorm.isFinite else { return nil }
                embedding.append(value)
            }
            guard squaredNorm > 0 else { return nil }
            return embedding
        }
    }
}
