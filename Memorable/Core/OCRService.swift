import Vision
import UIKit
import CoreML

/// Sendable invariant: the requests and operation are immutable and owned by one
/// detached task; cancellation only invokes Vision's thread-safe `cancel()` API.
private final class VisionWorkBox<Value: Sendable>: @unchecked Sendable {
    let requests: [VNRequest]
    let operation: () throws -> Value

    init(requests: [VNRequest], operation: @escaping () throws -> Value) {
        self.requests = requests
        self.operation = operation
    }
}

enum CancellableVisionOperation {
    static func run<Value: Sendable>(
        request: VNRequest,
        operation: @escaping () throws -> Value
    ) async throws -> Value {
        try await run(requests: [request], operation: operation)
    }

    static func run<Value: Sendable>(
        requests: [VNRequest],
        operation: @escaping () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let box = VisionWorkBox(requests: requests, operation: operation)
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            do {
                let value = try box.operation()
                try Task.checkCancellation()
                return value
            } catch {
                // Vision may report its own cancellation error after cancel().
                try Task.checkCancellation()
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
            for request in box.requests {
                request.cancel()
            }
        }
    }
}

enum VisionRequestExecution {
    static func configure(_ request: VNRequest) throws {
        request.preferBackgroundProcessing = true
        #if targetEnvironment(simulator)
        // The simulator cannot execute Vision's Neural Engine/GPU workloads.
        for (stage, devices) in try request.supportedComputeStageDevices {
            guard let cpu = devices.first(where: {
                if case .cpu = $0 { return true }
                return false
            }) else {
                throw ConfigurationError.cpuUnavailable
            }
            request.setComputeDevice(cpu, for: stage)
        }
        #endif
    }

    static func perform(_ requests: [VNRequest], using handler: VNImageRequestHandler) throws {
        try Task.checkCancellation()
        do {
            for request in requests {
                try configure(request)
            }
            try handler.perform(requests)
        } catch {
            try Task.checkCancellation()
            guard requests.count > 1 else { throw error }
            logger.error("Grouped photo analysis failed: \(error.safeDiagnosticCode)")
            // A failed request can prevent its siblings from running. Retry only
            // missing results; an empty array is a successful analysis of no matches.
            for request in requests where request.results == nil {
                try Task.checkCancellation()
                do {
                    try configure(request)
                    try handler.perform([request])
                } catch {
                    try Task.checkCancellation()
                    logger.error("Photo analysis request failed: \(error.safeDiagnosticCode)")
                }
            }
        }
        try Task.checkCancellation()
    }

    private enum ConfigurationError: Error {
        case cpuUnavailable
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

struct PhotoVisionAnalysis: Sendable, Equatable {
    let ocrText: String?
    let sceneLabels: [String]
}

class OCRService {

    /// Shares Vision's image preparation between OCR and scene classification.
    /// Callers that already obtained accurate OCR can skip thumbnail OCR.
    static func analyzePhoto(
        _ image: UIImage,
        recognizeText: Bool = true
    ) async -> PhotoVisionAnalysis {
        let empty = PhotoVisionAnalysis(ocrText: nil, sceneLabels: [])
        guard let cgImage = image.cgImage else { return empty }
        let classification = VNClassifyImageRequest()
        let textRecognition = recognizeText ? VNRecognizeTextRequest() : nil
        textRecognition?.recognitionLevel = .fast
        textRecognition?.usesLanguageCorrection = false

        var requests: [VNRequest] = [classification]
        if let textRecognition {
            requests.append(textRecognition)
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            return try await CancellableVisionOperation.run(requests: requests) {
                try VisionRequestExecution.perform(requests, using: handler)
                try Task.checkCancellation()
                return PhotoVisionAnalysis(
                    ocrText: OCRTextPolicy.boundedText(from:
                        (textRecognition?.results ?? []).lazy.compactMap {
                            $0.topCandidates(1).first?.string
                        }
                    ),
                    sceneLabels: SceneClassifier.labels(from: classification.results ?? [])
                )
            }
        } catch is CancellationError {
            return empty
        } catch {
            logger.error("Photo analysis failed: \(error.safeDiagnosticCode)")
            return empty
        }
    }

    static func extractText(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNRecognizeTextRequest()

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            return try await CancellableVisionOperation.run(request: request) {
                try VisionRequestExecution.perform([request], using: handler)
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
                try VisionRequestExecution.perform([request], using: handler)
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
