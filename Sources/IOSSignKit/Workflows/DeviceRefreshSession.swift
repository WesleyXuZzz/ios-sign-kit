import Foundation

@MainActor
final class DeviceRefreshSession {
    private var task: Task<Void, Never>?
    private var taskIdentifier: UUID?
    private var supersededTasks: [UUID: Task<Void, Never>] = [:]
    private(set) var currentSequence: Int = 0

    var isRunning: Bool {
        task != nil
    }

    var nextSequence: Int {
        currentSequence &+ 1
    }

    @discardableResult
    func begin() -> Int {
        currentSequence &+= 1
        if let task {
            task.cancel()
            retainUntilSettled(task)
        }
        task = nil
        taskIdentifier = nil
        return currentSequence
    }

    func run(
        sequence: Int,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard sequence == currentSequence else {
            return
        }
        if let task {
            task.cancel()
            retainUntilSettled(task)
        }
        let identifier = UUID()
        taskIdentifier = identifier
        task = Task { @MainActor [weak self] in
            await operation()
            self?.finishTask(identifier: identifier)
        }
    }

    @discardableResult
    func complete(sequence: Int) -> Bool {
        guard sequence == currentSequence else {
            return false
        }
        if let task {
            retainUntilSettled(task)
        }
        task = nil
        taskIdentifier = nil
        return true
    }

    func invalidate() {
        currentSequence &+= 1
        if let task {
            task.cancel()
            retainUntilSettled(task)
        }
        task = nil
        taskIdentifier = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        taskIdentifier = nil
        supersededTasks.values.forEach { $0.cancel() }
    }

    func waitUntilSettled() async {
        let activeTask = task
        let olderTasks = Array(supersededTasks.values)
        if let activeTask {
            await activeTask.value
        }
        for olderTask in olderTasks {
            await olderTask.value
        }
    }

    func waitUntilCurrentSettled() async {
        await task?.value
    }

    func cancelAndWait() async {
        let activeTask = task
        let olderTasks = Array(supersededTasks.values)
        activeTask?.cancel()
        olderTasks.forEach { $0.cancel() }
        task = nil
        taskIdentifier = nil
        if let activeTask {
            await activeTask.value
        }
        for olderTask in olderTasks {
            await olderTask.value
        }
    }

    func isCurrent(_ sequence: Int) -> Bool {
        sequence == currentSequence
    }

    private func retainUntilSettled(_ task: Task<Void, Never>) {
        let identifier = UUID()
        supersededTasks[identifier] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.supersededTasks.removeValue(forKey: identifier)
        }
    }

    private func finishTask(identifier: UUID) {
        guard taskIdentifier == identifier else {
            return
        }
        task = nil
        taskIdentifier = nil
    }
}

enum EnvironmentRefreshMode: Equatable, Sendable {
    case backgroundPoll
    case connectionConfirmation
    case appMetadataRetry
    case automaticRecoveryCheck
    case manualDeepCheck

    func scanOptions(for config: AppConfig) -> DeviceScanOptions {
        switch self {
        case .backgroundPoll:
            return DeviceScanOptions.polling(
                preferredDeviceID: config.preferredDeviceID,
                preferredDeviceName: config.preferredDeviceName
            )
        case .connectionConfirmation, .appMetadataRetry:
            return DeviceScanOptions.automaticRecovery(
                preferredDeviceID: config.preferredDeviceID,
                preferredDeviceName: config.preferredDeviceName
            )
        case .automaticRecoveryCheck:
            return DeviceScanOptions.automaticRecovery(
                preferredDeviceID: config.preferredDeviceID,
                preferredDeviceName: config.preferredDeviceName
            )
        case .manualDeepCheck:
            return DeviceScanOptions.reliable(
                preferredDeviceID: config.preferredDeviceID,
                preferredDeviceName: config.preferredDeviceName
            )
        }
    }

    func shouldInspectInstalledApp(
        hasKnownExpiry: Bool,
        hasConfirmedInstallation: Bool
    ) -> Bool {
        switch self {
        case .backgroundPoll:
            return true
        case .appMetadataRetry:
            return true
        case .connectionConfirmation:
            return false
        case .automaticRecoveryCheck:
            return true
        case .manualDeepCheck:
            return true
        }
    }

    var treatsScanFailureAsTransient: Bool {
        switch self {
        case .backgroundPoll, .connectionConfirmation, .appMetadataRetry, .automaticRecoveryCheck:
            return true
        case .manualDeepCheck:
            return false
        }
    }

    var targetScanPurpose: TargetScanPurpose {
        switch self {
        case .backgroundPoll:
            return .background
        case .connectionConfirmation,
             .appMetadataRetry,
             .automaticRecoveryCheck:
            return .recovery
        case .manualDeepCheck:
            return .interactive
        }
    }

    var refreshRequestKind: RefreshRequestKind {
        switch self {
        case .backgroundPoll:
            return .background
        case .connectionConfirmation,
             .appMetadataRetry,
             .automaticRecoveryCheck:
            return .recovery
        case .manualDeepCheck:
            return .manual
        }
    }
}

enum EnvironmentRefreshPresentation: Equatable, Sendable {
    case foreground
    case background
}

struct DeviceRefreshSnapshot: Sendable {
    let environmentStatus: EnvironmentStatus
    let availableDevices: [DeviceInfo]
    let matchedDevice: DeviceInfo?
    let deviceMatchResult: DeviceMatchResult
    let installedAppInspectionOutcome: InstalledAppInspectionOutcome
    let treatsScanFailureAsTransient: Bool
    let refreshMode: EnvironmentRefreshMode
    let scanResult: DeviceScanResult?
    let targetObservation: TargetDeviceObservation?
    let identityPersistenceCandidate:
        DeviceIdentityPersistenceCandidate?
    let policyGeneration: UInt64
    let observationGeneration: UInt64
    let allowsCriticalActions: Bool
    let usedCachedActionEvidence: Bool
    let xcodeCacheUpdate: XcodeValidationCacheUpdate?
    let installedAppCacheUpdate: InstalledAppCacheUpdate?
    let installedAppCacheInvalidationKey: InstalledAppCacheKey?
    let errorMessage: String?
}

struct XcodeValidationCacheUpdate: Sendable {
    let key: XcodeValidationCacheKey
    let entry: XcodeValidationCacheEntry
}

struct InstalledAppCacheUpdate: Sendable {
    let key: InstalledAppCacheKey
    let entry: InstalledAppCacheEntry
}

enum InstalledAppInspectionOutcome: Sendable {
    case notRequested
    case found(InstalledAppInfo)
    case notInstalled
    case failed(String)

    var didRunInspection: Bool {
        if case .notRequested = self {
            return false
        }
        return true
    }

    var isNotInstalled: Bool {
        if case .notInstalled = self {
            return true
        }
        return false
    }

    func shouldSuppressActions(hasUsableExpiry: Bool) -> Bool {
        switch self {
        case .notRequested:
            return false
        case .found:
            return !hasUsableExpiry
        case .notInstalled, .failed:
            return true
        }
    }
}

struct InstalledAppStateReduction {
    let expiryEvidenceVerified: Bool
    let failureMessage: String?
}
