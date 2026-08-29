import XCTest
import UIKit
@testable import Memorable

final class ImagePreprocessingTests: XCTestCase {

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

    func testImageRequestOptionsUseHighQualityLocalExactLoading() {
        let options = PhotoLibrary.imageRequestOptions()

        XCTAssertEqual(options.deliveryMode, .highQualityFormat)
        XCTAssertEqual(options.resizeMode, .exact)
        XCTAssertFalse(options.isSynchronous)
        XCTAssertFalse(options.isNetworkAccessAllowed)
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
}

private struct RGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}
