import SwiftUI

/// 兼容原有调用点的状态页容器。具体视觉拆分为 Hero、轨迹和活动焦点三个组件。
struct ExpiryCommandCenterView: View {
    let presentation: PrimaryJourneyPresentation
    let deployLogText: String
    let onAction: (PrimaryJourneyAction) -> Void
    let onDeviceSelectionRequested: () -> Void
    var isAnimationActive = true

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            HeroCountdownCard(
                presentation: presentation,
                onAction: onAction,
                onOpenSettings: onDeviceSelectionRequested,
                isAnimationActive: isAnimationActive
            )

            EnvironmentTrackRow(
                steps: presentation.verificationSteps,
                onFix: { _ in onDeviceSelectionRequested() }
            )

            ActivityFocusCard(
                presentation: presentation,
                deployLogText: deployLogText,
                onAction: onAction,
                onOpenHistory: { onAction(openHistoryAction) },
                isAnimationActive: isAnimationActive
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var openHistoryAction: PrimaryJourneyAction {
        PrimaryJourneyAction(
            id: .openHistory,
            title: "查看历史",
            systemImage: "clock.arrow.circlepath",
            placement: .task,
            style: .quiet,
            availability: .enabled
        )
    }
}
