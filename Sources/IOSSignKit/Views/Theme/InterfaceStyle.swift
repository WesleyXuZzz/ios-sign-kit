import SwiftUI

/// An application preference, independent of deployment configuration drafts.
enum InterfaceStyle: String, CaseIterable, Identifiable, Sendable {
    case native
    case glass

    static let preferenceKey = "interfaceStyle"
    var id: String { rawValue }

    init(storedValue: String) {
        self = Self(rawValue: storedValue) ?? .native
    }

    var title: String {
        switch self {
        case .native: "现代 macOS 原生"
        case .glass: "轻盈玻璃拟态"
        }
    }

    var detail: String {
        switch self {
        case .native: "清晰表面、细边框与克制的层次"
        case .glass: "半透明材质、细边框与浮起的卡片"
        }
    }

    var accent: Color { self == .glass ? ColorTokens.Glass.accent : ColorTokens.Accent.renew }
    var accentGradient: LinearGradient {
        self == .glass ? ColorTokens.Glass.accentGradient : ColorTokens.Accent.renewGradient
    }

    var cardRadius: CGFloat { self == .glass ? 18 : 12 }
    var controlRadius: CGFloat { self == .glass ? 10 : 8 }

    func usesTransparency(reduceTransparency: Bool) -> Bool {
        self == .glass && !reduceTransparency
    }
}

private struct InterfaceStyleKey: EnvironmentKey {
    static let defaultValue = InterfaceStyle.native
}

extension EnvironmentValues {
    var interfaceStyle: InterfaceStyle {
        get { self[InterfaceStyleKey.self] }
        set { self[InterfaceStyleKey.self] = newValue }
    }
}
