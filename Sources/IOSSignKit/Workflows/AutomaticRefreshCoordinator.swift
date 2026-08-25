import Foundation

@MainActor
final class AutomaticRefreshCoordinator {
    private let scheduler: RefreshScheduler
    private let waitCoordinator: AutomaticRefreshWaitCoordinator
    private var countdownTask: Task<Void, Never>?
    private var countdownIdentifier: UUID?

    init(
        scheduler: RefreshScheduler = .continuous,
        waitPolicy: AutomaticRefreshWaitPolicy
    ) {
        self.scheduler = scheduler
        self.waitCoordinator = AutomaticRefreshWaitCoordinator(
            policy: waitPolicy,
            scheduler: scheduler
        )
    }

    var isCountdownScheduled: Bool {
        countdownTask != nil
    }

    var isWaiting: Bool {
        waitCoordinator.isWaiting
    }

    @discardableResult
    func wait(
        key: AutomaticRefreshWaitKey,
        blocker: AutomaticRefreshWaitBlocker,
        probe: @escaping AutomaticRefreshWaitCoordinator.Probe,
        resume: @escaping AutomaticRefreshWaitCoordinator.Resume,
        transition: @escaping AutomaticRefreshWaitCoordinator.Transition = { _ in }
    ) -> Bool {
        waitCoordinator.wait(
            key: key,
            blocker: blocker,
            probe: probe,
            resume: resume,
            transition: transition
        )
    }

    func observeWake() {
        waitCoordinator.observeWake()
    }

    func probeNow() {
        waitCoordinator.probeNow()
    }

    func waitUntilCurrentProbeSettled() async {
        await waitCoordinator.waitUntilCurrentProbeSettled()
    }

    func cancelWait() {
        waitCoordinator.cancel()
    }

    func scheduleCountdown(
        seconds: Int,
        shouldContinue: @escaping @MainActor () -> Bool,
        onUpdate: @escaping @MainActor (Int?) -> Void,
        onReady: @escaping @MainActor () -> Void
    ) {
        cancelCountdown()
        let identifier = UUID()
        countdownIdentifier = identifier
        onUpdate(seconds)

        countdownTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.countdownIdentifier == identifier else {
                return
            }

            for remaining in stride(
                from: seconds,
                through: 1,
                by: -1
            ) {
                guard !Task.isCancelled,
                      self.countdownIdentifier == identifier,
                      shouldContinue() else {
                    self.cancelCountdown()
                    onUpdate(nil)
                    return
                }
                onUpdate(remaining)
                do {
                    try await self.scheduler.sleep(.seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.countdownIdentifier == identifier else {
                    return
                }
            }

            guard self.countdownIdentifier == identifier else {
                return
            }
            self.countdownTask = nil
            self.countdownIdentifier = nil
            onUpdate(nil)
            onReady()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownIdentifier = nil
    }
}
