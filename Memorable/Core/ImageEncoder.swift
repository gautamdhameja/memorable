import CoreML
import UIKit
import Accelerate
import os

final class ImageEncoder: Sendable {
    private let model: OSAllocatedUnfairLock<any CoreMLModelPredicting>

    init(resourceManager: ModelResourceManaging = ModelResourceManager.shared) async throws {
        try Task.checkCancellation()
        let modelURL = try resourceManager.url(for: .imageEncoder)
        let loadedModel = try await MLModel.load(
            contentsOf: modelURL,
            configuration: Self.modelConfiguration()
        )
        try Task.checkCancellation()
        self.model = OSAllocatedUnfairLock(initialState: loadedModel)
    }

    init(model: any CoreMLModelPredicting) {
        self.model = OSAllocatedUnfairLock(initialState: model)
    }

    // Encode a UIImage into a 768-dimensional normalized embedding vector
    func encode(image: UIImage) throws -> [Float] {
        try Task.checkCancellation()
        guard let pixelBuffer = image.toPixelBuffer(width: 224, height: 224) else {
            throw ImageEncoderError.preprocessingFailed
        }

        let inputArray = try pixelBufferToMLMultiArray(pixelBuffer: pixelBuffer, width: 224, height: 224)
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "pixel_values": MLFeatureValue(multiArray: inputArray)
        ])
        try Task.checkCancellation()

        let output = try currentModel().prediction(from: inputFeatures)

        guard let embeddingArray = output.featureValue(for: "image_embedding")?.multiArrayValue else {
            throw ImageEncoderError.outputExtractionFailed
        }

        var embedding = embeddingArray.toFloatArray()
        try Task.checkCancellation()
        guard embedding.count == EmbeddingConfig.dimensions else {
            throw ImageEncoderError.invalidEmbedding
        }
        guard embedding.l2Normalize() else { throw ImageEncoderError.invalidEmbedding }
        return embedding
    }

    /// Uses Core ML's async prediction API so cancellation can stop an active
    /// production inference instead of only discarding its eventual result.
    func encodeCancellable(image: UIImage) async throws -> [Float] {
        try Task.checkCancellation()
        guard let pixelBuffer = image.toPixelBuffer(width: 224, height: 224) else {
            throw ImageEncoderError.preprocessingFailed
        }
        let inputArray = try pixelBufferToMLMultiArray(
            pixelBuffer: pixelBuffer,
            width: 224,
            height: 224
        )
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "pixel_values": MLFeatureValue(multiArray: inputArray),
        ])
        try Task.checkCancellation()
        let output = try await currentModel().cancellablePrediction(from: inputFeatures)
        try Task.checkCancellation()
        guard let embeddingArray = output.featureValue(
            for: "image_embedding"
        )?.multiArrayValue else {
            throw ImageEncoderError.outputExtractionFailed
        }
        var embedding = embeddingArray.toFloatArray()
        guard embedding.count == EmbeddingConfig.dimensions,
              embedding.l2Normalize() else {
            throw ImageEncoderError.invalidEmbedding
        }
        return embedding
    }

    /// Keep inference single-flight and release each image's feature buffers
    /// before starting the next item. This bounds cancellation-time memory.
    func encodeBatchCancellable(images: [UIImage]) async throws -> [[Float]] {
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(images.count)
        for image in images {
            try Task.checkCancellation()
            embeddings.append(try await encodeCancellable(image: image))
        }
        return embeddings
    }

    private func currentModel() -> any CoreMLModelPredicting {
        model.withLock { $0 }
    }

    private static func modelConfiguration() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        return config
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
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
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
        try Task.checkCancellation()

        #if DEBUG
        let batchStart = CFAbsoluteTimeGetCurrent()
        #endif

        // Preprocess all images into MLFeatureProviders
        var featureProviders: [MLFeatureProvider] = []
        for image in images {
            try Task.checkCancellation()
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
        try Task.checkCancellation()
        let batchResults = try currentModel().predictions(
            from: batchProvider,
            options: MLPredictionOptions()
        )
        guard batchResults.count == images.count else {
            throw ImageEncoderError.invalidEmbedding
        }

        // Extract embeddings
        var embeddings: [[Float]] = []
        for i in 0..<batchResults.count {
            try Task.checkCancellation()
            let output = batchResults.features(at: i)
            guard let embeddingArray = output.featureValue(for: "image_embedding")?.multiArrayValue else {
                throw ImageEncoderError.outputExtractionFailed
            }

            var embedding = embeddingArray.toFloatArray()
            guard embedding.count == EmbeddingConfig.dimensions else {
                throw ImageEncoderError.invalidEmbedding
            }
            guard embedding.l2Normalize() else { throw ImageEncoderError.invalidEmbedding }
            embeddings.append(embedding)
        }

        #if DEBUG
        logger.info("[ImageEncoder] Batch of \(images.count) images encoded in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - batchStart))s")
        #endif

        return embeddings
    }

    enum ImageEncoderError: LocalizedError, Equatable {
        case modelNotFound
        case preprocessingFailed
        case outputExtractionFailed
        case invalidEmbedding

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "The image analysis model could not be found. Please reinstall the app."
            case .preprocessingFailed:
                return "Failed to process the image. The file may be corrupted."
            case .outputExtractionFailed:
                return "The image analysis model returned an unexpected result."
            case .invalidEmbedding:
                return "The image analysis model returned an invalid embedding."
            }
        }
    }
}

// UIImage extension to create a pixel buffer
extension UIImage {
    func toPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard cgImage != nil || ciImage != nil else { return nil }

        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true as CFBoolean,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true as CFBoolean
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

        guard let ctx = context else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }

        // UIKit drawing assumes a top-left origin, while a raw bitmap context
        // uses a bottom-left origin. Align the context before drawing so row 0
        // contains the visually top row while UIImage still applies its EXIF
        // orientation.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        self.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()
        CVPixelBufferUnlockBaseAddress(buffer, [])

        return buffer
    }
}
