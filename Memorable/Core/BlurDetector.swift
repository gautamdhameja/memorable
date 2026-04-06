import UIKit
import Accelerate

class BlurDetector {

    /// Compute a sharpness score for an image using Laplacian variance.
    /// Higher score = sharper image. Typical ranges:
    /// - Very blurry: < 20
    /// - Slightly blurry: 20-50
    /// - Acceptable: 50-100
    /// - Sharp: > 100
    static func sharpnessScore(for image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 10, height > 10 else { return 0 }

        // Convert to grayscale
        let pixelCount = width * height
        var grayPixels = [Float](repeating: 0, count: pixelCount)

        guard let context = CGContext(
            data: &grayPixels,
            width: width,
            height: height,
            bitsPerComponent: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue).rawValue
        ) else {
            // Fallback: manual grayscale conversion
            return manualSharpness(cgImage: cgImage, width: width, height: height)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Apply 3x3 Laplacian kernel: [0, 1, 0; 1, -4, 1; 0, 1, 0]
        // Compute variance of the Laplacian response
        return computeLaplacianVariance(pixels: grayPixels, width: width, height: height)
    }

    private static func computeLaplacianVariance(pixels: [Float], width: Int, height: Int) -> Double {
        var sum: Double = 0
        var sumSq: Double = 0
        var count: Double = 0

        // Skip borders (1 pixel each side)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                let laplacian =
                    pixels[idx - width] +     // top
                    pixels[idx - 1] +         // left
                    -4 * pixels[idx] +        // center
                    pixels[idx + 1] +         // right
                    pixels[idx + width]       // bottom

                sum += Double(laplacian)
                sumSq += Double(laplacian) * Double(laplacian)
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        let mean = sum / count
        let variance = (sumSq / count) - (mean * mean)
        return variance * 10000 // Scale up for readable numbers
    }

    private static func manualSharpness(cgImage: CGImage, width: Int, height: Int) -> Double {
        // Fallback using raw RGBA data
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to grayscale floats
        var grayPixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * bytesPerRow + x * bytesPerPixel
                let r = Float(rawData[idx])
                let g = Float(rawData[idx + 1])
                let b = Float(rawData[idx + 2])
                grayPixels[y * width + x] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            }
        }

        return computeLaplacianVariance(pixels: grayPixels, width: width, height: height)
    }
}
