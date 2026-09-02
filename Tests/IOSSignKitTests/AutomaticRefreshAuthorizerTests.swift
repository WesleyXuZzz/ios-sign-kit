import Testing
@testable import IOSSignKit

struct AutomaticRefreshAuthorizerTests {
    @Test
    func degradedObservationProceedsOnlyWithFreshExactAppEvidence() {
        let disposition = AutomaticRefreshAuthorizer().evaluate(
            context(
                hasDegradedTargetObservation: true,
                hasExactStableTargetMatch: true,
                hasFreshVerifiedInstalledApp: true
            )
        )

        #expect(
            disposition
                == .proceed(.freshVerifiedAppOnExactDevice)
        )
    }

    @Test
    func degradedObservationWithoutFreshExactAppEvidenceDefers() {
        let disposition = AutomaticRefreshAuthorizer().evaluate(
            context(
                hasDegradedTargetObservation: true,
                hasExactStableTargetMatch: true,
                hasFreshVerifiedInstalledApp: false
            )
        )

        #expect(disposition == .defer(.degradedDeviceEvidence))
    }

    @Test
    func deviceEvidenceConflictBlocksEvenWithFreshExactAppEvidence() {
        let disposition = AutomaticRefreshAuthorizer().evaluate(
            context(
                hasAvailabilityConflict: true,
                hasDegradedTargetObservation: true,
                hasExactStableTargetMatch: true,
                hasFreshVerifiedInstalledApp: true
            )
        )

        #expect(disposition == .block(.deviceEvidenceConflict))
    }

    private func context(
        externallySuppressesActions: Bool = false,
        allowsCriticalActions: Bool = true,
        usedCachedActionEvidence: Bool = false,
        hasAvailabilityConflict: Bool = false,
        hasDegradedTargetObservation: Bool = false,
        hasInstallationBlocker: Bool = false,
        hasExactStableTargetMatch: Bool = false,
        hasFreshVerifiedInstalledApp: Bool = false
    ) -> AutomaticRefreshAuthorizer.Context {
        AutomaticRefreshAuthorizer.Context(
            externallySuppressesActions: externallySuppressesActions,
            allowsCriticalActions: allowsCriticalActions,
            usedCachedActionEvidence: usedCachedActionEvidence,
            hasAvailabilityConflict: hasAvailabilityConflict,
            hasDegradedTargetObservation:
                hasDegradedTargetObservation,
            hasInstallationBlocker: hasInstallationBlocker,
            hasExactStableTargetMatch: hasExactStableTargetMatch,
            hasFreshVerifiedInstalledApp:
                hasFreshVerifiedInstalledApp
        )
    }
}
