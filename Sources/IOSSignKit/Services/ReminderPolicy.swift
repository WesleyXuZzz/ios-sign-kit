import Foundation

struct ReminderPolicy {
    func evaluate(
        config: AppConfig,
        state: AppState,
        matchedDevice: DeviceInfo?,
        installedAppInfo: InstalledAppInfo? = nil,
        expiryInfo: ExpiryInfo? = nil,
        hasConfirmedInstallation: Bool? = nil,
        now: Date = Date()
    ) -> ReminderDecision {
        if state.processRecoveryBlocked {
            return ReminderDecision(
                shouldPrompt: false,
                reason: state.lastErrorSummary
                    ?? "仍有无法安全核验的后台进程，已阻止新续签。",
                nextEligibleAt: nil
            )
        }

        guard let matchedDevice, matchedDevice.isAvailable else {
            return ReminderDecision(shouldPrompt: false, reason: "目标设备离线。", nextEligibleAt: nil)
        }

        if state.isDeployRunning {
            return ReminderDecision(shouldPrompt: false, reason: "正在执行续签。", nextEligibleAt: nil)
        }

        guard hasConfirmedInstallation
            ?? (installedAppInfo != nil || state.targetAppPresence == .installed) else {
            return ReminderDecision(
                shouldPrompt: false,
                reason: "尚未确认目标设备上已安装 App。",
                nextEligibleAt: nil
            )
        }

        if installedAppInfo == nil {
            if let lastSuccessAt = state.activeInstallationSuccessAt,
               let graceDeadline = Calendar.current.date(byAdding: .minute, value: 10, to: lastSuccessAt),
               graceDeadline > now {
                return ReminderDecision(shouldPrompt: false, reason: "安装刚完成，等待设备更新安装索引。", nextEligibleAt: graceDeadline)
            }
        }

        let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt
            ?? state.lastDetectedExpiryAt
            ?? state.activeInstallationSuccessAt.map(PersonalSigningValidity.expiryDate)

        guard let estimatedExpiryAt else {
            let reason = installedAppInfo == nil
                ? "暂未检测到目标 App，等待后续检查。"
                : "暂时还没有可用的预计过期时间。"
            return ReminderDecision(shouldPrompt: false, reason: reason, nextEligibleAt: nil)
        }

        guard estimatedExpiryAt <= now else {
            let reason = installedAppInfo == nil
                ? "暂未从设备确认安装状态，先按最近续签记录估算。"
                : "已安装 App 仍在有效期内。"
            return ReminderDecision(
                shouldPrompt: false,
                reason: reason,
                nextEligibleAt: estimatedExpiryAt
            )
        }

        if let lastPromptAt = state.lastPromptAt {
            let elapsed = now.timeIntervalSince(lastPromptAt)
            if elapsed >= 0,
               elapsed
                < TimeInterval(config.reminderCooldownHours) * 60 * 60,
               let nextPromptAt = Calendar.current.date(
                   byAdding: .hour,
                   value: config.reminderCooldownHours,
                   to: lastPromptAt
               ) {
                return ReminderDecision(
                    shouldPrompt: false,
                    reason: "提醒冷却中。",
                    nextEligibleAt: nextPromptAt
                )
            }
        }

        let reason = installedAppInfo == nil
            ? "暂未从设备确认安装状态，但按最近续签记录预计已到期。"
            : "已安装 App 预计已到期。"
        return ReminderDecision(shouldPrompt: true, reason: reason, nextEligibleAt: nil)
    }
}
