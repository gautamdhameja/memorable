import Foundation

enum IndexingJobKind: String, CaseIterable, Hashable {
    case indexPhotos
    case indexVideos
    case enrichPhotos
    case geocodeMedia
    case cleanOrphans
    case validateSurpriseQueries
    case indexFolder
}

enum IndexingJobPriority: Int, Comparable {
    case background = 100
    case enrichment = 200
    case maintenance = 300
    case userInitiated = 400

    static func < (lhs: IndexingJobPriority, rhs: IndexingJobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum IndexingJobOutcome: Equatable {
    case completed
    case cancelled
}

struct IndexingJob {
    let id: UUID
    let workflowID: UUID
    let kind: IndexingJobKind
    let priority: IndexingJobPriority
    let dependencies: Set<IndexingJobKind>
    let delayAfterDependencies: TimeInterval
    let operation: @MainActor () async -> IndexingJobOutcome

    init(
        id: UUID = UUID(),
        workflowID: UUID,
        kind: IndexingJobKind,
        priority: IndexingJobPriority,
        dependencies: Set<IndexingJobKind> = [],
        delayAfterDependencies: TimeInterval = 0,
        operation: @escaping @MainActor () async -> IndexingJobOutcome
    ) {
        self.id = id
        self.workflowID = workflowID
        self.kind = kind
        self.priority = priority
        self.dependencies = dependencies
        self.delayAfterDependencies = delayAfterDependencies
        self.operation = operation
    }
}

/// A single-lane scheduler for indexing work. Dependencies are scoped to a
/// workflow, so completion from an older indexing pass cannot unblock a newer
/// pass. Cancelling a job always removes pending work and cancels the active
/// task; a late return from an operation is ignored unless its job is still
/// active.
@MainActor
final class IndexingJobQueue {
    typealias Clock = () -> Date
    typealias Sleeper = (UInt64) async throws -> Void

    private struct PendingJob {
        let job: IndexingJob
        let enqueuedAt: Date
        let sequence: Int
    }

    private struct ActiveJob {
        let job: IndexingJob
        let task: Task<Void, Never>
    }

    private var pending: [PendingJob] = []
    private var active: ActiveJob?
    private var completed: [UUID: [IndexingJobKind: Date]] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var sequence = 0
    private var wakeTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private let now: Clock
    private let sleep: Sleeper

    init(
        now: @escaping Clock = Date.init,
        sleep: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.now = now
        self.sleep = sleep
    }

    var isIdle: Bool {
        active == nil && pending.isEmpty
    }

    var retainedWorkflowCount: Int { completed.count }
    var retainedCancellationCount: Int { cancelledIDs.count }

    func contains(_ kind: IndexingJobKind) -> Bool {
        active?.job.kind == kind || pending.contains { $0.job.kind == kind }
    }

    func enqueue(_ job: IndexingJob) {
        sequence += 1
        pending.append(PendingJob(
            job: job,
            enqueuedAt: now(),
            sequence: sequence
        ))
        scheduleNextIfNeeded()
    }

    func cancel(_ kind: IndexingJobKind) {
        let removed = pending.filter { $0.job.kind == kind }
        pending.removeAll { $0.job.kind == kind }
        for pendingJob in removed {
            cancelPendingDependents(
                of: pendingJob.job.kind,
                workflowID: pendingJob.job.workflowID
            )
        }

        if active?.job.kind == kind, let active {
            cancelledIDs.insert(active.job.id)
            active.task.cancel()
            cancelPendingDependents(of: active.job.kind, workflowID: active.job.workflowID)
        }
        pruneCompletedWorkflows()
        scheduleNextIfNeeded()
        finishIdleWaitersIfNeeded()
    }

    func cancelAll() {
        pending.removeAll()
        wakeTask?.cancel()
        wakeTask = nil
        if let active {
            cancelledIDs.insert(active.job.id)
            active.task.cancel()
        }
        pruneCompletedWorkflows()
        finishIdleWaitersIfNeeded()
    }

    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func scheduleNextIfNeeded() {
        wakeTask?.cancel()
        wakeTask = nil

        if let active {
            schedulePreemptionIfNeeded(for: active)
            return
        }

        let currentDate = now()
        let ready = pending.filter { candidate in
            guard let eligibleAt = eligibleAt(for: candidate) else { return false }
            return eligibleAt <= currentDate
        }

        if let next = ready.max(by: { lhs, rhs in
            if lhs.job.priority != rhs.job.priority {
                return lhs.job.priority < rhs.job.priority
            }
            return lhs.sequence > rhs.sequence
        }) {
            pending.removeAll { $0.job.id == next.job.id }
            start(next.job)
            return
        }

        guard let nextWake = pending.compactMap(eligibleAt(for:)).min() else {
            finishIdleWaitersIfNeeded()
            return
        }
        let nanoseconds = UInt64(max(0, nextWake.timeIntervalSince(currentDate)) * 1_000_000_000)
        wakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.wakeTask = nil
            self.scheduleNextIfNeeded()
        }
    }

    private func start(_ job: IndexingJob) {
        let task = Task { [weak self] in
            guard !Task.isCancelled else {
                self?.complete(job, outcome: .cancelled)
                return
            }
            let outcome = await job.operation()
            self?.complete(job, outcome: outcome)
        }
        active = ActiveJob(job: job, task: task)
        scheduleNextIfNeeded()
    }

    private func complete(_ job: IndexingJob, outcome: IndexingJobOutcome) {
        guard active?.job.id == job.id else { return }
        active = nil
        let wasCancelled = cancelledIDs.remove(job.id) != nil
        if !wasCancelled, outcome == .completed, !Task.isCancelled {
            completed[job.workflowID, default: [:]][job.kind] = now()
        } else {
            cancelPendingDependents(of: job.kind, workflowID: job.workflowID)
        }
        scheduleNextIfNeeded()
        pruneCompletedWorkflows()
        finishIdleWaitersIfNeeded()
    }

    private func finishIdleWaitersIfNeeded() {
        guard isIdle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func eligibleAt(for pendingJob: PendingJob) -> Date? {
        let workflowCompletions = completed[pendingJob.job.workflowID, default: [:]]
        let dependencyDates = pendingJob.job.dependencies.compactMap { workflowCompletions[$0] }
        guard dependencyDates.count == pendingJob.job.dependencies.count else { return nil }
        let dependencyCompletion = dependencyDates.max() ?? pendingJob.enqueuedAt
        return dependencyCompletion.addingTimeInterval(max(0, pendingJob.job.delayAfterDependencies))
    }

    private func schedulePreemptionIfNeeded(for activeJob: ActiveJob) {
        guard !cancelledIDs.contains(activeJob.job.id),
              activeJob.job.kind == .enrichPhotos || activeJob.job.kind == .geocodeMedia else {
            return
        }
        let userJobs = pending.filter { $0.job.priority == .userInitiated }
        guard let nextUserEligibility = userJobs.compactMap(eligibleAt(for:)).min() else { return }
        let currentDate = now()
        if nextUserEligibility <= currentDate {
            cancelledIDs.insert(activeJob.job.id)
            activeJob.task.cancel()
            cancelPendingDependents(
                of: activeJob.job.kind,
                workflowID: activeJob.job.workflowID
            )
            return
        }

        let nanoseconds = UInt64(
            max(0, nextUserEligibility.timeIntervalSince(currentDate)) * 1_000_000_000
        )
        wakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.wakeTask = nil
            self.scheduleNextIfNeeded()
        }
    }

    private func cancelPendingDependents(of kind: IndexingJobKind, workflowID: UUID) {
        var cancelledKinds: Set<IndexingJobKind> = [kind]
        var foundDependent = true
        while foundDependent {
            foundDependent = false
            for candidate in pending where candidate.job.workflowID == workflowID {
                if !candidate.job.dependencies.isDisjoint(with: cancelledKinds),
                   cancelledKinds.insert(candidate.job.kind).inserted {
                    foundDependent = true
                }
            }
        }
        cancelledKinds.remove(kind)
        pending.removeAll {
            $0.job.workflowID == workflowID && cancelledKinds.contains($0.job.kind)
        }
    }

    private func pruneCompletedWorkflows() {
        let referenced = Set(pending.map(\.job.workflowID) + [active?.job.workflowID].compactMap { $0 })
        completed = completed.filter { referenced.contains($0.key) }
    }
}
