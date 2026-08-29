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
