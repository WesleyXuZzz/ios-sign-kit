import Foundation

struct StableDeviceID: Hashable, Sendable {
    let value: String

    init?(_ rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DeviceIdentityValidator.isSafe(normalized) else {
            return nil
        }
        self.value = normalized
    }
}

enum StableDeviceIDSource: Equatable, Sendable {
    case xcdeviceIdentifier
    case devicectlHardwareUDID
}

enum TargetDeviceReference: Equatable, Sendable {
    case stableID(StableDeviceID, displayName: String?)
    case compatibilityName(String)
}

enum TargetScanPurpose: Equatable, Sendable {
    case background
    case recovery
    case interactive
}

enum InventoryScanPurpose: Equatable, Sendable {
    case backgroundDiscovery
    case interactive
}

enum TargetRecoveryReason: Equatable, Sendable {
    case pairingRequired
    case trustRequired
    case wirelessTransportUnavailable
}

struct TargetRecoveryCandidate: Equatable, Sendable {
    let deviceID: StableDeviceID
    let displayName: String
    let osVersion: String?
    let reason: TargetRecoveryReason
}

struct DeviceIdentityPersistenceCandidate: Equatable, Sendable {
    let deviceID: StableDeviceID
    let displayName: String
}

enum InventoryIdentityResolution: Equatable, Sendable {
    case complete
    case incomplete
    case ambiguous
}

enum ObservationQuality: Equatable, Sendable {
    case complete
    case degraded
}

struct DeviceObservationDiagnostics: Equatable, Sendable {
    let quality: ObservationQuality
    let source: DeviceScanSource
    let summary: String?
}

enum TargetDeviceEvidence: Equatable, Sendable {
    case matched(DeviceInfo)
    case confirmedAbsent
    case unavailable(UnavailableDeviceInfo)
    case inconclusive
    case conflict
}

struct TargetDeviceObservation: Equatable, Sendable {
    let evidence: TargetDeviceEvidence
    let recoveryCandidate: TargetRecoveryCandidate?
    let identityPersistenceCandidate: DeviceIdentityPersistenceCandidate?
    let diagnostics: DeviceObservationDiagnostics

    init(
        evidence: TargetDeviceEvidence,
        recoveryCandidate: TargetRecoveryCandidate?,
        identityPersistenceCandidate: DeviceIdentityPersistenceCandidate? = nil,
        diagnostics: DeviceObservationDiagnostics
    ) {
        self.evidence = evidence
        self.recoveryCandidate = recoveryCandidate
        self.identityPersistenceCandidate = identityPersistenceCandidate
        self.diagnostics = diagnostics
    }
}

struct DeviceInventory: Equatable, Sendable {
    let devices: [DeviceInfo]
    let unavailableDevices: [UnavailableDeviceInfo]
    let recoveryCandidates: [TargetRecoveryCandidate]
    let identityResolution: InventoryIdentityResolution
    let identityPersistenceCandidate: DeviceIdentityPersistenceCandidate?
    let diagnostics: DeviceObservationDiagnostics

    init(
        devices: [DeviceInfo],
        unavailableDevices: [UnavailableDeviceInfo] = [],
        recoveryCandidates: [TargetRecoveryCandidate],
        identityResolution: InventoryIdentityResolution,
        identityPersistenceCandidate: DeviceIdentityPersistenceCandidate? = nil,
        diagnostics: DeviceObservationDiagnostics
    ) {
        self.devices = devices
        self.unavailableDevices = unavailableDevices
        self.recoveryCandidates = recoveryCandidates
        self.identityResolution = identityResolution
        self.identityPersistenceCandidate = identityPersistenceCandidate
        self.diagnostics = diagnostics
    }
}
