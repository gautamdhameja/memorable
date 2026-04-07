import AVFoundation
import UIKit
import Photos

class VideoFrameExtractor {

    static func frameCount(forDuration duration: Double) -> Int {
        VideoFrameConfig.frameCount(forDuration: duration)
    }

    static func framePositions(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        if count == 1 { return [0.5] }

        var positions: [Double] = []
        for i in 0..<count {
            let position = 0.1 + (0.8 * Double(i) / Double(count - 1))
            positions.append(position)
        }
        return positions
    }

    static func extractFrames(from asset: AVAsset, positions: [Double], targetSize: CGSize = CGSize(width: 224, height: 224)) async -> [(position: Double, image: UIImage)] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        guard let duration = try? await asset.load(.duration) else { return [] }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds > 0 else { return [] }

        var results: [(position: Double, image: UIImage)] = []

        for position in positions {
            let timeSeconds = durationSeconds * position
            let time = CMTime(seconds: timeSeconds, preferredTimescale: 600)

            do {
                let (cgImage, _) = try await generator.image(at: time)
                let image = UIImage(cgImage: cgImage)
                results.append((position: position, image: image))
            } catch {
                continue
            }
        }

        return results
    }

    static func loadAVAsset(from phAsset: PHAsset) async -> AVAsset? {
        await withTimeout(seconds: TimeoutConfig.videoLoad) { completion in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, _ in
                completion(avAsset)
            }
        }
    }

    static func thumbnail(from phAsset: PHAsset, atPosition position: Double, targetSize: CGSize = CGSize(width: 400, height: 400)) async -> UIImage? {
        guard let avAsset = await loadAVAsset(from: phAsset) else { return nil }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize

        guard let duration = try? await avAsset.load(.duration) else { return nil }
        let time = CMTime(seconds: CMTimeGetSeconds(duration) * position, preferredTimescale: 600)

        guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
