import Foundation
import Testing
@testable import IOSSignKit

struct ReminderPolicyTests {
    @Test
    func doesNotPromptWhenAppIsNotYetDetected() {
        let decision = ReminderPolicy().evaluate(
            config: .default,
            state: .default,
            matchedDevice: exampleDevice,
            installedAppInfo: nil,
            expiryInfo: nil
        )

        #expect(!decision.shouldPrompt)
    }

    @Test
    func doesNotPromptBeforeExpiry() {
        let policy = ReminderPolicy()
        let config = AppConfig.default
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let expiryAt = now.addingTimeInterval(60)
        let decision = policy.evaluate(
            config: config,
            state: .default,
            matchedDevice: exampleDevice,
            installedAppInfo: exampleInstalledApp,
            expiryInfo: makeExpiryInfo(at: expiryAt),
            now: now
        )

        #expect(!decision.shouldPrompt)
        #expect(decision.nextEligibleAt == expiryAt)
    }

    @Test
    func promptsWhenExpiryIsReached() {
        let policy = ReminderPolicy()
        let config = AppConfig.default
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let decision = policy.evaluate(
            config: config,
            state: .default,
            matchedDevice: exampleDevice,
            installedAppInfo: exampleInstalledApp,
            expiryInfo: makeExpiryInfo(at: now),
            now: now
        )

        #expect(decision.shouldPrompt)
        #expect(decision.reason == "已安装 App 预计已到期。")
    }

    @Test
    func waitsForCooldownAfterExpiry() {
        let policy = ReminderPolicy()
        let config = AppConfig.default
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        var state = AppState.default
        state.lastPromptAt = now.addingTimeInterval(-2 * 60 * 60)

        let decision = policy.evaluate(
            config: config,
            state: state,
            matchedDevice: exampleDevice,
            installedAppInfo: exampleInstalledApp,
            expiryInfo: makeExpiryInfo(at: now.addingTimeInterval(-60)),
            now: now
        )

        #expect(!decision.shouldPrompt)
        #expect(decision.reason == "提醒冷却中。")
    }

    @Test
    func futurePromptTimestampDoesNotCreateAnUnboundedCooldown() {
        let policy = ReminderPolicy()
        let config = AppConfig.default
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        var state = AppState.default
        state.lastPromptAt = now.addingTimeInterval(365 * 24 * 60 * 60)

        let decision = policy.evaluate(
            config: config,
            state: state,
            matchedDevice: exampleDevice,
            installedAppInfo: exampleInstalledApp,
            expiryInfo: makeExpiryInfo(at: now.addingTimeInterval(-60)),
            now: now
        )

        #expect(decision.shouldPrompt)
        #expect(decision.nextEligibleAt == nil)
    }

    @Test(arguments: [true, false])
    func processRecoveryBlockSuppressesExpiredReminder(
        isDeploymentBlock: Bool
    ) {
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        var state = AppState.default
        state.deploymentRecoveryBlocked = isDeploymentBlock
        state.commandRecoveryBlocked = !isDeploymentBlock
        state.lastErrorSummary = "进程恢复尚未完成，已阻止新续签。"

        let decision = ReminderPolicy().evaluate(
            config: .default,
            state: state,
            matchedDevice: exampleDevice,
            installedAppInfo: exampleInstalledApp,
            expiryInfo: makeExpiryInfo(at: now.addingTimeInterval(-60)),
            now: now
        )

        #expect(!decision.shouldPrompt)
        #expect(decision.reason == state.lastErrorSummary)
        #expect(decision.nextEligibleAt == nil)
    }
}

private let exampleDevice = DeviceInfo(
    id: "1",
    name: "Phone",
    platform: "com.apple.platform.iphoneos",
    osVersion: "18",
    isAvailable: true,
    isPaired: true
)

private let exampleInstalledApp = InstalledAppInfo(
    bundleIdentifier: "com.example.app",
    name: "Example",
    version: "1.0",
    bundleVersion: "1",
    appURL: "file:///tmp/Example.app",
    builtByDeveloper: true,
    installMetadata: nil
)

private func makeExpiryInfo(at date: Date) -> ExpiryInfo {
    ExpiryInfo(
        estimatedExpiryAt: date,
        source: "test",
        detectedAt: date,
        isFallbackValue: false
    )
}
