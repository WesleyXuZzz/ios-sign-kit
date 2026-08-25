import Testing
@testable import IOSSignKit

@MainActor
struct WorkflowCoordinatorTests {
    @Test
    func deviceRefreshSessionRejectsStaleSequenceCompletion() {
        let session = DeviceRefreshSession()
        let first = session.begin()
        let second = session.begin()

        #expect(second != first)
        #expect(!session.complete(sequence: first))
        #expect(session.isCurrent(second))
        #expect(session.complete(sequence: second))
        #expect(!session.isRunning)
    }

    @Test
    func deploymentCancellationRequestKeepsTransactionUntilTaskSettles() {
        let coordinator = DeploymentTransactionCoordinator()
        coordinator.begin(isAutomatic: true) {}

        #expect(coordinator.hasActiveTask)
        #expect(coordinator.isAutomaticPreflight)

        coordinator.requestPreflightCancellation()

        #expect(coordinator.hasActiveTask)
        #expect(!coordinator.isAutomaticPreflight)

        coordinator.clearPreflight()
        #expect(!coordinator.hasActiveTask)
    }
}
