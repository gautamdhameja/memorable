import Foundation
import Accelerate
import CoreML
import AVKit
import UIKit
import SwiftUI
import Photos

// MARK: - L2 Normalization

extension Array where Element == Float {
    /// L2-normalize the vector in place. After normalization, ||self|| = 1.
    mutating func l2Normalize() {
        var norm: Float = 0
        vDSP_svesq(self, 1, &norm, vDSP_Length(count))
        norm = sqrt(norm)
        if norm > 0 {
            vDSP_vsdiv(self, 1, &norm, &self, 1, vDSP_Length(count))
        }
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

// MARK: - Video Playback

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

/// Present a native AVPlayerViewController from anywhere in the app.
func presentVideoPlayer(for phAsset: PHAsset) {
    Task {
        guard let avAsset = await VideoFrameExtractor.loadAVAsset(from: phAsset) else { return }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
        let controller = AVPlayerViewController()
        controller.player = player

        await MainActor.run {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                topVC.present(controller, animated: true) {
                    player.play()
                }
            }
        }
    }
}

// MARK: - Haptics

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
