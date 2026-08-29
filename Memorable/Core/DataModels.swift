import Foundation
import GRDB

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
    var outcome: PhotoEnrichmentOutcome = .completed
}

struct IndexedPhotoReference: Identifiable, Sendable {
    let id: String
    let localIdentifier: String
    let creationDate: Date?
    let sourceId: String
    let filePath: String?

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

struct SlideshowPhoto: Identifiable, Sendable {
    let id: String
    let localIdentifier: String
    let creationDate: Date?
    let embedding: Data
    let sourceId: String
    let filePath: String?

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
    var supportsFindSimilar: Bool { !isVideo }

    init(
        id: String,
        score: Float,
        localIdentifier: String,
        creationDate: Date?,
        isVideo: Bool,
        bestFramePosition: Double?,
        sourceId: String = PhotoSourceType.photokit.rawValue,
        filePath: String? = nil
    ) {
        self.id = id
        self.score = score
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.isVideo = isVideo
        self.bestFramePosition = bestFramePosition
        self.sourceId = sourceId
        self.filePath = filePath
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
