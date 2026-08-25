import Testing
@testable import IOSSignKit

struct HardcodedConstantsPolicyTests {
    @Test
    func protocolFormatsHaveSingleCurrentVersions() {
        #expect(DeployLogFormat.currentVersion == 2)
        #expect(DeployLogFormat.currentVersionHeader == "format_version=2")
        #expect(CommandOwnershipMarkerFormat.currentSchemaVersion == 3)
        #expect(
            CommandOwnershipMarkerFormat.directoryName(userID: 501)
                == "iOSSignKit-process-markers-v3-501"
        )
        #expect(DeployLogFilename.operationalTimeZoneSecondsFromGMT == 28_800)
        #expect(
            DeployLogFilename.timestampFormat
                == "yyyy-MM-dd-HH-mm-ss.SSS-'T+08-00'"
        )
    }

    @Test
    func appConfigConstraintsOwnDefaultsRangesAndNormalization() {
        #expect(AppConfigConstraints.defaultCheckIntervalMinutes == 5)
        #expect(AppConfigConstraints.checkIntervalRange == 1...60)
        #expect(AppConfigConstraints.defaultExpiredCheckIntervalMinutes == 1)
        #expect(AppConfigConstraints.expiredCheckIntervalRange == 1...60)
        #expect(AppConfigConstraints.defaultReminderCooldownHours == 24)
        #expect(AppConfigConstraints.reminderCooldownRange == 1...72)
        #expect(AppConfigConstraints.normalizeCheckInterval(-1) == 1)
        #expect(AppConfigConstraints.normalizeCheckInterval(61) == 60)
        #expect(AppConfigConstraints.normalizeExpiredCheckInterval(-1) == 1)
        #expect(AppConfigConstraints.normalizeExpiredCheckInterval(61) == 60)
        #expect(AppConfigConstraints.normalizeReminderCooldown(0) == 1)
        #expect(AppConfigConstraints.normalizeReminderCooldown(73) == 72)

        var config = AppConfig.default
        config.checkIntervalMinutes = 12
        config.expiredCheckIntervalMinutes = 3
        #expect(config.backgroundCheckIntervalMinutes(isExpired: false) == 12)
        #expect(config.backgroundCheckIntervalMinutes(isExpired: true) == 3)
    }

    @Test
    func productionDeviceCommandBudgetsPreserveExistingValues() {
        let catalog = DeviceCommandBudgetCatalog.production

        assertBudget(
            catalog.budget(for: .backgroundObservation),
            command: 6,
            outer: 6,
            attempts: 1,
            retry: 0
        )
        assertBudget(
            catalog.budget(for: .interactiveObservation),
            command: 8,
            outer: 8,
            attempts: 3,
            retry: 1
        )
        assertBudget(
            catalog.budget(for: .recoveryObservation),
            command: 12,
            outer: 12,
            attempts: 1,
            retry: 0
        )
        assertBudget(
            catalog.budget(for: .deploymentVerification),
            command: 18,
            outer: 18,
            attempts: 1,
            retry: 0
        )
        assertBudget(
            catalog.budget(for: .installedAppInspection),
            command: 8,
            outer: 9,
            attempts: 4,
            retry: 1
        )
        assertBudget(
            catalog.budget(for: .lockStateInspection),
            command: 5,
            outer: 6,
            attempts: 2,
            retry: 0.2
        )
        assertBudget(
            catalog.budget(for: .wirelessPairing),
            command: 60,
            outer: 61,
            attempts: 1,
            retry: 0
        )
    }

    @Test
    func refreshTimingAndCompatibilityPoliciesPreserveExistingValues() {
        let policy = RefreshTimingPolicy.production

        #expect(policy.automaticRefreshCountdownSeconds == 5)
        #expect(policy.installedAppRetryDelays == [5, 30, 120, 600])
        #expect(policy.postDeployInspectionTimeout == 30)
        #expect(policy.automaticRecoveryDelay == 10)
        #expect(policy.automaticRecoveryFailureBackoff == 600)
        #expect(policy.wirelessPairingCooldown == 30 * 60)
        #expect(policy.xcodeValidationCacheTTL == .seconds(30 * 60))
        #expect(policy.installedAppCacheTTL == .seconds(10 * 60))
        #expect(policy.connectionConfirmationInterval == .seconds(30))
        #expect(policy.connectionRetryDelay == .seconds(5))
        #expect(policy.wakeRecheckDelay == .seconds(5))
        #expect(policy.requiredAbsenceCount == 2)
        #expect(
            DeviceCompatibilityPolicy.minimumWirelessPairingMajorVersion
                == 27
        )
        #expect(
            DeviceCompatibilityPolicy.wiredConnectionGuidance
                .contains("iOS 27")
        )
    }

    private func assertBudget(
        _ budget: DeviceCommandBudget,
        command: Double,
        outer: Double,
        attempts: Int,
        retry: Double
    ) {
        #expect(budget.commandTimeoutSeconds == command)
        #expect(budget.outerTimeoutSeconds == outer)
        #expect(budget.attempts == attempts)
        #expect(budget.retryDelay.timeInterval == retry)
    }
}
