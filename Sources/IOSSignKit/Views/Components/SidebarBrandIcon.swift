import SwiftUI

/// 侧栏品牌标记：透明底的 Renewal Loop，与设计稿中的 64pt 品牌区保持一致。
struct SidebarBrandIcon: View {
    enum Layout {
        static let defaultSize: CGFloat = 64
        static let preferredFrameRate = 60.0
        static let reducedMotionFrameRate = 4.0
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
        let frameRate = accessibilityReduceMotion
            ? Layout.reducedMotionFrameRate
            : Layout.preferredFrameRate

        TimelineView(
            .animation(
                minimumInterval: 1 / frameRate,
                paused: !isAnimationActive
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
        .onChange(of: isAnimationActive) { wasActive, isActive in
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
    let phases: RenewalIconMotionPhases
    let profile: RenewalIconMotionProfile
    let size: CGFloat

    private let ringFraction: CGFloat = 130 / 164

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: ringFraction)
                .stroke(
                    ColorTokens.Accent.renewGradient,
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
                ColorTokens.Accent.renewGradient,
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
        .fill(ColorTokens.Accent.renewGradient)
        .scaleEffect(
            1 + (pulseScale * (0.5 + (0.5 * sin(phase * 2 * .pi))))
        )
    }
}
