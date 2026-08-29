import Vision
import UIKit

class SceneClassifier {

    static func classify(image: UIImage, maxLabels: Int = 5,
                         minConfidence: Float = 0.3) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            return try await CancellableVisionOperation.run(request: request) {
                try handler.perform([request])
                try Task.checkCancellation()
                guard let observations = request.results else { return [] }
                return observations
                    .filter { $0.confidence >= minConfidence }
                    .prefix(maxLabels)
                    .map { $0.identifier.lowercased().replacingOccurrences(of: "_", with: " ") }
            }
        } catch is CancellationError {
            return []
        } catch {
            logger.error("[SceneClassifier] Failed: \(error.safeDiagnosticCode)")
            return []
        }
    }

    static func labelsToString(_ labels: [String]) -> String? {
        labels.isEmpty ? nil : labels.joined(separator: ",")
    }

    static func stringToLabels(_ string: String?) -> [String] {
        guard let string, !string.isEmpty else { return [] }
        return string.components(separatedBy: ",")
    }
}
