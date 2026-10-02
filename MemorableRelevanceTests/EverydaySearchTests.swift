import GRDB
import UIKit
import XCTest
@testable import Memorable

final class EverydaySearchTests: XCTestCase {
    struct Query: Decodable {
        let text: String
        let relevantIDs: [String]
        let requiredTextIDs: [String]
        let expectsNoMainResults: Bool
        let allowsFallback: Bool
    }

    func testEverydayQueriesWithRealModelsAndOCR() async throws {
        let bundle = Bundle(for: Self.self)
        let manifest = try RelevanceFixtureLoader.loadManifest(bundle: bundle)
        let queriesURL = try XCTUnwrap(bundle.url(forResource: "everyday-queries", withExtension: "json"))
        let queries = try JSONDecoder().decode([Query].self, from: Data(contentsOf: queriesURL))
        XCTAssertEqual(queries.count, 12)
        XCTAssertEqual(Set(queries.filter(\.allowsFallback).map(\.text)), ["dog", "black cat"])
        let database = AppDatabase(openQueue: { try DatabaseQueue() },
                                   migrate: { try AppDatabase.migrator.migrate($0) })
        let imageEncoder = try await ImageEncoder()
        let textEncoder = try await TextEncoder()
        for entry in manifest.entries {
            let image = try RelevanceFixtureLoader.loadImage(for: entry)
            try await insert(image, id: entry.expectedAssetIds[0], encoder: imageEncoder, database: database)
        }
        for id in ["clinic-sign", "appointment-card", "landscape-worksheet", "alpine-river"] {
            let url = RelevanceFixtureLoader.repositoryRoot
                .appendingPathComponent("MemorableRelevanceTests/Fixtures/text-search/\(id).png")
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            try await insert(image, id: id, encoder: imageEncoder, database: database)
        }
        try await insert(bookingScreenshot(), id: "booking-screenshot", encoder: imageEncoder,
                         database: database, isScreenshot: true)
        let engine = SearchEngine(textEncoder: textEncoder, database: database)
        try engine.loadIndex()
        var report: [String] = []
        for query in queries {
            // Deterministic parsing isolates retrieval from device-dependent Foundation Models.
            let response = try await engine.search(query: query.text)
            let main = response.results
            let firstRank = main.firstIndex { query.relevantIDs.contains($0.id) }.map { $0 + 1 }
            let fallbackRank = response.fallbackResults.firstIndex { query.relevantIDs.contains($0.id) }.map { $0 + 1 }
            let precision = main.prefix(5).filter { query.relevantIDs.contains($0.id) }.count
            print("RELEVANCE everyday query=\(query.text) main_rank=\(firstRank ?? 0) fallback_rank=\(fallbackRank ?? 0) relevant_top5=\(precision) main_count=\(main.count)")
            let candidates = main.isEmpty ? response.fallbackResults : main
            report.append("\(query.text) [\(main.isEmpty ? "optional" : "main")]: " + candidates.prefix(5).map { "\($0.id)=\($0.score)" }.joined(separator: ", "))
            if query.expectsNoMainResults {
                XCTAssertTrue(main.isEmpty, "Unexpected main results for \(query.text): \(main.map(\.id))")
            } else if query.allowsFallback, firstRank == nil {
                // Explicit known misses: do not count these as main-result recall.
                XCTAssertLessThanOrEqual(fallbackRank ?? .max, 5, query.text)
            } else {
                XCTAssertNotNil(firstRank, "No main result for \(query.text); fallback rank \(fallbackRank ?? 0)")
                XCTAssertLessThanOrEqual(firstRank ?? .max, 5, query.text)
            }
            let textIDs = Set(main.filter(\.isTextMatch).map(\.id))
            XCTAssertTrue(Set(query.requiredTextIDs).isSubset(of: textIDs), query.text)
            XCTAssertEqual(Set(main.map(\.id)).count, main.count)
        }
        try report.joined(separator: "\n").write(
            to: RelevanceFixtureLoader.repositoryRoot.appendingPathComponent(".relevance-cache/everyday-search-report.txt"),
            atomically: true, encoding: .utf8
        )
    }

    private func insert(_ image: UIImage, id: String, encoder: ImageEncoder, database: AppDatabase,
                        isScreenshot: Bool = false) async throws {
        let embedding = try await encoder.encodeCancellable(image: image)
        let recognizedText = if isScreenshot {
            await OCRService.extractText(from: image)
        } else {
            await OCRService.extractTextFast(from: image)
        }
        try database.insertPhoto(IndexedPhoto(
            id: id, localIdentifier: id, creationDate: nil, latitude: nil, longitude: nil,
            pixelWidth: Int(image.size.width), pixelHeight: Int(image.size.height),
            embedding: embedding.toFloat16Data(), indexedAt: Date(),
            ocrText: recognizedText, isScreenshot: isScreenshot
        ))
    }

    private func bookingScreenshot() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            for (line, y, size) in [("Booking confirmed", 100.0, 28.0), ("Aster Hotel", 190.0, 24.0),
                                    ("Reservation 482913", 240.0, 22.0), ("Check-in: 12 September", 320.0, 20.0)] {
                (line as NSString).draw(at: CGPoint(x: 24, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black,
                ])
            }
        }
    }
}
