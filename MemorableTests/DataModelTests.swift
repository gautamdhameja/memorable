import XCTest
import SwiftUI
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

    func testMemoryCardAspectRatioFollowsPortraitCompositionWithinLayoutBounds() {
        let portrait = memoryReference(id: "portrait", width: 3_024, height: 4_032)
        let veryTall = memoryReference(id: "very-tall", width: 1_080, height: 2_400)
        let panorama = memoryReference(id: "panorama", width: 4_000, height: 1_000)
        let landscape = memoryReference(id: "landscape", width: 4_032, height: 3_024)
        let missingDimensions = memoryReference(id: "missing", width: 0, height: -1)

        XCTAssertEqual(
            MemoryCardLayout.aspectRatio(for: portrait),
            3.0 / 4.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MemoryCardLayout.aspectRatio(for: veryTall),
            MemoryCardLayout.minimumAspectRatio,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MemoryCardLayout.aspectRatio(for: panorama),
            MemoryCardLayout.maximumAspectRatio,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MemoryCardLayout.aspectRatio(for: landscape),
            4.0 / 3.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MemoryCardLayout.aspectRatio(for: missingDimensions),
            MemoryCardLayout.fallbackAspectRatio,
            accuracy: 0.001
        )

        let defaultTarget = MemoryCardLayout.targetSize(for: portrait)
        XCTAssertEqual(defaultTarget.width, MemoryCardLayout.targetWidth, accuracy: 0.001)
        XCTAssertEqual(defaultTarget.height, 1_024 * 4.0 / 3.0, accuracy: 0.001)

        let thumbnailTarget = MemoryCardLayout.targetSize(for: landscape, width: 400)
        XCTAssertEqual(thumbnailTarget.width, 400, accuracy: 0.001)
        XCTAssertEqual(thumbnailTarget.height, 300, accuracy: 0.001)
    }

    @MainActor
    func testLoadedMemoryRowsKeepTheirMetadataBasedHeight() {
        for size in [CGSize(width: 300, height: 400), CGSize(width: 400, height: 300), CGSize(width: 800, height: 200)] {
            let reference = memoryReference(id: "layout", width: Int(size.width), height: Int(size.height))
            let ratio = MemoryCardLayout.aspectRatio(for: reference)
            let image = memoryLayoutImage(size: size)
            for width: CGFloat in [125, 190, 390] {
                let loaded = UIHostingController(rootView:
                    MemoryPhotoImage(image: image, backgroundBlurRadius: 12)
                        .aspectRatio(ratio, contentMode: .fit)
                )
                let measured = loaded.sizeThatFits(in: CGSize(width: width, height: 1_000))
                XCTAssertEqual(measured.width, width, accuracy: 0.5, "Loading \(size) must not widen a grid cell")
                XCTAssertEqual(measured.height, width / ratio, accuracy: 0.5, "Loading \(size) must not move following rows")
            }
        }
    }

    func testSearchResultTilesUseTheIndexedShapeAndClampExtremes() {
        func result(width: Int, height: Int) -> SearchResult {
            SearchResult(
                id: "\(width)x\(height)", score: 1, localIdentifier: "asset",
                creationDate: nil, isVideo: false, bestFramePosition: nil,
                pixelWidth: width, pixelHeight: height
            )
        }

        XCTAssertEqual(
            MediaTileAspectRatio.ratio(for: result(width: 3_024, height: 4_032)),
            3.0 / 4.0, accuracy: 0.001
        )
        XCTAssertEqual(
            MediaTileAspectRatio.ratio(for: result(width: 4_032, height: 3_024)),
            4.0 / 3.0, accuracy: 0.001
        )
        // A very tall photo and a panorama are clamped so one result cannot
        // take over the grid.
        XCTAssertEqual(
            MediaTileAspectRatio.ratio(for: result(width: 1_080, height: 2_400)),
            MediaTileAspectRatio.minimum, accuracy: 0.001
        )
        XCTAssertEqual(
            MediaTileAspectRatio.ratio(for: result(width: 4_000, height: 1_000)),
            MediaTileAspectRatio.maximum, accuracy: 0.001
        )
        // An index written before dimensions were recorded falls back rather
        // than producing an invalid ratio.
        XCTAssertEqual(
            MediaTileAspectRatio.ratio(for: result(width: 0, height: 0)),
            MediaTileAspectRatio.fallback, accuracy: 0.001
        )
        XCTAssertEqual(
            MediaTileAspectRatio.ratio(for: result(width: -4, height: 3)),
            MediaTileAspectRatio.fallback, accuracy: 0.001
        )
    }

    @MainActor
    func testSearchTilesReserveTheIndexedShapeBeforeTheImageLoads() {
        // A portrait result must already be taller than a landscape one while
        // both are still placeholders, and loading must not change either.
        for (width, height) in [(300, 400), (400, 300), (800, 200)] {
            let ratio = MediaTileAspectRatio.ratio(pixelWidth: width, pixelHeight: height)
            for proposedWidth: CGFloat in [125, 190, 350] {
                let proposal = CGSize(width: proposedWidth, height: 1_000)
                let placeholder = UIHostingController(rootView:
                    PhotoThumbnailView.imageContent(
                        thumbnail: nil, isVideo: false, aspectRatio: ratio
                    )
                ).sizeThatFits(in: proposal)
                XCTAssertEqual(placeholder.width, proposedWidth, accuracy: 0.5)
                XCTAssertEqual(
                    placeholder.height, proposedWidth / ratio, accuracy: 0.5,
                    "A \(width)x\(height) tile must reserve its indexed shape"
                )

                let loaded = UIHostingController(rootView:
                    PhotoThumbnailView.imageContent(
                        thumbnail: memoryLayoutImage(
                            size: CGSize(width: width, height: height)
                        ),
                        isVideo: false, aspectRatio: ratio
                    )
                ).sizeThatFits(in: proposal)
                XCTAssertEqual(loaded.width, placeholder.width, accuracy: 0.5)
                XCTAssertEqual(
                    loaded.height, placeholder.height, accuracy: 0.5,
                    "Loading must not move the rows below a \(width)x\(height) tile"
                )
            }
        }
    }

    @MainActor
    func testSearchThumbnailsKeepPlaceholderSizeWhenPhotosOrVideoFramesLoad() {
        for isVideo in [false, true] {
            for contentMode in [ContentMode.fill, .fit] {
                assertStableImageLayout { image in
                    PhotoThumbnailView.imageContent(thumbnail: image, isVideo: isVideo, contentMode: contentMode)
                }
            }
        }
    }

    @MainActor
    func testUnavailableThumbnailsKeepTheirLoadingBounds() {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for width: CGFloat in [125, 190, 350, 700] {
                for isVideo in [false, true] {
                    let proposal = CGSize(width: width, height: 1_000)
                    let loading = UIHostingController(rootView:
                        PhotoThumbnailView.imageContent(thumbnail: nil, isVideo: isVideo)
                            .environment(\.dynamicTypeSize, typeSize)
                    ).sizeThatFits(in: proposal)
                    let unavailable = UIHostingController(rootView:
                        PhotoThumbnailView.imageContent(
                            thumbnail: nil, isVideo: isVideo, isLoading: false
                        )
                        .environment(\.dynamicTypeSize, typeSize)
                    ).sizeThatFits(in: proposal)
                    XCTAssertEqual(unavailable.width, loading.width, accuracy: 0.5)
                    XCTAssertEqual(unavailable.height, loading.height, accuracy: 0.5,
                                   "An unavailable preview must not move the following results")
                }
            }
        }
    }

    @MainActor
    func testUnavailableMemoriesKeepTheirMetadataBasedHeight() {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for width: CGFloat in [125, 190, 390] {
                for ratio: CGFloat in [3.0 / 4.0, 4.0 / 3.0, 2.0] {
                    for isLoading in [true, false] {
                        let measured = UIHostingController(rootView:
                            MemoryThumbnail.imageContent(
                                thumbnail: nil, isLoading: isLoading, aspectRatio: ratio
                            )
                            .environment(\.dynamicTypeSize, typeSize)
                        ).sizeThatFits(in: CGSize(width: width, height: 1_000))
                        XCTAssertEqual(measured.width, width, accuracy: 0.5)
                        XCTAssertEqual(measured.height, width / ratio, accuracy: 0.5)
                    }
                }
            }
        }
    }

    @MainActor
    func testUnavailableViewerKeepsTheFullScreenCanvas() {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for size in [CGSize(width: 320, height: 568), CGSize(width: 852, height: 393)] {
                for isLoading in [true, false] {
                    let measured = UIHostingController(rootView:
                        ZoomableAsyncImage.unloadedContent(isLoading: isLoading, retry: {})
                            .frame(width: size.width, height: size.height)
                            .environment(\.dynamicTypeSize, typeSize)
                    ).sizeThatFits(in: size)
                    XCTAssertEqual(measured.width, size.width, accuracy: 0.5)
                    XCTAssertEqual(measured.height, size.height, accuracy: 0.5)
                }
            }
        }
    }

    @MainActor
    func testVisualSearchThumbnailsFillTheirTilesWithoutEmptyBands() throws {
        for size in [CGSize(width: 300, height: 400), CGSize(width: 800, height: 200)] {
            let renderer = ImageRenderer(content:
                PhotoThumbnailView.imageContent(thumbnail: memoryLayoutImage(size: size), isVideo: false)
                    .frame(width: 120, height: 90)
            )
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: 120 * 90 * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(
                    data: bytes.baseAddress, width: 120, height: 90,
                    bitsPerComponent: 8, bytesPerRow: 120 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 90))
            }
            // Sample inside each edge, away from the rounded corners.
            for (x, y) in [(6, 45), (114, 45), (60, 6), (60, 84), (60, 45)] {
                let offset = (y * 120 + x) * 4
                XCTAssertGreaterThan(pixels[offset + 2], 240, "Photo \(size) must fill edge (\(x), \(y))")
                XCTAssertLessThan(pixels[offset], 15)
                XCTAssertLessThan(pixels[offset + 1], 15)
            }
        }
    }

    @MainActor
    func testIndexingSlideshowKeepsItsSizeAcrossPhotoChanges() {
        assertStableImageLayout { image in
            IndexingSlideshowView.imageContent(
                currentImage: image, currentDate: Date(timeIntervalSince1970: 0),
                isVisible: true, dateVisible: true
            )
        }
    }

    @MainActor
    func testDuplicateThumbnailsKeepPlaceholderSizeWhenPhotosLoad() {
        assertStableImageLayout { image in
            DuplicatePairRow.thumbnailView(image: image, label: "LEFT", alignment: .topLeading)
        }
    }

    @MainActor
    func testHomeMemoryBackdropCannotWidenTheCardWhenPhotosLoad() {
        assertStableImageLayout { image in
            SearchHomePhotoImage.imageContent(image: image, fillsBackdrop: true, bounds: nil, contentMode: .fit)
                .frame(height: 156)
        }
    }

    @MainActor
    private func assertStableImageLayout<Content: View>(
        file: StaticString = #filePath, line: UInt = #line,
        @ViewBuilder content: (UIImage?) -> Content
    ) {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            for width: CGFloat in [125, 190, 350, 700] {
                let proposal = CGSize(width: width, height: 1_000)
                let placeholder = UIHostingController(
                    rootView: content(nil).environment(\.dynamicTypeSize, typeSize)
                ).sizeThatFits(in: proposal)
                for size in [CGSize(width: 300, height: 400), CGSize(width: 400, height: 300),
                             CGSize(width: 800, height: 200), CGSize(width: 200, height: 800)] {
                    let loaded = UIHostingController(
                        rootView: content(memoryLayoutImage(size: size)).environment(\.dynamicTypeSize, typeSize)
                    ).sizeThatFits(in: proposal)
                    XCTAssertEqual(loaded.width, placeholder.width, accuracy: 0.5,
                                   "Loading \(size) must not widen a \(width)-point container", file: file, line: line)
                    XCTAssertEqual(loaded.height, placeholder.height, accuracy: 0.5,
                                   "Loading \(size) must not move following rows", file: file, line: line)
                }
            }
        }
    }

    @MainActor
    private func memoryLayoutImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testMemoryContentPolicyRejectsScreenshotsAndDocumentImages() {
        XCTAssertFalse(MemoryContentPolicy.isEligible(
            isMarkedScreenshot: true,
            pixelWidth: 900,
            pixelHeight: 1_200,
            ocrText: nil,
            sceneLabels: nil
        ))
        XCTAssertFalse(MemoryContentPolicy.isEligible(
            isMarkedScreenshot: false,
            pixelWidth: 1_170,
            pixelHeight: 2_532,
            ocrText: nil,
            sceneLabels: nil
        ))
        XCTAssertFalse(MemoryContentPolicy.isEligible(
            isMarkedScreenshot: false,
            pixelWidth: 1_200,
            pixelHeight: 1_600,
            ocrText: Array(repeating: "document text", count: 20).joined(separator: " "),
            sceneLabels: "document,text"
        ))
        XCTAssertTrue(MemoryContentPolicy.isEligible(
            isMarkedScreenshot: false,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            ocrText: "Trail summit",
            sceneLabels: "mountain,outdoor"
        ))
    }

    func testMemoryDuplicateFilterKeepsOneRepresentativePerNearDuplicateGroup() {
        var first = [Float](repeating: 0, count: EmbeddingConfig.dimensions)
        first[0] = 1
        var distinct = [Float](repeating: 0, count: EmbeddingConfig.dimensions)
        distinct[1] = 1
        var filter = MemoryDuplicateFilter()

        XCTAssertTrue(filter.accepts(first.toFloat16Data()))
        XCTAssertFalse(filter.accepts(first.toFloat16Data()))
        XCTAssertTrue(filter.accepts(distinct.toFloat16Data()))
        XCTAssertEqual(filter.retainedCount, 2)
    }

    private func memoryReference(id: String, width: Int, height: Int) -> IndexedPhotoReference {
        IndexedPhotoReference(
            id: id,
            localIdentifier: id,
            creationDate: nil,
            sourceId: PhotoSourceType.photokit.rawValue,
            filePath: nil,
            pixelWidth: width,
            pixelHeight: height
        )
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
