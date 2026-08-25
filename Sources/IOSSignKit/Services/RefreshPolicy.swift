import Foundation

enum RefreshWork: Equatable, Sendable {
    case heartbeatOnly
    case verifyAppThenEvaluate
    case fullInteractiveCheck
}

enum RefreshRequestKind: Equatable, Sendable {
    case background
    case recovery
    case manual
}

struct RefreshPolicyContext: Equatable, Sendable {
    let requestKind: RefreshRequestKind
    let hasFreshXcodeValidation: Bool
    let hasFreshInstalledAppEvidence: Bool
    let criticalActionCandidates: Set<CriticalRefreshAction>

    init(
        requestKind: RefreshRequestKind,
        hasFreshXcodeValidation: Bool,
        hasFreshInstalledAppEvidence: Bool,
        criticalActionCandidates: Set<CriticalRefreshAction> = []
    ) {
        self.requestKind = requestKind
        self.hasFreshXcodeValidation = hasFreshXcodeValidation
        self.hasFreshInstalledAppEvidence = hasFreshInstalledAppEvidence
        self.criticalActionCandidates = criticalActionCandidates
    }
}

enum CriticalRefreshAction: CaseIterable, Hashable, Sendable {
    case reminder
    case wirelessPairing
    case automaticRefreshCountdown
    case deployment
}

struct RefreshPolicy: Sendable {
    func work(for context: RefreshPolicyContext) -> RefreshWork {
        if context.requestKind == .manual
            || context.criticalActionCandidates.contains(.deployment) {
            return .fullInteractiveCheck
        } else if context.requestKind == .recovery {
            return .verifyAppThenEvaluate
        } else if !context.criticalActionCandidates.isEmpty {
            return .verifyAppThenEvaluate
        } else if !context.hasFreshXcodeValidation
                    || !context.hasFreshInstalledAppEvidence {
            return .verifyAppThenEvaluate
        } else {
            return .heartbeatOnly
        }
    }
}
