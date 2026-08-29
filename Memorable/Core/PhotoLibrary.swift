import Photos
import UIKit
import AVFoundation
import ImageIO
import os

enum PhotoThumbnailSizePolicy {
    static func targetSize(
        pixelWidth: Int,
        pixelHeight: Int,
        maxDimension: CGFloat
    ) -> CGSize? {
        guard pixelWidth > 0, pixelHeight > 0,
              maxDimension.isFinite, maxDimension > 0 else {
            return nil
        }
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let scale = maxDimension / max(width, height)
        let size = CGSize(width: width * scale, height: height * scale)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }
}

enum FolderFileReadOperation {
    private static let permits = CancellablePermitPool(limit: 2)

    static func run<Value: Sendable>(
        onDiscardedResult: @escaping @Sendable (Value) -> Void = { _ in },
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard await permits.acquire() else { return nil }
        if Task.isCancelled {
            await permits.release()
            return nil
        }
        let decodeTask = Task.detached(priority: .utility) {
            await operation()
        }
        let result = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        await permits.release()
        guard !Task.isCancelled else {
            onDiscardedResult(result)
            return nil
        }
        return result
    }
}

enum FolderImageLoadOperation {
    static func run(
        operation: @escaping @Sendable () async -> UIImage?
    ) async -> UIImage? {
        await FolderFileReadOperation.run(operation: operation) ?? nil
    }
}

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
    static let maximumPixelDimension: CGFloat = 4_096

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
}

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

actor CancellablePermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        available = min(limit, available + 1)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

final class PhotoKitRequestController<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var continuation: ContinuationGuard<Value?>?
        var requestID: PHImageRequestID = PHInvalidImageRequestID
        var timeoutTask: Task<Void, Never>?
        var timeoutGeneration: UInt = 0
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void
    private let onCancel: @Sendable () -> Void

    init(
        cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void,
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.cancelRequest = cancelRequest
        self.onCancel = onCancel
    }

    @discardableResult
    func installContinuation(_ continuation: ContinuationGuard<Value?>) -> Bool {
        let didInstall = state.withLock { state in
            guard !state.isFinished else { return false }
            state.continuation = continuation
            return true
        }
        if !didInstall {
            continuation.resume(returning: nil)
        }
        return didInstall
    }

    func registerRequestID(_ requestID: PHImageRequestID) {
        let shouldCancel = state.withLock { state in
            guard !state.isFinished else { return true }
            state.requestID = requestID
            return false
        }
        if shouldCancel, requestID != PHInvalidImageRequestID {
            cancelRequest(requestID)
        }
    }

    @discardableResult
    func beginNextPhase() -> Bool {
        let transition = state.withLock { state -> (didBegin: Bool, timeoutTask: Task<Void, Never>?) in
            guard !state.isFinished else { return (false, nil) }
            state.requestID = PHInvalidImageRequestID
            state.timeoutGeneration &+= 1
            defer { state.timeoutTask = nil }
            return (true, state.timeoutTask)
        }
        guard transition.didBegin else { return false }
        transition.timeoutTask?.cancel()
        return true
    }

    func scheduleTimeout(
        seconds: Double,
        action: @escaping @Sendable () -> Void
    ) {
        let registration = state.withLock { state -> (generation: UInt, previous: Task<Void, Never>?)? in
            guard !state.isFinished else { return nil }
            state.timeoutGeneration &+= 1
            defer { state.timeoutTask = nil }
            return (state.timeoutGeneration, state.timeoutTask)
        }
        guard let registration else { return }
        registration.previous?.cancel()

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.claimTimeout(generation: registration.generation) else { return }
            action()
        }

        let shouldCancel = state.withLock { state in
            guard !state.isFinished,
                  state.timeoutGeneration == registration.generation else { return true }
            state.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel {
            timeoutTask.cancel()
        }
    }

    @discardableResult
    func finish(_ value: Value?) -> Bool {
        guard let completion = takeCompletion() else { return false }
        completion.timeoutTask?.cancel()
        completion.continuation?.resume(returning: value)
        return true
    }

    func cancel() {
        guard let completion = takeCompletion() else { return }
        completion.timeoutTask?.cancel()
        if completion.requestID != PHInvalidImageRequestID {
            cancelRequest(completion.requestID)
        }
        onCancel()
        completion.continuation?.resume(returning: nil)
    }

    private func claimTimeout(generation: UInt) -> Bool {
        state.withLock { state in
            guard !state.isFinished, state.timeoutGeneration == generation else { return false }
            state.timeoutTask = nil
            return true
        }
    }

    private func takeCompletion() -> (
        continuation: ContinuationGuard<Value?>?,
        requestID: PHImageRequestID,
        timeoutTask: Task<Void, Never>?
    )? {
        state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            state.timeoutGeneration &+= 1
            defer {
                state.continuation = nil
                state.requestID = PHInvalidImageRequestID
                state.timeoutTask = nil
            }
            return (state.continuation, state.requestID, state.timeoutTask)
        }
    }
}

class PhotoLibrary {
    struct VideoFrame: Sendable {
        let position: Double
        let image: UIImage
    }

    private final class VideoFrameCancellation: Sendable {
        private struct State {
            var generator: AVAssetImageGenerator?
            var isCancelled = false
            var isFinished = false
        }

        private let state = OSAllocatedUnfairLock(uncheckedState: State())

        func register(_ generator: AVAssetImageGenerator) {
            let shouldCancel = state.withLockUnchecked { state in
                guard !state.isCancelled, !state.isFinished else { return true }
                state.generator = generator
                return false
            }
            if shouldCancel {
                generator.cancelAllCGImageGeneration()
            }
        }

        func cancel() {
            let generator = state.withLockUnchecked { state in
                state.isCancelled = true
                defer { state.generator = nil }
                return state.generator
            }
            generator?.cancelAllCGImageGeneration()
        }

        func finish() {
            state.withLockUnchecked {
                $0.isFinished = true
                $0.generator = nil
            }
        }
    }

    private final class VideoFrameAccumulator: Sendable {
        private struct State: Sendable {
            var remaining: Int
            var frames: [VideoFrame]
            let completion: @Sendable ([VideoFrame]?) -> Void
        }

        private let state: OSAllocatedUnfairLock<State>
        private let cancellation: VideoFrameCancellation

        init(
            count: Int,
            cancellation: VideoFrameCancellation,
            completion: @escaping @Sendable ([VideoFrame]?) -> Void
        ) {
            self.cancellation = cancellation
            state = OSAllocatedUnfairLock(
                initialState: State(remaining: count, frames: [], completion: completion)
            )
        }

        func receive(position: Double, image: UIImage?) {
            let finished: (completion: @Sendable ([VideoFrame]?) -> Void, frames: [VideoFrame]?)? = state.withLock { state in
                guard state.remaining > 0 else { return nil }
                state.remaining -= 1
                if let image {
                    state.frames.append(VideoFrame(position: position, image: image))
                }
                guard state.remaining == 0 else { return nil }
                let frames = state.frames.sorted { $0.position < $1.position }
                return (state.completion, frames.isEmpty ? nil : frames)
            }
            if let finished {
                cancellation.finish()
                finished.completion(finished.frames)
            }
        }

        func finishAfterTimeout() {
            let finished: (completion: @Sendable ([VideoFrame]?) -> Void, frames: [VideoFrame]?)? = state.withLock { state in
                guard state.remaining > 0 else { return nil }
                state.remaining = 0
                let frames = state.frames.sorted { $0.position < $1.position }
                return (state.completion, frames.isEmpty ? nil : frames)
            }
            if let finished {
                cancellation.cancel()
                finished.completion(finished.frames)
            }
        }
    }

    struct VideoPlaybackAsset: Sendable {
        private let asset: OSAllocatedUnfairLock<AVAsset>

        fileprivate init(asset: AVAsset) {
            self.asset = OSAllocatedUnfairLock(uncheckedState: asset)
        }

        @MainActor
        func makePlayer() -> AVPlayer? {
            asset.withLockUnchecked { AVPlayer(playerItem: AVPlayerItem(asset: $0)) }
        }
    }

    // Request authorization to access the photo library
    static func requestAuthorization() async -> PHAuthorizationStatus {
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // Get a UIImage from a PHAsset at a specific size for embedding
    static func loadImage(for asset: PHAsset, targetSize: CGSize = CGSize(width: 224, height: 224)) async -> UIImage? {
        await requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: imageRequestOptions())
    }

    /// Loads either a PhotoKit result or a validated security-scoped folder
    /// result without exposing raw folder paths to view code.
    static func loadImage(
        for result: SearchResult,
        targetSize: CGSize
    ) async -> UIImage? {
        if result.sourceId != PhotoSourceType.photokit.rawValue {
            guard !result.isVideo, let filePath = result.filePath else { return nil }
            return await FolderImageLoadOperation.run {
                FolderScanner.loadImageFromBookmarkedSource(
                    filePath: filePath,
                    sourceId: result.sourceId,
                    targetSize: targetSize
                )
            }
        }

        guard let asset = getAsset(by: result.localIdentifier) else { return nil }
        if result.isVideo {
            return await VideoFrameExtractor.thumbnail(
                from: asset,
                atPosition: result.bestFramePosition ?? 0.5,
                targetSize: targetSize
            )
        }
        return await loadImage(for: asset, targetSize: targetSize)
    }

    static func prepareShareItem(for result: SearchResult) async throws -> PreparedPhotoShareItem {
        guard !result.isVideo else { throw PhotoSharePreparationError.unsupportedMedia }

        if result.sourceId != PhotoSourceType.photokit.rawValue {
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
        guard let source = CGImageSourceCreateWithData(snapshot.data as CFData, nil) else {
            throw PhotoSharePreparationError.sourceUnavailable
        }
        return try renderMetadataStrippedShareItem(from: source)
    }

    private static func preferredPhotoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .alternatePhoto })
            ?? resources.first(where: { $0.type == .photo })
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
        requestRegistered: @escaping @Sendable () -> Void = {},
        renderShareItem: @escaping @Sendable (URL) throws -> PreparedPhotoShareItem = { fileURL in
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                throw PhotoSharePreparationError.sourceUnavailable
            }
            return try renderMetadataStrippedShareItem(from: source)
        }
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
                do {
                    let item = try renderShareItem(fileURL)
                    PhotoShareFileCleanup.remove(fileURL)
                    completion(.success(item))
                } catch let error as PhotoSharePreparationError {
                    PhotoShareFileCleanup.remove(fileURL)
                    completion(.failure(error))
                } catch {
                    PhotoShareFileCleanup.remove(fileURL)
                    logger.error("[PhotoLibrary] Metadata-safe share rendering failed: \(error.safeDiagnosticCode)")
                    completion(.failure(.storageUnavailable))
                }
            })
        }
        guard let outcome else {
            throw writer.failure ?? PhotoSharePreparationError.sourceUnavailable
        }
        return try outcome.get()
    }

    private static func renderMetadataStrippedShareItem(
        from source: CGImageSource
    ) throws -> PreparedPhotoShareItem {
        guard !Task.isCancelled else { throw CancellationError() }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: PhotoShareResourcePolicy.maximumPixelDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw PhotoSharePreparationError.sourceUnavailable
        }
        guard !Task.isCancelled else { throw CancellationError() }

        let alphaInfo = image.alphaInfo
        let preservesAlpha = alphaInfo == .first
            || alphaInfo == .last
            || alphaInfo == .premultipliedFirst
            || alphaInfo == .premultipliedLast
        let outputType = preservesAlpha ? "public.png" : "public.jpeg"
        let pathExtension = preservesAlpha ? "png" : "jpg"
        let fileURL = try shareFileURL(pathExtension: pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(
            fileURL as CFURL,
            outputType as CFString,
            1,
            nil
        ) else {
            throw PhotoSharePreparationError.storageUnavailable
        }
        let properties: [CFString: Any] = preservesAlpha
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            PhotoShareFileCleanup.remove(fileURL)
            throw PhotoSharePreparationError.storageUnavailable
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let fileSize = attributes[.size] as? NSNumber,
                  fileSize.intValue <= PhotoShareResourcePolicy.maximumFileBytes else {
                PhotoShareFileCleanup.remove(fileURL)
                throw PhotoSharePreparationError.fileTooLarge
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: fileURL.path
            )
            try LocalOnlyStorage.excludeFromBackup(fileURL)
            return PreparedPhotoShareItem(fileURL: fileURL)
        } catch let error as PhotoSharePreparationError {
            throw error
        } catch {
            PhotoShareFileCleanup.remove(fileURL)
            logger.error("[PhotoLibrary] Could not finalize a share image: \(error.safeDiagnosticCode)")
            throw PhotoSharePreparationError.storageUnavailable
        }
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

    // Get a UIImage from a PHAsset for indexing. Embedding quality depends on
    // matching the displayed photo representation, so this intentionally uses
    // the same high-quality local request mode as the display path.
    static func loadImageForIndexing(for asset: PHAsset, targetSize: CGSize = CGSize(width: 224, height: 224)) async -> UIImage? {
        await requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: imageRequestOptions())
    }

    static func imageRequestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false
        options.resizeMode = .exact
        return options
    }

    private static func requestImage(
        for asset: PHAsset,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions
    ) async -> UIImage? {
        await withPhotoKitTimeout(seconds: TimeoutConfig.imageLoad) { completion in
            return PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                if photoKitRequestDidFail(info) {
                    completion(nil)
                    return
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    completion(image)
                }
            }
        }
    }

    // Get a thumbnail for display in search results — preserves original aspect ratio
    static func loadThumbnail(for asset: PHAsset, maxDimension: CGFloat = 400) async -> UIImage? {
        guard let targetSize = PhotoThumbnailSizePolicy.targetSize(
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            maxDimension: maxDimension
        ) else { return nil }

        return await withPhotoKitTimeout(seconds: TimeoutConfig.imageLoad) { completion in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false
            options.resizeMode = .fast

            return PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if photoKitRequestDidFail(info) {
                    completion(nil)
                    return
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    completion(image)
                }
            }
        }
    }

    static func fetchAllMedia() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                         PHAssetMediaType.image.rawValue,
                                         PHAssetMediaType.video.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    static func fetchMedia(ofType mediaType: PHAssetMediaType) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        return PHAsset.fetchAssets(with: options)
    }

    static func getAsset(by localIdentifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        return result.firstObject
    }

    static func loadVideoFrames(
        for asset: PHAsset,
        positions: [Double],
        targetSize: CGSize = CGSize(width: 224, height: 224)
    ) async -> [VideoFrame]? {
        let duration = asset.duration
        guard duration > 0, !positions.isEmpty else { return nil }
        let cancellation = VideoFrameCancellation()

        return await withPhotoKitRequest(
            seconds: TimeoutConfig.videoLoad,
            onCancel: { cancellation.cancel() }
        ) { completion, requestController in
            requestLocalVideoAsset(for: asset) { avAsset in
                guard let avAsset else {
                    completion(nil)
                    return
                }
                guard requestController.beginNextPhase() else { return }

                let generator = AVAssetImageGenerator(asset: avAsset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = targetSize
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

                let requestedTimes = positions.map {
                    NSValue(time: CMTime(seconds: duration * $0, preferredTimescale: 600))
                }
                let accumulator = VideoFrameAccumulator(
                    count: requestedTimes.count,
                    cancellation: cancellation,
                    completion: completion
                )
                requestController.scheduleTimeout(seconds: TimeoutConfig.videoLoad) {
                    accumulator.finishAfterTimeout()
                }
                generator.generateCGImagesAsynchronously(forTimes: requestedTimes) { requestedTime, cgImage, _, _, _ in
                    let requestedSeconds = CMTimeGetSeconds(requestedTime)
                    let position = positions.min {
                        abs(duration * $0 - requestedSeconds) < abs(duration * $1 - requestedSeconds)
                    } ?? (requestedSeconds / duration)
                    accumulator.receive(
                        position: position,
                        image: cgImage.map(UIImage.init(cgImage:))
                    )
                }
                cancellation.register(generator)
            }
        }
    }

    static func loadVideoPlaybackAsset(for asset: PHAsset) async -> VideoPlaybackAsset? {
        return await withPhotoKitTimeout(seconds: TimeoutConfig.videoLoad) { completion in
            requestLocalVideoAsset(for: asset) { avAsset in
                completion(avAsset.map(VideoPlaybackAsset.init(asset:)))
            }
        }
    }

    private static func requestLocalVideoAsset(
        for asset: PHAsset,
        completion: @escaping @Sendable (AVAsset?) -> Void
    ) -> PHImageRequestID {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat

        return PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
            avAsset,
            _,
            info in
            completion(photoKitRequestDidFail(info) ? nil : avAsset)
        }
    }

    private static func withPhotoKitTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping (@escaping @Sendable (T?) -> Void) -> PHImageRequestID
    ) async -> T? {
        await withPhotoKitRequest(seconds: seconds, onCancel: {}) { completion, _ in
            operation(completion)
        }
    }

    private static func withPhotoKitRequest<T: Sendable>(
        seconds: Double,
        cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void = {
            PHImageManager.default().cancelImageRequest($0)
        },
        requestRegistered: @escaping @Sendable () -> Void = {},
        onDiscardedResult: @escaping @Sendable (T) -> Void = { _ in },
        onCancel: @escaping @Sendable () -> Void,
        operation: @escaping (
            @escaping @Sendable (T?) -> Void,
            PhotoKitRequestController<T>
        ) -> PHImageRequestID
    ) async -> T? {
        let controller = PhotoKitRequestController<T>(
            cancelRequest: cancelRequest,
            onCancel: onCancel
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard controller.installContinuation(ContinuationGuard(continuation)) else {
                    return
                }
                controller.scheduleTimeout(seconds: seconds) { [weak controller] in
                    controller?.cancel()
                }
                let requestID = operation({ value in
                    if let value, !controller.finish(value) {
                        onDiscardedResult(value)
                    } else if value == nil {
                        controller.finish(nil)
                    }
                }, controller)
                controller.registerRequestID(requestID)
                requestRegistered()
            }
        } onCancel: {
            controller.cancel()
        }
    }

    private static func photoKitRequestDidFail(_ info: [AnyHashable: Any]?) -> Bool {
        if (info?[PHImageCancelledKey] as? Bool) == true { return true }
        if info?[PHImageErrorKey] != nil { return true }
        if (info?[PHImageResultIsInCloudKey] as? Bool) == true { return true }
        return false
    }

}
