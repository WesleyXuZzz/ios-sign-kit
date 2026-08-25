import Foundation

struct ReminderDecision: Equatable {
    var shouldPrompt: Bool
    var reason: String
    var nextEligibleAt: Date?
}
