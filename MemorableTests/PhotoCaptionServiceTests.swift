import XCTest
@testable import Memorable

final class PhotoCaptionServiceTests: XCTestCase {
    private actor EncoderGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private(set) var observedCancellation = false

        func encode(_ prompt: String) async throws -> [Float] {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }

            if !released {
                await withCheckedContinuation { continuation in
                    releaseWaiter = continuation
                }
            }

            do {
                try Task.checkCancellation()
            } catch {
                observedCancellation = true
                throw error
            }
            return [1]
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    @MainActor
    func testMemoryWarningDuringPreparationCannotRepopulateReleasedEmbeddings() async {
        let appState = AppState()
        let service = appState.captionService
        let gate = EncoderGate()
        let preparation = Task { @MainActor in
            await service.prepare(categories: [PhotoCaptionService.categories[0]]) { prompt in
                try await gate.encode(prompt)
            }
        }

        await gate.waitUntilStarted()
        appState.handleMemoryWarning()
        await gate.release()
        await preparation.value

        let observedCancellation = await gate.observedCancellation
        XCTAssertTrue(observedCancellation)
        XCTAssertNil(service.caption(for: [1]))
    }
}
