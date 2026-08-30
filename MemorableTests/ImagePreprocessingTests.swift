import XCTest
import UIKit
@preconcurrency import Photos
import ImageIO
import Darwin
import os
@testable import Memorable

final class ImagePreprocessingTests: XCTestCase {
    func testThumbnailSizeRejectsInvalidDimensions() {
        XCTAssertNil(PhotoThumbnailSizePolicy.targetSize(
            pixelWidth: 0,
            pixelHeight: 100,
            maxDimension: 400
        ))
        XCTAssertNil(PhotoThumbnailSizePolicy.targetSize(
            pixelWidth: 100,
            pixelHeight: 0,
            maxDimension: 400
        ))
        XCTAssertNil(PhotoThumbnailSizePolicy.targetSize(
            pixelWidth: 100,
            pixelHeight: 100,
            maxDimension: .nan
        ))
        XCTAssertNil(PhotoThumbnailSizePolicy.targetSize(
            pixelWidth: 100,
            pixelHeight: 100,
            maxDimension: .infinity
        ))
    }

    func testThumbnailSizePreservesAspectRatio() throws {
        let size = try XCTUnwrap(PhotoThumbnailSizePolicy.targetSize(
            pixelWidth: 4_000,
            pixelHeight: 2_000,
            maxDimension: 400
        ))

        XCTAssertEqual(size.width, 400)
        XCTAssertEqual(size.height, 200)
    }

    func testOCRTextPolicyBoundsDenseTextLinearly() {
        let fragments = (0..<1_000).map { _ in String(repeating: "x", count: 100) }

        let text = OCRTextPolicy.boundedText(from: fragments)

        XCTAssertNotNil(text)
        XCTAssertLessThanOrEqual(text?.count ?? 0, OCRTextPolicy.maximumCharacters)
        XCTAssertLessThanOrEqual(text?.split(separator: " ").count ?? 0, OCRTextPolicy.maximumObservations)
    }

    func testFolderScanStopsAtConfiguredBoundAndSortsRetainedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<8 {
            let file = root.appendingPathComponent(String(format: "%02d.jpg", 7 - index))
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        }

        let results = FolderScanner.scanFolder(at: root, maximumImageCount: 5)

        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(results.map(\.lastPathComponent), results.map(\.lastPathComponent).sorted())
    }

    func testFolderScanHasAVisitedEntryCeiling() {
        XCTAssertGreaterThan(FolderScanner.maximumVisitedEntries, 0)
        XCTAssertLessThanOrEqual(FolderScanner.maximumVisitedEntries, 100_000)
    }

    func testImageRequestOptionsUseHighQualityLocalExactLoading() {
        let options = PhotoLibrary.imageRequestOptions()

        XCTAssertEqual(options.deliveryMode, .highQualityFormat)
        XCTAssertEqual(options.resizeMode, .exact)
        XCTAssertFalse(options.isSynchronous)
        XCTAssertFalse(options.isNetworkAccessAllowed)
    }

    func testFolderImageDecodeUsesRequestedPixelBoundWithoutApplyingScreenScaleAgain() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 800, height: 400),
            format: format
        ).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        try XCTUnwrap(source.pngData()).write(to: imageURL)

        let decoded = try XCTUnwrap(
            FolderScanner.loadImage(
                from: imageURL,
                targetSize: CGSize(width: 100, height: 80)
            )
        )
        let cgImage = try XCTUnwrap(decoded.cgImage)

        XCTAssertEqual(cgImage.width, 100)
        XCTAssertEqual(cgImage.height, 50)
        XCTAssertEqual(decoded.scale, 1)
    }

    @MainActor
    func testZoomDisplayTargetIsScaledOnceAndCappedProportionally() {
        let target = ZoomableAsyncImage.displayTargetSize(
            screenSize: CGSize(width: 430, height: 932),
            screenScale: 3,
            zoomHeadroom: 3,
            maximumPixelDimension: 4_096
        )

        XCTAssertEqual(max(target.width, target.height), 4_096, accuracy: 0.001)
        XCTAssertEqual(target.width / target.height, 430.0 / 932.0, accuracy: 0.001)
    }

    func testFolderImageLoadPropagatesOuterTaskCancellation() async {
        let probe = AsyncCancellationProbe()
        let outerTask = Task {
            await FolderImageLoadOperation.run {
                await probe.markStarted()
                while !Task.isCancelled {
                    if await probe.shouldStop { break }
                    await Task.yield()
                }
                await probe.markFinished(cancelled: Task.isCancelled)
                return nil
            }
        }

        let started = await Self.waitUntil { await probe.hasStarted }
        XCTAssertTrue(started)
        outerTask.cancel()
        let finished = await Self.waitUntil { await probe.hasFinished }
        if !finished {
            await probe.stop()
        }
        _ = await outerTask.value

        XCTAssertTrue(finished)
        let cancellationObserved = await probe.wasCancelled
        XCTAssertTrue(cancellationObserved)
    }

    func testFolderImageLoadsHaveBoundedPeakConcurrency() async {
        let probe = FolderLoadConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = await FolderImageLoadOperation.run {
                        await probe.begin()
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        await probe.end()
                        return nil
                    }
                }
            }
        }

        let maximumConcurrent = await probe.maximumConcurrent
        XCTAssertLessThanOrEqual(maximumConcurrent, 2)
    }

    @MainActor
    func testSimilaritySearchRunsOffMainThreadAndPropagatesCancellation() async {
        let probe = AsyncCancellationProbe()
        let outerTask = Task {
            await SimilaritySearchOperation.run {
                await probe.markStarted(onMainThread: Self.currentThreadIsMain())
                while !Task.isCancelled {
                    if await probe.shouldStop { break }
                    await Task.yield()
                }
                await probe.markFinished(cancelled: Task.isCancelled)
                return []
            }
        }

        let started = await Self.waitUntil { await probe.hasStarted }
        let ranOnMainThread = await probe.ranOnMainThread
        XCTAssertTrue(started)
        XCTAssertFalse(ranOnMainThread)
        outerTask.cancel()
        let finished = await Self.waitUntil { await probe.hasFinished }
        if !finished {
            await probe.stop()
        }
        _ = await outerTask.value

        XCTAssertTrue(finished)
        let cancellationObserved = await probe.wasCancelled
        XCTAssertTrue(cancellationObserved)
    }

    private nonisolated static func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }

    func testPixelBufferRowZeroContainsVisuallyTopColor() throws {
        let image = makeTopBottomImage(width: 2, height: 2)

        let pixels = try rgbPixels(
            from: XCTUnwrap(image.toPixelBuffer(width: 2, height: 2)),
            width: 2,
            height: 2
        )

        XCTAssertGreaterThan(pixels[0].red, pixels[0].blue)
        XCTAssertGreaterThan(pixels[2].blue, pixels[2].red)
    }

    func testPixelBufferAppliesNonUpImageOrientation() throws {
        let source = makeLeftRightImage(width: 2, height: 1)
        let oriented = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 1, orientation: .right)

        let pixels = try rgbPixels(
            from: XCTUnwrap(oriented.toPixelBuffer(width: 1, height: 2)),
            width: 1,
            height: 2
        )

        XCTAssertGreaterThan(pixels[0].red, pixels[0].blue)
        XCTAssertGreaterThan(pixels[1].blue, pixels[1].red)
    }

    func testPixelBufferCreationFailsGracefullyForEmptyImage() {
        let empty = UIImage()

        XCTAssertNil(empty.toPixelBuffer(width: 224, height: 224))
    }

    func testFolderScannerValidatesImageFileWithinSourceFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("image.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(FolderScanner.isValidImageFile(imageURL, within: root))
    }

    func testFolderScannerRejectsFilesOutsideSourceFolder() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("source", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let outsideImage = outside.appendingPathComponent("image.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([0]).write(to: outsideImage)
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertFalse(FolderScanner.isValidImageFile(outsideImage, within: root))
    }

    func testFolderScannerRejectsUnsupportedFileExtensions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let textURL = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: textURL)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(FolderScanner.isValidImageFile(textURL, within: root))
    }

    func testFolderScannerRejectsImageContainerOverByteLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("oversized.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: Data([0])))
        defer { try? FileManager.default.removeItem(at: root) }

        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(FolderScanner.maximumImageFileBytes + 1))
        try handle.close()

        XCTAssertFalse(FolderScanner.isValidImageFile(imageURL, within: root))
    }

    func testFolderScannerRejectsNamedPipeWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fifoURL = root.appendingPathComponent("blocked.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertFalse(FolderScanner.isValidImageFile(fifoURL, within: root))
        XCTAssertTrue(FolderScanner.scanFolder(at: root).isEmpty)
    }

    func testFolderScannerRejectsUnsupportedContentRenamedAsJPEG() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let disguisedGIF = root.appendingPathComponent("disguised.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let onePixelGIF = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        try onePixelGIF.write(to: disguisedGIF)

        XCTAssertNil(FolderScanner.loadImage(from: disguisedGIF, within: root))
        let dimensions = FolderScanner.imageDimensions(from: disguisedGIF, within: root)
        XCTAssertEqual(dimensions.width, 0)
        XCTAssertEqual(dimensions.height, 0)
    }

    func testFolderScannerRejectsFileReplacedByOutsideSymlinkAfterScan() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("source", isDirectory: true)
        let outsideImage = parent.appendingPathComponent("outside.png")
        let scannedImage = root.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let imageData = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        try imageData.write(to: outsideImage)
        try imageData.write(to: scannedImage)

        let scanned = FolderScanner.scanFolder(at: root, maximumImageCount: 1)
        XCTAssertEqual(scanned, [scannedImage])

        try FileManager.default.removeItem(at: scannedImage)
        try FileManager.default.createSymbolicLink(
            at: scannedImage,
            withDestinationURL: outsideImage
        )

        XCTAssertFalse(FolderScanner.isValidImageFile(scannedImage, within: root))
        XCTAssertNil(FolderScanner.loadImage(from: scannedImage, within: root))
        XCTAssertEqual(
            FolderScanner.imageDimensions(from: scannedImage, within: root).width,
            0
        )
        let metadata = FolderScanner.extractMetadata(from: scannedImage, within: root)
        XCTAssertNil(metadata.date)
        XCTAssertNil(metadata.latitude)
        XCTAssertNil(metadata.longitude)
    }

    func testFolderScannerDecodesTheValidatedDescriptorAfterPathReplacement() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("source", isDirectory: true)
        let selectedImage = root.appendingPathComponent("image.png")
        let outsideImage = parent.appendingPathComponent("outside.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()).write(to: selectedImage)
        try XCTUnwrap(renderer.image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()).write(to: outsideImage)

        let decoded = try XCTUnwrap(
            FolderScanner.withValidatedImageSource(selectedImage, within: root) { source, _ in
                try FileManager.default.removeItem(at: selectedImage)
                try FileManager.default.createSymbolicLink(
                    at: selectedImage,
                    withDestinationURL: outsideImage
                )
                return CGImageSourceCreateImageAtIndex(source, 0, nil).map(UIImage.init)
            } ?? nil
        )
        let pixel = try XCTUnwrap(
            rgbPixels(
                from: XCTUnwrap(decoded.toPixelBuffer(width: 1, height: 1)),
                width: 1,
                height: 1
            ).first
        )

        XCTAssertGreaterThan(pixel.red, pixel.blue)
        XCTAssertFalse(FolderScanner.isValidImageFile(selectedImage, within: root))
    }

    func testFolderScannerImageSourceUsesImmutableBoundedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()).write(to: imageURL)
        let blueData = try XCTUnwrap(renderer.image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())

        let decoded = try XCTUnwrap(
            FolderScanner.withValidatedImageSource(imageURL, within: root) { source, _ in
                try blueData.write(to: imageURL)
                return CGImageSourceCreateImageAtIndex(source, 0, nil).map(UIImage.init)
            } ?? nil
        )
        let pixel = try XCTUnwrap(
            rgbPixels(
                from: XCTUnwrap(decoded.toPixelBuffer(width: 1, height: 1)),
                width: 1,
                height: 1
            ).first
        )

        XCTAssertGreaterThan(pixel.red, pixel.blue)
    }

    private func makeTopBottomImage(width: Int, height: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        }
    }

    private func makeLeftRightImage(width: Int, height: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
    }

    private func rgbPixels(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> [RGB] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var values: [RGB] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                values.append(RGB(
                    red: pixels[offset + 2],
                    green: pixels[offset + 1],
                    blue: pixels[offset]
                ))
            }
        }
        return values
    }

    private static func waitUntil(
        attempts: Int = 2_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private actor AsyncCancellationProbe {
    private(set) var hasStarted = false
    private(set) var hasFinished = false
    private(set) var wasCancelled = false
    private(set) var ranOnMainThread = false
    private(set) var shouldStop = false

    func markStarted(onMainThread: Bool = false) {
        hasStarted = true
        ranOnMainThread = onMainThread
    }

    func markFinished(cancelled: Bool) {
        hasFinished = true
        wasCancelled = cancelled
    }

    func stop() {
        shouldStop = true
    }
}

private actor FolderLoadConcurrencyProbe {
    private var currentConcurrent = 0
    private(set) var maximumConcurrent = 0

    func begin() {
        currentConcurrent += 1
        maximumConcurrent = max(maximumConcurrent, currentConcurrent)
    }

    func end() {
        currentConcurrent -= 1
    }
}

private struct RGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}
