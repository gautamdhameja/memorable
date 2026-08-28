import CoreML
import UIKit
import XCTest
@testable import Memorable

final class EncoderConcurrencyTests: XCTestCase {
    private enum TestError: Error {
        case forcedPredictionFailure
    }

    private final class LockedCounter {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class EncodeResults {
        private let lock = NSLock()
        private var embeddings: [[Float]] = []
        private var errors: [Error] = []

        func record(_ result: Result<[Float], Error>) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let embedding):
                embeddings.append(embedding)
            case .failure(let error):
                errors.append(error)
            }
        }

        func snapshot() -> (embeddings: [[Float]], errors: [Error]) {
            lock.lock()
            defer { lock.unlock() }
            return (embeddings, errors)
        }
    }

    private final class ControlledPredictionModel: CoreMLModelPredicting {
        private let lock = NSLock()
        private let embeddingKey: String
        private var remainingPredictionFailures: Int
        private var remainingBatchFailures: Int

        init(
            embeddingKey: String,
            predictionFailures: Int = 0,
            batchFailures: Int = 0
        ) {
            self.embeddingKey = embeddingKey
            self.remainingPredictionFailures = predictionFailures
            self.remainingBatchFailures = batchFailures
        }

        func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
            if consumePredictionFailure() {
                throw TestError.forcedPredictionFailure
            }
            return try makeOutputProvider()
        }

        func predictions(
            from inputBatch: MLBatchProvider,
            options: MLPredictionOptions
        ) throws -> MLBatchProvider {
            if consumeBatchFailure() {
                throw TestError.forcedPredictionFailure
            }
            let outputs = try (0..<inputBatch.count).map { _ in
                try makeOutputProvider()
            }
            return MLArrayBatchProvider(array: outputs)
        }

        private func consumePredictionFailure() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard remainingPredictionFailures > 0 else { return false }
            remainingPredictionFailures -= 1
            return true
        }

        private func consumeBatchFailure() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard remainingBatchFailures > 0 else { return false }
            remainingBatchFailures -= 1
            return true
        }

        private func makeOutputProvider() throws -> MLFeatureProvider {
            let array = try MLMultiArray(
                shape: [1, NSNumber(value: EmbeddingConfig.dimensions)],
                dataType: .float32
            )
            for index in 0..<array.count {
                array[index] = 1
            }
            return try MLDictionaryFeatureProvider(dictionary: [
                embeddingKey: MLFeatureValue(multiArray: array)
            ])
        }
    }

    func testTextEncoderConcurrentPredictionsSurviveForcedReload() throws {
        let initialModel = ControlledPredictionModel(
            embeddingKey: "text_embedding",
            predictionFailures: 1
        )
        let replacementModel = ControlledPredictionModel(embeddingKey: "text_embedding")
        let reloadCount = LockedCounter()
        let encoder = TextEncoder(
            model: initialModel,
            tokenizer: try CLIPTokenizer()
        ) {
            reloadCount.increment()
            return replacementModel
        }
        let results = EncodeResults()
        let iterationCount = 24

        DispatchQueue.concurrentPerform(iterations: iterationCount) { index in
            results.record(Result {
                try encoder.encode(text: "photo search query \(index % 6)")
            })
        }

        let snapshot = results.snapshot()
        XCTAssertTrue(snapshot.errors.isEmpty)
        XCTAssertEqual(snapshot.embeddings.count, iterationCount)
        XCTAssertEqual(reloadCount.value(), 1)
        assertNormalized(snapshot.embeddings)
    }

    func testImageEncoderConcurrentPredictionsSurviveForcedReload() {
        let initialModel = ControlledPredictionModel(
            embeddingKey: "image_embedding",
            predictionFailures: 1
        )
        let replacementModel = ControlledPredictionModel(embeddingKey: "image_embedding")
        let reloadCount = LockedCounter()
        let encoder = ImageEncoder(model: initialModel) {
            reloadCount.increment()
            return replacementModel
        }
        let image = makeTestImage()
        let results = EncodeResults()
        let iterationCount = 12

        DispatchQueue.concurrentPerform(iterations: iterationCount) { _ in
            results.record(Result { try encoder.encode(image: image) })
        }

        let snapshot = results.snapshot()
        XCTAssertTrue(snapshot.errors.isEmpty)
        XCTAssertEqual(snapshot.embeddings.count, iterationCount)
        XCTAssertEqual(reloadCount.value(), 1)
        assertNormalized(snapshot.embeddings)
    }

    func testImageEncoderBatchPredictionRetriesOnceAfterReload() throws {
        let initialModel = ControlledPredictionModel(
            embeddingKey: "image_embedding",
            batchFailures: 1
        )
        let replacementModel = ControlledPredictionModel(embeddingKey: "image_embedding")
        let reloadCount = LockedCounter()
        let encoder = ImageEncoder(model: initialModel) {
            reloadCount.increment()
            return replacementModel
        }

        let embeddings = try encoder.encodeBatch(images: [makeTestImage(), makeTestImage()])

        XCTAssertEqual(embeddings.count, 2)
        XCTAssertEqual(reloadCount.value(), 1)
        assertNormalized(embeddings)
    }

    private func assertNormalized(
        _ embeddings: [[Float]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for embedding in embeddings {
            XCTAssertEqual(embedding.count, EmbeddingConfig.dimensions, file: file, line: line)
            let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
            XCTAssertEqual(norm, 1, accuracy: 0.0001, file: file, line: line)
        }
    }

    private func makeTestImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
