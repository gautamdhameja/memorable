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
        removeBookmark: () -> Void
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
            if didInsertSource {
                do {
                    try await Task.detached(priority: .utility) {
                        try removeSource()
                    }.value
                } catch {
                    logger.error("Failed to roll back cancelled folder source registration: \(error.safeDiagnosticCode)")
                }
            }
            removeBookmark()
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
        let setReachedDeviceIndexLimit: (Bool) -> Void
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
        let displayName = FolderDisplayNamePolicy.sanitized(name)
        let hasAccess = url.startAccessingSecurityScopedResource()
        guard hasAccess else {
            logger.error("[IndexingService] Could not acquire security-scoped folder access")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let db = database
        let initialIndexedMediaCount: Int
        do {
            let counts = try await Task.detached(priority: .utility) {
                try db.indexedMediaCounts()
            }.value
            initialIndexedMediaCount = counts.total
        } catch {
            logger.error("Failed to determine the current index size: \(error.safeDiagnosticCode)")
            return
        }
        let remainingCapacity = max(0, ProTier.maxIndexedMedia - initialIndexedMediaCount)
        guard remainingCapacity > 0 else {
            callbacks.setReachedDeviceIndexLimit(true)
            return
        }
        callbacks.setReachedDeviceIndexLimit(false)

        let imageURLs = await FolderScanOperation.run {
            FolderScanner.scanFolder(at: url, maximumImageCount: remainingCapacity)
        }
        guard !Task.isCancelled, !imageURLs.isEmpty else { return }

        let sourceId = UUID().uuidString
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
                    FolderBookmarkStore.remove(for: sourceId)
                }
            )
        } catch {
            logger.error("Failed to create source: \(error.safeDiagnosticCode)")
            return
        }

        func rollbackIncompleteSource() async {
            defer {
                FolderBookmarkStore.remove(for: sourceId)
            }
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

        let alreadyIndexed: Set<String>
        do {
            let db = database
            alreadyIndexed = try await Task.detached(priority: .utility) {
                try db.allIndexedFilePaths()
            }.value
        } catch {
            logger.error("Failed to load indexed folder paths: \(error.safeDiagnosticCode)")
            alreadyIndexed = []
        }
        var indexed = 0
        var persisted = 0
        var indexedMediaCount = initialIndexedMediaCount
        var batch: [IndexedPhoto] = []

        for imageURL in imageURLs {
            if Task.isCancelled { break }
            if alreadyIndexed.contains(imageURL.path) {
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }
            guard indexedMediaCount < ProTier.maxIndexedMedia else { break }

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
                indexedMediaCount += 1

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
        guard persisted > 0 else {
            await rollbackIncompleteSource()
            return
        }
        do {
            let db = database
            try await Task.detached(priority: .utility) {
                try db.updateSourceStats(sourceId, photoCount: persisted)
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
