import Foundation
import Testing
@testable import IOSSignKit

struct RefreshStateSettlementTests {
    @Test
    func commitPersistsUpdatedState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-state-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let settlement = RefreshStateSettlement(stateStore: store)

        let committed = try settlement.commit(
            currentState: .default,
            recoveringFromPersistenceFailure: false
        ) { state in
            state.lastResult = .success
            state.lastSuccessAt = Date(timeIntervalSinceReferenceDate: 100)
        }

        #expect(store.loadState() == committed)
        #expect(committed.lastResult == .success)
    }

    @Test
    func failedPreparedCommitLeavesPublishedStateUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-state-blocked-write-\(UUID().uuidString)"
            )
        try Data("not-a-directory".utf8).write(to: directory)
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        var publishedState = AppState.default
        var preparedState = publishedState
        preparedState.lastResult = .success
        var didThrow = false

        do {
            publishedState = try settlement.commit(
                proposedState: preparedState,
                recoveringFromPersistenceFailure: false
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(publishedState == .default)
    }

    @Test
    func successfulRecoveryClearsOnlyPersistenceDiagnostic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-state-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let settlement = RefreshStateSettlement(stateStore: store)
        var state = AppState.default
        state.lastErrorSummary = "无法写入运行状态：磁盘暂时不可用"

        let recovered = try settlement.commit(
            currentState: state,
            recoveringFromPersistenceFailure: true
        ) { _ in }

        #expect(recovered.lastErrorSummary == nil)
    }

    @Test
    func recoveryDoesNotHideProcessBlockerDiagnostic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-state-blocker-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let settlement = RefreshStateSettlement(stateStore: store)
        var state = AppState.default
        state.deploymentRecoveryBlocked = true
        state.lastErrorSummary = "无法写入运行状态：仍有遗留部署进程"

        let recovered = try settlement.commit(
            currentState: state,
            recoveringFromPersistenceFailure: true
        ) { _ in }

        #expect(recovered.lastErrorSummary == state.lastErrorSummary)
        #expect(recovered.processRecoveryBlocked)
    }

    @Test
    func deviceObservationUpdatesRelatedFieldsAsOneStateTransition() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-device-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let device = DeviceInfo(
            id: "DEVICE-1",
            name: "测试 iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        let observedAt = Date(timeIntervalSinceReferenceDate: 200)
        var state = AppState.default

        settlement.applyDeviceObservation(
            .init(
                status: .online,
                device: device,
                unavailableDevice: nil,
                detectedExpiryAt: nil,
                expirySource: nil,
                scanResult: nil,
                observationDiagnostics: nil,
                scanFailure: nil,
                diagnosticMessage: nil,
                pairingAttemptAt: observedAt,
                pairingDeviceID: device.id,
                now: observedAt
            ),
            to: &state
        )

        #expect(state.currentDeviceStatus == .online)
        #expect(state.currentDeviceName == device.name)
        #expect(state.lastDeviceSeenAt == observedAt)
        #expect(state.lastPairingAttemptAt == observedAt)
        #expect(state.lastPairingDeviceID == device.id)
    }

    @Test
    func successfulDeploymentSettlementRebindsInstallationEvidence() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-deploy-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let device = DeviceInfo(
            id: "DEVICE-1",
            name: "测试 iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = AppConfig.default
        config.bundleID = "com.example.app"
        let context = DeploymentContext(
            generation: 1,
            config: config,
            device: device,
            deviceDetectionRollout: .init(mode: .production, generation: 1),
            source: .automaticInitial,
            profileRefreshMode: .automatic,
            installationIdentity: .init(state: .default)
        )
        let finishedAt = Date(timeIntervalSinceReferenceDate: 300)
        let result = DeployResult(
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            outcome: .success,
            summary: "完成",
            logPath: nil
        )
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running

        settlement.applyDeploymentResult(
            result,
            context: context,
            isCurrentTarget: true,
            cancellationResult: .cancelled,
            to: &state
        )

        #expect(!state.isDeployRunning)
        #expect(state.lastResult == .success)
        #expect(state.activeInstallationSuccessAt == finishedAt)
        #expect(state.targetDeviceID == device.id)
        #expect(state.targetAppBundleID == config.bundleID)
        #expect(state.isTargetAppExpiryEvidenceVerified)
        #expect(state.automaticRefreshEvents.last?.kind == .settled)
    }

    @Test
    func successfulDeploymentPrefersVerifiedProfileExpirationReceipt() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-verified-expiry-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let device = DeviceInfo(
            id: "DEVICE-1",
            name: "测试 iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = AppConfig.default
        config.bundleID = "com.example.app"
        let context = DeploymentContext(
            generation: 1,
            config: config,
            device: device,
            deviceDetectionRollout: .init(mode: .production, generation: 1),
            source: .manual,
            profileRefreshMode: .automatic,
            installationIdentity: .init(state: .default)
        )
        let finishedAt = Date(timeIntervalSinceReferenceDate: 700)
        let verifiedExpiration = finishedAt.addingTimeInterval(345_600)
        let result = DeployResult(
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            outcome: .success,
            summary: "完成",
            logPath: nil,
            verifiedProfileExpirationDate: verifiedExpiration
        )
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running

        settlement.applyDeploymentResult(
            result,
            context: context,
            isCurrentTarget: true,
            cancellationResult: .cancelled,
            to: &state
        )

        #expect(state.lastDetectedExpiryAt == verifiedExpiration)
        #expect(state.expirySource == .verifiedDeploymentProfile)
        #expect(state.lastExpiryVerifiedAt == finishedAt)
    }

    @Test
    func successfulLegacyDeploymentKeepsDeployTimeEstimateFallback() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-estimated-expiry-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let device = DeviceInfo(
            id: "DEVICE-1",
            name: "测试 iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = AppConfig.default
        config.bundleID = "com.example.app"
        let context = DeploymentContext(
            generation: 1,
            config: config,
            device: device,
            deviceDetectionRollout: .init(mode: .production, generation: 1),
            source: .manual,
            profileRefreshMode: .automatic,
            installationIdentity: .init(state: .default)
        )
        let finishedAt = Date(timeIntervalSinceReferenceDate: 800)
        let result = DeployResult(
            startedAt: finishedAt.addingTimeInterval(-10),
            finishedAt: finishedAt,
            outcome: .success,
            summary: "完成",
            logPath: nil
        )
        var state = AppState.default

        settlement.applyDeploymentResult(
            result,
            context: context,
            isCurrentTarget: true,
            cancellationResult: .cancelled,
            to: &state
        )

        #expect(
            state.lastDetectedExpiryAt
                == PersonalSigningValidity.expiryDate(after: finishedAt)
        )
        #expect(state.expirySource == .deployTimeEstimate)
        #expect(state.lastExpiryVerifiedAt == nil)
    }

    @Test
    func unconfirmedDeploymentTreeUsesBuiltInDeploymentDiagnostic() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-unconfirmed-tree-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let device = DeviceInfo(
            id: "DEVICE-1",
            name: "测试 iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = AppConfig.default
        config.bundleID = "com.example.app"
        let context = DeploymentContext(
            generation: 1,
            config: config,
            device: device,
            deviceDetectionRollout: .init(mode: .production, generation: 1),
            source: .manual,
            profileRefreshMode: .automatic,
            installationIdentity: .init(state: .default)
        )
        let result = DeployResult(
            startedAt: Date(timeIntervalSinceReferenceDate: 900),
            finishedAt: Date(timeIntervalSinceReferenceDate: 910),
            outcome: .failure,
            summary: "失败",
            logPath: "/tmp/deployment.log",
            processGroupTerminationWasConfirmed: false
        )
        var state = AppState.default
        state.isDeployRunning = true

        settlement.applyDeploymentResult(
            result,
            context: context,
            isCurrentTarget: true,
            cancellationResult: .cancelled,
            to: &state
        )

        #expect(state.deploymentRecoveryBlocked)
        #expect(state.lastErrorSummary?.contains("续签部署进程") == true)
        #expect(state.lastErrorSummary?.contains("续签脚本主进程") == false)
    }

    @Test
    func unconfirmedProfileCacheRecoveryKeepsDeploymentTokenAndBlocks() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-unconfirmed-profile-cache-settlement-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let device = DeviceInfo(
            id: "DEVICE-1",
            name: "测试 iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        var config = AppConfig.default
        config.bundleID = "com.example.app"
        let context = DeploymentContext(
            generation: 1,
            config: config,
            device: device,
            deviceDetectionRollout: .init(mode: .production, generation: 1),
            source: .manual,
            profileRefreshMode: .force,
            installationIdentity: .init(state: .default)
        )
        let result = DeployResult(
            startedAt: Date(timeIntervalSinceReferenceDate: 900),
            finishedAt: Date(timeIntervalSinceReferenceDate: 910),
            outcome: .failure,
            summary: "缓存事务提交失败",
            logPath: "/tmp/deployment.log",
            profileCacheRecoveryWasConfirmed: false
        )
        let deploymentToken = DeploymentToken.make().rawValue
        var state = AppState.default
        state.isDeployRunning = true
        state.activeDeployProcessGroupID = 42_433
        state.activeDeploymentToken = deploymentToken

        settlement.applyDeploymentResult(
            result,
            context: context,
            isCurrentTarget: true,
            cancellationResult: .cancelled,
            to: &state
        )

        #expect(!state.isDeployRunning)
        #expect(state.deploymentRecoveryBlocked)
        #expect(state.activeDeployProcessGroupID == nil)
        #expect(state.activeDeploymentToken == deploymentToken)
        #expect(state.lastResult == .interrupted)
        #expect(
            state.lastErrorSummary?
                .contains("签名描述文件缓存事务") == true
        )
        #expect(
            state.lastErrorSummary?
                .contains("完整进程树") == false
        )
    }

    @Test
    func typedEventsCommitDeploymentOwnershipAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-typed-events-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let settlement = RefreshStateSettlement(stateStore: store)
        let startedAt = Date(timeIntervalSinceReferenceDate: 400)

        let commit = try settlement.commit(
            currentState: .default,
            recoveringFromPersistenceFailure: false,
            events: [
                .deploymentStarted(
                    token: "deployment-token",
                    source: .automaticInitial,
                    startedAt: startedAt
                ),
                .deploymentProcessRecorded(
                    processGroupID: 42,
                    token: "deployment-token"
                )
            ]
        )

        #expect(commit.state.isDeployRunning)
        #expect(commit.state.activeDeployProcessGroupID == 42)
        #expect(commit.state.activeDeploymentToken == "deployment-token")
        #expect(commit.state.lastAttemptAt == startedAt)
        #expect(commit.state.lastAutomaticAttemptAt == startedAt)
        #expect(
            commit.state.automaticRefreshEvents.last?.kind
                == .deploymentCommitted
        )
        let persisted = store.loadState()
        #expect(persisted.isDeployRunning)
        #expect(persisted.activeDeployProcessGroupID == 42)
        #expect(persisted.activeDeploymentToken == "deployment-token")
        #expect(persisted.lastAttemptAt == startedAt)
    }

    @Test
    func installationIdentityChangeInvalidatesPreviousExpiryEvidence() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-install-identity-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let inspectedAt = Date(timeIntervalSinceReferenceDate: 500)
        var state = AppState.default
        state.activeInstallationSuccessAt = inspectedAt.addingTimeInterval(-60)
        state.lastDetectedExpiryAt = inspectedAt.addingTimeInterval(3_600)
        state.expirySource = .installMetadata(
            "embedded_mobileprovision"
        )
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.app"
        state.targetDeviceID = "DEVICE-1"
        state.targetAppVersion = "1.0"
        state.targetAppBuildVersion = "1"
        state.targetAppURL =
            "application-container:11111111-1111-1111-1111-111111111111"
        state.isTargetAppExpiryEvidenceVerified = true
        let appInfo = InstalledAppInfo(
            bundleIdentifier: "com.example.app",
            name: "Example",
            version: "1.0",
            bundleVersion: "1",
            appURL:
                "application-container:22222222-2222-2222-2222-222222222222",
            builtByDeveloper: true,
            installMetadata: AppInstallMetadataSnapshot(
                schemaVersion: 1,
                recordedAt: inspectedAt,
                bundleIdentifier: "com.example.app",
                shortVersion: "1.0",
                buildVersion: "1",
                expectedExpiryAt: inspectedAt.addingTimeInterval(3_600),
                profileSource: "embedded_mobileprovision"
            ),
            installMetadataValidation: .valid
        )

        let reduction = settlement.applyInstallationInspection(
            .init(
                outcome: .found(appInfo),
                confirmedAbsent: false,
                inspectedAt: inspectedAt,
                inspectedDeviceID: "DEVICE-1",
                configuredBundleID: "com.example.app",
                unidentifiedEvidenceGracePeriod: 60
            ),
            to: &state
        )

        #expect(!reduction.expiryEvidenceVerified)
        #expect(state.activeInstallationSuccessAt == nil)
        #expect(state.lastDetectedExpiryAt == nil)
        #expect(state.expirySource == nil)
        #expect(
            state.lastAppInspectionFailure
                == "检测到新的 App 安装实例，旧有效期证据已失效。"
        )
    }

    @Test
    func recentDeploymentEvidenceSurvivesMetadataIndexingGracePeriod() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-install-grace-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let deployedAt = Date(timeIntervalSinceReferenceDate: 600)
        var state = AppState.default
        state.activeInstallationSuccessAt = deployedAt
        state.lastDetectedExpiryAt = deployedAt.addingTimeInterval(604_800)
        state.expirySource = .deployTimeEstimate
        state.targetAppPresence = .unknown
        state.targetAppBundleID = "com.example.app"
        state.targetDeviceID = "DEVICE-1"
        state.isTargetAppExpiryEvidenceVerified = true
        let appInfo = InstalledAppInfo(
            bundleIdentifier: "com.example.app",
            name: "Example",
            version: "1.0",
            bundleVersion: "1",
            appURL:
                "application-container:33333333-3333-3333-3333-333333333333",
            builtByDeveloper: true,
            installMetadata: nil,
            installMetadataValidation: .notFound
        )

        let reduction = settlement.applyInstallationInspection(
            .init(
                outcome: .found(appInfo),
                confirmedAbsent: false,
                inspectedAt: deployedAt.addingTimeInterval(10),
                inspectedDeviceID: "DEVICE-1",
                configuredBundleID: "com.example.app",
                unidentifiedEvidenceGracePeriod: 60
            ),
            to: &state
        )

        #expect(reduction.expiryEvidenceVerified)
        #expect(state.isTargetAppExpiryEvidenceVerified)
        #expect(state.lastDetectedExpiryAt != nil)
        #expect(state.expirySource == .deployTimeEstimate)
        #expect(
            reduction.failureMessage
                == "已检测到 App，但安装元数据中没有可用的有效期。"
        )
        #expect(state.lastAppInspectionFailure == reduction.failureMessage)
    }

    @Test
    func hostReceiptIdentityBindsFirstURLAfterGraceAndRejectsURLChange() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-host-receipt-identity-\(UUID().uuidString)",
                isDirectory: true
            )
        let settlement = RefreshStateSettlement(
            stateStore: RefreshStateStore(appSupportDirectory: directory)
        )
        let installedAt = Date(timeIntervalSinceReferenceDate: 700)
        let expiryAt = installedAt.addingTimeInterval(604_800)
        var state = AppState.default
        state.activeInstallationSuccessAt = installedAt
        state.lastDetectedExpiryAt = expiryAt
        state.expirySource = .verifiedDeploymentProfile
        state.lastExpiryVerifiedAt = installedAt
        state.targetAppPresence = .unknown
        state.targetAppBundleID = "com.example.app"
        state.targetDeviceID = "DEVICE-1"
        state.targetAppVersion = "1.2.3"
        state.targetAppBuildVersion = "42"
        state.targetAppURL = nil
        state.isTargetAppExpiryEvidenceVerified = true
        let firstURL =
            "application-container:44444444-4444-4444-4444-444444444444"
        let firstObservation = InstalledAppInfo(
            bundleIdentifier: "com.example.app",
            name: "Example",
            version: "1.2.3",
            bundleVersion: "42",
            appURL: firstURL,
            builtByDeveloper: true,
            installMetadata: nil,
            installMetadataValidation: .notFound
        )

        let firstReduction = settlement.applyInstallationInspection(
            .init(
                outcome: .found(firstObservation),
                confirmedAbsent: false,
                inspectedAt: installedAt.addingTimeInterval(3_600),
                inspectedDeviceID: "DEVICE-1",
                configuredBundleID: "com.example.app",
                unidentifiedEvidenceGracePeriod: 60
            ),
            to: &state
        )

        #expect(firstReduction.expiryEvidenceVerified)
        #expect(state.isTargetAppExpiryEvidenceVerified)
        #expect(state.lastDetectedExpiryAt == expiryAt)
        #expect(state.expirySource == .verifiedDeploymentProfile)
        #expect(state.targetAppURL == firstURL)
        #expect(firstReduction.failureMessage == nil)
        #expect(state.lastAppInspectionFailure == nil)

        var replacement = firstObservation
        replacement.appURL =
            "application-container:55555555-5555-5555-5555-555555555555"
        let replacementReduction = settlement.applyInstallationInspection(
            .init(
                outcome: .found(replacement),
                confirmedAbsent: false,
                inspectedAt: installedAt.addingTimeInterval(3_700),
                inspectedDeviceID: "DEVICE-1",
                configuredBundleID: "com.example.app",
                unidentifiedEvidenceGracePeriod: 60
            ),
            to: &state
        )

        #expect(!replacementReduction.expiryEvidenceVerified)
        #expect(!state.isTargetAppExpiryEvidenceVerified)
        #expect(state.lastDetectedExpiryAt == nil)
        #expect(state.expirySource == nil)
        #expect(state.lastExpiryVerifiedAt == nil)
    }
}
