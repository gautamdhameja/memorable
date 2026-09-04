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
                    // Production source deletion already performs rollback-safe
                    // bookmark cleanup. The extra idempotent cleanup preserves
                    // this helper's injected-operation contract in tests.
                    shouldRemoveBookmark = true
                } catch let rollbackError {
                    shouldRemoveBookmark = false
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
        operation: @escaping @Sendable () async -> FolderScanner.ScanResult
    ) async -> FolderScanner.ScanResult {
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

enum FolderIndexingOutcome: Equatable {
    case completed
    case completedWithWarnings
    case failed
    case cancelled

    var didComplete: Bool {
        self == .completed || self == .completedWithWarnings
    }
}

enum FolderPendingBatch {
    static func takeAll<Element>(_ batch: inout [Element]) -> [Element] {
        let pending = batch
        batch.removeAll(keepingCapacity: true)
        return pending
    }
}

enum FolderScanCompletionPolicy {
    static func isComplete(
        directoryScanWasComplete: Bool,
        failedFileCount: Int,
        successfullyHandledFileCount: Int
    ) -> Bool {
        directoryScanWasComplete
            && (failedFileCount == 0 || successfullyHandledFileCount > 0)
    }
}

@MainActor
final class FolderIndexingWorker {
    nonisolated static func shouldPersistFolderWrite(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    struct Callbacks {
        let searchableCount: () -> Int
        let setProgress: (IndexingProgress) -> Void
        let reportError: (String) -> Void
        let reloadSearchIndex: () async -> Bool
        let didReplaceMedia: (String) -> Void
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

    func index(url: URL, name: String) async -> FolderIndexingOutcome {
        await index(
            url: url,
            name: name,
            existingSource: nil,
            reloadSearchIndex: true
        )
    }

    func reindex(
        source: PhotoSource,
        reloadSearchIndex: Bool = true
    ) async -> FolderIndexingOutcome {
        guard source.type == PhotoSourceType.folder.rawValue else {
            callbacks.reportError("This saved source is not a folder.")
            logger.error("Refusing to re-index a non-folder source")
            return .failed
        }
        guard let url = FolderScanner.resolveBookmark(forSourceId: source.id) else {
            callbacks.reportError("Memorable can no longer access \(source.name). Remove it and add the folder again.")
            logger.error("Could not resolve a saved folder bookmark for re-indexing")
            return .failed
        }
        return await index(
            url: url,
            name: source.name,
            existingSource: source,
            reloadSearchIndex: reloadSearchIndex
        )
    }

    private func index(
        url: URL,
        name: String,
        existingSource: PhotoSource?,
        reloadSearchIndex: Bool
    ) async -> FolderIndexingOutcome {
        let displayName = FolderDisplayNamePolicy.sanitized(name)
        let hasAccess = url.startAccessingSecurityScopedResource()
        guard hasAccess else {
            callbacks.reportError("Memorable could not access this folder. Choose it again.")
            logger.error("[IndexingService] Could not acquire security-scoped folder access")
            return .failed
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let db = database
        let indexedAt = Date()
        let scan = await FolderScanOperation.run {
            FolderScanner.scanFolder(at: url)
        }
        guard !Task.isCancelled else { return .cancelled }
        let imageURLs = scan.imageURLs
        guard existingSource != nil || !imageURLs.isEmpty else {
            callbacks.reportError(
                scan.isComplete
                    ? "This folder does not contain supported photos."
                    : "Memorable could not finish scanning this folder safely. Choose a smaller folder."
            )
            return .failed
        }

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
                callbacks.reportError("Memorable could not save access to this folder. Try again.")
                logger.error("Failed to save folder bookmark: \(error.safeDiagnosticCode)")
                return .failed
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
            } catch let error as PhotoSourceRegistrationError {
                callbacks.reportError(UserFacingErrorMessage.message(
                    for: error,
                    fallback: "The folder couldn't be added. Check access and try again."
                ))
                logger.error("Failed to create source: \(error.safeDiagnosticCode)")
                return .failed
            } catch {
                callbacks.reportError("The folder could not be added. Try again.")
                logger.error("Failed to create source: \(error.safeDiagnosticCode)")
                return .failed
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
            try await CancellableDetachedOperation.run(priority: .utility) {
                _ = try db.insertPhotos(photos, completingRequiredRebuild: false)
            }
        }
        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return .cancelled
        }
        var currentProgress = IndexingProgress(
            total: imageURLs.count,
            completed: 0,
            isRunning: true,
            searchableCount: callbacks.searchableCount()
        )
        var progressPublisher = IndexingProgressPublisher()
        progressPublisher.publish(currentProgress, force: true, using: callbacks.setProgress)

        var indexed = 0
        var failedFileCount = 0
        var successfullyHandledFileCount = 0
        var batch: [IndexedPhoto] = []

        var existingVersions: [String: IndexedMediaVersion] = [:]
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
                    existingVersions = try await Task.detached(priority: .utility) {
                        try db.indexedFolderVersions(in: paths, sourceId: sourceId)
                    }.value
                } catch {
                    callbacks.reportError("Memorable could not read the saved folder index. Try again.")
                    logger.error("Failed to check indexed folder paths: \(error.safeDiagnosticCode)")
                    await rollbackIncompleteSource()
                    return .failed
                }
            }
            let existingVersion = existingVersions[imageURL.path]
            if let existingVersion {
                let modifiedAt = await FolderFileReadOperation.run {
                    FolderScanner.fileModificationDate(imageURL, within: url)
                } ?? nil
                guard !Task.isCancelled else { break }
                // If the file cannot be inspected, attempt the normal load so
                // failure is reported and the previous searchable row remains.
                if let modifiedAt,
                   !IndexedMediaFreshness.needsRefresh(modifiedAt: modifiedAt, indexedAt: existingVersion.indexedAt) {
                    successfullyHandledFileCount += 1
                    indexed += 1
                    currentProgress.completed = indexed
                    progressPublisher.publish(currentProgress, using: callbacks.setProgress)
                    continue
                }
            }

            let loadedImage = await FolderFileReadOperation.run {
                FolderScanner.loadIndexingImage(from: imageURL, within: url)
            } ?? nil
            guard !Task.isCancelled else { break }
            guard let loadedImage else {
                failedFileCount += 1
                indexed += 1
                currentProgress.completed = indexed
                progressPublisher.publish(currentProgress, using: callbacks.setProgress)
                continue
            }

            do {
                let encoder = imageEncoder
                let embedding = try await encoder.encodeCancellable(image: loadedImage.image)
                try Task.checkCancellation()
                let photo = IndexedPhoto(
                    id: existingVersion?.id ?? UUID().uuidString,
                    localIdentifier: FolderScanner.localIdentifier(for: imageURL, within: url, sourceId: sourceId),
                    creationDate: loadedImage.date,
                    latitude: loadedImage.latitude,
                    longitude: loadedImage.longitude,
                    pixelWidth: loadedImage.width,
                    pixelHeight: loadedImage.height,
                    embedding: embedding.toFloat16Data(),
                    indexedAt: indexedAt,
                    sourceId: sourceId,
                    filePath: imageURL.path,
                    isScreenshot: MemoryContentPolicy.isLikelyScreenshotDimensions(
                        width: loadedImage.width,
                        height: loadedImage.height
                    )
                )
                if existingVersion != nil {
                    try await IndexedMediaReplacementOperation.run { try db.replacePhoto(photo) }
                    callbacks.didReplaceMedia(photo.localIdentifier)
                } else {
                    batch.append(photo)
                }
                successfullyHandledFileCount += 1
                if batch.count >= batchSize {
                    let photosToInsert = FolderPendingBatch.takeAll(&batch)
                    do {
                        try await persist(photosToInsert)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        callbacks.reportError("Memorable could not save this folder's search data. Free storage and try again.")
                        logger.error("Failed to save a bounded folder batch: \(error.safeDiagnosticCode)")
                        await rollbackIncompleteSource()
                        return .failed
                    }
                }
            } catch is CancellationError {
                break
            } catch {
                failedFileCount += 1
                logger.error("Failed to index a folder image: \(error.safeDiagnosticCode)")
            }

            indexed += 1
            currentProgress.completed = indexed
            progressPublisher.publish(currentProgress, using: callbacks.setProgress)
            if indexed % 10 == 0 { await Task.yield() }
        }

        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return .cancelled
        }
        if !batch.isEmpty {
            let photosToInsert = FolderPendingBatch.takeAll(&batch)
            do {
                try await persist(photosToInsert)
            } catch is CancellationError {
                await rollbackIncompleteSource()
                return .cancelled
            } catch {
                callbacks.reportError("Memorable could not save this folder's search data. Free storage and try again.")
                logger.error("Failed to flush a bounded folder batch: \(error.safeDiagnosticCode)")
                await rollbackIncompleteSource()
                return .failed
            }
        }

        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return .cancelled
        }
        let totalPersistedForSource: Int
        let scanWasComplete = FolderScanCompletionPolicy.isComplete(
            directoryScanWasComplete: scan.isComplete,
            failedFileCount: failedFileCount,
            successfullyHandledFileCount: successfullyHandledFileCount
        )
        do {
            let db = database
            totalPersistedForSource = try await CancellableDetachedOperation.run {
                try db.reconcileFolderSource(
                    sourceId,
                    scannedFilePaths: Set(imageURLs.map(\.path)),
                    scanWasComplete: scanWasComplete
                )
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            await rollbackIncompleteSource()
            return .cancelled
        } catch {
            callbacks.reportError("Memorable could not finish updating this folder. Try again.")
            logger.error("Failed to reconcile folder source: \(error.safeDiagnosticCode)")
            await rollbackIncompleteSource()
            return .failed
        }
        guard existingSource != nil || totalPersistedForSource > 0 else {
            await rollbackIncompleteSource()
            callbacks.reportError("Memorable could not index any supported photos in this folder.")
            return .failed
        }

        guard failedFileCount == 0 else {
            callbacks.reportError("Memorable skipped \(failedFileCount) unreadable photo(s). You can refresh this folder later.")
            if reloadSearchIndex {
                guard await callbacks.reloadSearchIndex() else { return .failed }
            }
            return successfullyHandledFileCount > 0 ? .completedWithWarnings : .failed
        }

        guard !Task.isCancelled else {
            await rollbackIncompleteSource()
            return .cancelled
        }
        if reloadSearchIndex {
            guard await callbacks.reloadSearchIndex() else {
                callbacks.reportError("Memorable saved the folder but could not refresh search. Try again.")
                return .failed
            }
        }
        return .completed
    }
}
