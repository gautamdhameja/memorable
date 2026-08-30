import Photos
import UIKit
import AVFoundation
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

    static func withPhotoKitRequest<T: Sendable>(
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
