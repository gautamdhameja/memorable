import Foundation
import Photos
import os

struct PreparedPhotoShareItem: Identifiable, Sendable {
    let id = UUID()
    let fileURL: URL

    func cleanup() {
        PhotoShareFileCleanup.remove(fileURL)
    }
}

enum PhotoShareFileCleanup {
    static func remove(_ fileURL: URL) {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            logger.error("[PhotoLibrary] Could not remove a share file: \(error.safeDiagnosticCode)")
        }
    }

    static func close(_ handle: FileHandle?) {
        guard let handle else { return }
        do {
            try handle.close()
        } catch {
            logger.error("[PhotoLibrary] Could not close a share file: \(error.safeDiagnosticCode)")
        }
    }
}

enum PhotoSharePreparationError: Error, Equatable, Sendable {
    case unsupportedMedia
    case sourceUnavailable
    case fileTooLarge
    case storageUnavailable

    var userMessage: String {
        switch self {
        case .unsupportedMedia:
            return "This item cannot be shared as a photo."
        case .sourceUnavailable:
            return "The photo is not available on this iPhone."
        case .fileTooLarge:
            return "The photo is too large to prepare safely."
        case .storageUnavailable:
            return "The photo could not be prepared. Check available storage and try again."
        }
    }
}

enum PhotoShareResourcePolicy {
    static let maximumFileBytes = 256 * 1_024 * 1_024

    private static let canonicalExtensions = [
        "public.jpeg": "jpg",
        "public.png": "png",
        "public.heic": "heic",
        "public.heif": "heif",
        "org.webmproject.webp": "webp",
        "public.tiff": "tiff",
        "com.microsoft.bmp": "bmp",
    ]

    static func pathExtension(
        forTypeIdentifier typeIdentifier: String,
        fallbackFilename: String
    ) -> String {
        canonicalExtensions[typeIdentifier]
            ?? safePathExtension(for: fallbackFilename)
    }

    static func safePathExtension(for filename: String) -> String {
        let candidate = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard !candidate.isEmpty,
              candidate.count <= 10,
              candidate.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return "image"
        }
        return candidate
    }

    static func pathExtension(forDetectedTypeIdentifier typeIdentifier: String) -> String? {
        canonicalExtensions[typeIdentifier]
    }
}

/// Sendable invariant: the file handle, byte count, and terminal failure are
/// accessed only while holding `state`; the URL and size limit are immutable.
final class PhotoShareFileWriter: @unchecked Sendable {
    private struct State {
        var handle: FileHandle?
        var byteCount = 0
        var failure: PhotoSharePreparationError?
    }

    let fileURL: URL
    private let maximumByteCount: Int
    private let state: OSAllocatedUnfairLock<State>

    init(fileURL: URL, maximumByteCount: Int = PhotoShareResourcePolicy.maximumFileBytes) throws {
        guard maximumByteCount > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
        let created = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard created else { throw CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: fileURL.path
            )
            try LocalOnlyStorage.excludeFromBackup(fileURL)
            let handle = try FileHandle(forWritingTo: fileURL)
            self.fileURL = fileURL
            self.maximumByteCount = maximumByteCount
            self.state = OSAllocatedUnfairLock(initialState: State(handle: handle))
        } catch {
            PhotoShareFileCleanup.remove(fileURL)
            throw error
        }
    }

    func append(_ data: Data) -> Bool {
        state.withLock { state in
            guard let handle = state.handle else {
                return false
            }
            guard data.count <= maximumByteCount - state.byteCount else {
                state.failure = .fileTooLarge
                return false
            }
            do {
                try handle.write(contentsOf: data)
                state.byteCount += data.count
                return true
            } catch {
                state.failure = .storageUnavailable
                return false
            }
        }
    }

    var failure: PhotoSharePreparationError? {
        state.withLock { $0.failure }
    }

    func finish() -> Bool {
        let handle = state.withLock { state -> FileHandle? in
            defer { state.handle = nil }
            return state.handle
        }
        guard let handle else { return false }
        do {
            try handle.close()
            return true
        } catch {
            state.withLock { $0.failure = .storageUnavailable }
            PhotoShareFileCleanup.remove(fileURL)
            return false
        }
    }

    func discard() {
        let handle = state.withLock { state -> FileHandle? in
            defer { state.handle = nil }
            return state.handle
        }
        PhotoShareFileCleanup.close(handle)
        PhotoShareFileCleanup.remove(fileURL)
    }
}


extension PhotoLibrary {
    static func prepareShareItem(for result: SearchResult) async throws -> PreparedPhotoShareItem {
        guard !result.isVideo else { throw PhotoSharePreparationError.unsupportedMedia }

        if result.sourceId != PhotoSourceType.photokit.rawValue {
            let isPro = await MainActor.run { ProManager.shared.isPro }
            guard FolderResultAccessPolicy.allows(
                sourceId: result.sourceId,
                isPro: isPro
            ) else {
                throw PhotoSharePreparationError.sourceUnavailable
            }
            guard let filePath = result.filePath else {
                throw PhotoSharePreparationError.sourceUnavailable
            }
            let outcome: Result<PreparedPhotoShareItem, PhotoSharePreparationError>? = await FolderFileReadOperation.run(
                onDiscardedResult: { (result: Result<PreparedPhotoShareItem, PhotoSharePreparationError>) in
                    if case .success(let item) = result { item.cleanup() }
                }
            ) { () async -> Result<PreparedPhotoShareItem, PhotoSharePreparationError> in
                guard let snapshot = FolderScanner.validatedImageSnapshotFromBookmarkedSource(
                    filePath: filePath,
                    sourceId: result.sourceId
                ) else {
                    return Result.failure(PhotoSharePreparationError.sourceUnavailable)
                }
                do {
                    return .success(try prepareFolderShareItem(
                        snapshot
                    ))
                } catch let error as PhotoSharePreparationError {
                    return .failure(error)
                } catch {
                    logger.error("[PhotoLibrary] Folder share preparation failed: \(error.safeDiagnosticCode)")
                    return .failure(.storageUnavailable)
                }
            }
            guard let outcome else { throw CancellationError() }
            return try outcome.get()
        }

        guard let asset = getAsset(by: result.localIdentifier),
              let resource = preferredPhotoResource(for: asset) else {
            throw PhotoSharePreparationError.sourceUnavailable
        }
        return try await copyLocalPhotoResource(resource)
    }

    static func prepareFolderShareItem(
        _ snapshot: FolderScanner.ValidatedImageSnapshot
    ) throws -> PreparedPhotoShareItem {
        guard !Task.isCancelled else { throw CancellationError() }
        guard snapshot.data.count <= FolderScanner.maximumImageFileBytes else {
            throw PhotoSharePreparationError.fileTooLarge
        }
        guard let pathExtension = PhotoShareResourcePolicy.pathExtension(
            forDetectedTypeIdentifier: snapshot.typeIdentifier
        ) else {
            throw PhotoSharePreparationError.sourceUnavailable
        }

        let fileURL: URL
        let writer: PhotoShareFileWriter
        do {
            fileURL = try shareFileURL(pathExtension: pathExtension)
            writer = try PhotoShareFileWriter(
                fileURL: fileURL,
                maximumByteCount: FolderScanner.maximumImageFileBytes
            )
        } catch {
            logger.error("[PhotoLibrary] Could not create a folder share file: \(error.safeDiagnosticCode)")
            throw PhotoSharePreparationError.storageUnavailable
        }

        guard writer.append(snapshot.data), writer.finish() else {
            let failure = writer.failure ?? .storageUnavailable
            writer.discard()
            throw failure
        }
        guard !Task.isCancelled else {
            writer.discard()
            throw CancellationError()
        }
        return PreparedPhotoShareItem(fileURL: fileURL)
    }

    private static func preferredPhotoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .alternatePhoto })
    }

    private static func copyLocalPhotoResource(
        _ resource: PHAssetResource
    ) async throws -> PreparedPhotoShareItem {
        let manager = PHAssetResourceManager.default()
        return try await copyLocalPhotoResource(
            pathExtension: PhotoShareResourcePolicy.pathExtension(
                forTypeIdentifier: resource.uniformTypeIdentifier,
                fallbackFilename: resource.originalFilename
            ),
            requestData: { options, dataHandler, completionHandler in
                manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: dataHandler,
                    completionHandler: completionHandler
                )
            },
            cancelRequest: { manager.cancelDataRequest($0) }
        )
    }

    static func copyLocalPhotoResource(
        pathExtension: String,
        maximumByteCount: Int = PhotoShareResourcePolicy.maximumFileBytes,
        requestData: @escaping (
            PHAssetResourceRequestOptions,
            @escaping @Sendable (Data) -> Void,
            @escaping @Sendable (Error?) -> Void
        ) -> PHImageRequestID,
        cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void,
        requestRegistered: @escaping @Sendable () -> Void = {}
    ) async throws -> PreparedPhotoShareItem {
        let fileURL: URL
        let writer: PhotoShareFileWriter
        do {
            fileURL = try shareFileURL(pathExtension: pathExtension)
            writer = try PhotoShareFileWriter(
                fileURL: fileURL,
                maximumByteCount: maximumByteCount
            )
        } catch {
            logger.error("[PhotoLibrary] Could not create a share file: \(error.safeDiagnosticCode)")
            throw PhotoSharePreparationError.storageUnavailable
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let outcome: Result<PreparedPhotoShareItem, PhotoSharePreparationError>? = await withPhotoKitRequest(
            seconds: TimeoutConfig.videoLoad,
            cancelRequest: cancelRequest,
            requestRegistered: requestRegistered,
            onDiscardedResult: { result in
                if case .success(let item) = result { item.cleanup() }
            },
            onCancel: writer.discard
        ) { completion, controller in
            requestData(options, { data in
                if !writer.append(data) {
                    controller.cancel()
                }
            }, { error in
                if let error {
                    logger.error("[PhotoLibrary] Local PhotoKit share read failed: \(error.safeDiagnosticCode)")
                    writer.discard()
                    completion(.failure(.sourceUnavailable))
                    return
                }
                guard writer.finish() else {
                    let failure = writer.failure ?? .storageUnavailable
                    writer.discard()
                    completion(.failure(failure))
                    return
                }
                completion(.success(PreparedPhotoShareItem(fileURL: fileURL)))
            })
        }
        guard let outcome else {
            if Task.isCancelled { throw CancellationError() }
            throw writer.failure ?? PhotoSharePreparationError.sourceUnavailable
        }
        return try outcome.get()
    }

    private static func shareFileURL(pathExtension: String) throws -> URL {
        let directory = shareItemsDirectoryURL
        try LocalOnlyStorage.prepareDirectory(at: directory)
        return directory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(pathExtension)
    }

    static var shareItemsDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MemorableShareItems", isDirectory: true)
    }

    static func cleanupShareItems(in directory: URL? = nil) {
        let targetDirectory = directory ?? shareItemsDirectoryURL
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: targetDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            logger.error("[PhotoLibrary] Could not inspect stale share items: \(error.safeDiagnosticCode)")
            return
        }
        for file in files {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                logger.error("[PhotoLibrary] Failed to remove a stale share item: \(error.safeDiagnosticCode)")
            }
        }
    }

}
