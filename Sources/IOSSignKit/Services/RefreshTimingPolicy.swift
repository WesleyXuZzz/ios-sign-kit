import Foundation

struct RefreshTimingPolicy: Equatable, Sendable {
    static let production = RefreshTimingPolicy(
        automaticRefreshCountdownSeconds: 5,
        installedAppRetryDelays: [5, 30, 120, 600],
        postDeployInspectionTimeout: 30,
        automaticRecoveryDelay: 10,
        automaticRecoveryFailureBackoff: 10 * 60,
        wirelessPairingCooldown: 30 * 60,
        xcodeValidationCacheTTL: .seconds(30 * 60),
        installedAppCacheTTL: .seconds(10 * 60),
        connectionConfirmationInterval: .seconds(30),
        connectionRetryDelay: .seconds(5),
        wakeRecheckDelay: .seconds(5),
        automaticWaitPolicy: AutomaticRefreshWaitPolicy(
            lockedProbeInterval: .seconds(30),
            unknownProbeInterval: .seconds(60),
            destinationProbeInterval: .seconds(120),
            prolongedProbeInterval: .seconds(300),
            rapidProbeWindow: .seconds(2 * 60 * 60),
            wakeFirstProbeDelay: .seconds(5),
            wakeSecondProbeDelay: .seconds(20)
        ),
        requiredAbsenceCount: 2
    )

    let automaticRefreshCountdownSeconds: Int
    let installedAppRetryDelays: [TimeInterval]
    let postDeployInspectionTimeout: TimeInterval
    let automaticRecoveryDelay: TimeInterval
    let automaticRecoveryFailureBackoff: TimeInterval
    let wirelessPairingCooldown: TimeInterval
    let xcodeValidationCacheTTL: Duration
    let installedAppCacheTTL: Duration
    let connectionConfirmationInterval: Duration
    let connectionRetryDelay: Duration
    let wakeRecheckDelay: Duration
    let automaticWaitPolicy: AutomaticRefreshWaitPolicy
    let requiredAbsenceCount: Int
}
