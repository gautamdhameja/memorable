import Photos
import UIKit
import AVFoundation
import os

class PhotoLibrary {
    private final class PhotoKitTimeoutController: Sendable {
        private struct State: Sendable {
            var task: Task<Void, Never>?
            var isStopped = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func register(_ task: Task<Void, Never>) {
            let shouldCancel = state.withLock { state in
                guard !state.isStopped else { return true }
                state.task = task
                return false
            }
            if shouldCancel {
                task.cancel()
            }
        }

        func stop() {
            let task = state.withLock { state in
                state.isStopped = true
                defer { state.task = nil }
                return state.task
            }
            task?.cancel()
        }
    }

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
    }

    /// PhotoKit owns request callbacks and may invoke them from arbitrary queues.
    /// The request identifier is always accessed under `lock`.
    fileprivate final class PhotoKitRequestToken: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHImageRequestID = PHInvalidImageRequestID

        func set(_ requestID: PHImageRequestID) {
            lock.lock()
            self.requestID = requestID
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let id = requestID
            requestID = PHInvalidImageRequestID
            lock.unlock()
            if id != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(id)
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
        // Compute target size that preserves the asset's aspect ratio
        let assetWidth = CGFloat(asset.pixelWidth)
        let assetHeight = CGFloat(asset.pixelHeight)
        let targetSize: CGSize
        if assetWidth > assetHeight {
            let scale = maxDimension / assetWidth
            targetSize = CGSize(width: maxDimension, height: assetHeight * scale)
        } else {
            let scale = maxDimension / assetHeight
            targetSize = CGSize(width: assetWidth * scale, height: maxDimension)
        }

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
        let assetLoadTimeout = PhotoKitTimeoutController()

        return await withPhotoKitTimeout(
            seconds: TimeoutConfig.videoLoad,
            timeoutController: assetLoadTimeout,
            onCancel: { cancellation.cancel() }
        ) { completion in
            requestLocalVideoAsset(for: asset) { avAsset in
                guard let avAsset else {
                    completion(nil)
                    return
                }
                assetLoadTimeout.stop()

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

    static func loadVideoURL(for asset: PHAsset) async -> URL? {
        await withPhotoKitTimeout(seconds: TimeoutConfig.videoLoad) { completion in
            requestLocalVideoAsset(for: asset) { avAsset in
                completion((avAsset as? AVURLAsset)?.url)
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

    // MARK: - Quick Look Support

    private static let quickLookCacheDir: URL = {
        // The iOS sandbox always provides a caches directory, but fall back to
        // the temp directory instead of crashing if the system somehow doesn't.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("QuickLookPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func getQuickLookURL(for asset: PHAsset) async -> URL? {
        if asset.mediaType == .video {
            return await loadVideoURL(for: asset)
        } else {
            return await withPhotoKitTimeout(seconds: TimeoutConfig.videoLoad) { completion in
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .highQualityFormat

                return PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                    if photoKitRequestDidFail(info) {
                        completion(nil)
                        return
                    }
                    guard let data else {
                        completion(nil)
                        return
                    }

                    let ext: String
                    if let uti, uti.hasPrefix("public.heic") || uti.hasPrefix("public.heif") {
                        ext = "heic"
                    } else if let uti, uti.contains("png") {
                        ext = "png"
                    } else {
                        ext = "jpg"
                    }

                    let fileURL = quickLookCacheDir
                        .appendingPathComponent(asset.localIdentifier.replacingOccurrences(of: "/", with: "_"))
                        .appendingPathExtension(ext)

                    do {
                        try data.write(to: fileURL, options: .atomic)
                        completion(fileURL)
                    } catch {
                        completion(nil)
                    }
                }
            }
        }
    }

    private static func withPhotoKitTimeout<T: Sendable>(
        seconds: Double,
        timeoutController: PhotoKitTimeoutController = PhotoKitTimeoutController(),
        onCancel: @escaping @Sendable () -> Void = {},
        operation: @escaping (@escaping @Sendable (T?) -> Void) -> PHImageRequestID
    ) async -> T? {
        let token = PhotoKitRequestToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let guard_ = ContinuationGuard(continuation)
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    } catch {
                        return
                    }
                    onCancel()
                    token.cancel()
                    guard_.resume(returning: nil)
                }
                timeoutController.register(timeoutTask)
                let requestID = operation { value in
                    timeoutController.stop()
                    guard_.resume(returning: value)
                }
                token.set(requestID)
            }
        } onCancel: {
            timeoutController.stop()
            onCancel()
            token.cancel()
        }
    }

    private static func photoKitRequestDidFail(_ info: [AnyHashable: Any]?) -> Bool {
        if (info?[PHImageCancelledKey] as? Bool) == true { return true }
        if info?[PHImageErrorKey] != nil { return true }
        if (info?[PHImageResultIsInCloudKey] as? Bool) == true { return true }
        return false
    }

    static func cleanupQuickLookFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupAllQuickLookFiles() {
        let dir = quickLookCacheDir
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
