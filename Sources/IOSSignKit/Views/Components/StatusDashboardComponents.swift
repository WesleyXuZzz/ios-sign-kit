import SwiftUI

enum HeroMetricUnitPresentation {
    static func text(
        phase: PrimaryJourneyPhase,
        unit: String?
    ) -> String {
        if phase == .countdown {
            return "后自动续期"
        }
        guard let unit else { return "" }
        return "\(unit)后到期"
    }
}

struct HeroRenewalRingPresentation: Equatable {
    let tone: RenewalRingView.Tone
    let fraction: Double
    let motion: RenewalRingView.Motion
    let glyph: RenewalRingView.CenterGlyph

    var showsMetric: Bool {
        glyph == .none && activeTitle == nil
    }

    var showsWaterLevel: Bool {
        activeTitle != nil
    }

    var activeTitle: String? {
        switch motion {
        case .checking:
            "检查中"
        case .deploying:
            "续签中"
        case .none, .countdown, .success:
            nil
        }
    }

    static func make(
        presentation: PrimaryJourneyPresentation,
        successFeedbackIsActive: Bool
    ) -> HeroRenewalRingPresentation {
        if presentation.phase == .completed,
           !successFeedbackIsActive {
            return HeroRenewalRingPresentation(
                tone: .neutral,
                fraction: presentation.header.consumedExpiryProgress ?? 0,
                motion: .none,
                glyph: .none
            )
        }

        let tone = tone(for: presentation)
        let motion = motion(for: presentation)
        return HeroRenewalRingPresentation(
            tone: tone,
            fraction: fraction(
                for: presentation,
                tone: tone,
                motion: motion
            ),
            motion: motion,
            glyph: glyph(for: presentation, tone: tone)
        )
    }

    private static func tone(
        for presentation: PrimaryJourneyPresentation
    ) -> RenewalRingView.Tone {
        return switch presentation.phase {
        case .needsSetup:
            .needsSetup
        case .blocked:
            .critical
        case .completed:
            .success
        case .waitingForDevice:
            .offline
        case .attention where presentation.header.tone == .critical:
            .environmentError
        case .renewalRequired:
            .critical
        case .countdown:
            .warning
        default:
            switch presentation.renewalIcon.visualState {
            case .normal, .healthy:
                .neutral
            case .warning:
                .warning
            case .critical:
                .critical
            case .offline:
                .offline
            }
        }
    }

    private static func motion(
        for presentation: PrimaryJourneyPresentation
    ) -> RenewalRingView.Motion {
        switch presentation.renewalIcon.motion {
        case .checking:
            .checking
        case .countdown:
            .countdown
        case .deploying:
            .deploying
        case .success:
            .success
        case .recovering, .attention, .idle, .paused:
            .none
        }
    }

    private static func glyph(
        for presentation: PrimaryJourneyPresentation,
        tone: RenewalRingView.Tone
    ) -> RenewalRingView.CenterGlyph {
        switch tone {
        case .needsSetup:
            .plus
        case .environmentError:
            .cross
        case .success:
            .checkmark
        case .critical where presentation.phase == .blocked:
            .pause
        default:
            .none
        }
    }

    private static func fraction(
        for presentation: PrimaryJourneyPresentation,
        tone: RenewalRingView.Tone,
        motion: RenewalRingView.Motion
    ) -> Double {
        if motion == .checking || motion == .deploying {
            return RenewalRingVisualSpecification.activeArcFraction
        }

        switch presentation.phase {
        case .needsSetup:
            return 1
        case .attention where tone == .environmentError:
            return 1
        case .blocked:
            return presentation.header.consumedExpiryProgress ?? 0.28
        case .completed, .renewalRequired:
            return 1
        case .countdown:
            if case .fraction(let fraction) = presentation.currentTask?.progress {
                return min(max(fraction, 0), 1)
            }
            return 1
        default:
            return presentation.header.consumedExpiryProgress ?? 0.28
        }
    }
}

struct HeroRenewalRingResultTransition: Equatable {
    let activeTitle: String
    let activeElapsed: TimeInterval
    let startedAt: Date
    let startLevel: Double
    let startRingRotation: Double
    let targetRing: HeroRenewalRingPresentation

    init(
        activeTitle: String,
        activeElapsed: TimeInterval,
        startedAt: Date,
        targetRing: HeroRenewalRingPresentation,
        reducesMotion: Bool
    ) {
        self.activeTitle = activeTitle
        self.activeElapsed = activeElapsed
        self.startedAt = startedAt
        self.startLevel = RenewalWaterLevelSpecification.level(
            at: activeElapsed,
            reducesMotion: reducesMotion
        )
        self.startRingRotation = RenewalWaterResultTransitionSpecification
            .activeRingRotation(at: activeElapsed)
        self.targetRing = targetRing
    }

    func frame(
        at date: Date,
        reducesMotion: Bool
    ) -> RenewalWaterResultTransitionFrame {
        RenewalWaterResultTransitionSpecification.frame(
            at: max(date.timeIntervalSince(startedAt), 0),
            startLevel: startLevel,
            activeElapsed: activeElapsed,
            startRingRotation: startRingRotation,
            targetRingFraction: targetRing.fraction,
            reducesMotion: reducesMotion
        )
    }
}

struct HeroCountdownCard: View {
    let presentation: PrimaryJourneyPresentation
    let onAction: (PrimaryJourneyAction) -> Void
    let onOpenSettings: () -> Void
    let isAnimationActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroClock = RenewalRingMotionClock()
    @State private var successFeedbackDidSettle = false
    @State private var isBlockReasonPresented = false
    @State private var waterResultTransition:
        HeroRenewalRingResultTransition?

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.lg) {
            HStack(alignment: .center, spacing: SpacingTokens.xl) {
                ringSummary

                VStack(alignment: .leading, spacing: 0) {
                    Text(statusTitle)
                        .font(TypeTokens.pageTitle)
                        .foregroundStyle(statusColor)

                    Text(statusDetail)
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(
                            .top,
                            SpacingTokens.HeroCard.statusDetailTopPadding
                        )

                    if showsActionRow && !showsAttentionActionsBelowSummary {
                        actionRow
                            .padding(
                                .top,
                                SpacingTokens.HeroCard.actionTopPadding
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 176)

            if showsAttentionActionsBelowSummary {
                actionRow
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Rectangle()
                .fill(ColorTokens.Border.subtle)
                .frame(height: SpacingTokens.Hairline.width)
                .padding(.horizontal, -SpacingTokens.lg)

            deviceRow
        }
        .padding(.horizontal, SpacingTokens.lg)
        .padding(.vertical, SpacingTokens.HeroCard.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interfaceSurface(emphasized: true)
        .accessibilityElement(children: .contain)
        .alert("为什么续签被阻止？", isPresented: $isBlockReasonPresented) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(presentation.currentTask?.detail ?? presentation.header.detail)
        }
        .onAppear {
            resetHeroClock()
        }
        .onChange(of: presentation.phase) { previousPhase, _ in
            handlePhaseChange(from: previousPhase)
        }
        .onChange(of: heroTimelineShouldRun) { _, isActive in
            setHeroClockActive(isActive)
        }
        .onChange(of: isAnimationActive) { _, isActive in
            if !isActive {
                waterResultTransition = nil
            }
        }
    }

    private var ringSummary: some View {
        TimelineView(
            .animation(
                minimumInterval: heroTimelineInterval,
                paused: !heroTimelineShouldRun
            )
        ) { context in
            let elapsed = heroClock.elapsed(at: context.date)
            let successFeedbackIsActive = presentation.phase == .completed
                && !successFeedbackDidSettle
                && elapsed < RenewalRingVisualSpecification.successDuration
            let ring = HeroRenewalRingPresentation.make(
                presentation: presentation,
                successFeedbackIsActive: successFeedbackIsActive
            )

            Group {
                if let transition = waterResultTransition {
                    let frame = transition.frame(
                        at: context.date,
                        reducesMotion: reduceMotion
                    )

                    ZStack {
                        RenewalRingView(
                            diameter: 132,
                            lineWidth: 10,
                            tone: transition.targetRing.tone,
                            fraction: transition.targetRing.fraction,
                            motion: .none,
                            centerGlyph: .none,
                            ambientActivityStyle: .twinArcOrbit,
                            isAnimationActive: false
                        )
                        .opacity(frame.resultOpacity)

                        RenewalRingResultTransitionView(
                            targetTone: transition.targetRing.tone,
                            frame: frame
                        )
                        .opacity(1 - frame.resultOpacity)

                        RenewalWaterResultTransitionView(
                            title: transition.activeTitle,
                            activeElapsed: transition.activeElapsed,
                            targetTone: transition.targetRing.tone,
                            frame: frame
                        )

                        centerMetric(
                            ring: transition.targetRing,
                            elapsed: elapsed
                        )
                        .opacity(frame.resultOpacity)
                        .scaleEffect(frame.resultScale)
                    }
                    .onChange(of: frame.isComplete) { _, isComplete in
                        if isComplete,
                           waterResultTransition?.startedAt
                            == transition.startedAt {
                            waterResultTransition = nil
                        }
                    }
                } else {
                    ZStack {
                        RenewalRingView(
                            diameter: 132,
                            lineWidth: 10,
                            tone: ring.tone,
                            fraction: ring.fraction,
                            motion: ring.motion,
                            centerGlyph: ring.glyph,
                            ambientActivityStyle: .twinArcOrbit,
                            isAnimationActive: isAnimationActive,
                            elapsedOverride: ring.showsWaterLevel
                                ? elapsed
                                : nil
                        )

                        if ring.showsWaterLevel,
                           let activeTitle = ring.activeTitle {
                            RenewalWaterLevelView(
                                title: activeTitle,
                                isAnimationActive: isAnimationActive,
                                elapsedOverride: elapsed
                            )
                        } else if ring.showsMetric {
                            centerMetric(
                                ring: ring,
                                elapsed: elapsed
                            )
                        }
                    }
                }
            }
            .onChange(of: successFeedbackIsActive) { wasActive, isActive in
                if wasActive && !isActive {
                    successFeedbackDidSettle = true
                }
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityMetric)
    }

    @ViewBuilder
    private func centerMetric(
        ring: HeroRenewalRingPresentation,
        elapsed: TimeInterval
    ) -> some View {
        VStack(spacing: 4) {
            if presentation.phase == .countdown {
                countdownMetric(elapsed: elapsed)
            } else {
                Text(metricValue)
                    .font(metricFont)
                    .foregroundStyle(metricColor(for: ring.tone))
                    .contentTransition(.numericText())
            }

            Text(metricUnit)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ColorTokens.Text.secondary)
        }
    }

    private func countdownMetric(elapsed: TimeInterval) -> some View {
        let parts = metricValue.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let minutes = parts.first.map(String.init) ?? "00"
        let seconds = parts.count > 1 ? String(parts[1]) : "00"

        return HStack(spacing: 0) {
            Text(minutes)
                .contentTransition(.numericText())
            Text(":")
                .opacity(countdownColonOpacity(elapsed: elapsed))
            Text(seconds)
                .contentTransition(.numericText())
        }
        .font(metricFont)
        .foregroundStyle(ColorTokens.Semantic.warningText)
        .animation(MotionTokens.easeOut(0.18), value: metricValue)
    }

    private var deviceRow: some View {
        HStack(spacing: SpacingTokens.md) {
            Image(systemName: "iphone")
                .font(TypeTokens.deviceIcon)
                .foregroundStyle(ColorTokens.Text.secondary)
                .frame(
                    width: SpacingTokens.HeroCard.deviceIconSize,
                    height: SpacingTokens.HeroCard.deviceIconSize
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: SpacingTokens.Radius.deviceIcon,
                        style: .continuous
                    )
                    .fill(ColorTokens.BG.surface)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: SpacingTokens.Radius.deviceIcon,
                        style: .continuous
                    )
                    .strokeBorder(
                        ColorTokens.Border.subtle,
                        lineWidth: SpacingTokens.Hairline.width
                    )
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SpacingTokens.xxs) {
                Text(presentation.targetDevice.value)
                    .font(TypeTokens.cardTitle)
                    .foregroundStyle(ColorTokens.Text.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                Text(deviceDetail)
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusPill(text: devicePillText, tone: deviceTone)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("目标设备")
        .accessibilityValue(
            [
                presentation.targetDevice.value,
                devicePillText,
                deviceDetail
            ]
            .joined(separator: "，")
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        if presentation.phase == .needsSetup {
            Button {
                onOpenSettings()
            } label: {
                Label("开始配置", systemImage: "gearshape")
            }
            .buttonStyle(
                RenewalButtonStyle(
                    kind: .primary,
                    height: SpacingTokens.ControlHeight.heroPrimary
                )
            )
            .help("打开设置并完成项目配置")
        } else if presentation.phase == .blocked {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isBlockReasonPresented = true
                } label: {
                    Label("查看原因", systemImage: "info.circle")
                }
                .buttonStyle(
                    RenewalButtonStyle(
                        kind: .primary,
                        height: SpacingTokens.ControlHeight.heroPrimary
                    )
                )

                Button("重新检查", systemImage: "arrow.clockwise") {
                    if let action = firstAction(withID: .recheck) {
                        onAction(action)
                    }
                }
                .buttonStyle(RenewalButtonStyle(kind: .secondary))
                .disabled(firstAction(withID: .recheck)?.isEnabled != true)
            }
        } else if showsAttentionActionsBelowSummary {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SpacingTokens.sm) {
                    attentionActions
                }
                VStack(alignment: .trailing, spacing: SpacingTokens.sm) {
                    attentionActions
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(displayedActions) { action in
                    actionButton(for: action)
                }
            }
        }
    }

    private var showsAttentionActionsBelowSummary: Bool {
        presentation.phase == .attention && presentation.header.tone == .critical
    }

    @ViewBuilder
    private var attentionActions: some View {
        Button("打开设置", systemImage: "gearshape") {
            onOpenSettings()
        }
        .buttonStyle(RenewalButtonStyle(kind: .secondary))

        actionButton(for: firstAction(withID: .recheck), kind: .secondary)
    }

    @ViewBuilder
    private func actionButton(
        for action: PrimaryJourneyAction?,
        kind: RenewalButtonStyle.Kind? = nil
    ) -> some View {
        if let action {
            Button {
                onAction(action)
            } label: {
                Label(displayTitle(for: action), systemImage: action.systemImage)
            }
            .buttonStyle(
                RenewalButtonStyle(
                    kind: kind ?? buttonKind(for: action),
                    height: (kind ?? buttonKind(for: action)) == .primary
                        ? SpacingTokens.ControlHeight.heroPrimary
                        : SpacingTokens.ControlHeight.secondary
                )
            )
            .disabled(shouldDisable(action))
            .help(action.availability.helpText ?? action.title)
        }
    }

    private func shouldDisable(_ action: PrimaryJourneyAction) -> Bool {
        if !action.isEnabled {
            return true
        }
        if presentation.phase == .checking {
            return action.id == .recheck
                || action.id == .recoveryPreservingRecheck
                || action.id == .requestRefresh
        }
        if presentation.phase == .deploying {
            return action.id != .cancelRefresh
                && action.id != .showDeployLog
        }
        return false
    }

    private var displayedActions: [PrimaryJourneyAction] {
        presentation.heroActions
            .filter { $0.id != .dismissFeedback }
            .sorted { lhs, rhs in
                if lhs.style == .primary && rhs.style != .primary {
                    return true
                }
                if rhs.style == .primary && lhs.style != .primary {
                    return false
                }
                return false
            }
            .prefix(2)
            .map { $0 }
    }

    private var showsActionRow: Bool {
        if presentation.phase == .needsSetup
            || presentation.phase == .blocked
        {
            return true
        }
        if presentation.phase == .attention,
           presentation.header.tone == .critical
        {
            return true
        }
        return !displayedActions.isEmpty
    }

    private func firstAction(
        withID id: PrimaryJourneyAction.ID
    ) -> PrimaryJourneyAction? {
        (presentation.currentTask?.actions ?? [])
            .first { $0.id == id }
            ?? presentation.headerActions.first { $0.id == id }
    }

    private func displayTitle(for action: PrimaryJourneyAction) -> String {
        switch action.id {
        case .requestRefresh:
            "立即续签"
        case .cancelRefresh:
            "停止续签"
        case .cancelCountdown:
            "取消自动续期"
        case .recoveryPreservingRecheck, .recheck:
            "重新检查"
        default:
            action.title
        }
    }

    private func buttonKind(
        for action: PrimaryJourneyAction
    ) -> RenewalButtonStyle.Kind {
        switch action.style {
        case .primary:
            .primary
        case .destructive:
            .destructive
        case .quiet:
            .text
        case .secondary:
            .secondary
        }
    }

    private var statusTitle: String {
        switch presentation.phase {
        case .needsSetup:
            "尚未配置"
        case .waitingForDevice:
            "等待设备连接"
        case .monitoring:
            isWarningExpiry ? "即将到期" : "签名有效"
        case .renewalRequired:
            "签名已过期"
        case .checking:
            "正在检查…"
        case .countdown:
            "即将自动续期"
        case .recovering:
            "正在等待恢复"
        case .deploying:
            "正在续签…"
        case .completed:
            "续签完成"
        case .attention:
            presentation.header.title.isEmpty ? "需要处理" : presentation.header.title
        case .blocked:
            "无法自动续期"
        }
    }

    private var statusDetail: String {
        if presentation.phase == .waitingForDevice {
            return presentation.header.detail
        }

        let detail = presentation.header.detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            return detail
        }

        switch presentation.phase {
        case .needsSetup:
            return "选择项目目录与目标设备后，iOSSignKit 将开始监测签名有效期。"
        case .waitingForDevice:
            return "签名状态将在目标设备连接后重新确认。"
        default:
            return presentation.header.lastFullVerificationSummary
        }
    }

    private var metricValue: String {
        if presentation.phase == .renewalRequired {
            return "已过期"
        }

        if presentation.phase == .countdown,
           let seconds = presentation.currentTask?.progress,
           case .fraction(let fraction) = seconds
        {
            let remainingSeconds = max(Int((fraction * 5).rounded()), 0)
            return String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
        }

        return presentation.header.remainingExpiryComponents.first?.value
            ?? (presentation.header.remainingExpiryText == "--" ? "—" : presentation.header.remainingExpiryText)
    }

    private var metricUnit: String {
        if presentation.phase == .renewalRequired {
            return presentation.header.expiredDurationText
                ?? "签名已失效"
        }

        return HeroMetricUnitPresentation.text(
            phase: presentation.phase,
            unit: presentation.header.remainingExpiryComponents.first?.unit
        )
    }

    private var metricFont: Font {
        if presentation.phase == .countdown {
            return TypeTokens.heroMetricCompact
        }
        if presentation.phase == .renewalRequired {
            return .system(size: 22, weight: .bold, design: .rounded)
        }
        if presentation.header.remainingExpiryComponents.first?.unit == nil {
            return .system(size: 22, weight: .bold, design: .rounded)
        }
        return TypeTokens.heroMetric
    }

    private var isWarningExpiry: Bool {
        guard let seconds = presentation.header.remainingExpiryComponents.first,
              seconds.unit != nil else {
            return false
        }
        return presentation.renewalIcon.visualState == .warning
    }

    private var statusColor: Color {
        let ring = HeroRenewalRingPresentation.make(
            presentation: presentation,
            successFeedbackIsActive: true
        )
        return switch ring.tone {
        case .normal, .neutral:
            ColorTokens.Text.primary
        case .warning:
            ColorTokens.Semantic.warningText
        case .critical, .environmentError:
            ColorTokens.Semantic.criticalText
        case .success:
            ColorTokens.Semantic.successText
        case .offline, .needsSetup:
            ColorTokens.Text.primary
        }
    }

    private func metricColor(
        for tone: RenewalRingView.Tone
    ) -> Color {
        switch tone {
        case .normal:
            ColorTokens.Text.primary
        case .neutral:
            ColorTokens.Semantic.offline
        case .warning:
            ColorTokens.Semantic.warningText
        case .critical, .environmentError:
            ColorTokens.Semantic.criticalText
        case .success:
            ColorTokens.Semantic.success
        case .offline, .needsSetup:
            ColorTokens.Semantic.offline
        }
    }

    private var deviceTone: StatusTone {
        if presentation.phase == .waitingForDevice {
            return .neutral
        }
        return presentation.targetDevice.tone
    }

    private var devicePillText: String {
        switch presentation.phase {
        case .waitingForDevice:
            "未连接"
        case .needsSetup:
            "未固定设备"
        default:
            switch presentation.targetDevice.tone {
            case .good:
                "已连接"
            case .critical:
                "不可用"
            case .warning:
                "待确认"
            case .info:
                "检查中"
            case .neutral:
                "未连接"
            }
        }
    }

    private var deviceDetail: String {
        let detail = presentation.targetDevice.cardDetail
            ?? presentation.targetDevice.detail
            ?? "连接后将自动确认设备状态"
        if presentation.phase == .needsSetup {
            return "支持有线 / Wi-Fi 已配对设备"
        }
        return detail
    }

    private var heroTimelineShouldRun: Bool {
        guard isAnimationActive else { return false }
        if waterResultTransition != nil {
            return true
        }

        switch presentation.phase {
        case .countdown:
            return !reduceMotion
        case .checking, .deploying:
            return true
        case .completed:
            return !successFeedbackDidSettle
        default:
            return false
        }
    }

    private var heroTimelineInterval: TimeInterval {
        if waterResultTransition != nil {
            return 1 / 60
        }

        return switch presentation.phase {
        case .countdown, .completed:
            reduceMotion ? 0.25 : 1 / 30
        case .checking, .deploying:
            reduceMotion ? 0.25 : 1 / 60
        default:
            1
        }
    }

    private func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = max(Int(elapsed), 0)
        return String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
    }

    private func countdownColonOpacity(
        elapsed: TimeInterval
    ) -> Double {
        guard isAnimationActive, !reduceMotion else { return 1 }
        return 0.6 + 0.4 * cos(2 * .pi * elapsed)
    }

    private func handlePhaseChange(
        from previousPhase: PrimaryJourneyPhase
    ) {
        let now = Date()
        let targetRing = HeroRenewalRingPresentation.make(
            presentation: presentation,
            successFeedbackIsActive: true
        )

        if isAnimationActive,
           let activeTitle = activeTitle(for: previousPhase),
           targetRing.showsMetric {
            waterResultTransition = HeroRenewalRingResultTransition(
                activeTitle: activeTitle,
                activeElapsed: heroClock.elapsed(at: now),
                startedAt: now,
                targetRing: targetRing,
                reducesMotion: reduceMotion
            )
        } else {
            waterResultTransition = nil
        }

        successFeedbackDidSettle = false
        resetHeroClock(at: now)
    }

    private func activeTitle(
        for phase: PrimaryJourneyPhase
    ) -> String? {
        switch phase {
        case .checking:
            "检查中"
        case .deploying:
            "续签中"
        default:
            nil
        }
    }

    private func resetHeroClock(at date: Date = Date()) {
        var updatedClock = heroClock
        updatedClock.reset(
            isActive: heroTimelineShouldRun,
            at: date
        )
        heroClock = updatedClock
    }

    private func setHeroClockActive(_ isActive: Bool) {
        var updatedClock = heroClock
        updatedClock.setActive(isActive, at: Date())
        heroClock = updatedClock
    }

    private var accessibilityMetric: String {
        let ring = HeroRenewalRingPresentation.make(
            presentation: presentation,
            successFeedbackIsActive: true
        )
        if let activeTitle = ring.activeTitle {
            return "\(activeTitle)，\(statusTitle)"
        }

        let metric = [metricValue, metricUnit]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return "签名\(metric)，\(statusTitle)"
    }
}

struct EnvironmentTrackRow: View {
    static let separatorWidth: CGFloat = 1
    static let separatorHorizontalPadding: CGFloat = 16

    let steps: [PrimaryJourneyVerificationStep]
    let onFix: (PrimaryJourneyVerificationStep.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                node(step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(ColorTokens.Border.subtle)
                        .frame(height: Self.separatorWidth)
                        .padding(.horizontal, Self.separatorHorizontalPadding)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .interfaceSurface()
    }

    private func node(_ step: PrimaryJourneyVerificationStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusDot(for: step)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: step))
                        .font(TypeTokens.cardTitle)
                        .foregroundStyle(ColorTokens.Text.primary)
                        .lineLimit(1)

                    Text(step.value)
                        .font(.system(size: 11))
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsSettingsAction(for: step) {
                Button("打开设置 ›") {
                    onFix(step.id)
                }
                .buttonStyle(RenewalButtonStyle(kind: .text))
                .font(.system(size: 11, weight: .medium))
                .padding(.leading, 32)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title(for: step))
        .accessibilityValue("\(step.value)，\(toneText(step.tone))")
    }

    private func showsSettingsAction(
        for step: PrimaryJourneyVerificationStep
    ) -> Bool {
        if step.id == .device,
           step.tone == .neutral,
           step.systemImage == "minus" {
            return true
        }
        return step.tone == .warning || step.tone == .critical
    }

    private func statusDot(
        for step: PrimaryJourneyVerificationStep
    ) -> some View {
        ZStack {
            Circle()
                .fill(step.tone.color)
                .frame(width: 22, height: 22)

            Image(systemName: step.systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private func title(
        for step: PrimaryJourneyVerificationStep
    ) -> String {
        switch step.id {
        case .environment:
            "开发环境"
        case .device:
            "设备连接"
        case .signing:
            "签名状态"
        }
    }

    private func toneText(_ tone: StatusTone) -> String {
        switch tone {
        case .good:
            "正常"
        case .warning:
            "待确认"
        case .critical:
            "异常"
        case .info:
            "检查中"
        case .neutral:
            "无法确认"
        }
    }
}

struct ActivityFocusCard: View {
    let presentation: PrimaryJourneyPresentation
    let deployLogText: String
    let onAction: (PrimaryJourneyAction) -> Void
    let onOpenHistory: () -> Void
    let isAnimationActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taskStartedAt = Date()

    var body: some View {
        Group {
            if let task = activeTask {
                taskCard(task)
            } else if let result = presentation.previousResult {
                resultCard(result)
            } else {
                emptyCard
            }
        }
        .onAppear {
            taskStartedAt = Date()
        }
        .onChange(of: activeTask?.kind) { _, _ in
            taskStartedAt = Date()
        }
    }

    static func showsLiveOutput(for task: PrimaryJourneyTask?) -> Bool {
        task?.kind == .deploying
    }

    static func liveOutputAction(
        for task: PrimaryJourneyTask
    ) -> PrimaryJourneyAction? {
        task.actions.first { $0.id == .showDeployLog }
    }

    static func taskCardActions(
        _ actions: [PrimaryJourneyAction],
        showsLiveOutput: Bool = true
    ) -> [PrimaryJourneyAction] {
        actions.filter { !showsLiveOutput || $0.id != .showDeployLog }
    }

    private var activeTask: PrimaryJourneyTask? {
        presentation.currentTask
    }

    private func taskCard(_ task: PrimaryJourneyTask) -> some View {
        TimelineView(
            .animation(
                minimumInterval: 1,
                paused: !isAnimationActive || task.kind == .currentFeedback
            )
        ) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: task.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(task.tone.color)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(stageTitle(for: task))
                            .font(TypeTokens.cardTitle)
                            .foregroundStyle(ColorTokens.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if task.kind != .currentFeedback {
                            Text(elapsedText(at: context.date))
                                .font(TypeTokens.mono)
                                .foregroundStyle(ColorTokens.Text.secondary)
                        }
                    }

                    Spacer(minLength: 12)

                    if usesFailureActionLayout(task),
                       let dismiss = task.actions.first(where: { $0.id == .dismissFeedback }) {
                        Button {
                            onAction(dismiss)
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .accessibilityLabel(dismiss.title)
                        .help(dismiss.availability.helpText ?? dismiss.title)
                        .disabled(!dismiss.isEnabled)
                    }
                }

                if !task.detail.isEmpty && task.detail != stageTitle(for: task) {
                    Text(task.detail)
                        .font(TypeTokens.caption)
                        .foregroundStyle(ColorTokens.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !Self.taskCardActions(
                    task.actions, showsLiveOutput: Self.showsLiveOutput(for: task)
                ).isEmpty {
                    actionButtons(task)
                }

                if let progress = task.progress {
                    progressBar(progress, tone: task.tone)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .interfaceSurface()
            .accessibilityElement(children: .contain)
        }
    }

    private func stageTitle(for task: PrimaryJourneyTask) -> String {
        switch task.kind {
        case .checking:
            "设备与安装状态核验"
        case .countdown:
            "自动续期倒计时"
        case .deploying:
            task.detail
        case .recovering:
            "等待设备恢复"
        case .processRecoveryBlocked:
            "续签进程恢复"
        case .currentFeedback:
            task.title
        }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = max(Int(date.timeIntervalSince(taskStartedAt)), 0)
        return String(
            format: "已用时 %02d:%02d",
            elapsed / 60,
            elapsed % 60
        )
    }

    private func resultCard(
        _ result: PrimaryJourneyPreviousResult
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            RenewalRingView(
                diameter: 40,
                lineWidth: 3.5,
                tone: resultTone(result),
                fraction: result.outcome == .failure ? 1 : 0.72,
                centerGlyph: resultGlyph(result),
                isAnimationActive: isAnimationActive
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(TypeTokens.cardTitle)
                    .foregroundStyle(ColorTokens.Text.primary)
                    .lineLimit(1)

                Text(resultDetail(result))
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button {
                onOpenHistory()
            } label: {
                HStack(spacing: 4) {
                    Text("查看历史")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(RenewalButtonStyle(kind: .text))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interfaceSurface()
        .accessibilityElement(children: .contain)
    }

    private var emptyCard: some View {
        HStack(spacing: 12) {
            RenewalRingView(
                diameter: 40,
                lineWidth: 3,
                tone: .offline,
                fraction: 0,
                centerGlyph: .minus,
                isAnimationActive: isAnimationActive
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("还没有续签记录")
                    .font(TypeTokens.cardTitle)
                    .foregroundStyle(ColorTokens.Text.primary)
                Text("完成一次续签后，这里会展示最近结果。")
                    .font(TypeTokens.caption)
                    .foregroundStyle(ColorTokens.Text.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interfaceSurface()
    }

    @ViewBuilder
    private func progressBar(
        _ progress: OperationActivityProgress,
        tone: StatusTone
    ) -> some View {
        switch progress {
        case .fraction(let value):
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(ColorTokens.Border.subtle)
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tone.color, ColorTokens.Accent.renewEnd],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 4)
        case .indeterminate:
            IndeterminateRenewalProgressBar(
                tone: tone,
                isAnimationActive: isAnimationActive,
                reduceMotion: reduceMotion
            )
        }
    }

    private func usesFailureActionLayout(_ task: PrimaryJourneyTask) -> Bool {
        task.kind == .currentFeedback && task.tone == .critical
    }

    @ViewBuilder
    private func actionButtons(
        _ task: PrimaryJourneyTask
    ) -> some View {
        let actions = Self.taskCardActions(
            task.actions, showsLiveOutput: Self.showsLiveOutput(for: task)
        )
        if usesFailureActionLayout(task) {
            let footerActions = actions.filter { $0.id != .dismissFeedback }
            if !footerActions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SpacingTokens.sm) {
                        ForEach(footerActions) { action in
                            taskActionButton(action)
                        }
                    }
                    VStack(alignment: .trailing, spacing: SpacingTokens.sm) {
                        ForEach(footerActions) { action in
                            taskActionButton(action)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, SpacingTokens.xs)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions) { action in
                    taskActionButton(action)
                }
            }
        }
    }

    private func taskActionButton(_ action: PrimaryJourneyAction) -> some View {
        Button {
            onAction(action)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .buttonStyle(
            RenewalButtonStyle(
                kind: action.style == .destructive
                    ? .destructive : action.style == .primary ? .primary : .text
            )
        )
        .disabled(!action.isEnabled)
        .help(action.availability.helpText ?? action.title)
    }

    private func resultTone(
        _ result: PrimaryJourneyPreviousResult
    ) -> RenewalRingView.Tone {
        switch result.outcome {
        case .success:
            .success
        case .failure:
            .critical
        case .cancelled, .interrupted, .unknown:
            .offline
        }
    }

    private func resultGlyph(
        _ result: PrimaryJourneyPreviousResult
    ) -> RenewalRingView.CenterGlyph {
        switch result.outcome {
        case .success:
            .checkmark
        case .failure:
            .cross
        case .cancelled, .interrupted, .unknown:
            .minus
        }
    }

    private func resultDetail(
        _ result: PrimaryJourneyPreviousResult
    ) -> String {
        let timestamp = result.occurredAt.map { dateSummary(for: $0) }
        if result.outcome == .success {
            return timestamp ?? "续签已完成"
        }
        return [timestamp, result.detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func dateSummary(for date: Date) -> String {
        VerificationTimePresentation.make(date: date).compactSummary
    }
}

private struct IndeterminateRenewalProgressBar: View {
    let tone: StatusTone
    let isAnimationActive: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? 0.25 : 1 / 30,
                paused: reduceMotion || !isAnimationActive
            )
        ) { context in
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(ColorTokens.Border.subtle)

                    Capsule(style: .continuous)
                        .fill(tone.color.opacity(0.24))

                    if !reduceMotion {
                        LinearGradient(
                            colors: [
                                Color.clear,
                                ColorTokens.Accent.renew.opacity(0.18),
                                ColorTokens.Accent.renewEnd,
                                ColorTokens.Accent.renew.opacity(0.18),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(width * 0.42, 80))
                        .offset(x: shimmerOffset(width: width, at: context.date))
                    }
                }
                .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func shimmerOffset(width: CGFloat, at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.2) / 1.2
        let shimmerWidth = max(width * 0.42, 80)
        return -shimmerWidth + ((width + shimmerWidth) * phase)
    }
}

private extension PrimaryJourneyAction.Availability {
    var helpText: String? {
        guard case .disabled(let reason) = self else { return nil }
        return reason
    }
}
