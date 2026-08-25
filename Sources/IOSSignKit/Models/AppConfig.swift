import Foundation

struct AppConfig: Codable, Equatable, Sendable {
    static let currentApplicationTargetResolutionSchemaVersion = 2

    var projectRootPath: String?
    var deployScriptPath: String?
    var xcodeprojPath: String?
    var scheme: String?
    var targetName: String?
    var bundleID: String?
    var applicationTargetResolutionSchemaVersion: Int
    var preferredDeviceID: String?
    var preferredDeviceName: String?
    var checkIntervalMinutes: Int
    var expiredCheckIntervalMinutes: Int
    var reminderCooldownHours: Int
    var startAtLogin: Bool
    var autoRefreshPolicy: AutoRefreshPolicy
    var lanControl: LANControlConfiguration

    static let `default` = AppConfig(
        projectRootPath: nil,
        deployScriptPath: nil,
        xcodeprojPath: nil,
        scheme: nil,
        targetName: nil,
        bundleID: nil,
        preferredDeviceID: nil,
        preferredDeviceName: nil,
        checkIntervalMinutes:
            AppConfigConstraints.defaultCheckIntervalMinutes,
        expiredCheckIntervalMinutes:
            AppConfigConstraints.defaultExpiredCheckIntervalMinutes,
        reminderCooldownHours:
            AppConfigConstraints.defaultReminderCooldownHours,
        startAtLogin: false,
        autoRefreshPolicy: .reminderOnly,
        lanControl: .default
    )

    var hasResolvedApplicationTarget: Bool {
        projectRootPath != nil
            && xcodeprojPath != nil
            && scheme != nil
            && targetName != nil
            && bundleID != nil
            && applicationTargetResolutionSchemaVersion
                == Self.currentApplicationTargetResolutionSchemaVersion
    }

    init(
        projectRootPath: String?,
        deployScriptPath: String?,
        xcodeprojPath: String?,
        scheme: String?,
        targetName: String? = nil,
        bundleID: String?,
        preferredDeviceID: String?,
        preferredDeviceName: String?,
        checkIntervalMinutes: Int,
        expiredCheckIntervalMinutes: Int? = nil,
        reminderCooldownHours: Int,
        startAtLogin: Bool,
        autoRefreshPolicy: AutoRefreshPolicy,
        lanControl: LANControlConfiguration = .default,
        applicationTargetResolutionSchemaVersion: Int =
            AppConfig.currentApplicationTargetResolutionSchemaVersion
    ) {
        self.projectRootPath = Self.normalizedOptional(projectRootPath)
        self.deployScriptPath = Self.normalizedOptional(deployScriptPath)
        self.xcodeprojPath = Self.normalizedOptional(xcodeprojPath)
        self.scheme = Self.normalizedOptional(scheme)
        self.targetName = Self.normalizedOptional(targetName)
        self.bundleID = Self.normalizedOptional(bundleID)
        self.applicationTargetResolutionSchemaVersion =
            applicationTargetResolutionSchemaVersion
        self.preferredDeviceID = Self.normalizedOptional(preferredDeviceID)
        self.preferredDeviceName = Self.normalizedOptional(preferredDeviceName)
        self.checkIntervalMinutes =
            AppConfigConstraints.normalizeCheckInterval(checkIntervalMinutes)
        self.expiredCheckIntervalMinutes =
            AppConfigConstraints.normalizeExpiredCheckInterval(
                expiredCheckIntervalMinutes
                    ?? AppConfigConstraints.defaultExpiredCheckIntervalMinutes
            )
        self.reminderCooldownHours =
            AppConfigConstraints.normalizeReminderCooldown(reminderCooldownHours)
        self.startAtLogin = startAtLogin
        self.autoRefreshPolicy = autoRefreshPolicy
        self.lanControl = lanControl
    }

    enum CodingKeys: String, CodingKey {
        case projectRootPath
        case deployScriptPath
        case xcodeprojPath
        case scheme
        case targetName
        case bundleID
        case applicationTargetResolutionSchemaVersion
        case preferredDeviceID
        case preferredDeviceName
        case checkIntervalMinutes
        case expiredCheckIntervalMinutes
        case reminderCooldownHours
        case startAtLogin
        case autoRefreshPolicy
        case lanControl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectRootPath = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .projectRootPath))
        deployScriptPath = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .deployScriptPath))
        xcodeprojPath = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .xcodeprojPath))
        scheme = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .scheme))
        targetName = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .targetName))
        bundleID = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .bundleID))
        applicationTargetResolutionSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .applicationTargetResolutionSchemaVersion
        ) ?? 0
        preferredDeviceID = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .preferredDeviceID))
        preferredDeviceName = Self.normalizedOptional(try container.decodeIfPresent(String.self, forKey: .preferredDeviceName))
        checkIntervalMinutes = AppConfigConstraints.normalizeCheckInterval(
            try container.decodeIfPresent(
                Int.self,
                forKey: .checkIntervalMinutes
            ) ?? AppConfigConstraints.defaultCheckIntervalMinutes
        )
        expiredCheckIntervalMinutes =
            AppConfigConstraints.normalizeExpiredCheckInterval(
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .expiredCheckIntervalMinutes
                ) ?? AppConfigConstraints.defaultExpiredCheckIntervalMinutes
            )
        reminderCooldownHours =
            AppConfigConstraints.normalizeReminderCooldown(
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .reminderCooldownHours
                ) ?? AppConfigConstraints.defaultReminderCooldownHours
        )
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        autoRefreshPolicy = try container.decodeIfPresent(AutoRefreshPolicy.self, forKey: .autoRefreshPolicy) ?? .reminderOnly
        lanControl = try container.decodeIfPresent(
            LANControlConfiguration.self,
            forKey: .lanControl
        ) ?? .default
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    func backgroundCheckIntervalMinutes(isExpired: Bool) -> Int {
        isExpired ? expiredCheckIntervalMinutes : checkIntervalMinutes
    }

}
