import Vision
import UIKit

class OCRService {

    static func extractText(from image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        var recognizedText = ""

        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                if let topCandidate = observation.topCandidates(1).first {
                    recognizedText += topCandidate.string + " "
                }
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.error("OCR failed: \(error.localizedDescription)")
            return nil
        }

        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func extractTextFast(from image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }

        var recognizedText = ""

        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                if let topCandidate = observation.topCandidates(1).first {
                    recognizedText += topCandidate.string + " "
                }
            }
        }

        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            #if DEBUG
            logger.error("OCR (fast) failed: \(error.localizedDescription)")
            #endif
            return nil
        }

        let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isLikelyScreenshot(width: Int, height: Int) -> Bool {
        let screenSizes: Set<String> = [
            "1170x2532", "2532x1170",
            "1179x2556", "2556x1179",
            "1290x2796", "2796x1290",
            "1284x2778", "2778x1284",
            "1125x2436", "2436x1125",
            "1242x2688", "2688x1242",
            "1080x1920", "1920x1080",
            "750x1334", "1334x750",
            "1668x2388", "2388x1668",
            "2048x2732", "2732x2048",
        ]
        return screenSizes.contains("\(width)x\(height)")
    }
}
