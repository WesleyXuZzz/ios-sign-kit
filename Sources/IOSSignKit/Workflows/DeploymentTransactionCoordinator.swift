import Foundation

@MainActor
final class DeploymentTransactionCoordinator {
    struct TerminationSnapshot {
        let deployment: RunningDeploy?
        let context: DeploymentContext?
    }

    private var task: Task<Void, Never>?
    private var cancelledTasks: [UUID: Task<Void, Never>] = [:]
    private var deployment: RunningDeploy?
    private var context: DeploymentContext?
    private var runningOrSettledWaiters:
        [CheckedContinuation<Void, Never>] = []
    private(set) var isAutomaticPreflight = false

    var hasActiveTask: Bool {
        task != nil
    }

    var hasRunningDeployment: Bool {
        deployment != nil
    }

    var runningDeployment: RunningDeploy? {
        deployment
    }

    func begin(
        isAutomatic: Bool,
        operation: @escaping @MainActor () async -> Void
    ) {
        cancelPreflight()
        isAutomaticPreflight = isAutomatic
        task = Task { @MainActor in
            await operation()
        }
    }

    func markRunning(
        _ deployment: RunningDeploy,
        context: DeploymentContext
    ) {
        isAutomaticPreflight = false
        self.deployment = deployment
        self.context = context
        resumeRunningOrSettledWaiters()
    }

    func clearPreflight() {
        isAutomaticPreflight = false
        if let task {
            retainUntilSettled(task)
        }
        task = nil
        resumeRunningOrSettledWaiters()
    }

    func cancelPreflight() {
        if let task {
            task.cancel()
            retainUntilSettled(task)
        }
        if deployment == nil {
            task = nil
            context = nil
        }
        isAutomaticPreflight = false
    }

    func requestPreflightCancellation() {
        task?.cancel()
        isAutomaticPreflight = false
    }

    func requestCancellation() {
        deployment?.cancel()
        task?.cancel()
    }

    func settle() {
        isAutomaticPreflight = false
        deployment = nil
        context = nil
        if let task {
            retainUntilSettled(task)
        }
        task = nil
        resumeRunningOrSettledWaiters()
    }

    func waitUntilRunningOrSettled() async {
        guard deployment == nil, task != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            runningOrSettledWaiters.append(continuation)
        }
    }

    private func resumeRunningOrSettledWaiters() {
        let waiters = runningOrSettledWaiters
        runningOrSettledWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilSettled() async {
        let activeTask = task
        let olderTasks = Array(cancelledTasks.values)
        if let activeTask {
            await activeTask.value
        }
        for olderTask in olderTasks {
            await olderTask.value
        }
    }

    func detachForTermination() -> TerminationSnapshot {
        task?.cancel()
        let snapshot = TerminationSnapshot(
            deployment: deployment,
            context: context
        )
        settle()
        return snapshot
    }

    private func retainUntilSettled(_ task: Task<Void, Never>) {
        let identifier = UUID()
        cancelledTasks[identifier] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.cancelledTasks.removeValue(forKey: identifier)
        }
    }
}
