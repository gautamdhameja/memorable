import CoreML
import Accelerate

protocol TextEmbeddingEncoding {
    func encode(text: String) throws -> [Float]
}

class TextEncoder: TextEmbeddingEncoding {
    private var model: CoreMLModelPredicting
    private let modelLoader: () throws -> CoreMLModelPredicting
    private let modelLock = NSLock()
    private let tokenizer: CLIPTokenizer
    private let contextLength: Int = 64

    init(resourceManager: ModelResourceManaging = ModelResourceManager.shared) throws {
        let loader = {
            let modelURL = try resourceManager.url(for: .textEncoder)
            return try MLModel(contentsOf: modelURL, configuration: Self.modelConfiguration())
        }
        self.modelLoader = loader
        self.model = try loader()
        self.tokenizer = try CLIPTokenizer(contextLength: contextLength)
    }

    init(
        model: CoreMLModelPredicting,
        tokenizer: CLIPTokenizer,
        modelLoader: @escaping () throws -> CoreMLModelPredicting
    ) {
        self.model = model
        self.tokenizer = tokenizer
        self.modelLoader = modelLoader
    }

    func encode(text: String) throws -> [Float] {
        let tokenIds = tokenizer.tokenize(text: text.lowercased(), maxLength: contextLength)

        #if DEBUG
        let nonPadTokens = tokenIds.filter { $0 != 0 }
        let idPreview = nonPadTokens.map { String($0) }.joined(separator: ", ")
        logger.info("[TextEncoder] '\(text.prefix(60))' -> \(nonPadTokens.count) tokens, ids=[\(idPreview)]")
        #endif

        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: contextLength)], dataType: .int32)
        for (i, tokenId) in tokenIds.enumerated() {
            inputArray[i] = NSNumber(value: tokenId)
        }

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputArray)
        ])

        let output: MLFeatureProvider
        do {
            output = try currentModel().prediction(from: inputFeatures)
        } catch {
            #if DEBUG
            logger.warning("[TextEncoder] Prediction failed, reloading model: \(error.localizedDescription)")
            #endif
            output = try reloadModel().prediction(from: inputFeatures)
        }

        guard let embeddingArray = output.featureValue(for: "text_embedding")?.multiArrayValue else {
            throw TextEncoderError.outputExtractionFailed
        }

        var embedding = embeddingArray.toFloatArray()

        #if DEBUG
        var rawNorm: Float = 0
        vDSP_svesq(embedding, 1, &rawNorm, vDSP_Length(embedding.count))
        rawNorm = sqrt(rawNorm)
        #endif

        embedding.l2Normalize()

        #if DEBUG
        var finalNorm: Float = 0
        vDSP_svesq(embedding, 1, &finalNorm, vDSP_Length(embedding.count))
        finalNorm = sqrt(finalNorm)
        logger.info("[TextEncoder] Embedding norm: raw=\(String(format: "%.4f", rawNorm)) -> normalized=\(String(format: "%.4f", finalNorm))")
        #endif

        return embedding
    }

    private func currentModel() -> CoreMLModelPredicting {
        modelLock.lock()
        defer { modelLock.unlock() }
        return model
    }

    @discardableResult
    private func reloadModel() throws -> CoreMLModelPredicting {
        let reloadedModel = try modelLoader()
        modelLock.lock()
        model = reloadedModel
        modelLock.unlock()
        return reloadedModel
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

    enum TextEncoderError: LocalizedError {
        case modelNotFound
        case outputExtractionFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "The text analysis model could not be found. Please reinstall the app."
            case .outputExtractionFailed:
                return "The text analysis model returned an unexpected result."
            }
        }
    }
}
