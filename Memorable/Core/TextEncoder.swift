import CoreML
import Accelerate
import os

protocol TextEmbeddingEncoding: Sendable {
    func encode(text: String) throws -> [Float]
    func encodeCancellable(text: String) async throws -> [Float]
}

extension TextEmbeddingEncoding {
    func encodeCancellable(text: String) async throws -> [Float] {
        try Task.checkCancellation()
        return try encode(text: text)
    }
}

final class TextEncoder: TextEmbeddingEncoding, Sendable {
    private let model: OSAllocatedUnfairLock<any CoreMLModelPredicting>
    private let tokenizer: CLIPTokenizer
    private let contextLength: Int = 64
    private static let predictionPermits = CancellablePermitPool(limit: 1)

    init(resourceManager: ModelResourceManaging = ModelResourceManager.shared) async throws {
        try Task.checkCancellation()
        let modelURL = try resourceManager.url(for: .textEncoder)
        #if DEBUG || STARTUP_METRICS
        let modelStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let loadedModel = try await MLModel.load(
            contentsOf: modelURL,
            configuration: Self.modelConfiguration()
        )
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.textModelLoad,
            durationSeconds: CFAbsoluteTimeGetCurrent() - modelStartedAt
        )
        #endif
        try Task.checkCancellation()
        self.model = OSAllocatedUnfairLock(initialState: loadedModel)
        #if DEBUG || STARTUP_METRICS
        let tokenizerStartedAt = CFAbsoluteTimeGetCurrent()
        #endif
        let tokenizer = try CLIPTokenizer(contextLength: contextLength)
        #if DEBUG || STARTUP_METRICS
        PerformanceMetrics.shared.record(
            PerformancePhase.tokenizerLoad,
            durationSeconds: CFAbsoluteTimeGetCurrent() - tokenizerStartedAt
        )
        #endif
        self.tokenizer = tokenizer
    }

    init(
        model: any CoreMLModelPredicting,
        tokenizer: CLIPTokenizer
    ) {
        self.model = OSAllocatedUnfairLock(initialState: model)
        self.tokenizer = tokenizer
    }

    func encode(text: String) throws -> [Float] {
        let tokenIds = try tokenizer.tokenize(text: text, maxLength: contextLength)

        #if DEBUG
        let nonPadTokens = tokenIds.filter { $0 != 0 }
        logger.info("[TextEncoder] Encoded \(nonPadTokens.count) non-padding tokens")
        #endif

        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: contextLength)], dataType: .int32)
        for (i, tokenId) in tokenIds.enumerated() {
            inputArray[i] = NSNumber(value: tokenId)
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray)
        ])

        let output = try currentModel().prediction(from: inputFeatures)

        guard let embeddingArray = output.featureValue(for: "text_embedding")?.multiArrayValue else {
            throw TextEncoderError.outputExtractionFailed
        }

        var embedding = embeddingArray.toFloatArray()
        guard embedding.count == EmbeddingConfig.dimensions else {
            throw TextEncoderError.invalidEmbedding
        }

        #if DEBUG
        var rawNorm: Float = 0
        vDSP_svesq(embedding, 1, &rawNorm, vDSP_Length(embedding.count))
        rawNorm = sqrt(rawNorm)
        #endif

        guard embedding.l2Normalize() else { throw TextEncoderError.invalidEmbedding }

        #if DEBUG
        var finalNorm: Float = 0
        vDSP_svesq(embedding, 1, &finalNorm, vDSP_Length(embedding.count))
        finalNorm = sqrt(finalNorm)
        logger.info("[TextEncoder] Embedding norm: raw=\(String(format: "%.4f", rawNorm)) -> normalized=\(String(format: "%.4f", finalNorm))")
        #endif

        return embedding
    }

    func encodeCancellable(text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let tokenIds = try tokenizer.tokenize(
            text: text,
            maxLength: contextLength
        )
        let inputArray = try MLMultiArray(
            shape: [1, NSNumber(value: contextLength)],
            dataType: .int32
        )
        for (index, tokenID) in tokenIds.enumerated() {
            inputArray[index] = NSNumber(value: tokenID)
        }
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray),
        ])
        guard await Self.predictionPermits.acquire() else {
            throw CancellationError()
        }

        let output: MLFeatureProvider
        do {
            try Task.checkCancellation()
            output = try await currentModel().cancellablePrediction(from: inputFeatures)
            await Self.predictionPermits.release()
        } catch {
            await Self.predictionPermits.release()
            throw error
        }
        try Task.checkCancellation()
        guard let embeddingArray = output.featureValue(
            for: "text_embedding"
        )?.multiArrayValue else {
            throw TextEncoderError.outputExtractionFailed
        }
        var embedding = embeddingArray.toFloatArray()
        guard embedding.count == EmbeddingConfig.dimensions,
              embedding.l2Normalize() else {
            throw TextEncoderError.invalidEmbedding
        }
        return embedding
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

    enum TextEncoderError: LocalizedError, Equatable {
        case modelNotFound
        case outputExtractionFailed
        case invalidEmbedding

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "The text analysis model could not be found. Please reinstall the app."
            case .outputExtractionFailed:
                return "The text analysis model returned an unexpected result."
            case .invalidEmbedding:
                return "The text analysis model returned an invalid embedding."
            }
        }
    }
}
