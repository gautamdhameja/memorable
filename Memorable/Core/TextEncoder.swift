import CoreML

class TextEncoder {
    private var model: MLModel
    private let tokenizer: CLIPTokenizer
    private let contextLength: Int = 77

    init() throws {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        config.computeUnits = .all
        #endif
        guard let modelURL = Bundle.main.url(forResource: "MobileCLIP2_S4_TextEncoder", withExtension: "mlmodelc") else {
            throw TextEncoderError.modelNotFound
        }
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.tokenizer = try CLIPTokenizer(contextLength: contextLength)
    }

    func encode(text: String) throws -> [Float] {
        let tokenIds = tokenizer.tokenize(text: text.lowercased(), maxLength: contextLength)

        #if DEBUG
        let nonPadCount = tokenIds.filter { $0 != 0 }.count
        logger.info("[TextEncoder] Encoding '\(text.prefix(50))': \(nonPadCount) tokens (incl. SOT/EOT)")
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
        guard let modelURL = Bundle.main.url(forResource: "MobileCLIP2_S4_TextEncoder", withExtension: "mlmodelc") else {
            throw TextEncoderError.modelNotFound
        }
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
