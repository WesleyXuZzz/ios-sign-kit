import Testing
@testable import IOSSignKit

struct EnvironmentRefreshModeTests {
    @Test
    func backgroundPollRevalidatesInstalledAppBeforeTakingActions() {
        let config = AppConfig(
            projectRootPath: nil,
            deployScriptPath: nil,
            xcodeprojPath: nil,
            scheme: nil,
            bundleID: "com.example.app",
            preferredDeviceID: "iphone-1",
            preferredDeviceName: "Example iPhone",
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )

        let options = EnvironmentRefreshMode.backgroundPoll.scanOptions(for: config)

        #expect(options.preferredDeviceID == "iphone-1")
        #expect(options.preferredDeviceName == "Example iPhone")
        #expect(options.attemptCount == 1)
        #expect(options.usesDevicectlFallback)
        #expect(EnvironmentRefreshMode.backgroundPoll.shouldInspectInstalledApp(
            hasKnownExpiry: false,
            hasConfirmedInstallation: false
        ))
        #expect(EnvironmentRefreshMode.backgroundPoll.shouldInspectInstalledApp(
            hasKnownExpiry: true,
            hasConfirmedInstallation: false
        ))
        #expect(EnvironmentRefreshMode.backgroundPoll.shouldInspectInstalledApp(
            hasKnownExpiry: true,
            hasConfirmedInstallation: true
        ))
        #expect(EnvironmentRefreshMode.backgroundPoll.treatsScanFailureAsTransient)
    }

    @Test
    func manualDeepCheckUsesReliableScanAndInspectsInstalledApp() {
        let config = AppConfig(
            projectRootPath: nil,
            deployScriptPath: nil,
            xcodeprojPath: nil,
            scheme: nil,
            bundleID: "com.example.app",
            preferredDeviceID: "iphone-1",
            preferredDeviceName: "Example iPhone",
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )

        let options = EnvironmentRefreshMode.manualDeepCheck.scanOptions(for: config)

        #expect(options.preferredDeviceID == "iphone-1")
        #expect(options.preferredDeviceName == "Example iPhone")
        #expect(options.attemptCount == 3)
        #expect(options.usesDevicectlFallback)
        #expect(EnvironmentRefreshMode.manualDeepCheck.shouldInspectInstalledApp(
            hasKnownExpiry: false,
            hasConfirmedInstallation: false
        ))
        #expect(EnvironmentRefreshMode.manualDeepCheck.shouldInspectInstalledApp(
            hasKnownExpiry: true,
            hasConfirmedInstallation: true
        ))
        #expect(!EnvironmentRefreshMode.manualDeepCheck.treatsScanFailureAsTransient)
    }

    @Test
    func automaticRecoveryUsesSingleDeepScanAndRevalidatesInstalledApp() {
        let config = AppConfig(
            projectRootPath: nil,
            deployScriptPath: nil,
            xcodeprojPath: nil,
            scheme: nil,
            bundleID: "com.example.app",
            preferredDeviceID: "iphone-1",
            preferredDeviceName: "Example iPhone",
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .autoRefreshWhenExpired
        )

        let options = EnvironmentRefreshMode.automaticRecoveryCheck.scanOptions(for: config)

        #expect(options.attemptCount == 1)
        #expect(options.commandTimeoutSeconds == 12)
        #expect(options.usesDevicectlFallback)
        #expect(EnvironmentRefreshMode.automaticRecoveryCheck.shouldInspectInstalledApp(
            hasKnownExpiry: false,
            hasConfirmedInstallation: false
        ))
        #expect(EnvironmentRefreshMode.automaticRecoveryCheck.shouldInspectInstalledApp(
            hasKnownExpiry: true,
            hasConfirmedInstallation: true
        ))
        #expect(EnvironmentRefreshMode.automaticRecoveryCheck.treatsScanFailureAsTransient)
    }
}
