import XCTest
import UIKit
@testable import Memorable

final class ImagePreprocessingTests: XCTestCase {

    func testIndexingImageRequestOptionsUseFastLocalExactLoading() {
        let options = PhotoLibrary.indexingImageRequestOptions()

        XCTAssertEqual(options.deliveryMode, .fastFormat)
        XCTAssertEqual(options.resizeMode, .exact)
        XCTAssertFalse(options.isSynchronous)
        XCTAssertFalse(options.isNetworkAccessAllowed)
    }

    func testDisplayImageRequestOptionsRemainHighQuality() {
        let options = PhotoLibrary.displayImageRequestOptions()

        XCTAssertEqual(options.deliveryMode, .highQualityFormat)
        XCTAssertEqual(options.resizeMode, .exact)
        XCTAssertFalse(options.isSynchronous)
        XCTAssertFalse(options.isNetworkAccessAllowed)
    }

    func testPixelBufferUsesDisplayedImageOrientation() throws {
        let source = makeTwoColorImage(width: 2, height: 1)
        let oriented = UIImage(cgImage: source.cgImage!, scale: 1, orientation: .right)
        let expected = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 2)).image { _ in
            oriented.draw(in: CGRect(x: 0, y: 0, width: 1, height: 2))
        }

        let expectedPixels = try rgbPixels(from: XCTUnwrap(expected.toPixelBuffer(width: 1, height: 2)), width: 1, height: 2)
        let actualPixels = try rgbPixels(from: XCTUnwrap(oriented.toPixelBuffer(width: 1, height: 2)), width: 1, height: 2)

        XCTAssertEqual(actualPixels, expectedPixels)
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

    private func makeTwoColorImage(width: Int, height: Int) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: height))
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 1, y: 0, width: 1, height: height))
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
