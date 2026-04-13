import os

/// Thread-safe wrapper to ensure a CheckedContinuation is resumed exactly once.
/// Protects against PHImageManager's multi-callback pattern where the handler
/// may fire on different threads.
final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.state = OSAllocatedUnfairLock(initialState: continuation)
    }

    /// Resume with a value. Only the first call succeeds; subsequent calls are no-ops.
    func resume(returning value: T) {
        let cont = state.withLock { continuation -> CheckedContinuation<T, Never>? in
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(returning: value)
    }
}
