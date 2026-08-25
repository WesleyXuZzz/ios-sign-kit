import Foundation

enum PersonalSigningValidity {
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    static func expiryDate(after installationDate: Date) -> Date {
        installationDate.addingTimeInterval(duration)
    }
}
