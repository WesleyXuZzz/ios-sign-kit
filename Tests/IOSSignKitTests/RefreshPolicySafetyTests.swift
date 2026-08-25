import Testing
@testable import IOSSignKit

struct RefreshPolicySafetyTests {
    @Test
    func backgroundWithFreshCandidateEvidenceOnlyNeedsHeartbeat() {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .background,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: true
            )
        )

        #expect(work == .heartbeatOnly)
    }

    @Test
    func backgroundCacheMissVerifiesAppBeforeEvaluation() {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .background,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: false
            )
        )

        #expect(work == .verifyAppThenEvaluate)
    }

    @Test
    func manualRequestAlwaysUsesFullInteractiveCheck() {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .manual,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: true
            )
        )

        #expect(work == .fullInteractiveCheck)
    }

    @Test
    func recoveryRequestBypassesCandidateCaches() {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .recovery,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: true
            )
        )

        #expect(work == .verifyAppThenEvaluate)
    }

    @Test(arguments: CriticalRefreshAction.allCases)
    func criticalActionCandidatesRequireFreshWork(
        _ action: CriticalRefreshAction
    ) {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .background,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: true,
                criticalActionCandidates: [action]
            )
        )

        let expectedWork: RefreshWork = action == .deployment
            ? .fullInteractiveCheck
            : .verifyAppThenEvaluate
        #expect(work == expectedWork)
    }

    @Test
    func cachedReminderCandidateTriggersFreshVerification() {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .background,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: true,
                criticalActionCandidates: [.reminder]
            )
        )

        #expect(work == .verifyAppThenEvaluate)
    }

    @Test
    func deploymentCandidateRequiresFullInteractiveWork() {
        let work = RefreshPolicy().work(
            for: RefreshPolicyContext(
                requestKind: .background,
                hasFreshXcodeValidation: true,
                hasFreshInstalledAppEvidence: true,
                criticalActionCandidates: [.deployment]
            )
        )

        #expect(work == .fullInteractiveCheck)
    }
}
