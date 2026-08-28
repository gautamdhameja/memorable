import UIKit
import Photos

enum VideoFrameExtractor {

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

    static func thumbnail(from phAsset: PHAsset, atPosition position: Double, targetSize: CGSize = CGSize(width: 400, height: 400)) async -> UIImage? {
        await PhotoLibrary.loadVideoFrames(
            for: phAsset,
            positions: [position],
            targetSize: targetSize
        )?.first?.image
    }
}
