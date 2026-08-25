import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct AutomaticRefreshWaitCoordinatorTests {
    @Test
    func lockedDeviceIsProbedUntilUnlockAndResumesOnlyOnce()
        async throws
    {
        let scheduler = ManualRefreshScheduler()
        let probes = AutomaticWaitProbeRecorder(
            outcomes: [.stillWaiting(.deviceLocked), .resume]
        )
        let transitions = TestEventRecorder<AutomaticRefreshWaitTransition>()
        var resumeCount = 0
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )

        let started = coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: { await probes.next() },
            resume: {
                resumeCount += 1
                return true
            },
            transition: transitions.record
        )
        #expect(started)
        #expect(try await transitions.next() == .waitingLocked)

        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        #expect(try await transitions.next() == .waitingLocked)
        await scheduler.waitUntilScheduled(count: 2)
        scheduler.advance(by: .milliseconds(5))
        #expect(try await transitions.next() == .unlockObserved)
        #expect(try await transitions.next() == .resumed)

        #expect(await probes.count() == 2)
        #expect(resumeCount == 1)
        #expect(!coordinator.isWaiting)
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    @Test
    func duplicateRequestsForSameExpiryKeepASingleProbeLoop()
        async throws
    {
        let scheduler = ManualRefreshScheduler()
        let resumes = TestEventRecorder<Void>()
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )
        var resumeCount = 0
        let resume: AutomaticRefreshWaitCoordinator.Resume = {
            resumeCount += 1
            resumes.record(())
            return true
        }

        let firstStarted = coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: { .resume },
            resume: resume
        )
        let duplicateStarted = coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: { .resume },
            resume: resume
        )

        #expect(firstStarted)
        #expect(!duplicateStarted)
        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        _ = try await resumes.next()
        #expect(resumeCount == 1)
        #expect(scheduler.snapshot.requestedDelays.count == 1)
    }

    @Test
    func targetChangeDiscardsStaleProbeResult() async throws {
        let scheduler = ManualRefreshScheduler()
        let staleProbeGate = AutomaticWaitGate()
        let staleProbeStarted = TestEventRecorder<Void>()
        let currentResumed = TestEventRecorder<Void>()
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )
        var staleResumeCount = 0
        var currentResumeCount = 0

        let staleStarted = coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: {
                staleProbeStarted.record(())
                await staleProbeGate.wait()
                return .resume
            },
            resume: {
                staleResumeCount += 1
                return true
            }
        )
        #expect(staleStarted)
        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        _ = try await staleProbeStarted.next()

        let currentStarted = coordinator.wait(
            key: AutomaticRefreshWaitKey(
                targetGeneration: 1,
                deviceID: "other-device",
                bundleID: "com.example.other",
                installationIdentity: .test,
                source: .automaticInitial
            ),
            blocker: .deviceLocked,
            probe: { .resume },
            resume: {
                currentResumeCount += 1
                currentResumed.record(())
                return true
            }
        )
        #expect(currentStarted)
        staleProbeGate.release()
        await scheduler.waitUntilScheduled(count: 2)
        scheduler.advance(by: .milliseconds(5))
        _ = try await currentResumed.next()

        #expect(staleResumeCount == 0)
        #expect(currentResumeCount == 1)
    }

    @Test
    func productionPolicyUsesBlockerSpecificInitialIntervals()
        async
    {
        let cases: [(AutomaticRefreshWaitBlocker, Duration)] = [
            (.deviceLocked, .seconds(30)),
            (.lockStateUnknown, .seconds(60)),
            (.destinationPreparation, .seconds(120)),
        ]

        for (blocker, expectedDelay) in cases {
            let scheduler = ManualRefreshScheduler()
            let coordinator = AutomaticRefreshWaitCoordinator(
                policy: RefreshTimingPolicy.production
                    .automaticWaitPolicy,
                scheduler: scheduler.interface
            )
            coordinator.wait(
                key: .test,
                blocker: blocker,
                probe: { .cancel },
                resume: { true }
            )

            await scheduler.waitUntilScheduled(count: 1)
            #expect(scheduler.snapshot.requestedDelays.first == expectedDelay)
            coordinator.cancel()
            #expect(scheduler.snapshot.pendingSleepCount == 0)
        }
    }

    @Test
    func prolongedWaitUsesFiveMinuteIntervalAfterTwoHours()
        async
    {
        let scheduler = ManualRefreshScheduler()
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: RefreshTimingPolicy.production
                .automaticWaitPolicy,
            scheduler: scheduler.interface
        )
        coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: { .stillWaiting(.deviceLocked) },
            resume: { true }
        )

        await scheduler.waitUntilScheduled(count: 1)
        #expect(scheduler.snapshot.requestedDelays == [.seconds(30)])
        scheduler.advance(by: .seconds(2 * 60 * 60))
        await scheduler.waitUntilScheduled(count: 2)
        #expect(
            scheduler.snapshot.requestedDelays
                == [.seconds(30), .seconds(300)]
        )
        coordinator.cancel()
    }

    @Test
    func wakeReplacesRegularDelayWithFiveAndTwentySecondProbes()
        async
    {
        let scheduler = ManualRefreshScheduler()
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: RefreshTimingPolicy.production
                .automaticWaitPolicy,
            scheduler: scheduler.interface
        )
        coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: { .stillWaiting(.deviceLocked) },
            resume: { true }
        )
        await scheduler.waitUntilScheduled(count: 1)

        coordinator.observeWake()
        await scheduler.waitUntilScheduled(count: 2)
        scheduler.advance(by: .seconds(5))
        await scheduler.waitUntilScheduled(count: 3)

        #expect(
            scheduler.snapshot.requestedDelays
                == [.seconds(30), .seconds(5), .seconds(15)]
        )
        coordinator.cancel()
    }

    @Test
    func busyResumeKeepsWaitAliveUntilPreflightCanTakeOver()
        async throws
    {
        let scheduler = ManualRefreshScheduler()
        let transitions = TestEventRecorder<AutomaticRefreshWaitTransition>()
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )
        var resumeAttempts = 0
        coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: { .resume },
            resume: {
                resumeAttempts += 1
                return resumeAttempts == 2
            },
            transition: transitions.record
        )
        #expect(try await transitions.next() == .waitingLocked)

        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        #expect(try await transitions.next() == .unlockObserved)
        #expect(try await transitions.next() == .preflightDeferred)
        await scheduler.waitUntilScheduled(count: 2)
        scheduler.advance(by: .milliseconds(5))
        #expect(try await transitions.next() == .unlockObserved)
        #expect(try await transitions.next() == .resumed)

        #expect(resumeAttempts == 2)
        #expect(!coordinator.isWaiting)
    }

    @Test
    func immediateProbeDoesNotOverlapAnInFlightProbe()
        async throws
    {
        let scheduler = ManualRefreshScheduler()
        let probes = AutomaticWaitConcurrencyRecorder()
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )
        coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: {
                await probes.probe()
                return .stillWaiting(.deviceLocked)
            },
            resume: { true }
        )
        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        try await probes.waitUntilProbeStarts(number: 1)

        coordinator.probeNow()
        coordinator.probeNow()
        await probes.releaseFirstProbe()
        await scheduler.waitUntilScheduled(count: 2)
        try await probes.waitUntilProbeStarts(number: 2)

        #expect(await probes.maximumConcurrentCalls == 1)
        coordinator.cancel()
        await probes.finishCurrentProbe()
    }

    @Test
    func pendingImmediateProbeDoesNotDiscardInFlightResume()
        async throws
    {
        let scheduler = ManualRefreshScheduler()
        let probeGate = AutomaticWaitGate()
        let probeStarted = TestEventRecorder<Void>()
        let resumed = TestEventRecorder<Void>()
        let probes = AutomaticWaitProbeRecorder(outcomes: [])
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )
        var resumeCount = 0
        coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: {
                await probes.recordCall()
                probeStarted.record(())
                await probeGate.wait()
                return .resume
            },
            resume: {
                resumeCount += 1
                resumed.record(())
                return true
            }
        )
        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        _ = try await probeStarted.next()

        coordinator.probeNow()
        probeGate.release()
        _ = try await resumed.next()

        #expect(resumeCount == 1)
        #expect(await probes.count() == 1)
        #expect(!coordinator.isWaiting)
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    @Test
    func pendingImmediateProbeDoesNotDiscardInFlightCancellation()
        async throws
    {
        let scheduler = ManualRefreshScheduler()
        let probeGate = AutomaticWaitGate()
        let probeStarted = TestEventRecorder<Void>()
        let transitions = TestEventRecorder<AutomaticRefreshWaitTransition>()
        let probes = AutomaticWaitProbeRecorder(outcomes: [])
        let coordinator = AutomaticRefreshWaitCoordinator(
            policy: .test,
            scheduler: scheduler.interface
        )
        coordinator.wait(
            key: .test,
            blocker: .deviceLocked,
            probe: {
                await probes.recordCall()
                probeStarted.record(())
                await probeGate.wait()
                return .cancel
            },
            resume: { true },
            transition: transitions.record
        )
        #expect(try await transitions.next() == .waitingLocked)
        await scheduler.waitUntilScheduled(count: 1)
        scheduler.advance(by: .milliseconds(5))
        _ = try await probeStarted.next()

        coordinator.probeNow()
        probeGate.release()
        #expect(try await transitions.next() == .cancelled)

        #expect(await probes.count() == 1)
        #expect(!coordinator.isWaiting)
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    @Test
    func completeInstallationIdentityParticipatesInWaitKey() {
        let unverifiedIdentity = InstallationIdentitySnapshot(
            presence: .installed,
            bundleID: "com.example.App",
            deviceID: "iphone-1",
            version: "1|0",
            buildVersion: "1",
            appURL: "/Example.app",
            activeInstallationSuccessAt: nil,
            expiryEvidenceIsVerified: false
        )
        let verifiedIdentity = InstallationIdentitySnapshot(
            presence: .installed,
            bundleID: "com.example.App",
            deviceID: "iphone-1",
            version: "1|0",
            buildVersion: "1",
            appURL: "/Example.app",
            activeInstallationSuccessAt: nil,
            expiryEvidenceIsVerified: true
        )

        #expect(
            AutomaticRefreshWaitKey(
                targetGeneration: 0,
                deviceID: "iphone-1",
                bundleID: "com.example.App",
                installationIdentity: unverifiedIdentity,
                source: .automaticInitial
            ) != AutomaticRefreshWaitKey(
                targetGeneration: 0,
                deviceID: "iphone-1",
                bundleID: "com.example.App",
                installationIdentity: verifiedIdentity,
                source: .automaticInitial
            )
        )
    }
}

private actor AutomaticWaitProbeRecorder {
    private var outcomes: [AutomaticRefreshWaitProbeOutcome]
    private var callCount = 0

    init(outcomes: [AutomaticRefreshWaitProbeOutcome]) {
        self.outcomes = outcomes
    }

    func next() -> AutomaticRefreshWaitProbeOutcome {
        callCount += 1
        return outcomes.isEmpty ? .cancel : outcomes.removeFirst()
    }

    func count() -> Int { callCount }

    func recordCall() {
        callCount += 1
    }
}

private actor AutomaticWaitConcurrencyRecorder {
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0
    private var firstProbeContinuation: CheckedContinuation<Void, Never>?
    private var currentProbeContinuation: CheckedContinuation<Void, Never>?
    private let starts = TestEventRecorder<Int>()

    func probe() async {
        callCount += 1
        let number = callCount
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        starts.record(number)
        if number == 1 {
            await withCheckedContinuation { continuation in
                firstProbeContinuation = continuation
            }
        } else {
            await withCheckedContinuation { continuation in
                currentProbeContinuation = continuation
            }
        }
        activeCalls -= 1
    }

    func waitUntilProbeStarts(number: Int) async throws {
        while try await starts.next() != number {}
    }

    func releaseFirstProbe() {
        firstProbeContinuation?.resume()
        firstProbeContinuation = nil
    }

    func finishCurrentProbe() {
        currentProbeContinuation?.resume()
        currentProbeContinuation = nil
    }
}

private final class AutomaticWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if isReleased { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock {
            isReleased = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

private extension AutomaticRefreshWaitPolicy {
    static let test = AutomaticRefreshWaitPolicy(
        lockedProbeInterval: .milliseconds(5),
        unknownProbeInterval: .milliseconds(10),
        destinationProbeInterval: .milliseconds(15),
        prolongedProbeInterval: .milliseconds(20),
        rapidProbeWindow: .seconds(1),
        wakeFirstProbeDelay: .milliseconds(2),
        wakeSecondProbeDelay: .milliseconds(4)
    )
}

private extension AutomaticRefreshWaitKey {
    static let test = AutomaticRefreshWaitKey(
        targetGeneration: 0,
        deviceID: "iphone-1",
        bundleID: "com.example.App",
        installationIdentity: .test,
        source: .automaticInitial
    )
}

private extension InstallationIdentitySnapshot {
    static let test = InstallationIdentitySnapshot(
        presence: .installed,
        bundleID: "com.example.App",
        deviceID: "iphone-1",
        version: "1.0",
        buildVersion: "1",
        appURL: "/Example.app",
        activeInstallationSuccessAt: nil,
        expiryEvidenceIsVerified: true
    )
}
