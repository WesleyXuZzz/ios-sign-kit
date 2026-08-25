import Foundation

struct StatusMenuHeaderPresentation: Equatable {
    let tone: StatusTone
    let fraction: Double
    let headline: String
    let detail: String
    /// 设计稿 M2：菜单头微环中心的剩余天数数字；动态态与未知有效期为 nil。
    let centerText: String?

    var accessibilityLabel: String {
        "iOSSignKit，\(headline)，\(detail)"
    }

    static func make(
        menuBar: MenuBarStatusPresentation,
        environmentSummary: String?,
        deviceName: String?,
        operationActivity: OperationActivityPresentation,
        lastErrorSummary: String?,
        remainingExpiry: RemainingExpiryPresentation,
        lastDeviceSeenAt: Date? = nil
    ) -> StatusMenuHeaderPresentation {
        let currentOperationDetail = currentDetail(from: operationActivity)
        let environmentDetail = normalized(environmentSummary)
        let deviceDetail = normalized(deviceName)
        let lastErrorDetail = normalized(lastErrorSummary)

        switch menuBar.state {
        case .blocked:
            return presentation(
                menuBar: menuBar,
                tone: .critical,
                headline: "自动操作已阻止",
                detail:
                    currentOperationDetail
                    ?? lastErrorDetail
                    ?? "请打开面板检查并解除阻断。"
            )

        case .needsSetup:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "尚未完成配置",
                detail: "请选择项目、App 与目标设备。"
            )

        case .environmentError:
            return presentation(
                menuBar: menuBar,
                tone: .critical,
                headline: "运行环境异常",
                detail:
                    environmentDetail
                    ?? currentOperationDetail
                    ?? lastErrorDetail
                    ?? "请打开面板检查运行环境。"
            )

        case .scanError:
            return presentation(
                menuBar: menuBar,
                tone: .critical,
                headline: "设备检查异常",
                detail:
                    currentOperationDetail
                    ?? lastErrorDetail
                    ?? "暂时无法读取目标 iPhone 状态。"
            )

        case .waitingForUnlock:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "请解锁 iPhone",
                detail:
                    currentOperationDetail
                    ?? "解锁后将自动恢复重试一次。"
            )

        case .checking:
            return presentation(
                menuBar: menuBar,
                tone: .info,
                headline: "正在检查",
                detail: "正在核对环境、设备和 App 有效期。"
            )

        case .countdown(let seconds):
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "即将自动续期",
                detail: "\(seconds) 秒后开始，可在面板中取消。"
            )

        case .preparing:
            return presentation(
                menuBar: menuBar,
                tone: .info,
                headline: "正在准备续签",
                detail:
                    currentOperationDetail
                    ?? "正在检查设备、目标和签名条件。"
            )

        case .deploying:
            return presentation(
                menuBar: menuBar,
                tone: .info,
                headline: "正在续签…",
                detail:
                    currentOperationDetail
                    ?? "正在构建并安装到目标 iPhone。"
            )

        case .refreshResult(let result):
            return refreshResultPresentation(
                result,
                menuBar: menuBar,
                currentOperationDetail: currentOperationDetail,
                lastErrorDetail: lastErrorDetail,
                remainingExpiry: remainingExpiry
            )

        case .confirming:
            return presentation(
                menuBar: menuBar,
                tone: .info,
                headline: "正在确认连接",
                detail: "正在重新确认目标 iPhone 是否在线。"
            )

        case .pairing:
            return presentation(
                menuBar: menuBar,
                tone: .info,
                headline: "正在恢复连接",
                detail: "正在尝试与目标 iPhone 建立无线配对。"
            )

        case .confirmationRequired:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "需要在 iPhone 上确认",
                detail: "请在目标 iPhone 上确认信任或配对请求。"
            )

        case .pairingRequired:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "需要重新配对",
                detail: "请连接目标 iPhone，并按提示完成配对。"
            )

        case .xcodeUpdateRequired:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "需要升级 Xcode",
                detail: "当前 Xcode 无法支持目标 iPhone 系统版本。"
            )

        case .wiredConnectionRequired:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "需要数据线连接",
                detail: "请先通过数据线连接目标 iPhone。"
            )

        case .offline:
            // 设计稿 M2-3：headline「等待设备连接」，detail 承载剩余有效期与最后在线时间。
            var parts: [String] = []
            if let remainingSummary = primaryRemainingSummary(from: remainingExpiry) {
                parts.append("签名剩余 \(remainingSummary)")
            }
            if let lastDeviceSeenAt {
                let seenText = VerificationTimePresentation.make(
                    date: lastDeviceSeenAt
                ).absoluteText
                parts.append("最后在线\(seenText)")
            }
            let fallbackDetail = deviceDetail.map { "\($0) 当前未连接。" }
                ?? "连接设备后将自动继续检查。"
            return presentation(
                menuBar: menuBar,
                tone: .neutral,
                headline: "等待设备连接",
                detail: parts.isEmpty
                    ? fallbackDetail
                    : parts.joined(separator: " · "),
                remainingExpiry: remainingExpiry,
                centerText: compactCenterText(from: remainingExpiry)
            )

        case .pendingDetection:
            return presentation(
                menuBar: menuBar,
                tone: .neutral,
                headline: "正在等待有效期",
                detail: "设备已连接，尚未取得可信的 App 有效期。"
            )

        case .unknown:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "设备状态待确认",
                detail:
                    currentOperationDetail
                    ?? lastErrorDetail
                    ?? "请重新检查目标 iPhone 状态。"
            )

        case .expiry(let isExpired, let isInProgress):
            if isExpired {
                return presentation(
                    menuBar: menuBar,
                    tone: .critical,
                    headline: "签名已到期",
                    detail: "请立即续签。"
                )
            }

            if isInProgress {
                return presentation(
                    menuBar: menuBar,
                    tone: .info,
                    headline: "正在检查",
                    detail: "上次确认剩余 \(menuBar.title)。"
                )
            }

            return presentation(
                menuBar: menuBar,
                tone: .good,
                headline: "运行正常",
                detail: "剩余有效期 \(menuBar.title) · 刚刚检查",
                remainingExpiry: remainingExpiry,
                centerText: compactCenterText(from: remainingExpiry)
            )
        }
    }

    private static func refreshResultPresentation(
        _ result: MenuBarRefreshResult,
        menuBar: MenuBarStatusPresentation,
        currentOperationDetail: String?,
        lastErrorDetail: String?,
        remainingExpiry: RemainingExpiryPresentation
    ) -> StatusMenuHeaderPresentation {
        switch result {
        case .succeeded:
            let detail = remainingExpiry.menuBarText.map {
                "有效期已更新为 \($0)。"
            } ?? "正在重新确认有效期。"
            return presentation(
                menuBar: menuBar,
                tone: .good,
                headline: "续签成功",
                detail: detail,
                remainingExpiry: remainingExpiry,
                centerText: compactCenterText(from: remainingExpiry)
            )

        case .cancelled:
            return presentation(
                menuBar: menuBar,
                tone: .neutral,
                headline: "已取消",
                detail: currentOperationDetail ?? "本次续签未完成。"
            )

        case .failed:
            return presentation(
                menuBar: menuBar,
                tone: .critical,
                headline: "续签失败",
                detail:
                    currentOperationDetail
                    ?? lastErrorDetail
                    ?? "请打开面板查看原因并重试。"
            )

        case .interrupted:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "续签已中断",
                detail:
                    currentOperationDetail
                    ?? lastErrorDetail
                    ?? "续签流程未能正常完成。"
            )

        case .unknown:
            return presentation(
                menuBar: menuBar,
                tone: .warning,
                headline: "续签结果待确认",
                detail:
                    currentOperationDetail
                    ?? lastErrorDetail
                    ?? "请重新检查设备与 App 状态。"
            )
        }
    }

    private static func presentation(
        menuBar: MenuBarStatusPresentation,
        tone: StatusTone,
        headline: String,
        detail: String,
        remainingExpiry: RemainingExpiryPresentation = .unknown,
        centerText: String? = nil
    ) -> StatusMenuHeaderPresentation {
        StatusMenuHeaderPresentation(
            tone: tone,
            fraction: fraction(
                for: menuBar,
                remaining: remainingExpiry.progressFraction
            ),
            headline: headline,
            detail: boundedDetail(detail),
            centerText: centerText
        )
    }

    /// 设计稿 §9 环矩阵：弧长表达七天签名周期中**剩余**的比例，越接近到期弧越短。
    private static func fraction(
        for menuBar: MenuBarStatusPresentation,
        remaining: Double?
    ) -> Double {
        switch menuBar.state {
        case .needsSetup, .environmentError, .scanError, .blocked:
            return 0
        case .expiry(let isExpired, _):
            return isExpired ? 0 : (remaining ?? 0)
        case .countdown(let seconds):
            return min(max(Double(seconds) / 5, 0), 1)
        case .refreshResult(let result):
            switch result {
            case .succeeded:
                return remaining ?? 1
            case .failed, .cancelled, .interrupted, .unknown:
                return remaining ?? 0.72
            }
        case .checking, .preparing, .deploying, .confirming, .pairing:
            return 0.32
        case .waitingForUnlock, .confirmationRequired, .pairingRequired,
             .xcodeUpdateRequired, .wiredConnectionRequired, .offline,
             .pendingDetection, .unknown:
            return remaining ?? 0
        }
    }

    /// 环心数字：剩余不足一天时按小时、不足一小时按分钟展示。
    private static func compactCenterText(
        from remainingExpiry: RemainingExpiryPresentation
    ) -> String? {
        guard let seconds = remainingExpiry.remainingSeconds, seconds > 0 else {
            return nil
        }
        if seconds >= 24 * 60 * 60 {
            return "\(seconds / (24 * 60 * 60))"
        }
        if seconds >= 60 * 60 {
            return "\(seconds / (60 * 60))"
        }
        if seconds >= 60 {
            return "\(seconds / 60)"
        }
        return nil
    }

    /// 离线 detail 的剩余有效期摘要，如「3 天」「5 小时」。
    private static func primaryRemainingSummary(
        from remainingExpiry: RemainingExpiryPresentation
    ) -> String? {
        guard let component = remainingExpiry.metricComponents.first else {
            return nil
        }
        return [component.value, component.unit]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func currentDetail(
        from activity: OperationActivityPresentation
    ) -> String? {
        switch activity.source {
        case .currentActivity, .currentFeedback:
            normalized(activity.detail)
        case .historicalResult, .idle:
            nil
        }
    }

    private static func boundedDetail(_ value: String) -> String {
        let normalizedValue = normalized(value) ?? ""
        let maximumCharacterCount = 120
        guard normalizedValue.count > maximumCharacterCount else {
            return normalizedValue
        }

        return String(normalizedValue.prefix(maximumCharacterCount - 1)) + "…"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalizedValue = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalizedValue.isEmpty ? nil : normalizedValue
    }
}
