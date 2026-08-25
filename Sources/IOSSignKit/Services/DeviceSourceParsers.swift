import Foundation

enum DeviceSourceParser {
    static func parseXCDevice(_ output: String) throws -> SourceScanOutcome {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start <= end else {
            throw DeviceMonitorError.commandFailed(
                "xcdevice 没有返回可解析的 JSON 设备列表。"
            )
        }

        let data = Data(output[start...end].utf8)
        let decoded = try JSONDecoder().decode(
            [XCDeviceRecord].self,
            from: data
        )
        var records: [ParsedDeviceRecord] = []
        var isPartial = false
        for record in decoded where !record.simulator
            && record.platform == "com.apple.platform.iphoneos" {
            guard record.isIPhone else {
                if !record.isKnownNonIPhone {
                    isPartial = true
                }
                continue
            }
            let parsed = record.parsedRecord
            records.append(parsed)
            if parsed.stableID == nil || parsed.name == nil {
                isPartial = true
            }
        }
        return isPartial
            ? .partial(
                records,
                "xcdevice 包含无法安全分类的物理 iOS 设备记录。"
            )
            : .completed(records)
    }

    static func parseDeviceCtl(_ data: Data) throws -> SourceScanOutcome {
        let decoded = try JSONDecoder().decode(
            DeviceCtlResponse.self,
            from: data
        )
        var records: [ParsedDeviceRecord] = []
        var isPartial = false
        for record in decoded.result.devices {
            guard record.isIPhoneLike else {
                if record.looksLikeUnclassifiedIOSDevice {
                    isPartial = true
                }
                continue
            }
            let parsed = record.parsedRecord
            records.append(parsed)
            if parsed.stableID == nil
                || parsed.name == nil
                || record.hasUnknownSemanticValue {
                isPartial = true
            }
        }
        return isPartial
            ? .partial(
                records,
                "devicectl 包含无法安全分类的 iPhone 记录。"
            )
            : .completed(records)
    }
}

enum SourceScanOutcome: Sendable {
    case completed([ParsedDeviceRecord])
    case partial([ParsedDeviceRecord], String)
    case failed(String)

    var records: [ParsedDeviceRecord] {
        switch self {
        case .completed(let records), .partial(let records, _):
            return records
        case .failed:
            return []
        }
    }

    var isComplete: Bool {
        if case .completed = self {
            return true
        }
        return false
    }

    var diagnosticMessage: String? {
        switch self {
        case .completed:
            return nil
        case .partial(_, let message), .failed(let message):
            return message
        }
    }
}

struct ParsedDeviceRecord: Sendable {
    let source: DeviceScanSource
    let stableID: StableDeviceID?
    let stableIDSource: StableDeviceIDSource?
    let sourceLocalID: String?
    let name: String?
    let platform: String?
    let osVersion: String?
    let explicitAvailability: Bool?
    let pairingState: String?
    let connectionState: String?
    let tunnelState: String?
    let transportType: String?
    let developerModeStatus: String?
    let sourceDiagnostic: String?

    var compatibilityAssessment: ParsedDeviceAssessment? {
        guard let assessment else {
            return nil
        }
        switch assessment {
        case .positive, .unavailable:
            return assessment
        case .uncertain(let device, let recoveryCandidate):
            return .unavailable(device, recoveryCandidate)
        }
    }

    var assessment: ParsedDeviceAssessment? {
        guard let stableID,
              let name,
              DeviceIdentityValidator.isSafe(name) else {
            return nil
        }
        let osVersion = osVersion.flatMap {
            DeviceIdentityValidator.isSafe($0) ? $0 : nil
        } ?? "未知"
        let paired = normalized(pairingState)
        let isExplicitlyUnpaired = paired.map {
            $0.contains("unpaired")
                || $0.contains("notpaired")
                || $0.contains("not paired")
        } ?? false
        let isExplicitlyUntrusted = paired.map {
            $0.contains("untrusted")
                || $0.contains("nottrusted")
                || $0.contains("not trusted")
        } ?? false
        let isPaired = source == .xcdevice
            || paired == "paired"
            || paired == "trusted"
            || explicitAvailability == true
            || isPositiveConnectionValue(connectionState)
            || isPositiveConnectionValue(tunnelState)
        let device = DeviceInfo(
            id: stableID.value,
            name: name,
            platform: "com.apple.platform.iphoneos",
            osVersion: osVersion,
            isAvailable: false,
            isPaired: isPaired
        )
        let unavailable = UnavailableDeviceInfo(
            id: stableID.value,
            name: name,
            osVersion: osVersion,
            pairingState: pairingState,
            connectionState: connectionState,
            tunnelState: tunnelState,
            developerModeStatus: developerModeStatus,
            diagnosticMessage: diagnosticMessage
        )

        if explicitAvailability == false || isExplicitlyUnpaired || isExplicitlyUntrusted {
            let reason: TargetRecoveryReason? = isExplicitlyUnpaired
                ? .pairingRequired
                : (isExplicitlyUntrusted ? .trustRequired : recoveryReason)
            return .unavailable(
                unavailable,
                reason.map {
                    TargetRecoveryCandidate(
                        deviceID: stableID,
                        displayName: name,
                        osVersion: osVersion,
                        reason: $0
                    )
                }
            )
        }
        if explicitAvailability == true
            || (isPaired
                && (isPositiveConnectionValue(connectionState)
                    || isPositiveConnectionValue(tunnelState))) {
            var availableDevice = device
            availableDevice.isAvailable = true
            return .positive(availableDevice)
        }
        return .uncertain(
            unavailable,
            recoveryReason.map {
                TargetRecoveryCandidate(
                    deviceID: stableID,
                    displayName: name,
                    osVersion: osVersion,
                    reason: $0
                )
            }
        )
    }

    private var recoveryReason: TargetRecoveryReason? {
        let normalizedTransport = normalized(transportType)
        let normalizedTunnel = normalized(tunnelState)
        let normalizedPairing = normalized(pairingState)
        if normalizedPairing == "paired"
            && normalizedTransport == "localnetwork"
            && (normalizedTunnel == "disconnected"
                || normalizedTunnel == "unavailable") {
            return .wirelessTransportUnavailable
        }
        return nil
    }

    private var diagnosticMessage: String? {
        let details = [
            sourceDiagnostic,
            connectionState.map { "connectionState=\($0)" },
            tunnelState.map { "tunnelState=\($0)" },
            pairingState.map { "pairingState=\($0)" },
            transportType.map { "transportType=\($0)" },
            developerModeStatus.map { "developerMode=\($0)" }
        ].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: "，")
    }

    private func isPositiveConnectionValue(_ value: String?) -> Bool {
        guard let normalized = normalized(value) else {
            return false
        }
        return ["connected", "available", "ready", "active", "established"]
            .contains(normalized)
    }

    private func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

enum ParsedDeviceAssessment: Sendable {
    case positive(DeviceInfo)
    case unavailable(UnavailableDeviceInfo, TargetRecoveryCandidate?)
    case uncertain(UnavailableDeviceInfo, TargetRecoveryCandidate?)
}

struct XCDeviceRecord: Decodable {
    let simulator: Bool
    let available: Bool
    let platform: String
    let identifier: String
    let name: String
    let operatingSystemVersion: String
    let modelCode: String?
    let modelName: String?
    let error: XCDeviceError?

    var isIPhone: Bool {
        [modelCode, modelName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { $0.hasPrefix("iphone") || $0.contains(" iphone") }
    }

    var isKnownNonIPhone: Bool {
        [modelCode, modelName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains {
                $0.contains("ipad")
                    || $0.contains("ipod")
                    || $0.contains("apple tv")
                    || $0.contains("watch")
            }
    }

    var parsedRecord: ParsedDeviceRecord {
        let normalizedName = normalizedValue(name)
            .flatMap { DeviceIdentityValidator.isSafe($0) ? $0 : nil }
        let stableID = StableDeviceID(identifier)
        return ParsedDeviceRecord(
            source: .xcdevice,
            stableID: stableID,
            stableIDSource: stableID == nil ? nil : .xcdeviceIdentifier,
            sourceLocalID: stableID?.value,
            name: normalizedName,
            platform: platform,
            osVersion: DeviceIdentityValidator.isSafe(operatingSystemVersion)
                ? operatingSystemVersion
                : nil,
            explicitAvailability: available,
            pairingState: "paired",
            connectionState: nil,
            tunnelState: nil,
            transportType: nil,
            developerModeStatus: nil,
            sourceDiagnostic: [error?.description, error?.recoverySuggestion]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        )
    }

    var deviceInfo: DeviceInfo? {
        guard let identifier = normalizedValue(identifier),
              let name = normalizedValue(name),
              DeviceIdentityValidator.isSafe(identifier),
              DeviceIdentityValidator.isSafe(name),
              DeviceIdentityValidator.isSafe(operatingSystemVersion) else {
            return nil
        }
        return DeviceInfo(
            id: identifier,
            name: name,
            platform: platform,
            osVersion: operatingSystemVersion,
            isAvailable: available,
            isPaired: true
        )
    }

    var unavailableDeviceInfo: UnavailableDeviceInfo? {
        guard let deviceInfo else {
            return nil
        }
        let message = [error?.description, error?.recoverySuggestion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return UnavailableDeviceInfo(
            id: deviceInfo.id,
            name: deviceInfo.name,
            osVersion: deviceInfo.osVersion,
            pairingState: nil,
            connectionState: nil,
            tunnelState: nil,
            developerModeStatus: nil,
            diagnosticMessage: message.isEmpty ? nil : message
        )
    }

    private func normalizedValue(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct XCDeviceError: Decodable {
    let description: String?
    let recoverySuggestion: String?
}

struct DeviceCtlResponse: Decodable {
    let result: DeviceCtlResult
}

struct DeviceCtlResult: Decodable {
    let devices: [DeviceCtlRecord]
}

struct DeviceCtlRecord: Decodable {
    let identifier: String?
    let name: String?
    let available: Bool?
    let platform: String?
    let operatingSystemVersion: String?
    let deviceProperties: DeviceCtlDeviceProperties?
    let hardwareProperties: DeviceCtlHardwareProperties?
    let connectionProperties: DeviceCtlConnectionProperties?

    var deviceInfo: DeviceInfo? {
        guard isIPhoneLike else {
            return nil
        }

        guard let deviceID = firstNonEmpty([
            hardwareProperties?.udid,
            identifier,
            hardwareProperties?.serialNumber
        ]),
        let deviceName = firstNonEmpty([name, deviceProperties?.name]),
        DeviceIdentityValidator.isSafe(deviceID),
        DeviceIdentityValidator.isSafe(deviceName) else {
            return nil
        }
        let osVersion = firstNonEmpty([
            operatingSystemVersion,
            deviceProperties?.osVersionNumber,
            deviceProperties?.osVersion
        ]) ?? "未知"
        guard DeviceIdentityValidator.isSafe(osVersion) else {
            return nil
        }

        return DeviceInfo(
            id: deviceID,
            name: deviceName,
            platform: "com.apple.platform.iphoneos",
            osVersion: osVersion,
            isAvailable: isAvailable,
            isPaired: isPaired
        )
    }

    var unavailableDeviceInfo: UnavailableDeviceInfo? {
        guard let deviceInfo, !deviceInfo.isAvailable else {
            return nil
        }

        return UnavailableDeviceInfo(
            id: deviceInfo.id,
            name: deviceInfo.name,
            osVersion: deviceInfo.osVersion,
            pairingState: connectionProperties?.pairingState,
            connectionState: connectionProperties?.connectionState,
            tunnelState: connectionProperties?.tunnelState,
            developerModeStatus: deviceProperties?.developerModeStatus,
            diagnosticMessage: unavailableDiagnosticMessage
        )
    }

    var isIPhoneLike: Bool {
        let values = [
            hardwareProperties?.deviceType,
            hardwareProperties?.productType,
            deviceProperties?.deviceClass
        ]
        let normalizedValues = values
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return normalizedValues.contains("iphone")
    }

    var looksLikeUnclassifiedIOSDevice: Bool {
        let platformValues = [
            platform,
            hardwareProperties?.platform
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return platformValues.contains("ios")
            || platformValues.contains("iphoneos")
    }

    var parsedRecord: ParsedDeviceRecord {
        let stableID = hardwareProperties?.udid.flatMap(StableDeviceID.init)
        let deviceName = firstNonEmpty([name, deviceProperties?.name])
            .flatMap { DeviceIdentityValidator.isSafe($0) ? $0 : nil }
        let osVersion = firstNonEmpty([
            operatingSystemVersion,
            deviceProperties?.osVersionNumber,
            deviceProperties?.osVersion
        ]).flatMap { DeviceIdentityValidator.isSafe($0) ? $0 : nil }
        return ParsedDeviceRecord(
            source: .devicectl,
            stableID: stableID,
            stableIDSource: stableID == nil ? nil : .devicectlHardwareUDID,
            sourceLocalID: firstNonEmpty([identifier]),
            name: deviceName,
            platform: platform ?? hardwareProperties?.platform,
            osVersion: osVersion,
            explicitAvailability: available,
            pairingState: connectionProperties?.pairingState,
            connectionState: connectionProperties?.connectionState,
            tunnelState: connectionProperties?.tunnelState,
            transportType: connectionProperties?.transportType,
            developerModeStatus: deviceProperties?.developerModeStatus,
            sourceDiagnostic: nil
        )
    }

    var hasUnknownSemanticValue: Bool {
        !isRecognized(
            connectionProperties?.pairingState,
            values: [
                "paired", "trusted", "unpaired", "notpaired", "not paired",
                "untrusted", "nottrusted", "not trusted"
            ]
        )
            || !isRecognized(
                connectionProperties?.connectionState,
                values: [
                    "connected", "available", "ready", "active", "established",
                    "disconnected", "unavailable", "notconnected", "not connected",
                    "connecting"
                ]
            )
            || !isRecognized(
                connectionProperties?.tunnelState,
                values: [
                    "connected", "available", "ready", "active", "established",
                    "disconnected", "unavailable", "notconnected", "not connected",
                    "connecting"
                ]
            )
    }

    private var isAvailable: Bool {
        guard isPaired else {
            return false
        }

        if let available {
            return available
        }

        return isPositiveConnectionValue(connectionProperties?.connectionState)
            || isPositiveConnectionValue(connectionProperties?.tunnelState)
    }

    private var unavailableDiagnosticMessage: String? {
        let details = [
            connectionProperties?.connectionState.map { "connectionState=\($0)" },
            connectionProperties?.tunnelState.map { "tunnelState=\($0)" },
            connectionProperties?.pairingState.map { "pairingState=\($0)" },
            deviceProperties?.developerModeStatus.map { "developerMode=\($0)" }
        ].compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: "，")
    }

    private var isPaired: Bool {
        if let pairingState = normalizedValue(connectionProperties?.pairingState) {
            if pairingState.contains("unpaired")
                || pairingState.contains("notpaired")
                || pairingState.contains("not paired") {
                return false
            }
            if pairingState.contains("paired") || pairingState == "trusted" {
                return true
            }
        }
        if available == true {
            return true
        }
        return isPositiveConnectionValue(connectionProperties?.connectionState)
            || isPositiveConnectionValue(connectionProperties?.tunnelState)
    }

    private func isPositiveConnectionValue(_ value: String?) -> Bool {
        guard let normalized = normalizedValue(value),
              !normalized.contains("disconnected"),
              !normalized.contains("unavailable"),
              !normalized.contains("notconnected"),
              !normalized.contains("not connected") else {
            return false
        }
        return ["connected", "available", "ready", "active", "established"].contains(normalized)
    }

    private func isRecognized(_ value: String?, values: Set<String>) -> Bool {
        guard let normalized = normalizedValue(value) else {
            return true
        }
        return values.contains(normalized)
    }

    private func normalizedValue(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        values
            .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            .first(where: { !$0.isEmpty })
    }
}

struct DeviceCtlDeviceProperties: Decodable {
    let name: String?
    let osVersionNumber: String?
    let osVersion: String?
    let deviceClass: String?
    let developerModeStatus: String?
}

struct DeviceCtlHardwareProperties: Decodable {
    let udid: String?
    let serialNumber: String?
    let platform: String?
    let deviceType: String?
    let productType: String?
}

struct DeviceCtlConnectionProperties: Decodable {
    let connectionState: String?
    let tunnelState: String?
    let transportType: String?
    let pairingState: String?
}

extension Array where Element == DeviceInfo {
    func sortedByName() -> [DeviceInfo] {
        sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension Array where Element == UnavailableDeviceInfo {
    func sortedByName() -> [UnavailableDeviceInfo] {
        sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct DeviceScanBatch {
    let devices: [DeviceInfo]
    let unavailableDevices: [UnavailableDeviceInfo]
}
