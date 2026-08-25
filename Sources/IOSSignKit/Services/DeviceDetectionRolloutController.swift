enum DeviceDetectionRolloutMode: Equatable, Sendable {
    case fallback
    case shadow
    case readOnly
    case production
}

enum DeviceDetectionEngine: Equatable, Sendable {
    case compatibility
    case canonical
}

enum DeviceDetectionEngineComparison: Equatable, Sendable {
    case pure(DeviceDetectionEngine)
}

struct DeviceDetectionDecision: Equatable, Sendable {
    let primaryEngine: DeviceDetectionEngine
    let comparison: DeviceDetectionEngineComparison?
    let allowsCriticalActions: Bool
}

struct DeviceDetectionRolloutState: Equatable, Sendable {
    let mode: DeviceDetectionRolloutMode
    let generation: UInt64
}

struct DeviceDetectionRolloutTransition: Equatable, Sendable {
    let nextState: DeviceDetectionRolloutState
    let invalidatesSessionCaches: Bool
    let resetsConnectionState: Bool
    let discardsOlderPassiveResults: Bool
    let preservesActiveDeployment: Bool
    let deferredMode: DeviceDetectionRolloutMode?
}

struct DeviceDetectionRolloutController: Sendable {
    func decision(
        for mode: DeviceDetectionRolloutMode
    ) -> DeviceDetectionDecision {
        switch mode {
        case .fallback:
            return DeviceDetectionDecision(
                primaryEngine: .compatibility,
                comparison: nil,
                allowsCriticalActions: true
            )
        case .shadow:
            return DeviceDetectionDecision(
                primaryEngine: .compatibility,
                comparison: .pure(.canonical),
                allowsCriticalActions: true
            )
        case .readOnly:
            return DeviceDetectionDecision(
                primaryEngine: .canonical,
                comparison: .pure(.compatibility),
                allowsCriticalActions: false
            )
        case .production:
            return DeviceDetectionDecision(
                primaryEngine: .canonical,
                comparison: nil,
                allowsCriticalActions: true
            )
        }
    }

    func transition(
        from state: DeviceDetectionRolloutState,
        to requestedMode: DeviceDetectionRolloutMode,
        hasActiveDeployment: Bool
    ) -> DeviceDetectionRolloutTransition {
        guard requestedMode != state.mode else {
            return DeviceDetectionRolloutTransition(
                nextState: state,
                invalidatesSessionCaches: false,
                resetsConnectionState: false,
                discardsOlderPassiveResults: false,
                preservesActiveDeployment: true,
                deferredMode: nil
            )
        }
        guard !hasActiveDeployment else {
            return DeviceDetectionRolloutTransition(
                nextState: state,
                invalidatesSessionCaches: false,
                resetsConnectionState: false,
                discardsOlderPassiveResults: false,
                preservesActiveDeployment: true,
                deferredMode: requestedMode
            )
        }

        return DeviceDetectionRolloutTransition(
            nextState: DeviceDetectionRolloutState(
                mode: requestedMode,
                generation: state.generation + 1
            ),
            invalidatesSessionCaches: true,
            resetsConnectionState: true,
            discardsOlderPassiveResults: true,
            preservesActiveDeployment: true,
            deferredMode: nil
        )
    }
}
