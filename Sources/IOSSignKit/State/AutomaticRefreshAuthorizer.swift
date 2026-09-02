import Foundation

struct AutomaticRefreshAuthorizer: Sendable {
    struct Context: Sendable {
        let externallySuppressesActions: Bool
        let allowsCriticalActions: Bool
        let usedCachedActionEvidence: Bool
        let hasAvailabilityConflict: Bool
        let hasDegradedTargetObservation: Bool
        let hasInstallationBlocker: Bool
        let hasExactStableTargetMatch: Bool
        let hasFreshVerifiedInstalledApp: Bool
    }

    enum Disposition: Equatable, Sendable {
        case proceed(Basis)
        case `defer`(DeferralReason)
        case block(BlockReason)

        var allowsAutomaticRefreshEvaluation: Bool {
            if case .proceed = self {
                return true
            }
            return false
        }
    }

    enum Basis: Equatable, Sendable {
        case completeObservation
        case freshVerifiedAppOnExactDevice
    }

    enum DeferralReason: Equatable, Sendable {
        case passiveObservation
        case cachedActionEvidence
        case installationEvidenceUnavailable
        case degradedDeviceEvidence
    }

    enum BlockReason: Equatable, Sendable {
        case criticalActionsDisabled
        case deviceEvidenceConflict
    }

    func evaluate(_ context: Context) -> Disposition {
        guard context.allowsCriticalActions else {
            return .block(.criticalActionsDisabled)
        }
        guard !context.hasAvailabilityConflict else {
            return .block(.deviceEvidenceConflict)
        }
        guard !context.externallySuppressesActions else {
            return .defer(.passiveObservation)
        }
        guard !context.usedCachedActionEvidence else {
            return .defer(.cachedActionEvidence)
        }
        guard !context.hasInstallationBlocker else {
            return .defer(.installationEvidenceUnavailable)
        }
        guard context.hasDegradedTargetObservation else {
            return .proceed(.completeObservation)
        }
        guard context.hasExactStableTargetMatch,
              context.hasFreshVerifiedInstalledApp else {
            return .defer(.degradedDeviceEvidence)
        }
        return .proceed(.freshVerifiedAppOnExactDevice)
    }
}
