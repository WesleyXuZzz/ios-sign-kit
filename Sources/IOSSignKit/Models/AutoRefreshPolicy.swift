import Foundation

enum AutoRefreshPolicy: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
    case reminderOnly
    case autoRefreshWhenExpired

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminderOnly:
            return "仅提醒"
        case .autoRefreshWhenExpired:
            return "到期时自动续期"
        }
    }

    var helpText: String {
        switch self {
        case .reminderOnly:
            return "预计有效期到期后发送提醒，不自动打包安装。"
        case .autoRefreshWhenExpired:
            return "仅在确认 App 已安装且到期后自动续期；iOS \(DeviceCompatibilityPolicy.minimumWirelessPairingMajorVersion) 及以上离线设备可能尝试无线配对，并要求在 iPhone 上确认信任。"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue {
        case Self.reminderOnly.rawValue:
            self = .reminderOnly
        case "autoRefreshWhenDue", Self.autoRefreshWhenExpired.rawValue:
            self = .autoRefreshWhenExpired
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知的自动续期策略：\(rawValue)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
