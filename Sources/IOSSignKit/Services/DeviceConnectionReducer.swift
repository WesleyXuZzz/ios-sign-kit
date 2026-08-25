import Foundation

enum DeviceConnectionPhase: Equatable, Sendable {
    case unknown
    case online
    case confirming
    case offline
    case inconclusive
    case recoveryCandidate
}

struct DeviceConnectionState: Equatable, Sendable {
    static let initial = DeviceConnectionState()

    fileprivate(set) var phase: DeviceConnectionPhase = .unknown
    fileprivate(set) var confirmedAbsenceCount = 0
    fileprivate(set) var confirmationStartedAt: ContinuousClock.Instant?
    fileprivate(set) var latestObservation: TargetDeviceObservation?

    var matchedDevice: DeviceInfo? {
        guard case .matched(let device) = latestObservation?.evidence else {
            return nil
        }
        return device
    }

    var recoveryCandidate: TargetRecoveryCandidate? {
        latestObservation?.recoveryCandidate
    }

    var unavailableDevice: UnavailableDeviceInfo? {
        guard case .unavailable(let device) = latestObservation?.evidence else {
            return nil
        }
        return device
    }

    var diagnostics: DeviceObservationDiagnostics? {
        latestObservation?.diagnostics
    }
}

enum DeviceConnectionEvent: Equatable, Sendable {
    case observation(
        TargetDeviceObservation,
        at: ContinuousClock.Instant
    )
    case sessionStarted
    case targetChanged
    case systemWoke
}

struct DeviceConnectionTransition: Equatable, Sendable {
    let state: DeviceConnectionState
    let nextCheckAfter: Duration?
}

struct DeviceConnectionReducer: Sendable {
    let confirmationInterval: Duration
    let retryDelay: Duration
    let wakeRecheckDelay: Duration
    let requiredAbsenceCount: Int

    init(
        confirmationInterval: Duration =
            RefreshTimingPolicy.production.connectionConfirmationInterval,
        retryDelay: Duration =
            RefreshTimingPolicy.production.connectionRetryDelay,
        wakeRecheckDelay: Duration =
            RefreshTimingPolicy.production.wakeRecheckDelay,
        requiredAbsenceCount: Int =
            RefreshTimingPolicy.production.requiredAbsenceCount
    ) {
        self.confirmationInterval = max(
            confirmationInterval,
            RefreshTimingPolicy.production.connectionConfirmationInterval
        )
        self.retryDelay = max(retryDelay, .zero)
        self.wakeRecheckDelay = max(wakeRecheckDelay, .zero)
        self.requiredAbsenceCount = max(
            requiredAbsenceCount,
            RefreshTimingPolicy.production.requiredAbsenceCount
        )
    }

    func reduce(
        state: DeviceConnectionState,
        event: DeviceConnectionEvent
    ) -> DeviceConnectionTransition {
        switch event {
        case .sessionStarted, .targetChanged:
            return DeviceConnectionTransition(
                state: .initial,
                nextCheckAfter: nil
            )
        case .systemWoke:
            return DeviceConnectionTransition(
                state: .initial,
                nextCheckAfter: wakeRecheckDelay
            )
        case .observation(let observation, let observedAt):
            switch observation.evidence {
            case .matched:
                return matchedTransition(
                    from: state,
                    observation: observation
                )
            case .confirmedAbsent:
                guard observation.diagnostics.quality == .complete else {
                    return inconclusiveTransition(
                        from: state,
                        observation: observation,
                        observedAt: observedAt
                    )
                }
                return confirmedAbsenceTransition(
                    from: state,
                    observation: observation,
                    observedAt: observedAt
                )
            case .unavailable:
                return recoveryTransition(
                    from: state,
                    observation: observation
                )
            case .inconclusive:
                if observation.recoveryCandidate != nil {
                    return recoveryTransition(
                        from: state,
                        observation: observation
                    )
                }
                return inconclusiveTransition(
                    from: state,
                    observation: observation,
                    observedAt: observedAt
                )
            case .conflict:
                return conflictTransition(observation: observation)
            }
        }
    }

    private func matchedTransition(
        from state: DeviceConnectionState,
        observation: TargetDeviceObservation
    ) -> DeviceConnectionTransition {
        var nextState = state
        nextState.phase = .online
        nextState.confirmedAbsenceCount = 0
        nextState.confirmationStartedAt = nil
        nextState.latestObservation = observation
        return DeviceConnectionTransition(
            state: nextState,
            nextCheckAfter: nil
        )
    }

    private func confirmedAbsenceTransition(
        from state: DeviceConnectionState,
        observation: TargetDeviceObservation,
        observedAt: ContinuousClock.Instant
    ) -> DeviceConnectionTransition {
        var nextState = state
        if nextState.confirmationStartedAt == nil {
            nextState.confirmationStartedAt = observedAt
        }
        nextState.confirmedAbsenceCount += 1
        nextState.latestObservation = observation

        let elapsed = confirmationElapsed(
            state: nextState,
            observedAt: observedAt
        )
        if nextState.confirmedAbsenceCount >= requiredAbsenceCount,
           elapsed >= confirmationInterval {
            nextState.phase = .offline
            return DeviceConnectionTransition(
                state: nextState,
                nextCheckAfter: nil
            )
        }

        nextState.phase = .confirming
        return DeviceConnectionTransition(
            state: nextState,
            nextCheckAfter: nextConfirmationCheckAfter(
                state: nextState,
                observedAt: observedAt
            )
        )
    }

    private func inconclusiveTransition(
        from state: DeviceConnectionState,
        observation: TargetDeviceObservation,
        observedAt: ContinuousClock.Instant
    ) -> DeviceConnectionTransition {
        var nextState = state
        nextState.latestObservation = observation
        if nextState.confirmedAbsenceCount > 0 {
            nextState.phase = .confirming
        } else if nextState.phase != .offline {
            nextState.phase = .inconclusive
        }
        return DeviceConnectionTransition(
            state: nextState,
            nextCheckAfter: nextConfirmationCheckAfter(
                state: nextState,
                observedAt: observedAt
            )
        )
    }

    private func recoveryTransition(
        from state: DeviceConnectionState,
        observation: TargetDeviceObservation
    ) -> DeviceConnectionTransition {
        var nextState = state
        nextState.phase = observation.recoveryCandidate == nil
            ? .offline
            : .recoveryCandidate
        nextState.confirmedAbsenceCount = 0
        nextState.confirmationStartedAt = nil
        nextState.latestObservation = observation
        return DeviceConnectionTransition(
            state: nextState,
            nextCheckAfter: nil
        )
    }

    private func conflictTransition(
        observation: TargetDeviceObservation
    ) -> DeviceConnectionTransition {
        var nextState = DeviceConnectionState.initial
        nextState.phase = .inconclusive
        nextState.latestObservation = observation
        return DeviceConnectionTransition(
            state: nextState,
            nextCheckAfter: retryDelay
        )
    }

    private func confirmationElapsed(
        state: DeviceConnectionState,
        observedAt: ContinuousClock.Instant
    ) -> Duration {
        guard let startedAt = state.confirmationStartedAt else {
            return .zero
        }
        return max(startedAt.duration(to: observedAt), .zero)
    }

    private func nextConfirmationCheckAfter(
        state: DeviceConnectionState,
        observedAt: ContinuousClock.Instant
    ) -> Duration {
        let elapsed = confirmationElapsed(
            state: state,
            observedAt: observedAt
        )
        let remaining = max(confirmationInterval - elapsed, .zero)

        if state.confirmedAbsenceCount >= requiredAbsenceCount,
           remaining > .zero {
            return remaining
        }
        if remaining > .zero {
            return min(retryDelay, remaining)
        }
        return retryDelay
    }
}
