import Foundation
import Photos
import os

struct PhotoLibraryChangeDiff: Equatable, Sendable {
    var hasNewMedia: Bool
    var orphanedPhotoIDs: Set<String>
    var orphanedVideoIDs: Set<String>

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
    }

    mutating func merge(_ other: PhotoLibraryChangeEvent) {
        requiresFullReconciliation = requiresFullReconciliation
            || other.requiresFullReconciliation
        for id in other.insertedPhotoIDs {
            removedPhotoIDs.remove(id)
            insertedPhotoIDs.insert(id)
        }
        for id in other.insertedVideoIDs {
            removedVideoIDs.remove(id)
            insertedVideoIDs.insert(id)
        }
        for id in other.removedPhotoIDs {
            insertedPhotoIDs.remove(id)
            removedPhotoIDs.insert(id)
        }
        for id in other.removedVideoIDs {
            insertedVideoIDs.remove(id)
            removedVideoIDs.insert(id)
        }
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
    static func reconcile(
        _ event: PhotoLibraryChangeEvent,
        database: DatabaseProtocol,
        authorizationStatus: PHAuthorizationStatus
    ) throws -> PhotoLibraryChangeDiff {
        if event.requiresFullReconciliation {
            return try fullReconciliation(database: database)
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
                || !event.insertedVideoIDs.subtracting(indexedInsertedVideos).isEmpty,
            orphanedPhotoIDs: orphanedPhotos,
            orphanedVideoIDs: orphanedVideos
        )
    }

    private static func fullReconciliation(
        database: DatabaseProtocol
    ) throws -> PhotoLibraryChangeDiff {
        let allMedia = PhotoLibrary.fetchAllMedia()
        var hasNewMedia = false
        let pageSize = SearchIndexLimits.databasePageMediaItems
        for pageStart in stride(from: 0, to: allMedia.count, by: pageSize) {
            try Task.checkCancellation()
            let pageEnd = min(pageStart + pageSize, allMedia.count)
            var photoIDs: [String] = []
            var videoIDs: [String] = []
            photoIDs.reserveCapacity(pageEnd - pageStart)
            videoIDs.reserveCapacity(pageEnd - pageStart)
            for index in pageStart..<pageEnd {
                let asset = allMedia.object(at: index)
                if asset.mediaType == .video {
                    videoIDs.append(asset.localIdentifier)
                } else {
                    photoIDs.append(asset.localIdentifier)
                }
            }
            let pageDiff = PhotoLibraryChangeDiff.evaluate(
                libraryPhotos: Set(photoIDs),
                libraryVideos: Set(videoIDs),
                indexedPhotos: try database.existingPhotoIdentifiers(in: photoIDs),
                indexedVideos: try database.existingVideoIdentifiers(in: videoIDs),
                allowsOrphanCleanup: false
            )
            hasNewMedia = hasNewMedia || pageDiff.hasNewMedia
        }

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

final class PhotoChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let callback = OSAllocatedUnfairLock<(@MainActor @Sendable (PhotoLibraryChangeEvent) -> Void)?>(
        initialState: nil
    )
    private let observing = OSAllocatedUnfairLock(initialState: false)
    private let fetchResult = OSAllocatedUnfairLock<PHFetchResult<PHAsset>?>(
        initialState: nil
    )
    private let registrar: PhotoChangeObservationRegistrar

    override convenience init() {
        self.init(registrar: SystemPhotoChangeObservationRegistrar())
    }

    init(registrar: PhotoChangeObservationRegistrar) {
        self.registrar = registrar
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
        Task.detached(priority: .utility) { [weak self] in
            let initialFetch = PhotoLibrary.fetchAllMedia()
            guard let self, self.observing.withLock({ $0 }) else { return }
            self.fetchResult.withLock { $0 = initialFetch }
        }
    }

    func stopObserving() {
        let shouldUnregister = observing.withLock { isObserving in
            guard isObserving else { return false }
            isObserving = false
            return true
        }
        callback.withLock { $0 = nil }
        fetchResult.withLock { $0 = nil }
        guard shouldUnregister else { return }
        registrar.unregister(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        let event = fetchResult.withLock { storedResult -> PhotoLibraryChangeEvent in
            guard let beforeChanges = storedResult,
                  let details = changeInstance.changeDetails(for: beforeChanges) else {
                storedResult = PhotoLibrary.fetchAllMedia()
                return .fullReconciliation
            }
            storedResult = details.fetchResultAfterChanges
            guard details.hasIncrementalChanges else {
                return .fullReconciliation
            }
            var event = PhotoLibraryChangeEvent()
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
            return event
        }
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
