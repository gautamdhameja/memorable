import XCTest
@testable import Memorable

final class DataModelTests: XCTestCase {

    // MARK: - SearchResult

    func testSearchResultEquality() {
        let a = SearchResult(id: "1", score: 0.5, localIdentifier: "abc", creationDate: nil, isVideo: false, bestFramePosition: nil)
        let b = SearchResult(id: "1", score: 0.5, localIdentifier: "abc", creationDate: nil, isVideo: false, bestFramePosition: nil)
        XCTAssertEqual(a, b)
    }

    func testSearchResultInequality() {
        let a = SearchResult(id: "1", score: 0.5, localIdentifier: "abc", creationDate: nil, isVideo: false, bestFramePosition: nil)
        let b = SearchResult(id: "2", score: 0.8, localIdentifier: "def", creationDate: nil, isVideo: false, bestFramePosition: nil)
        XCTAssertNotEqual(a, b)
    }

    func testSearchResultWithDate() {
        let date = Date()
        let r = SearchResult(id: "1", score: 0.3, localIdentifier: "abc", creationDate: date, isVideo: false, bestFramePosition: nil)
        XCTAssertEqual(r.creationDate, date)
    }

    func testSearchResultVideo() {
        let r = SearchResult(id: "v1", score: 0.4, localIdentifier: "vid", creationDate: nil, isVideo: true, bestFramePosition: 0.5)
        XCTAssertFalse(r.supportsFindSimilar)
        XCTAssertTrue(r.isVideo)
        XCTAssertEqual(r.bestFramePosition, 0.5)
    }

    func testIndexedFolderPhotoPreservesItsValidatedLoadingReference() {
        let photo = IndexedPhoto(
            id: "photo-id",
            localIdentifier: "folder-local-id",
            creationDate: Date(timeIntervalSince1970: 10),
            latitude: nil,
            longitude: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            embedding: Data(),
            indexedAt: Date(timeIntervalSince1970: 20),
            sourceId: "folder-source",
            filePath: "/selected/photo.jpg"
        )

        XCTAssertEqual(photo.searchResult.id, photo.id)
        XCTAssertEqual(photo.searchResult.sourceId, "folder-source")
        XCTAssertEqual(photo.searchResult.filePath, "/selected/photo.jpg")
        XCTAssertFalse(photo.searchResult.isVideo)
    }

    func testOnThisDayMemoryLimitsAreBounded() {
        XCTAssertGreaterThan(MemoryConfig.maximumOnThisDayYears, 0)
        XCTAssertLessThanOrEqual(MemoryConfig.maximumOnThisDayYears, 100)
        XCTAssertGreaterThan(MemoryConfig.maximumOnThisDayPhotosPerYear, 0)
        XCTAssertLessThanOrEqual(MemoryConfig.maximumOnThisDayPhotosPerYear, 500)
    }

    // MARK: - EmbeddingConfig

    func testEmbeddingDimensions() {
        XCTAssertEqual(EmbeddingConfig.dimensions, 768)
    }

    func testBytesPerEmbedding() {
        XCTAssertEqual(EmbeddingConfig.bytesPerEmbedding, 768 * MemoryLayout<Float16>.size)
        XCTAssertEqual(EmbeddingConfig.bytesPerEmbedding, 1536)
    }

    // MARK: - PhotoSourceType

    func testPhotoSourceTypeRawValues() {
        XCTAssertEqual(PhotoSourceType.photokit.rawValue, "photokit")
        XCTAssertEqual(PhotoSourceType.folder.rawValue, "folder")
    }

    // MARK: - Float16 Conversion

    func testToFloat16DataByteCount() {
        let floats: [Float] = [0.1, 0.2, 0.3]
        let data = floats.toFloat16Data()
        XCTAssertEqual(data.count, floats.count * MemoryLayout<Float16>.size)
    }

    func testFloat16RoundTrip() {
        let original: [Float] = [1.0, -0.5, 0.0, 0.75]
        let data = original.toFloat16Data()
        let recovered = data.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: Float16.self)
            return (0..<original.count).map { Float(ptr[$0]) }
        }
        for (a, b) in zip(original, recovered) {
            XCTAssertEqual(a, b, accuracy: 0.01)
        }
    }

    func testFloat16RoundTripNegativeValues() {
        let original: [Float] = [-1.0, -0.25, -100.0]
        let data = original.toFloat16Data()
        let recovered = data.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: Float16.self)
            return (0..<original.count).map { Float(ptr[$0]) }
        }
        for (a, b) in zip(original, recovered) {
            XCTAssertEqual(a, b, accuracy: 1.0, "Large negatives lose precision in Float16")
        }
    }

    func testFloat16RoundTripZero() {
        let original: [Float] = [0.0]
        let data = original.toFloat16Data()
        let recovered = data.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: Float16.self)
            return [Float(ptr[0])]
        }
        XCTAssertEqual(recovered[0], 0.0)
    }

    func testFloat16EmptyArray() {
        let empty: [Float] = []
        let data = empty.toFloat16Data()
        XCTAssertEqual(data.count, 0)
    }

    func testFloat16PrecisionLoss() {
        // Float16 has ~3.3 decimal digits of precision
        let original: [Float] = [0.123456789]
        let data = original.toFloat16Data()
        let recovered = data.withUnsafeBytes { buf -> [Float] in
            let ptr = buf.bindMemory(to: Float16.self)
            return [Float(ptr[0])]
        }
        // Should be close but not exact
        XCTAssertEqual(recovered[0], original[0], accuracy: 0.001)
        // But not perfectly equal
        XCTAssertNotEqual(recovered[0], original[0])
    }

    func testValidatedEmbeddingRejectsMalformedDatabaseBlob() {
        XCTAssertNil(Data(repeating: 0, count: EmbeddingConfig.bytesPerEmbedding - 1)
            .validatedFloat16Embedding())
        XCTAssertNil(Data(repeating: 0, count: EmbeddingConfig.bytesPerEmbedding + 1)
            .validatedFloat16Embedding())
    }

    func testValidatedEmbeddingDecodesUnalignedBytes() {
        let vector = (0..<EmbeddingConfig.dimensions).map { Float($0) / 100 }
        let decoded = vector.toFloat16Data().validatedFloat16Embedding()

        XCTAssertEqual(decoded?.count, EmbeddingConfig.dimensions)
        XCTAssertEqual(Float(decoded?[17] ?? 0), vector[17], accuracy: 0.001)
    }

    func testValidatedEmbeddingRejectsNonFiniteAndZeroVectors() {
        var nonFinite = [Float](repeating: 1, count: EmbeddingConfig.dimensions)
        nonFinite[17] = .nan

        XCTAssertNil(nonFinite.toFloat16Data().validatedFloat16Embedding())
        XCTAssertNil(
            [Float](repeating: 0, count: EmbeddingConfig.dimensions)
                .toFloat16Data()
                .validatedFloat16Embedding()
        )
    }

    // MARK: - IndexingProgress

    func testProgressPercentage() {
        let progress = IndexingProgress(total: 100, completed: 50, isRunning: true)
        XCTAssertEqual(progress.percentage, 50.0)
    }

    func testProgressPercentageZeroTotal() {
        let progress = IndexingProgress(total: 0, completed: 0, isRunning: false)
        XCTAssertEqual(progress.percentage, 0)
    }

    func testProgressPercentageFull() {
        let progress = IndexingProgress(total: 200, completed: 200, isRunning: false)
        XCTAssertEqual(progress.percentage, 100.0)
    }

    func testProgressPercentageZeroCompleted() {
        let progress = IndexingProgress(total: 100, completed: 0, isRunning: true)
        XCTAssertEqual(progress.percentage, 0.0)
    }

    func testProgressPercentageDecimal() {
        let progress = IndexingProgress(total: 3, completed: 1, isRunning: true)
        XCTAssertEqual(progress.percentage, 100.0 / 3.0, accuracy: 0.01)
    }

    func testProgressDefaultPhase() {
        let progress = IndexingProgress(total: 10, completed: 5, isRunning: true)
        XCTAssertEqual(progress.phase, .idle)
        XCTAssertFalse(progress.photosComplete)
    }

    // MARK: - SearchResponse

    func testSearchResponseWithResults() {
        let results = [
            SearchResult(id: "1", score: 0.25, localIdentifier: "a", creationDate: nil, isVideo: false, bestFramePosition: nil),
            SearchResult(id: "2", score: 0.20, localIdentifier: "b", creationDate: nil, isVideo: false, bestFramePosition: nil),
        ]
        let response = SearchResponse(results: results, fallbackResults: [], filtersApplied: nil)
        XCTAssertEqual(response.results.count, 2)
        XCTAssertTrue(response.fallbackResults.isEmpty)
        XCTAssertNil(response.filtersApplied)
    }

    func testSearchResponseEmptyWithFallback() {
        let fallback = [
            SearchResult(id: "1", score: 0.11, localIdentifier: "a", creationDate: nil, isVideo: false, bestFramePosition: nil),
        ]
        let summary = FilterSummary(dateDescription: nil, locationDescription: nil, visualQuery: "selfie")
        let response = SearchResponse(results: [], fallbackResults: fallback, filtersApplied: summary)
        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.count, 1)
        XCTAssertEqual(response.filtersApplied?.visualQuery, "selfie")
    }

    func testSearchResponseFallbackScoresBelowThreshold() {
        // Fallback results should contain near-miss scores below the threshold
        let threshold = SearchConfig.minimumScoreThreshold
        let fallback = [
            SearchResult(id: "1", score: threshold - 0.01, localIdentifier: "a", creationDate: nil, isVideo: false, bestFramePosition: nil),
            SearchResult(id: "2", score: threshold - 0.02, localIdentifier: "b", creationDate: nil, isVideo: false, bestFramePosition: nil),
        ]
        let response = SearchResponse(results: [], fallbackResults: fallback, filtersApplied: nil)
        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.fallbackResults.count, 2)
        for result in response.fallbackResults {
            XCTAssertLessThan(result.score, threshold)
        }
    }

    func testFilterSummaryWithAllFields() {
        let summary = FilterSummary(
            dateDescription: "Last summer",
            locationDescription: "Berlin",
            visualQuery: "sunset"
        )
        XCTAssertEqual(summary.dateDescription, "Last summer")
        XCTAssertEqual(summary.locationDescription, "Berlin")
        XCTAssertEqual(summary.visualQuery, "sunset")
    }

    func testFilterSummaryVisualQueryOnly() {
        let summary = FilterSummary(
            dateDescription: nil,
            locationDescription: nil,
            visualQuery: "dog eating carrot"
        )
        XCTAssertNil(summary.dateDescription)
        XCTAssertNil(summary.locationDescription)
        XCTAssertEqual(summary.visualQuery, "dog eating carrot")
    }

    func testSearchResultVideoWithFrame() {
        let r = SearchResult(id: "v1", score: 0.15, localIdentifier: "vid", creationDate: nil, isVideo: true, bestFramePosition: 0.3)
        XCTAssertTrue(r.isVideo)
        XCTAssertEqual(r.bestFramePosition, 0.3)
        XCTAssertEqual(r.score, 0.15, accuracy: 0.001)
    }

    func testSearchResultMixedTypes() {
        let photo = SearchResult(id: "p1", score: 0.20, localIdentifier: "a", creationDate: nil, isVideo: false, bestFramePosition: nil)
        let video = SearchResult(id: "v1", score: 0.18, localIdentifier: "b", creationDate: nil, isVideo: true, bestFramePosition: 0.5)
        XCTAssertFalse(photo.isVideo)
        XCTAssertTrue(video.isVideo)
        XCTAssertGreaterThan(photo.score, video.score)
    }
}
