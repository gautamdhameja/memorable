import CoreML
import UIKit
import XCTest
import os
@testable import Memorable

final class EncoderConcurrencyTests: XCTestCase {
    private enum TestError: Error {
        case forcedPredictionFailure
    }

    private final class LockedCounter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)

        func increment() {
            count.withLock { $0 += 1 }
        }

        func value() -> Int {
            count.withLock { $0 }
        }
    }

    private final class EncodeResults: Sendable {
        private struct State {
            var embeddings: [[Float]] = []
            var errors: [Error] = []
        }

        private let state = OSAllocatedUnfairLock(uncheckedState: State())

        func record(_ result: Result<[Float], Error>) {
            state.withLockUnchecked { state in
                switch result {
                case .success(let embedding):
                    state.embeddings.append(embedding)
                case .failure(let error):
                    state.errors.append(error)
                }
            }
        }

        func snapshot() -> (embeddings: [[Float]], errors: [Error]) {
            state.withLockUnchecked { ($0.embeddings, $0.errors) }
        }
    }

    private final class ControlledPredictionModel: CoreMLModelPredicting {
        private struct FailureState: Sendable {
            var remainingPredictions: Int
            var remainingBatches: Int
        }

        private let embeddingKey: String
        private let failures: OSAllocatedUnfairLock<FailureState>

        init(
            embeddingKey: String,
            predictionFailures: Int = 0,
            batchFailures: Int = 0
        ) {
            self.embeddingKey = embeddingKey
            self.failures = OSAllocatedUnfairLock(
                initialState: FailureState(
                    remainingPredictions: predictionFailures,
                    remainingBatches: batchFailures
                )
            )
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
            failures.withLock {
                guard $0.remainingPredictions > 0 else { return false }
                $0.remainingPredictions -= 1
                return true
            }
        }

        private func consumeBatchFailure() -> Bool {
            failures.withLock {
                guard $0.remainingBatches > 0 else { return false }
                $0.remainingBatches -= 1
                return true
            }
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
