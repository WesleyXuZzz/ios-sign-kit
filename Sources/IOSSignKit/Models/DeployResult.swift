import Foundation

enum DeployOutcome: String, Codable, Equatable, Sendable {
    case success
    case cancelled
    case timedOut
    case failure
}

enum DeployFailureReason: Hashable, Sendable, Codable {
    case devicePreparationRequired
    case generic
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "device_preparation_required":
            self = .devicePreparationRequired
        case "generic":
            self = .generic
        default:
            self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .devicePreparationRequired:
            "device_preparation_required"
        case .generic:
            "generic"
        case .unknown(let rawValue):
            rawValue
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct DeployResult: Codable, Equatable, Sendable {
    var startedAt: Date
    var finishedAt: Date
    var outcome: DeployOutcome
    var failureReason: DeployFailureReason?
    var summary: String
    var logPath: String?
    var logWarning: String? = nil
    /// Exact expiry read from the provisioning profile embedded in the App
    /// artifact that was installed by this deployment transaction.
    var verifiedProfileExpirationDate: Date? = nil
    var processGroupTerminationWasConfirmed: Bool
    /// True only when any provisioning-profile cache transaction was either
    /// durably committed after installation or fully restored after failure.
    var profileCacheRecoveryWasConfirmed: Bool

    var isSuccess: Bool {
        outcome == .success
    }

    init(
        startedAt: Date,
        finishedAt: Date,
        outcome: DeployOutcome,
        failureReason: DeployFailureReason? = nil,
        summary: String,
        logPath: String?,
        logWarning: String? = nil,
        verifiedProfileExpirationDate: Date? = nil,
        processGroupTerminationWasConfirmed: Bool = true,
        profileCacheRecoveryWasConfirmed: Bool = true
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failureReason = failureReason
        self.summary = summary
        self.logPath = logPath
        self.logWarning = logWarning
        self.verifiedProfileExpirationDate = verifiedProfileExpirationDate
        self.processGroupTerminationWasConfirmed =
            processGroupTerminationWasConfirmed
        self.profileCacheRecoveryWasConfirmed =
            profileCacheRecoveryWasConfirmed
    }

    init(
        startedAt: Date,
        finishedAt: Date,
        isSuccess: Bool,
        failureReason: DeployFailureReason? = nil,
        summary: String,
        logPath: String?,
        logWarning: String? = nil,
        verifiedProfileExpirationDate: Date? = nil,
        processGroupTerminationWasConfirmed: Bool = true,
        profileCacheRecoveryWasConfirmed: Bool = true
    ) {
        self.init(
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: isSuccess ? .success : .failure,
            failureReason: failureReason,
            summary: summary,
            logPath: logPath,
            logWarning: logWarning,
            verifiedProfileExpirationDate: verifiedProfileExpirationDate,
            processGroupTerminationWasConfirmed:
                processGroupTerminationWasConfirmed,
            profileCacheRecoveryWasConfirmed:
                profileCacheRecoveryWasConfirmed
        )
    }

    enum CodingKeys: String, CodingKey {
        case startedAt
        case finishedAt
        case outcome
        case failureReason
        case summary
        case logPath
        case logWarning
        case verifiedProfileExpirationDate
        case processGroupTerminationWasConfirmed
        case profileCacheRecoveryWasConfirmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        outcome = try container.decode(DeployOutcome.self, forKey: .outcome)
        failureReason = try container.decodeIfPresent(
            DeployFailureReason.self,
            forKey: .failureReason
        )
        summary = try container.decode(String.self, forKey: .summary)
        logPath = try container.decodeIfPresent(String.self, forKey: .logPath)
        logWarning = try container.decodeIfPresent(
            String.self,
            forKey: .logWarning
        )
        verifiedProfileExpirationDate = try container.decodeIfPresent(
            Date.self,
            forKey: .verifiedProfileExpirationDate
        )
        processGroupTerminationWasConfirmed = try container.decodeIfPresent(
            Bool.self,
            forKey: .processGroupTerminationWasConfirmed
        ) ?? true
        profileCacheRecoveryWasConfirmed = try container.decodeIfPresent(
            Bool.self,
            forKey: .profileCacheRecoveryWasConfirmed
        ) ?? true
    }
}
