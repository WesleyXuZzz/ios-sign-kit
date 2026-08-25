import Foundation

struct DeploymentContext: Sendable {
    let generation: Int
    let config: AppConfig
    let device: DeviceInfo
    let deviceDetectionRollout: DeviceDetectionRolloutState
    let source: RefreshTriggerSource
    let profileRefreshMode: ProvisioningProfileRefreshMode
    let installationIdentity: InstallationIdentitySnapshot
}
enum PostDeployInspectionResult: Sendable {
    case completed(InstalledAppInfo?)
    case failed
    case deadlineReached
    case cancelled
}

final class DeployOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private let delivery: @MainActor @Sendable (String, Bool) -> Void
    private let maximumPendingCharacters: Int
    private var pendingText = ""
    private var latestChunkWasError = false
    private var deliveryLoopScheduled = false
    private var omittedCharacterCount = 0
    private var isInvalidated = false

    init(
        maximumPendingCharacters: Int = 48_000,
        delivery: @escaping @MainActor @Sendable (String, Bool) -> Void
    ) {
        self.maximumPendingCharacters = maximumPendingCharacters
        self.delivery = delivery
    }

    func enqueue(_ text: String, isError: Bool) {
        guard !text.isEmpty else {
            return
        }

        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        pendingText.append(text)
        latestChunkWasError = isError
        if pendingText.count > maximumPendingCharacters {
            let excess = pendingText.count - maximumPendingCharacters
            omittedCharacterCount += excess
            pendingText = String(pendingText.suffix(maximumPendingCharacters))
        }
        let shouldStartDeliveryLoop = !deliveryLoopScheduled
        deliveryLoopScheduled = true
        lock.unlock()

        guard shouldStartDeliveryLoop else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.runDeliveryLoop()
        }
    }

    @MainActor
    func flushNow() {
        guard let batch = takeBatch(finishesLoopWhenEmpty: false) else {
            return
        }
        delivery(batch.text, batch.isError)
    }

    @MainActor
    func invalidate() {
        lock.lock()
        isInvalidated = true
        pendingText = ""
        omittedCharacterCount = 0
        deliveryLoopScheduled = false
        lock.unlock()
    }

    @MainActor
    private func runDeliveryLoop() async {
        while true {
            try? await Task.sleep(for: .milliseconds(120))
            guard let batch = takeBatch(finishesLoopWhenEmpty: true) else {
                return
            }
            delivery(batch.text, batch.isError)
        }
    }

    private func takeBatch(
        finishesLoopWhenEmpty: Bool
    ) -> (text: String, isError: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalidated else {
            return nil
        }
        guard !pendingText.isEmpty else {
            if finishesLoopWhenEmpty {
                deliveryLoopScheduled = false
            }
            return nil
        }

        let omission = omittedCharacterCount > 0
            ? "… 已省略 \(omittedCharacterCount) 个实时输出字符 …\n"
            : ""
        let batch = (omission + pendingText, latestChunkWasError)
        pendingText = ""
        omittedCharacterCount = 0
        return batch
    }
}

struct CommittedDeploymentStart {
    let deployment: RunningDeploy
}

final class PostDeployInspectionRace: @unchecked Sendable {
    static let deadlineQueue = DispatchQueue(
        label: "iossignkit.post-deploy-inspection-deadline",
        qos: .userInitiated
    )

    private let lock = NSLock()
    private var continuation: CheckedContinuation<PostDeployInspectionResult, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var deadlineWorkItem: DispatchWorkItem?
    private var resolvedResult: PostDeployInspectionResult?

    func makeDeadlineWorkItem() -> DispatchWorkItem {
        DispatchWorkItem { @Sendable [weak self] in
            self?.finish(.deadlineReached)
        }
    }

    func install(
        continuation: CheckedContinuation<PostDeployInspectionResult, Never>
    ) {
        lock.lock()
        if let resolvedResult {
            lock.unlock()
            continuation.resume(returning: resolvedResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func install(
        inspectionTask: Task<Void, Never>,
        deadlineWorkItem: DispatchWorkItem
    ) {
        lock.lock()
        let wasAlreadyResolved = resolvedResult != nil
        if !wasAlreadyResolved {
            self.inspectionTask = inspectionTask
            self.deadlineWorkItem = deadlineWorkItem
        }
        lock.unlock()

        if wasAlreadyResolved {
            inspectionTask.cancel()
            deadlineWorkItem.cancel()
        }
    }

    func finish(_ result: PostDeployInspectionResult) {
        lock.lock()
        guard resolvedResult == nil else {
            lock.unlock()
            return
        }
        resolvedResult = result
        let continuation = self.continuation
        self.continuation = nil
        let inspectionTask = self.inspectionTask
        let deadlineWorkItem = self.deadlineWorkItem
        self.inspectionTask = nil
        self.deadlineWorkItem = nil
        lock.unlock()

        inspectionTask?.cancel()
        deadlineWorkItem?.cancel()
        continuation?.resume(returning: result)
    }
}
