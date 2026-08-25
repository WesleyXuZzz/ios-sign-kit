import SwiftUI

enum MotionTokens {
    static let fast: Double = 0.15
    static let medium: Double = 0.24

    static func easeOut(_ duration: Double = medium) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    static let spring = Animation.spring(
        response: 0.45,
        dampingFraction: 0.86
    )
}
