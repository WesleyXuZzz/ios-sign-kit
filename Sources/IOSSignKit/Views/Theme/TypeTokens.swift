import SwiftUI

enum TypeTokens {
    static let heroMetric = Font
        .system(size: 56, weight: .bold, design: .rounded)
        .monospacedDigit()
    static let heroMetricCompact = Font
        .system(size: 26, weight: .bold, design: .rounded)
        .monospacedDigit()
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let auxiliary = Font.system(size: 11)
    static let controlLabel = Font.system(size: 11)
    static let controlLabelEmphasized = Font.system(
        size: 11,
        weight: .semibold
    )
    static let mono = Font.system(size: 11, design: .monospaced)
    static let controlIcon = Font.system(size: 18)
    static let optionIcon = Font.system(size: 15, weight: .medium)
    static let deviceIcon = Font.system(size: 18)
}
