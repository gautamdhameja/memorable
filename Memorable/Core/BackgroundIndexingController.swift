@preconcurrency import BackgroundTasks
import Foundation
import UIKit

enum IndexingBackgroundExecutionState: Equatable {
    case foreground
    case continuingInBackground
    case pausedAwaitingForeground
}

enum BackgroundIndexingLaunchResult: Equatable {
    case completed
    case running
    /// A permanent condition such as an unsupported device or revoked Photos
    /// permission. Completing the current task is correct; retrying would only
    /// ask the system to launch work that cannot succeed.
    case terminalFailure
    /// A recoverable setup failure such as model/database contention. Preserve
    /// the checkpoint and ask BackgroundTasks for a later recovery launch.
    case retryableFailure
}

enum BackgroundIndexingIdentifiers {
    static func processing(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).indexing.processing"
    }

    static func continuedWildcard(bundleIdentifier: String) -> String {
        "\(bundleIdentifier).indexing.continued.*"
    }

    static func continued(bundleIdentifier: String, runID: UUID) -> String {
        "\(bundleIdentifier).indexing.continued.\(runID.uuidString)"
    }
}

@MainActor
protocol BackgroundIndexingTaskHandle: AnyObject {
    func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void)
    func setTaskCompleted(success: Bool)
    func updateProgress(completedUnits: Int64, title: String, subtitle: String)
}

@MainActor
private final class AppleBackgroundIndexingTaskHandle: BackgroundIndexingTaskHandle {
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func setExpirationHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        task.expirationHandler = { @Sendable in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    handler()
                }
            } else {
                // Apple does not document the expiration callback queue. Block
                // it briefly so cancellation and task completion happen before
                // the system suspends the process.
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        handler()
                    }
                }
            }
        }
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }

    func updateProgress(completedUnits: Int64, title: String, subtitle: String) {
        guard #available(iOS 26.0, *),
              let continuedTask = task as? BGContinuedProcessingTask else { return }
        continuedTask.progress.totalUnitCount = ContinuedIndexingProgress.totalUnits
        continuedTask.progress.completedUnitCount = completedUnits
        continuedTask.updateTitle(title, subtitle: subtitle)
    }
}

enum ContinuedProcessingSubmissionPolicy {
    static func shouldSubmit(
        isApplicationActive: Bool,
        isUserInitiated: Bool
    ) -> Bool {
        isApplicationActive && isUserInitiated
    }
}

enum ContinuedProcessingRegistration {
    static func registerAndSubmit(
        identifier: String,
        register: (String) -> Bool,
        submit: (String) throws -> Void
    ) rethrows -> Bool {
        guard !identifier.hasSuffix(".*") else { return false }
        guard register(identifier) else { return false }
        try submit(identifier)
        return true
    }
}

/// Owns the system assertions that let an initial, user-requested indexing run
/// survive a scene transition. The indexing database remains the source of
/// truth: system tasks only resume the same idempotent workflow and never carry
/// media or embeddings themselves.
@MainActor
final class BackgroundIndexingController {
    typealias ResumeHandler = @MainActor @Sendable () async -> BackgroundIndexingLaunchResult
    typealias ExpirationHandler = @MainActor @Sendable () -> Void

    static let shared = BackgroundIndexingController()

    private var resumeHandler: ResumeHandler?
    private var expirationHandler: ExpirationHandler?
    private var activeSystemTask: (any BackgroundIndexingTaskHandle)?
    private var activeRunner: Task<Void, Never>?
    private var continuedRequestIdentifier: String?
    private var lastProgressUnits: Int64?
    private var lastProgressSubtitle: String?
    private var didRegister = false
    private let recoverySchedulingObserver: (() -> Void)?

    init(recoverySchedulingObserver: (() -> Void)? = nil) {
        self.recoverySchedulingObserver = recoverySchedulingObserver
    }

    var hasActiveSystemTask: Bool {
        activeSystemTask != nil
    }

    func configure(
        resume: @escaping ResumeHandler,
        expire: @escaping ExpirationHandler
    ) {
        resumeHandler = resume
        expirationHandler = expire
    }

    func registerLaunchHandlers() {
        guard !didRegister else { return }
        didRegister = true

        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingIdentifier,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                BackgroundIndexingController.shared.handleLaunch(task)
            }
        }
        if !processingRegistered {
            logger.error("Background indexing processing handler registration failed")
        } else {
            logger.info("Background indexing processing handler registered")
        }
    }

    func initialIndexingDidStart(
        isApplicationActive: Bool,
        isUserInitiated: Bool
    ) {
        scheduleProcessingRecovery()
        guard ContinuedProcessingSubmissionPolicy.shouldSubmit(
            isApplicationActive: isApplicationActive,
            isUserInitiated: isUserInitiated
        ) else { return }
        if #available(iOS 26.0, *) {
            scheduleContinuedProcessing()
        }
    }

    func initialIndexingWasInterrupted() {
        scheduleProcessingRecovery()
        finishActiveTask(success: false)
    }

    func initialIndexingDidComplete() {
        finishActiveTask(success: true)
        cancelPendingRequests()
    }

    func initialIndexingWasStopped() {
        finishActiveTask(success: false)
        cancelPendingRequests()
    }

    func update(progress: IndexingProgress) {
        guard let task = activeSystemTask else { return }
        let completedUnits = ContinuedIndexingProgress.completedUnits(for: progress)
        let subtitle = Self.subtitle(for: progress)
        guard completedUnits != lastProgressUnits || subtitle != lastProgressSubtitle else { return }
        lastProgressUnits = completedUnits
        lastProgressSubtitle = subtitle
        task.updateProgress(
            completedUnits: completedUnits,
            title: "Indexing your library",
            subtitle: subtitle
        )
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.blockdeep.memorable"
    }

    private var processingIdentifier: String {
        BackgroundIndexingIdentifiers.processing(bundleIdentifier: bundleIdentifier)
    }

    private func handleLaunch(_ task: BGTask) {
        handleLaunch(AppleBackgroundIndexingTaskHandle(task: task))
    }

    @discardableResult
    func handleLaunch(_ task: any BackgroundIndexingTaskHandle) -> Task<Void, Never>? {
        guard activeSystemTask == nil else {
            task.setTaskCompleted(success: false)
            return nil
        }
        activeSystemTask = task
        task.setExpirationHandler { [weak self] in
            self?.expireActiveTask()
        }
        logger.info("Background indexing task launched")
        task.updateProgress(
            completedUnits: 0,
            title: "Indexing your library",
            subtitle: "Preparing your library"
        )
        lastProgressUnits = 0
        lastProgressSubtitle = "Preparing your library"

        let runner = Task { @MainActor [weak self, weak task] in
            guard let self, let task else { return }
            guard let resumeHandler else {
                guard activeSystemTask === task else { return }
                finishActiveTask(success: false)
                return
            }
            let result = await resumeHandler()
            guard !Task.isCancelled, activeSystemTask === task else { return }
            switch result {
            case .completed:
                finishActiveTask(success: true)
            case .running:
                break
            case .terminalFailure:
                finishActiveTask(success: false)
            case .retryableFailure:
                scheduleProcessingRecovery()
                finishActiveTask(success: false)
            }
        }
        activeRunner = runner
        return runner
    }

    private func expireActiveTask() {
        logger.info("Background indexing task expired; cancelling work")
        expirationHandler?()
        scheduleProcessingRecovery()
        finishActiveTask(success: false)
    }

    private func finishActiveTask(success: Bool) {
        activeRunner?.cancel()
        activeRunner = nil
        guard let task = activeSystemTask else { return }
        activeSystemTask = nil
        lastProgressUnits = nil
        lastProgressSubtitle = nil
        task.setTaskCompleted(success: success)
        logger.info("Background indexing task completed success=\(success)")
    }

    private func scheduleProcessingRecovery() {
        recoverySchedulingObserver?()
        #if targetEnvironment(simulator)
        return
        #else
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Background indexing recovery request submitted")
        } catch {
            logger.error("Unable to schedule background indexing recovery: \(error.safeDiagnosticCode)")
        }
        #endif
    }

    @available(iOS 26.0, *)
    private func scheduleContinuedProcessing() {
        #if targetEnvironment(simulator)
        return
        #else
        if let continuedRequestIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedRequestIdentifier)
        }
        let identifier = BackgroundIndexingIdentifiers.continued(
            bundleIdentifier: bundleIdentifier,
            runID: UUID()
        )
        do {
            let registered = try ContinuedProcessingRegistration.registerAndSubmit(
                identifier: identifier,
                register: { registeredIdentifier in
                    BGTaskScheduler.shared.register(
                        forTaskWithIdentifier: registeredIdentifier,
                        using: .main
                    ) { task in
                        MainActor.assumeIsolated {
                            BackgroundIndexingController.shared.handleLaunch(task)
                        }
                    }
                },
                submit: { submittedIdentifier in
                    let request = BGContinuedProcessingTaskRequest(
                        identifier: submittedIdentifier,
                        title: "Indexing your library",
                        subtitle: "Making your photos and videos searchable."
                    )
                    try BGTaskScheduler.shared.submit(request)
                }
            )
            guard registered else {
                logger.error("Continued indexing handler registration failed")
                return
            }
            continuedRequestIdentifier = identifier
            logger.info("Continued indexing request submitted")
        } catch {
            logger.error("Unable to schedule continued indexing: \(error.safeDiagnosticCode)")
        }
        #endif
    }

    private func cancelPendingRequests() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
        if let continuedRequestIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedRequestIdentifier)
            self.continuedRequestIdentifier = nil
        }
    }

    private static func subtitle(for progress: IndexingProgress) -> String {
        switch progress.phase {
        case .photos:
            return "Making your photos searchable · \(Int(progress.percentage))%"
        case .videos:
            return "Adding your videos · \(Int(progress.percentage))%"
        case .enrichment:
            return "Finishing your search index"
        case .idle:
            return "Preparing your library"
        }
    }
}

@MainActor
final class MemorableAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundIndexingController.shared.registerLaunchHandlers()
        return true
    }
}
