import AppKit
import SwiftUI

enum StatusTone: Equatable {
    case good
    case warning
    case critical
    case info
    case neutral

    var color: Color {
        switch self {
        case .good:
            ColorTokens.Semantic.success
        case .warning:
            ColorTokens.Semantic.warning
        case .critical:
            ColorTokens.Semantic.critical
        case .info:
            ColorTokens.Accent.renew
        case .neutral:
            ColorTokens.Semantic.offline
        }
    }
}

/// Renewal Loop 的颜色系统。所有新视图只通过这里读取颜色，避免同一语义在不同组件中漂移。
enum ColorTokens {
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark
                : light
        })
    }

    private static func rgb(
        _ red: Double,
        _ green: Double,
        _ blue: Double,
        _ alpha: Double = 1
    ) -> NSColor {
        NSColor(
            srgbRed: red / 255,
            green: green / 255,
            blue: blue / 255,
            alpha: alpha
        )
    }

    enum BG {
        static let canvas = ColorTokens.dynamic(
            light: ColorTokens.rgb(245, 246, 248),
            dark: ColorTokens.rgb(22, 24, 29)
        )
        static let surface = ColorTokens.dynamic(
            light: ColorTokens.rgb(255, 255, 255),
            dark: ColorTokens.rgb(31, 34, 40)
        )
        static let surfaceEmphasis = ColorTokens.dynamic(
            light: ColorTokens.rgb(239, 241, 245),
            dark: ColorTokens.rgb(38, 42, 50)
        )
    }

    enum Border {
        static let subtle = ColorTokens.dynamic(
            light: ColorTokens.rgb(0, 0, 0, 0.07),
            dark: ColorTokens.rgb(255, 255, 255, 0.10)
        )
        static let strong = ColorTokens.dynamic(
            light: ColorTokens.rgb(0, 0, 0, 0.14),
            dark: ColorTokens.rgb(255, 255, 255, 0.18)
        )
    }

    enum Text {
        static let primary = ColorTokens.dynamic(
            light: ColorTokens.rgb(29, 29, 31),
            dark: ColorTokens.rgb(245, 245, 247)
        )
        static let secondary = ColorTokens.dynamic(
            light: ColorTokens.rgb(110, 110, 115),
            dark: ColorTokens.rgb(152, 152, 157)
        )
        static let tertiary = ColorTokens.dynamic(
            light: ColorTokens.rgb(174, 174, 178),
            dark: ColorTokens.rgb(99, 99, 102)
        )
    }

    enum Accent {
        static let renew = ColorTokens.dynamic(
            light: ColorTokens.rgb(10, 132, 255),
            dark: ColorTokens.rgb(76, 157, 255)
        )
        static let renewStart = renew
        static let renewEnd = ColorTokens.dynamic(
            light: ColorTokens.rgb(100, 210, 255),
            dark: ColorTokens.rgb(111, 216, 232)
        )
        static let renewScanner = Color(
            nsColor: ColorTokens.rgb(100, 210, 255)
        )
        static let renewGlow = Color(
            nsColor: ColorTokens.rgb(10, 132, 255)
        )

        static var renewGradient: LinearGradient {
            LinearGradient(
                colors: [renewStart, renewEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    enum Semantic {
        static let success = ColorTokens.dynamic(
            light: ColorTokens.rgb(52, 199, 89),
            dark: ColorTokens.rgb(48, 209, 88)
        )
        static let warning = ColorTokens.dynamic(
            light: ColorTokens.rgb(255, 149, 0),
            dark: ColorTokens.rgb(255, 159, 10)
        )
        static let critical = ColorTokens.dynamic(
            light: ColorTokens.rgb(255, 59, 48),
            dark: ColorTokens.rgb(255, 69, 58)
        )
        static let offline = ColorTokens.dynamic(
            light: ColorTokens.rgb(142, 142, 147),
            dark: ColorTokens.rgb(152, 152, 157)
        )
        static let warningText = ColorTokens.dynamic(
            light: ColorTokens.rgb(178, 94, 0),
            dark: ColorTokens.rgb(255, 159, 10)
        )
        static let criticalText = ColorTokens.dynamic(
            light: ColorTokens.rgb(193, 39, 31),
            dark: ColorTokens.rgb(255, 69, 58)
        )
        static let successText = ColorTokens.dynamic(
            light: ColorTokens.rgb(31, 138, 61),
            dark: ColorTokens.rgb(48, 209, 88)
        )
    }

    enum Log {
        static let background = ColorTokens.dynamic(
            light: ColorTokens.rgb(16, 18, 22),
            dark: ColorTokens.rgb(11, 13, 16)
        )
        static let text = ColorTokens.dynamic(
            light: ColorTokens.rgb(123, 227, 139),
            dark: ColorTokens.rgb(123, 227, 139)
        )
        static let border = ColorTokens.dynamic(
            light: ColorTokens.rgb(255, 255, 255, 0.08),
            dark: ColorTokens.rgb(255, 255, 255, 0.07)
        )
    }
}
