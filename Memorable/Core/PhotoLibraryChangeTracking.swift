import Foundation
import Photos
import os

struct PhotoLibraryChangeDiff: Equatable, Sendable {
    var hasNewMedia: Bool
    var orphanedPhotoIDs: Set<String>
    var orphanedVideoIDs: Set<String>
    var changedPhotoIDs: Set<String> = []
    var changedVideoIDs: Set<String> = []

    static func evaluate(
        libraryPhotos: Set<String>,
        libraryVideos: Set<String>,
        indexedPhotos: Set<String>,
        indexedVideos: Set<String>,
        allowsOrphanCleanup: Bool
    ) -> PhotoLibraryChangeDiff {
        PhotoLibraryChangeDiff(
            hasNewMedia: !libraryPhotos.subtracting(indexedPhotos).isEmpty
                || !libraryVideos.subtracting(indexedVideos).isEmpty,
            orphanedPhotoIDs: allowsOrphanCleanup
                ? indexedPhotos.subtracting(libraryPhotos)
                : [],
            orphanedVideoIDs: allowsOrphanCleanup
                ? indexedVideos.subtracting(libraryVideos)
                : []
        )
    }
}

struct PhotoLibraryChangeEvent: Equatable, Sendable {
    var insertedPhotoIDs: Set<String> = []
    var insertedVideoIDs: Set<String> = []
    var removedPhotoIDs: Set<String> = []
    var removedVideoIDs: Set<String> = []
    var changedPhotoIDs: Set<String> = []
    var changedVideoIDs: Set<String> = []
    var requiresFullReconciliation = false

    static let fullReconciliation = PhotoLibraryChangeEvent(
        requiresFullReconciliation: true
    )

    var hasWork: Bool {
        requiresFullReconciliation
            || !insertedPhotoIDs.isEmpty
            || !insertedVideoIDs.isEmpty
            || !removedPhotoIDs.isEmpty
            || !removedVideoIDs.isEmpty
            || !changedPhotoIDs.isEmpty
            || !changedVideoIDs.isEmpty
    }

    mutating func merge(_ other: PhotoLibraryChangeEvent) {
        requiresFullReconciliation = requiresFullReconciliation
            || other.requiresFullReconciliation
        for id in other.insertedPhotoIDs {
            removedPhotoIDs.remove(id)
            changedPhotoIDs.remove(id)
            insertedPhotoIDs.insert(id)
        }
        for id in other.insertedVideoIDs {
            removedVideoIDs.remove(id)
            changedVideoIDs.remove(id)
            insertedVideoIDs.insert(id)
        }
        for id in other.removedPhotoIDs {
            insertedPhotoIDs.remove(id)
            changedPhotoIDs.remove(id)
            removedPhotoIDs.insert(id)
        }
        for id in other.removedVideoIDs {
            insertedVideoIDs.remove(id)
            changedVideoIDs.remove(id)
            removedVideoIDs.insert(id)
        }
        changedPhotoIDs.formUnion(other.changedPhotoIDs.subtracting(removedPhotoIDs))
        changedVideoIDs.formUnion(other.changedVideoIDs.subtracting(removedVideoIDs))
    }
}

struct PhotoChangeScanState: Equatable {
    private(set) var hasPendingChange = false
    private(set) var isScanning = false

    mutating func requestScan(isIndexing: Bool) -> Bool {
        hasPendingChange = true
        return startPendingScanIfPossible(isIndexing: isIndexing)
    }

    mutating func startPendingScanIfPossible(isIndexing: Bool) -> Bool {
        guard hasPendingChange, !isIndexing, !isScanning else { return false }
        hasPendingChange = false
        isScanning = true
        return true
    }

    mutating func finishScan(isIndexing: Bool) -> Bool {
        isScanning = false
        return startPendingScanIfPossible(isIndexing: isIndexing)
    }

    mutating func cancel() {
        hasPendingChange = false
        isScanning = false
    }
}

enum PhotoLibraryOrphanCleanupAuthorizationPolicy {
    static func allowsCleanup(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized
    }
}

enum PhotoLibraryChangeReconciler {
    struct AssetVersion: Equatable, Sendable {
        let localIdentifier: String
        let modifiedAt: Date?
    }

    static func needsIndexing(
        assets: [AssetVersion], indexed: [String: IndexedMediaVersion]
    ) -> Bool {
        assets.contains { asset in
            guard let version = indexed[asset.localIdentifier] else { return true }
            return IndexedMediaFreshness.needsRefresh(
                modifiedAt: asset.modifiedAt, indexedAt: version.indexedAt
            )
        }
    }

    /// Count equality cannot establish completeness after edits or replacement.
    /// Read at most one page of identities/timestamps at a time and stop once
    /// there is work; folder rows never participate in this comparison.
    static func hasUnindexedOrModifiedMedia(database: DatabaseProtocol) throws -> Bool {
        let assets = PhotoLibrary.fetchAllMedia()
        let pageSize = SearchIndexLimits.databasePageMediaItems
        for start in stride(from: 0, to: assets.count, by: pageSize) {
            try Task.checkCancellation()
            var photos: [AssetVersion] = []
            var videos: [AssetVersion] = []
            for index in start..<min(start + pageSize, assets.count) {
                let asset = assets.object(at: index)
                let version = AssetVersion(localIdentifier: asset.localIdentifier, modifiedAt: asset.modificationDate)
                if asset.mediaType == .video { videos.append(version) } else { photos.append(version) }
            }
            if try needsIndexing(assets: photos, indexed: database.indexedPhotoVersions(in: photos.map(\.localIdentifier)))
                || needsIndexing(assets: videos, indexed: database.indexedVideoVersions(in: videos.map(\.localIdentifier))) {
                return true
            }
        }
        return false
    }

    static func reconcile(
        _ event: PhotoLibraryChangeEvent,
        database: DatabaseProtocol,
        authorizationStatus: PHAuthorizationStatus
    ) throws -> PhotoLibraryChangeDiff {
        if event.requiresFullReconciliation {
            var result = try fullReconciliation(database: database)
            result.changedPhotoIDs = event.changedPhotoIDs
            result.changedVideoIDs = event.changedVideoIDs
            result.hasNewMedia = result.hasNewMedia
                || !event.changedPhotoIDs.isEmpty || !event.changedVideoIDs.isEmpty
            return result
        }

        let indexedInsertedPhotos = try database.existingPhotoIdentifiers(
            in: Array(event.insertedPhotoIDs)
        )
        let indexedInsertedVideos = try database.existingVideoIdentifiers(
            in: Array(event.insertedVideoIDs)
        )
        var orphanedPhotos: Set<String> = []
        var orphanedVideos: Set<String> = []
        if authorizationStatus == .authorized {
            orphanedPhotos = try database.existingPhotoIdentifiers(
                in: Array(event.removedPhotoIDs)
            )
            orphanedVideos = try database.existingVideoIdentifiers(
                in: Array(event.removedVideoIDs)
            )
            let indexedCount = try database.photoLibraryIndexedMediaCounts().total
            if OrphanCleanupSafetyPolicy.exceedsSafetyThreshold(
                candidateRemovalCount: orphanedPhotos.count + orphanedVideos.count,
                photoLibraryIndexedCount: indexedCount
            ) {
                orphanedPhotos.removeAll(keepingCapacity: false)
                orphanedVideos.removeAll(keepingCapacity: false)
            }
        }
        return PhotoLibraryChangeDiff(
            hasNewMedia: !event.insertedPhotoIDs.subtracting(indexedInsertedPhotos).isEmpty
                || !event.insertedVideoIDs.subtracting(indexedInsertedVideos).isEmpty
                || !event.changedPhotoIDs.isEmpty || !event.changedVideoIDs.isEmpty,
            orphanedPhotoIDs: orphanedPhotos,
            orphanedVideoIDs: orphanedVideos,
            changedPhotoIDs: event.changedPhotoIDs,
            changedVideoIDs: event.changedVideoIDs
        )
    }

    private static func fullReconciliation(
        database: DatabaseProtocol
    ) throws -> PhotoLibraryChangeDiff {
        let hasNewMedia = try hasUnindexedOrModifiedMedia(database: database)
        let pageSize = SearchIndexLimits.databasePageMediaItems

        var orphanedPhotos: Set<String> = []
        var orphanedVideos: Set<String> = []
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            let indexedCount = try database.photoLibraryIndexedMediaCounts().total
            var cursor: SearchMediaPageCursor?
            repeat {
                try Task.checkCancellation()
                let page = try database.loadIndexedMediaIdentifierPage(
                    after: cursor,
                    limit: pageSize
                )
                let identifiers = page.photos + page.videos
                guard !identifiers.isEmpty else { break }
                let existingAssets = PHAsset.fetchAssets(
                    withLocalIdentifiers: identifiers,
                    options: nil
                )
                var existing: Set<String> = []
                existing.reserveCapacity(existingAssets.count)
                existingAssets.enumerateObjects { asset, _, _ in
                    existing.insert(asset.localIdentifier)
                }
                let pageDiff = PhotoLibraryChangeDiff.evaluate(
                    libraryPhotos: Set(page.photos).intersection(existing),
                    libraryVideos: Set(page.videos).intersection(existing),
                    indexedPhotos: Set(page.photos),
                    indexedVideos: Set(page.videos),
                    allowsOrphanCleanup: true
                )
                orphanedPhotos.formUnion(pageDiff.orphanedPhotoIDs)
                orphanedVideos.formUnion(pageDiff.orphanedVideoIDs)
                if OrphanCleanupSafetyPolicy.exceedsSafetyThreshold(
                    candidateRemovalCount: orphanedPhotos.count + orphanedVideos.count,
                    photoLibraryIndexedCount: indexedCount
                ) {
                    orphanedPhotos.removeAll(keepingCapacity: false)
                    orphanedVideos.removeAll(keepingCapacity: false)
                    break
                }
                cursor = page.nextCursor
            } while cursor != nil
        }
        return PhotoLibraryChangeDiff(
            hasNewMedia: hasNewMedia,
            orphanedPhotoIDs: orphanedPhotos,
            orphanedVideoIDs: orphanedVideos
        )
    }
}

protocol PhotoChangeObservationRegistrar: AnyObject {
    func register(_ observer: PHPhotoLibraryChangeObserver)
    func unregister(_ observer: PHPhotoLibraryChangeObserver)
}

private final class SystemPhotoChangeObservationRegistrar: PhotoChangeObservationRegistrar {
    func register(_ observer: PHPhotoLibraryChangeObserver) {
        PHPhotoLibrary.shared().register(observer)
    }

    func unregister(_ observer: PHPhotoLibraryChangeObserver) {
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
    }
}

/// Sendable invariant: callback, registration state, and the PhotoKit fetch
/// snapshot each have a dedicated lock. User callbacks are dispatched to the
/// main queue, and the registrar reference is immutable after initialization.
final class PhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let callback = OSAllocatedUnfairLock<(@MainActor @Sendable (PhotoLibraryChangeEvent) -> Void)?>(
        initialState: nil
    )
    private let observing = OSAllocatedUnfairLock(initialState: false)
    private struct FetchState: Sendable {
        var result: PHFetchResult<PHAsset>?
        var revision: UInt = 0
    }
    private let fetchResult = OSAllocatedUnfairLock(initialState: FetchState())
    private let registrar: PhotoChangeObservationRegistrar
    private let fetchMedia: @Sendable () -> PHFetchResult<PHAsset>

    override convenience init() {
        self.init(registrar: SystemPhotoChangeObservationRegistrar())
    }

    init(
        registrar: PhotoChangeObservationRegistrar,
        fetchMedia: @escaping @Sendable () -> PHFetchResult<PHAsset> = { PhotoLibrary.fetchAllMedia() }
    ) {
        self.registrar = registrar
        self.fetchMedia = fetchMedia
        super.init()
    }

    var onPhotoLibraryChange: (@MainActor @Sendable (PhotoLibraryChangeEvent) -> Void)? {
        get { callback.withLock { $0 } }
        set { callback.withLock { $0 = newValue } }
    }

    func startObserving() {
        let shouldRegister = observing.withLock { isObserving in
            guard !isObserving else { return false }
            isObserving = true
            return true
        }
        guard shouldRegister else { return }
        registrar.register(self)
        let revision = fetchResult.withLock { $0.revision }
        Task.detached(priority: .utility) { [weak self, fetchMedia] in
            let initialFetch = fetchMedia()
            guard let self, self.observing.withLock({ $0 }) else { return }
            self.fetchResult.withLock {
                guard $0.revision == revision else { return }
                $0.result = initialFetch
                $0.revision &+= 1
            }
        }
    }

    func stopObserving() {
        let shouldUnregister = observing.withLock { isObserving in
            guard isObserving else { return false }
            isObserving = false
            return true
        }
        callback.withLock { $0 = nil }
        fetchResult.withLock {
            $0.result = nil
            $0.revision &+= 1
        }
        guard shouldUnregister else { return }
        registrar.unregister(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard observing.withLock({ $0 }) else { return }
        let before = fetchResult.withLock { $0 }
        // PhotoKit can perform I/O and materialize many changed assets here.
        // Never hold the snapshot lock while doing that work: stopObserving
        // also takes it on the main thread during memory-pressure cleanup.
        let updated: PHFetchResult<PHAsset>
        var event = PhotoLibraryChangeEvent.fullReconciliation
        if let result = before.result,
           let details = changeInstance.changeDetails(for: result) {
            updated = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                event = PhotoLibraryChangeEvent()
                for asset in details.insertedObjects {
                    if asset.mediaType == .video {
                        event.insertedVideoIDs.insert(asset.localIdentifier)
                    } else {
                        event.insertedPhotoIDs.insert(asset.localIdentifier)
                    }
                }
                for asset in details.removedObjects {
                    if asset.mediaType == .video {
                        event.removedVideoIDs.insert(asset.localIdentifier)
                    } else {
                        event.removedPhotoIDs.insert(asset.localIdentifier)
                    }
                }
                for asset in details.changedObjects {
                    if asset.mediaType == .video {
                        event.changedVideoIDs.insert(asset.localIdentifier)
                    } else {
                        event.changedPhotoIDs.insert(asset.localIdentifier)
                    }
                }
            }
        } else {
            updated = fetchMedia()
        }
        let installed = fetchResult.withLock {
            guard $0.revision == before.revision else { return false }
            $0.result = updated
            $0.revision &+= 1
            return true
        }
        // A concurrent change owns a newer snapshot. Reconcile against Photos
        // instead of replacing it with an out-of-order incremental snapshot.
        if !installed { event = .fullReconciliation }
        guard event.hasWork else { return }
        enqueueDelivery(event)
    }

    func enqueueDelivery(_ event: PhotoLibraryChangeEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.observing.withLock({ $0 }),
                  let callback = self.callback.withLock({ $0 }) else { return }
            callback(event)
        }
    }

    deinit {
        stopObserving()
    }
}
