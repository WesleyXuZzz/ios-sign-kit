import Foundation

enum DeviceMatchResult: Equatable, Sendable {
    case matched(DeviceInfo)
    case preferredIdentifierUnavailable(String)
    case preferredNameUnavailable(String)
    case ambiguousName(String, matchingDeviceIDs: [String])
    case selectionRequired([DeviceInfo])
    case noAvailableDevices

    var device: DeviceInfo? {
        guard case .matched(let device) = self else {
            return nil
        }
        return device
    }

    var diagnosticMessage: String? {
        switch self {
        case .matched:
            return nil
        case .preferredIdentifierUnavailable:
            return "固定的目标 iPhone 当前不可用，不会回退到其他设备。"
        case .preferredNameUnavailable(let name):
            return "未找到名为 \(name) 的目标 iPhone。"
        case .ambiguousName(let name, _):
            return "检测到多台同名设备“\(name)”，为避免续签到错误设备，请先固定设备 ID。"
        case .selectionRequired(let devices):
            return "检测到 \(devices.count) 台 iPhone，请先选择目标设备。"
        case .noAvailableDevices:
            return nil
        }
    }
}

struct DeviceMatcher: Sendable {
    func match(
        preferredDeviceID: String?,
        preferredDeviceName: String?,
        devices: [DeviceInfo]
    ) -> DeviceMatchResult {
        if let preferredDeviceID = normalizedValue(preferredDeviceID) {
            if let exactMatch = devices.first(where: { $0.id == preferredDeviceID }) {
                return .matched(exactMatch)
            }
            return .preferredIdentifierUnavailable(preferredDeviceID)
        }

        if let preferredDeviceName = normalizedValue(preferredDeviceName) {
            let normalizedName = normalize(preferredDeviceName)
            let matches = devices.filter { normalize($0.name) == normalizedName }
            if matches.count == 1, let match = matches.first {
                return .matched(match)
            }
            if matches.count > 1 {
                return .ambiguousName(
                    preferredDeviceName,
                    matchingDeviceIDs: matches.map(\.id).sorted()
                )
            }
            return .preferredNameUnavailable(preferredDeviceName)
        }

        switch devices.count {
        case 0:
            return .noAvailableDevices
        case 1:
            return .matched(devices[0])
        default:
            return .selectionRequired(devices)
        }
    }

    private func normalizedValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
