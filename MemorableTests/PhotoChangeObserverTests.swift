import Photos
import XCTest
@testable import Memorable

final class PhotoChangeObserverTests: XCTestCase {
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
