import Foundation
import ImageIO

enum FolderDisplayNamePolicy {
    static let maximumCharacters = 100

    static func sanitized(_ value: String) -> String {
        let withoutControls = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = QueryInputPolicy.bounded(
            trimmed,
            maximumUnicodeScalars: maximumCharacters,
            maximumUTF8Bytes: maximumCharacters * 4
        )
        return bounded.isEmpty ? "Folder" : bounded
    }
}

enum FolderSourceRegistration {
    @MainActor
    static func register(
        bookmarkData: Data,
        sourceId: String,
        persistBookmark: (Data) throws -> Void,
        insertSource: @escaping @Sendable () throws -> Void,
        removeSource: @escaping @Sendable () throws -> Void,
        removeBookmark: () throws -> Void
    ) async throws {
        _ = sourceId
        try persistBookmark(bookmarkData)
        var didInsertSource = false
        do {
            let insertTask = Task.detached(priority: .utility) {
                try insertSource()
            }
            try await withTaskCancellationHandler {
                try await insertTask.value
            } onCancel: {
                insertTask.cancel()
            }
            didInsertSource = true
            try Task.checkCancellation()
        } catch {
            var shouldRemoveBookmark = !didInsertSource
            if didInsertSource {
                do {
                    try await Task.detached(priority: .utility) {
                        try removeSource()
                    }.value
                    shouldRemoveBookmark = true
                } catch FolderSourceDeletionError.bookmarkCleanupFailed {
                    // Database rows are already gone; retry only the remaining
                    // bookmark cleanup below.
                    shouldRemoveBookmark = true
                } catch let rollbackError {
                    logger.error("Failed to roll back cancelled folder source registration: \(rollbackError.safeDiagnosticCode)")
                }
            }
            if shouldRemoveBookmark {
                do {
                    try removeBookmark()
                } catch let cleanupError {
                    logger.error("Failed to clean up a folder bookmark after registration failure: \(cleanupError.safeDiagnosticCode)")
                }
            }
            throw error
        }
    }
}

enum FolderScanOperation {
    static func run(
        operation: @escaping @Sendable () async -> [URL]
    ) async -> [URL] {
        let scanTask = Task.detached(priority: .utility) {
            await operation()
        }
        return await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
    }
}

private enum FolderSourceRegistrationError: Error {
    case bookmarkPersistenceFailed
}

@MainActor
final class FolderIndexingWorker {
    nonisolated static func shouldPersistFolderWrite(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    struct Callbacks {
        let searchableCount: () -> Int
        let setProgress: (IndexingProgress) -> Void
        let reloadSearchIndex: () async -> Void
    }

    private let imageEncoder: ImageEncoder
    private let database: DatabaseProtocol
    private let batchSize: Int
    private let callbacks: Callbacks

    init(
        imageEncoder: ImageEncoder,
        database: DatabaseProtocol,
        batchSize: Int = IndexingConfig.batchInsertSize,
        callbacks: Callbacks
    ) {
        self.imageEncoder = imageEncoder
        self.database = database
        self.batchSize = batchSize
        self.callbacks = callbacks
    }

    func index(url: URL, name: String) async {
        await index(url: url, name: name, existingSource: nil)
    }

    func reindex(source: PhotoSource) async {
        guard source.type == PhotoSourceType.folder.rawValue,
              let url = FolderScanner.resolveBookmark(forSourceId: source.id) else {
            logger.error("Could not resolve a saved folder bookmark for re-indexing")
            return
        }
        await index(url: url, name: source.name, existingSource: source)
    }

    private func index(
        url: URL,
        name: String,
        existingSource: PhotoSource?
    ) async {
        let displayName = FolderDisplayNamePolicy.sanitized(name)
        let hasAccess = url.startAccessingSecurityScopedResource()
        guard hasAccess else {
            logger.error("[IndexingService] Could not acquire security-scoped folder access")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let db = database
        let imageURLs = await FolderScanOperation.run {
            FolderScanner.scanFolder(at: url)
        }
        guard !Task.isCancelled, !imageURLs.isEmpty else { return }

        let sourceId = existingSource?.id ?? UUID().uuidString
        if existingSource == nil {
            let bookmarkData: Data
            do {
                bookmarkData = try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                logger.error("Failed to save folder bookmark: \(error.safeDiagnosticCode)")
                return
            }

            let source = PhotoSource(
                id: sourceId,
                type: PhotoSourceType.folder.rawValue,
                path: PhotoSourcePolicy.canonicalPath(url),
                name: displayName,
                addedAt: Date(),
                lastIndexedAt: nil,
                photoCount: 0
            )
            do {
                try await FolderSourceRegistration.register(
                    bookmarkData: bookmarkData,
                    sourceId: sourceId,
                    persistBookmark: { data in
                        try FolderBookmarkStore.set(data, for: sourceId)
                    },
                    insertSource: { try db.insertSource(source) },
                    removeSource: { try db.deleteSource(sourceId) },
                    removeBookmark: {
                        try FolderBookmarkStore.remove(for: sourceId)
                    }
                )
            } catch {
                logger.error("Failed to create source: \(error.safeDiagnosticCode)")
                return
            }
        }

        func rollbackIncompleteSource() async {
            guard existingSource == nil else { return }
            let rollbackTask = Task.detached(priority: .utility) {
                try db.deleteSource(sourceId)
            }
            do {
                try await rollbackTask.value
            } catch {
                logger.error("Failed to roll back incomplete folder source: \(error.safeDiagnosticCode)")
            }
        }
        func persist(_ photos: [IndexedPhoto]) async throws {
            guard Self.shouldPersistFolderWrite(isCancelled: Task.isCancelled) else {
                throw CancellationError()
            }
            let persistTask = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                _ = try db.insertPhotos(photos, completingRequiredRebuild: false)
            }
            try await withTaskCancellationHandler {
                try await persistTask.value
            } onCancel: {
                persistTask.cancel()
            }
            try Task.checkCancellation()
        }
        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return
        }
        var currentProgress = IndexingProgress(
            total: imageURLs.count,
            completed: 0,
            isRunning: true,
            searchableCount: callbacks.searchableCount()
        )
        callbacks.setProgress(currentProgress)

        var indexed = 0
        var persisted = 0
        var alreadyIndexed = 0
        var batch: [IndexedPhoto] = []

        var existingPaths: Set<String> = []
        for (imageIndex, imageURL) in imageURLs.enumerated() {
            if Task.isCancelled { break }
            if imageIndex.isMultiple(of: SearchIndexLimits.databasePageMediaItems) {
                let end = min(
                    imageURLs.count,
                    imageIndex + SearchIndexLimits.databasePageMediaItems
                )
                let paths = imageURLs[imageIndex..<end].map(\.path)
                do {
                    let db = database
                    existingPaths = try await Task.detached(priority: .utility) {
                        try db.existingFilePaths(in: paths)
                    }.value
                } catch {
                    logger.error("Failed to check indexed folder paths: \(error.safeDiagnosticCode)")
                    return
                }
            }
            if existingPaths.contains(imageURL.path) {
                alreadyIndexed += 1
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }

            let loadedImage = await FolderImageLoadOperation.run {
                FolderScanner.loadImage(from: imageURL, within: url)
            }
            guard !Task.isCancelled else { break }
            guard let image = loadedImage else {
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }

            do {
                let encoder = imageEncoder
                let embedding = try await encoder.encodeCancellable(image: image)
                try Task.checkCancellation()
                let metadata = await FolderFileReadOperation.run {
                    FolderScanner.extractMetadata(from: imageURL, within: url)
                } ?? (date: nil, latitude: nil, longitude: nil)
                try Task.checkCancellation()
                var (originalWidth, originalHeight) = await FolderFileReadOperation.run {
                    FolderScanner.imageDimensions(from: imageURL, within: url)
                } ?? (width: 0, height: 0)
                try Task.checkCancellation()
                if originalWidth == 0 || originalHeight == 0 {
                    if originalWidth == 0 { originalWidth = Int(image.size.width) }
                    if originalHeight == 0 { originalHeight = Int(image.size.height) }
                }

                try Task.checkCancellation()
                batch.append(IndexedPhoto(
                    id: UUID().uuidString,
                    localIdentifier: FolderScanner.localIdentifier(for: imageURL, within: url, sourceId: sourceId),
                    creationDate: metadata.date,
                    latitude: metadata.latitude,
                    longitude: metadata.longitude,
                    pixelWidth: originalWidth,
                    pixelHeight: originalHeight,
                    embedding: embedding.toFloat16Data(),
                    indexedAt: Date(),
                    sourceId: sourceId,
                    filePath: imageURL.path
                ))
                if batch.count >= batchSize {
                    let photosToInsert = batch
                    try await persist(photosToInsert)
                    persisted += photosToInsert.count
                    batch.removeAll(keepingCapacity: true)
                }
            } catch is CancellationError {
                break
            } catch {
                logger.error("Failed to index a folder image: \(error.safeDiagnosticCode)")
            }

            indexed += 1
            currentProgress.completed = indexed
            callbacks.setProgress(currentProgress)
            if indexed % 10 == 0 { await Task.yield() }
        }

        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return
        }
        if !batch.isEmpty {
            do {
                let photosToInsert = batch
                try await persist(photosToInsert)
                persisted += photosToInsert.count
            } catch is CancellationError {
                await rollbackIncompleteSource()
                return
            } catch {
                logger.error("Failed to flush folder batch: \(error.safeDiagnosticCode), retrying individually")
                for photo in batch {
                    do {
                        try await persist([photo])
                        persisted += 1
                    } catch is CancellationError {
                        await rollbackIncompleteSource()
                        return
                    } catch {
                        logger.error("Failed to insert a folder photo: \(error.safeDiagnosticCode)")
                    }
                }
            }
        }

        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return
        }
        let totalPersistedForSource = persisted + alreadyIndexed
        guard totalPersistedForSource > 0 else {
            await rollbackIncompleteSource()
            return
        }
        do {
            let db = database
            try await Task.detached(priority: .utility) {
                try db.updateSourceStats(sourceId, photoCount: totalPersistedForSource)
            }.value
        } catch {
            logger.error("Failed to update source stats: \(error.safeDiagnosticCode)")
        }

        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return
        }
        await callbacks.reloadSearchIndex()
        currentProgress.searchableCount = callbacks.searchableCount()
        currentProgress.isRunning = false
        callbacks.setProgress(currentProgress)
    }
}
