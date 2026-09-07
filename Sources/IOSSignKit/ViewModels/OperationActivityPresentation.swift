import Foundation

enum OperationActivityKind: Equatable {
    case idle
    case checking
    case countdown
    case deploying
    case success
    case warning
    case failure
    case cancelled
    case info
}

enum OperationActivityProgress: Equatable {
    case indeterminate
    case fraction(Double)
}

enum OperationActivityActions: Equatable {
    case none
    case checking
    case countdown
    case deploying
    case success
    case recovery
    case recheck
    case retry
    case dismiss
}

enum OperationActivitySource: Equatable {
    case currentActivity
    case currentFeedback
    case historicalResult
    case idle
}

struct OperationActivityPresentation: Equatable {
    let kind: OperationActivityKind
    let source: OperationActivitySource
    let title: String
    let detail: String
    let tone: StatusTone
    let systemImage: String
    let progress: OperationActivityProgress?
    let countdownSeconds: Int?
    let actions: OperationActivityActions

    static func make(
        isReloadingEnvironment: Bool,
        pendingAutoRefreshCountdown: Int?,
        isDeploymentActive: Bool,
        isAwaitingDeployRecovery: Bool,
        isProcessRecoveryBlocked: Bool,
        isFeedbackDismissed: Bool,
        deployProgressText: String?,
        feedbackMessage: String?,
        feedbackResult: RefreshResult?,
        lastResult: RefreshResult?,
        lastErrorSummary: String?
    ) -> OperationActivityPresentation {
        let progressText = normalized(deployProgressText)
        let feedback = normalized(feedbackMessage)
        let lastError = normalized(lastErrorSummary)

        if isProcessRecoveryBlocked {
            return OperationActivityPresentation(
                kind: .failure,
                source: .currentActivity,
                title: "续签已阻止",
                detail: (lastError ?? "未能确认续签进程已经结束。")
                    + " 请重启 iOSSignKit 重新核验，核验通过后才会恢复续签。",
                tone: .critical,
                systemImage: "exclamationmark.octagon.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: .none
            )
        }

        if let pendingAutoRefreshCountdown {
            let seconds = max(pendingAutoRefreshCountdown, 0)
            let fraction = min(max(Double(seconds) / 5.0, 0), 1)
            return OperationActivityPresentation(
                kind: .countdown,
                source: .currentActivity,
                title: "\(seconds) 秒后自动续期",
                detail: "检测到 App 已到期。",
                tone: .warning,
                systemImage: "timer",
                progress: .fraction(fraction),
                countdownSeconds: seconds,
                actions: .countdown
            )
        }

        if isAwaitingDeployRecovery {
            return OperationActivityPresentation(
                kind: .warning,
                source: .currentActivity,
                title: "请解锁 iPhone",
                detail: feedback ?? progressText ?? "解锁后将自动恢复重试一次。",
                tone: .warning,
                systemImage: "lock.trianglebadge.exclamationmark",
                progress: nil,
                countdownSeconds: nil,
                actions: .recovery
            )
        }

        if isDeploymentActive {
            return OperationActivityPresentation(
                kind: .deploying,
                source: .currentActivity,
                title: "正在续签…",
                detail: activeDeploymentDetail(
                    progressText: progressText,
                    feedback: feedback
                ),
                tone: .info,
                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                progress: .indeterminate,
                countdownSeconds: nil,
                actions: .deploying
            )
        }

        if isReloadingEnvironment {
            return OperationActivityPresentation(
                kind: .checking,
                source: .currentActivity,
                title: "正在检查设备与安装状态",
                detail: "正在验证设备连接与 App 安装状态。",
                tone: .info,
                systemImage: "arrow.clockwise.circle.fill",
                progress: .indeterminate,
                countdownSeconds: nil,
                actions: .checking
            )
        }

        if isFeedbackDismissed {
            return idlePresentation()
        }

        let settledFeedback = isTransientCheckingFeedback(feedback) ? nil : feedback

        if let feedbackResult, let settledFeedback {
            return settledPresentation(
                result: feedbackResult,
                feedback: settledFeedback,
                progressText: progressText,
                lastError: lastError,
                source: .currentFeedback
            )
        }

        if containsAny(settledFeedback, terms: ["解锁", "设备准备", "等待 iPhone"]) {
            return OperationActivityPresentation(
                kind: .warning,
                source: .currentFeedback,
                title: "请解锁 iPhone",
                detail: settledFeedback ?? progressText ?? "解锁后再重新检查目标设备。",
                tone: .warning,
                systemImage: "lock.trianglebadge.exclamationmark",
                progress: nil,
                countdownSeconds: nil,
                actions: .recheck
            )
        }

        if containsAny(
            settledFeedback,
            terms: ["已取消", "取消本次", "已停止"]
        ) {
            return OperationActivityPresentation(
                kind: .cancelled,
                source: .currentFeedback,
                title: "已取消",
                detail: settledFeedback ?? "已取消本次续签。",
                tone: .neutral,
                systemImage: "minus.circle.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: .dismiss
            )
        }

        if let settledFeedback {
            return OperationActivityPresentation(
                kind: .info,
                source: .currentFeedback,
                title: "操作反馈",
                detail: settledFeedback,
                tone: .info,
                systemImage: "info.circle.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: .dismiss
            )
        }

        if let lastResult {
            return settledPresentation(
                result: lastResult,
                feedback: nil,
                progressText: progressText,
                lastError: lastError,
                source: .historicalResult
            )
        }

        return idlePresentation()
    }

    private static func idlePresentation(
        source: OperationActivitySource = .idle
    ) -> OperationActivityPresentation {
        OperationActivityPresentation(
            kind: .idle,
            source: source,
            title: "暂无进行中的操作",
            detail: "状态与最近结果可在下方查看。",
            tone: .neutral,
            systemImage: "minus.circle",
            progress: nil,
            countdownSeconds: nil,
            actions: .none
        )
    }

    private static func settledPresentation(
        result: RefreshResult,
        feedback: String?,
        progressText: String?,
        lastError: String?,
        source: OperationActivitySource
    ) -> OperationActivityPresentation {
        switch result {
        case .failure:
            return OperationActivityPresentation(
                kind: .failure,
                source: source,
                title: "续签失败",
                detail: feedback ?? lastError ?? progressText ?? "安装过程中发生错误。",
                tone: .critical,
                systemImage: "xmark.octagon.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: source == .currentFeedback ? .retry : .recheck
            )
        case .cancelled:
            return OperationActivityPresentation(
                kind: .cancelled,
                source: source,
                title: "已取消",
                detail: feedback ?? "已取消本次续签。",
                tone: .neutral,
                systemImage: "minus.circle.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: .dismiss
            )
        case .interrupted:
            return OperationActivityPresentation(
                kind: .warning,
                source: source,
                title: "续签已中断",
                detail: feedback ?? lastError ?? "续签流程未能正常完成。",
                tone: .warning,
                systemImage: "exclamationmark.triangle.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: .recheck
            )
        case .unrecognized:
            return OperationActivityPresentation(
                kind: .warning,
                source: source,
                title: "续签结果待确认",
                detail: feedback ?? lastError ?? "无法确认最近一次续签结果。",
                tone: .warning,
                systemImage: "questionmark.circle.fill",
                progress: nil,
                countdownSeconds: nil,
                actions: .recheck
            )
        case .running:
            return OperationActivityPresentation(
                kind: .warning,
                source: source,
                title: "正在恢复续签状态",
                detail: feedback ?? progressText ?? "正在确认上次续签进程是否已经结束。",
                tone: .warning,
                systemImage: "arrow.clockwise.circle.fill",
                progress: .indeterminate,
                countdownSeconds: nil,
                actions: .recheck
            )
        case .success:
            if feedback != nil || progressText != nil {
                return OperationActivityPresentation(
                    kind: .success,
                    source: source,
                    title: "续签成功",
                    detail: feedback ?? progressText ?? "目标 App 已完成续签。",
                    tone: .good,
                    systemImage: "checkmark.circle.fill",
                    progress: nil,
                    countdownSeconds: nil,
                    actions: .success
                )
            }
            return idlePresentation(source: source)
        }
    }

    private static func isTransientCheckingFeedback(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        return value == "正在检查设备与安装状态..."
            || value == "正在检查设备与安装状态…"
    }

    private static func activeDeploymentDetail(
        progressText: String?,
        feedback: String?
    ) -> String {
        for candidate in [progressText, feedback] {
            guard let candidate = normalized(candidate),
                  candidate.count <= 160,
                  !candidate.contains(where: \.isNewline) else {
                continue
            }
            return candidate
        }

        return "正在为目标 App 续签并安装到 iPhone。"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func containsAny(_ value: String?, terms: [String]) -> Bool {
        guard let value else {
            return false
        }

        return terms.contains { value.localizedCaseInsensitiveContains($0) }
    }
}
