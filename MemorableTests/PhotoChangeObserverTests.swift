import Photos
import XCTest
import os
@testable import Memorable

final class PhotoChangeObserverTests: XCTestCase {
    @MainActor
    func testStoppingObservationDoesNotWaitForPhotoKitFetch() async {
        let registrar = RecordingPhotoChangeRegistrar()
        let initialFetch = expectation(description: "initial fetch")
        let changeFetch = expectation(description: "change fetch blocked")
        let releaseFetch = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
        let observer = PhotoChangeObserver(registrar: registrar, fetchMedia: {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 {
                initialFetch.fulfill()
            } else {
                changeFetch.fulfill()
                _ = releaseFetch.wait(timeout: .now() + 3)
            }
            return assets
        })
        observer.startObserving()
        await fulfillment(of: [initialFetch], timeout: 1)
        let change = Task.detached { observer.photoLibraryDidChange(PHChange()) }
        await fulfillment(of: [changeFetch], timeout: 1)
        let startedAt = ContinuousClock.now
        observer.stopObserving()
        let elapsed = startedAt.duration(to: .now)
        releaseFetch.signal()
        await change.value
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(registrar.unregistrationCount, 1)
    }

    func testRegistrationLifecycleIsIdempotentAndDeinitUnregisters() {
        let registrar = RecordingPhotoChangeRegistrar()
        weak var releasedObserver: PhotoChangeObserver?

        autoreleasepool {
            let observer = PhotoChangeObserver(registrar: registrar)
            releasedObserver = observer

            observer.startObserving()
            observer.startObserving()

            XCTAssertEqual(registrar.registrationCount, 1)
            XCTAssertEqual(registrar.unregistrationCount, 0)
        }

        XCTAssertNil(releasedObserver)
        XCTAssertEqual(registrar.unregistrationCount, 1)
    }

    func testExplicitStopUnregistersOnlyOnce() {
        let registrar = RecordingPhotoChangeRegistrar()
        let observer = PhotoChangeObserver(registrar: registrar)

        observer.startObserving()
        observer.stopObserving()
        observer.stopObserving()

        XCTAssertEqual(registrar.registrationCount, 1)
        XCTAssertEqual(registrar.unregistrationCount, 1)
    }

    @MainActor
    func testQueuedDeliveryDoesNotRunAfterStop() async {
        let registrar = RecordingPhotoChangeRegistrar()
        let observer = PhotoChangeObserver(registrar: registrar)
        let callback = expectation(description: "stopped callback")
        callback.isInverted = true

        observer.startObserving()
        observer.onPhotoLibraryChange = { _ in callback.fulfill() }
        observer.enqueueDelivery(PhotoLibraryChangeEvent(insertedPhotoIDs: ["new-photo"]))
        observer.stopObserving()

        await fulfillment(of: [callback], timeout: 0.1)
    }
}

private final class RecordingPhotoChangeRegistrar: PhotoChangeObservationRegistrar {
    private(set) var registrationCount = 0
    private(set) var unregistrationCount = 0

    func register(_ observer: PHPhotoLibraryChangeObserver) {
        registrationCount += 1
    }

    func unregister(_ observer: PHPhotoLibraryChangeObserver) {
        unregistrationCount += 1
    }
}
