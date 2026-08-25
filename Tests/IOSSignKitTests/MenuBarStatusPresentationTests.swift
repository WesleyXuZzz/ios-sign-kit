import Foundation
import Testing
@testable import IOSSignKit

struct MenuBarStatusPresentationTests {
    @Test
    func mapsEveryPresentationToItsVisibleContract() {
        let cases: [(
            presentation: MenuBarStatusPresentation,
            state: MenuBarStatusPresentation.State,
            title: String,
            icon: MenuBarIconTransitionIdentity,
            accessibilityLabel: String,
            transition: MenuBarTitleTransitionGroup,
            widthTier: MenuBarTitleWidthTier,
            fontStyle: MenuBarTitleFontStyle
        )] = [
            (
                .blocked,
                .blocked,
                "异常",
                .error,
                "iOSSignKit，自动操作已阻止，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .needsSetup,
                .needsSetup,
                "待配置",
                .setup,
                "iOSSignKit，尚未完成配置",
                .semantic,
                .standard,
                .status
            ),
            (
                .environmentError,
                .environmentError,
                "异常",
                .error,
                "iOSSignKit，运行环境异常，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .scanError,
                .scanError,
                "异常",
                .error,
                "iOSSignKit，设备检查异常，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .waitingForUnlock,
                .waitingForUnlock,
                "待解锁",
                .attention,
                "iOSSignKit，等待解锁 iPhone",
                .semantic,
                .standard,
                .status
            ),
            (
                .checking,
                .checking,
                "检查中",
                .progress,
                "iOSSignKit，正在检查",
                .semantic,
                .standard,
                .status
            ),
            (
                .countdown(seconds: 5),
                .countdown(seconds: 5),
                "5s",
                .attention,
                "iOSSignKit，5 秒后自动续期",
                .semantic,
                .compact,
                .status
            ),
            (
                .preparing,
                .preparing,
                "续签中",
                .progress,
                "iOSSignKit，正在准备续签",
                .semantic,
                .standard,
                .status
            ),
            (
                .deploying,
                .deploying,
                "续签中",
                .progress,
                "iOSSignKit，正在续签",
                .semantic,
                .standard,
                .status
            ),
            (
                .refreshResult(.succeeded),
                .refreshResult(.succeeded),
                "已续签",
                .online,
                "iOSSignKit，续签成功",
                .semantic,
                .standard,
                .status
            ),
            (
                .refreshResult(.failed),
                .refreshResult(.failed),
                "异常",
                .error,
                "iOSSignKit，续签失败，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .refreshResult(.cancelled),
                .refreshResult(.cancelled),
                "已取消",
                .attention,
                "iOSSignKit，已取消",
                .semantic,
                .standard,
                .status
            ),
            (
                .refreshResult(.interrupted),
                .refreshResult(.interrupted),
                "异常",
                .error,
                "iOSSignKit，续签中断，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .refreshResult(.unknown),
                .refreshResult(.unknown),
                "异常",
                .attention,
                "iOSSignKit，续签结果待确认，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .confirming,
                .confirming,
                "确认中",
                .progress,
                "iOSSignKit，正在确认设备连接",
                .semantic,
                .standard,
                .status
            ),
            (
                .pairing,
                .pairing,
                "配对中",
                .progress,
                "iOSSignKit，正在恢复设备连接",
                .semantic,
                .standard,
                .status
            ),
            (
                .confirmationRequired,
                .confirmationRequired,
                "需确认",
                .attention,
                "iOSSignKit，需要在 iPhone 上确认",
                .semantic,
                .standard,
                .status
            ),
            (
                .pairingRequired,
                .pairingRequired,
                "需配对",
                .attention,
                "iOSSignKit，需要重新配对 iPhone",
                .semantic,
                .standard,
                .status
            ),
            (
                .xcodeUpdateRequired,
                .xcodeUpdateRequired,
                "需升级",
                .error,
                "iOSSignKit，需要升级 Xcode",
                .semantic,
                .standard,
                .status
            ),
            (
                .wiredConnectionRequired,
                .wiredConnectionRequired,
                "需连线",
                .attention,
                "iOSSignKit，需要通过数据线连接 iPhone",
                .semantic,
                .standard,
                .status
            ),
            (
                .offline,
                .offline,
                "离线",
                .offline,
                "iOSSignKit，目标 iPhone 离线",
                .semantic,
                .compact,
                .status
            ),
            (
                .pendingDetection,
                .pendingDetection,
                "待检测",
                .online,
                "iOSSignKit，正在等待有效期信息",
                .semantic,
                .standard,
                .status
            ),
            (
                .unknown,
                .unknown,
                "异常",
                .attention,
                "iOSSignKit，设备状态待确认，打开面板查看详情",
                .semantic,
                .compact,
                .status
            ),
            (
                .expiry(title: "4d3h", isExpired: false, isInProgress: false),
                .expiry(isExpired: false, isInProgress: false),
                "4d3h",
                .online,
                "iOSSignKit，剩余有效期 4d3h",
                .expiry,
                .standard,
                .time
            ),
            (
                .expiry(title: "4d3h", isExpired: false, isInProgress: true),
                .expiry(isExpired: false, isInProgress: true),
                "4d3h",
                .progress,
                "iOSSignKit，正在检查，剩余有效期 4d3h",
                .expiry,
                .standard,
                .time
            ),
            (
                .expiry(title: "10h40m", isExpired: false, isInProgress: false),
                .expiry(isExpired: false, isInProgress: false),
                "10h40m",
                .online,
                "iOSSignKit，剩余有效期 10h40m",
                .expiry,
                .standard,
                .time
            ),
            (
                .expiry(title: "59m", isExpired: false, isInProgress: false),
                .expiry(isExpired: false, isInProgress: false),
                "59m",
                .online,
                "iOSSignKit，剩余有效期 59m",
                .expiry,
                .compact,
                .time
            ),
            (
                .expiry(title: "到期", isExpired: true, isInProgress: true),
                .expiry(isExpired: true, isInProgress: true),
                "到期",
                .attention,
                "iOSSignKit，签名已到期",
                .semantic,
                .compact,
                .status
            )
        ]

        for item in cases {
            #expect(item.presentation.state == item.state)
            #expect(item.presentation.title == item.title)
            #expect(item.presentation.iconTransitionIdentity == item.icon)
            #expect(item.presentation.accessibilityLabel == item.accessibilityLabel)
            #expect(item.presentation.titleTransitionGroup == item.transition)
            #expect(item.presentation.titleWidthTier == item.widthTier)
            #expect(item.presentation.titleFontStyle == item.fontStyle)
        }
    }

    @Test
    func appliesPersistentStatusPriorityBeforeActivityAndExpiry() {
        let trustedExpiry = makeRemainingExpiry(seconds: 4 * day)
        let cases: [(
            context: MenuBarStatusContext,
            activity: MenuBarActivity,
            expectedState: MenuBarStatusPresentation.State,
            expectedTitle: String,
            expectedIcon: MenuBarIconTransitionIdentity
        )] = [
            (
                makeContext(
                    isBlocked: true,
                    needsSetup: true,
                    environmentStatus: .unknown,
                    currentDeviceStatus: .scanFailed,
                    matchedDevice: exampleDevice,
                    hasConfirmedDeviceThisSession: true,
                    hasTrustedExpiry: true
                ),
                .deploying,
                .blocked,
                "4d0h",
                .error
            ),
            (
                makeContext(
                    needsSetup: true,
                    environmentStatus: failedEnvironmentStatus,
                    matchedDevice: exampleDevice,
                    hasConfirmedDeviceThisSession: true,
                    hasTrustedExpiry: true
                ),
                .result(.succeeded),
                .needsSetup,
                "待配置",
                .setup
            ),
            (
                makeContext(
                    environmentStatus: failedEnvironmentStatus,
                    matchedDevice: exampleDevice,
                    hasConfirmedDeviceThisSession: true,
                    hasTrustedExpiry: true
                ),
                .deploying,
                .environmentError,
                "4d0h",
                .error
            ),
            (
                makeContext(
                    currentDeviceStatus: .scanFailed,
                    matchedDevice: exampleDevice,
                    hasConfirmedDeviceThisSession: true,
                    hasTrustedExpiry: true
                ),
                .result(.succeeded),
                .scanError,
                "4d0h",
                .error
            ),
            (
                makeContext(
                    currentDeviceStatus: .wirelessPairingConfirmationRequired,
                    matchedDevice: exampleDevice,
                    hasConfirmedDeviceThisSession: true,
                    hasTrustedExpiry: true
                ),
                .checking,
                .confirmationRequired,
                "需确认",
                .attention
            ),
            (
                makeContext(
                    currentDeviceStatus: .offline,
                    matchedDevice: exampleDevice,
                    hasConfirmedDeviceThisSession: true,
                    hasTrustedExpiry: true
                ),
                .preparing,
                .offline,
                "离线",
                .offline
            )
        ]

        for item in cases {
            let presentation = MenuBarStatusPresentation.make(
                context: item.context,
                activity: item.activity,
                remainingExpiry: trustedExpiry
            )
            #expect(presentation.state == item.expectedState)
            #expect(presentation.title == item.expectedTitle)
            #expect(presentation.iconTransitionIdentity == item.expectedIcon)
        }
    }

    @Test
    func exceptionsKeepTrustedExpiryAndUseCompactFallbackWithoutIt() {
        let trustedContext = makeContext(
            matchedDevice: exampleDevice,
            hasConfirmedDeviceThisSession: true,
            hasTrustedExpiry: true
        )
        let untrustedContext = makeContext(
            matchedDevice: exampleDevice,
            hasConfirmedDeviceThisSession: true,
            hasTrustedExpiry: false
        )
        let expiry = makeRemainingExpiry(seconds: 4 * day + 3 * hour)

        let trustedFailure = MenuBarStatusPresentation.make(
            context: trustedContext,
            activity: .result(.failed),
            remainingExpiry: expiry
        )
        let untrustedFailure = MenuBarStatusPresentation.make(
            context: untrustedContext,
            activity: .result(.failed),
            remainingExpiry: expiry
        )

        #expect(trustedFailure.state == .refreshResult(.failed))
        #expect(trustedFailure.title == "4d3h")
        #expect(trustedFailure.titleWidthTier == .standard)
        #expect(
            trustedFailure.accessibilityLabel
                == "iOSSignKit，续签失败，剩余有效期 4d3h，打开面板查看详情"
        )

        #expect(untrustedFailure.state == .refreshResult(.failed))
        #expect(untrustedFailure.title == "异常")
        #expect(untrustedFailure.titleWidthTier == .compact)
        #expect(
            untrustedFailure.accessibilityLabel
                == "iOSSignKit，续签失败，打开面板查看详情"
        )
    }

    @Test
    func exceptionsChooseWidthTierFromTrustedExpiryFormat() {
        let trustedContext = makeContext(
            matchedDevice: exampleDevice,
            hasConfirmedDeviceThisSession: true,
            hasTrustedExpiry: true
        )
        let cases: [(
            remainingExpiry: RemainingExpiryPresentation,
            title: String,
            widthTier: MenuBarTitleWidthTier
        )] = [
            (
                makeRemainingExpiry(seconds: 4 * day + 3 * hour),
                "4d3h",
                .standard
            ),
            (
                makeRemainingExpiry(seconds: 10 * hour + 40 * minute),
                "10h40m",
                .standard
            ),
            (
                makeRemainingExpiry(seconds: 59 * minute),
                "59m",
                .compact
            ),
            (
                makeRemainingExpiry(seconds: 0),
                "到期",
                .compact
            )
        ]

        for item in cases {
            let presentation = MenuBarStatusPresentation.make(
                context: trustedContext,
                activity: .result(.failed),
                remainingExpiry: item.remainingExpiry
            )

            #expect(presentation.title == item.title)
            #expect(presentation.titleWidthTier == item.widthTier)
            #expect(presentation.iconTransitionIdentity == .error)
        }
    }

    @Test
    func mapsEveryDeviceRecoveryStatusInsideMenuBarPresentation() {
        let cases: [(DeviceStatus, MenuBarStatusPresentation)] = [
            (.scanFailed, .scanError),
            (.wirelessPairing, .pairing),
            (.wirelessPairingConfirmationRequired, .confirmationRequired),
            (.wirelessPairingRequired, .pairingRequired),
            (.xcodeUpdateRequired, .xcodeUpdateRequired),
            (.wiredConnectionRequired, .wiredConnectionRequired),
            (.offline, .offline),
            (.unrecognized("future"), .unknown)
        ]

        for (deviceStatus, expected) in cases {
            let presentation = MenuBarStatusPresentation.make(
                context: makeContext(
                    currentDeviceStatus: deviceStatus,
                    matchedDevice: exampleDevice
                ),
                activity: .idle,
                remainingExpiry: .unknown
            )

            #expect(presentation == expected)
        }
    }

    @Test
    func incompleteEnvironmentIsCheckingRatherThanAnError() {
        let presentation = MenuBarStatusPresentation.make(
            context: makeContext(environmentStatus: .unknown),
            activity: .idle,
            remainingExpiry: .unknown
        )

        #expect(presentation == .checking)
    }

    @Test
    func checkingKeepsTrustedExpiryForTheConfirmedConnection() {
        let presentation = MenuBarStatusPresentation.make(
            context: makeContext(
                matchedDevice: exampleDevice,
                hasConfirmedDeviceThisSession: true,
                hasTrustedExpiry: true
            ),
            activity: .checking,
            remainingExpiry: makeRemainingExpiry(seconds: 4 * day + 3 * hour)
        )

        #expect(
            presentation == .expiry(
                title: "4d3h",
                isExpired: false,
                isInProgress: true
            )
        )
    }

    @Test
    func checkingDoesNotUseCachedExpiryBeforeThisSessionConfirmsTheDevice() {
        let presentation = MenuBarStatusPresentation.make(
            context: makeContext(
                matchedDevice: exampleDevice,
                hasConfirmedDeviceThisSession: false,
                hasTrustedExpiry: true
            ),
            activity: .checking,
            remainingExpiry: makeRemainingExpiry(seconds: 4 * day)
        )

        #expect(presentation == .checking)
    }

    @Test
    func confirmingKeepsTrustedExpiryFromThePreviouslyConfirmedConnection() {
        let presentation = MenuBarStatusPresentation.make(
            context: makeContext(
                currentDeviceStatus: .confirming,
                matchedDevice: nil,
                hasConfirmedDeviceThisSession: true,
                hasTrustedExpiry: true
            ),
            activity: .idle,
            remainingExpiry: makeRemainingExpiry(seconds: 23 * hour)
        )

        #expect(
            presentation == .expiry(
                title: "23h0m",
                isExpired: false,
                isInProgress: false
            )
        )
        #expect(presentation.iconTransitionIdentity == .online)
    }

    @Test
    func confirmingWithoutTrustedExpiryUsesConfirmingStatus() {
        let presentation = MenuBarStatusPresentation.make(
            context: makeContext(
                currentDeviceStatus: .confirming,
                hasConfirmedDeviceThisSession: true,
                hasTrustedExpiry: false
            ),
            activity: .idle,
            remainingExpiry: makeRemainingExpiry(seconds: 23 * hour)
        )

        #expect(presentation == .confirming)
    }

    @Test
    func activeOperationsAndCurrentResultsOverrideTrustedExpiry() {
        let context = makeContext(
            matchedDevice: exampleDevice,
            hasConfirmedDeviceThisSession: true,
            hasTrustedExpiry: true
        )
        let expiry = makeRemainingExpiry(seconds: 4 * day)
        let cases: [(
            activity: MenuBarActivity,
            state: MenuBarStatusPresentation.State,
            title: String,
            icon: MenuBarIconTransitionIdentity
        )] = [
            (.waitingForUnlock, .waitingForUnlock, "待解锁", .attention),
            (.countdown(seconds: 4), .countdown(seconds: 4), "4s", .attention),
            (.preparing, .preparing, "续签中", .progress),
            (.deploying, .deploying, "续签中", .progress),
            (
                .result(.succeeded),
                .refreshResult(.succeeded),
                "已续签",
                .online
            ),
            (
                .result(.failed),
                .refreshResult(.failed),
                "4d0h",
                .error
            ),
            (
                .result(.cancelled),
                .refreshResult(.cancelled),
                "已取消",
                .attention
            ),
            (
                .result(.interrupted),
                .refreshResult(.interrupted),
                "4d0h",
                .error
            ),
            (
                .result(.unknown),
                .refreshResult(.unknown),
                "4d0h",
                .attention
            )
        ]

        for item in cases {
            let presentation = MenuBarStatusPresentation.make(
                context: context,
                activity: item.activity,
                remainingExpiry: expiry
            )
            #expect(presentation.state == item.state)
            #expect(presentation.title == item.title)
            #expect(presentation.iconTransitionIdentity == item.icon)
        }
    }

    @Test
    func activitiesAndResultsRemainVisibleWithoutTrustedExpiry() {
        let context = makeContext(
            matchedDevice: exampleDevice,
            hasConfirmedDeviceThisSession: true,
            hasTrustedExpiry: false
        )
        let cases: [(MenuBarActivity, MenuBarStatusPresentation)] = [
            (.checking, .checking),
            (.countdown(seconds: 4), .countdown(seconds: 4)),
            (.preparing, .preparing),
            (.deploying, .deploying),
            (.waitingForUnlock, .waitingForUnlock),
            (.result(.succeeded), .refreshResult(.succeeded)),
            (.result(.failed), .refreshResult(.failed)),
            (.result(.cancelled), .refreshResult(.cancelled)),
            (.result(.interrupted), .refreshResult(.interrupted)),
            (.result(.unknown), .refreshResult(.unknown))
        ]

        for (activity, expected) in cases {
            #expect(
                MenuBarStatusPresentation.make(
                    context: context,
                    activity: activity,
                    remainingExpiry: makeRemainingExpiry(seconds: 4 * day)
                ) == expected
            )
        }
    }

    @Test
    func expiredExpiryAlwaysUsesAttentionIcon() {
        let presentation = MenuBarStatusPresentation.make(
            context: makeContext(
                matchedDevice: exampleDevice,
                hasConfirmedDeviceThisSession: true,
                hasTrustedExpiry: true
            ),
            activity: .checking,
            remainingExpiry: makeRemainingExpiry(seconds: 0)
        )

        #expect(presentation.title == "到期")
        #expect(presentation.iconTransitionIdentity == .attention)
    }

    @Test
    func fallsBackToConnectionStateWithoutTrustedExpiry() {
        let online = MenuBarStatusPresentation.make(
            context: makeContext(
                currentDeviceStatus: .online,
                matchedDevice: exampleDevice,
                hasConfirmedDeviceThisSession: true
            ),
            activity: .idle,
            remainingExpiry: .unknown
        )
        let offline = MenuBarStatusPresentation.make(
            context: makeContext(currentDeviceStatus: .unknown),
            activity: .idle,
            remainingExpiry: .unknown
        )

        #expect(online == .pendingDetection)
        #expect(offline == .offline)
    }

    @Test
    func convertsPersistedRefreshResultsToTransientMenuBarResults() {
        let cases: [(RefreshResult, MenuBarRefreshResult)] = [
            (.success, .succeeded),
            (.failure, .failed),
            (.cancelled, .cancelled),
            (.interrupted, .interrupted),
            (.running, .unknown),
            (.unrecognized("future"), .unknown)
        ]

        for (result, expected) in cases {
            #expect(MenuBarRefreshResult(result) == expected)
        }
    }

    @Test
    func clampsNegativeCountdownToZeroInVisibleTitle() {
        #expect(MenuBarStatusPresentation.countdown(seconds: -1).title == "0s")
    }
}

private func makeContext(
    isBlocked: Bool = false,
    needsSetup: Bool = false,
    environmentStatus: EnvironmentStatus = readyEnvironmentStatus,
    currentDeviceStatus: DeviceStatus? = nil,
    matchedDevice: DeviceInfo? = nil,
    hasConfirmedDeviceThisSession: Bool = false,
    hasTrustedExpiry: Bool = false
) -> MenuBarStatusContext {
    MenuBarStatusContext(
        isBlocked: isBlocked,
        needsSetup: needsSetup,
        environmentStatus: environmentStatus,
        currentDeviceStatus: currentDeviceStatus,
        matchedDevice: matchedDevice,
        hasConfirmedDeviceThisSession: hasConfirmedDeviceThisSession,
        hasTrustedExpiry: hasTrustedExpiry
    )
}

private func makeRemainingExpiry(seconds: TimeInterval) -> RemainingExpiryPresentation {
    RemainingExpiryPresentation.make(
        expiryDate: testNow.addingTimeInterval(seconds),
        now: testNow
    )
}

private let testNow = Date(timeIntervalSinceReferenceDate: 0)
private let minute: TimeInterval = 60
private let hour = minute * 60
private let day = hour * 24

private let readyEnvironmentStatus = EnvironmentStatus(
    isXcodebuildAvailable: true,
    isXcrunAvailable: true,
    isProjectPathValid: true,
    isApplicationTargetResolved: true,
    summary: "环境检查通过，可以开始使用。"
)

private let failedEnvironmentStatus = EnvironmentStatus(
    isXcodebuildAvailable: true,
    isXcrunAvailable: true,
    isProjectPathValid: false,
    isApplicationTargetResolved: true,
    summary: "项目目录不可用。"
)

private let exampleDevice = DeviceInfo(
    id: "iphone-1",
    name: "Example iPhone",
    platform: "com.apple.platform.iphoneos",
    osVersion: "18.4",
    isAvailable: true,
    isPaired: true
)
