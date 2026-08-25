import Foundation

enum AppConfigConstraints {
    static let defaultCheckIntervalMinutes = 5
    static let checkIntervalRange = 1...60
    static let defaultExpiredCheckIntervalMinutes = 1
    static let expiredCheckIntervalRange = 1...60
    static let defaultReminderCooldownHours = 24
    static let reminderCooldownRange = 1...72

    static func normalizeCheckInterval(_ value: Int) -> Int {
        min(
            max(value, checkIntervalRange.lowerBound),
            checkIntervalRange.upperBound
        )
    }

    static func normalizeExpiredCheckInterval(_ value: Int) -> Int {
        min(
            max(value, expiredCheckIntervalRange.lowerBound),
            expiredCheckIntervalRange.upperBound
        )
    }

    static func normalizeReminderCooldown(_ value: Int) -> Int {
        min(
            max(value, reminderCooldownRange.lowerBound),
            reminderCooldownRange.upperBound
        )
    }
}
