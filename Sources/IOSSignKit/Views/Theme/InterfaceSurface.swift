import AppKit
import SwiftUI

/// Shared surfaces keep both styles on the same layout and semantic state model.
struct InterfaceCanvas: View {
    @Environment(\.interfaceStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if style.usesTransparency(reduceTransparency: reduceTransparency) {
                WindowGlassBackground()
            } else if style == .glass {
                Color(nsColor: .windowBackgroundColor)
            } else {
                ColorTokens.BG.canvas
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The system composites the background directly; no custom tint or wallpaper sampling.
private struct WindowGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct InterfaceSurface: ViewModifier {
    var emphasized = false
    @Environment(\.interfaceStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
        content
            .background {
                if style.usesTransparency(reduceTransparency: reduceTransparency) {
                    shape.fill(.ultraThinMaterial)
                } else {
                    shape.fill(
                        style == .glass
                            ? Color(nsColor: .windowBackgroundColor)
                            : emphasized ? ColorTokens.BG.surfaceEmphasis : ColorTokens.BG.surface)
                }
            }
            .overlay {
                shape.strokeBorder(
                    style == .glass ? ColorTokens.Glass.border : ColorTokens.Border.subtle,
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(style == .glass ? (colorScheme == .dark ? 0.22 : 0.07) : 0),
                radius: style == .glass ? 16 : 0, x: 0, y: style == .glass ? 8 : 0
            )
    }
}

extension View {
    func interfaceSurface(emphasized: Bool = false) -> some View {
        modifier(InterfaceSurface(emphasized: emphasized))
    }
}
