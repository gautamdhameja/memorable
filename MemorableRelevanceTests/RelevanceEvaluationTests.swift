import XCTest
@testable import Memorable

final class RelevanceEvaluationTests: XCTestCase {
    private var fixtureBundle: Bundle { Bundle(for: Self.self) }

    func testRealModelRankingMatchesSimulatorBaseline() throws {
        let manifest = try RelevanceFixtureLoader.loadManifest(bundle: fixtureBundle)
        let perturbationValue = ProcessInfo.processInfo.environment["MEMORABLE_RELEVANCE_PERTURBATION"]
        let perturbation = perturbationValue?.isEmpty == false ? perturbationValue : nil
        let imageEncoder = try ImageEncoder()
        let embeddings = try manifest.entries.map { entry -> [Float16] in
            let image = try RelevanceFixtureLoader.loadImage(for: entry, perturbation: perturbation)
            return try imageEncoder.encode(image: image).map(Float16.init)
        }
        let textEncoder = try TextEncoder()
        let database = RelevanceFixtureDatabase(manifest: manifest, embeddings: embeddings)
        let engine = SearchEngine(textEncoder: textEncoder, database: database)
        try engine.loadIndex()

        let metrics = try evaluate(manifest: manifest, engine: engine)
        report(metrics, perturbation: perturbation)

        let skipBaseline = ProcessInfo.processInfo.environment["MEMORABLE_RELEVANCE_SKIP_BASELINE"] == "1"
        if skipBaseline { return }

        let baseline = try RelevanceFixtureLoader.loadBaseline(bundle: fixtureBundle)
        try assertBaseline(baseline, metrics: metrics, manifest: manifest)
    }

    func testMissingCacheImageFailsWithPreparationCommand() throws {
        let manifest = try RelevanceFixtureLoader.loadManifest(bundle: fixtureBundle)
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(
            try RelevanceFixtureLoader.loadImage(for: manifest.entries[0], imagesRoot: missingRoot)
        ) { error in
            XCTAssertEqual(error as? RelevanceFixtureError, .missingImage(manifest.entries[0].localFilename))
            XCTAssertTrue(error.localizedDescription.contains("scripts/relevance.py run"))
        }
    }

    func testCorruptCacheImageFailsSHA256Validation() throws {
        let manifest = try RelevanceFixtureLoader.loadManifest(bundle: fixtureBundle)
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        let entry = manifest.entries[0]
        try Data("not the expected image".utf8).write(to: temporaryRoot.appendingPathComponent(entry.localFilename))

        XCTAssertThrowsError(
            try RelevanceFixtureLoader.loadImage(for: entry, imagesRoot: temporaryRoot)
        ) { error in
            guard case .imageHashMismatch(let filename, let expected, let actual) = error as? RelevanceFixtureError else {
                return XCTFail("Expected imageHashMismatch, got \(error)")
            }
            XCTAssertEqual(filename, entry.localFilename)
            XCTAssertEqual(expected, entry.imageSha256)
            XCTAssertNotEqual(actual, expected)
        }
    }

    private func evaluate(manifest: RelevanceManifest, engine: SearchEngine) throws -> RelevanceMetrics {
        let queryMetrics = try manifest.entries.map { entry -> RelevanceQueryMetrics in
            let response = try engine.hybridSearch(hints: QueryHints(
                textQuery: entry.query,
                dateRange: nil,
                locationHint: nil,
                locationCoordinate: nil,
                locationRadiusKm: nil,
                locationLocality: nil,
                locationSubAdmin: nil,
                locationAdminArea: nil,
                locationCountryName: nil,
                seasonHint: nil,
                negativeTerms: [],
                timeOfDayHours: nil,
                hasVisualQuery: true
            ))
            let usedFallback = response.results.isEmpty && !response.fallbackResults.isEmpty
            let rankedIds = (usedFallback ? response.fallbackResults : response.results).map(\.id)
            let expected = Set(entry.expectedAssetIds)
            let firstRank = rankedIds.firstIndex(where: expected.contains).map { $0 + 1 }
            return RelevanceQueryMetrics(
                questionId: entry.questionId,
                recallAt10: firstRank.map { $0 <= 10 ? 1 : 0 } ?? 0,
                recallAt50: firstRank.map { $0 <= 50 ? 1 : 0 } ?? 0,
                reciprocalRank: firstRank.map { 1.0 / Double($0) } ?? 0,
                usedFallback: usedFallback
            )
        }
        return RelevanceMetrics(queries: queryMetrics)
    }

    private func assertBaseline(
        _ baseline: RelevanceBaseline,
        metrics: RelevanceMetrics,
        manifest: RelevanceManifest
    ) throws {
        XCTAssertEqual(baseline.schemaVersion, 1)
        XCTAssertEqual(baseline.environment, "iOS Simulator, cpuOnly")
        XCTAssertEqual(baseline.datasetRevision, manifest.dataset.revision)
        XCTAssertEqual(baseline.queries.count, manifest.entries.count)

        let actualByQuestionId = Dictionary(uniqueKeysWithValues: metrics.queries.map { ($0.questionId, $0) })
        for expected in baseline.queries {
            let actual = try XCTUnwrap(actualByQuestionId[expected.questionId])
            assertNoRegression(actual.recallAt10, expected.recallAt10, baseline.tolerance, "recall@10", expected.questionId)
            assertNoRegression(actual.recallAt50, expected.recallAt50, baseline.tolerance, "recall@50", expected.questionId)
            assertNoRegression(actual.reciprocalRank, expected.reciprocalRank, baseline.tolerance, "reciprocal rank", expected.questionId)
        }

        assertNoRegression(metrics.recallAt10, baseline.aggregate.recallAt10, baseline.tolerance, "aggregate recall@10", "all")
        assertNoRegression(metrics.recallAt50, baseline.aggregate.recallAt50, baseline.tolerance, "aggregate recall@50", "all")
        assertNoRegression(metrics.meanReciprocalRank, baseline.aggregate.meanReciprocalRank, baseline.tolerance, "aggregate MRR", "all")
        XCTAssertLessThanOrEqual(
            metrics.fallbackQueryRate,
            baseline.aggregate.fallbackQueryRate + baseline.tolerance,
            "Relevance regression for all: fallback query rate baseline=\(format(baseline.aggregate.fallbackQueryRate)), actual=\(format(metrics.fallbackQueryRate)), tolerance=\(format(baseline.tolerance))"
        )
    }

    private func assertNoRegression(
        _ actual: Double,
        _ baseline: Double,
        _ tolerance: Double,
        _ metric: String,
        _ query: String
    ) {
        XCTAssertGreaterThanOrEqual(
            actual + tolerance,
            baseline,
            "Relevance regression for \(query): \(metric) baseline=\(format(baseline)), actual=\(format(actual)), tolerance=\(format(tolerance))"
        )
    }

    private func report(_ metrics: RelevanceMetrics, perturbation: String?) {
        print("RELEVANCE mode=\(perturbation ?? "baseline") queries=\(metrics.queries.count)")
        for metric in metrics.queries {
            print(
                "RELEVANCE query=\(metric.questionId) "
                + "recall@10=\(format(metric.recallAt10)) "
                + "recall@50=\(format(metric.recallAt50)) "
                + "reciprocal_rank=\(format(metric.reciprocalRank))"
            )
        }
        print(
            "RELEVANCE aggregate "
            + "recall@10=\(format(metrics.recallAt10)) "
            + "recall@50=\(format(metrics.recallAt50)) "
            + "MRR=\(format(metrics.meanReciprocalRank)) "
            + "fallback_rate=\(format(metrics.fallbackQueryRate))"
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
