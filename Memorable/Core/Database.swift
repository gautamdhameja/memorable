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

enum SearchEngineError: Error, Equatable {
    /// Persisted index columns or embedding rows are malformed. Refuse to load.
    case corruptedIndex
    /// A model returned an embedding with an unsafe shape.
    case invalidEmbedding
}

enum SearchIndexLimits {
    /// Maximum number of media items retained in the in-memory fast path. This
    /// is a resident-memory limit, not a Pro product or persistence limit.
    static let residentMediaItems = 8_000
    /// Media descriptors fetched per whole-library database scan. Frames for a
    /// selected video are loaded together, so a page never splits one video.
    static let databasePageMediaItems = 512
    static let maximumMediaItems = residentMediaItems
    static let maximumPhotoRows = residentMediaItems
    static let maximumVideoFramesPerMedia = 5
    static let maximumVideoFrameRows = residentMediaItems * maximumVideoFramesPerMedia
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

struct IndexedMediaIdentifiers {
    let photos: Set<String>
    let videos: Set<String>
}

struct IndexedMediaIdentifierPage: Sendable {
    let photos: [String]
    let videos: [String]
    let nextCursor: SearchMediaPageCursor?
}

struct SearchMediaPageCursor: Equatable, Sendable {
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

enum DatabaseCapabilityError: Error, Equatable {
    case unavailable
    case indexingUnavailableInFallback
}

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
    func allIndexedIdentifiers() throws -> Set<String>
    func loadIndexedPhotoIdentifierPage(after: String?, limit: Int) throws -> [String]
    func allIndexedFilePaths() throws -> Set<String>
    func existingFilePaths(in filePaths: [String]) throws -> Set<String>
    func indexedCount() throws -> Int
    func hasIndexedPhotos() throws -> Bool
    func indexedMediaCounts() throws -> IndexedMediaCounts
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
    func videoIndexedCount() throws -> Int
    func allIndexedVideoIdentifiers() throws -> Set<String>
    /// Loads the deterministic, newest searchable video-frame window, bounded
    /// by `SearchIndexLimits.maximumVideoFrameRows`.
    func loadAllVideoEmbeddings() throws -> MediaIndex
    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws
    func trimToLimit(_ limit: Int) throws
    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult
    func reconcileFreeTier(
        _ limit: Int,
        whilePermitted: @escaping @Sendable () -> Bool
    ) throws -> FreeTierReconciliationResult

    // Location backfill
    func photosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)]
    func videosNeedingLocationBackfill(limit: Int) throws -> [(localIdentifier: String, lat: Double, lon: Double)]
    func geocodingCounts() throws -> GeocodingCounts
    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws
    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?, country: String?, name: String?) throws

    // Sources
    func insertSource(_ source: PhotoSource) throws
    func listSources() throws -> [PhotoSource]
    func deleteSource(_ id: String) throws
    func updateSourceStats(_ id: String, photoCount: Int) throws

    // Queries
    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])]

    // Search History
    func addSearchHistory(_ query: String) throws
    func loadSearchHistory() throws -> [String]
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

    var errorDescription: String? {
        switch self {
        case .bookmarkCleanupFailed:
            return "The folder could not be removed because its saved access could not be cleaned up."
        }
    }
}

extension DatabaseProtocol {
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

    func existingFilePaths(in filePaths: [String]) throws -> Set<String> {
        let existing = try allIndexedFilePaths()
        return Set(filePaths).intersection(existing)
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
    static let shared = AppDatabase()
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

    private init() {
        let result = Self.openMigratedDatabase(
            openQueue: Self.openOnDiskDatabase,
            migrate: { try Self.migrator.migrate($0) },
            fallbackMigrate: { try Self.migrator.migrate($0) },
            migrateLegacyBookmark: FolderBookmarkStore.migrateLegacyDataIfNeeded
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
            migrateLegacyBookmark: migrateLegacyBookmark
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
            migrateLegacyBookmark: FolderBookmarkStore.migrateLegacyDataIfNeeded
        )
        if let error = result.error { throw error }
        dbQueue = RecoverableDatabaseQueue(result.queue)
        storageMode = result.mode
    }

    private static func openMigratedDatabase(
        openQueue: () throws -> DatabaseQueue,
        migrate: (DatabaseQueue) throws -> Void,
        fallbackMigrate: (DatabaseQueue) throws -> Void,
        migrateLegacyBookmark: (String) throws -> Void
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
            _ = migrateLegacyFolderBookmarks(in: queue, migrate: migrateLegacyBookmark)
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

        let dbDir = appSupport.appendingPathComponent("Memorable", isDirectory: true)
        try LocalOnlyStorage.prepareDirectory(at: dbDir)

        let dbURL = dbDir.appendingPathComponent("photos.sqlite")
        let dbPath = dbURL.path

        let config = Configuration()
        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        try protectSQLiteFiles(for: dbURL)

        return queue
    }

    static func migrateLegacyFolderBookmarks(
        in queue: DatabaseQueue,
        migrate: (String) throws -> Void = FolderBookmarkStore.migrateLegacyDataIfNeeded
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

        var failedSourceIDs: [String] = []
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

    private static func shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
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

    private static func clearIndexRebuildRequired(in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM app_state WHERE key = ?",
            arguments: [indexRebuildStateKey]
        )
    }

    private enum DatabaseInitError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            "Application Support directory not found"
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

        return migrator
    }

    // MARK: - Photos

    func insertPhoto(_ photo: IndexedPhoto) throws {
        try requireIndexingWrites()
        try dbQueue.write { db in
            try Self.sanitizedForPersistence(photo).insert(db)
        }
    }

    @discardableResult
    func insertPhotos(
        _ photos: [IndexedPhoto],
        completingRequiredRebuild: Bool
    ) throws -> Bool {
        guard !photos.isEmpty else { return false }
        try requireIndexingWrites()
        return try dbQueue.write { db in
            var completesRequiredRebuild = false
            if completingRequiredRebuild {
                completesRequiredRebuild = try Self.shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
                    in: db
                )
            }
            for photo in photos {
                try Self.sanitizedForPersistence(photo).insert(db, onConflict: .ignore)
            }
            if completesRequiredRebuild {
                try Self.clearIndexRebuildRequired(in: db)
            }
            return completesRequiredRebuild
        }
    }

    private static func sanitizedForPersistence(_ photo: IndexedPhoto) throws -> IndexedPhoto {
        var photo = photo
        guard photo.embedding.validatedFloat16Embedding() != nil else {
            throw SearchEngineError.invalidEmbedding
        }
        if !LocationCoordinatePolicy.isValidOrAbsent(
            latitude: photo.latitude,
            longitude: photo.longitude
        ) {
            photo.latitude = nil
            photo.longitude = nil
        }
        photo.ocrText = PersistedMetadataTextPolicy.bounded(
            photo.ocrText,
            maximumCharacters: PersistedMetadataTextPolicy.maximumOCRCharacters
        )
        photo.sceneLabels = PersistedMetadataTextPolicy.bounded(
            photo.sceneLabels,
            maximumCharacters: PersistedMetadataTextPolicy.maximumSceneLabelCharacters
        )
        photo.locationCity = PersistedMetadataTextPolicy.bounded(
            photo.locationCity,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        photo.locationState = PersistedMetadataTextPolicy.bounded(
            photo.locationState,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        photo.locationCountry = PersistedMetadataTextPolicy.bounded(
            photo.locationCountry,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        photo.locationName = PersistedMetadataTextPolicy.bounded(
            photo.locationName,
            maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
        )
        return photo
    }

    func isIndexed(localIdentifier: String) throws -> Bool {
        try dbQueue.read { db in
            try IndexedPhoto.filter(Column("localIdentifier") == localIdentifier).fetchCount(db) > 0
        }
    }

    func existingPhotoIdentifiers(in localIdentifiers: [String]) throws -> Set<String> {
        try existingStrings(
            localIdentifiers,
            table: "indexed_photos",
            column: "localIdentifier"
        )
    }

    func allIndexedIdentifiers() throws -> Set<String> {
        try dbQueue.read { db in
            try Self.loadIdentifierSet(
                db,
                sql: """
                    SELECT localIdentifier FROM indexed_photos
                    WHERE sourceId = ?
                    ORDER BY creationDate DESC, id ASC
                    LIMIT ?
                """,
                arguments: [PhotoSourceType.photokit.rawValue],
                limit: SearchIndexLimits.maximumPhotoRows
            )
        }
    }

    func loadIndexedPhotoIdentifierPage(after: String?, limit: Int) throws -> [String] {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.databasePageMediaItems))
        guard boundedLimit > 0 else { return [] }
        return try dbQueue.read { db in
            if let after {
                return try String.fetchAll(
                    db,
                    sql: """
                        SELECT localIdentifier FROM indexed_photos
                        WHERE sourceId = ? AND localIdentifier > ?
                        ORDER BY localIdentifier ASC
                        LIMIT ?
                    """,
                    arguments: [PhotoSourceType.photokit.rawValue, after, boundedLimit]
                )
            }
            return try String.fetchAll(
                db,
                sql: """
                    SELECT localIdentifier FROM indexed_photos
                    WHERE sourceId = ?
                    ORDER BY localIdentifier ASC
                    LIMIT ?
                """,
                arguments: [PhotoSourceType.photokit.rawValue, boundedLimit]
            )
        }
    }

    func allIndexedFilePaths() throws -> Set<String> {
        try dbQueue.read { db in
            try Self.loadIdentifierSet(
                db,
                sql: """
                    SELECT filePath FROM indexed_photos
                    WHERE filePath IS NOT NULL
                    ORDER BY creationDate DESC, id ASC
                    LIMIT ?
                """,
                limit: SearchIndexLimits.maximumPhotoRows
            )
        }
    }

    func existingFilePaths(in filePaths: [String]) throws -> Set<String> {
        try existingStrings(filePaths, table: "indexed_photos", column: "filePath")
    }

    private func existingStrings(
        _ values: [String],
        table: String,
        column: String
    ) throws -> Set<String> {
        guard !values.isEmpty else { return [] }
        var matches: Set<String> = []
        try dbQueue.read { db in
            for chunk in values.chunked(into: 900) {
                try Task.checkCancellation()
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT \(column) FROM \(table) WHERE \(column) IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                matches.formUnion(rows)
            }
        }
        return matches
    }

    func indexedCount() throws -> Int {
        try dbQueue.read { db in
            try IndexedPhoto.fetchCount(db)
        }
    }

    func hasIndexedPhotos() throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM indexed_photos LIMIT 1)"
            ) ?? false
        }
    }

    func indexedMediaCounts() throws -> IndexedMediaCounts {
        try dbQueue.read { db in
            IndexedMediaCounts(
                photos: try IndexedPhoto.fetchCount(db),
                videos: try IndexedVideo.fetchCount(db)
            )
        }
    }

    func photoLibraryIndexedMediaCounts() throws -> IndexedMediaCounts {
        try dbQueue.read { db in
            IndexedMediaCounts(
                photos: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM indexed_photos WHERE sourceId = ?",
                    arguments: [PhotoSourceType.photokit.rawValue]
                ) ?? 0,
                videos: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM indexed_videos WHERE sourceId = ?",
                    arguments: [PhotoSourceType.photokit.rawValue]
                ) ?? 0
            )
        }
    }

    func allIndexedMediaIdentifiers() throws -> IndexedMediaIdentifiers {
        try loadIndexedMediaIdentifiers(limit: SearchIndexLimits.maximumMediaItems)
    }

    func loadIndexedMediaIdentifierPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> IndexedMediaIdentifierPage {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.databasePageMediaItems))
        guard boundedLimit > 0 else {
            return IndexedMediaIdentifierPage(photos: [], videos: [], nextCursor: nil)
        }
        return try dbQueue.read { db in
            let fetchLimit = boundedLimit + 1
            let photoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .photo,
                includesLocalIdentifier: true,
                sourceID: PhotoSourceType.photokit.rawValue,
                after: cursor,
                limit: fetchLimit
            )
            let videoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .video,
                includesLocalIdentifier: true,
                sourceID: PhotoSourceType.photokit.rawValue,
                after: cursor,
                limit: fetchLimit
            )
            let descriptors = try Self.mergeMediaPageDescriptors(
                photoDescriptors,
                videoDescriptors,
                limit: fetchLimit
            )
            let hasMore = descriptors.count > boundedLimit
            let selected = Array(descriptors.prefix(boundedLimit))
            let nextCursor = hasMore ? selected.last.map {
                SearchMediaPageCursor(
                    creationDate: $0.creationDate,
                    id: $0.id,
                    mediaType: $0.mediaType
                )
            } : nil
            return IndexedMediaIdentifierPage(
                photos: selected.filter { $0.mediaType == .photo }.compactMap(\.localIdentifier),
                videos: selected.filter { $0.mediaType == .video }.compactMap(\.localIdentifier),
                nextCursor: nextCursor
            )
        }
    }

    func loadIndexedMediaIdentifiers(limit: Int) throws -> IndexedMediaIdentifiers {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumMediaItems))
        guard boundedLimit > 0 else {
            return IndexedMediaIdentifiers(photos: [], videos: [])
        }
        return try dbQueue.read { db in
            var photos = Set<String>(minimumCapacity: boundedLimit)
            var videos = Set<String>(minimumCapacity: boundedLimit)
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT mediaType, localIdentifier FROM (
                        SELECT 'photo' AS mediaType, localIdentifier, creationDate, id
                        FROM indexed_photos
                        WHERE sourceId = ?
                        UNION ALL
                        SELECT 'video' AS mediaType, localIdentifier, creationDate, id
                        FROM indexed_videos
                        WHERE sourceId = ?
                    )
                    ORDER BY creationDate DESC, id ASC, mediaType ASC
                    LIMIT ?
                """,
                arguments: [
                    PhotoSourceType.photokit.rawValue,
                    PhotoSourceType.photokit.rawValue,
                    boundedLimit,
                ]
            )
            var rowNumber = 0
            while let row = try cursor.next() {
                if rowNumber.isMultiple(of: 256) { try Task.checkCancellation() }
                let identifier: String = row["localIdentifier"]
                let mediaType: String = row["mediaType"]
                if mediaType == "photo" {
                    photos.insert(identifier)
                } else {
                    videos.insert(identifier)
                }
                rowNumber += 1
            }
            return IndexedMediaIdentifiers(photos: photos, videos: videos)
        }
    }

    private static func loadIdentifierSet(
        _ db: Database,
        sql: String,
        arguments: StatementArguments = [],
        limit: Int
    ) throws -> Set<String> {
        guard limit > 0 else { return [] }
        var identifiers = Set<String>(minimumCapacity: limit)
        var resolvedArguments = arguments
        resolvedArguments += [limit]
        let cursor = try String.fetchCursor(db, sql: sql, arguments: resolvedArguments)
        var row = 0
        while let identifier = try cursor.next() {
            if row.isMultiple(of: 256) { try Task.checkCancellation() }
            identifiers.insert(identifier)
            row += 1
        }
        return identifiers
    }

    func loadAllEmbeddings() throws -> MediaIndex {
        try loadPhotoEmbeddings(limit: SearchIndexLimits.maximumPhotoRows)
    }

    func loadSearchMediaPage(
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> SearchMediaPage {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.residentMediaItems))
        guard boundedLimit > 0 else {
            return SearchMediaPage(
                photos: MediaIndex(kind: .photo),
                videos: MediaIndex(kind: .videoFrame),
                mediaCount: 0,
                totalPhotoCount: cursor == nil ? try indexedCount() : 0,
                totalVideoCount: cursor == nil ? try videoIndexedCount() : 0,
                nextCursor: nil
            )
        }

        return try dbQueue.read { db in
            // Persisted totals initialize the resident snapshot. Continuation
            // pages do not consume them, so avoid two full COUNT queries on
            // every bounded page scan.
            let totalPhotoCount = cursor == nil ? try IndexedPhoto.fetchCount(db) : 0
            let totalVideoCount = cursor == nil ? try IndexedVideo.fetchCount(db) : 0

            let fetchLimit = boundedLimit + 1
            let photoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .photo,
                includesLocalIdentifier: false,
                sourceID: nil,
                after: cursor,
                limit: fetchLimit
            )
            let videoDescriptors = try Self.loadMediaPageDescriptors(
                in: db,
                mediaType: .video,
                includesLocalIdentifier: false,
                sourceID: nil,
                after: cursor,
                limit: fetchLimit
            )
            let descriptors = try Self.mergeMediaPageDescriptors(
                photoDescriptors,
                videoDescriptors,
                limit: fetchLimit
            )

            let hasMore = descriptors.count > boundedLimit
            let selected = Array(descriptors.prefix(boundedLimit))
            let photoIDs = selected.filter { $0.mediaType == .photo }.map(\.id)
            let videoIDs = selected.filter { $0.mediaType == .video }.map(\.id)
            let photos = try Self.loadPhotoRows(in: db, ids: photoIDs)
            let videos = try Self.loadVideoRows(in: db, ids: videoIDs)
            let nextCursor = hasMore ? selected.last.map {
                SearchMediaPageCursor(
                    creationDate: $0.creationDate,
                    id: $0.id,
                    mediaType: $0.mediaType
                )
            } : nil
            return SearchMediaPage(
                photos: photos,
                videos: videos,
                mediaCount: selected.count,
                totalPhotoCount: totalPhotoCount,
                totalVideoCount: totalVideoCount,
                nextCursor: nextCursor
            )
        }
    }

    static func mediaPageDescriptorQuery(
        mediaType: SearchMediaPageKind,
        includesLocalIdentifier: Bool,
        sourceID: String?,
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) -> MediaPageDescriptorQuery {
        let table: String
        switch mediaType {
        case .photo:
            table = "indexed_photos"
        case .video:
            table = "indexed_videos"
        }
        let columns = includesLocalIdentifier
            ? "id, localIdentifier, creationDate"
            : "id, creationDate"
        var sql = "SELECT \(columns) FROM \(table)"
        var predicates: [String] = []
        var arguments = StatementArguments()
        if let sourceID {
            predicates.append("sourceId = ?")
            arguments += [sourceID]
        }
        if let cursor {
            let idOperator = mediaType.rawValue > cursor.mediaType.rawValue ? ">=" : ">"
            if let creationDate = cursor.creationDate {
                predicates.append(
                    "(creationDate < ? OR creationDate IS NULL OR (creationDate = ? AND id \(idOperator) ?))"
                )
                arguments += [creationDate, creationDate, cursor.id]
            } else {
                predicates.append("creationDate IS NULL AND id \(idOperator) ?")
                arguments += [cursor.id]
            }
        }
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.joined(separator: " AND ")
        }
        sql += " ORDER BY creationDate DESC, id ASC LIMIT ?"
        arguments += [limit]
        return MediaPageDescriptorQuery(sql: sql, arguments: arguments)
    }

    private struct MediaPageDescriptor {
        let mediaType: SearchMediaPageKind
        let id: String
        let localIdentifier: String?
        let creationDate: Date?
    }

    private static func loadMediaPageDescriptors(
        in db: Database,
        mediaType: SearchMediaPageKind,
        includesLocalIdentifier: Bool,
        sourceID: String?,
        after cursor: SearchMediaPageCursor?,
        limit: Int
    ) throws -> [MediaPageDescriptor] {
        let query = mediaPageDescriptorQuery(
            mediaType: mediaType,
            includesLocalIdentifier: includesLocalIdentifier,
            sourceID: sourceID,
            after: cursor,
            limit: limit
        )
        var descriptors: [MediaPageDescriptor] = []
        descriptors.reserveCapacity(limit)
        let rows = try Row.fetchCursor(db, sql: query.sql, arguments: query.arguments)
        while let row = try rows.next() {
            try SearchCancellation.check(descriptors.count)
            descriptors.append(MediaPageDescriptor(
                mediaType: mediaType,
                id: row["id"],
                localIdentifier: includesLocalIdentifier ? row["localIdentifier"] : nil,
                creationDate: row["creationDate"]
            ))
        }
        return descriptors
    }

    private static func mergeMediaPageDescriptors(
        _ photos: [MediaPageDescriptor],
        _ videos: [MediaPageDescriptor],
        limit: Int
    ) throws -> [MediaPageDescriptor] {
        var result: [MediaPageDescriptor] = []
        result.reserveCapacity(limit)
        var photoIndex = 0
        var videoIndex = 0
        while result.count < limit,
              photoIndex < photos.count || videoIndex < videos.count {
            try SearchCancellation.check(result.count)
            if photoIndex >= photos.count {
                result.append(videos[videoIndex])
                videoIndex += 1
            } else if videoIndex >= videos.count
                        || mediaPageDescriptorPrecedes(photos[photoIndex], videos[videoIndex]) {
                result.append(photos[photoIndex])
                photoIndex += 1
            } else {
                result.append(videos[videoIndex])
                videoIndex += 1
            }
        }
        return result
    }

    private static func mediaPageDescriptorPrecedes(
        _ lhs: MediaPageDescriptor,
        _ rhs: MediaPageDescriptor
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.mediaType.rawValue < rhs.mediaType.rawValue
        }
    }

    func loadPhotoEmbedding(id: String) throws -> MediaIndex? {
        try dbQueue.read { db in
            let index = try Self.loadPhotoRows(in: db, ids: [id])
            return index.count == 0 ? nil : index
        }
    }

    private static func loadPhotoRows(in db: Database, ids: [String]) throws -> MediaIndex {
        guard !ids.isEmpty else { return MediaIndex(kind: .photo) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var arguments = StatementArguments([EmbeddingConfig.bytesPerEmbedding])
        arguments += StatementArguments(ids)
        var index = MediaIndex(kind: .photo)
        index.reserveCapacity(ids.count)
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, localIdentifier, sourceId, filePath, creationDate,
                       latitude, longitude,
                       substr(locationCity, 1, 256) AS locationCity,
                       substr(locationState, 1, 256) AS locationState,
                       substr(locationCountry, 1, 256) AS locationCountry,
                       substr(locationName, 1, 256) AS locationName,
                       substr(ocrText, 1, 4096) AS ocrText,
                       substr(sceneLabels, 1, 1024) AS sceneLabels,
                       CASE WHEN length(embedding) = ? THEN embedding END AS embedding
                FROM indexed_photos
                WHERE id IN (\(placeholders))
                ORDER BY creationDate DESC, id ASC
            """,
            arguments: arguments
        )
        var rowNumber = 0
        while let row = try cursor.next() {
            try SearchCancellation.check(rowNumber)
            guard let data: Data = row["embedding"],
                  let embedding = data.validatedFloat16Embedding() else {
                throw SearchEngineError.corruptedIndex
            }
            try index.append(
                MediaIndex.Row(
                    id: row["id"], localIdentifier: row["localIdentifier"],
                    sourceId: row["sourceId"], filePath: row["filePath"],
                    date: row["creationDate"], latitude: row["latitude"],
                    longitude: row["longitude"], city: row["locationCity"],
                    state: row["locationState"], country: row["locationCountry"],
                    locationName: row["locationName"],
                    details: .photo(ocrText: row["ocrText"], sceneLabels: row["sceneLabels"])
                ),
                embedding: embedding
            )
            rowNumber += 1
        }
        return index
    }

    private static func loadVideoRows(in db: Database, ids: [String]) throws -> MediaIndex {
        guard !ids.isEmpty else { return MediaIndex(kind: .videoFrame) }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let invalidVideoID = try String.fetchOne(
            db,
            sql: """
                SELECT v.id
                FROM indexed_videos v
                LEFT JOIN indexed_video_frames f ON f.videoId = v.id
                WHERE v.id IN (\(placeholders))
                GROUP BY v.id
                HAVING COUNT(f.id) < 1 OR COUNT(f.id) > ?
                LIMIT 1
            """,
            arguments: StatementArguments(ids)
                + [SearchIndexLimits.maximumVideoFramesPerMedia]
        )
        guard invalidVideoID == nil else {
            throw SearchEngineError.corruptedIndex
        }
        var arguments = StatementArguments([EmbeddingConfig.bytesPerEmbedding])
        arguments += StatementArguments(ids)
        var index = MediaIndex(kind: .videoFrame)
        index.reserveCapacity(ids.count * SearchIndexLimits.maximumVideoFramesPerMedia)
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT v.id, v.localIdentifier, v.sourceId, v.creationDate,
                       v.latitude, v.longitude,
                       substr(v.locationCity, 1, 256) AS locationCity,
                       substr(v.locationState, 1, 256) AS locationState,
                       substr(v.locationCountry, 1, 256) AS locationCountry,
                       substr(v.locationName, 1, 256) AS locationName,
                       f.framePosition,
                       CASE WHEN length(f.embedding) = ? THEN f.embedding END AS embedding
                FROM indexed_video_frames f
                JOIN indexed_videos v ON f.videoId = v.id
                WHERE v.id IN (\(placeholders))
                ORDER BY v.creationDate DESC, v.id ASC, f.framePosition ASC, f.id ASC
            """,
            arguments: arguments
        )
        var rowNumber = 0
        while let row = try cursor.next() {
            try SearchCancellation.check(rowNumber)
            guard let data: Data = row["embedding"],
                  let embedding = data.validatedFloat16Embedding() else {
                throw SearchEngineError.corruptedIndex
            }
            try index.append(
                MediaIndex.Row(
                    id: row["id"], localIdentifier: row["localIdentifier"],
                    sourceId: row["sourceId"], filePath: nil,
                    date: row["creationDate"], latitude: row["latitude"],
                    longitude: row["longitude"], city: row["locationCity"],
                    state: row["locationState"], country: row["locationCountry"],
                    locationName: row["locationName"],
                    details: .videoFrame(position: row["framePosition"])
                ),
                embedding: embedding
            )
            rowNumber += 1
        }
        return index
    }

    func loadPhotoEmbeddings(
        limit: Int,
        mediaLimit: Int = SearchIndexLimits.maximumMediaItems
    ) throws -> MediaIndex {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumPhotoRows))
        let boundedMediaLimit = max(0, min(mediaLimit, SearchIndexLimits.maximumMediaItems))
        guard boundedLimit > 0, boundedMediaLimit > 0 else { return MediaIndex(kind: .photo) }
        #if DEBUG
        let loadStart = CFAbsoluteTimeGetCurrent()
        #endif
        let result = try dbQueue.read { db in
            var index = MediaIndex(kind: .photo)
            let rowCount = try Int.fetchOne(
                db,
                sql: """
                    WITH selected_media AS (
                        SELECT mediaType, id FROM (
                            SELECT 'photo' AS mediaType, id, creationDate FROM indexed_photos
                            UNION ALL
                            SELECT 'video' AS mediaType, id, creationDate FROM indexed_videos
                        )
                        ORDER BY creationDate DESC, id ASC, mediaType ASC
                        LIMIT ?
                    )
                    SELECT COUNT(*) FROM (
                        SELECT 1 FROM indexed_photos p
                        JOIN selected_media s ON s.mediaType = 'photo' AND s.id = p.id
                        LIMIT ?
                    )
                    """,
                arguments: [boundedMediaLimit, boundedLimit]
            ) ?? 0
            index.reserveCapacity(rowCount)

            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    WITH selected_media AS (
                        SELECT mediaType, id FROM (
                            SELECT 'photo' AS mediaType, id, creationDate FROM indexed_photos
                            UNION ALL
                            SELECT 'video' AS mediaType, id, creationDate FROM indexed_videos
                        )
                        ORDER BY creationDate DESC, id ASC, mediaType ASC
                        LIMIT ?
                    )
                    SELECT p.id, p.localIdentifier, p.sourceId, p.filePath, p.creationDate,
                           p.latitude, p.longitude,
                           substr(p.locationCity, 1, 256) AS locationCity,
                           substr(p.locationState, 1, 256) AS locationState,
                           substr(p.locationCountry, 1, 256) AS locationCountry,
                           substr(p.locationName, 1, 256) AS locationName,
                           substr(p.ocrText, 1, 4096) AS ocrText,
                           substr(p.sceneLabels, 1, 1024) AS sceneLabels,
                           CASE WHEN length(p.embedding) = ? THEN p.embedding END AS embedding
                    FROM indexed_photos p
                    JOIN selected_media s ON s.mediaType = 'photo' AND s.id = p.id
                    ORDER BY p.creationDate DESC, p.id ASC
                    LIMIT ?
                """,
                arguments: [boundedMediaLimit, EmbeddingConfig.bytesPerEmbedding, boundedLimit]
            )

            var rowNumber = 0
            while let photo = try cursor.next() {
                if rowNumber.isMultiple(of: 64) { try Task.checkCancellation() }
                guard let embeddingData: Data = photo["embedding"] else {
                    throw SearchEngineError.corruptedIndex
                }
                let row = MediaIndex.Row(
                    id: photo["id"],
                    localIdentifier: photo["localIdentifier"],
                    sourceId: photo["sourceId"],
                    filePath: photo["filePath"],
                    date: photo["creationDate"],
                    latitude: photo["latitude"],
                    longitude: photo["longitude"],
                    city: photo["locationCity"],
                    state: photo["locationState"],
                    country: photo["locationCountry"],
                    locationName: photo["locationName"],
                    details: .photo(
                        ocrText: photo["ocrText"],
                        sceneLabels: photo["sceneLabels"]
                    )
                )
                guard let embedding = embeddingData.validatedFloat16Embedding() else {
                    throw SearchEngineError.corruptedIndex
                }
                try index.append(row, embedding: embedding)
                rowNumber += 1
            }

            return index
        }

        #if DEBUG
        logger.info("[Database] Loaded \(result.ids.count) photo embeddings in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - loadStart))s")
        #endif

        return result
    }

    func loadEmbeddingsForDuplicateScan(limit: Int) throws -> MediaIndex {
        let boundedLimit = max(0, min(limit, IndexingConfig.maxDuplicateScanPhotos))
        guard boundedLimit > 0 else { return MediaIndex(kind: .photo) }

        return try dbQueue.read { db in
            var index = MediaIndex(kind: .photo)
            index.reserveCapacity(boundedLimit)
            let cursor = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, localIdentifier, sourceId, filePath, creationDate,
                           latitude, longitude,
                           substr(locationCity, 1, 256) AS locationCity,
                           substr(locationState, 1, 256) AS locationState,
                           substr(locationCountry, 1, 256) AS locationCountry,
                           substr(locationName, 1, 256) AS locationName,
                           substr(ocrText, 1, 4096) AS ocrText,
                           substr(sceneLabels, 1, 1024) AS sceneLabels,
                           CASE WHEN length(embedding) = ? THEN embedding END AS embedding
                    FROM indexed_photos
                    WHERE sourceId = ?
                    ORDER BY creationDate DESC, id ASC
                    LIMIT ?
                    """,
                arguments: [
                    EmbeddingConfig.bytesPerEmbedding,
                    PhotoSourceType.photokit.rawValue,
                    boundedLimit,
                ]
            )

            while let photo = try cursor.next() {
                try Task.checkCancellation()
                guard let embeddingData: Data = photo["embedding"] else {
                    throw SearchEngineError.corruptedIndex
                }
                guard let embedding = embeddingData.validatedFloat16Embedding() else {
                    throw SearchEngineError.corruptedIndex
                }
                try index.append(
                    MediaIndex.Row(
                        id: photo["id"],
                        localIdentifier: photo["localIdentifier"],
                        sourceId: photo["sourceId"],
                        filePath: photo["filePath"],
                        date: photo["creationDate"],
                        latitude: photo["latitude"],
                        longitude: photo["longitude"],
                        city: photo["locationCity"],
                        state: photo["locationState"],
                        country: photo["locationCountry"],
                        locationName: photo["locationName"],
                        details: .photo(
                            ocrText: photo["ocrText"],
                            sceneLabels: photo["sceneLabels"]
                        )
                    ),
                    embedding: embedding
                )
            }
            return index
        }
    }

    /// Removes derived media index data while preserving user-selected folder
    /// sources and their security-scoped bookmarks for the subsequent rebuild.
    func resetIndexedMedia() throws {
        try dbQueue.write { db in
            _ = try IndexedPhoto.deleteAll(db)
            _ = try db.execute(sql: "DELETE FROM indexed_video_frames")
            _ = try IndexedVideo.deleteAll(db)
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = 0, lastIndexedAt = NULL"
            )
        }
    }

    func deletePhoto(localIdentifier: String) throws {
        try dbQueue.write { db in
            _ = try IndexedPhoto.filter(Column("localIdentifier") == localIdentifier).deleteAll(db)
        }
    }

    func photosNeedingEnrichment(limit: Int = IndexingConfig.enrichmentBatchSize) throws -> [PhotoEnrichmentCandidate] {
        try dbQueue.read { db in
            let retryBefore = Date().addingTimeInterval(-IndexingConfig.enrichmentRetryDelaySeconds)
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, pixelWidth, pixelHeight, sourceId, filePath FROM indexed_photos
                WHERE enrichmentComplete = 0
                  AND (enrichmentAttemptedAt IS NULL OR enrichmentAttemptedAt <= ?)
                ORDER BY creationDate DESC
                LIMIT ?
            """, arguments: [retryBefore, limit])
            return rows.map {
                PhotoEnrichmentCandidate(
                    localIdentifier: $0["localIdentifier"] as String,
                    pixelWidth: $0["pixelWidth"] as Int,
                    pixelHeight: $0["pixelHeight"] as Int,
                    sourceId: $0["sourceId"] as String,
                    filePath: $0["filePath"] as String?
                )
            }
        }
    }

    func photosNeedingEnrichmentCount() throws -> Int {
        try dbQueue.read { db in
            let retryBefore = Date().addingTimeInterval(-IndexingConfig.enrichmentRetryDelaySeconds)
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_photos
                WHERE enrichmentComplete = 0
                  AND (enrichmentAttemptedAt IS NULL OR enrichmentAttemptedAt <= ?)
            """, arguments: [retryBefore]) ?? 0
        }
    }

    func updatePhotoEnrichment(_ updates: [PhotoEnrichmentUpdate]) throws {
        guard !updates.isEmpty else { return }
        try dbQueue.write { db in
            for update in updates {
                switch update.outcome {
                case .completed:
                    try db.execute(
                        sql: """
                            UPDATE indexed_photos
                            SET ocrText = ?, sharpnessScore = ?, sceneLabels = ?,
                                enrichmentComplete = 1, enrichmentAttemptedAt = NULL
                            WHERE localIdentifier = ?
                        """,
                        arguments: [
                            PersistedMetadataTextPolicy.bounded(
                                update.ocrText,
                                maximumCharacters: PersistedMetadataTextPolicy.maximumOCRCharacters
                            ),
                            update.sharpnessScore,
                            PersistedMetadataTextPolicy.bounded(
                                update.sceneLabels,
                                maximumCharacters: PersistedMetadataTextPolicy.maximumSceneLabelCharacters
                            ),
                            update.localIdentifier
                        ]
                    )
                case .loadFailed(let attemptedAt):
                    try db.execute(
                        sql: """
                            UPDATE indexed_photos
                            SET enrichmentAttemptedAt = ?
                            WHERE localIdentifier = ? AND enrichmentComplete = 0
                        """,
                        arguments: [attemptedAt, update.localIdentifier]
                    )
                }
            }
        }
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

    // MARK: - Sources

    func insertSource(_ source: PhotoSource) throws {
        try requireIndexingWrites()
        try dbQueue.write { db in
            var source = source
            if source.type == PhotoSourceType.folder.rawValue {
                if let path = source.path {
                    source.path = PhotoSourcePolicy.canonicalPath(
                        URL(fileURLWithPath: path)
                    )
                }
                let folderCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM photo_sources WHERE type = ?",
                    arguments: [PhotoSourceType.folder.rawValue]
                ) ?? 0
                guard folderCount < PhotoSourcePolicy.maximumFolderSources else {
                    throw PhotoSourceRegistrationError.sourceLimitReached
                }
                if let path = source.path {
                    let duplicateCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM photo_sources WHERE type = ? AND path = ?",
                        arguments: [PhotoSourceType.folder.rawValue, path]
                    ) ?? 0
                    guard duplicateCount == 0 else {
                        throw PhotoSourceRegistrationError.duplicateFolder
                    }
                }
            }
            try source.insert(db)
        }
    }

    func listSources() throws -> [PhotoSource] {
        try dbQueue.read { db in
            try PhotoSource.filter(Column("type") == PhotoSourceType.folder.rawValue)
                .order(Column("addedAt").desc)
                .fetchAll(db)
        }
    }

    func deleteSource(_ id: String) throws {
        try deleteSource(id) { sourceID in
            try FolderBookmarkStore.remove(for: sourceID)
        }
    }

    func deleteSource(
        _ id: String,
        removeBookmark: (String) throws -> Void
    ) throws {
        do {
            try removeBookmark(id)
        } catch {
            logger.error("Failed to clean up a folder bookmark before deletion: \(error.safeDiagnosticCode)")
            throw FolderSourceDeletionError.bookmarkCleanupFailed
        }
        try dbQueue.write { db in
            _ = try IndexedPhoto.filter(Column("sourceId") == id).deleteAll(db)
            _ = try PhotoSource.filter(Column("id") == id).deleteAll(db)
        }
    }

    func updateSourceStats(_ id: String, photoCount: Int) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = ?, lastIndexedAt = ? WHERE id = ?",
                arguments: [photoCount, Date(), id]
            )
        }
    }

    // MARK: - Videos

    func isVideoIndexed(localIdentifier: String) throws -> Bool {
        try dbQueue.read { db in
            try IndexedVideo.filter(Column("localIdentifier") == localIdentifier).fetchCount(db) > 0
        }
    }

    func existingVideoIdentifiers(in localIdentifiers: [String]) throws -> Set<String> {
        try existingStrings(
            localIdentifiers,
            table: "indexed_videos",
            column: "localIdentifier"
        )
    }

    func videoIndexedCount() throws -> Int {
        try dbQueue.read { db in try IndexedVideo.fetchCount(db) }
    }

    func allIndexedVideoIdentifiers() throws -> Set<String> {
        try dbQueue.read { db in
            try Self.loadIdentifierSet(
                db,
                sql: """
                    SELECT localIdentifier FROM indexed_videos
                    ORDER BY creationDate DESC, id ASC
                    LIMIT ?
                """,
                limit: SearchIndexLimits.maximumMediaItems
            )
        }
    }

    func loadAllVideoEmbeddings() throws -> MediaIndex {
        try loadVideoEmbeddings(limit: SearchIndexLimits.maximumVideoFrameRows)
    }

    func loadVideoEmbeddings(
        limit: Int,
        mediaLimit: Int = SearchIndexLimits.maximumMediaItems
    ) throws -> MediaIndex {
        let boundedLimit = max(0, min(limit, SearchIndexLimits.maximumVideoFrameRows))
        let boundedMediaLimit = max(0, min(mediaLimit, SearchIndexLimits.maximumMediaItems))
        guard boundedLimit > 0, boundedMediaLimit > 0 else { return MediaIndex(kind: .videoFrame) }
        return try dbQueue.read { db in
            let sql = """
                WITH selected_media AS (
                    SELECT mediaType, id FROM (
                        SELECT 'photo' AS mediaType, id, creationDate FROM indexed_photos
                        UNION ALL
                        SELECT 'video' AS mediaType, id, creationDate FROM indexed_videos
                    )
                    ORDER BY creationDate DESC, id ASC, mediaType ASC
                    LIMIT ?
                )
                SELECT v.id, v.localIdentifier, v.sourceId, v.creationDate, v.latitude, v.longitude,
                       substr(v.locationCity, 1, 256) AS locationCity,
                       substr(v.locationState, 1, 256) AS locationState,
                       substr(v.locationCountry, 1, 256) AS locationCountry,
                       substr(v.locationName, 1, 256) AS locationName,
                       f.framePosition,
                       CASE WHEN length(f.embedding) = ? THEN f.embedding END AS embedding
                FROM indexed_video_frames f
                JOIN indexed_videos v ON f.videoId = v.id
                JOIN selected_media s ON s.mediaType = 'video' AND s.id = v.id
                ORDER BY v.creationDate DESC, v.id ASC, f.framePosition ASC, f.id ASC
            """
            var index = MediaIndex(kind: .videoFrame)
            let rowCount = try Int.fetchOne(
                db,
                sql: """
                    WITH selected_media AS (
                        SELECT mediaType, id FROM (
                            SELECT 'photo' AS mediaType, id, creationDate FROM indexed_photos
                            UNION ALL
                            SELECT 'video' AS mediaType, id, creationDate FROM indexed_videos
                        )
                        ORDER BY creationDate DESC, id ASC, mediaType ASC
                        LIMIT ?
                    )
                    SELECT COUNT(*) FROM (
                        SELECT 1 FROM indexed_video_frames f
                        JOIN indexed_videos v ON f.videoId = v.id
                        JOIN selected_media s ON s.mediaType = 'video' AND s.id = v.id
                        LIMIT ?
                    )
                    """,
                arguments: [boundedMediaLimit, boundedLimit]
            ) ?? 0
            index.reserveCapacity(rowCount)
            let cursor = try Row.fetchCursor(
                db,
                sql: sql + "\nLIMIT ?",
                arguments: [
                    boundedMediaLimit,
                    EmbeddingConfig.bytesPerEmbedding,
                    boundedLimit,
                ]
            )

            var rowNumber = 0
            while let row = try cursor.next() {
                if rowNumber.isMultiple(of: 64) { try Task.checkCancellation() }
                guard let embeddingData: Data = row["embedding"] else {
                    throw SearchEngineError.corruptedIndex
                }
                let indexRow = MediaIndex.Row(
                    id: row["id"],
                    localIdentifier: row["localIdentifier"],
                    sourceId: row["sourceId"],
                    filePath: nil,
                    date: row["creationDate"],
                    latitude: row["latitude"],
                    longitude: row["longitude"],
                    city: row["locationCity"],
                    state: row["locationState"],
                    country: row["locationCountry"],
                    locationName: row["locationName"],
                    details: .videoFrame(position: row["framePosition"])
                )
                guard let embedding = embeddingData.validatedFloat16Embedding() else {
                    throw SearchEngineError.corruptedIndex
                }
                try index.append(indexRow, embedding: embedding)
                rowNumber += 1
            }

            return index
        }
    }

    func deleteOrphanedPhotos(localIdentifiers: Set<String>) throws {
        guard !localIdentifiers.isEmpty else { return }
        let chunks = Array(localIdentifiers).chunked(into: 900)
        try dbQueue.write { db in
            for chunk in chunks {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(chunk)
                try db.execute(
                    sql: "DELETE FROM indexed_photos WHERE localIdentifier IN (\(placeholders))",
                    arguments: args
                )
            }
        }
    }

    func deleteOrphanedVideos(localIdentifiers: Set<String>) throws {
        guard !localIdentifiers.isEmpty else { return }
        let chunks = Array(localIdentifiers).chunked(into: 900)
        try dbQueue.write { db in
            for chunk in chunks {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(chunk)
                try db.execute(
                    sql: "DELETE FROM indexed_video_frames WHERE videoId IN (SELECT id FROM indexed_videos WHERE localIdentifier IN (\(placeholders)))",
                    arguments: args
                )
                try db.execute(
                    sql: "DELETE FROM indexed_videos WHERE localIdentifier IN (\(placeholders))",
                    arguments: args
                )
            }
        }
    }

    @discardableResult
    func insertVideo(
        _ video: IndexedVideo,
        _ frames: [IndexedVideoFrame],
        completingRequiredRebuild: Bool
    ) throws -> Bool {
        guard (1...SearchIndexLimits.maximumVideoFramesPerMedia).contains(frames.count),
              frames.allSatisfy({
            $0.videoId == video.id
                && $0.framePosition.isFinite
                && (0...1).contains($0.framePosition)
                && $0.embedding.validatedFloat16Embedding() != nil
        }) else {
            throw SearchEngineError.corruptedIndex
        }
        try requireIndexingWrites()
        return try dbQueue.write { db in
            var completesRequiredRebuild = false
            if completingRequiredRebuild {
                completesRequiredRebuild = try Self.shouldCompleteRequiredRebuildOnNextEmbeddingWrite(
                    in: db
                )
            }
            var video = video
            video.frameCount = frames.count
            if !LocationCoordinatePolicy.isValidOrAbsent(
                latitude: video.latitude,
                longitude: video.longitude
            ) {
                video.latitude = nil
                video.longitude = nil
            }
            video.locationCity = PersistedMetadataTextPolicy.bounded(
                video.locationCity,
                maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
            )
            video.locationState = PersistedMetadataTextPolicy.bounded(
                video.locationState,
                maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
            )
            video.locationCountry = PersistedMetadataTextPolicy.bounded(
                video.locationCountry,
                maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
            )
            video.locationName = PersistedMetadataTextPolicy.bounded(
                video.locationName,
                maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters
            )
            try video.insert(db)
            for frame in frames { try frame.insert(db) }
            if completesRequiredRebuild {
                try Self.clearIndexRebuildRequired(in: db)
            }
            return completesRequiredRebuild
        }
    }

    func trimToLimit(_ limit: Int) throws {
        try dbQueue.write { db in
            _ = try Self.trimMedia(in: db, to: limit)
        }
    }

    func reconcileFreeTier(_ limit: Int) throws -> FreeTierReconciliationResult {
        try reconcileFreeTier(limit, whilePermitted: { true })
    }

    func reconcileFreeTier(
        _ limit: Int,
        whilePermitted: @escaping @Sendable () -> Bool
    ) throws -> FreeTierReconciliationResult {
        try dbQueue.write { db in
            guard whilePermitted() else { throw CancellationError() }
            // Folder access is a Pro feature. Remove every non-PhotoKit row,
            // including rows whose source record is missing or malformed. Keep
            // source registrations and bookmarks so a later Pro entitlement
            // can resume without requiring the user to select folders again.
            try db.execute(
                sql: "DELETE FROM indexed_photos WHERE sourceId != ?",
                arguments: [PhotoSourceType.photokit.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM indexed_video_frames WHERE videoId IN (SELECT id FROM indexed_videos WHERE sourceId != ?)",
                arguments: [PhotoSourceType.photokit.rawValue]
            )
            try db.execute(
                sql: "DELETE FROM indexed_videos WHERE sourceId != ?",
                arguments: [PhotoSourceType.photokit.rawValue]
            )
            try db.execute(
                sql: "UPDATE photo_sources SET photoCount = 0, lastIndexedAt = NULL WHERE type = ? OR id != ?",
                arguments: [PhotoSourceType.folder.rawValue, PhotoSourceType.photokit.rawValue]
            )

            let didTrim = try Self.trimMedia(in: db, to: limit)
            let retainedCount = try IndexedPhoto.fetchCount(db) + IndexedVideo.fetchCount(db)
            guard whilePermitted() else { throw CancellationError() }
            return FreeTierReconciliationResult(
                retainedMediaCount: retainedCount,
                didTrimMedia: didTrim
            )
        }
    }

    private static func trimMedia(in db: Database, to limit: Int) throws -> Bool {
            let safeLimit = max(0, limit)
            let photoCount = try IndexedPhoto.fetchCount(db)
            let videoCount = try IndexedVideo.fetchCount(db)
            let totalCount = photoCount + videoCount

            guard totalCount > safeLimit else { return false }

            // Proportional allocation: each type keeps its share of the limit
            let photoLimit: Int
            let videoLimit: Int
            if photoCount == 0 {
                photoLimit = 0
                videoLimit = safeLimit
            } else if videoCount == 0 {
                photoLimit = safeLimit
                videoLimit = 0
            } else {
                photoLimit = max(Int(Double(photoCount) / Double(totalCount) * Double(safeLimit)), 1)
                videoLimit = max(safeLimit - photoLimit, 1)
            }

            // Trim photos
            if photoCount > photoLimit {
                try db.execute(sql: """
                    DELETE FROM indexed_photos WHERE id NOT IN (
                        SELECT id FROM indexed_photos ORDER BY indexedAt DESC LIMIT ?
                    )
                """, arguments: [photoLimit])
            }

            // Trim videos (delete frames first due to foreign key)
            if videoCount > videoLimit {
                try db.execute(sql: """
                    DELETE FROM indexed_video_frames WHERE videoId IN (
                        SELECT id FROM indexed_videos WHERE id NOT IN (
                            SELECT id FROM indexed_videos ORDER BY indexedAt DESC LIMIT ?
                        )
                    )
                """, arguments: [videoLimit])
                try db.execute(sql: """
                    DELETE FROM indexed_videos WHERE id NOT IN (
                        SELECT id FROM indexed_videos ORDER BY indexedAt DESC LIMIT ?
                    )
                """, arguments: [videoLimit])
            }
            return true
    }

    func photosNeedingLocationBackfill(limit: Int = 500) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_photos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
                AND (locationCity IS NULL OR locationCity = '')
                LIMIT ?
            """, arguments: [limit])
            return rows.map { (
                $0["localIdentifier"] as String,
                $0["latitude"] as Double,
                $0["longitude"] as Double
            ) }
        }
    }

    func videosNeedingLocationBackfill(limit: Int = 500) throws -> [(localIdentifier: String, lat: Double, lon: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localIdentifier, latitude, longitude FROM indexed_videos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
                AND (locationCity IS NULL OR locationCity = '')
                LIMIT ?
            """, arguments: [limit])
            return rows.map { (
                $0["localIdentifier"] as String,
                $0["latitude"] as Double,
                $0["longitude"] as Double
            ) }
        }
    }

    func geocodingCounts() throws -> GeocodingCounts {
        try dbQueue.read { db in
            let photosWithGPS = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_photos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
            """) ?? 0
            let videosWithGPS = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_videos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
            """) ?? 0
            let photosRemaining = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_photos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
                AND (locationCity IS NULL OR locationCity = '')
            """) ?? 0
            let videosRemaining = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM indexed_videos
                WHERE latitude BETWEEN -90 AND 90
                AND longitude BETWEEN -180 AND 180
                AND (locationCity IS NULL OR locationCity = '')
            """) ?? 0
            return GeocodingCounts(
                totalWithGPS: photosWithGPS + videosWithGPS,
                remaining: photosRemaining + videosRemaining,
                indexedPhotos: try IndexedPhoto.fetchCount(db),
                indexedVideos: try IndexedVideo.fetchCount(db)
            )
        }
    }

    func updatePhotoLocationStrings(localIdentifier: String, city: String?, state: String?,
                                    country: String?, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_photos
                    SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?
                    WHERE localIdentifier = ?
                """,
                arguments: [
                    PersistedMetadataTextPolicy.bounded(city, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(state, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(country, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(name, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    localIdentifier
                ]
            )
        }
    }

    func updateVideoLocationStrings(localIdentifier: String, city: String?, state: String?,
                                    country: String?, name: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_videos
                    SET locationCity = ?, locationState = ?, locationCountry = ?, locationName = ?
                    WHERE localIdentifier = ?
                """,
                arguments: [
                    PersistedMetadataTextPolicy.bounded(city, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(state, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(country, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    PersistedMetadataTextPolicy.bounded(name, maximumCharacters: PersistedMetadataTextPolicy.maximumLocationCharacters),
                    localIdentifier
                ]
            )
        }
    }

    func fetchRandomPhoto(sharp: Bool) throws -> SlideshowPhoto? {
        try dbQueue.read { db in
            var photo: SlideshowPhoto?
            if sharp {
                photo = try Self.fetchRandomSlideshowPhoto(
                    db,
                    sharpOnly: true
                )
            }
            if photo == nil {
                photo = try Self.fetchRandomSlideshowPhoto(db, sharpOnly: false)
            }
            return photo
        }
    }

    private static func fetchRandomSlideshowPhoto(
        _ db: Database,
        sharpOnly: Bool
    ) throws -> SlideshowPhoto? {
        let sharpClause = sharpOnly ? "AND sharpnessScore > 50" : ""
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT id, localIdentifier, creationDate, sourceId, filePath,
                       CASE WHEN length(embedding) = ? THEN embedding END AS embedding
                FROM indexed_photos
                WHERE rowid IN (
                    SELECT rowid FROM indexed_photos
                    ORDER BY rowid DESC
                    LIMIT ?
                )
                \(sharpClause)
                ORDER BY RANDOM()
                LIMIT 1
            """,
            arguments: [
                EmbeddingConfig.bytesPerEmbedding,
                SearchIndexLimits.maximumPhotoRows,
            ]
        ) else {
            return nil
        }
        guard let embedding: Data = row["embedding"] else {
            throw SearchEngineError.corruptedIndex
        }
        return SlideshowPhoto(
            id: row["id"],
            localIdentifier: row["localIdentifier"],
            creationDate: row["creationDate"],
            embedding: embedding,
            sourceId: row["sourceId"],
            filePath: row["filePath"]
        )
    }

    func onThisDayPhotos() throws -> [(year: Int, photos: [IndexedPhotoReference])] {
        let calendar = Calendar.current
        let today = Date()
        let currentMonth = calendar.component(.month, from: today)
        let currentDay = calendar.component(.day, from: today)
        let currentYear = calendar.component(.year, from: today)

        return try dbQueue.read { db in
            let sql = """
                SELECT id, localIdentifier, creationDate, sourceId, filePath
                FROM indexed_photos
                WHERE rowid IN (
                    SELECT rowid FROM indexed_photos
                    ORDER BY rowid DESC
                    LIMIT ?
                )
                  AND creationDate IS NOT NULL
                  AND cast(strftime('%m', creationDate) as integer) = ?
                  AND abs(cast(strftime('%d', creationDate) as integer) - ?) <= 1
                  AND cast(strftime('%Y', creationDate) as integer) < ?
                ORDER BY creationDate DESC
                LIMIT ?
            """
            let cursor = try Row.fetchCursor(
                db,
                sql: sql,
                arguments: [
                    SearchIndexLimits.maximumPhotoRows,
                    currentMonth,
                    currentDay,
                    currentYear,
                    MemoryConfig.maximumOnThisDayYears
                        * MemoryConfig.maximumOnThisDayPhotosPerYear,
                ]
            )
            var yearGroups: [Int: [IndexedPhotoReference]] = [:]
            while let row = try cursor.next() {
                guard let date: Date = row["creationDate"] else { continue }
                let year = calendar.component(.year, from: date)
                if yearGroups[year] == nil,
                   yearGroups.count >= MemoryConfig.maximumOnThisDayYears {
                    break
                }
                guard yearGroups[year, default: []].count
                        < MemoryConfig.maximumOnThisDayPhotosPerYear else { continue }
                yearGroups[year, default: []].append(IndexedPhotoReference(
                    id: row["id"],
                    localIdentifier: row["localIdentifier"],
                    creationDate: date,
                    sourceId: row["sourceId"],
                    filePath: row["filePath"]
                ))
            }

            return yearGroups
                .sorted { $0.key > $1.key }
                .map { (year: $0.key, photos: $0.value) }
        }
    }

    // MARK: - Search History

    func addSearchHistory(_ query: String) throws {
        let boundedQuery = QueryInputPolicy.bounded(query)
        guard !boundedQuery.isEmpty else { return }
        try dbQueue.write { db in
            // Remove existing duplicate (case-insensitive)
            try db.execute(sql: "DELETE FROM search_history WHERE LOWER(query) = LOWER(?)", arguments: [boundedQuery])
            try db.execute(
                sql: "INSERT INTO search_history (query, searchedAt) VALUES (?, ?)",
                arguments: [boundedQuery, Date()]
            )
            // Keep only the most recent 20
            try db.execute(sql: """
                DELETE FROM search_history WHERE id NOT IN (
                    SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT 20
                )
            """)
        }
    }

    func loadSearchHistory() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT query FROM search_history ORDER BY searchedAt DESC LIMIT 20")
        }
    }

    func clearSearchHistory() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM search_history")
        }
    }

    func removeSearchHistory(at index: Int) throws {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM search_history ORDER BY searchedAt DESC LIMIT 20")
            guard index < rows.count else { return }
            let id: Int64 = rows[index]["id"]
            try db.execute(sql: "DELETE FROM search_history WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Smart Albums

    func loadSmartAlbums() throws -> [SmartAlbum] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, name, query, createdAt FROM smart_albums ORDER BY createdAt DESC LIMIT ?",
                arguments: [SmartAlbumPolicy.maximumAlbums]
            ).map { row in
                SmartAlbum(
                    id: row["id"],
                    name: row["name"],
                    query: row["query"],
                    createdAt: row["createdAt"]
                )
            }
        }
    }

    func saveSmartAlbum(_ album: SmartAlbum) throws {
        let boundedAlbum = SmartAlbum(
            id: album.id,
            name: SmartAlbumPolicy.boundedName(album.name),
            query: QueryInputPolicy.bounded(album.query),
            createdAt: album.createdAt
        )
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO smart_albums (id, name, query, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [boundedAlbum.id, boundedAlbum.name, boundedAlbum.query, boundedAlbum.createdAt]
            )
            try db.execute(sql: """
                DELETE FROM smart_albums WHERE id NOT IN (
                    SELECT id FROM smart_albums ORDER BY createdAt DESC LIMIT ?
                )
            """, arguments: [SmartAlbumPolicy.maximumAlbums])
        }
    }

    func deleteSmartAlbum(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM smart_albums WHERE id = ?", arguments: [id])
        }
    }

    private func requireIndexingWrites() throws {
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
