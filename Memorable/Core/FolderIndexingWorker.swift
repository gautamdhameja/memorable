import Foundation
import ImageIO

@MainActor
final class FolderIndexingWorker {
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
        let hasAccess = url.startAccessingSecurityScopedResource()
        guard hasAccess else {
            logger.error("[IndexingService] Could not acquire security-scoped access for folder: \(url.lastPathComponent)")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let sourceId = UUID().uuidString
        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: AppKeys.folderBookmark(sourceId: sourceId))
        } catch {
            logger.error("Failed to save folder bookmark: \(error.localizedDescription)")
        }

        let source = PhotoSource(
            id: sourceId,
            type: PhotoSourceType.folder.rawValue,
            path: url.path,
            name: name,
            addedAt: Date(),
            lastIndexedAt: nil,
            photoCount: 0
        )
        do {
            let db = database
            try await Task.detached(priority: .utility) {
                try db.insertSource(source)
            }.value
        } catch {
            logger.error("Failed to create source: \(error.localizedDescription)")
            return
        }

        let imageURLs = await Task.detached(priority: .utility) {
            FolderScanner.scanFolder(at: url)
        }.value
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
            logger.error("Failed to load indexed folder paths: \(error.localizedDescription)")
            alreadyIndexed = []
        }
        var indexed = 0
        var batch: [IndexedPhoto] = []

        for imageURL in imageURLs {
            if Task.isCancelled { break }
            if alreadyIndexed.contains(imageURL.path) {
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }

            let loadedImage = await Task.detached(priority: .utility) {
                FolderScanner.loadImage(from: imageURL)
            }.value
            guard let image = loadedImage else {
                indexed += 1
                currentProgress.completed = indexed
                callbacks.setProgress(currentProgress)
                continue
            }

            do {
                let encoder = imageEncoder
                let embedding = try await Task.detached(priority: .userInitiated) {
                    try encoder.encode(image: image)
                }.value
                let metadata = await Task.detached(priority: .utility) {
                    FolderScanner.extractMetadata(from: imageURL)
                }.value
                var (originalWidth, originalHeight) = await Task.detached(priority: .utility) {
                    var width = 0
                    var height = 0
                    if let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                        width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
                        height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
                    }
                    return (width, height)
                }.value
                if originalWidth == 0 || originalHeight == 0 {
                    if originalWidth == 0 { originalWidth = Int(image.size.width) }
                    if originalHeight == 0 { originalHeight = Int(image.size.height) }
                }

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
                    let db = database
                    try await Task.detached(priority: .utility) {
                        _ = try db.insertPhotos(photosToInsert, completingRequiredRebuild: false)
                    }.value
                    batch.removeAll(keepingCapacity: true)
                }
            } catch {
                logger.error("Failed to index \(imageURL.lastPathComponent): \(error.localizedDescription)")
            }

            indexed += 1
            currentProgress.completed = indexed
            callbacks.setProgress(currentProgress)
            if indexed % 10 == 0 { await Task.yield() }
        }

        if !batch.isEmpty {
            do {
                let photosToInsert = batch
                let db = database
                try await Task.detached(priority: .utility) {
                    _ = try db.insertPhotos(photosToInsert, completingRequiredRebuild: false)
                }.value
            } catch {
                logger.error("Failed to flush folder batch: \(error.localizedDescription), retrying individually")
                for photo in batch {
                    do {
                        let db = database
                        try await Task.detached(priority: .utility) {
                            _ = try db.insertPhotos([photo], completingRequiredRebuild: false)
                        }.value
                    } catch {
                        logger.error("Failed to insert photo \(photo.localIdentifier): \(error.localizedDescription)")
                    }
                }
            }
        }

        do {
            let db = database
            try await Task.detached(priority: .utility) {
                try db.updateSourceStats(sourceId, photoCount: indexed)
            }.value
        } catch {
            logger.error("Failed to update source stats: \(error.localizedDescription)")
        }

        await callbacks.reloadSearchIndex()
        currentProgress.searchableCount = callbacks.searchableCount()
        currentProgress.isRunning = false
        callbacks.setProgress(currentProgress)
    }
}
