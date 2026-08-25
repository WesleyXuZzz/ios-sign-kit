import Foundation

enum DeviceIdentityValidator {
    static let maximumFieldBytes = 512

    static func isSafe(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumFieldBytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}

struct DeviceInfo: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var platform: String
    var osVersion: String
    var isAvailable: Bool
    var isPaired: Bool
}

struct CompatibilityDeploymentTarget: Equatable, Sendable {
    let device: DeviceInfo

    init(
        device: DeviceInfo,
        availableDevices: [DeviceInfo],
        unavailableDevices: [UnavailableDeviceInfo] = []
    ) throws {
        let normalizedID = Self.validatedIdentityValue(device.id)
        let normalizedName = Self.normalize(device.name)
        guard let normalizedID,
              Self.isSafeIdentityValue(device.name),
              !normalizedName.isEmpty else {
            throw DeploymentTargetError.invalidDeviceIdentity
        }
        guard device.isAvailable else {
            throw DeploymentTargetError.deviceUnavailable(device.name)
        }
        guard device.isPaired else {
            throw DeploymentTargetError.deviceNotPaired(device.name)
        }
        guard let verifiedDevice = availableDevices.first(where: {
            Self.validatedIdentityValue($0.id) == normalizedID
        }),
        verifiedDevice.isAvailable,
        verifiedDevice.isPaired,
        Self.normalize(verifiedDevice.name) == normalizedName else {
            throw DeploymentTargetError.deviceNotVerified(device.name)
        }
        let sameNameDeviceIDs = Set(
            availableDevices
                .filter { Self.normalize($0.name) == normalizedName }
                .map(\.id)
            + unavailableDevices
                .filter { Self.normalize($0.name) == normalizedName }
                .map(\.id)
        )
        guard sameNameDeviceIDs == Set([device.id]) else {
            throw DeploymentTargetError.ambiguousDeviceName(device.name)
        }
        self.device = device
    }

    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizedValue(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func validatedIdentityValue(_ value: String) -> String? {
        guard isSafeIdentityValue(value) else {
            return nil
        }
        return normalizedValue(value)
    }

    private static func isSafeIdentityValue(_ value: String) -> Bool {
        DeviceIdentityValidator.isSafe(value)
    }
}

enum DeploymentTargetError: Error, LocalizedError, Equatable {
    case invalidDeviceIdentity
    case deviceUnavailable(String)
    case deviceNotPaired(String)
    case deviceNotVerified(String)
    case ambiguousDeviceName(String)

    var errorDescription: String? {
        switch self {
        case .invalidDeviceIdentity:
            return "目标设备缺少稳定 ID 或设备名称，本次续签已停止。"
        case .deviceUnavailable(let name):
            return "目标设备“\(name)”当前不可用，本次续签已停止。"
        case .deviceNotPaired(let name):
            return "目标设备“\(name)”尚未完成配对，本次续签已停止。"
        case .deviceNotVerified(let name):
            return "未检测到目标 iPhone“\(name)”，请连接并解锁设备后重试。"
        case .ambiguousDeviceName(let name):
            return "检测到多台名为“\(name)”的 iPhone。为避免续签到错误设备，本次续签已停止；请断开或重命名同名设备，或在项目配置中重新选择并固定目标设备。"
        }
    }
}
