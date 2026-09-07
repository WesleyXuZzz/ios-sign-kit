import Testing
@testable import IOSSignKit

struct OperationActivityPresentationTests {
    @Test
    func offlineFeedbackCannotReplaceRecoveryFailure() {
        let reason = "读取进程表失败：Command timed out after 1.0 seconds."
        let presentation = makePresentation(
            isProcessRecoveryBlocked: true,
            feedbackMessage: "固定的目标 iPhone 当前不可用，不会回退到其他设备。",
            lastResult: .interrupted,
            lastErrorSummary: reason
        )
        #expect(presentation.detail.contains(reason))
        #expect(!presentation.detail.contains("iPhone 当前不可用"))
    }

    @Test
    func recoveryFailureWithoutDiagnosticDoesNotBorrowDeviceFeedback() {
        let presentation = makePresentation(
            isProcessRecoveryBlocked: true,
            feedbackMessage: "固定的目标 iPhone 当前不可用，不会回退到其他设备。"
        )
        #expect(presentation.detail.contains("未能确认"))
        #expect(!presentation.detail.contains("iPhone 当前不可用"))
    }

    @Test
    func prioritizesProcessRecoveryBlocker() {
        let presentation = makePresentation(
            isReloadingEnvironment: true,
            pendingAutoRefreshCountdown: 4,
            isDeploymentActive: true,
            isProcessRecoveryBlocked: true,
            feedbackMessage: "续签进程树未确认结束。"
        )

        #expect(presentation.kind == .failure)
        #expect(presentation.source == .currentActivity)
        #expect(presentation.title == "续签已阻止")
        #expect(presentation.tone == .critical)
        #expect(presentation.actions == .none)
    }

    @Test
    func presentsCountdownWithStableFraction() {
        let presentation = makePresentation(
            pendingAutoRefreshCountdown: 3
        )

        #expect(presentation.kind == .countdown)
        #expect(presentation.title == "3 秒后自动续期")
        #expect(presentation.detail == "检测到 App 已到期。")
        #expect(presentation.progress == .fraction(0.6))
        #expect(presentation.countdownSeconds == 3)
        #expect(presentation.actions == .countdown)
    }

    @Test
    func presentsDeploymentPreflightAsActiveWork() {
        let presentation = makePresentation(
            isDeploymentActive: true,
            deployProgressText: "正在确认 Xcode destination..."
        )

        #expect(presentation.kind == .deploying)
        #expect(presentation.title == "正在续签…")
        #expect(presentation.detail == "正在确认 Xcode destination...")
        #expect(presentation.progress == .indeterminate)
        #expect(presentation.actions == .deploying)
    }

    @Test
    func replacesOversizedDeploymentOutputWithStableStatusCopy() {
        let presentation = makePresentation(
            isDeploymentActive: true,
            deployProgressText: String(
                repeating: "/very/long/build/path ",
                count: 20
            )
        )

        #expect(presentation.kind == .deploying)
        #expect(presentation.detail == "正在为目标 App 续签并安装到 iPhone。")
    }

    @Test
    func presentsAutomaticRecoveryAsActionableWarning() {
        let presentation = makePresentation(
            isAwaitingDeployRecovery: true,
            feedbackMessage: "设备准备失败，解锁后将自动恢复重试一次。"
        )

        #expect(presentation.kind == .warning)
        #expect(presentation.title == "请解锁 iPhone")
        #expect(presentation.tone == .warning)
        #expect(presentation.actions == .recovery)
    }

    @Test
    func presentsCheckingBeforePassiveFeedback() {
        let presentation = makePresentation(
            isReloadingEnvironment: true,
            isFeedbackDismissed: true,
            feedbackMessage: "正在检查设备与安装状态..."
        )

        #expect(presentation.kind == .checking)
        #expect(presentation.title == "正在检查设备与安装状态")
        #expect(presentation.progress == .indeterminate)
        #expect(presentation.actions == .checking)
    }

    @Test
    func ignoresTransientCheckingCopyAfterCheckSettles() {
        let presentation = makePresentation(
            feedbackMessage: "正在检查设备与安装状态...",
            lastResult: .failure,
            lastErrorSummary: "无法验证目标设备的稳定身份。"
        )

        #expect(presentation.kind == .failure)
        #expect(presentation.source == .historicalResult)
        #expect(presentation.detail == "无法验证目标设备的稳定身份。")
    }

    @Test
    func dismissedSettledFeedbackFallsBackToIdle() {
        let presentation = makePresentation(
            isFeedbackDismissed: true,
            feedbackMessage: "安装过程中发生错误。",
            lastResult: .failure,
            lastErrorSummary: "签名失败。"
        )

        #expect(presentation.kind == .idle)
        #expect(presentation.source == .idle)
        #expect(presentation.title == "暂无进行中的操作")
        #expect(presentation.actions == .none)
    }

    @Test
    func mapsSettledResultsToSemanticStates() {
        let success = makePresentation(
            feedbackMessage: "新的预计过期时间是 8月4日 10:30。",
            feedbackResult: .success,
            lastResult: .success
        )
        let failure = makePresentation(
            feedbackMessage: "安装过程中发生错误。",
            feedbackResult: .failure,
            lastResult: .failure
        )
        let cancelled = makePresentation(
            feedbackMessage: "已取消本次续签。",
            feedbackResult: .cancelled,
            lastResult: .cancelled
        )

        #expect(success.kind == .success)
        #expect(success.source == .currentFeedback)
        #expect(success.tone == .good)
        #expect(success.actions == .success)
        #expect(failure.kind == .failure)
        #expect(failure.tone == .critical)
        #expect(failure.actions == .retry)
        #expect(cancelled.kind == .cancelled)
        #expect(cancelled.tone == .neutral)
        #expect(cancelled.actions == .dismiss)
    }

    @Test
    func currentCancellationAndUnlockFeedbackRemainActionable() {
        let cancellation = makePresentation(
            feedbackMessage: "已取消本次自动续期。",
            feedbackResult: .cancelled
        )
        let unlock = makePresentation(
            feedbackMessage: "请解锁 iPhone 后再续签。"
        )

        #expect(cancellation.kind == .cancelled)
        #expect(cancellation.title == "已取消")
        #expect(unlock.kind == .warning)
        #expect(unlock.title == "请解锁 iPhone")
        #expect(unlock.actions == .recheck)
    }

    @Test
    func genericFeedbackDoesNotInheritHistoricalDeploymentFailure() {
        let presentation = makePresentation(
            feedbackMessage: "更新启动自启失败：没有权限。",
            lastResult: .failure,
            lastErrorSummary: "旧续签签名失败。"
        )

        #expect(presentation.kind == .info)
        #expect(presentation.title == "操作反馈")
        #expect(presentation.detail == "更新启动自启失败：没有权限。")
        #expect(presentation.actions == .dismiss)
    }

    @Test
    func fallsBackToInfoAndIdleStates() {
        let info = makePresentation(feedbackMessage: "无线配对成功，正在重新检查。")
        let idle = makePresentation()

        #expect(info.kind == .info)
        #expect(info.source == .currentFeedback)
        #expect(info.detail == "无线配对成功，正在重新检查。")
        #expect(idle.kind == .idle)
        #expect(idle.source == .idle)
        #expect(idle.title == "暂无进行中的操作")
        #expect(idle.detail == "状态与最近结果可在下方查看。")
    }

    private func makePresentation(
        isReloadingEnvironment: Bool = false,
        pendingAutoRefreshCountdown: Int? = nil,
        isDeploymentActive: Bool = false,
        isAwaitingDeployRecovery: Bool = false,
        isProcessRecoveryBlocked: Bool = false,
        isFeedbackDismissed: Bool = false,
        deployProgressText: String? = nil,
        feedbackMessage: String? = nil,
        feedbackResult: RefreshResult? = nil,
        lastResult: RefreshResult? = nil,
        lastErrorSummary: String? = nil
    ) -> OperationActivityPresentation {
        OperationActivityPresentation.make(
            isReloadingEnvironment: isReloadingEnvironment,
            pendingAutoRefreshCountdown: pendingAutoRefreshCountdown,
            isDeploymentActive: isDeploymentActive,
            isAwaitingDeployRecovery: isAwaitingDeployRecovery,
            isProcessRecoveryBlocked: isProcessRecoveryBlocked,
            isFeedbackDismissed: isFeedbackDismissed,
            deployProgressText: deployProgressText,
            feedbackMessage: feedbackMessage,
            feedbackResult: feedbackResult,
            lastResult: lastResult,
            lastErrorSummary: lastErrorSummary
        )
    }
}
