import SwiftUI

struct RenewalWaterLevelSpecification: Equatable {
    static let size: CGFloat = 104
    static let riseDuration: TimeInterval = 6
    static let levelPeriod: TimeInterval = riseDuration * 2
    static let minimumLevel = 0.05
    static let maximumLevel = 0.95
    static let amplitudeFadeRange = 0.06
    static let bubbleInterval: TimeInterval = 0.5
    static let bubbleMinimumLevel = minimumLevel + 0.03

    struct Wave: Equatable {
        let surfaceOffset: CGFloat
        let amplitude: CGFloat
        let wavelength: CGFloat
        let angularSpeed: Double
        let phase: Double
    }

    static let backWave = Wave(
        surfaceOffset: 2,
        amplitude: 4.5,
        wavelength: 62,
        angularSpeed: 1.4,
        phase: 0
    )

    static let frontWave = Wave(
        surfaceOffset: 0,
        amplitude: 3,
        wavelength: 44,
        angularSpeed: -2.1,
        phase: 1.7
    )

    static func level(
        at elapsed: TimeInterval,
        reducesMotion: Bool
    ) -> Double {
        guard !reducesMotion else { return 0.52 }
        return minimumLevel
            + (maximumLevel - minimumLevel)
                * (0.5 - 0.5 * cos((2 * .pi * elapsed) / levelPeriod))
    }

    static func surfaceY(
        at elapsed: TimeInterval,
        reducesMotion: Bool
    ) -> CGFloat {
        size * CGFloat(1 - level(at: elapsed, reducesMotion: reducesMotion))
    }

    static func amplitudeScale(
        for level: Double,
        reducesMotion: Bool
    ) -> Double {
        guard !reducesMotion else { return 1 }
        return max(
            min((level - minimumLevel) / amplitudeFadeRange, 1)
                * min((maximumLevel - level) / amplitudeFadeRange, 1),
            0
        )
    }

    static func waveOffset(
        x: CGFloat,
        elapsed: TimeInterval,
        wave: Wave,
        amplitudeScale: Double
    ) -> CGFloat {
        wave.amplitude * CGFloat(amplitudeScale)
            * sin(
                (x / wave.wavelength) * .pi * 2
                    + wave.angularSpeed * elapsed
                    + wave.phase
            )
    }
}

struct RenewalWaterResultTransitionFrame: Equatable {
    let transitionElapsed: TimeInterval
    let drainProgress: Double
    let colorProgress: Double
    let waterLevel: Double
    let waterOpacity: Double
    let bubbleOpacity: Double
    let amplitudeScale: Double
    let activeCaptionOpacity: Double
    let resultOpacity: Double
    let resultScale: CGFloat
    let waterElapsed: TimeInterval
    let ringFraction: Double
    let ringRotation: Double
    let isComplete: Bool
}

struct RenewalWaterResultTransitionSpecification: Equatable {
    static let minimumDrainDuration: TimeInterval = 0.80
    static let maximumDrainDuration: TimeInterval = 1.24
    static let drainBaseDuration: TimeInterval = 0.72
    static let drainLevelFactor: TimeInterval = 0.52
    static let reducedMotionDrainDuration: TimeInterval = 0.16
    static let resultRevealDuration: TimeInterval = 0.26
    static let reducedMotionResultRevealDuration: TimeInterval = 0.16
    static let colorHoldProgress = 0.05
    static let colorCompletionProgress = 0.82
    static let waterFadeStartProgress = 0.88
    static let resultInitialScale: CGFloat = 0.965

    static func drainDuration(
        from level: Double,
        reducesMotion: Bool
    ) -> TimeInterval {
        guard !reducesMotion else { return reducedMotionDrainDuration }
        return clamp(
            drainBaseDuration + drainLevelFactor * sqrt(clamp(level)),
            minimum: minimumDrainDuration,
            maximum: maximumDrainDuration
        )
    }

    static func frame(
        at transitionElapsed: TimeInterval,
        startLevel: Double,
        activeElapsed: TimeInterval,
        startRingRotation: Double,
        targetRingFraction: Double,
        reducesMotion: Bool
    ) -> RenewalWaterResultTransitionFrame {
        let elapsed = max(transitionElapsed, 0)
        let duration = drainDuration(
            from: startLevel,
            reducesMotion: reducesMotion
        )
        let rawDrainProgress = clamp(elapsed / duration)
        let easedDrainProgress = reducesMotion
            ? rawDrainProgress
            : easeInOutCubic(rawDrainProgress)
        let level = reducesMotion
            ? (rawDrainProgress < 1 ? clamp(startLevel) : 0)
            : clamp(startLevel) * (1 - easedDrainProgress)
        let drainedRatio = reducesMotion
            ? rawDrainProgress
            : startLevel <= 0
                ? 1
                : 1 - level / clamp(startLevel)
        let colorProgress = smoothstep(
            from: colorHoldProgress,
            to: colorCompletionProgress,
            value: drainedRatio
        )
        let waterOpacity = reducesMotion
            ? 1 - rawDrainProgress
            : 1 - smoothstep(
                from: waterFadeStartProgress,
                to: 1,
                value: drainedRatio
            )
        let activeCaptionOpacity = 1 - smoothstep(
            from: 0.02,
            to: 0.28,
            value: rawDrainProgress
        )
        let revealDuration = reducesMotion
            ? reducedMotionResultRevealDuration
            : resultRevealDuration
        let rawRevealProgress = clamp((elapsed - duration) / revealDuration)
        let resultOpacity = smoothstep(
            from: 0,
            to: 1,
            value: rawRevealProgress
        )
        let resultScale = reducesMotion
            ? 1
            : mix(
                resultInitialScale,
                1,
                resultOpacity
            )
        let ringProgress = easeInOutCubic(rawDrainProgress)
        let targetRotation = nearestEquivalentAngle(
            target: -90,
            reference: startRingRotation
        )
        let startAmplitudeScale = RenewalWaterLevelSpecification
            .amplitudeScale(
                for: startLevel,
                reducesMotion: reducesMotion
            )
        let amplitudeScale = reducesMotion
            ? 1
            : min(
                startAmplitudeScale,
                smoothstep(from: 0, to: 0.08, value: level)
            ) * (1 - 0.28 * colorProgress)

        return RenewalWaterResultTransitionFrame(
            transitionElapsed: elapsed,
            drainProgress: rawDrainProgress,
            colorProgress: colorProgress,
            waterLevel: level,
            waterOpacity: waterOpacity,
            bubbleOpacity: max(1 - elapsed * 1.8, 0) * waterOpacity,
            amplitudeScale: amplitudeScale,
            activeCaptionOpacity: activeCaptionOpacity,
            resultOpacity: resultOpacity,
            resultScale: resultScale,
            waterElapsed: reducesMotion
                ? activeElapsed
                : activeElapsed + elapsed,
            ringFraction: mix(
                RenewalRingVisualSpecification.activeArcFraction,
                clamp(targetRingFraction),
                ringProgress
            ),
            ringRotation: mix(
                startRingRotation,
                targetRotation,
                ringProgress
            ),
            isComplete: rawRevealProgress >= 1
        )
    }

    static func activeRingRotation(at elapsed: TimeInterval) -> Double {
        -90 + normalized(
            elapsed / RenewalRingVisualSpecification.activeSpinDuration
        ) * 360
    }

    static func nearestEquivalentAngle(
        target: Double,
        reference: Double
    ) -> Double {
        target + 360 * ((reference - target) / 360).rounded()
    }

    private static func easeInOutCubic(_ value: Double) -> Double {
        let progress = clamp(value)
        if progress < 0.5 {
            return 4 * progress * progress * progress
        }
        return 1 - pow(-2 * progress + 2, 3) / 2
    }

    private static func smoothstep(
        from: Double,
        to: Double,
        value: Double
    ) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        let progress = clamp((value - from) / (to - from))
        return progress * progress * (3 - 2 * progress)
    }

    private static func mix(
        _ from: Double,
        _ to: Double,
        _ progress: Double
    ) -> Double {
        from + (to - from) * progress
    }

    private static func mix(
        _ from: CGFloat,
        _ to: CGFloat,
        _ progress: Double
    ) -> CGFloat {
        from + (to - from) * CGFloat(progress)
    }

    private static func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func clamp(
        _ value: Double,
        minimum: Double = 0,
        maximum: Double = 1
    ) -> Double {
        min(max(value, minimum), maximum)
    }
}

struct RenewalWaterBubble: Equatable {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
}

enum RenewalWaterBubbleField {
    private static let maximumLifetime: TimeInterval = 8

    static func bubbles(
        at elapsed: TimeInterval,
        surfaceY: CGFloat,
        spawnedBefore spawnCutoff: TimeInterval? = nil
    ) -> [RenewalWaterBubble] {
        guard elapsed > 0 else { return [] }

        let interval = RenewalWaterLevelSpecification.bubbleInterval
        let latestSlot = min(
            Int(floor(elapsed / interval)),
            spawnCutoff.map { Int(floor($0 / interval)) }
                ?? .max
        )
        let earliestSlot = max(
            1,
            Int(floor((elapsed - maximumLifetime) / interval))
        )
        guard latestSlot >= earliestSlot else { return [] }

        return (earliestSlot...latestSlot).compactMap { slot in
            let spawnedAt = Double(slot) * interval
            let spawnLevel = RenewalWaterLevelSpecification.level(
                at: spawnedAt,
                reducesMotion: false
            )
            guard spawnLevel
                    > RenewalWaterLevelSpecification.bubbleMinimumLevel else {
                return nil
            }

            let age = elapsed - spawnedAt
            let speed = 14 + unitValue(slot: slot, stream: 2) * 12
            let y = RenewalWaterLevelSpecification.size + 4
                - CGFloat(speed * age)
            guard y >= surfaceY + 4 else { return nil }

            return RenewalWaterBubble(
                x: 18
                    + CGFloat(unitValue(slot: slot, stream: 0))
                        * (RenewalWaterLevelSpecification.size - 36),
                y: y,
                radius: 1 + CGFloat(unitValue(slot: slot, stream: 1)) * 1.6
            )
        }
    }

    private static func unitValue(slot: Int, stream: UInt64) -> Double {
        var value = UInt64(slot) &+ (stream &* 0x9E37_79B9_7F4A_7C15)
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value & 0x1F_FFFF_FFFF_FFFF)
            / Double(0x20_0000_0000_0000)
    }
}

private struct RenewalWaterRGB {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    func mixed(with target: Self, progress: Double) -> Self {
        let clampedProgress = min(max(progress, 0), 1)
        return RenewalWaterRGB(
            red: red + (target.red - red) * clampedProgress,
            green: green + (target.green - green) * clampedProgress,
            blue: blue + (target.blue - blue) * clampedProgress
        )
    }
}

private struct RenewalWaterPalette {
    let top: RenewalWaterRGB
    let bottom: RenewalWaterRGB
    let backOpacity: Double
    let frontTopOpacity: Double
    let bubbleOpacity: Double

    static func make(colorScheme: ColorScheme) -> Self {
        if colorScheme == .dark {
            return RenewalWaterPalette(
                top: RenewalWaterRGB(red: 111, green: 216, blue: 232),
                bottom: RenewalWaterRGB(red: 76, green: 157, blue: 255),
                backOpacity: 0.40,
                frontTopOpacity: 0.90,
                bubbleOpacity: 0.75
            )
        }
        return RenewalWaterPalette(
            top: RenewalWaterRGB(red: 100, green: 210, blue: 255),
            bottom: RenewalWaterRGB(red: 10, green: 132, blue: 255),
            backOpacity: 0.45,
            frontTopOpacity: 0.92,
            bubbleOpacity: 0.80
        )
    }
}

private struct RenewalWaterLayer: View {
    let elapsed: TimeInterval
    let level: Double
    let amplitudeScale: Double
    let backColor: Color
    let frontTopColor: Color
    let frontBottomColor: Color
    let bubbleColor: Color
    let bubbleOpacity: Double
    let bubbleSpawnCutoff: TimeInterval?
    let showsBubbles: Bool

    var body: some View {
        let surfaceY = RenewalWaterLevelSpecification.size
            * CGFloat(1 - level)

        Canvas { context, _ in
            drawWave(
                RenewalWaterLevelSpecification.backWave,
                surfaceY: surfaceY,
                shading: .color(backColor),
                in: &context
            )

            drawWave(
                RenewalWaterLevelSpecification.frontWave,
                surfaceY: surfaceY,
                shading: .linearGradient(
                    Gradient(colors: [frontTopColor, frontBottomColor]),
                    startPoint: CGPoint(x: 0, y: surfaceY - 6),
                    endPoint: CGPoint(
                        x: 0,
                        y: RenewalWaterLevelSpecification.size
                    )
                ),
                in: &context
            )

            guard showsBubbles, bubbleOpacity > 0 else { return }
            for bubble in RenewalWaterBubbleField.bubbles(
                at: elapsed,
                surfaceY: surfaceY,
                spawnedBefore: bubbleSpawnCutoff
            ) {
                let diameter = bubble.radius * 2
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: bubble.x - bubble.radius,
                            y: bubble.y - bubble.radius,
                            width: diameter,
                            height: diameter
                        )
                    ),
                    with: .color(bubbleColor.opacity(bubbleOpacity))
                )
            }
        }
        .opacity(level > 0 ? 1 : 0)
    }

    private func drawWave(
        _ wave: RenewalWaterLevelSpecification.Wave,
        surfaceY: CGFloat,
        shading: GraphicsContext.Shading,
        in context: inout GraphicsContext
    ) {
        let size = RenewalWaterLevelSpecification.size
        var path = Path()
        path.move(to: CGPoint(x: -2, y: size + 2))

        var x: CGFloat = -2
        while x <= size + 2 {
            path.addLine(
                to: CGPoint(
                    x: x,
                    y: surfaceY
                        + wave.surfaceOffset
                        + RenewalWaterLevelSpecification.waveOffset(
                            x: x,
                            elapsed: elapsed,
                            wave: wave,
                            amplitudeScale: amplitudeScale
                        )
                )
            )
            x += 3
        }

        path.addLine(to: CGPoint(x: size + 2, y: size + 2))
        path.closeSubpath()
        context.fill(path, with: shading)
    }
}

struct RenewalWaterLevelView: View {
    let title: String
    let isAnimationActive: Bool
    var elapsedOverride: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var motionClock = RenewalRingMotionClock()

    init(
        title: String,
        isAnimationActive: Bool,
        elapsedOverride: TimeInterval? = nil
    ) {
        self.title = title
        self.isAnimationActive = isAnimationActive
        self.elapsedOverride = elapsedOverride
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1 / 60,
                paused: !animationShouldRun
            )
        ) { context in
            let elapsed = elapsedOverride
                ?? motionClock.elapsed(at: context.date)

            ZStack {
                waterCanvas(elapsed: elapsed)

                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(0.32)
                        .foregroundStyle(ColorTokens.Text.primary)

                    Text("已用时 \(elapsedText(elapsed))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(ColorTokens.Text.secondary)
                }
                .shadow(
                    color: colorScheme == .dark
                        ? .black.opacity(0.40)
                        : .white.opacity(0.35),
                    radius: 3,
                    x: 0,
                    y: 1
                )
            }
        }
        .frame(
            width: RenewalWaterLevelSpecification.size,
            height: RenewalWaterLevelSpecification.size
        )
        .clipShape(Circle())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            resetMotionClock()
        }
        .onChange(of: title) { _, _ in
            resetMotionClock()
        }
        .onChange(of: animationShouldRun) { _, isActive in
            setMotionClockActive(isActive)
        }
    }

    private var animationShouldRun: Bool {
        isAnimationActive && !reduceMotion && elapsedOverride == nil
    }

    private func waterCanvas(elapsed: TimeInterval) -> some View {
        let level = RenewalWaterLevelSpecification.level(
            at: elapsed,
            reducesMotion: reduceMotion
        )
        let amplitudeScale = RenewalWaterLevelSpecification.amplitudeScale(
            for: level,
            reducesMotion: reduceMotion
        )
        let palette = RenewalWaterPalette.make(colorScheme: colorScheme)

        return RenewalWaterLayer(
            elapsed: elapsed,
            level: level,
            amplitudeScale: amplitudeScale,
            backColor: palette.top.color.opacity(palette.backOpacity),
            frontTopColor: palette.top.color.opacity(palette.frontTopOpacity),
            frontBottomColor: palette.bottom.color.opacity(0.95),
            bubbleColor: .white,
            bubbleOpacity: palette.bubbleOpacity,
            bubbleSpawnCutoff: nil,
            showsBubbles: !reduceMotion
        )
    }

    private func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = max(Int(elapsed), 0)
        return String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
    }

    private func resetMotionClock() {
        var updatedClock = motionClock
        updatedClock.reset(
            isActive: animationShouldRun,
            at: Date()
        )
        motionClock = updatedClock
    }

    private func setMotionClockActive(_ isActive: Bool) {
        var updatedClock = motionClock
        updatedClock.setActive(isActive, at: Date())
        motionClock = updatedClock
    }
}

struct RenewalWaterResultTransitionView: View {
    let title: String
    let activeElapsed: TimeInterval
    let targetTone: RenewalRingView.Tone
    let frame: RenewalWaterResultTransitionFrame

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = RenewalWaterPalette.make(colorScheme: colorScheme)
        let target = targetRGB
        let top = palette.top.mixed(
            with: target,
            progress: frame.colorProgress
        )
        let bottom = palette.bottom.mixed(
            with: target,
            progress: frame.colorProgress
        )

        ZStack {
            RenewalWaterLayer(
                elapsed: frame.waterElapsed,
                level: frame.waterLevel,
                amplitudeScale: frame.amplitudeScale,
                backColor: top.color.opacity(
                    palette.backOpacity * frame.waterOpacity
                ),
                frontTopColor: top.color.opacity(
                    palette.frontTopOpacity * frame.waterOpacity
                ),
                frontBottomColor: bottom.color.opacity(
                    0.95 * frame.waterOpacity
                ),
                bubbleColor: .white,
                bubbleOpacity: palette.bubbleOpacity * frame.bubbleOpacity,
                bubbleSpawnCutoff: activeElapsed,
                showsBubbles: !reduceMotion
            )

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(0.32)
                    .foregroundStyle(ColorTokens.Text.primary)

                Text("已用时 \(elapsedText(frame.waterElapsed))")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ColorTokens.Text.secondary)
            }
            .opacity(frame.activeCaptionOpacity)
            .offset(
                y: reduceMotion
                    ? 0
                    : 4 * (1 - frame.activeCaptionOpacity)
            )
            .shadow(
                color: colorScheme == .dark
                    ? .black.opacity(0.40)
                    : .white.opacity(0.35),
                radius: 3,
                x: 0,
                y: 1
            )
        }
        .frame(
            width: RenewalWaterLevelSpecification.size,
            height: RenewalWaterLevelSpecification.size
        )
        .clipShape(Circle())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var targetRGB: RenewalWaterRGB {
        RenewalWaterTransitionPalette.target(
            for: targetTone,
            colorScheme: colorScheme
        )
    }

    private func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = max(Int(elapsed), 0)
        return String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
}

struct RenewalRingResultTransitionView: View {
    let targetTone: RenewalRingView.Tone
    let frame: RenewalWaterResultTransitionFrame
    var diameter: CGFloat = 132
    var lineWidth: CGFloat = 10

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let geometry = RenewalRingGeometry(
            diameter: diameter,
            lineWidth: lineWidth
        )
        let palette = RenewalWaterPalette.make(colorScheme: colorScheme)
        let target = RenewalWaterTransitionPalette.target(
            for: targetTone,
            colorScheme: colorScheme
        )
        let gradientStart = palette.bottom.mixed(
            with: target,
            progress: frame.colorProgress
        )
        let gradientEnd = palette.top.mixed(
            with: target,
            progress: frame.colorProgress
        )

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            ColorTokens.Accent.renewGlow.opacity(0.32),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter * (44 / 132)
                    )
                )
                .frame(
                    width: max(diameter - lineWidth * 0.8, 0),
                    height: max(diameter - lineWidth * 0.8, 0)
                )
                .scaleEffect(glowScale)
                .opacity(glowOpacity * (1 - frame.drainProgress))

            Circle()
                .inset(by: geometry.inset)
                .stroke(
                    ColorTokens.Border.subtle,
                    style: StrokeStyle(lineWidth: lineWidth)
                )

            Circle()
                .inset(by: geometry.inset)
                .trim(from: 0, to: CGFloat(frame.ringFraction))
                .stroke(
                    LinearGradient(
                        colors: [
                            gradientStart.color,
                            gradientEnd.color
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .rotationEffect(.degrees(frame.ringRotation))
        }
        .frame(width: diameter, height: diameter)
        .drawingGroup(opaque: false)
        .accessibilityHidden(true)
    }

    private var glowPhase: Double {
        let cycle = normalized(
            frame.waterElapsed
                / (RenewalRingVisualSpecification.glowDuration * 2)
        )
        let triangle = cycle <= 0.5 ? cycle * 2 : (1 - cycle) * 2
        return 0.5 - 0.5 * cos(.pi * triangle)
    }

    private var glowScale: CGFloat {
        0.92 + 0.13 * CGFloat(glowPhase)
    }

    private var glowOpacity: Double {
        0.35 + 0.55 * glowPhase
    }

    private func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }
}

private enum RenewalWaterTransitionPalette {
    static func target(
        for tone: RenewalRingView.Tone,
        colorScheme: ColorScheme
    ) -> RenewalWaterRGB {
        switch tone {
        case .normal:
            return colorScheme == .dark
                ? RenewalWaterRGB(red: 76, green: 157, blue: 255)
                : RenewalWaterRGB(red: 10, green: 132, blue: 255)
        case .neutral, .offline, .needsSetup:
            return colorScheme == .dark
                ? RenewalWaterRGB(red: 152, green: 152, blue: 157)
                : RenewalWaterRGB(red: 142, green: 142, blue: 147)
        case .warning:
            return colorScheme == .dark
                ? RenewalWaterRGB(red: 255, green: 159, blue: 10)
                : RenewalWaterRGB(red: 255, green: 149, blue: 0)
        case .critical, .environmentError:
            return colorScheme == .dark
                ? RenewalWaterRGB(red: 255, green: 69, blue: 58)
                : RenewalWaterRGB(red: 255, green: 59, blue: 48)
        case .success:
            return colorScheme == .dark
                ? RenewalWaterRGB(red: 48, green: 209, blue: 88)
                : RenewalWaterRGB(red: 52, green: 199, blue: 89)
        }
    }
}
