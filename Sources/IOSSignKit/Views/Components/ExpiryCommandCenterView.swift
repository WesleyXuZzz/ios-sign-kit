import SwiftUI

struct DashboardLayout: Equatable {
    let availableWidth: CGFloat
    static let columnGap: CGFloat = 12
    static let mainColumnRatio: CGFloat = 1.25

    var mainWidth: CGFloat {
        max(availableWidth - Self.columnGap, 0) * Self.mainColumnRatio / (Self.mainColumnRatio + 1)
    }
    var sideWidth: CGFloat { max(availableWidth - Self.columnGap, 0) - mainWidth }
}

/// The single status workspace. Actions are still authorized by the shared presentation.
struct ExpiryCommandCenterView: View {
    let presentation: PrimaryJourneyPresentation
    let deployLogText: String
    let onAction: (PrimaryJourneyAction) -> Void
    let onDeviceSelectionRequested: () -> Void
    var isAnimationActive = true
    var config: AppConfig = .default
    var availableWidth: CGFloat = 872
    var minimumHeight: CGFloat = 540

    var body: some View {
        let layout = DashboardLayout(availableWidth: availableWidth)
        HStack(alignment: .top, spacing: DashboardLayout.columnGap) {
            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                HeroCountdownCard(
                    presentation: presentation,
                    onAction: onAction,
                    onOpenSettings: onDeviceSelectionRequested,
                    isAnimationActive: isAnimationActive
                )
                ActivityFocusCard(
                    presentation: presentation,
                    deployLogText: deployLogText,
                    onAction: onAction,
                    onOpenHistory: { onAction(openHistoryAction) },
                    isAnimationActive: isAnimationActive
                )
            }
            .frame(width: layout.mainWidth)

            VStack(alignment: .leading, spacing: SpacingTokens.sm) {
                EnvironmentTrackRow(
                    steps: presentation.verificationSteps,
                    onFix: { _ in onDeviceSelectionRequested() }
                )
                if let task = presentation.currentTask, ActivityFocusCard.showsLiveOutput(for: task)
                {
                    LiveDeployOutputPanel(logText: deployLogText) {
                        if let action = ActivityFocusCard.liveOutputAction(for: task) {
                            onAction(action)
                        }
                    }
                } else {
                    RenewalPolicySummaryCard(config: config)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: layout.sideWidth)
            .frame(minHeight: minimumHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var openHistoryAction: PrimaryJourneyAction {
        PrimaryJourneyAction(
            id: .openHistory, title: "查看历史", systemImage: "clock.arrow.circlepath",
            placement: .task, style: .quiet, availability: .enabled
        )
    }
}

struct RenewalPolicySummaryCard: View {
    let config: AppConfig

    static func summary(for config: AppConfig) -> String {
        let policy = config.autoRefreshPolicy == .reminderOnly ? "到期时提醒" : "到期时自动刷新"
        return
            "\(policy) · 到期前每 \(config.checkIntervalMinutes) 分钟检查 · 到期后每 \(config.expiredCheckIntervalMinutes) 分钟检查 · 提醒冷却 \(config.reminderCooldownHours) 小时"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("续期策略", systemImage: "clock")
                .font(TypeTokens.cardTitle)
                .foregroundStyle(ColorTokens.Text.primary)
            Text(Self.summary(for: config))
                .font(TypeTokens.caption)
                .foregroundStyle(ColorTokens.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if config.autoRefreshPolicy == .autoRefreshWhenExpired {
                Text("确认 App 已安装且签名到期后，等待设备解锁与 Xcode 就绪，再复核并续签。")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Text("续签进行中时，这里会切换为实时输出。")
                .font(TypeTokens.auxiliary)
                .foregroundStyle(ColorTokens.Text.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .interfaceSurface()
    }
}
