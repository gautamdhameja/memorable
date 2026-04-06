import Foundation
import GRDB

// MARK: - Constants

enum EmbeddingConfig {
    static let dimensions = 768
    static let bytesPerEmbedding = dimensions * MemoryLayout<Float16>.size // 1536
}

// MARK: - Photo Records

struct IndexedPhoto: Codable, FetchableRecord, PersistableRecord {
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

    static let databaseTableName = "indexed_photos"
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

enum IndexingPhase {
    case idle
    case photos
    case videos
}

struct IndexingProgress {
    var total: Int
    var completed: Int
    var isRunning: Bool
    var phase: IndexingPhase = .idle
    var photosComplete: Bool = false

    var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total) * 100
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
