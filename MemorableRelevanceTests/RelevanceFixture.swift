import CryptoKit
import Foundation
import UIKit
@testable import Memorable

struct RelevanceManifest: Decodable {
    let schemaVersion: Int
    let selection: String
    let dataset: Dataset
    let entries: [Entry]

    struct Dataset: Decodable, Equatable {
        let repository: String
        let revision: String
        let config: String
        let split: String
        let license: String
    }

    struct Entry: Decodable {
        let rowIndex: Int
        let rowId: Int
        let questionId: String
        let query: String
        let expectedAssetIds: [String]
        let cocoUrl: URL
        let licenseCode: Int
        let pinnedRevision: String
        let localFilename: String
        let imageSha256: String
    }
}

struct RelevanceBaseline: Decodable {
    let schemaVersion: Int
    let environment: String
    let datasetRevision: String
    let tolerance: Double
    let aggregate: Metrics
    let queries: [Query]

    struct Metrics: Decodable {
        let recallAt10: Double
        let recallAt50: Double
        let meanReciprocalRank: Double
        let fallbackQueryRate: Double
    }

    struct Query: Decodable {
        let questionId: String
        let recallAt10: Double
        let recallAt50: Double
        let reciprocalRank: Double
    }
}

enum RelevanceFixtureError: LocalizedError, Equatable {
    case missingResource(String)
    case invalidManifest(String)
    case missingImage(String)
    case imageHashMismatch(filename: String, expected: String, actual: String)
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let filename):
            return "Relevance fixture resource is missing: \(filename)"
        case .invalidManifest(let reason):
            return "Relevance fixture manifest is invalid: \(reason)"
        case .missingImage(let filename):
            return "Relevance image cache is missing \(filename). Run `python3 scripts/relevance.py run`."
        case .imageHashMismatch(let filename, let expected, let actual):
            return "Relevance image cache integrity failed for \(filename): expected \(expected), got \(actual)."
        case .unreadableImage(let filename):
            return "Relevance fixture is not a readable image: \(filename)"
        }
    }
}

enum RelevanceFixtureLoader {
    static let expectedDataset = RelevanceManifest.Dataset(
        repository: "LIME-DATA/COCO-Caption2017",
        revision: "b14474455722b8c56eb7cdeb3f6be76fca1bba7a",
        config: "default",
        split: "train",
        license: "apache-2.0"
    )

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var imagesRoot: URL {
        repositoryRoot.appendingPathComponent(".relevance-cache/coco-caption-2017/images")
    }

    static func loadManifest(bundle: Bundle) throws -> RelevanceManifest {
        guard let url = bundle.url(forResource: "coco-caption-2017", withExtension: "json") else {
            throw RelevanceFixtureError.missingResource("coco-caption-2017.json")
        }
        let manifest = try JSONDecoder().decode(RelevanceManifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1 else {
            throw RelevanceFixtureError.invalidManifest("unsupported schema version \(manifest.schemaVersion)")
        }
        guard manifest.dataset == expectedDataset else {
            throw RelevanceFixtureError.invalidManifest("dataset source does not match the approved pin")
        }
        guard manifest.entries.count == 50 else {
            throw RelevanceFixtureError.invalidManifest("expected 50 rows, got \(manifest.entries.count)")
        }
        guard manifest.entries.map(\.rowIndex) == Array(0..<50) else {
            throw RelevanceFixtureError.invalidManifest("row selection must be the deterministic range 0...49")
        }
        guard Set(manifest.entries.map(\.questionId)).count == manifest.entries.count else {
            throw RelevanceFixtureError.invalidManifest("question identifiers must be unique")
        }
        for entry in manifest.entries {
            guard entry.pinnedRevision == expectedDataset.revision else {
                throw RelevanceFixtureError.invalidManifest("row \(entry.rowIndex) has the wrong revision")
            }
            guard entry.expectedAssetIds == [URL(fileURLWithPath: entry.questionId).deletingPathExtension().lastPathComponent] else {
                throw RelevanceFixtureError.invalidManifest("row \(entry.rowIndex) has unexpected asset identifiers")
            }
            guard entry.localFilename == entry.questionId else {
                throw RelevanceFixtureError.invalidManifest("row \(entry.rowIndex) filename does not match question_id")
            }
        }
        return manifest
    }

    static func loadBaseline(bundle: Bundle) throws -> RelevanceBaseline {
        guard let url = bundle.url(forResource: "simulator-baseline", withExtension: "json") else {
            throw RelevanceFixtureError.missingResource("simulator-baseline.json")
        }
        return try JSONDecoder().decode(RelevanceBaseline.self, from: Data(contentsOf: url))
    }

    static func loadImage(
        for entry: RelevanceManifest.Entry,
        imagesRoot: URL = imagesRoot,
        perturbation: String? = nil
    ) throws -> UIImage {
        let url = imagesRoot.appendingPathComponent(entry.localFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RelevanceFixtureError.missingImage(entry.localFilename)
        }
        let data = try Data(contentsOf: url)
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualHash == entry.imageSha256 else {
            throw RelevanceFixtureError.imageHashMismatch(
                filename: entry.localFilename,
                expected: entry.imageSha256,
                actual: actualHash
            )
        }
        guard let image = UIImage(data: data) else {
            throw RelevanceFixtureError.unreadableImage(entry.localFilename)
        }
        return perturbation == "vertical-flip" ? verticallyFlipped(image) : image
    }

    private static func verticallyFlipped(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            context.cgContext.translateBy(x: 0, y: image.size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

struct RelevanceQueryMetrics {
    let questionId: String
    let recallAt10: Double
    let recallAt50: Double
    let reciprocalRank: Double
    let usedFallback: Bool
}

struct RelevanceMetrics {
    let queries: [RelevanceQueryMetrics]

    var recallAt10: Double { average(queries.map(\.recallAt10)) }
    var recallAt50: Double { average(queries.map(\.recallAt50)) }
    var meanReciprocalRank: Double { average(queries.map(\.reciprocalRank)) }
    var fallbackQueryRate: Double {
        average(queries.map { $0.usedFallback ? 1 : 0 })
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

final class RelevanceFixtureDatabase: DatabaseProtocol {
    private let manifest: RelevanceManifest
    private let embeddings: [[Float16]]

    init(manifest: RelevanceManifest, embeddings: [[Float16]]) {
        self.manifest = manifest
        self.embeddings = embeddings
    }

    func indexedCount() throws -> Int { manifest.entries.count }
    func videoIndexedCount() throws -> Int { 0 }
    func indexedMediaCounts() throws -> IndexedMediaCounts {
        IndexedMediaCounts(photos: manifest.entries.count, videos: 0)
    }
    func photoLibraryIndexedMediaCounts() throws -> IndexedMediaCounts {
        IndexedMediaCounts(photos: manifest.entries.count, videos: 0)
    }
    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers {
        IndexedMediaIdentifiers(
            photos: Set(manifest.entries.flatMap(\.expectedAssetIds)),
            videos: []
        )
    }

    func loadAllEmbeddings() throws -> MediaIndex {
        guard manifest.entries.count == embeddings.count else {
            throw SearchEngineError.corruptedIndex
        }
        var index = MediaIndex(kind: .photo)
        for (entry, embedding) in zip(manifest.entries, embeddings) {
            try index.append(
                MediaIndex.Row(
                    id: entry.expectedAssetIds[0],
                    localIdentifier: entry.questionId,
                    date: nil,
                    latitude: nil,
                    longitude: nil,
                    city: nil,
                    state: nil,
                    country: nil,
                    locationName: nil,
                    details: .photo(ocrText: nil, sceneLabels: nil)
                ),
                embedding: embedding
            )
        }
        return index
    }

    func loadEmbeddingsForDuplicateScan(limit: Int) throws -> MediaIndex {
        try loadAllEmbeddings()
    }

    func loadAllVideoEmbeddings() throws -> MediaIndex {
        MediaIndex(kind: .videoFrame)
    }

    func insertPhoto(_ photo: IndexedPhoto) throws {}
    func insertPhotos(_ photos: [IndexedPhoto], completingRequiredRebuild: Bool) throws -> Bool { false }
    func isIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedIdentifiers() throws -> Set<String> { [] }
    func allIndexedFilePaths() throws -> Set<String> { [] }
    func resetIndexedMedia() throws {}
    func deletePhoto(localIdentifier: String) throws {}
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {}
    func fetchRandomPhoto(sharp: Bool) throws -> SlideshowPhoto? { nil }
    func photosNeedingEnrichment(limit: Int) throws -> [PhotoEnrichmentCandidate] { [] }
    func photosNeedingEnrichmentCount() throws -> Int { 0 }
    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws {}
    func indexRebuildRequired() throws -> Bool { false }
    func clearIndexRebuildRequired() throws {}
    func insertVideo(_ video: IndexedVideo, _ frames: [IndexedVideoFrame], completingRequiredRebuild: Bool) throws -> Bool { false }
    func isVideoIndexed(localIdentifier: String) throws -> Bool { false }
    func allIndexedVideoIdentifiers() throws -> Set<String> { [] }
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws {}
    func trimToLimit(_ limit: Int) throws {}
    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult {
        FreeTierReconciliationResult(
            retainedMediaCount: min(manifest.entries.count, max(0, limit)),
            didTrimMedia: manifest.entries.count > max(0, limit)
        )
    }
    func photosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func videosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)] { [] }
    func geocodingCounts() throws -> GeocodingCounts {
        GeocodingCounts(totalWithGPS: 0, remaining: 0, indexedPhotos: manifest.entries.count, indexedVideos: 0)
    }
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws {}
    func insertSource(_ source: PhotoSource) throws {}
    func listSources() throws -> [PhotoSource] { [] }
    func deleteSource(_ id: String) throws {}
    func updateSourceStats(_ id: String, photoCount: Int) throws {}
    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])] { [] }
    func addSearchHistory(_ query: String) throws {}
    func loadSearchHistory() throws -> [String] { [] }
    func clearSearchHistory() throws {}
    func removeSearchHistory(at index: Int) throws {}
    func loadSmartAlbums() throws -> [SmartAlbum] { [] }
    func saveSmartAlbum(_ album: SmartAlbum) throws {}
    func deleteSmartAlbum(id: String) throws {}
}
