import Testing
@testable import IOSSignKit

struct RenewalIconPresentationTests {
    @Test
    func monitoringUsesNormalIdleForAHealthyOnlineDevice() {
        let presentation = make(
            phase: .monitoring,
            expiryUrgency: .healthy
        )

        #expect(presentation.visualState == .normal)
        #expect(presentation.motion == .idle)
    }

    @Test
    func warningUrgencyUsesWarningWhileIdle() {
        let presentation = make(
            phase: .monitoring,
            expiryUrgency: .warning
        )

        #expect(presentation.visualState == .warning)
        #expect(presentation.motion == .idle)
    }

    @Test
    func criticalUrgencyStaysWarningUntilActuallyExpired() {
        let presentation = make(
            phase: .monitoring,
            expiryUrgency: .critical,
            isExpired: false
        )

        #expect(presentation.visualState == .warning)
    }

    @Test
    func expiredStateIsCritical() {
        let presentation = make(
            phase: .monitoring,
            expiryUrgency: .critical,
            isExpired: true
        )

        #expect(presentation.visualState == .critical)
    }

    @Test
    func offlineDevicePausesWhenWaiting() {
        let presentation = make(
            phase: .waitingForDevice,
            deviceTone: .warning
        )

        #expect(presentation.visualState == .offline)
        #expect(presentation.motion == .paused)
    }

    @Test
    func offlineDeviceKeepsItsColorWhileChecking() {
        let presentation = make(
            phase: .checking,
            deviceTone: .neutral
        )

        #expect(presentation.visualState == .offline)
        #expect(presentation.motion == .checking)
    }

    @Test
    func countdownIsWarningAndClampsProgress() {
        let presentation = make(
            phase: .countdown,
            progress: .fraction(1.6)
        )

        #expect(presentation.visualState == .warning)
        #expect(presentation.motion == .countdown(fraction: 1))
    }

    @Test
    func deployingKeepsTheUnderlyingVisualState() {
        let presentation = make(
            phase: .deploying,
            expiryUrgency: .warning
        )

        #expect(presentation.visualState == .warning)
        #expect(presentation.motion == .deploying)
    }

    @Test
    func completedIsTheOnlyEventThatForcesHealthySuccess() {
        let completed = make(
            phase: .completed,
            deviceTone: .warning,
            expiryUrgency: .critical,
            isExpired: true
        )
        let afterFeedback = make(
            phase: .monitoring,
            expiryUrgency: .healthy
        )

        #expect(completed.visualState == .healthy)
        #expect(completed.motion == .success)
        #expect(afterFeedback.visualState == .normal)
        #expect(afterFeedback.motion == .idle)
    }

    @Test
    func blockedStateIsCriticalAndPaused() {
        let presentation = make(phase: .blocked)

        #expect(presentation.visualState == .critical)
        #expect(presentation.motion == .paused)
    }

    @Test
    func criticalAttentionUsesCriticalVisualState() {
        let presentation = make(
            phase: .attention,
            headerTone: .critical
        )

        #expect(presentation.visualState == .critical)
        #expect(presentation.motion == .attention)
    }

    private func make(
        phase: PrimaryJourneyPhase,
        headerTone: StatusTone = .info,
        deviceTone: StatusTone = .good,
        expiryUrgency: RemainingExpiryUrgency = .unknown,
        isExpired: Bool = false,
        progress: OperationActivityProgress? = nil
    ) -> RenewalIconPresentation {
        RenewalIconPresentation.make(
            phase: phase,
            headerTone: headerTone,
            deviceTone: deviceTone,
            expiryUrgency: expiryUrgency,
            isExpired: isExpired,
            progress: progress
        )
    }
}
