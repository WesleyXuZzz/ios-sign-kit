import Foundation

enum AutomaticRefreshWaitBlocker: String, Equatable, Sendable {
    case deviceLocked
    case lockStateUnknown
    case destinationPreparation
}

enum AutomaticRefreshWaitProbeOutcome: Equatable, Sendable {
    case stillWaiting(AutomaticRefreshWaitBlocker)
    case resume
    case cancel
}

struct AutomaticRefreshWaitKey: Hashable, Sendable {
    let targetGeneration: Int
    let deviceID: String
    let bundleID: String
    let installationIdentity: InstallationIdentitySnapshot
    let source: RefreshTriggerSource
}

struct AutomaticRefreshWaitPolicy: Equatable, Sendable {
    let lockedProbeInterval: Duration
    let unknownProbeInterval: Duration
    let destinationProbeInterval: Duration
    let prolongedProbeInterval: Duration
    let rapidProbeWindow: Duration
    let wakeFirstProbeDelay: Duration
    let wakeSecondProbeDelay: Duration
}

enum AutomaticRefreshWaitTransition: String, Equatable, Sendable {
    case waitingLocked
    case waitingForLockState
    case waitingForDestination
    case wakeObserved
    case unlockObserved
    case preflightDeferred
    case resumed
    case cancelled
}

@MainActor
final class AutomaticRefreshWaitCoordinator {
    typealias Probe = @MainActor () async -> AutomaticRefreshWaitProbeOutcome
    typealias Resume = @MainActor () -> Bool
    typealias Transition = @MainActor (AutomaticRefreshWaitTransition) -> Void

    private struct Request {
        let key: AutomaticRefreshWaitKey
        let operationID: UUID
        let startedAt: Date
        var blocker: AutomaticRefreshWaitBlocker
        let probe: Probe
        let resume: Resume
        let transition: Transition
        var hasPendingWakeFollowup: Bool
    }

    private let policy: AutomaticRefreshWaitPolicy
    private let scheduler: RefreshScheduler
    private var request: Request?
    private var task: Task<Void, Never>?
    private var isProbeInFlight = false
    private var pendingProbeDelay: Duration?

    var isWaiting: Bool { request != nil }

    init(
        policy: AutomaticRefreshWaitPolicy,
        scheduler: RefreshScheduler = .continuous
    ) {
        self.policy = policy
        self.scheduler = scheduler
    }

    @discardableResult
    func wait(
        key: AutomaticRefreshWaitKey,
        blocker: AutomaticRefreshWaitBlocker,
        probe: @escaping Probe,
        resume: @escaping Resume,
        transition: @escaping Transition = { _ in }
    ) -> Bool {
        if request?.key == key {
            return false
        }

        cancel(recordTransition: request != nil)
        let operationID = UUID()
        request = Request(
            key: key,
            operationID: operationID,
            startedAt: scheduler.wallNow(),
            blocker: blocker,
            probe: probe,
            resume: resume,
            transition: transition,
            hasPendingWakeFollowup: false
        )
        emit(Self.transition(for: blocker), operationID: operationID)
        requestProbe(
            operationID: operationID,
            after: delay(for: blocker)
        )
        return true
    }

    func observeWake() {
        guard var request else {
            return
        }
        request.hasPendingWakeFollowup = true
        self.request = request
        emit(.wakeObserved, operationID: request.operationID)
        requestProbe(
            operationID: request.operationID,
            after: policy.wakeFirstProbeDelay
        )
    }

    func probeNow() {
        guard let operationID = request?.operationID else {
            return
        }
        requestProbe(operationID: operationID, after: .zero)
    }

    func waitUntilCurrentProbeSettled() async {
        await task?.value
    }

    func cancel() {
        cancel(recordTransition: true)
    }

    private func cancel(recordTransition: Bool) {
        if recordTransition, let operationID = request?.operationID {
            emit(.cancelled, operationID: operationID)
        }
        task?.cancel()
        task = nil
        pendingProbeDelay = nil
        request = nil
    }

    private func requestProbe(
        operationID: UUID,
        after delay: Duration
    ) {
        guard request?.operationID == operationID else {
            return
        }
        if isProbeInFlight {
            if let pendingProbeDelay {
                self.pendingProbeDelay = min(pendingProbeDelay, delay)
            } else {
                pendingProbeDelay = delay
            }
            return
        }
        task?.cancel()
        scheduleProbe(operationID: operationID, after: delay)
    }

    private func scheduleProbe(operationID: UUID, after delay: Duration) {
        let sleep = scheduler.sleep
        task = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.request?.operationID == operationID,
                  let probe = self.request?.probe else {
                return
            }

            self.isProbeInFlight = true
            let outcome = await probe()
            self.isProbeInFlight = false
            let pendingDelay = self.pendingProbeDelay
            self.pendingProbeDelay = nil
            guard self.request?.operationID == operationID else {
                if let pendingDelay,
                   let pendingOperationID = self.request?.operationID {
                    self.scheduleProbe(
                        operationID: pendingOperationID,
                        after: pendingDelay
                    )
                }
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self.task = nil
            self.handle(
                outcome,
                operationID: operationID,
                pendingProbeDelay: pendingDelay
            )
        }
    }

    private func handle(
        _ outcome: AutomaticRefreshWaitProbeOutcome,
        operationID: UUID,
        pendingProbeDelay: Duration?
    ) {
        guard var request, request.operationID == operationID else {
            return
        }

        switch outcome {
        case .cancel:
            cancel(recordTransition: true)
        case .resume:
            emit(.unlockObserved, operationID: operationID)
            guard request.resume() else {
                emit(.preflightDeferred, operationID: operationID)
                let nextDelay = pendingProbeDelay ?? nextDelay(for: &request)
                self.request = request
                requestProbe(
                    operationID: operationID,
                    after: nextDelay
                )
                return
            }
            guard self.request?.operationID == operationID else {
                return
            }
            emit(.resumed, operationID: operationID)
            task = nil
            self.request = nil
        case .stillWaiting(let blocker):
            request.blocker = blocker
            let nextDelay = pendingProbeDelay ?? nextDelay(for: &request)
            self.request = request
            emit(Self.transition(for: blocker), operationID: operationID)
            requestProbe(operationID: operationID, after: nextDelay)
        }
    }

    private func nextDelay(for request: inout Request) -> Duration {
        if request.hasPendingWakeFollowup {
            request.hasPendingWakeFollowup = false
            return max(
                policy.wakeSecondProbeDelay
                    - policy.wakeFirstProbeDelay,
                .zero
            )
        }
        return delay(
            for: request.blocker,
            startedAt: request.startedAt
        )
    }

    private func delay(
        for blocker: AutomaticRefreshWaitBlocker,
        startedAt: Date? = nil
    ) -> Duration {
        if let startedAt,
           scheduler.wallNow().timeIntervalSince(startedAt)
                >= policy.rapidProbeWindow.timeInterval {
            return policy.prolongedProbeInterval
        }
        switch blocker {
        case .deviceLocked:
            return policy.lockedProbeInterval
        case .lockStateUnknown:
            return policy.unknownProbeInterval
        case .destinationPreparation:
            return policy.destinationProbeInterval
        }
    }

    private func emit(
        _ transition: AutomaticRefreshWaitTransition,
        operationID: UUID
    ) {
        guard let request, request.operationID == operationID else {
            return
        }
        request.transition(transition)
    }

    private static func transition(
        for blocker: AutomaticRefreshWaitBlocker
    ) -> AutomaticRefreshWaitTransition {
        switch blocker {
        case .deviceLocked:
            return .waitingLocked
        case .lockStateUnknown:
            return .waitingForLockState
        case .destinationPreparation:
            return .waitingForDestination
        }
    }
}
