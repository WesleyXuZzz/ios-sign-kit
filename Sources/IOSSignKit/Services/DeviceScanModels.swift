import Foundation
struct DeviceScanOptions: Equatable, Sendable {
    var preferredDeviceID: String?
    var preferredDeviceName: String?
    var attemptCount: Int
    var retryDelaySeconds: TimeInterval
    var commandTimeoutSeconds: TimeInterval
    var usesDevicectlFallback: Bool
    var requiresCompleteInventory: Bool = false

    static func reliable(
        preferredDeviceID: String? = nil,
        preferredDeviceName: String? = nil
    ) -> DeviceScanOptions {
        let budget = DeviceCommandBudgetCatalog.production.budget(
            for: .interactiveObservation
        )
        return DeviceScanOptions(
            preferredDeviceID: preferredDeviceID,
            preferredDeviceName: preferredDeviceName,
            attemptCount: budget.attempts,
            retryDelaySeconds: budget.retryDelay.timeInterval,
            commandTimeoutSeconds: budget.commandTimeoutSeconds,
            usesDevicectlFallback: true,
            requiresCompleteInventory: true
        )
    }

    static func polling(
        preferredDeviceID: String? = nil,
        preferredDeviceName: String? = nil
    ) -> DeviceScanOptions {
        let hasPinnedTarget = preferredDeviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || preferredDeviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let budget = DeviceCommandBudgetCatalog.production.budget(
            for: .backgroundObservation
        )
        return DeviceScanOptions(
            preferredDeviceID: preferredDeviceID,
            preferredDeviceName: preferredDeviceName,
            attemptCount: budget.attempts,
            retryDelaySeconds: budget.retryDelay.timeInterval,
            commandTimeoutSeconds: budget.commandTimeoutSeconds,
            usesDevicectlFallback: true,
            requiresCompleteInventory: !hasPinnedTarget
        )
    }

    static func automaticRecovery(
        preferredDeviceID: String? = nil,
        preferredDeviceName: String? = nil
    ) -> DeviceScanOptions {
        let hasPinnedTarget = preferredDeviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || preferredDeviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let budget = DeviceCommandBudgetCatalog.production.budget(
            for: .recoveryObservation
        )
        return DeviceScanOptions(
            preferredDeviceID: preferredDeviceID,
            preferredDeviceName: preferredDeviceName,
            attemptCount: budget.attempts,
            retryDelaySeconds: budget.retryDelay.timeInterval,
            commandTimeoutSeconds: budget.commandTimeoutSeconds,
            usesDevicectlFallback: true,
            requiresCompleteInventory: !hasPinnedTarget
        )
    }
}

extension TargetScanPurpose {
    var commandPurpose: DeviceCommandPurpose {
        switch self {
        case .background:
            return .backgroundObservation
        case .recovery:
            return .recoveryObservation
        case .interactive:
            return .interactiveObservation
        }
    }
}

extension InventoryScanPurpose {
    var commandPurpose: DeviceCommandPurpose {
        switch self {
        case .backgroundDiscovery:
            return .backgroundObservation
        case .interactive:
            return .interactiveObservation
        }
    }
}

struct DeviceScanResult: Equatable, Sendable {
    let devices: [DeviceInfo]
    let source: DeviceScanSource
    let unavailableTarget: UnavailableDeviceInfo?
    let unavailableDevices: [UnavailableDeviceInfo]
    let conflictingDeviceIDs: Set<String>
    let isCompleteInventory: Bool
    let diagnostics: DeviceScanDiagnostics

    init(
        devices: [DeviceInfo],
        source: DeviceScanSource,
        unavailableTarget: UnavailableDeviceInfo?,
        unavailableDevices: [UnavailableDeviceInfo] = [],
        conflictingDeviceIDs: Set<String> = [],
        isCompleteInventory: Bool = false,
        diagnostics: DeviceScanDiagnostics
    ) {
        self.devices = devices
        self.source = source
        self.unavailableTarget = unavailableTarget
        self.unavailableDevices = unavailableDevices
        self.conflictingDeviceIDs = conflictingDeviceIDs
        self.isCompleteInventory = isCompleteInventory
        self.diagnostics = diagnostics
    }

    func hasAvailabilityConflict(
        preferredDeviceID: String?,
        preferredDeviceName: String? = nil
    ) -> Bool {
        let normalizedDeviceID = preferredDeviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedDeviceID.isEmpty {
            return conflictingDeviceIDs.contains(normalizedDeviceID)
        }

        if let preferredNormalizedName = normalizedDeviceName(
            preferredDeviceName
        ) {
            return unavailableDevices.contains {
                conflictingDeviceIDs.contains($0.id)
                    && normalizedDeviceName($0.name)
                        == preferredNormalizedName
            }
        }

        return !conflictingDeviceIDs.isEmpty
    }

    private func normalizedDeviceName(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct UnavailableDeviceInfo: Equatable, Sendable {
    let id: String
    let name: String
    let osVersion: String
    let pairingState: String?
    let connectionState: String?
    let tunnelState: String?
    let developerModeStatus: String?
    let diagnosticMessage: String?

    var osMajorVersion: Int? {
        let leadingDigits = osVersion
            .drop(while: { !$0.isNumber })
            .prefix(while: \.isNumber)
        return Int(leadingDigits)
    }
}

enum DeviceEvidenceMerger {
    static func available(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        var merged: [String: DeviceInfo] = [:]
        for device in devices {
            merged[device.id] = device
        }
        return Array(merged.values).sortedByName()
    }

    static func unavailable(
        _ devices: [UnavailableDeviceInfo]
    ) -> [UnavailableDeviceInfo] {
        var merged: [String: UnavailableDeviceInfo] = [:]
        for device in devices {
            merged[device.id] = device
        }
        return Array(merged.values).sortedByName()
    }
}

enum DeviceScanSource: String, Codable, Equatable, Hashable, Sendable {
    case xcdevice
    case devicectl
    case none

    var displayName: String {
        switch self {
        case .xcdevice:
            return "xcdevice"
        case .devicectl:
            return "devicectl"
        case .none:
            return "未检测到"
        }
    }
}

struct DeviceScanDiagnostics: Equatable, Sendable {
    let attempts: Int
    let message: String?
    let sourceOutcomes: [DeviceScanSourceOutcome]

    init(
        attempts: Int,
        message: String?,
        sourceOutcomes: [DeviceScanSourceOutcome] = []
    ) {
        self.attempts = attempts
        self.message = message
        self.sourceOutcomes = sourceOutcomes
    }

}

struct DeviceScanSourceOutcome: Equatable, Sendable {
    let source: DeviceScanSource
    let result: DeviceScanSourceResult
    let message: String?
}

enum DeviceScanSourceResult: String, Equatable, Sendable {
    case matchedTarget
    case completedWithoutTarget
    case failed
}

enum DeviceMonitorError: Error, LocalizedError, Equatable {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        }
    }
}
