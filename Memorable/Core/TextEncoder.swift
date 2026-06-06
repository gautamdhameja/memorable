import CoreML
import Accelerate

protocol TextEmbeddingEncoding {
    func encode(text: String) throws -> [Float]
}

class TextEncoder: TextEmbeddingEncoding {
    private var model: MLModel
    private let resourceManager: ModelResourceManaging
    private let tokenizer: CLIPTokenizer
    private let contextLength: Int = 64

    init(resourceManager: ModelResourceManaging = ModelResourceManager.shared) throws {
        self.resourceManager = resourceManager
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        let modelURL = try resourceManager.url(for: .textEncoder)
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.tokenizer = try CLIPTokenizer(contextLength: contextLength)
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
            output = try model.prediction(from: inputFeatures)
        } catch {
            #if DEBUG
            logger.warning("[TextEncoder] Prediction failed, reloading model: \(error.localizedDescription)")
            #endif
            try reloadModel()
            output = try model.prediction(from: inputFeatures)
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

    private func reloadModel() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        let modelURL = try resourceManager.url(for: .textEncoder)
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
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
