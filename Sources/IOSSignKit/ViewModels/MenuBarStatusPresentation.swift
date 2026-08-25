import Foundation

enum MenuBarTitleTransitionGroup: Equatable {
    case semantic
    case expiry
}

enum MenuBarTitleWidthTier: Equatable {
    case compact
    case standard
}

enum MenuBarTitleFontStyle: Equatable {
    case status
    case time
}

enum MenuBarIconTransitionIdentity: Equatable {
    case error
    case setup
    case attention
    case progress
    case offline
    case online
}

enum MenuBarRefreshResult: Equatable {
    case succeeded
    case failed
    case cancelled
    case interrupted
    case unknown

    init(_ result: RefreshResult) {
        switch result {
        case .success:
            self = .succeeded
        case .failure:
            self = .failed
        case .cancelled:
            self = .cancelled
        case .interrupted:
            self = .interrupted
        case .running, .unrecognized:
            self = .unknown
        }
    }
}

enum MenuBarActivity: Equatable {
    case idle
    case checking
    case countdown(seconds: Int)
    case preparing
    case deploying
    case waitingForUnlock
    case result(MenuBarRefreshResult)
}

struct MenuBarStatusContext: Equatable {
    var isBlocked: Bool
    var needsSetup: Bool
    var environmentStatus: EnvironmentStatus
    var currentDeviceStatus: DeviceStatus?
    var matchedDevice: DeviceInfo?
    var hasConfirmedDeviceThisSession: Bool
    var hasTrustedExpiry: Bool

    init(
        isBlocked: Bool = false,
        needsSetup: Bool = false,
        environmentStatus: EnvironmentStatus,
        currentDeviceStatus: DeviceStatus? = nil,
        matchedDevice: DeviceInfo? = nil,
        hasConfirmedDeviceThisSession: Bool = false,
        hasTrustedExpiry: Bool = false
    ) {
        self.isBlocked = isBlocked
        self.needsSetup = needsSetup
        self.environmentStatus = environmentStatus
        self.currentDeviceStatus = currentDeviceStatus
        self.matchedDevice = matchedDevice
        self.hasConfirmedDeviceThisSession = hasConfirmedDeviceThisSession
        self.hasTrustedExpiry = hasTrustedExpiry
    }
}

struct MenuBarStatusPresentation: Equatable {
    enum State: Equatable {
        case blocked
        case needsSetup
        case environmentError
        case scanError
        case waitingForUnlock
        case checking
        case countdown(seconds: Int)
        case preparing
        case deploying
        case refreshResult(MenuBarRefreshResult)
        case confirming
        case pairing
        case confirmationRequired
        case pairingRequired
        case xcodeUpdateRequired
        case wiredConnectionRequired
        case offline
        case pendingDetection
        case unknown
        case expiry(isExpired: Bool, isInProgress: Bool)
    }

    let state: State
    let title: String
    let iconTransitionIdentity: MenuBarIconTransitionIdentity
    let accessibilityLabel: String
    let titleFontStyle: MenuBarTitleFontStyle
    let titleTransitionGroup: MenuBarTitleTransitionGroup

    var titleWidthTier: MenuBarTitleWidthTier {
        switch state {
        case .countdown, .offline:
            return .compact
        default:
            break
        }

        if title == "异常" || title == "到期" || Self.isMinuteOnlyTitle(title) {
            return .compact
        }

        return .standard
    }

    static var blocked: MenuBarStatusPresentation {
        exceptional(
            state: .blocked,
            iconTransitionIdentity: .error,
            spokenStatus: "自动操作已阻止"
        )
    }

    static var needsSetup: MenuBarStatusPresentation {
        semantic(
            state: .needsSetup,
            title: "待配置",
            iconTransitionIdentity: .setup,
            spokenStatus: "尚未完成配置"
        )
    }

    static var environmentError: MenuBarStatusPresentation {
        exceptional(
            state: .environmentError,
            iconTransitionIdentity: .error,
            spokenStatus: "运行环境异常"
        )
    }

    static var scanError: MenuBarStatusPresentation {
        exceptional(
            state: .scanError,
            iconTransitionIdentity: .error,
            spokenStatus: "设备检查异常"
        )
    }

    static var waitingForUnlock: MenuBarStatusPresentation {
        semantic(
            state: .waitingForUnlock,
            title: "待解锁",
            iconTransitionIdentity: .attention,
            spokenStatus: "等待解锁 iPhone"
        )
    }

    static var checking: MenuBarStatusPresentation {
        semantic(
            state: .checking,
            title: "检查中",
            iconTransitionIdentity: .progress,
            spokenStatus: "正在检查"
        )
    }

    static func countdown(seconds: Int) -> MenuBarStatusPresentation {
        let clampedSeconds = max(seconds, 0)
        return semantic(
            state: .countdown(seconds: clampedSeconds),
            title: "\(clampedSeconds)s",
            iconTransitionIdentity: .attention,
            spokenStatus: "\(clampedSeconds) 秒后自动续期"
        )
    }

    static var preparing: MenuBarStatusPresentation {
        semantic(
            state: .preparing,
            title: "续签中",
            iconTransitionIdentity: .progress,
            spokenStatus: "正在准备续签"
        )
    }

    static var deploying: MenuBarStatusPresentation {
        semantic(
            state: .deploying,
            title: "续签中",
            iconTransitionIdentity: .progress,
            spokenStatus: "正在续签"
        )
    }

    static func refreshResult(
        _ result: MenuBarRefreshResult
    ) -> MenuBarStatusPresentation {
        refreshResult(result, trustedExpiry: nil)
    }

    static var confirming: MenuBarStatusPresentation {
        semantic(
            state: .confirming,
            title: "确认中",
            iconTransitionIdentity: .progress,
            spokenStatus: "正在确认设备连接"
        )
    }

    static var pairing: MenuBarStatusPresentation {
        semantic(
            state: .pairing,
            title: "配对中",
            iconTransitionIdentity: .progress,
            spokenStatus: "正在恢复设备连接"
        )
    }

    static var confirmationRequired: MenuBarStatusPresentation {
        semantic(
            state: .confirmationRequired,
            title: "需确认",
            iconTransitionIdentity: .attention,
            spokenStatus: "需要在 iPhone 上确认"
        )
    }

    static var pairingRequired: MenuBarStatusPresentation {
        semantic(
            state: .pairingRequired,
            title: "需配对",
            iconTransitionIdentity: .attention,
            spokenStatus: "需要重新配对 iPhone"
        )
    }

    static var xcodeUpdateRequired: MenuBarStatusPresentation {
        semantic(
            state: .xcodeUpdateRequired,
            title: "需升级",
            iconTransitionIdentity: .error,
            spokenStatus: "需要升级 Xcode"
        )
    }

    static var wiredConnectionRequired: MenuBarStatusPresentation {
        semantic(
            state: .wiredConnectionRequired,
            title: "需连线",
            iconTransitionIdentity: .attention,
            spokenStatus: "需要通过数据线连接 iPhone"
        )
    }

    static var offline: MenuBarStatusPresentation {
        semantic(
            state: .offline,
            title: "离线",
            iconTransitionIdentity: .offline,
            spokenStatus: "目标 iPhone 离线"
        )
    }

    static var pendingDetection: MenuBarStatusPresentation {
        semantic(
            state: .pendingDetection,
            title: "待检测",
            iconTransitionIdentity: .online,
            spokenStatus: "正在等待有效期信息"
        )
    }

    static var unknown: MenuBarStatusPresentation {
        exceptional(
            state: .unknown,
            iconTransitionIdentity: .attention,
            spokenStatus: "设备状态待确认"
        )
    }

    static func expiry(
        title: String,
        isExpired: Bool,
        isInProgress: Bool
    ) -> MenuBarStatusPresentation {
        let iconTransitionIdentity: MenuBarIconTransitionIdentity
        if isExpired {
            iconTransitionIdentity = .attention
        } else if isInProgress {
            iconTransitionIdentity = .progress
        } else {
            iconTransitionIdentity = .online
        }

        return MenuBarStatusPresentation(
            state: .expiry(
                isExpired: isExpired,
                isInProgress: isInProgress
            ),
            title: title,
            iconTransitionIdentity: iconTransitionIdentity,
            accessibilityLabel: isExpired
                ? "iOSSignKit，签名已到期"
                : isInProgress
                    ? "iOSSignKit，正在检查，剩余有效期 \(title)"
                    : "iOSSignKit，剩余有效期 \(title)",
            titleFontStyle: isExpired ? .status : .time,
            titleTransitionGroup: isExpired ? .semantic : .expiry
        )
    }

    static func make(
        context: MenuBarStatusContext,
        activity: MenuBarActivity,
        remainingExpiry: RemainingExpiryPresentation
    ) -> MenuBarStatusPresentation {
        let trustedExpiry = makeTrustedExpiry(
            context: context,
            remainingExpiry: remainingExpiry
        )
        let connectedTrustedExpiry: TrustedExpiry?
        if context.matchedDevice != nil
            || context.currentDeviceStatus == .confirming {
            connectedTrustedExpiry = trustedExpiry
        } else {
            connectedTrustedExpiry = nil
        }

        if context.isBlocked {
            return exceptional(
                state: .blocked,
                iconTransitionIdentity: .error,
                spokenStatus: "自动操作已阻止",
                trustedExpiry: trustedExpiry
            )
        }

        if context.needsSetup {
            return .needsSetup
        }

        if context.environmentStatus.isValidationComplete,
           !context.environmentStatus.areAllChecksPassing {
            return exceptional(
                state: .environmentError,
                iconTransitionIdentity: .error,
                spokenStatus: "运行环境异常",
                trustedExpiry: trustedExpiry
            )
        }

        if let persistentDeviceStatus = makePersistentDeviceStatus(
            context.currentDeviceStatus,
            trustedExpiry: trustedExpiry
        ) {
            return persistentDeviceStatus
        }

        switch activity {
        case .waitingForUnlock:
            return .waitingForUnlock
        case .countdown(let seconds):
            return .countdown(seconds: seconds)
        case .preparing:
            return .preparing
        case .deploying:
            return .deploying
        case .result(let result):
            return refreshResult(result, trustedExpiry: trustedExpiry)
        case .checking:
            return connectedTrustedExpiry.map {
                expiry(
                    title: $0.title,
                    isExpired: $0.isExpired,
                    isInProgress: true
                )
            } ?? .checking
        case .idle:
            break
        }

        if !context.environmentStatus.isValidationComplete {
            return connectedTrustedExpiry.map {
                expiry(
                    title: $0.title,
                    isExpired: $0.isExpired,
                    isInProgress: true
                )
            } ?? .checking
        }

        if context.currentDeviceStatus == .confirming {
            return connectedTrustedExpiry.map {
                expiry(
                    title: $0.title,
                    isExpired: $0.isExpired,
                    isInProgress: false
                )
            } ?? .confirming
        }

        guard context.matchedDevice != nil else {
            return .offline
        }

        if let connectedTrustedExpiry {
            return expiry(
                title: connectedTrustedExpiry.title,
                isExpired: connectedTrustedExpiry.isExpired,
                isInProgress: false
            )
        }

        return .pendingDetection
    }

    private struct TrustedExpiry {
        let title: String
        let isExpired: Bool
    }

    private static func makeTrustedExpiry(
        context: MenuBarStatusContext,
        remainingExpiry: RemainingExpiryPresentation
    ) -> TrustedExpiry? {
        guard context.hasConfirmedDeviceThisSession,
              context.hasTrustedExpiry,
              let title = remainingExpiry.menuBarText else {
            return nil
        }

        return TrustedExpiry(
            title: title,
            isExpired: remainingExpiry.isExpired
        )
    }

    private static func makePersistentDeviceStatus(
        _ status: DeviceStatus?,
        trustedExpiry: TrustedExpiry?
    ) -> MenuBarStatusPresentation? {
        switch status {
        case .scanFailed:
            exceptional(
                state: .scanError,
                iconTransitionIdentity: .error,
                spokenStatus: "设备检查异常",
                trustedExpiry: trustedExpiry
            )
        case .wirelessPairing:
            .pairing
        case .wirelessPairingConfirmationRequired:
            .confirmationRequired
        case .wirelessPairingRequired:
            .pairingRequired
        case .xcodeUpdateRequired:
            .xcodeUpdateRequired
        case .wiredConnectionRequired:
            .wiredConnectionRequired
        case .offline:
            .offline
        case .unrecognized:
            exceptional(
                state: .unknown,
                iconTransitionIdentity: .attention,
                spokenStatus: "设备状态待确认",
                trustedExpiry: trustedExpiry
            )
        case nil, .unknown, .online, .confirming:
            nil
        }
    }

    private static func refreshResult(
        _ result: MenuBarRefreshResult,
        trustedExpiry: TrustedExpiry?
    ) -> MenuBarStatusPresentation {
        switch result {
        case .succeeded:
            semantic(
                state: .refreshResult(.succeeded),
                title: "已续签",
                iconTransitionIdentity: .online,
                spokenStatus: "续签成功"
            )
        case .cancelled:
            semantic(
                state: .refreshResult(.cancelled),
                title: "已取消",
                iconTransitionIdentity: .attention,
                spokenStatus: "已取消"
            )
        case .failed:
            exceptional(
                state: .refreshResult(.failed),
                iconTransitionIdentity: .error,
                spokenStatus: "续签失败",
                trustedExpiry: trustedExpiry
            )
        case .interrupted:
            exceptional(
                state: .refreshResult(.interrupted),
                iconTransitionIdentity: .error,
                spokenStatus: "续签中断",
                trustedExpiry: trustedExpiry
            )
        case .unknown:
            exceptional(
                state: .refreshResult(.unknown),
                iconTransitionIdentity: .attention,
                spokenStatus: "续签结果待确认",
                trustedExpiry: trustedExpiry
            )
        }
    }

    private static func semantic(
        state: State,
        title: String,
        iconTransitionIdentity: MenuBarIconTransitionIdentity,
        spokenStatus: String
    ) -> MenuBarStatusPresentation {
        MenuBarStatusPresentation(
            state: state,
            title: title,
            iconTransitionIdentity: iconTransitionIdentity,
            accessibilityLabel: "iOSSignKit，\(spokenStatus)",
            titleFontStyle: .status,
            titleTransitionGroup: .semantic
        )
    }

    private static func exceptional(
        state: State,
        iconTransitionIdentity: MenuBarIconTransitionIdentity,
        spokenStatus: String,
        trustedExpiry: TrustedExpiry? = nil
    ) -> MenuBarStatusPresentation {
        guard let trustedExpiry else {
            return MenuBarStatusPresentation(
                state: state,
                title: "异常",
                iconTransitionIdentity: iconTransitionIdentity,
                accessibilityLabel: "iOSSignKit，\(spokenStatus)，打开面板查看详情",
                titleFontStyle: .status,
                titleTransitionGroup: .semantic
            )
        }

        let expiryDescription = trustedExpiry.isExpired
            ? "签名已到期"
            : "剩余有效期 \(trustedExpiry.title)"
        return MenuBarStatusPresentation(
            state: state,
            title: trustedExpiry.title,
            iconTransitionIdentity: iconTransitionIdentity,
            accessibilityLabel:
                "iOSSignKit，\(spokenStatus)，\(expiryDescription)，打开面板查看详情",
            titleFontStyle: trustedExpiry.isExpired ? .status : .time,
            titleTransitionGroup: trustedExpiry.isExpired ? .semantic : .expiry
        )
    }

    private static func isMinuteOnlyTitle(_ title: String) -> Bool {
        guard title.last == "m" else {
            return false
        }

        let numericPart = title.dropLast()
        return !numericPart.isEmpty && numericPart.allSatisfy(\.isNumber)
    }
}
