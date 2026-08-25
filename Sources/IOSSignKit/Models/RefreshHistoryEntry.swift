import Foundation

enum RefreshHistoryOutcome: Equatable, Sendable {
    case success
    case failure
    case cancelled
    case interrupted
    case unknown
}

enum RefreshHistoryTrigger: String, Equatable, Sendable {
    case manual
    case automatic
}

struct RefreshHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let startedAt: Date?
    let outcome: RefreshHistoryOutcome
    let trigger: RefreshHistoryTrigger?
    let failureReason: DeployFailureReason?
    let summary: String
    let detailSummary: String?
    let logExcerpt: String?
    let logPath: String
    let rawFilename: String

    init(
        id: String,
        startedAt: Date?,
        outcome: RefreshHistoryOutcome,
        trigger: RefreshHistoryTrigger? = nil,
        failureReason: DeployFailureReason? = nil,
        summary: String,
        detailSummary: String?,
        logExcerpt: String?,
        logPath: String,
        rawFilename: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.outcome = outcome
        self.trigger = trigger
        self.failureReason = failureReason
        self.summary = summary
        self.detailSummary = detailSummary
        self.logExcerpt = logExcerpt
        self.logPath = logPath
        self.rawFilename = rawFilename
    }

    var isSuccess: Bool? {
        switch outcome {
        case .success:
            true
        case .failure:
            false
        case .cancelled, .interrupted, .unknown:
            nil
        }
    }

    var isCancelled: Bool {
        outcome == .cancelled
    }
}
