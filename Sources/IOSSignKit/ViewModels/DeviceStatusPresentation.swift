import Foundation

struct DeviceStatusPresentation: Equatable {
    let heroSubtitle: String
    let disconnectedSummary: String
    let disconnectedTone: StatusTone
    let heroDeviceText: String
    let reminderBannerSummary: String?
    let reminderBannerTone: StatusTone?
    let recoveryMessage: String?

    var isConnectionRecovery: Bool {
        recoveryMessage != nil
    }

    static func make(
        status: DeviceStatus?,
        hasPersistedIdentity: Bool
    ) -> DeviceStatusPresentation {
        let defaultPresentation = DeviceStatusPresentation(
            heroSubtitle: "等待目标 iPhone 连接后即可继续。",
            disconnectedSummary: "离线",
            disconnectedTone: .warning,
            heroDeviceText: "未连接",
            reminderBannerSummary: nil,
            reminderBannerTone: nil,
            recoveryMessage: nil
        )

        switch status {
        case nil, .unknown:
            return DeviceStatusPresentation(
                heroSubtitle: defaultPresentation.heroSubtitle,
                disconnectedSummary: "待检查",
                disconnectedTone: .neutral,
                heroDeviceText: defaultPresentation.heroDeviceText,
                reminderBannerSummary: nil,
                reminderBannerTone: .neutral,
                recoveryMessage: nil
            )
        case .confirming:
            return DeviceStatusPresentation(
                heroSubtitle: "刚刚检测到过目标设备，正在重新确认连接状态。",
                disconnectedSummary: "正在确认连接",
                disconnectedTone: .info,
                heroDeviceText: "确认中",
                reminderBannerSummary: "正在确认目标设备连接",
                reminderBannerTone: .info,
                recoveryMessage: nil
            )
        case .scanFailed:
            return DeviceStatusPresentation(
                heroSubtitle: defaultPresentation.heroSubtitle,
                disconnectedSummary: hasPersistedIdentity ? "检测异常（上次在线）" : "检测异常",
                disconnectedTone: .critical,
                heroDeviceText: defaultPresentation.heroDeviceText,
                reminderBannerSummary: "暂时无法检测目标设备",
                reminderBannerTone: .critical,
                recoveryMessage: nil
            )
        case .wirelessPairing:
            return recoveryPresentation(
                heroSubtitle: "正在尝试通过同一局域网重新配对目标 iPhone。",
                disconnectedSummary: "正在无线配对",
                heroDeviceText: "配对中",
                reminderBannerSummary: "正在恢复目标设备连接",
                tone: .info,
                recoveryMessage: "正在尝试通过同一局域网重新配对目标 iPhone。"
            )
        case .wirelessPairingConfirmationRequired:
            return recoveryPresentation(
                heroSubtitle: "请解锁 iPhone，并在设备上确认信任或开启开发者模式。",
                disconnectedSummary: "等待 iPhone 确认",
                heroDeviceText: "需确认",
                reminderBannerSummary: "等待在 iPhone 上确认信任",
                tone: .warning,
                recoveryMessage: "请解锁 iPhone，在设备上确认信任，并确保开发者模式已开启。"
            )
        case .wirelessPairingRequired:
            return recoveryPresentation(
                heroSubtitle: "请解锁 iPhone，并确认它与 Mac 连接到同一 Wi-Fi。",
                disconnectedSummary: "等待无线连接恢复",
                heroDeviceText: "需配对",
                reminderBannerSummary: "等待目标设备恢复无线连接",
                tone: .warning,
                recoveryMessage: "请解锁 iPhone，并确认它与 Mac 连接到同一 Wi-Fi 后重新检查。"
            )
        case .xcodeUpdateRequired:
            return recoveryPresentation(
                heroSubtitle: "当前 Xcode/CoreDevice 不支持该设备版本，请升级 Xcode。",
                disconnectedSummary: "需升级 Xcode",
                heroDeviceText: "需升级",
                reminderBannerSummary: "需要升级 Xcode",
                tone: .critical,
                recoveryMessage: "当前 Xcode/CoreDevice 不支持该设备版本，请升级 Xcode 后重新检查。"
            )
        case .wiredConnectionRequired:
            return recoveryPresentation(
                heroSubtitle: "请用数据线连接 iPhone，并在 Finder 或 Xcode 完成一次信任或配对。",
                disconnectedSummary: "需用数据线重新配对",
                heroDeviceText: "需连线",
                reminderBannerSummary: "需要通过数据线重新配对",
                tone: .warning,
                recoveryMessage: "请用数据线连接 iPhone，并在 Finder 或 Xcode 完成一次信任或配对。"
            )
        case .unrecognized:
            return DeviceStatusPresentation(
                heroSubtitle: "设备状态来自较新版本，正在等待重新检查。",
                disconnectedSummary: "未知状态",
                disconnectedTone: .neutral,
                heroDeviceText: "待检查",
                reminderBannerSummary: "设备状态待重新检查",
                reminderBannerTone: .neutral,
                recoveryMessage: nil
            )
        case .online, .offline:
            return defaultPresentation
        }
    }

    private static func recoveryPresentation(
        heroSubtitle: String,
        disconnectedSummary: String,
        heroDeviceText: String,
        reminderBannerSummary: String,
        tone: StatusTone,
        recoveryMessage: String
    ) -> DeviceStatusPresentation {
        DeviceStatusPresentation(
            heroSubtitle: heroSubtitle,
            disconnectedSummary: disconnectedSummary,
            disconnectedTone: tone,
            heroDeviceText: heroDeviceText,
            reminderBannerSummary: reminderBannerSummary,
            reminderBannerTone: tone,
            recoveryMessage: recoveryMessage
        )
    }
}
