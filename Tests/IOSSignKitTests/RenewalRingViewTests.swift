import AppKit
import Foundation
import SwiftUI
import Testing
@testable import IOSSignKit

struct RenewalRingViewTests {
    @Test
    func visualSpecificationCoversTheCompleteStateMatrix() {
        let normal = specification(
            tone: .normal,
            fraction: 0.57
        )
        #expect(normal.paint == .normalGradient)
        #expect(normal.arcFraction == 0.57)
        #expect(normal.showsTrack)
        #expect(normal.showsAmbientActivity)
        #expect(!normal.showsGlow)
        #expect(normal.spinDuration == nil)
        #expect(
            RenewalRingVisualSpecification.inlineActivityFraction == 0.06
        )
        #expect(
            RenewalRingVisualSpecification.ambientOrbitDuration == 6
        )

        let neutral = specification(
            tone: .neutral,
            fraction: 0.29
        )
        #expect(neutral.paint == .neutral)
        #expect(neutral.arcFraction == 0.29)
        #expect(neutral.showsTrack)
        #expect(!neutral.showsAmbientActivity)

        let warning = specification(
            tone: .warning,
            fraction: 0.83
        )
        #expect(warning.paint == .warning)
        #expect(warning.arcFraction == 0.83)
        #expect(!warning.isFullCircle)
        #expect(!warning.showsAmbientActivity)
        #expect(!warning.showsGlow)

        let expired = specification(
            tone: .critical,
            fraction: 0.2
        )
        #expect(expired.paint == .critical)
        #expect(expired.isFullCircle)
        #expect(expired.showsTrack)

        let blocked = specification(
            tone: .critical,
            fraction: 0.61,
            centerGlyph: .pause
        )
        #expect(blocked.arcFraction == 0.61)
        #expect(!blocked.isFullCircle)
        #expect(!blocked.showsGlow)

        let success = specification(
            tone: .success,
            fraction: 0.1,
            motion: .success,
            centerGlyph: .checkmark
        )
        #expect(success.paint == .success)
        #expect(success.isFullCircle)
        #expect(!success.showsTrack)
        #expect(
            success.successPulseDuration
                == RenewalRingVisualSpecification.successDuration
        )

        let historicalSuccess = specification(
            tone: .success,
            fraction: 1
        )
        #expect(historicalSuccess.successPulseDuration == nil)

        let countdown = specification(
            tone: .warning,
            fraction: 0.4,
            motion: .countdown
        )
        #expect(countdown.paint == .warning)
        #expect(countdown.arcFraction == 0.4)
        #expect(countdown.spinDuration == nil)
        #expect(!countdown.showsGlow)

        let offline = specification(
            tone: .offline,
            fraction: 0.57
        )
        #expect(offline.paint == .offline)
        #expect(offline.arcFraction == 0.57)
        #expect(offline.showsTrack)
        #expect(!offline.showsAmbientActivity)

        for (tone, paint) in [
            (RenewalRingView.Tone.needsSetup,
             RenewalRingVisualSpecification.ArcPaint.offline),
            (.environmentError, .critical)
        ] {
            let dashed = specification(tone: tone, fraction: 0.2)
            #expect(dashed.paint == paint)
            #expect(dashed.isDashed)
            #expect(dashed.isFullCircle)
            #expect(!dashed.showsTrack)
            #expect(dashed.lineWidthScale == 0.8)
            #expect(dashed.dashPattern == [0.3, 1.4])
        }
    }

    @Test
    func checkingAndDeployingShareTheSpecifiedActiveArc() {
        for motion in [
            RenewalRingView.Motion.checking,
            .deploying
        ] {
            let active = specification(
                tone: .warning,
                fraction: 0.91,
                motion: motion
            )

            #expect(active.paint == .activeGradient)
            #expect(
                active.arcFraction
                    == RenewalRingVisualSpecification.activeArcFraction
            )
            #expect(
                active.spinDuration
                    == RenewalRingVisualSpecification.activeSpinDuration
            )
            #expect(active.spinDuration == 1.4)
            #expect(active.showsGlow)
            #expect(!active.showsAmbientActivity)
        }
    }

    @Test
    func twinArcOrbitWrapsTheMainRingWithBalancedLightweightArcs() {
        let orbit = RenewalRingAmbientOrbitGeometry(
            mainDiameter: 132,
            mainLineWidth: 10
        )

        #expect(abs(orbit.diameter - 158.4) < 0.001)
        #expect(abs(orbit.lineWidth - 3.6) < 0.001)
        #expect(
            abs(
                RenewalRingVisualSpecification.twinArcFraction
                    - (34.0 / 360.0)
            ) < 0.001
        )
        #expect(
            RenewalRingVisualSpecification.twinArcPhaseOffset == 0.5
        )
        #expect(
            RenewalRingVisualSpecification.twinArcSecondaryOpacity
                == 0.36
        )
    }

    @Test
    func motionClockPausesWithoutCatchingUpHiddenTime() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var clock = RenewalRingMotionClock()
        clock.reset(isActive: true, at: start)

        let pausedAt = start.addingTimeInterval(0.6)
        clock.setActive(false, at: pausedAt)
        #expect(abs(clock.elapsed(at: start.addingTimeInterval(30)) - 0.6) < 0.001)

        let resumedAt = start.addingTimeInterval(30)
        clock.setActive(true, at: resumedAt)
        #expect(
            abs(
                clock.elapsed(at: resumedAt.addingTimeInterval(0.4))
                    - 1.0
            ) < 0.001
        )
    }

    @Test
    func heroMappingKeepsStaticStatesStillAndUsesConsumedFractions() {
        let monitoring = HeroRenewalRingPresentation.make(
            presentation: journey(
                phase: .monitoring,
                visualState: .healthy,
                motion: .idle,
                consumedFraction: 0.29
            ),
            successFeedbackIsActive: true
        )
        #expect(monitoring.tone == .neutral)
        #expect(monitoring.showsMetric)
        #expect(monitoring.fraction == 0.29)

        let blocked = HeroRenewalRingPresentation.make(
            presentation: journey(
                phase: .blocked,
                visualState: .critical,
                motion: .paused,
                consumedFraction: 0.63
            ),
            successFeedbackIsActive: true
        )
        #expect(blocked.tone == .critical)
        #expect(blocked.motion == .none)
        #expect(blocked.activeTitle == nil)
        #expect(blocked.glyph == .pause)
        #expect(blocked.fraction == 0.63)

        let environmentError = HeroRenewalRingPresentation.make(
            presentation: journey(
                phase: .attention,
                headerTone: .critical,
                visualState: .critical,
                motion: .attention
            ),
            successFeedbackIsActive: true
        )
        #expect(environmentError.tone == .environmentError)
        #expect(environmentError.motion == .none)
        #expect(environmentError.glyph == .cross)

        let recovering = HeroRenewalRingPresentation.make(
            presentation: journey(
                phase: .recovering,
                visualState: .warning,
                motion: .recovering
            ),
            successFeedbackIsActive: true
        )
        #expect(recovering.tone == .warning)
        #expect(recovering.motion == .none)
        #expect(recovering.activeTitle == nil)

        let checking = HeroRenewalRingPresentation.make(
            presentation: journey(
                phase: .checking,
                visualState: .offline,
                motion: .checking,
                consumedFraction: 0.8
            ),
            successFeedbackIsActive: true
        )
        #expect(checking.motion == .checking)
        #expect(checking.activeTitle == "检查中")
        #expect(checking.showsWaterLevel)
        #expect(!checking.showsMetric)
        #expect(
            checking.fraction
                == RenewalRingVisualSpecification.activeArcFraction
        )

        let deploying = HeroRenewalRingPresentation.make(
            presentation: journey(
                phase: .deploying,
                visualState: .warning,
                motion: .deploying,
                consumedFraction: 0.8
            ),
            successFeedbackIsActive: true
        )
        #expect(deploying.motion == .deploying)
        #expect(deploying.activeTitle == "续签中")
        #expect(deploying.showsWaterLevel)
        #expect(!deploying.showsMetric)
    }

    @Test
    func waterLevelMatchesTheH5MotionContract() {
        #expect(RenewalWaterLevelSpecification.size == 104)
        #expect(RenewalWaterLevelSpecification.riseDuration == 6)
        #expect(RenewalWaterLevelSpecification.levelPeriod == 12)
        #expect(RenewalWaterLevelSpecification.minimumLevel == 0.05)
        #expect(RenewalWaterLevelSpecification.maximumLevel == 0.95)
        #expect(RenewalWaterLevelSpecification.amplitudeFadeRange == 0.06)
        #expect(RenewalWaterLevelSpecification.bubbleInterval == 0.5)

        #expect(abs(RenewalWaterLevelSpecification.level(
            at: 0,
            reducesMotion: false
        ) - 0.05) < 0.000_001)
        #expect(abs(RenewalWaterLevelSpecification.level(
            at: 3,
            reducesMotion: false
        ) - 0.50) < 0.000_001)
        #expect(abs(RenewalWaterLevelSpecification.level(
            at: 6,
            reducesMotion: false
        ) - 0.95) < 0.000_001)
        #expect(abs(RenewalWaterLevelSpecification.level(
            at: 9,
            reducesMotion: false
        ) - 0.50) < 0.000_001)
        #expect(abs(RenewalWaterLevelSpecification.level(
            at: 12,
            reducesMotion: false
        ) - 0.05) < 0.000_001)
        #expect(RenewalWaterLevelSpecification.level(
            at: 4.2,
            reducesMotion: true
        ) == 0.52)

        #expect(RenewalWaterLevelSpecification.amplitudeScale(
            for: 0.05,
            reducesMotion: false
        ) == 0)
        #expect(abs(RenewalWaterLevelSpecification.amplitudeScale(
            for: 0.08,
            reducesMotion: false
        ) - 0.5) < 0.000_001)
        #expect(RenewalWaterLevelSpecification.amplitudeScale(
            for: 0.50,
            reducesMotion: false
        ) == 1)
        #expect(RenewalWaterLevelSpecification.amplitudeScale(
            for: 0.95,
            reducesMotion: false
        ) == 0)
        #expect(RenewalWaterLevelSpecification.amplitudeScale(
            for: 0.52,
            reducesMotion: true
        ) == 1)

        let back = RenewalWaterLevelSpecification.backWave
        #expect(back.surfaceOffset == 2)
        #expect(back.amplitude == 4.5)
        #expect(back.wavelength == 62)
        #expect(back.angularSpeed == 1.4)
        #expect(back.phase == 0)

        let front = RenewalWaterLevelSpecification.frontWave
        #expect(front.surfaceOffset == 0)
        #expect(front.amplitude == 3)
        #expect(front.wavelength == 44)
        #expect(front.angularSpeed == -2.1)
        #expect(front.phase == 1.7)
    }

    @Test
    func waterBubblesUseTheH5SpawnAndMotionRanges() {
        #expect(RenewalWaterBubbleField.bubbles(
            at: 0.1,
            surfaceY: RenewalWaterLevelSpecification.size
        ).isEmpty)

        let elapsed: TimeInterval = 4
        let surfaceY = RenewalWaterLevelSpecification.surfaceY(
            at: elapsed,
            reducesMotion: false
        )
        let bubbles = RenewalWaterBubbleField.bubbles(
            at: elapsed,
            surfaceY: surfaceY
        )

        #expect(!bubbles.isEmpty)
        for bubble in bubbles {
            #expect(bubble.x >= 18)
            #expect(bubble.x <= RenewalWaterLevelSpecification.size - 18)
            #expect(bubble.radius >= 1)
            #expect(bubble.radius <= 2.6)
            #expect(bubble.y >= surfaceY + 4)
        }
    }

    @Test
    func waterResultTransitionMatchesTheApprovedTimeline() {
        let startLevel = 0.56
        let startRotation = 260.0
        let targetFraction = 2.0 / 7.0
        let duration = RenewalWaterResultTransitionSpecification
            .drainDuration(from: startLevel, reducesMotion: false)

        #expect(duration >= 0.80)
        #expect(duration <= 1.24)

        let start = RenewalWaterResultTransitionSpecification.frame(
            at: 0,
            startLevel: startLevel,
            activeElapsed: 3.2,
            startRingRotation: startRotation,
            targetRingFraction: targetFraction,
            reducesMotion: false
        )
        #expect(start.waterLevel == startLevel)
        #expect(start.colorProgress == 0)
        #expect(start.resultOpacity == 0)
        #expect(
            start.amplitudeScale
                == RenewalWaterLevelSpecification.amplitudeScale(
                    for: startLevel,
                    reducesMotion: false
                )
        )
        #expect(
            start.ringFraction
                == RenewalRingVisualSpecification.activeArcFraction
        )
        #expect(start.ringRotation == startRotation)

        let drainingFrames = (0...20).map { index in
            RenewalWaterResultTransitionSpecification.frame(
                at: duration * Double(index) / 20,
                startLevel: startLevel,
                activeElapsed: 3.2,
                startRingRotation: startRotation,
                targetRingFraction: targetFraction,
                reducesMotion: false
            )
        }
        for index in 1..<drainingFrames.count {
            #expect(
                drainingFrames[index].waterLevel
                    <= drainingFrames[index - 1].waterLevel
            )
            #expect(
                drainingFrames[index].colorProgress
                    >= drainingFrames[index - 1].colorProgress
            )
            #expect(
                drainingFrames[index].amplitudeScale
                    <= drainingFrames[index - 1].amplitudeScale
            )
        }
        #expect(drainingFrames.allSatisfy { $0.resultOpacity == 0 })

        let drained = drainingFrames[drainingFrames.count - 1]
        #expect(drained.waterLevel == 0)
        #expect(drained.waterOpacity == 0)
        #expect(drained.colorProgress == 1)
        #expect(abs(drained.ringFraction - targetFraction) < 0.000_001)
        #expect(abs(drained.ringRotation - 270) < 0.000_001)

        let revealed = RenewalWaterResultTransitionSpecification.frame(
            at: duration
                + RenewalWaterResultTransitionSpecification
                    .resultRevealDuration,
            startLevel: startLevel,
            activeElapsed: 3.2,
            startRingRotation: startRotation,
            targetRingFraction: targetFraction,
            reducesMotion: false
        )
        #expect(revealed.waterLevel == 0)
        #expect(revealed.resultOpacity == 1)
        #expect(revealed.resultScale == 1)
        #expect(revealed.isComplete)

        let minimumLevelStart = RenewalWaterResultTransitionSpecification.frame(
            at: 0,
            startLevel: RenewalWaterLevelSpecification.minimumLevel,
            activeElapsed: 0,
            startRingRotation: -90,
            targetRingFraction: targetFraction,
            reducesMotion: false
        )
        #expect(minimumLevelStart.amplitudeScale == 0)
    }

    @Test
    func reducedMotionFadesWaterInPlaceBeforeShowingTheResult() {
        let startLevel = 0.52
        let drainDuration = RenewalWaterResultTransitionSpecification
            .reducedMotionDrainDuration
        let midpoint = RenewalWaterResultTransitionSpecification.frame(
            at: drainDuration / 2,
            startLevel: startLevel,
            activeElapsed: 0,
            startRingRotation: -90,
            targetRingFraction: 0.4,
            reducesMotion: true
        )

        #expect(midpoint.waterLevel == startLevel)
        #expect(abs(midpoint.waterOpacity - 0.5) < 0.000_001)
        #expect(midpoint.resultOpacity == 0)
        #expect(midpoint.resultScale == 1)

        let drained = RenewalWaterResultTransitionSpecification.frame(
            at: drainDuration,
            startLevel: startLevel,
            activeElapsed: 0,
            startRingRotation: -90,
            targetRingFraction: 0.4,
            reducesMotion: true
        )
        #expect(drained.waterLevel == 0)
        #expect(drained.resultOpacity == 0)

        let complete = RenewalWaterResultTransitionSpecification.frame(
            at: drainDuration
                + RenewalWaterResultTransitionSpecification
                    .reducedMotionResultRevealDuration,
            startLevel: startLevel,
            activeElapsed: 0,
            startRingRotation: -90,
            targetRingFraction: 0.4,
            reducesMotion: true
        )
        #expect(complete.resultOpacity == 1)
        #expect(complete.isComplete)
    }

    @Test
    func completedHeroReturnsToNeutralWithoutChangingHistoricalSuccess() {
        let completed = journey(
            phase: .completed,
            visualState: .healthy,
            motion: .success,
            consumedFraction: 0.08
        )

        let feedback = HeroRenewalRingPresentation.make(
            presentation: completed,
            successFeedbackIsActive: true
        )
        #expect(feedback.tone == .success)
        #expect(feedback.motion == .success)
        #expect(feedback.glyph == .checkmark)
        #expect(feedback.fraction == 1)

        let settled = HeroRenewalRingPresentation.make(
            presentation: completed,
            successFeedbackIsActive: false
        )
        #expect(settled.tone == .neutral)
        #expect(settled.motion == .none)
        #expect(settled.glyph == .none)
        #expect(settled.fraction == 0.08)

        let history = specification(
            tone: .success,
            fraction: 1,
            motion: .none
        )
        #expect(history.paint == .success)
        #expect(history.successPulseDuration == nil)
    }

#if DEBUG
    @MainActor
    @Test
    func writesCompleteHeroRingVisualReviewSet() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "IOS_SIGN_KIT_HERO_RING_ARTIFACT_DIR"
        ], !outputPath.isEmpty else {
            return
        }

        let outputDirectory = URL(
            fileURLWithPath: outputPath,
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let lightScenarios: [(String, PrimaryJourneyPresentation)] = [
            (
                "hero-normal-light.png",
                journey(
                    phase: .monitoring,
                    visualState: .normal,
                    motion: .idle,
                    consumedFraction: 0.57,
                    headerDetail: "个人签名将在 3 天后到期。"
                )
            ),
            (
                "hero-warning-light.png",
                journey(
                    phase: .monitoring,
                    headerTone: .warning,
                    visualState: .warning,
                    motion: .idle,
                    consumedFraction: 0.92,
                    headerDetail: "签名将在今天到期，可立即续签。",
                    metricValue: "5",
                    metricUnit: "小时"
                )
            ),
            (
                "hero-expired-light.png",
                journey(
                    phase: .renewalRequired,
                    headerTone: .critical,
                    visualState: .critical,
                    motion: .attention,
                    consumedFraction: 1,
                    headerDetail: "签名已失效，设备已连接。"
                )
            ),
            (
                "hero-success-light.png",
                journey(
                    phase: .completed,
                    visualState: .healthy,
                    motion: .success,
                    consumedFraction: 0.04,
                    headerDetail: "本次续签已完成，新签名有效期为 7 天。"
                )
            ),
            (
                "hero-countdown-light.png",
                journey(
                    phase: .countdown,
                    headerTone: .warning,
                    visualState: .warning,
                    motion: .countdown(fraction: 0.6),
                    consumedFraction: 1,
                    progress: .fraction(0.6),
                    headerDetail: "保持设备连接，倒计时结束后自动续签。"
                )
            ),
            (
                "hero-blocked-light.png",
                journey(
                    phase: .blocked,
                    headerTone: .critical,
                    visualState: .critical,
                    motion: .paused,
                    consumedFraction: 0.63,
                    headerDetail: "检测到遗留部署进程，自动续签已阻止。"
                )
            ),
            (
                "hero-offline-light.png",
                journey(
                    phase: .waitingForDevice,
                    headerTone: .warning,
                    visualState: .offline,
                    motion: .paused,
                    consumedFraction: 0.57,
                    headerDetail: "签名剩余 3 天，连接设备后可立即续签。"
                )
            ),
            (
                "hero-needs-setup-light.png",
                journey(
                    phase: .needsSetup,
                    headerTone: .warning,
                    visualState: .warning,
                    motion: .idle,
                    consumedFraction: 0,
                    headerDetail: "选择项目和目标设备后开始监测签名。"
                )
            ),
            (
                "hero-environment-error-light.png",
                journey(
                    phase: .attention,
                    headerTone: .critical,
                    visualState: .critical,
                    motion: .attention,
                    consumedFraction: 0,
                    headerTitle: "开发环境异常",
                    headerDetail: "未找到可用的 Xcode 命令行工具。"
                )
            ),
            (
                "hero-checking-light.png",
                journey(
                    phase: .checking,
                    visualState: .normal,
                    motion: .checking,
                    consumedFraction: 0.57,
                    headerDetail: "正在核对设备连接与 App 安装状态。"
                )
            )
        ]

        for (filename, presentation) in lightScenarios {
            try await writeHeroScreenshot(
                presentation: presentation,
                colorScheme: .light,
                to: outputDirectory.appendingPathComponent(filename)
            )
        }

        for (filename, presentation) in [
            (
                "hero-normal-dark.png",
                journey(
                    phase: .monitoring,
                    visualState: .normal,
                    motion: .idle,
                    consumedFraction: 0.57,
                    headerDetail: "个人签名将在 3 天后到期。"
                )
            ),
            (
                "hero-offline-dark.png",
                journey(
                    phase: .waitingForDevice,
                    headerTone: .warning,
                    visualState: .offline,
                    motion: .paused,
                    consumedFraction: 0.57,
                    headerDetail: "签名剩余 3 天，连接设备后可立即续签。"
                )
            )
        ] {
            try await writeHeroScreenshot(
                presentation: presentation,
                colorScheme: .dark,
                to: outputDirectory.appendingPathComponent(filename)
            )
        }

        try await writeCheckingCloseup(
            to: outputDirectory.appendingPathComponent(
                "hero-checking-closeup-2x.png"
            )
        )
    }
#endif

    private func specification(
        tone: RenewalRingView.Tone,
        fraction: Double,
        motion: RenewalRingView.Motion = .none,
        centerGlyph: RenewalRingView.CenterGlyph = .none
    ) -> RenewalRingVisualSpecification {
        RenewalRingVisualSpecification.make(
            tone: tone,
            motion: motion,
            centerGlyph: centerGlyph,
            fraction: fraction
        )
    }

    private func journey(
        phase: PrimaryJourneyPhase,
        headerTone: StatusTone = .good,
        visualState: RenewalIconVisualState,
        motion: RenewalIconMotion,
        consumedFraction: Double = 0.57,
        progress: OperationActivityProgress? = nil,
        headerTitle: String = "状态",
        headerDetail: String = "状态详情",
        metricValue: String = "3",
        metricUnit: String? = "天"
    ) -> PrimaryJourneyPresentation {
        let taskKind: PrimaryJourneyTask.Kind?
        switch phase {
        case .blocked:
            taskKind = .processRecoveryBlocked
        case .checking:
            taskKind = .checking
        case .countdown:
            taskKind = .countdown
        case .recovering:
            taskKind = .recovering
        case .deploying:
            taskKind = .deploying
        case .completed, .attention:
            taskKind = .currentFeedback
        case .needsSetup, .waitingForDevice, .monitoring,
             .renewalRequired:
            taskKind = nil
        }

        let task = taskKind.map {
            PrimaryJourneyTask(
                kind: $0,
                title: "状态",
                detail: "状态详情",
                tone: headerTone,
                systemImage: "circle",
                progress: progress,
                actions: []
            )
        }

        let headerActions = [
            PrimaryJourneyAction(
                id: .requestRefresh,
                title: "立即续签",
                systemImage: "arrow.clockwise",
                placement: .header,
                style: .primary,
                availability: .enabled
            ),
            PrimaryJourneyAction(
                id: .recheck,
                title: "重新检查",
                systemImage: "arrow.clockwise",
                placement: .header,
                style: .secondary,
                availability: .enabled
            )
        ]

        return PrimaryJourneyPresentation(
            phase: phase,
            header: PrimaryJourneyHeader(
                title: headerTitle,
                detail: headerDetail,
                tone: headerTone,
                systemImage: "circle",
                lastFullVerificationSummary: "刚刚确认",
                remainingExpiryText: [metricValue, metricUnit]
                    .compactMap { $0 }
                    .joined(),
                remainingExpiryComponents: [
                    RemainingExpiryMetricComponent(
                        value: metricValue,
                        unit: metricUnit
                    )
                ],
                consumedExpiryProgress: consumedFraction,
                expiredDurationText: phase == .renewalRequired
                    ? "2 小时前"
                    : nil
            ),
            renewalIcon: RenewalIconPresentation(
                visualState: visualState,
                motion: motion
            ),
            targetDevice: PrimaryJourneyTargetDevice(
                value: "测试 iPhone",
                detail: "iOS 26",
                cardDetail: "App 已安装",
                tone: .good,
                badgeSystemImage: "iphone"
            ),
            verificationSteps: [],
            currentTask: task,
            previousResult: nil,
            headerActions: headerActions,
            deviceSelectionIsEnabled: true
        )
    }

#if DEBUG
    @MainActor
    private func writeHeroScreenshot(
        presentation: PrimaryJourneyPresentation,
        colorScheme: ColorScheme,
        to destination: URL
    ) async throws {
        let size = CGSize(width: 912, height: 216)
        let content = HeroCountdownCard(
            presentation: presentation,
            onAction: { _ in },
            onOpenSettings: {},
            isAnimationActive: true
        )
        .frame(width: 872)
        .padding(20)
        .background(ColorTokens.BG.canvas)
        .environment(\.colorScheme, colorScheme)

        try await writeScreenshot(
            content,
            size: size,
            scale: 2,
            to: destination
        )
    }

    @MainActor
    private func writeCheckingCloseup(to destination: URL) async throws {
        let size = CGSize(width: 172, height: 172)
        let content = ZStack {
            RenewalRingView(
                diameter: 132,
                lineWidth: 10,
                tone: .normal,
                fraction: 0.9,
                motion: .checking,
                isAnimationActive: true
            )

            RenewalWaterLevelView(
                title: "检查中",
                isAnimationActive: false,
                elapsedOverride: 3
            )
        }
        .frame(width: 132, height: 132)
        .padding(20)
        .background(ColorTokens.BG.canvas)
        .environment(\.colorScheme, .light)

        try await writeScreenshot(
            content,
            size: size,
            scale: 4,
            to: destination
        )
    }

    @MainActor
    private func writeScreenshot<Content: View>(
        _ content: Content,
        size: CGSize,
        scale: CGFloat,
        to destination: URL
    ) async throws {
        let hostingView = NSHostingView(
            rootView: content.frame(
                width: size.width,
                height: size.height
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try #require(
            bitmap.representation(using: .png, properties: [:])
        )
        try png.write(to: destination, options: .atomic)
        window.contentView = nil
        window.close()
    }
#endif
}
