import Foundation
import GRDB

enum PersistedMetadataTextPolicy {
    static let maximumOCRCharacters = OCRTextPolicy.maximumCharacters
    static let maximumSceneLabelCharacters = 1_024
    static let maximumLocationCharacters = 256

    static func bounded(_ value: String?, maximumCharacters: Int) -> String? {
        value.map {
            QueryInputPolicy.bounded(
                $0,
                maximumUnicodeScalars: maximumCharacters,
                maximumUTF8Bytes: maximumCharacters * 4
            )
        }
    }
}
import os

// MARK: - Embedding Index

enum SearchEngineError: LocalizedError, Equatable {
    /// Persisted index columns or embedding rows are malformed. Refuse to load.
    case corruptedIndex
    /// A model returned an embedding with an unsafe shape.
    case invalidEmbedding
    /// Background indexing may intentionally defer the query model until the
    /// app returns to the foreground and search becomes interactive.
    case textEncoderUnavailable

    var errorDescription: String? {
        switch self {
        case .corruptedIndex:
            return "The search index is damaged. Rebuild it from More, then try again."
        case .invalidEmbedding:
            return "Search found inconsistent local data. Rebuild the index from More, then try again."
        case .textEncoderUnavailable:
            return "Search is still getting ready. Try again in a moment."
        }
    }
}

enum SearchIndexLimits {
    /// Searchable embeddings are compact Float16 rows, but metadata and video
    /// frames add overhead. Reserve a conservative fraction of physical memory
    /// and clamp it so older A14-class phones remain safe.
    static let minimumResidentMediaItems = 8_000
    static let maximumResidentMediaItems = 50_000
    static let estimatedBytesPerResidentMedia = 4_096

    static func adaptiveResidentMediaItems(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let minimumBudget = UInt64(minimumResidentMediaItems * estimatedBytesPerResidentMedia)
        let maximumBudget = UInt64(maximumResidentMediaItems * estimatedBytesPerResidentMedia)
        let deviceBudget = max(minimumBudget, min(maximumBudget, physicalMemory / 64))
        return max(
            minimumResidentMediaItems,
            min(maximumResidentMediaItems, Int(deviceBudget) / estimatedBytesPerResidentMedia)
        )
    }

    static var residentMediaItems: Int { adaptiveResidentMediaItems() }
    /// Media descriptors fetched per whole-library database scan. Frames for a
    /// selected video are loaded together, so a page never splits one video.
    static let databasePageMediaItems = 512
    static let maximumMediaItems = minimumResidentMediaItems
    static let maximumPhotoRows = minimumResidentMediaItems
    static let maximumVideoFramesPerMedia = 5
    static let maximumVideoFrameRows = minimumResidentMediaItems * maximumVideoFramesPerMedia
    static let maximumTotalRows = maximumVideoFrameRows
}

/// Columnar searchable media with a single mutation boundary. The embedding
/// matrix stays flat for the scoring hot path; every append supplies one
/// complete metadata row plus exactly one embedding row.
struct MediaIndex: Sendable {
    enum Kind: Equatable, Sendable {
        case photo
        case videoFrame
    }

    enum RowDetails: Sendable {
        case photo(ocrText: String?, sceneLabels: String?)
        case videoFrame(position: Double)
    }

    struct Row: Sendable {
        let id: String
        let localIdentifier: String
        let sourceId: String
        let filePath: String?
        let date: Date?
        let latitude: Double?
        let longitude: Double?
        let city: String?
        let state: String?
        let country: String?
        let locationName: String?
        let details: RowDetails

        init(
            id: String,
            localIdentifier: String,
            sourceId: String = PhotoSourceType.photokit.rawValue,
            filePath: String? = nil,
            date: Date?,
            latitude: Double?,
            longitude: Double?,
            city: String?,
            state: String?,
            country: String?,
            locationName: String?,
            details: RowDetails
        ) {
            self.id = id
            self.localIdentifier = localIdentifier
            self.sourceId = sourceId
            self.filePath = filePath
            self.date = date
            self.latitude = latitude
            self.longitude = longitude
            self.city = city
            self.state = state
            self.country = country
            self.locationName = locationName
            self.details = details
        }
    }

    let kind: Kind
    private(set) var ids: [String]
    private(set) var localIdentifiers: [String]
    private(set) var sourceIds: [String]
    private(set) var filePaths: [String?]
    private(set) var dates: [Date?]
    private(set) var latitudes: [Double?]
    private(set) var longitudes: [Double?]
    private(set) var ocrTexts: [String?]
    private(set) var locationCities: [String?]
    private(set) var locationStates: [String?]
    private(set) var locationCountries: [String?]
    private(set) var locationNames: [String?]
    private(set) var sceneLabels: [String?]
    private(set) var framePositions: [Double?]
    private(set) var embeddings: [Float16]

    var count: Int { ids.count }
    var uniqueIDCount: Int { Set(ids).count }

    init(kind: Kind) {
        self.kind = kind
        ids = []
        localIdentifiers = []
        sourceIds = []
        filePaths = []
        dates = []
        latitudes = []
        longitudes = []
        ocrTexts = []
        locationCities = []
        locationStates = []
        locationCountries = []
        locationNames = []
        sceneLabels = []
        framePositions = []
        embeddings = []
    }

    init(
        kind: Kind,
        ids: [String],
        localIdentifiers: [String],
        sourceIds: [String]? = nil,
        filePaths: [String?]? = nil,
        dates: [Date?],
        latitudes: [Double?],
        longitudes: [Double?],
        ocrTexts: [String?],
        locationCities: [String?],
        locationStates: [String?],
        locationCountries: [String?],
        locationNames: [String?],
        sceneLabels: [String?],
        framePositions: [Double?],
        embeddings: [Float16]
    ) throws {
        let count = ids.count
        let resolvedSourceIds = sourceIds
            ?? [String](repeating: PhotoSourceType.photokit.rawValue, count: count)
        let resolvedFilePaths = filePaths ?? [String?](repeating: nil, count: count)
        let metadataCounts = [
            localIdentifiers.count, resolvedSourceIds.count, resolvedFilePaths.count,
            dates.count, latitudes.count,
            longitudes.count, ocrTexts.count, locationCities.count,
            locationStates.count, locationCountries.count, locationNames.count,
            sceneLabels.count, framePositions.count
        ]
        let (expectedEmbeddingCount, overflow) = count.multipliedReportingOverflow(
            by: EmbeddingConfig.dimensions
        )
        guard !overflow,
              metadataCounts.allSatisfy({ $0 == count }),
              embeddings.count == expectedEmbeddingCount,
              zip(latitudes, longitudes).allSatisfy({
                  LocationCoordinatePolicy.isValidOrAbsent(
                      latitude: $0.0,
                      longitude: $0.1
                  )
              }) else {
            throw SearchEngineError.corruptedIndex
        }

        switch kind {
        case .photo:
            guard framePositions.allSatisfy({ $0 == nil }) else {
                throw SearchEngineError.corruptedIndex
            }
        case .videoFrame:
            guard framePositions.allSatisfy({ position in
                      guard let position else { return false }
                      return position.isFinite && (0...1).contains(position)
                  }),
                  ocrTexts.allSatisfy({ $0 == nil }),
                  sceneLabels.allSatisfy({ $0 == nil }) else {
                throw SearchEngineError.corruptedIndex
            }
        }

        self.kind = kind
        self.ids = ids
        self.localIdentifiers = localIdentifiers
        self.sourceIds = resolvedSourceIds
        self.filePaths = resolvedFilePaths
        self.dates = dates
        self.latitudes = latitudes
        self.longitudes = longitudes
        self.ocrTexts = ocrTexts
        self.locationCities = locationCities
        self.locationStates = locationStates
        self.locationCountries = locationCountries
        self.locationNames = locationNames
        self.sceneLabels = sceneLabels
        self.framePositions = framePositions
        self.embeddings = embeddings
    }

    mutating func append(_ row: Row, embedding: UnsafeBufferPointer<Float16>) throws {
        guard embedding.count == EmbeddingConfig.dimensions else {
            throw SearchEngineError.corruptedIndex
        }
        guard LocationCoordinatePolicy.isValidOrAbsent(
            latitude: row.latitude,
            longitude: row.longitude
        ) else {
            throw SearchEngineError.corruptedIndex
        }

        let ocrText: String?
        let sceneLabel: String?
        let framePosition: Double?
        switch (kind, row.details) {
        case let (.photo, .photo(rowOCRText, rowSceneLabels)):
            ocrText = rowOCRText
            sceneLabel = rowSceneLabels
            framePosition = nil
        case let (.videoFrame, .videoFrame(position)):
            guard position.isFinite, (0...1).contains(position) else {
                throw SearchEngineError.corruptedIndex
            }
            ocrText = nil
            sceneLabel = nil
            framePosition = position
        default:
            throw SearchEngineError.corruptedIndex
        }

        ids.append(row.id)
        localIdentifiers.append(row.localIdentifier)
        sourceIds.append(row.sourceId)
        filePaths.append(row.filePath)
        dates.append(row.date)
        latitudes.append(row.latitude)
        longitudes.append(row.longitude)
        ocrTexts.append(PersistedMetadataTextPolicy.bounded(
            ocrText,
            maximumCharacters: PersistedMetadataTextPolicy.maximumOCRCharacters
        ))
        locationCities.append(PersistedMetadataTextPolicy.bounded(
            row.city,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        ))
        locationStates.append(PersistedMetadataTextPolicy.bounded(
            row.state,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        ))
        locationCountries.append(PersistedMetadataTextPolicy.bounded(
            row.country,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        ))
        locationNames.append(PersistedMetadataTextPolicy.bounded(
            row.locationName,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        ))
        sceneLabels.append(PersistedMetadataTextPolicy.bounded(
            sceneLabel,
            maximumCharacters: PersistedMetadataTextPolicy.maximumSceneLabelCharacters
        ))
        framePositions.append(framePosition)
        embeddings.append(contentsOf: embedding)
    }

    mutating func append(_ row: Row, embedding: [Float16]) throws {
        try embedding.withUnsafeBufferPointer { buffer in
            try append(row, embedding: buffer)
        }
    }

    mutating func reserveCapacity(_ rowCount: Int) {
        ids.reserveCapacity(rowCount)
        localIdentifiers.reserveCapacity(rowCount)
        sourceIds.reserveCapacity(rowCount)
        filePaths.reserveCapacity(rowCount)
        dates.reserveCapacity(rowCount)
        latitudes.reserveCapacity(rowCount)
        longitudes.reserveCapacity(rowCount)
        ocrTexts.reserveCapacity(rowCount)
        locationCities.reserveCapacity(rowCount)
        locationStates.reserveCapacity(rowCount)
        locationCountries.reserveCapacity(rowCount)
        locationNames.reserveCapacity(rowCount)
        sceneLabels.reserveCapacity(rowCount)
        framePositions.reserveCapacity(rowCount)
        embeddings.reserveCapacity(rowCount * EmbeddingConfig.dimensions)
    }
}

// MARK: - Database Protocol

struct IndexedMediaCounts {
    let photos: Int
    let videos: Int

    var total: Int { photos + videos }
}

struct SearchIndexContentRevision: Codable, Equatable, Sendable {
    let photoCount: Int
    let videoCount: Int
    let videoFrameCount: Int
    let latestPhotoRowID: Int64
    let latestVideoRowID: Int64
    let latestVideoFrameRowID: Int64
    let latestPhotoID: String?
    let latestVideoID: String?
    let latestVideoFrameID: String?
    let latestPhotoIndexedAt: Date?
    let latestVideoIndexedAt: Date?
    let latestVideoFrameIndexedAt: Date?
}

struct IndexedMediaIdentifiers {
    let photos: Set<String>
    let videos: Set<String>
}

struct IndexedMediaIdentifierPage: Sendable {
    let photos: [String]
    let videos: [String]
    let nextCursor: SearchMediaPageCursor?
}

struct SearchMediaPageCursor: Hashable, Sendable {
    let creationDate: Date?
    let id: String
    let mediaType: SearchMediaPageKind
}

enum SearchMediaPageKind: String, Equatable, Sendable {
    case photo
    case video
}

struct MediaPageDescriptorQuery {
    let sql: String
    let arguments: StatementArguments
}

struct SearchMediaPage: Sendable {
    let photos: MediaIndex
    let videos: MediaIndex
    let mediaCount: Int
    let totalPhotoCount: Int
    let totalVideoCount: Int
    let nextCursor: SearchMediaPageCursor?

    var totalMediaCount: Int { totalPhotoCount + totalVideoCount }
}

struct GeocodingCounts {
    let totalWithGPS: Int
    let remaining: Int
    let indexedPhotos: Int
    let indexedVideos: Int
}

enum DatabaseCapabilityError: LocalizedError, Equatable {
    case unavailable
    case indexingUnavailableInFallback

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Local search storage is unavailable. Close and reopen Memorable, then try again."
        case .indexingUnavailableInFallback:
            return "Memorable cannot update the search index right now. Close and reopen the app, then try again."
        }
    }
}

/// Internal diagnostic state retained by the test-only throwing initializer.
/// Its associated strings can contain storage details and must never be shown
/// directly in user-facing copy.
enum DatabaseInitializationError: Error {
    case persistentAndFallbackFailed(persistent: String, fallback: String)
}

/// Preserves the database API when storage initialization fails. Calls fail
/// with a recoverable error instead of terminating the process.
final class RecoverableDatabaseQueue: @unchecked Sendable {
    private let queue: DatabaseQueue?

    init(_ queue: DatabaseQueue?) {
        self.queue = queue
    }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        guard let queue else { throw DatabaseCapabilityError.unavailable }
        return try queue.read(value)
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        guard let queue else { throw DatabaseCapabilityError.unavailable }
        return try queue.write(updates)
    }

    func rawQueue() throws -> DatabaseQueue {
        guard let queue else { throw DatabaseCapabilityError.unavailable }
        return queue
    }
}

struct IndexedMediaVersion: Equatable, Sendable {
    let id: String
    let indexedAt: Date
}

enum IndexedMediaFreshness {
    enum Selection: Equatable {
        case skip
        case insert
        case replace
    }

    static func needsRefresh(modifiedAt: Date?, indexedAt: Date) -> Bool {
        modifiedAt.map { $0 > indexedAt } ?? false
    }

    static func selection(
        indexed: IndexedMediaVersion?, modifiedAt: Date?, forced: Bool, canAddMedia: Bool
    ) -> Selection {
        guard let indexed else { return canAddMedia ? .insert : .skip }
        return forced || needsRefresh(modifiedAt: modifiedAt, indexedAt: indexed.indexedAt)
            ? .replace : .skip
    }
}

protocol DatabaseProtocol: Sendable {
    var allowsIndexingWrites: Bool { get }
    // Photos
    func insertPhoto(_ photo: IndexedPhoto) throws
    /// Returns true when the write atomically completes a pending required rebuild.
    @discardableResult
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool
    func isIndexed(localIdentifier: String) throws -> Bool
    func existingPhotoIdentifiers(in localIdentifiers: [String]) throws -> Set<String>
    func indexedPhotoVersions(in localIdentifiers: [String]) throws -> [String: IndexedMediaVersion]
    func indexedFolderVersions(in filePaths: [String], sourceId: String) throws -> [String: IndexedMediaVersion]
    func replacePhoto(_ photo: IndexedPhoto) throws
    func markPhotoScreenshots(localIdentifiers: Set<String>) throws
    func allIndexedIdentifiers() throws -> Set<String>
    func loadIndexedPhotoIdentifierPage(after: String?, limit: Int) throws -> [String]
    func existingFilePaths(in filePaths: [String], sourceId: String) throws -> Set<String>
    func indexedCount() throws -> Int
    func hasIndexedPhotos() throws -> Bool
    func indexedMediaCounts() throws -> IndexedMediaCounts
    func searchIndexContentRevision() throws -> SearchIndexContentRevision
    func photoLibraryIndexedMediaCounts() throws -> IndexedMediaCounts
    /// Returns at most `SearchIndexLimits.maximumMediaItems` newest identifiers
    /// across photos and videos, including for oversized legacy stores.
    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers
    func loadIndexedMediaIdentifierPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> IndexedMediaIdentifierPage
    /// Loads the deterministic, newest searchable photo window, bounded by
    /// `SearchIndexLimits.maximumPhotoRows` even for oversized legacy stores.
    func loadAllEmbeddings() throws -> MediaIndex
    func loadSearchMediaPage(after cursor: SearchMediaPageCursor?, limit: Int) throws -> SearchMediaPage
    func loadPhotoEmbedding(id: String) throws -> MediaIndex?
    func loadEmbeddingsForDuplicateScan(limit: Int) throws -> MediaIndex
    func resetIndexedMedia() throws
    func deletePhoto(localIdentifier: String) throws
    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws
    func fetchRandomPhoto(sharp: Bool) throws -> SlideshowPhoto?
    func distinctMemoryPhotoIDs(in ids: [String]) throws -> Set<String>
    func photosNeedingEnrichment(limit: Int) throws -> [PhotoEnrichmentCandidate]
    func photosNeedingEnrichmentCount() throws -> Int
    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws
    func indexRebuildRequired() throws -> Bool
    func clearIndexRebuildRequired() throws

    // Videos
    /// Persists video metadata and frames together. Returns true when the write
    /// atomically completes a pending required rebuild.
    @discardableResult
    func insertVideo(
        _ video: IndexedVideo,
        _ frames: [IndexedVideoFrame],
        completingRequiredRebuild: Bool
    ) throws -> Bool
    func isVideoIndexed(localIdentifier: String) throws -> Bool
    func existingVideoIdentifiers(in localIdentifiers: [String]) throws -> Set<String>
    func indexedVideoVersions(in localIdentifiers: [String]) throws -> [String: IndexedMediaVersion]
    func replaceVideo(_ video: IndexedVideo, frames: [IndexedVideoFrame]) throws
    func videoIndexedCount() throws -> Int
    /// Loads the deterministic, newest searchable video-frame window, bounded
    /// by `SearchIndexLimits.maximumVideoFrameRows`.
    func loadAllVideoEmbeddings() throws -> MediaIndex
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws
    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult
    func reconcileFreeTier(
        _ limit: Int,
        whilePermitted: @escaping @Sendable () -> Bool
    ) throws -> FreeTierReconciliationResult

    // Location backfill
    func photosNeedingLocationBackfill(
        after localIdentifier: String?,
        limit: Int
    ) throws -> [(localIdentifier: String, lat: Double, lon: Double)]
    func videosNeedingLocationBackfill(
        after localIdentifier: String?,
        limit: Int
    ) throws -> [(localIdentifier: String, lat: Double, lon: Double)]
    func geocodingCounts() throws -> GeocodingCounts
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws
    func updatePhotoLocations(_ updates: [LocationBackfillUpdate]) throws
    func updateVideoLocations(_ updates: [LocationBackfillUpdate]) throws
    func deferPhotoLocationBackfill(localIdentifiers: [String], until: Date) throws
    func deferVideoLocationBackfill(localIdentifiers: [String], until: Date) throws
    func reverseGeocodeLocations(bucketKeys: [String]) throws -> [String: LocationStrings]
    func saveReverseGeocodeLocation(_ location: LocationStrings, bucketKey: String) throws

    // Sources
    func insertSource(_ source: PhotoSource) throws
    func listSources() throws -> [PhotoSource]
    func deleteSource(_ id: String) throws
    /// Removes source-owned rows missing from a complete scan and always
    /// repairs the persisted count from the rows that remain.
    @discardableResult
    func reconcileFolderSource(
        _ id: String,
        scannedFilePaths: Set<String>,
        scanWasComplete: Bool
    ) throws -> Int

    // Queries
    func recognizedText(photoID: String, isPro: Bool) throws -> String?
    func photosAround(_ photo: SearchResult, isPro: Bool) throws -> [IndexedPhotoReference]
    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])]
    func onThisDaySummary() throws -> OnThisDaySummary?

    // Search History
    func addSearchHistory(_ query: String) throws
    func addSearchHistory(_ query: String, preview: RecentSearchPreview?) throws
    func backfillSearchHistoryPreviews(_ previews: [RecentSearchPreview]) throws
    func loadSearchHistory() throws -> [String]
    func loadSearchHistoryPreviews(limit: Int) throws -> [RecentSearchPreview]
    func clearSearchHistory() throws
    func removeSearchHistory(at index: Int) throws

    // Smart Albums
    func loadSmartAlbums() throws -> [SmartAlbum]
    func saveSmartAlbum(_ album: SmartAlbum) throws
    func deleteSmartAlbum(id: String) throws
}

struct FreeTierReconciliationResult: Equatable, Sendable {
    let retainedMediaCount: Int
    let didTrimMedia: Bool
}

enum FolderSourceDeletionError: LocalizedError, Equatable {
    case bookmarkCleanupFailed
    case bookmarkRestorationFailed

    var errorDescription: String? {
        switch self {
        case .bookmarkCleanupFailed:
            return "The folder could not be removed because its saved access could not be cleaned up."
        case .bookmarkRestorationFailed:
            return "The folder could not be removed because its saved access could not be restored safely."
        }
    }
}

extension DatabaseProtocol {
    func recognizedText(photoID: String, isPro: Bool) throws -> String? {
        throw DatabaseCapabilityError.unavailable
    }

    func photosAround(_ photo: SearchResult, isPro: Bool) throws -> [IndexedPhotoReference] {
        throw DatabaseCapabilityError.unavailable
    }

    func indexedPhotoVersions(in localIdentifiers: [String]) throws -> [String: IndexedMediaVersion] {
        Dictionary(uniqueKeysWithValues: try existingPhotoIdentifiers(in: localIdentifiers).map {
            ($0, IndexedMediaVersion(id: $0, indexedAt: .distantFuture))
        })
    }

    func indexedVideoVersions(in localIdentifiers: [String]) throws -> [String: IndexedMediaVersion] {
        Dictionary(uniqueKeysWithValues: try existingVideoIdentifiers(in: localIdentifiers).map {
            ($0, IndexedMediaVersion(id: $0, indexedAt: .distantFuture))
        })
    }

    func indexedFolderVersions(in filePaths: [String], sourceId: String) throws -> [String: IndexedMediaVersion] {
        Dictionary(uniqueKeysWithValues: try existingFilePaths(in: filePaths, sourceId: sourceId).map {
            ($0, IndexedMediaVersion(id: $0, indexedAt: .distantFuture))
        })
    }

    func replacePhoto(_ photo: IndexedPhoto) throws {
        throw DatabaseCapabilityError.unavailable
    }

    func replaceVideo(_ video: IndexedVideo, frames: [IndexedVideoFrame]) throws {
        throw DatabaseCapabilityError.unavailable
    }

    func onThisDaySummary() throws -> OnThisDaySummary? {
        let groups = try onThisDayPhotos().filter { !$0.photos.isEmpty }
        guard let mostRecentGroup = groups.max(by: { $0.year < $1.year }),
              let heroPhoto = mostRecentGroup.photos.first else { return nil }
        return OnThisDaySummary(
            heroPhoto: heroPhoto,
            mostRecentYear: mostRecentGroup.year,
            yearCount: groups.count,
            photoCount: groups.reduce(0) { $0 + $1.photos.count }
        )
    }

    func updatePhotoLocations(_ updates: [LocationBackfillUpdate]) throws {
        for update in updates {
            try updatePhotoLocationStrings(
                localIdentifier: update.localIdentifier,
                city: update.location.city,
                state: update.location.state,
                country: update.location.country,
                name: update.location.name
            )
        }
    }

    func updateVideoLocations(_ updates: [LocationBackfillUpdate]) throws {
        for update in updates {
            try updateVideoLocationStrings(
                localIdentifier: update.localIdentifier,
                city: update.location.city,
                state: update.location.state,
                country: update.location.country,
                name: update.location.name
            )
        }
    }

    func markPhotoScreenshots(localIdentifiers: Set<String>) throws {}

    func distinctMemoryPhotoIDs(in ids: [String]) throws -> Set<String> {
        Set(ids)
    }

    func loadIndexedMediaIdentifierPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> IndexedMediaIdentifierPage {
        let page = try loadSearchMediaPage(after: cursor, limit: limit)
        return IndexedMediaIdentifierPage(
            photos: page.photos.localIdentifiers,
            videos: Array(Set(page.videos.localIdentifiers)),
            nextCursor: page.nextCursor
        )
    }

    func existingPhotoIdentifiers(in localIdentifiers: [String]) throws -> Set<String> {
        var result: Set<String> = []
        for identifier in localIdentifiers where try isIndexed(localIdentifier: identifier) {
            result.insert(identifier)
        }
        return result
    }

    func existingVideoIdentifiers(in localIdentifiers: [String]) throws -> Set<String> {
        var result: Set<String> = []
        for identifier in localIdentifiers where try isVideoIndexed(localIdentifier: identifier) {
            result.insert(identifier)
        }
        return result
    }

    func loadIndexedPhotoIdentifierPage(after: String?, limit: Int) throws -> [String] {
        let identifiers = try allIndexedIdentifiers().sorted()
        let start = after.flatMap { cursor in
            identifiers.firstIndex(where: { $0 > cursor })
        } ?? (after == nil ? identifiers.startIndex : identifiers.endIndex)
        return Array(identifiers[start...].prefix(max(0, limit)))
    }

    func loadSearchMediaPage(after cursor: SearchMediaPageCursor?, limit: Int) throws -> SearchMediaPage {
        guard cursor == nil, limit > 0 else {
            return SearchMediaPage(
                photos: MediaIndex(kind: .photo),
                videos: MediaIndex(kind: .videoFrame),
                mediaCount: 0,
                totalPhotoCount: try indexedCount(),
                totalVideoCount: try videoIndexedCount(),
                nextCursor: nil
            )
        }
        let photos = try loadAllEmbeddings()
        let videos = try loadAllVideoEmbeddings()
        let counts = try indexedMediaCounts()
        return SearchMediaPage(
            photos: photos,
            videos: videos,
            mediaCount: photos.count + videos.uniqueIDCount,
            totalPhotoCount: counts.photos,
            totalVideoCount: counts.videos,
            nextCursor: nil
        )
    }

    func loadPhotoEmbedding(id: String) throws -> MediaIndex? {
        let index = try loadAllEmbeddings()
        guard let row = index.ids.firstIndex(of: id) else { return nil }
        var result = MediaIndex(kind: .photo)
        let start = row * EmbeddingConfig.dimensions
        let embedding = Array(index.embeddings[start..<(start + EmbeddingConfig.dimensions)])
        try result.append(
            MediaIndex.Row(
                id: index.ids[row],
                localIdentifier: index.localIdentifiers[row],
                sourceId: index.sourceIds[row],
                filePath: index.filePaths[row],
                date: index.dates[row],
                latitude: index.latitudes[row],
                longitude: index.longitudes[row],
                city: index.locationCities[row],
                state: index.locationStates[row],
                country: index.locationCountries[row],
                locationName: index.locationNames[row],
                details: .photo(ocrText: index.ocrTexts[row], sceneLabels: index.sceneLabels[row])
            ),
            embedding: embedding
        )
        return result
    }

    /// Compatibility default for lightweight test doubles. The production
    /// database includes row identity and timestamps so same-count media
    /// replacements still invalidate derived search suggestions.
    func searchIndexContentRevision() throws -> SearchIndexContentRevision {
        let counts = try indexedMediaCounts()
        return SearchIndexContentRevision(
            photoCount: counts.photos,
            videoCount: counts.videos,
            videoFrameCount: counts.videos,
            latestPhotoRowID: Int64(counts.photos),
            latestVideoRowID: Int64(counts.videos),
            latestVideoFrameRowID: Int64(counts.videos),
            latestPhotoID: nil,
            latestVideoID: nil,
            latestVideoFrameID: nil,
            latestPhotoIndexedAt: nil,
            latestVideoIndexedAt: nil,
            latestVideoFrameIndexedAt: nil
        )
    }

    /// Compatibility default for test doubles. `AppDatabase` performs both
    /// validity checks inside one transaction so invalidation rolls back.
    func reconcileFreeTier(
        _ limit: Int,
        whilePermitted: @escaping @Sendable () -> Bool
    ) throws -> FreeTierReconciliationResult {
        guard whilePermitted() else { throw CancellationError() }
        let result = try reconcileFreeTier(limit)
        guard whilePermitted() else { throw CancellationError() }
        return result
    }

    var allowsIndexingWrites: Bool { true }

    func hasIndexedPhotos() throws -> Bool {
        try indexedCount() > 0
    }
}

// MARK: - AppDatabase

final class AppDatabase: DatabaseProtocol, Sendable {
    static let shared: AppDatabase = {
        var persistentStoreAvailable = true
        do {
            if try performPendingPersistentStoreReset() {
                logger.info("Scheduled local search store reset completed")
            }
        } catch {
            persistentStoreAvailable = false
            logger.error("Scheduled local search store reset failed: \(error.safeDiagnosticCode)")
        }
        return AppDatabase(persistentStoreAvailable: persistentStoreAvailable)
    }()
    private static let fallbackState = OSAllocatedUnfairLock(initialState: false)
    static var isInMemoryFallback: Bool {
        get { fallbackState.withLock { $0 } }
        set { fallbackState.withLock { $0 = newValue } }
    }
    private static let orientationMigrationID = "v3-orientation-normalized-embeddings"
    private static let indexRebuildStateKey = "indexRebuildRequired"
    private static let embeddingFormatStateKey = "embeddingFormatVersion"
    private static let currentEmbeddingFormatVersion = "orientation-correct-v1"
    private static let legacyFastFormatRebuildKey = "indexing.needsFastFormatPhotoRebuild"
    private enum StorageMode {
        case persistent
        case inMemoryFallback
        case unavailable
    }

    private struct OpenResult {
        let queue: DatabaseQueue?
        let mode: StorageMode
        let error: DatabaseInitializationError?
    }

    let dbQueue: RecoverableDatabaseQueue
    private let storageMode: StorageMode

    var allowsIndexingWrites: Bool { storageMode == .persistent }
    var isAvailable: Bool { storageMode != .unavailable }

    init(persistentStoreAvailable: Bool) {
        let openQueue: () throws -> DatabaseQueue
        if persistentStoreAvailable {
            openQueue = Self.openOnDiskDatabase
        } else {
            openQueue = { throw DatabaseInitError.pendingResetCleanup }
        }
        let result = Self.openMigratedDatabase(
            openQueue: openQueue,
            migrate: { try Self.migrator.migrate($0) },
            fallbackMigrate: { try Self.migrator.migrate($0) },
            migrateLegacyBookmark: FolderBookmarkStore.migrateLegacyDataIfNeeded,
            recoverPendingBookmarkDeletions: FolderBookmarkStore.reconcileStagedDeletions
        )
        dbQueue = RecoverableDatabaseQueue(result.queue)
        storageMode = result.mode
    }

    init(
        openQueue: () throws -> DatabaseQueue,
        migrate: (DatabaseQueue) throws -> Void,
        migrateLegacyBookmark: (String) throws -> Void = FolderBookmarkStore.migrateLegacyDataIfNeeded
    ) {
        let result = Self.openMigratedDatabase(
            openQueue: openQueue,
            migrate: migrate,
            fallbackMigrate: migrate,
            migrateLegacyBookmark: migrateLegacyBookmark,
            recoverPendingBookmarkDeletions: { _ in [] }
        )
        dbQueue = RecoverableDatabaseQueue(result.queue)
        storageMode = result.mode
    }

    init(
        openQueue: () throws -> DatabaseQueue,
        migrate: (DatabaseQueue) throws -> Void,
        fallbackMigrate: (DatabaseQueue) throws -> Void
    ) throws {
        let result = Self.openMigratedDatabase(
            openQueue: openQueue,
            migrate: migrate,
            fallbackMigrate: fallbackMigrate,
            migrateLegacyBookmark: FolderBookmarkStore.migrateLegacyDataIfNeeded,
            recoverPendingBookmarkDeletions: { _ in [] }
        )
        if let error = result.error { throw error }
        dbQueue = RecoverableDatabaseQueue(result.queue)
        storageMode = result.mode
    }

    private static func openMigratedDatabase(
        openQueue: () throws -> DatabaseQueue,
        migrate: (DatabaseQueue) throws -> Void,
        fallbackMigrate: (DatabaseQueue) throws -> Void,
        migrateLegacyBookmark: (String) throws -> Void,
        recoverPendingBookmarkDeletions: ([String]) -> [String]
    ) -> OpenResult {
        Self.isInMemoryFallback = false
        do {
            let queue = try openQueue()
            let orientationMigrationWasAlreadyApplied = try queue.read { db in
                try Self.migrator.appliedMigrations(db).contains(Self.orientationMigrationID)
            }
            try migrate(queue)
            try finalizeEmbeddingFormatState(
                in: queue,
                orientationMigrationWasAlreadyApplied: orientationMigrationWasAlreadyApplied
            )
            _ = migrateLegacyFolderBookmarks(
                in: queue,
                migrate: migrateLegacyBookmark,
                recoverPendingDeletions: recoverPendingBookmarkDeletions
            )
            #if DEBUG
            logger.info("[Database] Migrations completed successfully")
            #endif
            return OpenResult(queue: queue, mode: .persistent, error: nil)
        } catch let persistentError {
            logger.error("Database init or migration failed, using read-only in-memory fallback: \(persistentError.safeDiagnosticCode)")
            Self.isInMemoryFallback = true
            do {
                let queue = try DatabaseQueue()
                try fallbackMigrate(queue)
                try finalizeEmbeddingFormatState(
                    in: queue,
                    orientationMigrationWasAlreadyApplied: false
                )
                return OpenResult(queue: queue, mode: .inMemoryFallback, error: nil)
            } catch let fallbackError {
                logger.error("In-memory database migration failed; storage is unavailable: \(fallbackError.safeDiagnosticCode)")
                return OpenResult(
                    queue: nil,
                    mode: .unavailable,
                    error: .persistentAndFallbackFailed(
                        persistent: persistentError.localizedDescription,
                        fallback: fallbackError.localizedDescription
                    )
                )
            }
        }
    }

    private static func openOnDiskDatabase() throws -> DatabaseQueue {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DatabaseInitError.applicationSupportUnavailable
        }

        let dbURL = persistentStoreURL(applicationSupportURL: appSupport)
        let dbDir = dbURL.deletingLastPathComponent()
        try LocalOnlyStorage.prepareDirectory(at: dbDir)

        let dbPath = dbURL.path

        let config = Configuration()
        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        try protectSQLiteFiles(for: dbURL)

        return queue
    }

    static func schedulePersistentStoreReset(defaults: UserDefaults = .standard) {
        if !isPersistentStoreResetScheduled(defaults: defaults) {
            defaults.removeObject(forKey: AppKeys.persistentStoreResetStoreDeleted)
        }
        defaults.set(true, forKey: AppKeys.persistentStoreReset)
    }

    static func isPersistentStoreResetScheduled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppKeys.persistentStoreReset)
    }

    /// Deletes the SQLite search store, its sidecars, and folder-access
    /// bookmarks whose source registrations live in that store. The operation
    /// runs before `shared` opens the store on the next app launch. The pending
    /// marker is retained if any deletion fails so the app can try again later.
    /// Once the old SQLite files are gone, a separate phase marker prevents a
    /// retry from deleting a replacement store created after partial cleanup.
    @discardableResult
    static func performPendingPersistentStoreReset(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) throws -> Bool {
        guard isPersistentStoreResetScheduled(defaults: defaults) else { return false }
        let supportURL: URL
        if let applicationSupportURL {
            supportURL = applicationSupportURL
        } else {
            guard let discoveredURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw DatabaseInitError.applicationSupportUnavailable
            }
            supportURL = discoveredURL
        }

        let bookmarkDirectory = supportURL
            .appendingPathComponent("Memorable", isDirectory: true)
            .appendingPathComponent("FolderBookmarks", isDirectory: true)
        let pendingBookmarkDirectory = bookmarkDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("FolderBookmarks.reset-pending", isDirectory: true)
        let storeFilesAlreadyDeleted = defaults.bool(
            forKey: AppKeys.persistentStoreResetStoreDeleted
        )

        if !storeFilesAlreadyDeleted {
            if fileManager.fileExists(atPath: bookmarkDirectory.path),
               !fileManager.fileExists(atPath: pendingBookmarkDirectory.path) {
                try fileManager.moveItem(
                    at: bookmarkDirectory,
                    to: pendingBookmarkDirectory
                )
            }
            for key in defaults.dictionaryRepresentation().keys where
                key.hasPrefix(AppKeys.folderBookmarkPrefix) {
                defaults.removeObject(forKey: key)
            }

            let storeURL = persistentStoreURL(applicationSupportURL: supportURL)
            for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] {
                do {
                    try fileManager.removeItem(at: URL(fileURLWithPath: path))
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                }
            }
            defaults.set(true, forKey: AppKeys.persistentStoreResetStoreDeleted)
        }

        do {
            try fileManager.removeItem(at: pendingBookmarkDirectory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The desired state is already present.
        }
        defaults.removeObject(forKey: AppKeys.persistentStoreResetStoreDeleted)
        defaults.removeObject(forKey: AppKeys.persistentStoreReset)
        return true
    }

    private static func persistentStoreURL(applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent("Memorable", isDirectory: true)
            .appendingPathComponent("photos.sqlite", isDirectory: false)
    }

    static func migrateLegacyFolderBookmarks(
        in queue: DatabaseQueue,
        migrate: (String) throws -> Void = FolderBookmarkStore.migrateLegacyDataIfNeeded,
        recoverPendingDeletions: ([String]) -> [String] = { _ in [] }
    ) -> [String] {
        let sourceIDs: [String]
        do {
            sourceIDs = try queue.read { db -> [String] in
                guard try db.tableExists("photo_sources") else { return [] }
                return try String.fetchAll(
                    db,
                    sql: "SELECT id FROM photo_sources WHERE type = ? ORDER BY id ASC",
                    arguments: [PhotoSourceType.folder.rawValue]
                )
            }
        } catch {
            logger.error("Failed to inspect legacy folder bookmarks: \(error.safeDiagnosticCode)")
            return []
        }

        var failedSourceIDs = recoverPendingDeletions(sourceIDs)
        for sourceID in sourceIDs {
            do {
                try migrate(sourceID)
            } catch {
                failedSourceIDs.append(sourceID)
                logger.error("Failed to migrate a legacy folder bookmark: \(error.safeDiagnosticCode)")
            }
        }
        return failedSourceIDs
    }

    private static func protectSQLiteFiles(for dbURL: URL) throws {
        try setCompleteUnlessOpenProtection(at: dbURL)
        try setCompleteUnlessOpenProtection(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try setCompleteUnlessOpenProtection(at: URL(fileURLWithPath: dbURL.path + "-shm"))
    }

    private static func setCompleteUnlessOpenProtection(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
    }

    private static func finalizeEmbeddingFormatState(
        in queue: DatabaseQueue,
        orientationMigrationWasAlreadyApplied: Bool
    ) throws {
        let legacyRebuildRequired = UserDefaults.standard.bool(forKey: legacyFastFormatRebuildKey)
        var didConsumeLegacyFlag = false

        try queue.write { db in
            guard try db.tableExists("indexed_photos") else { return }
            try createAppStateTableIfNeeded(db)

            let storedVersion = try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [embeddingFormatStateKey]
            )
            guard storedVersion != currentEmbeddingFormatVersion else { return }

            let existingEmbeddingCount = try embeddingCount(in: db)
            if existingEmbeddingCount > 0
                && (orientationMigrationWasAlreadyApplied || legacyRebuildRequired) {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try setAppState(
                embeddingFormatStateKey,
                value: currentEmbeddingFormatVersion,
                in: db
            )
            didConsumeLegacyFlag = legacyRebuildRequired
        }

        if didConsumeLegacyFlag {
            UserDefaults.standard.removeObject(forKey: legacyFastFormatRebuildKey)
        }
    }

    private static func createAppStateTableIfNeeded(_ db: Database) throws {
        try db.create(table: "app_state", ifNotExists: true) { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
        }
    }

    private static func setAppState(_ key: String, value: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO app_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    private static func embeddingCount(in db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0)
            + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_video_frames") ?? 0)
    }

    static func shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
        in db: Database
    ) throws -> Bool {
        let rebuildRequired = try String.fetchOne(
            db,
            sql: "SELECT value FROM app_state WHERE key = ?",
            arguments: [indexRebuildStateKey]
        ) == "true"
        guard rebuildRequired else { return false }
        return try embeddingCount(in: db) == 0
    }

    static func markIndexRebuildRequired(in db: Database) throws {
        try setAppState(indexRebuildStateKey, value: "true", in: db)
    }

    static func clearIndexRebuildRequired(in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM app_state WHERE key = ?",
            arguments: [indexRebuildStateKey]
        )
    }

    private enum DatabaseInitError: LocalizedError {
        case applicationSupportUnavailable
        case pendingResetCleanup

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Application Support directory not found"
            case .pendingResetCleanup:
                return "Persistent store reset cleanup is still pending"
            }
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "indexed_photos") { t in
                t.column("id", .text).primaryKey()
                t.column("localIdentifier", .text).notNull().unique()
                t.column("creationDate", .datetime)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("pixelWidth", .integer).notNull()
                t.column("pixelHeight", .integer).notNull()
                t.column("embedding", .blob).notNull()
                t.column("indexedAt", .datetime).notNull()
                t.column("ocrText", .text)
                t.column("sharpnessScore", .double)
                t.column("sourceId", .text).notNull().defaults(to: "photokit")
                t.column("filePath", .text)
                t.column("locationCity", .text)
                t.column("locationState", .text)
                t.column("locationCountry", .text)
                t.column("locationName", .text)
                t.column("sceneLabels", .text)
            }

            try db.create(table: "photo_sources") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("path", .text)
                t.column("name", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastIndexedAt", .datetime)
                t.column("photoCount", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "indexed_videos") { t in
                t.column("id", .text).primaryKey()
                t.column("localIdentifier", .text).notNull().unique()
                t.column("creationDate", .datetime)
                t.column("latitude", .double)
                t.column("longitude", .double)
                t.column("duration", .double).notNull()
                t.column("pixelWidth", .integer).notNull()
                t.column("pixelHeight", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("indexedAt", .datetime).notNull()
                t.column("sourceId", .text).notNull().defaults(to: "photokit")
                t.column("locationCity", .text)
                t.column("locationState", .text)
                t.column("locationCountry", .text)
                t.column("locationName", .text)
            }

            try db.create(table: "indexed_video_frames") { t in
                t.column("id", .text).primaryKey()
                t.column("videoId", .text).notNull().references("indexed_videos", onDelete: .cascade)
                t.column("framePosition", .double).notNull()
                t.column("embedding", .blob).notNull()
                t.column("indexedAt", .datetime).notNull()
            }
            try db.create(index: "idx_video_frames_videoId", on: "indexed_video_frames",
                           columns: ["videoId"])

            try db.create(table: "search_history") { t in
                t.column("id", .integer).primaryKey(autoincrement: true)
                t.column("query", .text).notNull()
                t.column("searchedAt", .datetime).notNull()
            }

            try db.create(table: "smart_albums") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("query", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(index: "idx_photos_city", on: "indexed_photos",
                           columns: ["locationCity"])
        }

        // SigLIP2 model replacement: old MobileCLIP embeddings are incompatible.
        // Clear all indexed data so the app re-indexes with the new model.
        migrator.registerMigration("v2-siglip2-model-swap") { db in
            let existingMediaCount =
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0)
                + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_videos") ?? 0)
            try createAppStateTableIfNeeded(db)
            if existingMediaCount > 0 {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try db.execute(sql: "DELETE FROM indexed_video_frames")
            try db.execute(sql: "DELETE FROM indexed_videos")
            try db.execute(sql: "DELETE FROM indexed_photos")
        }

        // Embedding preprocessing changed to respect UIImage/EXIF orientation.
        // Old embeddings may represent raw sensor pixels rather than the
        // displayed image, so clear indexed media and rebuild homogeneously.
        migrator.registerMigration("v3-orientation-normalized-embeddings") { db in
            let existingMediaCount =
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0)
                + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_videos") ?? 0)
            try createAppStateTableIfNeeded(db)
            if existingMediaCount > 0 {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try db.execute(sql: "DELETE FROM indexed_video_frames")
            try db.execute(sql: "DELETE FROM indexed_videos")
            try db.execute(sql: "DELETE FROM indexed_photos")
        }

        // Existing rows were enriched inline by older indexing code. New rows
        // inserted by the progressive indexing path set this to false and are
        // completed by the deferred enrichment pass.
        migrator.registerMigration("v4-photo-enrichment-state") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "enrichmentComplete", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "idx_photos_enrichment_pending", on: "indexed_photos",
                          columns: ["enrichmentComplete", "creationDate"])
        }

        // V2 briefly indexed first-pass photo embeddings from PhotoKit
        // `.fastFormat` images. That can produce low-quality embedding inputs
        // on device and leave the app with a populated but ineffective search
        // index. Rebuild photo embeddings with the high-quality local loader.
        migrator.registerMigration("v5-rebuild-fastformat-photo-embeddings") { db in
            let existingPhotoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM indexed_photos") ?? 0
            try createAppStateTableIfNeeded(db)
            if existingPhotoCount > 0 {
                try setAppState(indexRebuildStateKey, value: "true", in: db)
            }
            try db.execute(sql: "DELETE FROM indexed_photos")
        }

        // Keep transient enrichment load failures retryable without allowing
        // one unreadable photo to spin inside a single enrichment pass.
        migrator.registerMigration("v6-photo-enrichment-retry") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "enrichmentAttemptedAt", .datetime)
            }
        }

        migrator.registerMigration("v7-index-rebuild-state") { db in
            try createAppStateTableIfNeeded(db)
        }

        // Older indexing wrote video metadata before its frames. If the app
        // stopped between those writes, the metadata row made later passes
        // skip a video that had no searchable embedding.
        migrator.registerMigration("v8-remove-incomplete-videos") { db in
            try db.execute(
                sql: """
                    DELETE FROM indexed_videos
                    WHERE NOT EXISTS (
                        SELECT 1 FROM indexed_video_frames
                        WHERE indexed_video_frames.videoId = indexed_videos.id
                    )
                """
            )
        }

        migrator.registerMigration("v9-search-pagination-indexes") { db in
            try db.execute(
                sql: """
                    CREATE INDEX idx_photos_search_order
                    ON indexed_photos(creationDate DESC, id ASC);
                    CREATE INDEX idx_photos_source_search_order
                    ON indexed_photos(sourceId, creationDate DESC, id ASC);
                    CREATE INDEX idx_videos_search_order
                    ON indexed_videos(creationDate DESC, id ASC);
                    CREATE INDEX idx_videos_source_search_order
                    ON indexed_videos(sourceId, creationDate DESC, id ASC);
                    CREATE INDEX idx_photos_file_path
                    ON indexed_photos(filePath)
                    WHERE filePath IS NOT NULL
                """
            )
        }

        // Speed source-scoped folder ownership checks and repair source counts
        // without deleting any existing user-derived index rows.
        migrator.registerMigration("v10-folder-source-integrity") { db in
            try db.execute(
                sql: """
                    CREATE INDEX idx_photos_source_file_path
                    ON indexed_photos(sourceId, filePath)
                    WHERE filePath IS NOT NULL;
                    UPDATE photo_sources
                    SET photoCount = (
                        SELECT COUNT(*) FROM indexed_photos
                        WHERE indexed_photos.sourceId = photo_sources.id
                    ),
                    lastIndexedAt = CASE
                        WHEN (
                            SELECT COUNT(*) FROM indexed_photos
                            WHERE indexed_photos.sourceId = photo_sources.id
                        ) = 0 THEN NULL
                        ELSE lastIndexedAt
                    END;
                """
            )
        }

        // Memory surfaces must distinguish ordinary photos from screenshots
        // and document captures without removing either from normal search.
        migrator.registerMigration("v11-memory-content-classification") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "isScreenshot", .boolean).notNull().defaults(to: false)
                t.add(column: "isDocumentImage", .boolean).notNull().defaults(to: false)
            }

            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, pixelWidth, pixelHeight, ocrText, sceneLabels
                    FROM indexed_photos
                """
            )
            while let row = try rows.next() {
                let width: Int = row["pixelWidth"]
                let height: Int = row["pixelHeight"]
                let ocrText: String? = row["ocrText"]
                let sceneLabels: String? = row["sceneLabels"]
                let isScreenshot = MemoryContentPolicy.isLikelyScreenshotDimensions(
                    width: width,
                    height: height
                )
                let isDocument = MemoryContentPolicy.isDocumentImage(
                    ocrText: ocrText,
                    sceneLabels: sceneLabels
                )
                guard isScreenshot || isDocument else { continue }
                try db.execute(
                    sql: """
                        UPDATE indexed_photos
                        SET isScreenshot = ?, isDocumentImage = ?
                        WHERE id = ?
                    """,
                    arguments: [isScreenshot, isDocument, row["id"] as String]
                )
            }
            try db.create(
                index: "idx_photos_memory_eligible",
                on: "indexed_photos",
                columns: ["isScreenshot", "isDocumentImage", "creationDate"]
            )
        }

        // Reuse reverse-geocoded location strings across launches and across
        // media captured in the same approximately one-kilometer coordinate cell.
        migrator.registerMigration("v12-persistent-reverse-geocode-cache") { db in
            try db.create(table: "reverse_geocode_cache") { t in
                t.column("bucketKey", .text).primaryKey()
                t.column("city", .text)
                t.column("state", .text)
                t.column("country", .text)
                t.column("name", .text)
                t.column("resolvedAt", .datetime).notNull()
            }
        }

        // Geocoding walks unresolved rows in stable identifier order. Partial
        // indexes keep that keyset scan bounded even for very large libraries.
        migrator.registerMigration("v13-geocoding-keyset-indexes") { db in
            try db.execute(
                sql: """
                    CREATE INDEX idx_photos_pending_geocoding
                    ON indexed_photos(localIdentifier)
                    WHERE latitude BETWEEN -90 AND 90
                      AND longitude BETWEEN -180 AND 180
                      AND (locationCity IS NULL OR locationCity = '');
                    CREATE INDEX idx_videos_pending_geocoding
                    ON indexed_videos(localIdentifier)
                    WHERE latitude BETWEEN -90 AND 90
                      AND longitude BETWEEN -180 AND 180
                      AND (locationCity IS NULL OR locationCity = '')
                """
            )
        }

        // Persist explicit geocoder no-result outcomes. These rows are omitted
        // from pending work until a deliberate retry date, so one permanently
        // unresolvable coordinate cannot keep progress visible across launches.
        migrator.registerMigration("v14-geocoding-no-result-retry") { db in
            try db.alter(table: "indexed_photos") { t in
                t.add(column: "locationRetryAfter", .datetime)
            }
            try db.alter(table: "indexed_videos") { t in
                t.add(column: "locationRetryAfter", .datetime)
            }
        }

        // Keep the top result for each recent query so the search home can be
        // photo-led without re-running semantic searches during launch.
        migrator.registerMigration("v15-search-history-previews") { db in
            try db.alter(table: "search_history") { t in
                t.add(column: "previewResultID", .text)
                t.add(column: "previewLocalIdentifier", .text)
                t.add(column: "previewCreationDate", .datetime)
                t.add(column: "previewIsVideo", .boolean)
                t.add(column: "previewBestFramePosition", .double)
                t.add(column: "previewSourceId", .text)
                t.add(column: "previewFilePath", .text)
                t.add(column: "previewResultCount", .integer)
            }
        }

        // Kept separate from v15 so development installs that already ran the
        // preview migration receive the score column without rebuilding data.
        migrator.registerMigration("v16-search-history-preview-score") { db in
            try db.alter(table: "search_history") { t in
                t.add(column: "previewScore", .double)
            }
        }

        return migrator
    }

    func indexRebuildRequired() throws -> Bool {
        try dbQueue.read { db in
            guard try db.tableExists("app_state") else { return false }
            return try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: [Self.indexRebuildStateKey]
            ) == "true"
        }
    }

    func clearIndexRebuildRequired() throws {
        try dbQueue.write { db in
            guard try db.tableExists("app_state") else { return }
            try Self.clearIndexRebuildRequired(in: db)
        }
    }

    func requireIndexingWrites() throws {
        guard isAvailable else { throw DatabaseCapabilityError.unavailable }
        guard allowsIndexingWrites else {
            throw DatabaseCapabilityError.indexingUnavailableInFallback
        }
    }
}

// MARK: - SwiftUI Environment

import SwiftUI

private struct DatabaseKey: EnvironmentKey {
    static let defaultValue: DatabaseProtocol = AppDatabase.shared
}

extension EnvironmentValues {
    var database: DatabaseProtocol {
        get { self[DatabaseKey.self] }
        set { self[DatabaseKey.self] = newValue }
    }
}
