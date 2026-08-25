import Foundation
import Testing
@testable import IOSSignKit

struct DeviceConnectionReducerTests {
    @Test
    func trustedMatchImmediatelyBecomesOnline() {
        let reducer = DeviceConnectionReducer()
        let now = ContinuousClock().now
        let device = targetDevice
        let observation = makeObservation(.matched(device))

        let transition = reducer.reduce(
            state: .initial,
            event: .observation(observation, at: now)
        )

        #expect(transition.state.phase == .online)
        #expect(transition.state.matchedDevice == device)
        #expect(transition.state.confirmedAbsenceCount == 0)
        #expect(transition.state.confirmationStartedAt == nil)
        #expect(transition.nextCheckAfter == nil)
    }

    @Test
    func firstCompleteAbsenceStartsMonotonicConfirmation() {
        let reducer = DeviceConnectionReducer()
        let now = ContinuousClock().now
        let observation = makeObservation(.confirmedAbsent)

        let transition = reducer.reduce(
            state: .initial,
            event: .observation(observation, at: now)
        )

        #expect(transition.state.phase == .confirming)
        #expect(transition.state.confirmedAbsenceCount == 1)
        #expect(transition.state.confirmationStartedAt == now)
        #expect(transition.nextCheckAfter == .seconds(5))
    }

    @Test
    func secondCompleteAbsenceWaitsForTheFullConfirmationWindow() {
        let reducer = DeviceConnectionReducer()
        let startedAt = ContinuousClock().now
        let first = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(.confirmedAbsent),
                at: startedAt
            )
        )

        let second = reducer.reduce(
            state: first.state,
            event: .observation(
                makeObservation(.confirmedAbsent),
                at: startedAt.advanced(by: .seconds(5))
            )
        )

        #expect(second.state.phase == .confirming)
        #expect(second.state.confirmedAbsenceCount == 2)
        #expect(second.state.confirmationStartedAt == startedAt)
        #expect(second.nextCheckAfter == .seconds(25))
    }

    @Test
    func twoCompleteAbsencesSpanningThirtySecondsBecomeOffline() {
        let reducer = DeviceConnectionReducer()
        let startedAt = ContinuousClock().now
        let first = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(.confirmedAbsent),
                at: startedAt
            )
        )

        let second = reducer.reduce(
            state: first.state,
            event: .observation(
                makeObservation(.confirmedAbsent),
                at: startedAt.advanced(by: .seconds(30))
            )
        )

        #expect(second.state.phase == .offline)
        #expect(second.state.confirmedAbsenceCount == 2)
        #expect(second.state.confirmationStartedAt == startedAt)
        #expect(second.nextCheckAfter == nil)
    }

    @Test
    func degradedAbsenceDoesNotContributeANegativeSample() {
        let reducer = DeviceConnectionReducer()
        let startedAt = ContinuousClock().now
        let first = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(.confirmedAbsent),
                at: startedAt
            )
        )

        let degraded = reducer.reduce(
            state: first.state,
            event: .observation(
                makeObservation(
                    .confirmedAbsent,
                    quality: .degraded
                ),
                at: startedAt.advanced(by: .seconds(30))
            )
        )

        #expect(degraded.state.phase == .confirming)
        #expect(degraded.state.confirmedAbsenceCount == 1)
        #expect(degraded.state.confirmationStartedAt == startedAt)
        #expect(degraded.nextCheckAfter == .seconds(5))
    }

    @Test
    func inconclusiveObservationNeverStartsAbsenceConfirmation() {
        let reducer = DeviceConnectionReducer()
        let now = ContinuousClock().now

        let transition = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(
                    .inconclusive,
                    quality: .degraded
                ),
                at: now
            )
        )

        #expect(transition.state.phase == .inconclusive)
        #expect(transition.state.confirmedAbsenceCount == 0)
        #expect(transition.state.confirmationStartedAt == nil)
        #expect(transition.nextCheckAfter == .seconds(5))
    }

    @Test
    func unavailableTargetEntersRecoveryWithoutPassingThroughOffline() throws {
        let reducer = DeviceConnectionReducer()
        let now = ContinuousClock().now
        let deviceID = try #require(StableDeviceID("iphone-1"))
        let candidate = TargetRecoveryCandidate(
            deviceID: deviceID,
            displayName: "Nearby iPhone",
            osVersion: "27.0",
            reason: .wirelessTransportUnavailable
        )
        let unavailableDevice = UnavailableDeviceInfo(
            id: "iphone-1",
            name: "Nearby iPhone",
            osVersion: "27.0",
            pairingState: "paired",
            connectionState: "connected",
            tunnelState: "disconnected",
            developerModeStatus: "enabled",
            diagnosticMessage: "无线隧道尚未建立"
        )

        let transition = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(
                    .unavailable(unavailableDevice),
                    recoveryCandidate: candidate
                ),
                at: now
            )
        )

        #expect(transition.state.phase == .recoveryCandidate)
        #expect(transition.state.recoveryCandidate == candidate)
        #expect(transition.state.unavailableDevice == unavailableDevice)
        #expect(transition.state.confirmedAbsenceCount == 0)
        #expect(transition.nextCheckAfter == nil)
    }

    @Test
    func inconclusiveTargetWithFreshCandidateEntersControlledRecovery() throws {
        let reducer = DeviceConnectionReducer()
        let deviceID = try #require(StableDeviceID("iphone-1"))
        let candidate = TargetRecoveryCandidate(
            deviceID: deviceID,
            displayName: "Nearby iPhone",
            osVersion: "27.0",
            reason: .wirelessTransportUnavailable
        )

        let transition = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(
                    .inconclusive,
                    quality: .degraded,
                    recoveryCandidate: candidate
                ),
                at: ContinuousClock().now
            )
        )

        #expect(transition.state.phase == .recoveryCandidate)
        #expect(transition.state.recoveryCandidate == candidate)
        #expect(transition.state.confirmedAbsenceCount == 0)
        #expect(transition.nextCheckAfter == nil)
    }

    @Test
    func unavailableTargetWithoutCandidateCannotEnterPairingRecovery() {
        let reducer = DeviceConnectionReducer()
        let unavailableDevice = UnavailableDeviceInfo(
            id: "iphone-1",
            name: "Nearby iPhone",
            osVersion: "27.0",
            pairingState: "paired",
            connectionState: "disconnected",
            tunnelState: nil,
            developerModeStatus: "enabled",
            diagnosticMessage: "设备明确不可用"
        )

        let transition = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(.unavailable(unavailableDevice)),
                at: ContinuousClock().now
            )
        )

        #expect(transition.state.phase == .offline)
        #expect(transition.state.recoveryCandidate == nil)
        #expect(transition.nextCheckAfter == nil)
    }

    @Test
    func sessionAndTargetChangesResetTransientConfirmationState() {
        let reducer = DeviceConnectionReducer()
        let now = ContinuousClock().now
        let confirming = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(.confirmedAbsent),
                at: now
            )
        ).state

        let sessionReset = reducer.reduce(
            state: confirming,
            event: .sessionStarted
        )
        let targetReset = reducer.reduce(
            state: confirming,
            event: .targetChanged
        )

        #expect(sessionReset.state == .initial)
        #expect(sessionReset.nextCheckAfter == nil)
        #expect(targetReset.state == .initial)
        #expect(targetReset.nextCheckAfter == nil)
    }

    @Test
    func wakeResetsEvidenceAndRequestsOneDelayedRecheck() {
        let reducer = DeviceConnectionReducer()
        let online = reducer.reduce(
            state: .initial,
            event: .observation(
                makeObservation(.matched(targetDevice)),
                at: ContinuousClock().now
            )
        ).state

        let transition = reducer.reduce(
            state: online,
            event: .systemWoke
        )

        #expect(transition.state == .initial)
        #expect(transition.nextCheckAfter == .seconds(5))
    }
}

private let targetDevice = DeviceInfo(
    id: "iphone-1",
    name: "Nearby iPhone",
    platform: "com.apple.platform.iphoneos",
    osVersion: "27.0",
    isAvailable: true,
    isPaired: true
)

private func makeObservation(
    _ evidence: TargetDeviceEvidence,
    quality: ObservationQuality = .complete,
    recoveryCandidate: TargetRecoveryCandidate? = nil
) -> TargetDeviceObservation {
    TargetDeviceObservation(
        evidence: evidence,
        recoveryCandidate: recoveryCandidate,
        diagnostics: DeviceObservationDiagnostics(
            quality: quality,
            source: .xcdevice,
            summary: nil
        )
    )
}
