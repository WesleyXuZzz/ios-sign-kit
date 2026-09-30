import Foundation
import Testing
@testable import IOSSignKit

struct EnergyEfficiencyPolicyTests {
    @Test
    func pollingToleranceIsTenPercentCappedAtOneMinute() {
        #expect(TimerCoalescingPolicy.pollingTolerance(for: 60) == 6)
        #expect(TimerCoalescingPolicy.pollingTolerance(for: 5 * 60) == 30)
        #expect(TimerCoalescingPolicy.pollingTolerance(for: 60 * 60) == 60)
        #expect(TimerCoalescingPolicy.pollingTolerance(for: 0) == 0)
    }

    @Test
    func expiryLabelToleranceKeepsCountdownsResponsive() {
        #expect(
            TimerCoalescingPolicy.expiryLabelTolerance(for: 1)
                == TimerCoalescingPolicy.secondsCountdownTolerance
        )
        #expect(TimerCoalescingPolicy.expiryLabelTolerance(for: 10) == 1)
        #expect(TimerCoalescingPolicy.expiryLabelTolerance(for: 61) == 2)
        #expect(TimerCoalescingPolicy.expiryLabelTolerance(for: 3_601) == 2)
        #expect(TimerCoalescingPolicy.expiryLabelTolerance(for: 0) == 0)
    }

    @Test
    func onlyTimerDrivenBackgroundChecksRunAtUtilityQoS() {
        let utilityModes: [EnvironmentRefreshMode] = [
            .backgroundPoll,
            .appMetadataRetry,
            .automaticRecoveryCheck
        ]
        for mode in utilityModes {
            #expect(
                MenuBarViewModel.commandQualityOfService(
                    presentation: .background,
                    mode: mode
                ) == .utility
            )
            #expect(
                MenuBarViewModel.commandQualityOfService(
                    presentation: .foreground,
                    mode: mode
                ) == .inherited
            )
        }
        for mode in [
            EnvironmentRefreshMode.connectionConfirmation,
            .manualDeepCheck
        ] {
            #expect(
                MenuBarViewModel.commandQualityOfService(
                    presentation: .background,
                    mode: mode
                ) == .inherited
            )
        }
    }

    @Test
    func spawnQualityOfServiceIsTaskScoped() async {
        #expect(CommandSpawnQualityOfService.current == .inherited)
        #expect(CommandSpawnQualityOfService.inherited.spawnQOSClass == nil)
        #expect(
            CommandSpawnQualityOfService.utility.spawnQOSClass
                == QOS_CLASS_UTILITY
        )
        await CommandSpawnQualityOfService.$current.withValue(.utility) {
            #expect(CommandSpawnQualityOfService.current == .utility)
            let inherited = await Task {
                CommandSpawnQualityOfService.current
            }.value
            #expect(inherited == .utility)
        }
        #expect(CommandSpawnQualityOfService.current == .inherited)
    }

    @Test
    func commandsStillRunWhenSpawnedAtUtilityQoS() async throws {
        let result = try await CommandSpawnQualityOfService.$current
            .withValue(.utility) {
                try await CommandRunner().runAsync(
                    "/bin/sh",
                    arguments: ["-c", "printf ok"],
                    timeoutSeconds: 5
                )
            }

        #expect(result.completedSuccessfullyAndFullyTerminated)
        #expect(result.standardOutput == "ok")
    }
}
