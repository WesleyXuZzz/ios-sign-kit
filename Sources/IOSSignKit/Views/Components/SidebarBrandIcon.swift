import SwiftUI

/// 可缩放的 Renewal Loop 品牌标记，主命令栏以 30pt 展示。
struct SidebarBrandIcon: View {
    enum Layout {
        static let defaultSize: CGFloat = 64
        /// 30pt 图标的最快轨道周期约 0.9 秒，30 fps 足够平滑且减半重绘开销。
        static let preferredFrameRate = 30.0
    }

    let presentation: RenewalIconPresentation
    let statusDescription: String
    let isAnimationActive: Bool
    var size: CGFloat = Layout.defaultSize

    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @State private var motionState: RenewalIconMotionState

    init(
        presentation: RenewalIconPresentation,
        statusDescription: String,
        isAnimationActive: Bool,
        size: CGFloat = Layout.defaultSize
    ) {
        self.presentation = presentation
        self.statusDescription = statusDescription
        self.isAnimationActive = isAnimationActive
        self.size = size
        _motionState = State(
            initialValue: RenewalIconMotionState(
                profile: RenewalIconMotionProfile.make(
                    presentation: presentation
                )
            )
        )
    }

    var body: some View {
        let profile = RenewalIconMotionProfile.make(
            presentation: presentation
        )
        let shouldAnimate = isAnimationActive && !accessibilityReduceMotion
            && (profile.orbitDuration > 0 || profile.pulseDuration > 0)

        TimelineView(
            .animation(
                minimumInterval: 1 / Layout.preferredFrameRate,
                paused: !shouldAnimate
            )
        ) { context in
            SidebarBrandMark(
                phases: motionState.phases(at: context.date).rendered(
                    reducesMotion: accessibilityReduceMotion
                ),
                profile: profile,
                size: size
            )
        }
        .frame(width: size, height: size)
        .onChange(of: profile) { _, newProfile in
            motionState.transition(to: newProfile, at: Date())
        }
        .onChange(of: shouldAnimate) { wasActive, isActive in
            let now = Date()
            if isActive {
                motionState.resume(at: now)
            } else if wasActive {
                motionState.pause(at: now)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("iOS 个人签名续期工具")
        .accessibilityValue(statusDescription)
    }
}

private struct SidebarBrandMark: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    let phases: RenewalIconMotionPhases
    let profile: RenewalIconMotionProfile
    let size: CGFloat

    private let ringFraction: CGFloat = 130 / 164

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringFraction)
                .stroke(
                    interfaceStyle.accentGradient,
                    style: StrokeStyle(
                        lineWidth: size * 5 / 64,
                        lineCap: .round
                    )
                )
                .rotationEffect(
                    .degrees(-90 + (phases.orbit * 360))
                )
                .frame(
                    width: size * 52 / 64,
                    height: size * 52 / 64
                )

            RoundedRectangle(
                cornerRadius: size * 4 / 64,
                style: .continuous
            )
            .stroke(
                interfaceStyle.accentGradient,
                lineWidth: size * 3 / 64
            )
            .frame(
                width: size * 16 / 64,
                height: size * 28 / 64
            )

            SidebarBrandBolt(
                size: size,
                phase: phases.pulse,
                pulseScale: profile.boltPulseScale
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SidebarBrandBolt: View {
    @Environment(\.interfaceStyle) private var interfaceStyle
    let size: CGFloat
    let phase: Double
    let pulseScale: CGFloat

    var body: some View {
        Path { path in
            let scale = size / 64
            path.move(to: CGPoint(x: 33 * scale, y: 24 * scale))
            path.addLine(to: CGPoint(x: 29 * scale, y: 32 * scale))
            path.addLine(to: CGPoint(x: 33 * scale, y: 32 * scale))
            path.addLine(to: CGPoint(x: 31 * scale, y: 40 * scale))
            path.addLine(to: CGPoint(x: 37 * scale, y: 30 * scale))
            path.addLine(to: CGPoint(x: 33 * scale, y: 30 * scale))
            path.closeSubpath()
        }
        .fill(interfaceStyle.accentGradient)
        .scaleEffect(
            1 + (pulseScale * (0.5 + (0.5 * sin(phase * 2 * .pi))))
        )
    }
}
