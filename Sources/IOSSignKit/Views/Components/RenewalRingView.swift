import AppKit
import SwiftUI

struct RenewalRingGeometry: Equatable {
    let diameter: CGFloat
    let lineWidth: CGFloat

    var inset: CGFloat {
        lineWidth / 2
    }

    var pathDiameter: CGFloat {
        max(diameter - lineWidth, 0)
    }

    var pathRadius: CGFloat {
        pathDiameter / 2
    }
}

struct RenewalRingAmbientOrbitGeometry: Equatable {
    static let diameterScale: CGFloat = 1.2
    static let lineWidthScale: CGFloat = 0.36

    let mainDiameter: CGFloat
    let mainLineWidth: CGFloat

    var diameter: CGFloat {
        mainDiameter * Self.diameterScale
    }

    var lineWidth: CGFloat {
        mainLineWidth * Self.lineWidthScale
    }

    var inset: CGFloat {
        lineWidth / 2
    }

}

struct RenewalRingMotionClock: Equatable {
    private(set) var accumulatedElapsed: TimeInterval = 0
    private(set) var resumedAt: Date?

    mutating func reset(isActive: Bool, at date: Date) {
        accumulatedElapsed = 0
        resumedAt = isActive ? date : nil
    }

    mutating func setActive(_ isActive: Bool, at date: Date) {
        if isActive {
            if resumedAt == nil {
                resumedAt = date
            }
            return
        }

        if let resumedAt {
            accumulatedElapsed += max(date.timeIntervalSince(resumedAt), 0)
            self.resumedAt = nil
        }
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let resumedAt else { return accumulatedElapsed }
        return accumulatedElapsed + max(date.timeIntervalSince(resumedAt), 0)
    }
}

struct RenewalRingVisualSpecification: Equatable {
    enum ArcPaint: Equatable {
        case normalGradient
        case activeGradient
        case neutral
        case warning
        case critical
        case success
        case offline
    }

    static let activeArcFraction = 0.32
    static let inlineActivityFraction: CGFloat = 0.06
    static let twinArcFraction: CGFloat = 34.0 / 360.0
    static let twinArcPhaseOffset = 0.5
    static let twinArcSecondaryOpacity = 0.36
    static let activeSpinDuration: TimeInterval = 1.4
    static let ambientOrbitDuration: TimeInterval = 6
    static let glowDuration: TimeInterval = 0.9
    static let successDuration: TimeInterval = 2.8

    let paint: ArcPaint
    let arcFraction: Double
    let isFullCircle: Bool
    let showsTrack: Bool
    let showsGlow: Bool
    let showsAmbientActivity: Bool
    let isDashed: Bool
    let lineWidthScale: CGFloat
    let dashPattern: [CGFloat]
    let spinDuration: TimeInterval?
    let successPulseDuration: TimeInterval?

    static func make(
        tone: RenewalRingView.Tone,
        motion: RenewalRingView.Motion,
        centerGlyph: RenewalRingView.CenterGlyph,
        fraction: Double
    ) -> RenewalRingVisualSpecification {
        let clampedFraction = min(max(fraction, 0), 1)

        switch tone {
        case .needsSetup:
            return dashedSpecification(paint: .offline)
        case .environmentError:
            return dashedSpecification(paint: .critical)
        case .success:
            return RenewalRingVisualSpecification(
                paint: .success,
                arcFraction: 1,
                isFullCircle: true,
                showsTrack: false,
                showsGlow: false,
                showsAmbientActivity: false,
                isDashed: false,
                lineWidthScale: 1,
                dashPattern: [],
                spinDuration: nil,
                successPulseDuration: motion == .success
                    ? successDuration
                    : nil
            )
        case .normal, .neutral, .warning, .critical, .offline:
            break
        }

        if motion == .checking || motion == .deploying {
            return RenewalRingVisualSpecification(
                paint: .activeGradient,
                arcFraction: activeArcFraction,
                isFullCircle: false,
                showsTrack: true,
                showsGlow: true,
                showsAmbientActivity: false,
                isDashed: false,
                lineWidthScale: 1,
                dashPattern: [],
                spinDuration: activeSpinDuration,
                successPulseDuration: nil
            )
        }

        if motion == .countdown {
            return progressSpecification(
                paint: .warning,
                fraction: clampedFraction
            )
        }

        switch tone {
        case .normal:
            var specification = progressSpecification(
                paint: .normalGradient,
                fraction: clampedFraction
            )
            specification = RenewalRingVisualSpecification(
                paint: specification.paint,
                arcFraction: specification.arcFraction,
                isFullCircle: specification.isFullCircle,
                showsTrack: specification.showsTrack,
                showsGlow: specification.showsGlow,
                showsAmbientActivity: true,
                isDashed: specification.isDashed,
                lineWidthScale: specification.lineWidthScale,
                dashPattern: specification.dashPattern,
                spinDuration: specification.spinDuration,
                successPulseDuration: specification.successPulseDuration
            )
            return specification
        case .neutral:
            return progressSpecification(
                paint: .neutral,
                fraction: clampedFraction
            )
        case .warning:
            return progressSpecification(
                paint: .warning,
                fraction: clampedFraction
            )
        case .critical:
            if centerGlyph == .pause {
                return progressSpecification(
                    paint: .critical,
                    fraction: clampedFraction
                )
            }
            return RenewalRingVisualSpecification(
                paint: .critical,
                arcFraction: 1,
                isFullCircle: true,
                showsTrack: true,
                showsGlow: false,
                showsAmbientActivity: false,
                isDashed: false,
                lineWidthScale: 1,
                dashPattern: [],
                spinDuration: nil,
                successPulseDuration: nil
            )
        case .offline:
            return progressSpecification(
                paint: .offline,
                fraction: clampedFraction
            )
        case .success, .needsSetup, .environmentError:
            preconditionFailure("Handled before the standard progress matrix")
        }
    }

    private static func progressSpecification(
        paint: ArcPaint,
        fraction: Double
    ) -> RenewalRingVisualSpecification {
        RenewalRingVisualSpecification(
            paint: paint,
            arcFraction: fraction,
            isFullCircle: false,
            showsTrack: true,
            showsGlow: false,
            showsAmbientActivity: false,
            isDashed: false,
            lineWidthScale: 1,
            dashPattern: [],
            spinDuration: nil,
            successPulseDuration: nil
        )
    }

    private static func dashedSpecification(
        paint: ArcPaint
    ) -> RenewalRingVisualSpecification {
        RenewalRingVisualSpecification(
            paint: paint,
            arcFraction: 1,
            isFullCircle: true,
            showsTrack: false,
            showsGlow: false,
            showsAmbientActivity: false,
            isDashed: true,
            lineWidthScale: 0.8,
            dashPattern: [0.3, 1.4],
            spinDuration: nil,
            successPulseDuration: nil
        )
    }
}

private struct RenewalRingAnimationPhases {
    let activeSpin: Double
    let ambientSpin: Double
    let breathe: Double
    let success: Double

    static let reducedMotion = RenewalRingAnimationPhases(
        activeSpin: 0,
        ambientSpin: 0,
        breathe: 0.5,
        success: 1
    )
}

struct RenewalRingView: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    enum AmbientActivityStyle: Equatable {
        case inlineArc
        case twinArcOrbit
    }

    enum Tone: Equatable {
        case normal
        case neutral
        case warning
        case critical
        case success
        case offline
        case needsSetup
        case environmentError
    }

    enum Motion: Equatable {
        case none
        case checking
        case countdown
        case deploying
        case success
    }

    enum CenterGlyph: Equatable {
        case none
        case checkmark
        case pause
        case plus
        case cross
        case minus
        case exclamation
        case verticalLine
    }

    let diameter: CGFloat
    let lineWidth: CGFloat
    let tone: Tone
    let fraction: Double
    var motion: Motion = .none
    var centerGlyph: CenterGlyph = .none
    var ambientActivityStyle: AmbientActivityStyle = .inlineArc
    var isAnimationActive = true
    var elapsedOverride: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motionClock = RenewalRingMotionClock()

    private var geometry: RenewalRingGeometry {
        RenewalRingGeometry(diameter: diameter, lineWidth: lineWidth)
    }

    private var specification: RenewalRingVisualSpecification {
        RenewalRingVisualSpecification.make(
            tone: tone,
            motion: motion,
            centerGlyph: centerGlyph,
            fraction: fraction
        )
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? 0.25 : 1 / 30,
                paused: !animationShouldRun
            )
        ) { context in
            let phases = animationPhases(at: context.date)
            ringContent(phases: phases)
                .scaleEffect(successScale(progress: phases.success))
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            resetMotionClock()
        }
        .onChange(of: tone) { _, _ in
            resetMotionClock()
        }
        .onChange(of: motion) { _, _ in
            resetMotionClock()
        }
        .onChange(of: animationShouldRun) { _, isActive in
            setMotionClockActive(isActive)
        }
        .animation(fractionAnimation, value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var animationShouldRun: Bool {
        isAnimationActive
            && !reduceMotion
            && elapsedOverride == nil
            && usesTimeline
    }

    private var usesTimeline: Bool {
        specification.spinDuration != nil
            || specification.showsAmbientActivity
            || specification.successPulseDuration != nil
    }

    @ViewBuilder
    private func ringContent(
        phases: RenewalRingAnimationPhases
    ) -> some View {
        ZStack {
            if specification.showsGlow {
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
                    .scaleEffect(
                        CGFloat(0.92 + 0.13 * phases.breathe)
                    )
                    .opacity(0.35 + 0.55 * phases.breathe)
            }

            if specification.showsTrack {
                Circle()
                    .inset(by: geometry.inset)
                    .stroke(
                        ColorTokens.Border.subtle,
                        style: StrokeStyle(lineWidth: lineWidth)
                    )
            }

            if specification.isDashed {
                Circle()
                    .inset(by: geometry.inset)
                    .stroke(
                        progressStyle,
                        style: StrokeStyle(
                            lineWidth: lineWidth * specification.lineWidthScale,
                            lineCap: .round,
                            dash: specification.dashPattern.map { $0 * lineWidth }
                        )
                    )
            } else if specification.isFullCircle {
                Circle()
                    .inset(by: geometry.inset)
                    .stroke(
                        progressStyle,
                        style: StrokeStyle(
                            lineWidth: lineWidth * specification.lineWidthScale
                        )
                    )
            } else {
                Circle()
                    .inset(by: geometry.inset)
                    .trim(
                        from: 0,
                        to: CGFloat(specification.arcFraction)
                    )
                    .stroke(
                        progressStyle,
                        style: StrokeStyle(
                            lineWidth: lineWidth * specification.lineWidthScale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .rotationEffect(
                        .degrees(
                            -90
                                + (specification.spinDuration == nil
                                    ? 0
                                    : phases.activeSpin * 360)
                        )
                    )

                if specification.showsAmbientActivity,
                   ambientActivityStyle == .inlineArc {
                    Circle()
                        .inset(by: geometry.inset)
                        .trim(
                            from: 0,
                            to: RenewalRingVisualSpecification
                                .inlineActivityFraction
                        )
                        .stroke(
                            ColorTokens.Accent.renewScanner.opacity(0.85),
                            style: StrokeStyle(
                                lineWidth: lineWidth,
                                lineCap: .round
                            )
                        )
                        .rotationEffect(
                            .degrees(-90 + phases.ambientSpin * 360)
                        )
                }
            }

            glyph
        }
        .frame(width: diameter, height: diameter)
        .drawingGroup(opaque: false)
        .overlay {
            if specification.showsAmbientActivity,
               ambientActivityStyle == .twinArcOrbit {
                twinArcActivityOrbit(phase: phases.ambientSpin)
            }
        }
    }

    private func twinArcActivityOrbit(phase: Double) -> some View {
        let orbit = RenewalRingAmbientOrbitGeometry(
            mainDiameter: diameter,
            mainLineWidth: lineWidth
        )
        let rotation = -90 + phase * 360

        return ZStack {
            Circle()
                .inset(by: orbit.inset)
                .trim(
                    from: 0,
                    to: RenewalRingVisualSpecification.twinArcFraction
                )
                .stroke(
                    interfaceStyle.accentGradient,
                    style: StrokeStyle(
                        lineWidth: orbit.lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(.degrees(rotation))

            Circle()
                .inset(by: orbit.inset)
                .trim(
                    from: 0,
                    to: RenewalRingVisualSpecification.twinArcFraction
                )
                .stroke(
                    interfaceStyle.accent.opacity(
                        RenewalRingVisualSpecification
                            .twinArcSecondaryOpacity
                    ),
                    style: StrokeStyle(
                        lineWidth: orbit.lineWidth,
                        lineCap: .round
                    )
                )
                .rotationEffect(
                    .degrees(
                        rotation
                            + RenewalRingVisualSpecification
                                .twinArcPhaseOffset * 360
                    )
                )
        }
        .frame(width: orbit.diameter, height: orbit.diameter)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch centerGlyph {
        case .none:
            EmptyView()
        case .checkmark:
            Path { path in
                path.move(
                    to: CGPoint(
                        x: diameter * (46 / 132),
                        y: diameter * (68 / 132)
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: diameter * (60 / 132),
                        y: diameter * (82 / 132)
                    )
                )
                path.addLine(
                    to: CGPoint(
                        x: diameter * (88 / 132),
                        y: diameter * (50 / 132)
                    )
                )
            }
            .stroke(
                toneColor,
                style: StrokeStyle(
                    lineWidth: lineWidth * 0.9,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .pause:
            HStack(spacing: lineWidth * 0.8) {
                RoundedRectangle(
                    cornerRadius: lineWidth * 0.3,
                    style: .continuous
                )
                    .fill(toneColor)
                    .frame(
                        width: lineWidth * 0.8,
                        height: diameter * (24 / 132)
                    )
                RoundedRectangle(
                    cornerRadius: lineWidth * 0.3,
                    style: .continuous
                )
                    .fill(toneColor)
                    .frame(
                        width: lineWidth * 0.8,
                        height: diameter * (24 / 132)
                    )
            }
        case .plus:
            Text("＋")
                .font(.system(size: diameter * (40 / 132)))
                .foregroundStyle(toneColor)
        case .cross:
            Text("✕")
                .font(
                    .system(
                        size: diameter * (38 / 132),
                        weight: .bold
                    )
                )
                .foregroundStyle(toneColor)
        case .minus:
            Capsule(style: .continuous)
                .fill(toneColor)
                .frame(width: diameter * 0.28, height: lineWidth * 0.72)
        case .exclamation:
            Image(systemName: "exclamationmark")
                .font(.system(size: diameter * 0.27, weight: .bold))
                .foregroundStyle(toneColor)
        case .verticalLine:
            Capsule(style: .continuous)
                .fill(toneColor)
                .frame(width: lineWidth * 0.72, height: diameter * 0.38)
        }
    }

    private var toneColor: Color {
        switch tone {
        case .normal:
            interfaceStyle.accent
        case .neutral:
            ColorTokens.Semantic.offline
        case .warning:
            ColorTokens.Semantic.warning
        case .critical, .environmentError:
            ColorTokens.Semantic.critical
        case .success:
            ColorTokens.Semantic.success
        case .offline, .needsSetup:
            ColorTokens.Semantic.offline
        }
    }

    private var progressStyle: AnyShapeStyle {
        switch specification.paint {
        case .normalGradient, .activeGradient:
            AnyShapeStyle(interfaceStyle.accentGradient)
        case .neutral:
            AnyShapeStyle(ColorTokens.Semantic.offline)
        case .warning:
            AnyShapeStyle(ColorTokens.Semantic.warning)
        case .critical:
            AnyShapeStyle(ColorTokens.Semantic.critical)
        case .success:
            AnyShapeStyle(ColorTokens.Semantic.success)
        case .offline:
            AnyShapeStyle(ColorTokens.Semantic.offline)
        }
    }

    private var fractionAnimation: Animation? {
        reduceMotion || motion == .countdown
            ? nil
            : MotionTokens.spring
    }

    private func animationPhases(
        at date: Date
    ) -> RenewalRingAnimationPhases {
        guard !reduceMotion else { return .reducedMotion }

        let elapsed = elapsedOverride ?? motionClock.elapsed(at: date)
        let breatheCycle = normalized(
            elapsed
                / (RenewalRingVisualSpecification.glowDuration * 2)
        )
        let breatheTriangle = breatheCycle <= 0.5
            ? breatheCycle * 2
            : (1 - breatheCycle) * 2
        let easedBreathe = 0.5 - 0.5 * cos(.pi * breatheTriangle)

        return RenewalRingAnimationPhases(
            activeSpin: normalized(
                elapsed
                    / RenewalRingVisualSpecification.activeSpinDuration
            ),
            ambientSpin: normalized(
                elapsed
                    / RenewalRingVisualSpecification.ambientOrbitDuration
            ),
            breathe: easedBreathe,
            success: min(
                max(
                    elapsed
                        / RenewalRingVisualSpecification.successDuration,
                    0
                ),
                1
            )
        )
    }

    private func successScale(progress: Double) -> CGFloat {
        guard specification.successPulseDuration != nil,
              !reduceMotion else {
            return 1
        }
        if progress < 0.45 {
            return 0.88 + (0.19 * CGFloat(progress / 0.45))
        }
        return 1.07 - (0.07 * CGFloat((progress - 0.45) / 0.55))
    }

    private func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
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

    private var accessibilityLabel: String {
        switch tone {
        case .normal, .neutral:
            "续期环，状态正常"
        case .warning:
            "续期环，即将到期"
        case .critical:
            "续期环，状态异常"
        case .success:
            "续期环，本次续期成功"
        case .offline:
            "续期环，设备离线"
        case .needsSetup:
            "续期环，尚未配置"
        case .environmentError:
            "续期环，运行环境异常"
        }
    }
}

/// 菜单栏和 AppKit 菜单头共用的微缩环绘制器。
enum RenewalRingArtwork {
    static func make(
        fraction: Double,
        tone: RenewalRingView.Tone,
        diameter: CGFloat,
        lineWidth: CGFloat,
        isTemplate: Bool,
        centerText: String? = nil
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()

        let geometry = RenewalRingGeometry(
            diameter: diameter,
            lineWidth: lineWidth
        )
        let rect = NSRect(
            x: geometry.inset,
            y: geometry.inset,
            width: geometry.pathDiameter,
            height: geometry.pathDiameter
        )

        // 设计稿 M1：菜单栏离线态使用虚线整圆，不表达进度弧。
        if tone == .offline, isTemplate {
            let dashed = NSBezierPath(ovalIn: rect)
            dashed.lineWidth = lineWidth
            var dashes: [CGFloat] = [lineWidth * 1.5, lineWidth * 1.9]
            dashed.setLineDash(&dashes, count: dashes.count, phase: 0)
            NSColor.labelColor.setStroke()
            dashed.stroke()
            image.unlockFocus()
            image.isTemplate = isTemplate
            return image
        }

        let trackColor = NSColor(ColorTokens.Border.subtle)
        trackColor.setStroke()
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        track.stroke()

        let progressColor: NSColor = isTemplate
            ? .labelColor
            : nsColor(for: tone)
        progressColor.setStroke()
        let progress = NSBezierPath()
        let center = NSPoint(x: diameter / 2, y: diameter / 2)
        let radius = geometry.pathRadius
        let endAngle = 90 - (360 * min(max(fraction, 0), 1))
        progress.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: endAngle,
            clockwise: true
        )
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        if tone == .needsSetup || tone == .environmentError {
            var dashes: [CGFloat] = [lineWidth * 0.7, lineWidth * 1.6]
            progress.setLineDash(&dashes, count: dashes.count, phase: 0)
        }
        progress.stroke()

        // 设计稿 M2：菜单头微环中心绘制剩余天数数字（12pt Bold，颜色随 tone）。
        if let centerText, !centerText.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: centerTextColor(for: tone, isTemplate: isTemplate)
            ]
            let textSize = (centerText as NSString).size(withAttributes: attributes)
            let textRect = NSRect(
                x: ((diameter - textSize.width) / 2).rounded(),
                y: ((diameter - textSize.height) / 2).rounded(),
                width: textSize.width,
                height: textSize.height
            )
            (centerText as NSString).draw(in: textRect, withAttributes: attributes)
        }

        image.unlockFocus()
        image.isTemplate = isTemplate
        return image
    }

    private static func centerTextColor(
        for tone: RenewalRingView.Tone,
        isTemplate: Bool
    ) -> NSColor {
        if isTemplate {
            return .labelColor
        }
        switch tone {
        case .neutral, .offline, .needsSetup:
            return NSColor(ColorTokens.Semantic.offline)
        case .normal, .warning, .critical, .success, .environmentError:
            return .labelColor
        }
    }

    private static func nsColor(for tone: RenewalRingView.Tone) -> NSColor {
        switch tone {
        case .normal:
            NSColor(ColorTokens.Accent.renew)
        case .neutral:
            NSColor(ColorTokens.Semantic.offline)
        case .warning:
            NSColor(ColorTokens.Semantic.warning)
        case .critical, .environmentError:
            NSColor(ColorTokens.Semantic.critical)
        case .success:
            NSColor(ColorTokens.Semantic.success)
        case .offline, .needsSetup:
            NSColor(ColorTokens.Semantic.offline)
        }
    }
}
