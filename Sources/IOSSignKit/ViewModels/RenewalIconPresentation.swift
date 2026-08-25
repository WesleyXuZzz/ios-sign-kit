import Foundation

enum RenewalIconVisualState: Equatable {
    case normal
    case healthy
    case warning
    case critical
    case offline
}

enum RenewalIconMotion: Equatable {
    case idle
    case checking
    case countdown(fraction: Double)
    case recovering
    case deploying
    case success
    case attention
    case paused
}

struct RenewalIconPresentation: Equatable {
    let visualState: RenewalIconVisualState
    let motion: RenewalIconMotion

    static func make(
        phase: PrimaryJourneyPhase,
        headerTone: StatusTone,
        deviceTone: StatusTone,
        expiryUrgency: RemainingExpiryUrgency,
        isExpired: Bool,
        progress: OperationActivityProgress?
    ) -> RenewalIconPresentation {
        switch phase {
        case .completed:
            return RenewalIconPresentation(
                visualState: .healthy,
                motion: .success
            )
        case .countdown:
            return RenewalIconPresentation(
                visualState: .warning,
                motion: .countdown(
                    fraction: countdownFraction(from: progress)
                )
            )
        case .needsSetup:
            return RenewalIconPresentation(
                visualState: .warning,
                motion: .idle
            )
        case .recovering:
            return RenewalIconPresentation(
                visualState: .warning,
                motion: .recovering
            )
        case .blocked:
            return RenewalIconPresentation(
                visualState: .critical,
                motion: .paused
            )
        case .attention:
            return RenewalIconPresentation(
                visualState: headerTone == .critical
                    ? .critical
                    : .warning,
                motion: .attention
            )
        case .waitingForDevice, .monitoring, .renewalRequired,
             .checking, .deploying:
            break
        }

        let visualState = baseVisualState(
            deviceTone: deviceTone,
            expiryUrgency: expiryUrgency,
            isExpired: isExpired
        )
        let motion: RenewalIconMotion
        switch phase {
        case .waitingForDevice:
            motion = .paused
        case .monitoring:
            motion = .idle
        case .renewalRequired:
            motion = .attention
        case .checking:
            motion = .checking
        case .deploying:
            motion = .deploying
        case .needsSetup, .countdown, .recovering, .completed,
             .attention, .blocked:
            motion = .idle
        }

        return RenewalIconPresentation(
            visualState: visualState,
            motion: motion
        )
    }

    private static func baseVisualState(
        deviceTone: StatusTone,
        expiryUrgency: RemainingExpiryUrgency,
        isExpired: Bool
    ) -> RenewalIconVisualState {
        guard deviceTone == .good else {
            return .offline
        }
        if isExpired {
            return .critical
        }
        switch expiryUrgency {
        case .warning, .critical:
            return .warning
        case .unknown, .healthy:
            return .normal
        }
    }

    private static func countdownFraction(
        from progress: OperationActivityProgress?
    ) -> Double {
        guard case .fraction(let value) = progress else {
            return 1
        }
        return min(max(value, 0), 1)
    }
}
