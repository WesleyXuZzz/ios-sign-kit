import Foundation

enum LANControlPageState: String, Codable, Equatable, Sendable {
    case ready
    case checking
    case progress
    case success
    case failure
    case unavailable
}

enum LANControlStatusTone: String, Codable, Equatable, Sendable {
    case good
    case warning
    case critical
    case info
    case neutral
}

enum LANControlOperationPhase: Int, Codable, CaseIterable, Sendable {
    case verifyingTarget
    case confirmingDestination
    case preparingSigning
    case signingAndBuilding
    case installing
    case synchronizingInstallation

    var title: String {
        switch self {
        case .verifyingTarget:
            "正在最终核验目标 iPhone"
        case .confirmingDestination:
            "正在确认 Xcode destination"
        case .preparingSigning:
            "正在准备签名配置"
        case .signingAndBuilding:
            "正在签名并构建 App"
        case .installing:
            "正在无线安装到 iPhone"
        case .synchronizingInstallation:
            "正在同步真机安装信息"
        }
    }
}

struct LANControlSnapshot: Codable, Equatable, Sendable {
    let pageState: LANControlPageState
    let appName: String
    let deviceName: String
    let deviceStatus: String
    let deviceStatusTone: LANControlStatusTone
    let signatureStatus: String
    let message: String
    let canRenew: Bool
    let canRecheck: Bool
    let phaseIndex: Int?
    let phases: [String]
    let elapsedSeconds: Int
    let expectedExpiryAt: Date?
    let checkedAt: Date
}

enum LANControlAction: Sendable {
    case renew(profileRefreshMode: ProvisioningProfileRefreshMode?)
    case recheck
    case dismissResult
}

struct LANControlActionOutcome: Codable, Equatable, Sendable {
    let accepted: Bool
    let requiresProfileChoice: Bool
    let message: String

    static func accepted(_ message: String) -> LANControlActionOutcome {
        LANControlActionOutcome(
            accepted: true,
            requiresProfileChoice: false,
            message: message
        )
    }

    static func profileChoiceRequired(
        _ message: String
    ) -> LANControlActionOutcome {
        LANControlActionOutcome(
            accepted: false,
            requiresProfileChoice: true,
            message: message
        )
    }

    static func rejected(_ message: String) -> LANControlActionOutcome {
        LANControlActionOutcome(
            accepted: false,
            requiresProfileChoice: false,
            message: message
        )
    }
}

enum LANControlServiceStatus: Equatable, Sendable {
    case disabled
    case starting(URL)
    case running(URL)
    case failed(String)

    var accessURL: URL? {
        switch self {
        case .starting(let url), .running(let url):
            url
        case .disabled, .failed:
            nil
        }
    }

    var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    var title: String {
        switch self {
        case .disabled:
            "未启用"
        case .starting:
            "正在启动"
        case .running:
            "运行中"
        case .failed:
            "启动失败"
        }
    }
}
