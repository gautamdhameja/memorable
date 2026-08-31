import Vision
import UIKit

private final class VisionWorkBox<Value: Sendable>: @unchecked Sendable {
    let request: VNRequest
    let operation: () throws -> Value

    init(request: VNRequest, operation: @escaping () throws -> Value) {
        self.request = request
        self.operation = operation
    }
}

enum CancellableVisionOperation {
    static func run<Value: Sendable>(
        request: VNRequest,
        operation: @escaping () throws -> Value
    ) async throws -> Value {
        let box = VisionWorkBox(request: request, operation: operation)
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try box.operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            box.request.cancel()
            task.cancel()
        }
    }
}

enum OCRTextPolicy {
    static let maximumObservations = 256
    static let maximumCharacters = 4_096

    static func boundedText(from fragments: some Sequence<String>) -> String? {
        var retained: [String] = []
        retained.reserveCapacity(maximumObservations)
        var scalarCount = 0
        for fragment in fragments.prefix(maximumObservations) {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let separatorCount = retained.isEmpty ? 0 : 1
            let remaining = maximumCharacters - scalarCount - separatorCount
            guard remaining > 0 else { break }
            let bounded = QueryInputPolicy.bounded(
                trimmed,
                maximumUnicodeScalars: remaining,
                maximumUTF8Bytes: remaining * 4
            )
            guard !bounded.isEmpty else { continue }
            retained.append(bounded)
            scalarCount += bounded.unicodeScalars.count + separatorCount
        }
        guard !retained.isEmpty else { return nil }
        return QueryInputPolicy.bounded(
            retained.joined(separator: " "),
            maximumUnicodeScalars: maximumCharacters,
            maximumUTF8Bytes: maximumCharacters * 4
        )
    }
}

class OCRService {

    static func extractText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            return try await CancellableVisionOperation.run(request: request) {
                try handler.perform([request])
                try Task.checkCancellation()
                guard let observations = request.results else { return nil }
                let candidates = observations.lazy.compactMap {
                    $0.topCandidates(1).first?.string
                }
                return OCRTextPolicy.boundedText(from: candidates)
            }
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("OCR failed: \(error.safeDiagnosticCode)")
            return nil
        }
    }

    static func extractTextFast(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()

        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            return try await CancellableVisionOperation.run(request: request) {
                try handler.perform([request])
                try Task.checkCancellation()
                guard let observations = request.results else { return nil }
                let candidates = observations.lazy.compactMap {
                    $0.topCandidates(1).first?.string
                }
                return OCRTextPolicy.boundedText(from: candidates)
            }
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("OCR (fast) failed: \(error.safeDiagnosticCode)")
            return nil
        }
    }

    static func isLikelyScreenshot(width: Int, height: Int) -> Bool {
        MemoryContentPolicy.isLikelyScreenshotDimensions(width: width, height: height)
    }
}
