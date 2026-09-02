import Foundation

enum AutomaticRefreshEventKind: String, Codable, Equatable, Sendable {
    case expiryDetected
    case waitingLocked
    case waitingForLockState
    case waitingForDestination
    case wakeObserved
    case unlockObserved
    case preflightStarted
    case preflightDeferred
    case resumed
    case deploymentCommitted
    case settled
    case cancelled
    case notificationScheduled
    case notificationDenied
    case notificationFailed
    case authorizationProceeded
    case authorizationDeferred
    case authorizationBlocked
}

enum AutomaticRefreshEventReason: String, Codable, Equatable, Sendable {
    case freshVerifiedAppOnExactDevice
    case passiveObservation
    case cachedActionEvidence
    case installationEvidenceUnavailable
    case degradedDeviceEvidence
    case criticalActionsDisabled
    case deviceEvidenceConflict
}

struct AutomaticRefreshEvent: Codable, Equatable, Sendable {
    let kind: AutomaticRefreshEventKind
    let occurredAt: Date
    let reason: AutomaticRefreshEventReason?

    init(
        kind: AutomaticRefreshEventKind,
        occurredAt: Date,
        reason: AutomaticRefreshEventReason? = nil
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.reason = reason
    }
}

struct AppState: Codable, Equatable {
    var lastSuccessAt: Date?
    var activeInstallationSuccessAt: Date?
    var lastPromptAt: Date?
    var lastAttemptAt: Date?
    var lastResult: RefreshResult?
    var lastErrorSummary: String?
    var lastDetectedExpiryAt: Date?
    var expirySource: ExpirySource?
    var lastExpiryVerifiedAt: Date?
    var lastAppInspectionAt: Date?
    var lastAppInspectionFailure: String?
    var currentDeviceStatus: DeviceStatus?
    var currentDeviceName: String?
    var currentDeviceOS: String?
    var lastDeviceSeenAt: Date?
    var lastDeviceScanSource: String?
    var lastDeviceScanFailure: String?
    var lastPairingAttemptAt: Date?
    var lastPairingDeviceID: String?
    var lastAutomaticAttemptAt: Date?
    var lastAutomaticRecoveryFailureAt: Date?
    var automaticRefreshEvents: [AutomaticRefreshEvent]
    var targetAppPresence: TargetAppPresence
    var targetAppBundleID: String?
    var targetDeviceID: String?
    var targetAppVersion: String?
    var targetAppBuildVersion: String?
    var targetAppURL: String?
    var isTargetAppExpiryEvidenceVerified: Bool
    var isDeployRunning: Bool
    var activeDeployProcessGroupID: Int32?
    var activeDeploymentToken: String?
    var deploymentRecoveryBlocked: Bool
    var commandRecoveryBlocked: Bool
    var lastLogPath: String?

    var processRecoveryBlocked: Bool {
        deploymentRecoveryBlocked || commandRecoveryBlocked
    }

    mutating func appendAutomaticRefreshEvent(
        _ kind: AutomaticRefreshEventKind,
        reason: AutomaticRefreshEventReason? = nil,
        occurredAt: Date = Date(),
        limit: Int = 50
    ) {
        automaticRefreshEvents.append(
            AutomaticRefreshEvent(
                kind: kind,
                occurredAt: occurredAt,
                reason: reason
            )
        )
        let normalizedLimit = max(limit, 1)
        if automaticRefreshEvents.count > normalizedLimit {
            automaticRefreshEvents.removeFirst(
                automaticRefreshEvents.count - normalizedLimit
            )
        }
    }

    init(
        lastSuccessAt: Date?,
        activeInstallationSuccessAt: Date? = nil,
        lastPromptAt: Date?,
        lastAttemptAt: Date?,
        lastResult: RefreshResult?,
        lastErrorSummary: String?,
        lastDetectedExpiryAt: Date?,
        expirySource: ExpirySource?,
        currentDeviceStatus: DeviceStatus?,
        currentDeviceName: String?,
        currentDeviceOS: String?,
        isDeployRunning: Bool,
        lastLogPath: String?,
        lastExpiryVerifiedAt: Date? = nil,
        lastAppInspectionAt: Date? = nil,
        lastAppInspectionFailure: String? = nil,
        lastDeviceSeenAt: Date? = nil,
        lastDeviceScanSource: String? = nil,
        lastDeviceScanFailure: String? = nil,
        lastPairingAttemptAt: Date? = nil,
        lastPairingDeviceID: String? = nil,
        lastAutomaticAttemptAt: Date? = nil,
        lastAutomaticRecoveryFailureAt: Date? = nil,
        automaticRefreshEvents: [AutomaticRefreshEvent] = [],
        targetAppPresence: TargetAppPresence = .unknown,
        targetAppBundleID: String? = nil,
        targetDeviceID: String? = nil,
        targetAppVersion: String? = nil,
        targetAppBuildVersion: String? = nil,
        targetAppURL: String? = nil,
        isTargetAppExpiryEvidenceVerified: Bool = false,
        activeDeployProcessGroupID: Int32? = nil,
        activeDeploymentToken: String? = nil,
        deploymentRecoveryBlocked: Bool = false,
        commandRecoveryBlocked: Bool = false
    ) {
        self.lastSuccessAt = lastSuccessAt
        self.activeInstallationSuccessAt = activeInstallationSuccessAt
        self.lastPromptAt = lastPromptAt
        self.lastAttemptAt = lastAttemptAt
        self.lastResult = lastResult
        self.lastErrorSummary = lastErrorSummary
        self.lastDetectedExpiryAt = lastDetectedExpiryAt
        self.expirySource = expirySource
        self.lastExpiryVerifiedAt = lastExpiryVerifiedAt
        self.lastAppInspectionAt = lastAppInspectionAt
        self.lastAppInspectionFailure = lastAppInspectionFailure
        self.currentDeviceStatus = currentDeviceStatus
        self.currentDeviceName = currentDeviceName
        self.currentDeviceOS = currentDeviceOS
        self.lastDeviceSeenAt = lastDeviceSeenAt
        self.lastDeviceScanSource = lastDeviceScanSource
        self.lastDeviceScanFailure = lastDeviceScanFailure
        self.lastPairingAttemptAt = lastPairingAttemptAt
        self.lastPairingDeviceID = lastPairingDeviceID
        self.lastAutomaticAttemptAt = lastAutomaticAttemptAt
        self.lastAutomaticRecoveryFailureAt =
            lastAutomaticRecoveryFailureAt
        self.automaticRefreshEvents = automaticRefreshEvents
        self.targetAppPresence = targetAppPresence
        self.targetAppBundleID = targetAppBundleID
        self.targetDeviceID = targetDeviceID
        self.targetAppVersion = targetAppVersion
        self.targetAppBuildVersion = targetAppBuildVersion
        self.targetAppURL = targetAppURL
        self.isTargetAppExpiryEvidenceVerified = isTargetAppExpiryEvidenceVerified
        self.isDeployRunning = isDeployRunning
        self.activeDeployProcessGroupID = activeDeployProcessGroupID
        self.activeDeploymentToken = activeDeploymentToken
        self.deploymentRecoveryBlocked = deploymentRecoveryBlocked
        self.commandRecoveryBlocked = commandRecoveryBlocked
        self.lastLogPath = lastLogPath
    }

    static let `default` = AppState(
        lastSuccessAt: nil,
        lastPromptAt: nil,
        lastAttemptAt: nil,
        lastResult: nil,
        lastErrorSummary: nil,
        lastDetectedExpiryAt: nil,
        expirySource: nil,
        currentDeviceStatus: .unknown,
        currentDeviceName: nil,
        currentDeviceOS: nil,
        isDeployRunning: false,
        lastLogPath: nil,
        lastExpiryVerifiedAt: nil,
        lastAppInspectionAt: nil,
        lastAppInspectionFailure: nil,
        lastDeviceSeenAt: nil,
        lastDeviceScanSource: nil,
        lastDeviceScanFailure: nil,
        lastPairingAttemptAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case lastSuccessAt
        case activeInstallationSuccessAt
        case lastPromptAt
        case lastAttemptAt
        case lastResult
        case lastErrorSummary
        case lastDetectedExpiryAt
        case expirySource
        case lastExpiryVerifiedAt
        case lastAppInspectionAt
        case lastAppInspectionFailure
        case currentDeviceStatus
        case currentDeviceName
        case currentDeviceOS
        case lastDeviceSeenAt
        case lastDeviceScanSource
        case lastDeviceScanFailure
        case lastPairingAttemptAt
        case lastPairingDeviceID
        case lastAutomaticAttemptAt
        case lastAutomaticRecoveryFailureAt
        case automaticRefreshEvents
        case targetAppPresence
        case targetAppBundleID
        case targetDeviceID
        case targetAppVersion
        case targetAppBuildVersion
        case targetAppURL
        case isTargetAppExpiryEvidenceVerified
        case isDeployRunning
        case activeDeployProcessGroupID
        case activeDeploymentToken
        case deploymentRecoveryBlocked
        case commandRecoveryBlocked
        case lastLogPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        activeInstallationSuccessAt = try container.decodeIfPresent(
            Date.self,
            forKey: .activeInstallationSuccessAt
        )
        lastPromptAt = try container.decodeIfPresent(Date.self, forKey: .lastPromptAt)
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastResult = try container.decodeIfPresent(RefreshResult.self, forKey: .lastResult)
        lastErrorSummary = try container.decodeIfPresent(String.self, forKey: .lastErrorSummary)
        lastDetectedExpiryAt = try container.decodeIfPresent(Date.self, forKey: .lastDetectedExpiryAt)
        expirySource = try container.decodeIfPresent(ExpirySource.self, forKey: .expirySource)
        lastExpiryVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastExpiryVerifiedAt)
        lastAppInspectionAt = try container.decodeIfPresent(Date.self, forKey: .lastAppInspectionAt)
        lastAppInspectionFailure = try container.decodeIfPresent(String.self, forKey: .lastAppInspectionFailure)
        currentDeviceStatus = try container.decodeIfPresent(DeviceStatus.self, forKey: .currentDeviceStatus)
        currentDeviceName = try container.decodeIfPresent(String.self, forKey: .currentDeviceName)
        currentDeviceOS = try container.decodeIfPresent(String.self, forKey: .currentDeviceOS)
        lastDeviceSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastDeviceSeenAt)
        lastDeviceScanSource = try container.decodeIfPresent(String.self, forKey: .lastDeviceScanSource)
        lastDeviceScanFailure = try container.decodeIfPresent(String.self, forKey: .lastDeviceScanFailure)
        lastPairingAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastPairingAttemptAt)
        lastPairingDeviceID = try container.decodeIfPresent(String.self, forKey: .lastPairingDeviceID)
        lastAutomaticAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAutomaticAttemptAt)
        lastAutomaticRecoveryFailureAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastAutomaticRecoveryFailureAt
        )
        automaticRefreshEvents = try container.decodeIfPresent(
            [AutomaticRefreshEvent].self,
            forKey: .automaticRefreshEvents
        ) ?? []
        targetAppPresence = try container.decodeIfPresent(TargetAppPresence.self, forKey: .targetAppPresence) ?? .unknown
        targetAppBundleID = try container.decodeIfPresent(String.self, forKey: .targetAppBundleID)
        targetDeviceID = try container.decodeIfPresent(String.self, forKey: .targetDeviceID)
        targetAppVersion = try container.decodeIfPresent(String.self, forKey: .targetAppVersion)
        targetAppBuildVersion = try container.decodeIfPresent(
            String.self,
            forKey: .targetAppBuildVersion
        )
        targetAppURL = try container.decodeIfPresent(String.self, forKey: .targetAppURL)
        isTargetAppExpiryEvidenceVerified = try container.decodeIfPresent(
            Bool.self,
            forKey: .isTargetAppExpiryEvidenceVerified
        ) ?? false
        isDeployRunning = try container.decodeIfPresent(Bool.self, forKey: .isDeployRunning) ?? false
        activeDeployProcessGroupID = try container.decodeIfPresent(Int32.self, forKey: .activeDeployProcessGroupID)
        activeDeploymentToken = try container.decodeIfPresent(String.self, forKey: .activeDeploymentToken)
        deploymentRecoveryBlocked = try container.decodeIfPresent(
            Bool.self,
            forKey: .deploymentRecoveryBlocked
        ) ?? false
        commandRecoveryBlocked = try container.decodeIfPresent(
            Bool.self,
            forKey: .commandRecoveryBlocked
        ) ?? false
        lastLogPath = try container.decodeIfPresent(String.self, forKey: .lastLogPath)
    }
}
