import XCTest
import Photos
@testable import Memorable

final class AppReadinessTests: XCTestCase {

    func testDeviceCompatibilityAllowsSimulatorAndA14MetalFamily() {
        XCTAssertTrue(DeviceCompatibility.isSupported(
            isSimulator: true,
            supportsApple7: false
        ))
        XCTAssertTrue(DeviceCompatibility.isSupported(
            isSimulator: false,
            supportsApple7: true
        ))
    }

    func testDeviceCompatibilityRejectsOlderPhysicalDevices() {
        XCTAssertFalse(DeviceCompatibility.isSupported(
            isSimulator: false,
            supportsApple7: false
        ))
    }

    func testInitialReadinessHasNoReadyStates() {
        let readiness = AppReadiness()

        XCTAssertFalse(readiness.isShellReady)
        XCTAssertFalse(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isIndexReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testShellReadyDoesNotImplySemanticReadiness() {
        var readiness = AppReadiness()

        readiness.markShellReady()

        XCTAssertTrue(readiness.isShellReady)
        XCTAssertFalse(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isIndexReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testSemanticModelReadyWithoutIndexIsNotSearchReady() {
        var readiness = AppReadiness()

        readiness.markSemanticModelReady()

        XCTAssertTrue(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testSemanticModelAndIndexReadyMarksSemanticSearchReady() {
        var readiness = AppReadiness()

        readiness.markSemanticModelReady()
        readiness.markIndexReady()

        XCTAssertTrue(readiness.isSemanticSearchReady)
    }

    func testMemoryRecoveryCanDropOnlyIndexReadiness() {
        var readiness = AppReadiness()
        readiness.markShellReady()
        readiness.markSemanticModelReady()
        readiness.markIndexReady()

        readiness.markIndexUnavailable()

        XCTAssertTrue(readiness.isShellReady)
        XCTAssertTrue(readiness.isSemanticModelReady)
        XCTAssertFalse(readiness.isIndexReady)
        XCTAssertFalse(readiness.isSemanticSearchReady)
    }

    func testPhotoAuthorizationRecoveryInitializesAfterSettingsGrant() {
        XCTAssertTrue(PhotoAuthorizationRecoveryPolicy.shouldInitialize(
            authorizationStatus: .authorized,
            isShellReady: false,
            isInitializing: false
        ))
        XCTAssertTrue(PhotoAuthorizationRecoveryPolicy.shouldInitialize(
            authorizationStatus: .limited,
            isShellReady: false,
            isInitializing: false
        ))
    }

    func testPhotoAuthorizationRecoveryDoesNotRestartReadyOrDeniedApp() {
        XCTAssertFalse(PhotoAuthorizationRecoveryPolicy.shouldInitialize(
            authorizationStatus: .authorized,
            isShellReady: true,
            isInitializing: false
        ))
        XCTAssertFalse(PhotoAuthorizationRecoveryPolicy.shouldInitialize(
            authorizationStatus: .denied,
            isShellReady: false,
            isInitializing: false
        ))
        XCTAssertFalse(PhotoAuthorizationRecoveryPolicy.shouldInitialize(
            authorizationStatus: .authorized,
            isShellReady: false,
            isInitializing: true
        ))
    }

    @MainActor
    func testAppStateRefreshesGrantedAuthorizationWithoutRequestingAgain() async {
        var requestCount = 0
        let state = AppState(
            shareItemCleanup: {},
            requestPhotoAuthorization: {
                requestCount += 1
                return .denied
            },
            currentPhotoAuthorization: { .authorized }
        )

        await state.refreshPhotoAuthorization()

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(state.authorizationStatus, .authorized)
        XCTAssertTrue(state.readiness.isShellReady)
        state.handleMemoryWarning()
    }

    @MainActor
    func testUnsupportedDeviceNeverRequestsPhotoAuthorizationOrStartsShell() async {
        var requestCount = 0
        let state = AppState(
            shareItemCleanup: {},
            requestPhotoAuthorization: {
                requestCount += 1
                return .authorized
            },
            currentPhotoAuthorization: { .authorized },
            isDeviceSupported: { false }
        )

        await state.initialize()

        XCTAssertFalse(state.isDeviceSupported)
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(state.readiness.isShellReady)
    }
}
