import CoreML
import UIKit
import XCTest
import os
@testable import Memorable

final class EncoderConcurrencyTests: XCTestCase {
    private enum TestError: Error {
        case forcedPredictionFailure
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
        }

        private let embeddingKey: String
        private let embeddingDimensions: Int
        private let failures: OSAllocatedUnfairLock<FailureState>

        init(
            embeddingKey: String,
            embeddingDimensions: Int = EmbeddingConfig.dimensions,
            predictionFailures: Int = 0
        ) {
            self.embeddingKey = embeddingKey
            self.embeddingDimensions = embeddingDimensions
            self.failures = OSAllocatedUnfairLock(
                initialState: FailureState(
                    remainingPredictions: predictionFailures
                )
            )
        }

        func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
            if consumePredictionFailure() {
                throw TestError.forcedPredictionFailure
            }
            return try makeOutputProvider()
        }

        private func consumePredictionFailure() -> Bool {
            failures.withLock {
                guard $0.remainingPredictions > 0 else { return false }
                $0.remainingPredictions -= 1
                return true
            }
        }

        private func makeOutputProvider() throws -> MLFeatureProvider {
            let array = try MLMultiArray(
                shape: [1, NSNumber(value: embeddingDimensions)],
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

    private final class BlockingAsyncPredictionModel: CoreMLModelPredicting {
        let probe = AsyncPredictionProbe()

        func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
            throw TestError.forcedPredictionFailure
        }

        func cancellablePrediction(
            from input: MLFeatureProvider
        ) async throws -> MLFeatureProvider {
            await probe.markStarted()
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw TestError.forcedPredictionFailure
            } catch is CancellationError {
                await probe.markCancelled()
                throw CancellationError()
            }
        }

    }

    func testTextEncoderConcurrentPredictionFailuresFailClosed() throws {
        let initialModel = ControlledPredictionModel(
            embeddingKey: "text_embedding",
            predictionFailures: 24
        )
        let encoder = TextEncoder(
            model: initialModel,
            tokenizer: try CLIPTokenizer()
        )
        let results = EncodeResults()
        let iterationCount = 24

        DispatchQueue.concurrentPerform(iterations: iterationCount) { index in
            results.record(Result {
                try encoder.encode(text: "photo search query \(index % 6)")
            })
        }

        let snapshot = results.snapshot()
        XCTAssertTrue(snapshot.embeddings.isEmpty)
        XCTAssertEqual(snapshot.errors.count, iterationCount)
    }

    func testTextEncoderAsyncPredictionObservesCancellation() async throws {
        let model = BlockingAsyncPredictionModel()
        let encoder = TextEncoder(model: model, tokenizer: try CLIPTokenizer())
        let task = Task {
            try await encoder.encodeCancellable(text: "cancel this search")
        }
        let didStart = await model.probe.waitUntilStarted()
        XCTAssertTrue(didStart)

        task.cancel()
        _ = await task.result

        let wasCancelled = await model.probe.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testImageEncoderConcurrentPredictionFailuresFailClosed() {
        let initialModel = ControlledPredictionModel(
            embeddingKey: "image_embedding",
            predictionFailures: 12
        )
        let encoder = ImageEncoder(model: initialModel)
        let image = makeTestImage()
        let results = EncodeResults()
        let iterationCount = 12

        DispatchQueue.concurrentPerform(iterations: iterationCount) { _ in
            results.record(Result { try encoder.encode(image: image) })
        }

        let snapshot = results.snapshot()
        XCTAssertTrue(snapshot.embeddings.isEmpty)
        XCTAssertEqual(snapshot.errors.count, iterationCount)
    }

    func testImageEncoderBatchPredictionFailureFailsClosed() async {
        let encoder = ImageEncoder(model: ControlledPredictionModel(
            embeddingKey: "image_embedding", predictionFailures: 1
        ))
        do {
            _ = try await encoder.encodeBatchCancellable(images: [makeTestImage(), makeTestImage()])
            XCTFail("A failed prediction must fail the batch")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    func testTextEncoderRejectsShortModelOutput() throws {
        let encoder = TextEncoder(
            model: ControlledPredictionModel(
                embeddingKey: "text_embedding",
                embeddingDimensions: 1
            ),
            tokenizer: try CLIPTokenizer()
        )

        XCTAssertThrowsError(try encoder.encode(text: "photo")) { error in
            XCTAssertEqual(error as? TextEncoder.TextEncoderError, .invalidEmbedding)
        }
    }

    func testImageEncoderRejectsShortModelOutput() {
        let encoder = ImageEncoder(model: ControlledPredictionModel(
            embeddingKey: "image_embedding",
            embeddingDimensions: 1
        ))

        XCTAssertThrowsError(try encoder.encode(image: makeTestImage())) { error in
            XCTAssertEqual(error as? ImageEncoder.ImageEncoderError, .invalidEmbedding)
        }
    }

    func testImageEncoderBatchRejectsShortModelOutput() async {
        let encoder = ImageEncoder(model: ControlledPredictionModel(
            embeddingKey: "image_embedding", embeddingDimensions: 1
        ))
        do {
            _ = try await encoder.encodeBatchCancellable(images: [makeTestImage()])
            XCTFail("A malformed embedding must fail the batch")
        } catch {
            XCTAssertEqual(error as? ImageEncoder.ImageEncoderError, .invalidEmbedding)
        }
    }

    func testImageEncoderBatchReturnsOneNormalizedEmbeddingPerImage() async throws {
        let encoder = ImageEncoder(model: ControlledPredictionModel(embeddingKey: "image_embedding"))
        let embeddings = try await encoder.encodeBatchCancellable(images: [makeTestImage(), makeTestImage()])
        XCTAssertEqual(embeddings.count, 2)
        assertNormalized(embeddings)
        let empty = try await encoder.encodeBatchCancellable(images: [])
        XCTAssertTrue(empty.isEmpty)
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

private actor AsyncPredictionProbe {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false

    func markStarted() {
        hasStarted = true
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !hasStarted, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return hasStarted
    }

    func markCancelled() {
        wasCancelled = true
    }
}
