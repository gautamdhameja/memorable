import XCTest
import UIKit
@preconcurrency import Photos
import ImageIO
import os
@testable import Memorable

final class PhotoSharingTests: XCTestCase {
    func testPhotoShareWriterStreamsWithinBoundAndCleansUp() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let writer = try PhotoShareFileWriter(fileURL: fileURL, maximumByteCount: 4)

        XCTAssertTrue(writer.append(Data([1, 2, 3])))
        XCTAssertFalse(writer.append(Data([4, 5])))
        XCTAssertTrue(writer.finish())
        XCTAssertEqual(try Data(contentsOf: fileURL), Data([1, 2, 3]))

        PreparedPhotoShareItem(fileURL: fileURL).cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testPhotoShareWriterDiscardsPartialFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let writer = try PhotoShareFileWriter(fileURL: fileURL, maximumByteCount: 4)

        XCTAssertTrue(writer.append(Data([1, 2])))
        writer.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testPhotoShareExtensionRejectsUnsafeFilenameSuffixes() {
        XCTAssertEqual(PhotoShareResourcePolicy.safePathExtension(for: "photo.HEIC"), "heic")
        XCTAssertEqual(PhotoShareResourcePolicy.safePathExtension(for: "photo"), "image")
        XCTAssertEqual(PhotoShareResourcePolicy.safePathExtension(for: "photo.bad-extension!"), "image")
        XCTAssertEqual(
            PhotoShareResourcePolicy.pathExtension(
                forTypeIdentifier: "public.png",
                fallbackFilename: "misleading.jpg"
            ),
            "png"
        )
    }

    func testLocalPhotoShareRequestIsNetworkDisabledAndPreservesSourceBytes() async throws {
        let registered = expectation(description: "photo resource request registered")
        let probe = PhotoResourceRequestProbe(
            requestID: 41,
            registrationExpectation: registered
        )
        let sourceData = try Self.jpegDataWithSensitiveMetadata()
        let task = Task {
            try await PhotoLibrary.copyLocalPhotoResource(
                pathExtension: "jpg",
                maximumByteCount: sourceData.count,
                requestData: probe.request,
                cancelRequest: probe.cancel,
                requestRegistered: probe.markRegistered
            )
        }

        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(probe.isNetworkAccessAllowed, false)
        probe.send(sourceData)
        probe.complete(error: nil)

        let item = try await task.value
        defer { item.cleanup() }
        XCTAssertEqual(try Data(contentsOf: item.fileURL), sourceData)
        XCTAssertTrue(probe.cancelledRequestIDs.isEmpty)
    }

    func testLocalPhotoSharePreservesEveryFrame() async throws {
        let registered = expectation(description: "photo resource request registered")
        let probe = PhotoResourceRequestProbe(
            requestID: 46,
            registrationExpectation: registered
        )
        let sourceData = try Self.twoFrameTIFFData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourceData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let task = Task {
            try await PhotoLibrary.copyLocalPhotoResource(
                pathExtension: "tiff",
                maximumByteCount: sourceData.count,
                requestData: probe.request,
                cancelRequest: probe.cancel,
                requestRegistered: probe.markRegistered
            )
        }

        await fulfillment(of: [registered], timeout: 1)
        probe.send(sourceData)
        probe.complete(error: nil)

        let item = try await task.value
        defer { item.cleanup() }
        XCTAssertEqual(try Data(contentsOf: item.fileURL), sourceData)
        let shared = try XCTUnwrap(CGImageSourceCreateWithURL(item.fileURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(shared), 2)
    }

    func testLocalPhotoShareOverflowCancelsRequestAndDeletesPartialFile() async {
        let registered = expectation(description: "photo resource request registered")
        let probe = PhotoResourceRequestProbe(
            requestID: 42,
            registrationExpectation: registered
        )
        let task = Task {
            try await PhotoLibrary.copyLocalPhotoResource(
                pathExtension: "jpg",
                maximumByteCount: 2,
                requestData: probe.request,
                cancelRequest: probe.cancel,
                requestRegistered: probe.markRegistered
            )
        }

        await fulfillment(of: [registered], timeout: 1)
        probe.send(Data([1, 2, 3]))

        do {
            _ = try await task.value
            XCTFail("Expected an oversized share resource to fail")
        } catch {
            XCTAssertEqual(error as? PhotoSharePreparationError, .fileTooLarge)
        }
        XCTAssertEqual(probe.cancelledRequestIDs, [42])
    }

    func testLocalPhotoShareCancellationUsesResourceManagerRequestID() async {
        let existingFiles = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: PhotoLibrary.shareItemsDirectoryURL,
                includingPropertiesForKeys: nil
            )) ?? []
        )
        let registered = expectation(description: "photo resource request registered")
        let probe = PhotoResourceRequestProbe(
            requestID: 43,
            registrationExpectation: registered
        )
        let task = Task {
            try await PhotoLibrary.copyLocalPhotoResource(
                pathExtension: "jpg",
                requestData: probe.request,
                cancelRequest: probe.cancel,
                requestRegistered: probe.markRegistered
            )
        }

        await fulfillment(of: [registered], timeout: 1)
        let requestFiles = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: PhotoLibrary.shareItemsDirectoryURL,
                includingPropertiesForKeys: nil
            )) ?? []
        ).subtracting(existingFiles)
        XCTAssertEqual(requestFiles.count, 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to stop share preparation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        probe.send(Data([1, 2, 3]))
        probe.complete(error: nil)
        XCTAssertTrue(requestFiles.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertEqual(probe.cancelledRequestIDs, [43])
    }

    func testLocalPhotoShareManagerErrorReturnsUnavailableAndRemovesFile() async {
        let registered = expectation(description: "photo resource request registered")
        let probe = PhotoResourceRequestProbe(
            requestID: 44,
            registrationExpectation: registered
        )
        let task = Task {
            try await PhotoLibrary.copyLocalPhotoResource(
                pathExtension: "jpg",
                requestData: probe.request,
                cancelRequest: probe.cancel,
                requestRegistered: probe.markRegistered
            )
        }

        await fulfillment(of: [registered], timeout: 1)
        probe.send(Data([1, 2]))
        probe.complete(error: CocoaError(.fileReadUnknown))

        do {
            _ = try await task.value
            XCTFail("Expected a resource-manager failure")
        } catch {
            XCTAssertEqual(error as? PhotoSharePreparationError, .sourceUnavailable)
        }
        XCTAssertTrue(probe.cancelledRequestIDs.isEmpty)
    }

    @MainActor
    func testShareCoordinatorDoesNothingUntilExplicitRequest() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([1]).write(to: fileURL)
        let probe = SharePreparationProbe(
            item: PreparedPhotoShareItem(fileURL: fileURL),
            suspends: false
        )
        let coordinator = PhotoShareCoordinator { result in
            try await probe.prepare(result)
        }
        let result = Self.photoResult(id: "visible")

        coordinator.visibleResultDidChange(to: result.id)
        coordinator.cancelPreparation()
        XCTAssertEqual(probe.invocationCount, 0)
        XCTAssertNil(coordinator.preparedItem)

        coordinator.requestShare(for: result)
        let itemPrepared = await Self.waitUntil { await coordinator.preparedItem != nil }
        XCTAssertTrue(itemPrepared)
        XCTAssertEqual(probe.invocationCount, 1)
        XCTAssertEqual(coordinator.preparedItem?.fileURL, fileURL)
        coordinator.cancelAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testShareCoordinatorDiscardsItemWhenVisibleResultChangesAtSameIndex() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([1]).write(to: fileURL)
        let probe = SharePreparationProbe(
            item: PreparedPhotoShareItem(fileURL: fileURL),
            suspends: true
        )
        let coordinator = PhotoShareCoordinator { result in
            try await probe.prepare(result)
        }

        coordinator.requestShare(for: Self.photoResult(id: "original"))
        let preparationStarted = await Self.waitUntil { await probe.isWaiting }
        XCTAssertTrue(preparationStarted)
        coordinator.visibleResultDidChange(to: "replacement")
        probe.resume()

        let staleItemRemoved = await Self.waitUntil {
            !FileManager.default.fileExists(atPath: fileURL.path)
        }
        XCTAssertTrue(staleItemRemoved)
        XCTAssertNil(coordinator.preparedItem)
    }

    @MainActor
    func testShareCoordinatorPresentsSafeFailureMessage() async {
        let coordinator = PhotoShareCoordinator { _ in
            throw PhotoSharePreparationError.sourceUnavailable
        }

        coordinator.requestShare(for: Self.photoResult(id: "missing"))

        let errorPresented = await Self.waitUntil { await coordinator.errorMessage != nil }
        XCTAssertTrue(errorPresented)
        XCTAssertEqual(
            coordinator.errorMessage,
            PhotoSharePreparationError.sourceUnavailable.userMessage
        )
    }

    func testCanceledFolderReadDiscardsCompletedShareItem() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([1, 2, 3]).write(to: fileURL)
        let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let operationStarted = expectation(description: "folder operation started")

        let task = Task {
            await FolderFileReadOperation.run(
                onDiscardedResult: { $0.cleanup() }
            ) {
                await withCheckedContinuation { pending in
                    continuation.withLock { $0 = pending }
                    operationStarted.fulfill()
                }
                return PreparedPhotoShareItem(fileURL: fileURL)
            }
        }

        await fulfillment(of: [operationStarted], timeout: 1)
        task.cancel()
        continuation.withLock { pending in
            pending?.resume()
            pending = nil
        }

        let discardedResult = await task.value
        XCTAssertNil(discardedResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFolderResultAccessRequiresProButPhotoKitDoesNot() {
        XCTAssertFalse(FolderResultAccessPolicy.allows(sourceId: "folder-source", isPro: false))
        XCTAssertTrue(FolderResultAccessPolicy.allows(sourceId: "folder-source", isPro: true))
        XCTAssertTrue(FolderResultAccessPolicy.allows(
            sourceId: PhotoSourceType.photokit.rawValue,
            isPro: false
        ))
    }

    func testFilteredResultSelectionPreservesCurrentPhotoAfterEarlierFolderRemoval() {
        XCTAssertEqual(
            FilteredResultSelectionPolicy.index(
                preserving: "current-photo",
                previousIndex: 2,
                remainingResultIDs: ["first-photo", "current-photo", "next-photo"]
            ),
            1
        )
    }

    @MainActor
    func testRevokedFolderResultCannotLoadOrShare() async {
        let previouslyPro = ProManager.shared.isPro
        ProManager.shared.isPro = false
        defer { ProManager.shared.isPro = previouslyPro }

        let result = SearchResult(
            id: "revoked-folder-result",
            score: 1,
            localIdentifier: "folder:source:photo.jpg",
            creationDate: nil,
            isVideo: false,
            bestFramePosition: nil,
            sourceId: "folder-source",
            filePath: "/tmp/photo.jpg"
        )

        let image = await PhotoLibrary.loadImage(
            for: result,
            targetSize: CGSize(width: 32, height: 32)
        )
        XCTAssertNil(image)

        do {
            _ = try await PhotoLibrary.prepareShareItem(for: result)
            XCTFail("Expected a revoked folder result to fail closed")
        } catch {
            XCTAssertEqual(error as? PhotoSharePreparationError, .sourceUnavailable)
        }
    }

    func testShareItemCleanupRemovesOnlyDedicatedDirectoryContents() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shareDirectory = temporaryRoot.appendingPathComponent("MemorableShareItems", isDirectory: true)
        let unrelatedFile = temporaryRoot.appendingPathComponent("unrelated.txt")
        try FileManager.default.createDirectory(at: shareDirectory, withIntermediateDirectories: true)
        let staleShare = shareDirectory.appendingPathComponent("stale.jpg")
        let hiddenStaleShare = shareDirectory.appendingPathComponent(".stale-atomic-write")
        try Data([1]).write(to: staleShare)
        try Data([1]).write(to: hiddenStaleShare)
        try Data([2]).write(to: unrelatedFile)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        PhotoLibrary.cleanupShareItems(in: shareDirectory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleShare.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenStaleShare.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    @MainActor
    func testAppStateInitializationDefersShareItemCleanupOffMainThread() async {
        let state = OSAllocatedUnfairLock(initialState: (count: 0, ranOnMain: true))
        let cleanupFinished = expectation(description: "share cleanup finished")

        _ = AppState(shareItemCleanup: {
            state.withLock {
                $0.count += 1
                $0.ranOnMain = Thread.isMainThread
            }
            cleanupFinished.fulfill()
        })
        await fulfillment(of: [cleanupFinished], timeout: 1)

        XCTAssertEqual(state.withLock { $0.count }, 1)
        XCTAssertFalse(state.withLock { $0.ranOnMain })
    }

    func testValidatedFolderShareSnapshotPreservesExactBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let misleadingURL = root.appendingPathComponent("misleading.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let pngData = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        try pngData.write(to: misleadingURL)

        let snapshot = try XCTUnwrap(
            FolderScanner.validatedImageSnapshot(misleadingURL, within: root)
        )

        XCTAssertEqual(snapshot.data, pngData)
        XCTAssertEqual(snapshot.typeIdentifier, "public.png")
        XCTAssertEqual(
            PhotoShareResourcePolicy.pathExtension(
                forTypeIdentifier: snapshot.typeIdentifier,
                fallbackFilename: misleadingURL.lastPathComponent
            ),
            "png"
        )
        let shareItem = try PhotoLibrary.prepareFolderShareItem(snapshot)
        defer { shareItem.cleanup() }
        XCTAssertEqual(shareItem.fileURL.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: shareItem.fileURL), pngData)
    }

    func testFolderSharePreservesLargeImageDimensionsWithinByteLimit() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 5_000, height: 20),
            format: format
        )
        let pngData = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 5_000, height: 20))
        }.pngData())
        let snapshot = FolderScanner.ValidatedImageSnapshot(
            data: pngData,
            typeIdentifier: "public.png"
        )

        let shareItem = try PhotoLibrary.prepareFolderShareItem(snapshot)
        defer { shareItem.cleanup() }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(shareItem.fileURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertEqual(max(width, height), 5_000)
        XCTAssertEqual(Double(width) / Double(height), 250, accuracy: 10)
    }

    func testFolderShareRejectsSnapshotsOverFolderByteLimit() {
        let snapshot = FolderScanner.ValidatedImageSnapshot(
            data: Data(
                repeating: 0,
                count: FolderScanner.maximumImageFileBytes + 1
            ),
            typeIdentifier: "public.png"
        )

        XCTAssertThrowsError(try PhotoLibrary.prepareFolderShareItem(snapshot)) { error in
            XCTAssertEqual(error as? PhotoSharePreparationError, .fileTooLarge)
        }
    }

    private static func photoResult(id: String) -> SearchResult {
        SearchResult(
            id: id,
            score: 1,
            localIdentifier: id,
            creationDate: nil,
            isVideo: false,
            bestFramePosition: nil
        )
    }

    private static func jpegDataWithSensitiveMetadata() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLatitude: 37.3349,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSLongitude: 122.0090,
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Private Camera",
            ],
        ]
        CGImageDestinationAddImage(
            destination,
            try XCTUnwrap(image.cgImage),
            properties as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func twoFrameTIFFData() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 2, nil)
        )
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let red = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.cgImage)
        let blue = try XCTUnwrap(renderer.image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.cgImage)
        CGImageDestinationAddImage(destination, red, nil)
        CGImageDestinationAddImage(destination, blue, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
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

@MainActor
private final class SharePreparationProbe {
    private let item: PreparedPhotoShareItem
    private let suspends: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0

    var isWaiting: Bool { continuation != nil }

    init(item: PreparedPhotoShareItem, suspends: Bool) {
        self.item = item
        self.suspends = suspends
    }

    func prepare(_ result: SearchResult) async throws -> PreparedPhotoShareItem {
        invocationCount += 1
        if suspends {
            await withCheckedContinuation { continuation = $0 }
        }
        return item
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class PhotoResourceRequestProbe: @unchecked Sendable {
    private struct State: Sendable {
        var isNetworkAccessAllowed: Bool?
        var dataHandler: (@Sendable (Data) -> Void)?
        var completionHandler: (@Sendable (Error?) -> Void)?
        var cancelledRequestIDs: [PHImageRequestID] = []
    }

    private let requestID: PHImageRequestID
    private let registrationExpectation: XCTestExpectation?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        requestID: PHImageRequestID,
        registrationExpectation: XCTestExpectation? = nil
    ) {
        self.requestID = requestID
        self.registrationExpectation = registrationExpectation
    }

    var isRegistered: Bool {
        state.withLock { $0.dataHandler != nil && $0.completionHandler != nil }
    }

    var isNetworkAccessAllowed: Bool? {
        state.withLock { $0.isNetworkAccessAllowed }
    }

    var cancelledRequestIDs: [PHImageRequestID] {
        state.withLock { $0.cancelledRequestIDs }
    }

    func request(
        options: PHAssetResourceRequestOptions,
        dataHandler: @escaping @Sendable (Data) -> Void,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) -> PHImageRequestID {
        let isNetworkAccessAllowed = options.isNetworkAccessAllowed
        state.withLock {
            $0.isNetworkAccessAllowed = isNetworkAccessAllowed
            $0.dataHandler = dataHandler
            $0.completionHandler = completionHandler
        }
        return requestID
    }

    func markRegistered() {
        registrationExpectation?.fulfill()
    }

    func send(_ data: Data) {
        let handler = state.withLock { $0.dataHandler }
        handler?(data)
    }

    func complete(error: Error?) {
        let handler = state.withLock { state -> (@Sendable (Error?) -> Void)? in
            defer {
                state.dataHandler = nil
                state.completionHandler = nil
            }
            return state.completionHandler
        }
        handler?(error)
    }

    func cancel(_ requestID: PHImageRequestID) {
        state.withLock { $0.cancelledRequestIDs.append(requestID) }
    }
}
