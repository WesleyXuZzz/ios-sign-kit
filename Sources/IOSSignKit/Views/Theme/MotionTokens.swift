import AppKit
import SwiftUI

enum MotionTokens {
    static let fast: Double = 0.15
    static let medium: Double = 0.24

    static func easeOut(_ duration: Double = medium) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Only pointer interactions opt into motion; keyboard and accessibility actions stay immediate.
    @MainActor
    static func interactionAnimation(
        reduceMotion: Bool,
        duration: Double = fast
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        return isPointerInteraction(NSApp?.currentEvent?.type) ? easeOut(duration) : nil
    }

    static func isPointerInteraction(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return true
        default:
            return false
        }
    }

    static let spring = Animation.spring(
        response: 0.45,
        dampingFraction: 0.86
    )
}
