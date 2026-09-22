import XCTest
import AVKit
import os
@testable import Memorable

final class SharedUtilitiesTests: XCTestCase {
    func testStagedBookmarkDeletionRecoversAfterInterruptedDatabaseCommit() throws {
        let sourceID = "staged-deletion-\(UUID().uuidString)"
        let bookmark = Data([7, 4, 1])
        defer { try? FolderBookmarkStore.remove(for: sourceID) }
        try FolderBookmarkStore.set(bookmark, for: sourceID)

        let token = try XCTUnwrap(FolderBookmarkStore.stageDeletion(for: sourceID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: token.liveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: token.pendingURL.path))

        try FolderBookmarkStore.recoverStagedDeletionIfNeeded(for: sourceID)

        XCTAssertEqual(FolderBookmarkStore.data(for: sourceID), bookmark)
        XCTAssertFalse(FileManager.default.fileExists(atPath: token.pendingURL.path))
    }

    func testCommittedStagedBookmarkDeletionIsRemovedOnRecoverySweep() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let committed = directory.appendingPathComponent("removed.bookmark.deletion-pending")
        let protected = directory.appendingPathComponent("live.bookmark.deletion-pending")
        let ordinary = directory.appendingPathComponent("keep.bookmark")
        for file in [committed, protected, ordinary] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data([1])))
        }

        try FolderBookmarkStore.cleanupCommittedStagedDeletions(
            in: directory,
            protectedPendingPaths: [protected.path]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ordinary.path))
    }

    func testLocalOnlyDirectoryIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try LocalOnlyStorage.prepareDirectory(at: directory)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFolderBookmarkMigratesOutOfUserDefaultsAndExcludesBackup() throws {
        let sourceID = UUID().uuidString
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceID)
        let bookmark = Data([1, 2, 3, 4])
        UserDefaults.standard.set(bookmark, forKey: legacyKey)
        defer { try? FolderBookmarkStore.remove(for: sourceID) }

        XCTAssertEqual(FolderBookmarkStore.data(for: sourceID), bookmark)
        XCTAssertNil(UserDefaults.standard.data(forKey: legacyKey))
        let bookmarkURL = try FolderBookmarkStore.bookmarkURL(for: sourceID)
        let values = try bookmarkURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testFolderBookmarkRemovalFailurePreservesLegacyDataForRetry() throws {
        enum ForcedFailure: Error { case removeDenied }
        let sourceID = UUID().uuidString
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceID)
        let bookmark = Data([5, 4, 3])
        UserDefaults.standard.set(bookmark, forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        XCTAssertThrowsError(try FolderBookmarkStore.remove(
            for: sourceID,
            removeItem: { _ in throw ForcedFailure.removeDenied }
        )) { error in
            XCTAssertTrue(error is ForcedFailure)
        }
        XCTAssertEqual(UserDefaults.standard.data(forKey: legacyKey), bookmark)
    }

    func testFolderBookmarkRemovalTreatsMissingFileAsSuccess() throws {
        let sourceID = UUID().uuidString
        let legacyKey = AppKeys.folderBookmark(sourceId: sourceID)
        UserDefaults.standard.set(Data([9, 8, 7]), forKey: legacyKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyKey) }

        try FolderBookmarkStore.remove(for: sourceID) { _ in
            throw CocoaError(.fileNoSuchFile)
        }

        XCTAssertNil(UserDefaults.standard.data(forKey: legacyKey))
    }

    func testSurpriseMatchProfileMigratesToExcludedLocalState() throws {
        SurpriseQueryCache.clear()
        defer { SurpriseQueryCache.clear() }
        UserDefaults.standard.set(
            ["golden hour", "selfie"],
            forKey: AppKeys.surpriseValidatedQueries
        )
        UserDefaults.standard.set(42, forKey: AppKeys.surpriseLastValidatedCount)

        SurpriseQueryCache.migrateLegacyDefaults()

        XCTAssertNil(UserDefaults.standard.object(forKey: AppKeys.surpriseValidatedQueries))
        XCTAssertNil(UserDefaults.standard.object(forKey: AppKeys.surpriseLastValidatedCount))
        XCTAssertEqual(
            SurpriseQueryCache.load(),
            .init(validatedQueries: ["golden hour", "selfie"], lastValidatedCount: 42)
        )
        let cacheURL = try SurpriseQueryCache.fileURL()
        let values = try cacheURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testSurpriseQueryCacheDecodesLegacyStateWithoutContentRevision() throws {
        let legacyJSON = Data(#"{"validatedQueries":["golden hour"],"lastValidatedCount":42}"#.utf8)

        let state = try JSONDecoder().decode(SurpriseQueryCache.State.self, from: legacyJSON)

        XCTAssertEqual(state.validatedQueries, ["golden hour"])
        XCTAssertEqual(state.lastValidatedCount, 42)
        XCTAssertNil(state.contentRevision)
    }

    func testImageLoadGenerationRejectsLateCompletionAfterMemoryPressure() {
        XCTAssertFalse(ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: 1,
            currentGeneration: 2,
            isCancelled: false
        ))
        XCTAssertFalse(ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: 2,
            currentGeneration: 2,
            isCancelled: true
        ))
        XCTAssertTrue(ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: 2,
            currentGeneration: 2,
            isCancelled: false
        ))
    }

    @MainActor
    func testSlideshowSelectionRetriesRepeatedRowsUntilItFindsAlternative() async {
        let candidates = OSAllocatedUnfairLock(initialState: ["shown", "shown", "alternative"])
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let selection = await SlideshowSelectionPolicy.next(
            recentIDs: ["shown"],
            historyLimit: 50,
            maxAttempts: 5,
            fetch: {
                attempts.withLock { $0 += 1 }
                return candidates.withLock { values in
                    values.isEmpty ? nil : values.removeFirst()
                }
            },
            identifier: { $0 }
        )

        XCTAssertEqual(selection?.item, "alternative")
        XCTAssertEqual(selection?.recentIDs, ["shown", "alternative"])
        XCTAssertEqual(attempts.withLock { $0 }, 3)
    }

    @MainActor
    func testSlideshowSelectionBoundsRetriesWhenDatabaseRepeatsOnlyRow() async {
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let selection = await SlideshowSelectionPolicy.next(
            recentIDs: ["only"],
            historyLimit: 50,
            maxAttempts: 4,
            fetch: {
                attempts.withLock { $0 += 1 }
                return "only"
            },
            identifier: { $0 }
        )

        XCTAssertEqual(selection?.item, "only")
        XCTAssertEqual(selection?.recentIDs, ["only"])
        XCTAssertEqual(attempts.withLock { $0 }, 4)
    }

    @MainActor
    func testSlideshowSelectionNeverFallsBackToRejectedMemoryCandidate() async {
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let selection = await SlideshowSelectionPolicy.next(
            recentIDs: [],
            historyLimit: 50,
            maxAttempts: 4,
            fetch: {
                attempts.withLock { $0 += 1 }
                return "duplicate"
            },
            identifier: { $0 },
            accepts: { _ in false }
        )

        XCTAssertNil(selection)
        XCTAssertEqual(attempts.withLock { $0 }, 4)
    }

    func testMemoryPressureGenerationInvalidatesEveryInFlightCompletion() {
        let completedBeforeWarning = [1, 2, 3].filter {
            ImageLoadGenerationPolicy.acceptsCompletion(
                startedGeneration: UInt($0),
                currentGeneration: 4,
                isCancelled: false
            )
        }

        XCTAssertTrue(completedBeforeWarning.isEmpty)
        XCTAssertFalse(ImageLoadGenerationPolicy.acceptsCompletion(
            startedGeneration: 4,
            currentGeneration: 4,
            isCancelled: true
        ))
    }

    func testVideoPlaybackRejectsReplacedAndCancelledLoads() {
        XCTAssertFalse(VideoPlaybackRequestPolicy.acceptsCompletion(
            startedGeneration: 1,
            currentGeneration: 2,
            isCancelled: false
        ))
        XCTAssertFalse(VideoPlaybackRequestPolicy.acceptsCompletion(
            startedGeneration: 2,
            currentGeneration: 2,
            isCancelled: true
        ))
        XCTAssertTrue(VideoPlaybackRequestPolicy.acceptsCompletion(
            startedGeneration: 2,
            currentGeneration: 2,
            isCancelled: false
        ))
    }

    @MainActor
    func testVideoPlaybackAllowsUserSelectedAirPlayAndPictureInPicture() {
        let player = AVPlayer()
        let controller = AVPlayerViewController()

        PrivateVideoPlaybackConfiguration.apply(to: player, controller: controller)

        XCTAssertTrue(player.allowsExternalPlayback)
        XCTAssertFalse(player.usesExternalPlaybackWhileExternalScreenIsActive)
        XCTAssertTrue(controller.allowsPictureInPicturePlayback)
    }

    @MainActor
    func testVideoPlaybackTeardownDeactivatesAudio() {
        let player = AVPlayer()
        var didDeactivate = false

        PrivateVideoPlaybackConfiguration.tearDown(player: player) {
            didDeactivate = true
        }

        XCTAssertTrue(didDeactivate)
        XCTAssertEqual(player.rate, 0)
    }

    func testMemoryPressureReleaseDropsDecodedImage() {
        var image: UIImage? = UIImage()

        MemoryPressureReleasePolicy.release(&image)

        XCTAssertNil(image)
    }

    func testMemoryPressureReleaseDropsStrongResourceReference() {
        final class Resource {}
        var resource: Resource? = Resource()
        let weakResource = WeakReference(resource)

        MemoryPressureReleasePolicy.release(&resource)

        XCTAssertNil(resource)
        XCTAssertNil(weakResource.value)
    }

    func testJustifiedRowFillsItsWidthAndGivesEveryTileTheSameHeight() {
        let ratios: [CGFloat] = [4.0 / 3.0, 16.0 / 9.0, 3.0 / 4.0]
        let spacing: CGFloat = 4
        let available: CGFloat = 390

        let height = JustifiedRowLayout.rowHeight(
            availableWidth: available, aspectRatios: ratios, spacing: spacing
        )
        XCTAssertGreaterThan(height, 0)

        let widths = JustifiedRowLayout.widths(
            availableWidth: available, aspectRatios: ratios, spacing: spacing
        )
        XCTAssertEqual(widths.count, ratios.count)

        // The row fills the proposed width exactly, leaving no gap.
        let total = widths.reduce(0, +) + spacing * CGFloat(ratios.count - 1)
        XCTAssertEqual(total, available, accuracy: 0.001)

        // Every tile renders at its own aspect ratio against the shared height.
        for (width, ratio) in zip(widths, ratios) {
            XCTAssertEqual(width / height, ratio, accuracy: 0.001)
        }
    }

    func testJustifiedRowFallsBackToEqualWidthsWhenItCannotBeJustified() {
        // No width yet, for example during an early layout pass.
        XCTAssertEqual(
            JustifiedRowLayout.rowHeight(
                availableWidth: 0, aspectRatios: [1, 1], spacing: 4
            ),
            0
        )
        let equal = JustifiedRowLayout.widths(
            availableWidth: 104, aspectRatios: [0, 0], spacing: 4
        )
        XCTAssertEqual(equal.count, 2)
        XCTAssertEqual(equal[0], 50, accuracy: 0.001)
        XCTAssertEqual(equal[1], 50, accuracy: 0.001)

        // Spacing wider than the row must not produce negative widths.
        let crowded = JustifiedRowLayout.widths(
            availableWidth: 10, aspectRatios: [1, 1], spacing: 40
        )
        XCTAssertEqual(crowded.count, 2)
        XCTAssertTrue(crowded.allSatisfy { $0 >= 0 })

        XCTAssertTrue(
            JustifiedRowLayout.widths(
                availableWidth: 390, aspectRatios: [], spacing: 4
            ).isEmpty
        )
    }

    func testJustifiedRowRejectsNonFiniteInput() {
        XCTAssertEqual(
            JustifiedRowLayout.rowHeight(
                availableWidth: .infinity, aspectRatios: [1], spacing: 0
            ),
            0
        )
        XCTAssertEqual(
            JustifiedRowLayout.rowHeight(
                availableWidth: 390, aspectRatios: [.nan], spacing: 0
            ),
            0
        )
        XCTAssertEqual(
            JustifiedRowLayout.rowHeight(
                availableWidth: 390, aspectRatios: [1], spacing: -4
            ),
            0
        )
    }

    func testPhotoViewerKeepsNeighbouringPagesLoadedAndReleasesDistantOnes() {
        // The visible page and the one on each side stay decoded so a swipe
        // reveals the photo instead of a spinner.
        for offset in -1...1 {
            XCTAssertTrue(
                PhotoViewerPreloadPolicy.shouldLoad(index: 5 + offset, currentIndex: 5),
                "Page at offset \(offset) should stay loaded"
            )
        }

        // Everything further away releases its image so viewer memory stays
        // bounded no matter how many results the search returned.
        XCTAssertFalse(PhotoViewerPreloadPolicy.shouldLoad(index: 3, currentIndex: 5))
        XCTAssertFalse(PhotoViewerPreloadPolicy.shouldLoad(index: 7, currentIndex: 5))
        XCTAssertFalse(PhotoViewerPreloadPolicy.shouldLoad(index: 0, currentIndex: 200))
    }

    func testPhotoViewerPreloadWindowIsConfigurableAndRejectsNegativeCounts() {
        XCTAssertTrue(
            PhotoViewerPreloadPolicy.shouldLoad(index: 7, currentIndex: 5, neighbourCount: 2)
        )
        XCTAssertFalse(
            PhotoViewerPreloadPolicy.shouldLoad(index: 8, currentIndex: 5, neighbourCount: 2)
        )
        XCTAssertTrue(
            PhotoViewerPreloadPolicy.shouldLoad(index: 5, currentIndex: 5, neighbourCount: 0)
        )
        // A negative window must not disable loading for the visible page.
        XCTAssertTrue(
            PhotoViewerPreloadPolicy.shouldLoad(index: 5, currentIndex: 5, neighbourCount: -3)
        )
        XCTAssertFalse(
            PhotoViewerPreloadPolicy.shouldLoad(index: 6, currentIndex: 5, neighbourCount: -3)
        )
    }

    func testActiveImageMemoryPressurePolicyPreservesOrSchedulesOneRecovery() {
        XCTAssertEqual(
            MemoryPressureImageRecoveryPolicy.decision(
                hasImage: true,
                isActive: true,
                preserveVisibleImage: true
            ),
            .preserve
        )
        XCTAssertEqual(
            MemoryPressureImageRecoveryPolicy.decision(
                hasImage: true,
                isActive: true,
                preserveVisibleImage: false
            ),
            .releaseAndRetry
        )
        XCTAssertEqual(
            MemoryPressureImageRecoveryPolicy.decision(
                hasImage: false,
                isActive: true,
                preserveVisibleImage: true
            ),
            .releaseAndRetry
        )
        XCTAssertEqual(
            MemoryPressureImageRecoveryPolicy.decision(
                hasImage: true,
                isActive: false,
                preserveVisibleImage: true
            ),
            .release
        )
    }

    // MARK: - L2 Normalization

    func testL2NormalizeUnitVector() {
        var vec: [Float] = [1.0, 0.0, 0.0]
        vec.l2Normalize()
        XCTAssertEqual(vec[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(vec[1], 0.0, accuracy: 0.001)
    }

    func testL2NormalizeProducesUnitLength() {
        var vec: [Float] = [3.0, 4.0]
        vec.l2Normalize()

        let norm = sqrt(vec[0] * vec[0] + vec[1] * vec[1])
        XCTAssertEqual(norm, 1.0, accuracy: 0.001, "Normalized vector should have unit length")
    }

    func testL2NormalizeZeroVector() {
        var vec: [Float] = [0.0, 0.0, 0.0]
        XCTAssertFalse(vec.l2Normalize())
        // Should not crash, vector stays zero
        XCTAssertEqual(vec, [0.0, 0.0, 0.0])
    }

    func testL2NormalizeRejectsNonFiniteVector() {
        var vec: [Float] = [1, .infinity]

        XCTAssertFalse(vec.l2Normalize())
    }

    func testL2NormalizePreservesDirection() {
        var vec: [Float] = [2.0, 2.0]
        vec.l2Normalize()
        // Both components should be equal (45 degree direction preserved)
        XCTAssertEqual(vec[0], vec[1], accuracy: 0.001)
    }

    // MARK: - Array Chunking

    func testChunkedEvenSplit() {
        let arr = [1, 2, 3, 4, 5, 6]
        let chunks = arr.chunked(into: 2)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], [1, 2])
        XCTAssertEqual(chunks[1], [3, 4])
        XCTAssertEqual(chunks[2], [5, 6])
    }

    func testChunkedUnevenSplit() {
        let arr = [1, 2, 3, 4, 5]
        let chunks = arr.chunked(into: 2)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[2], [5])
    }

    func testChunkedSingleChunk() {
        let arr = [1, 2, 3]
        let chunks = arr.chunked(into: 10)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], [1, 2, 3])
    }

    func testChunkedEmpty() {
        let arr: [Int] = []
        let chunks = arr.chunked(into: 5)
        XCTAssertTrue(chunks.isEmpty)
    }

    // MARK: - Safe Array Access

    func testSafeSubscriptValid() {
        let arr = [10, 20, 30]
        XCTAssertEqual(arr[safe: 0], 10)
        XCTAssertEqual(arr[safe: 2], 30)
    }

    func testSafeSubscriptOutOfBounds() {
        let arr = [10, 20, 30]
        XCTAssertNil(arr[safe: 3])
        XCTAssertNil(arr[safe: -1])
    }

    func testSafeSubscriptEmpty() {
        let arr: [Int] = []
        XCTAssertNil(arr[safe: 0])
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
