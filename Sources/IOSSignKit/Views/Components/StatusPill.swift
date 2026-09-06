import SwiftUI

struct StatusPill: View {
    let text: String
    let tone: StatusTone
    var showsDot = true

    var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                Circle()
                    .fill(tone.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(TypeTokens.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(
            Capsule(style: .continuous)
                .fill(tone.color.opacity(0.14))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SpacingTokens.sm) {
            HStack(spacing: SpacingTokens.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ColorTokens.Accent.renew)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                Text(title)
                    .font(TypeTokens.cardTitle)
                    .foregroundStyle(ColorTokens.Text.primary)

                Spacer(minLength: 0)
            }

            content
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SpacingTokens.md)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .interfaceSurface()
    }
}

struct RenewalButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case text
        case destructive
    }

    let kind: Kind
    var height: CGFloat = SpacingTokens.ControlHeight.secondary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.interfaceStyle) private var interfaceStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(
                TypeTokens.body.weight(
                    kind == .text ? .medium : .semibold
                )
            )
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .text ? 4 : 12)
            .frame(minHeight: height)
            .background(background)
            .overlay(border)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: interfaceStyle.controlRadius,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: interfaceStyle.controlRadius,
                    style: .continuous
                )
            )
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(
                reduceMotion ? nil : .easeOut(duration: MotionTokens.fast),
                value: configuration.isPressed
            )
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            .white
        case .secondary:
            ColorTokens.Text.primary
        case .text:
            ColorTokens.Accent.renew
        case .destructive:
            .white
        }
    }

    private var background: some View {
        Group {
            switch kind {
            case .primary:
                if interfaceStyle == .glass {
                    ColorTokens.Glass.accentGradient
                } else {
                    ColorTokens.Accent.renew
                }
            case .secondary:
                if interfaceStyle.usesTransparency(reduceTransparency: reduceTransparency) {
                    Rectangle().fill(.regularMaterial)
                } else {
                    ColorTokens.BG.surface
                }
            case .text:
                Color.clear
            case .destructive:
                ColorTokens.Semantic.critical
            }
        }
    }

    private var border: some View {
        Group {
            switch kind {
            case .primary, .text, .destructive:
                Color.clear
            case .secondary:
                RoundedRectangle(
                    cornerRadius: interfaceStyle.controlRadius,
                    style: .continuous
                )
                .strokeBorder(ColorTokens.Border.strong, lineWidth: 1)
            }
        }
    }
}
