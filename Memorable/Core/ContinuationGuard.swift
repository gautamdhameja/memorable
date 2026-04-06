import os

/// Thread-safe wrapper to ensure a CheckedContinuation is resumed exactly once.
/// Protects against PHImageManager's multi-callback pattern where the handler
/// may fire on different threads.
final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deallocate()
    }

    /// Resume with a value. Only the first call succeeds; subsequent calls are no-ops.
    func resume(returning value: T) {
        os_unfair_lock_lock(lock)
        let cont = continuation
        continuation = nil
        os_unfair_lock_unlock(lock)
        cont?.resume(returning: value)
    }
}
