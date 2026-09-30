import Foundation

/// Tolerances that let macOS coalesce the app's long-lived timers with other
/// wake-ups instead of waking the CPU at an exact instant.
///
/// A timer without tolerance forces a dedicated wake-up; Apple recommends at
/// least 10% of the interval for repeating work. The caps keep user-visible
/// timing (the next background check, the remaining-time label) within a
/// bound nobody would notice.
enum TimerCoalescingPolicy {
    /// Upper bound for how late a background device check may fire.
    static let maximumPollingTolerance: TimeInterval = 60
    /// Upper bound for how late the remaining-time label may update.
    static let maximumExpiryLabelTolerance: TimeInterval = 2
    /// Tolerance for the per-second countdown in the final minute.
    static let secondsCountdownTolerance: TimeInterval = 0.05

    static func pollingTolerance(for interval: TimeInterval) -> TimeInterval {
        guard interval > 0 else {
            return 0
        }
        return min(interval / 10, maximumPollingTolerance)
    }

    static func expiryLabelTolerance(
        for interval: TimeInterval
    ) -> TimeInterval {
        guard interval > 0 else {
            return 0
        }
        if interval <= 1 {
            return secondsCountdownTolerance
        }
        return min(interval / 10, maximumExpiryLabelTolerance)
    }
}
