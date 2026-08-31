import Foundation
import Accelerate
import CoreML
import AVKit
import UIKit
import SwiftUI
import Photos

extension Error {
    /// Returns a diagnostic category without user-controlled description text.
    var safeDiagnosticCode: String {
        let error = self as NSError
        return "\(error.domain)#\(error.code)"
    }
}

enum CancellableDetachedOperation {
    static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation()
        }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}

// MARK: - L2 Normalization

extension Array where Element == Float {
    /// L2-normalize the vector in place. After normalization, ||self|| = 1.
    @discardableResult
    mutating func l2Normalize() -> Bool {
        guard !isEmpty, allSatisfy(\.isFinite) else { return false }
        var norm: Float = 0
        vDSP_svesq(self, 1, &norm, vDSP_Length(count))
        norm = sqrt(norm)
        guard norm.isFinite, norm > 0 else { return false }
        vDSP_vsdiv(self, 1, &norm, &self, 1, vDSP_Length(count))
        return allSatisfy(\.isFinite)
    }
}

// MARK: - MLMultiArray Extraction

extension MLMultiArray {
    /// Extract values as [Float], handling both Float16 and Float32 data types.
    func toFloatArray() -> [Float] {
        let count = self.count
        var result = [Float](repeating: 0, count: count)

        if self.dataType == MLMultiArrayDataType.float16 {
            let ptr = self.dataPointer.bindMemory(to: Float16.self, capacity: count)
            for i in 0..<count { result[i] = Float(ptr[i]) }
        } else {
            let ptr = self.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count { result[i] = ptr[i] }
        }

        return result
    }
}

// MARK: - Timeout Wrapper

/// Wraps an async operation with a timeout. Returns nil if the timeout expires.
func withTimeout<T: Sendable>(seconds: Double, operation: @escaping (@escaping (T?) -> Void) -> Void) async -> T? {
    await withCheckedContinuation { continuation in
        let guard_ = ContinuationGuard(continuation)
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard_.resume(returning: nil)
        }
        operation { value in
            timeoutTask.cancel()
            guard_.resume(returning: value)
        }
    }
}

// MARK: - DateFormatter Cache

extension DateFormatter {
    static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
}

enum MemoryPressureReleasePolicy {
    static func release(_ image: inout UIImage?) {
        image = nil
    }

    static func release<Resource>(_ resource: inout Resource?) {
        resource = nil
    }
}

enum MemoryPressureImageRecoveryPolicy {
    enum Decision: Equatable {
        case preserve
        case release
        case releaseAndRetry
    }

    static let retryDelayNanoseconds: UInt64 = 1_000_000_000

    static func decision(
        hasImage: Bool,
        isActive: Bool,
        preserveVisibleImage: Bool
    ) -> Decision {
        guard isActive else { return .release }
        if hasImage && preserveVisibleImage { return .preserve }
        return .releaseAndRetry
    }
}

enum ImageLoadGenerationPolicy {
    static func acceptsCompletion(
        startedGeneration: UInt,
        currentGeneration: UInt,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && startedGeneration == currentGeneration
    }
}

struct SlideshowSelection<Item: Sendable>: Sendable {
    let item: Item
    let recentIDs: Set<String>
}

@MainActor
enum SlideshowSelectionPolicy {
    static func next<Item: Sendable>(
        recentIDs: Set<String>,
        historyLimit: Int,
        maxAttempts: Int = 5,
        fetch: () async -> Item?,
        identifier: (Item) -> String,
        accepts: (Item) -> Bool = { _ in true }
    ) async -> SlideshowSelection<Item>? {
        let boundedAttempts = max(1, maxAttempts)
        var fallback: Item?

        for _ in 0..<boundedAttempts {
            guard !Task.isCancelled else { return nil }
            guard let candidate = await fetch() else { break }
            guard accepts(candidate) else { continue }
            fallback = candidate
            if !recentIDs.contains(identifier(candidate)) {
                return selection(
                    candidate,
                    recentIDs: recentIDs,
                    historyLimit: historyLimit,
                    identifier: identifier
                )
            }
        }

        guard let fallback else { return nil }
        return selection(
            fallback,
            recentIDs: [],
            historyLimit: historyLimit,
            identifier: identifier
        )
    }

    private static func selection<Item: Sendable>(
        _ item: Item,
        recentIDs: Set<String>,
        historyLimit: Int,
        identifier: (Item) -> String
    ) -> SlideshowSelection<Item> {
        var updated = recentIDs
        if updated.count >= max(1, historyLimit) {
            updated.removeAll(keepingCapacity: true)
        }
        updated.insert(identifier(item))
        return SlideshowSelection(item: item, recentIDs: updated)
    }
}

enum MemoryPresentationValidator {
    static func isEligible(image: UIImage, requiresValidation: Bool) async -> Bool {
        guard requiresValidation else { return true }
        async let ocrText = OCRService.extractTextFast(from: image)
        async let sceneLabels = SceneClassifier.classify(image: image)
        return !MemoryContentPolicy.isDocumentImage(
            ocrText: await ocrText,
            sceneLabels: SceneClassifier.labelsToString(await sceneLabels)
        )
    }
}

enum VideoPlaybackRequestPolicy {
    static func acceptsCompletion(
        startedGeneration: UInt,
        currentGeneration: UInt,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && startedGeneration == currentGeneration
    }
}

// MARK: - Video Playback

@MainActor
enum PrivateVideoPlaybackConfiguration {
    static func apply(to player: AVPlayer, controller: AVPlayerViewController) {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        controller.allowsPictureInPicturePlayback = true
    }

    static func tearDown(
        player: AVPlayer,
        deactivateAudio: () throws -> Void
    ) rethrows {
        player.pause()
        try deactivateAudio()
    }
}

@MainActor
private final class PrivatePlayerViewController: AVPlayerViewController {
    var onPlaybackEnded: (() -> Void)?
    private var didEndPlayback = false

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didEndPlayback else { return }
        didEndPlayback = true
        onPlaybackEnded?()
        onPlaybackEnded = nil
    }
}

@MainActor
final class VideoPlaybackCoordinator {
    static let shared = VideoPlaybackCoordinator()

    private var loadTask: Task<Void, Never>?
    private var requestGeneration: UInt = 0
    private var activeController: PrivatePlayerViewController?

    func present(_ asset: PHAsset) {
        requestGeneration &+= 1
        let generation = requestGeneration
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dismissActivePlayback()
            guard VideoPlaybackRequestPolicy.acceptsCompletion(
                startedGeneration: generation,
                currentGeneration: self.requestGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            guard let playbackAsset = await PhotoLibrary.loadVideoPlaybackAsset(for: asset) else {
                return
            }
            guard VideoPlaybackRequestPolicy.acceptsCompletion(
                startedGeneration: generation,
                currentGeneration: self.requestGeneration,
                isCancelled: Task.isCancelled
            ) else { return }
            self.present(playbackAsset, generation: generation)
        }
    }

    func cancelPendingPresentation() {
        requestGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    func cancelForMemoryPressure() {
        cancelPendingPresentation()
        Task { @MainActor [weak self] in
            await self?.dismissActivePlayback()
        }
    }

    private func present(_ playbackAsset: PhotoLibrary.VideoPlaybackAsset, generation: UInt) {
        guard VideoPlaybackRequestPolicy.acceptsCompletion(
            startedGeneration: generation,
            currentGeneration: requestGeneration,
            isCancelled: Task.isCancelled
        ), let presenter = Self.presentationController(),
           presenter.viewIfLoaded?.window != nil,
           let player = playbackAsset.makePlayer() else {
            return
        }

        let controller = PrivatePlayerViewController()
        PrivateVideoPlaybackConfiguration.apply(to: player, controller: controller)
        controller.player = player
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Failed to configure audio playback: \(error.safeDiagnosticCode)")
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            return
        }

        activeController = controller
        controller.onPlaybackEnded = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.finishPlayback(controller)
        }
        presenter.present(controller, animated: true) { [weak self, weak controller] in
            guard let self, let controller,
                  self.activeController === controller,
                  VideoPlaybackRequestPolicy.acceptsCompletion(
                    startedGeneration: generation,
                    currentGeneration: self.requestGeneration,
                    isCancelled: false
                  ) else {
                if let controller {
                    self?.finishPlayback(controller)
                }
                return
            }
            player.play()
        }
        loadTask = nil
    }

    private func dismissActivePlayback() async {
        guard let controller = activeController else { return }
        finishPlayback(controller)
        guard controller.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: true) {
                continuation.resume()
            }
        }
    }

    private func finishPlayback(_ controller: PrivatePlayerViewController) {
        guard activeController === controller else { return }
        controller.onPlaybackEnded = nil
        if let player = controller.player {
            do {
                try PrivateVideoPlaybackConfiguration.tearDown(player: player) {
                    try AVAudioSession.sharedInstance().setActive(
                        false,
                        options: .notifyOthersOnDeactivation
                    )
                }
            } catch {
                logger.error("Failed to release audio playback: \(error.safeDiagnosticCode)")
            }
        }
        controller.player = nil
        activeController = nil
    }

    private static func presentationController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return nil
        }
        var presenter = root
        while let presented = presenter.presentedViewController,
              !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }
}

/// Presents one private, local-only video player at a time.
@MainActor
func presentVideoPlayer(for phAsset: PHAsset) {
    VideoPlaybackCoordinator.shared.present(phAsset)
}

@MainActor
func cancelPendingVideoPlayerPresentation() {
    VideoPlaybackCoordinator.shared.cancelPendingPresentation()
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Array Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
enum LocalOnlyStorage {
    static func prepareDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try excludeFromBackup(url)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
    }

    static func excludeFromBackup(_ url: URL) throws {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
    }
}
