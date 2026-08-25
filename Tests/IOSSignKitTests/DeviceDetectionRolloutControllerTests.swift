import Testing
@testable import IOSSignKit

struct DeviceDetectionRolloutControllerTests {
    @Test
    func fallbackExecutesCompatibilityEngineWithoutComparison() {
        let decision = DeviceDetectionRolloutController().decision(for: .fallback)

        #expect(decision.primaryEngine == .compatibility)
        #expect(decision.comparison == nil)
        #expect(decision.allowsCriticalActions)
    }

    @Test
    func shadowKeepsCompatibilityPrimaryAndOnlyComparesCanonical() {
        let decision = DeviceDetectionRolloutController().decision(for: .shadow)

        #expect(decision.primaryEngine == .compatibility)
        #expect(decision.comparison == .pure(.canonical))
        #expect(decision.allowsCriticalActions)
    }

    @Test
    func readOnlyExecutesCanonicalWithCompatibilityComparisonAndNoActions() {
        let decision = DeviceDetectionRolloutController().decision(for: .readOnly)

        #expect(decision.primaryEngine == .canonical)
        #expect(decision.comparison == .pure(.compatibility))
        #expect(!decision.allowsCriticalActions)
    }

    @Test
    func productionExecutesCanonicalAndAllowsActionsAfterRolloutGatesPass() {
        let decision = DeviceDetectionRolloutController().decision(for: .production)

        #expect(decision.primaryEngine == .canonical)
        #expect(decision.comparison == nil)
        #expect(decision.allowsCriticalActions)
    }

    @Test
    func selectingCurrentModePreservesGenerationAndTransientState() {
        let transition = DeviceDetectionRolloutController().transition(
            from: DeviceDetectionRolloutState(
                mode: .shadow,
                generation: 7
            ),
            to: .shadow,
            hasActiveDeployment: false
        )

        #expect(
            transition.nextState
                == DeviceDetectionRolloutState(mode: .shadow, generation: 7)
        )
        #expect(!transition.invalidatesSessionCaches)
        #expect(!transition.resetsConnectionState)
        #expect(!transition.discardsOlderPassiveResults)
        #expect(transition.deferredMode == nil)
    }

    @Test
    func switchingModeAdvancesGenerationAndRequestsTransientReset() {
        let transition = DeviceDetectionRolloutController().transition(
            from: DeviceDetectionRolloutState(
                mode: .shadow,
                generation: 7
            ),
            to: .readOnly,
            hasActiveDeployment: false
        )

        #expect(
            transition.nextState
                == DeviceDetectionRolloutState(
                    mode: .readOnly,
                    generation: 8
                )
        )
        #expect(transition.invalidatesSessionCaches)
        #expect(transition.resetsConnectionState)
        #expect(transition.discardsOlderPassiveResults)
        #expect(transition.preservesActiveDeployment)
        #expect(transition.deferredMode == nil)
    }

    @Test
    func switchingModeWaitsForActiveDeploymentWithoutResettingState() {
        let transition = DeviceDetectionRolloutController().transition(
            from: DeviceDetectionRolloutState(
                mode: .shadow,
                generation: 7
            ),
            to: .fallback,
            hasActiveDeployment: true
        )

        #expect(
            transition.nextState
                == DeviceDetectionRolloutState(mode: .shadow, generation: 7)
        )
        #expect(!transition.invalidatesSessionCaches)
        #expect(!transition.resetsConnectionState)
        #expect(!transition.discardsOlderPassiveResults)
        #expect(transition.preservesActiveDeployment)
        #expect(transition.deferredMode == .fallback)
    }
}
