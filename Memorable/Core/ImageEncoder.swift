import CoreML
import UIKit
import Accelerate

class ImageEncoder {
    private var model: MLModel

    init() throws {
        // Load the compiled Core ML model from the app bundle
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly  // Simulator lacks Neural Engine / GPU
        #else
        config.computeUnits = .all  // Use Neural Engine + GPU + CPU
        #endif
        guard let modelURL = Bundle.main.url(forResource: "SigLIP2_ImageEncoder", withExtension: "mlmodelc") else {
            throw ImageEncoderError.modelNotFound
        }
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    // Encode a UIImage into a 768-dimensional normalized embedding vector
    func encode(image: UIImage) throws -> [Float] {
        guard let pixelBuffer = image.toPixelBuffer(width: 224, height: 224) else {
            throw ImageEncoderError.preprocessingFailed
        }

        let inputArray = try pixelBufferToMLMultiArray(pixelBuffer: pixelBuffer, width: 224, height: 224)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "pixel_values": MLFeatureValue(multiArray: inputArray)
        ])

        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: inputFeatures)
        } catch {
            #if DEBUG
            logger.warning("[ImageEncoder] Prediction failed, reloading model: \(error.localizedDescription)")
            #endif
            try reloadModel()
            output = try model.prediction(from: inputFeatures)
        }

        guard let embeddingArray = output.featureValue(for: "image_embedding")?.multiArrayValue else {
            throw ImageEncoderError.outputExtractionFailed
        }

        var embedding = embeddingArray.toFloatArray()
        embedding.l2Normalize()
        return embedding
    }

    private func reloadModel() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        guard let modelURL = Bundle.main.url(forResource: "SigLIP2_ImageEncoder", withExtension: "mlmodelc") else {
            throw ImageEncoderError.modelNotFound
        }
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    private func pixelBufferToMLMultiArray(pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float16)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ImageEncoderError.preprocessingFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let pixelCount = height * width

        // SigLIP2 normalization: maps [0, 1] to [-1, 1]
        let mean: [Float] = [0.5, 0.5, 0.5]
        let std: [Float] = [0.5, 0.5, 0.5]

        // Write directly to MLMultiArray's underlying buffer — zero NSNumber allocations
        let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: 3 * pixelCount)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let r = (Float(pixels[offset + 2]) / 255.0 - mean[0]) / std[0]
                let g = (Float(pixels[offset + 1]) / 255.0 - mean[1]) / std[1]
                let b = (Float(pixels[offset]) / 255.0 - mean[2]) / std[2]

                let pixelIdx = y * width + x
                ptr[0 * pixelCount + pixelIdx] = Float16(r)
                ptr[1 * pixelCount + pixelIdx] = Float16(g)
                ptr[2 * pixelCount + pixelIdx] = Float16(b)
            }
        }

        return array
    }

    /// Batch-encode multiple images in a single Core ML prediction call.
    /// The Neural Engine is much more efficient with batched inputs.
    /// Returns array of L2-normalized embedding vectors (same order as input).
    func encodeBatch(images: [UIImage]) throws -> [[Float]] {
        guard !images.isEmpty else { return [] }

        #if DEBUG
        let batchStart = CFAbsoluteTimeGetCurrent()
        #endif

        // Preprocess all images into MLFeatureProviders
        var featureProviders: [MLFeatureProvider] = []
        for image in images {
            guard let pixelBuffer = image.toPixelBuffer(width: 224, height: 224) else {
                throw ImageEncoderError.preprocessingFailed
            }
            let inputArray = try pixelBufferToMLMultiArray(pixelBuffer: pixelBuffer, width: 224, height: 224)
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "pixel_values": MLFeatureValue(multiArray: inputArray)
            ])
            featureProviders.append(features)
        }

        // Run batch prediction
        let batchProvider = MLArrayBatchProvider(array: featureProviders)
        let batchResults: MLBatchProvider
        do {
            batchResults = try model.predictions(from: batchProvider, options: MLPredictionOptions())
        } catch {
            #if DEBUG
            logger.warning("[ImageEncoder] Batch prediction failed, reloading model: \(error.localizedDescription)")
            #endif
            try reloadModel()
            batchResults = try model.predictions(from: batchProvider, options: MLPredictionOptions())
        }

        // Extract embeddings
        var embeddings: [[Float]] = []
        for i in 0..<batchResults.count {
            let output = batchResults.features(at: i)
            guard let embeddingArray = output.featureValue(for: "image_embedding")?.multiArrayValue else {
                throw ImageEncoderError.outputExtractionFailed
            }

            var embedding = embeddingArray.toFloatArray()
            embedding.l2Normalize()
            embeddings.append(embedding)
        }

        #if DEBUG
        logger.info("[ImageEncoder] Batch of \(images.count) images encoded in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - batchStart))s")
        #endif

        return embeddings
    }

    enum ImageEncoderError: LocalizedError {
        case modelNotFound
        case preprocessingFailed
        case outputExtractionFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "The image analysis model could not be found. Please reinstall the app."
            case .preprocessingFailed:
                return "Failed to process the image. The file may be corrupted."
            case .outputExtractionFailed:
                return "The image analysis model returned an unexpected result."
            }
        }
    }
}

// UIImage extension to create a pixel buffer
extension UIImage {
    func toPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        guard let ctx = context, let cgImage = self.cgImage else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        return buffer
    }
}
