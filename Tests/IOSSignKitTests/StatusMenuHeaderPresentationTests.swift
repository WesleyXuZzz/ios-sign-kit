import AppKit
import Foundation
import Testing
@testable import IOSSignKit

struct StatusMenuHeaderPresentationTests {
    @Test
    func mapsPrimaryStatesToApprovedTwoLineContent() {
        let expiry = remainingExpiry(text: "6d12h")
        let cases: [(
            menuBar: MenuBarStatusPresentation,
            operationActivity: OperationActivityPresentation,
            headline: String,
            detail: String,
            tone: StatusTone
        )] = [
            (
                .expiry(
                    title: "6d12h",
                    isExpired: false,
                    isInProgress: false
                ),
                idleActivity,
                "运行正常",
                "剩余有效期 6d12h · 刚刚检查",
                .good
            ),
            (
                .expiry(
                    title: "6d12h",
                    isExpired: false,
                    isInProgress: true
                ),
                idleActivity,
                "正在检查",
                "上次确认剩余 6d12h。",
                .info
            ),
            (
                .expiry(
                    title: "到期",
                    isExpired: true,
                    isInProgress: false
                ),
                idleActivity,
                "签名已到期",
                "请立即续签。",
                .critical
            ),
            (
                .checking,
                idleActivity,
                "正在检查",
                "正在核对环境、设备和 App 有效期。",
                .info
            ),
            (
                .countdown(seconds: 5),
                idleActivity,
                "即将自动续期",
                "5 秒后开始，可在面板中取消。",
                .warning
            ),
            (
                .preparing,
                idleActivity,
                "正在准备续签",
                "正在检查设备、目标和签名条件。",
                .info
            ),
            (
                .deploying,
                idleActivity,
                "正在续签…",
                "正在构建并安装到目标 iPhone。",
                .info
            ),
            (
                .refreshResult(.succeeded),
                idleActivity,
                "续签成功",
                "有效期已更新为 6d12h。",
                .good
            ),
            (
                .refreshResult(.cancelled),
                idleActivity,
                "已取消",
                "本次续签未完成。",
                .neutral
            ),
            (
                .needsSetup,
                idleActivity,
                "尚未完成配置",
                "请选择项目、App 与目标设备。",
                .warning
            ),
            (
                .offline,
                idleActivity,
                "等待设备连接",
                "Example iPhone 当前未连接。",
                .neutral
            ),
            (
                .confirmationRequired,
                idleActivity,
                "需要在 iPhone 上确认",
                "请在目标 iPhone 上确认信任或配对请求。",
                .warning
            )
        ]

        for item in cases {
            let presentation = StatusMenuHeaderPresentation.make(
                menuBar: item.menuBar,
                environmentSummary: "运行环境正常",
                deviceName: "Example iPhone",
                operationActivity: item.operationActivity,
                lastErrorSummary: nil,
                remainingExpiry: expiry
            )

            #expect(presentation.headline == item.headline)
            #expect(presentation.detail == item.detail)
            #expect(presentation.tone == item.tone)
            #expect(
                presentation.accessibilityLabel
                    == "iOSSignKit，\(item.headline)，\(item.detail)"
            )
        }
    }

    @Test
    func problemsUseCurrentDiagnosticsButNeverHistoricalResults() {
        let currentFailure = activity(
            source: .currentFeedback,
            detail: "续签流程返回签名错误。"
        )
        let historicalFailure = activity(
            source: .historicalResult,
            detail: "旧的失败不应成为当前详情。"
        )

        let current = StatusMenuHeaderPresentation.make(
            menuBar: .refreshResult(.failed),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: currentFailure,
            lastErrorSummary: "回退错误",
            remainingExpiry: .unknown
        )
        #expect(current.headline == "续签失败")
        #expect(current.detail == "续签流程返回签名错误。")

        let historical = StatusMenuHeaderPresentation.make(
            menuBar: .refreshResult(.failed),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: historicalFailure,
            lastErrorSummary: "当前保存的错误",
            remainingExpiry: .unknown
        )
        #expect(historical.detail == "当前保存的错误")

        let healthy = StatusMenuHeaderPresentation.make(
            menuBar: .expiry(
                title: "6d12h",
                isExpired: false,
                isInProgress: false
            ),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: historicalFailure,
            lastErrorSummary: "旧的失败",
            remainingExpiry: remainingExpiry(text: "6d12h")
        )
        #expect(healthy.headline == "运行正常")
        #expect(healthy.detail == "剩余有效期 6d12h · 刚刚检查")
    }

    @Test
    func diagnosticDetailIsSingleLineAndBounded() {
        let longDetail =
            "  第一行\n第二行\t"
            + String(repeating: "错", count: 140)
            + "  "
        let presentation = StatusMenuHeaderPresentation.make(
            menuBar: .scanError,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: activity(
                source: .currentFeedback,
                detail: longDetail
            ),
            lastErrorSummary: nil,
            remainingExpiry: .unknown
        )

        #expect(!presentation.detail.contains("\n"))
        #expect(!presentation.detail.contains("\t"))
        #expect(presentation.detail.count == 120)
        #expect(presentation.detail.hasSuffix("…"))
    }

    @Test
    @MainActor
    func nativeHeaderKeepsFixedGeometryAndCombinedAccessibility() {
        let presentation = StatusMenuHeaderPresentation.make(
            menuBar: .expiry(
                title: "6d12h",
                isExpired: false,
                isInProgress: false
            ),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(text: "6d12h")
        )
        let view = StatusMenuHeaderView()

        view.update(presentation: presentation, image: nil)

        #expect(view.intrinsicContentSize == NSSize(width: 300, height: 54))
        #expect(view.frame.size == NSSize(width: 300, height: 54))
        #expect(view.accessibilityLabel() == presentation.accessibilityLabel)
        #expect(view.hitTest(.zero) == nil)
    }

    @Test
    func ringFractionExpressesRemainingValidity() {
        let day = 24 * 60 * 60
        let oneDayOffline = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(seconds: day)
        )
        #expect(abs(oneDayOffline.fraction - (1.0 / 7.0)) < 0.0001)

        let threeDaysTenHours = 3 * day + 10 * 60 * 60
        let partialDayOffline = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(seconds: threeDaysTenHours)
        )
        let partialDayExpected = Double(threeDaysTenHours) / Double(7 * day)
        #expect(abs(partialDayOffline.fraction - partialDayExpected) < 0.0001)

        let expiry = remainingExpiry(seconds: 3 * 24 * 60 * 60 + 12 * 60 * 60)
        let expected = (3.0 * 24 * 60 * 60 + 12 * 60 * 60) / (7.0 * 24 * 60 * 60)

        let healthy = StatusMenuHeaderPresentation.make(
            menuBar: .expiry(
                title: "3d12h",
                isExpired: false,
                isInProgress: false
            ),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: expiry
        )
        #expect(abs(healthy.fraction - expected) < 0.0001)

        let offline = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: expiry
        )
        #expect(abs(offline.fraction - expected) < 0.0001)

        let expired = StatusMenuHeaderPresentation.make(
            menuBar: .expiry(
                title: "到期",
                isExpired: true,
                isInProgress: false
            ),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: .unknown
        )
        #expect(expired.fraction == 0)

        let offlineUnknown = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: .unknown
        )
        #expect(offlineUnknown.fraction == 0)
    }

    @Test
    func centerTextShowsCompactRemainingOnlyForInformativeStates() {
        let days = StatusMenuHeaderPresentation.make(
            menuBar: .expiry(
                title: "3d12h",
                isExpired: false,
                isInProgress: false
            ),
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(seconds: 3 * 24 * 60 * 60 + 12 * 60 * 60)
        )
        #expect(days.centerText == "3")

        let hoursOffline = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(seconds: 5 * 60 * 60 + 30 * 60)
        )
        #expect(hoursOffline.centerText == "5")

        let deploying = StatusMenuHeaderPresentation.make(
            menuBar: .deploying,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(seconds: 3 * 24 * 60 * 60)
        )
        #expect(deploying.centerText == nil)

        let unknown = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: nil,
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: .unknown
        )
        #expect(unknown.centerText == nil)
    }

    @Test
    func offlineDetailCarriesRemainingAndLastSeenWhenAvailable() {
        let lastSeen = Date()
        let presentation = StatusMenuHeaderPresentation.make(
            menuBar: .offline,
            environmentSummary: nil,
            deviceName: "Example iPhone",
            operationActivity: idleActivity,
            lastErrorSummary: nil,
            remainingExpiry: remainingExpiry(
                seconds: 3 * 24 * 60 * 60,
                primaryComponent: ("3", "天")
            ),
            lastDeviceSeenAt: lastSeen
        )

        #expect(presentation.headline == "等待设备连接")
        #expect(presentation.detail.contains("签名剩余 3 天"))
        #expect(presentation.detail.contains("最后在线今天"))
    }
}

private let idleActivity = OperationActivityPresentation(
    kind: .idle,
    source: .idle,
    title: "暂无进行中的操作",
    detail: "状态与最近结果可在下方查看。",
    tone: .neutral,
    systemImage: "minus.circle",
    progress: nil,
    countdownSeconds: nil,
    actions: .none
)

private func activity(
    source: OperationActivitySource,
    detail: String
) -> OperationActivityPresentation {
    OperationActivityPresentation(
        kind: .failure,
        source: source,
        title: "续签失败",
        detail: detail,
        tone: .critical,
        systemImage: "xmark.octagon.fill",
        progress: nil,
        countdownSeconds: nil,
        actions: .recheck
    )
}

private func remainingExpiry(
    text: String
) -> RemainingExpiryPresentation {
    RemainingExpiryPresentation(
        panelText: "6 天 12 小时",
        metricComponents: [],
        menuBarText: text,
        isExpired: false,
        remainingSeconds: 6 * 24 * 60 * 60 + 12 * 60 * 60
    )
}

private func remainingExpiry(
    seconds: Int,
    primaryComponent: (String, String)? = nil
) -> RemainingExpiryPresentation {
    RemainingExpiryPresentation(
        panelText: "测试剩余",
        metricComponents: primaryComponent.map {
            [
                RemainingExpiryMetricComponent(
                    value: $0.0,
                    unit: $0.1
                )
            ]
        } ?? [],
        menuBarText: "测试",
        isExpired: false,
        remainingSeconds: seconds
    )
}
