import Darwin
import Foundation
import Testing
@testable import IOSSignKit

struct AppStatePersistenceTests {
    @Test
    func decodesStateWrittenBeforePairingCooldownWasAdded() throws {
        let data = Data(#"{"isDeployRunning":false}"#.utf8)

        let state = try JSONDecoder().decode(AppState.self, from: data)

        #expect(state.lastPairingAttemptAt == nil)
        #expect(state.lastExpiryVerifiedAt == nil)
        #expect(state.lastAppInspectionAt == nil)
        #expect(state.lastAppInspectionFailure == nil)
        #expect(state.isDeployRunning == false)
        #expect(!state.commandRecoveryBlocked)
        #expect(state.targetAppPresence == .unknown)
        #expect(state.targetAppBundleID == nil)
        #expect(state.automaticRefreshEvents.isEmpty)
        #expect(state.lastAutomaticRecoveryFailureAt == nil)
    }

    @Test
    func persistsAutomaticRecoveryFailureBackoffAndAuthorizationReason()
        throws
    {
        let failureAt = Date(timeIntervalSince1970: 1_750_000_000)
        var state = AppState.default
        state.lastAutomaticRecoveryFailureAt = failureAt
        state.appendAutomaticRefreshEvent(
            .authorizationProceeded,
            reason: .freshVerifiedAppOnExactDevice,
            occurredAt: failureAt
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            AppState.self,
            from: encoded
        )

        #expect(decoded.lastAutomaticRecoveryFailureAt == failureAt)
        #expect(
            decoded.automaticRefreshEvents.last?.kind
                == .authorizationProceeded
        )
        #expect(
            decoded.automaticRefreshEvents.last?.reason
                == .freshVerifiedAppOnExactDevice
        )
    }

    @Test
    func automaticRefreshEventTimelineKeepsOnlyLatestFiftyEvents() {
        var state = AppState.default
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        for offset in 0..<55 {
            state.appendAutomaticRefreshEvent(
                offset.isMultiple(of: 2) ? .waitingLocked : .wakeObserved,
                occurredAt: start.addingTimeInterval(TimeInterval(offset))
            )
        }

        #expect(state.automaticRefreshEvents.count == 50)
        #expect(
            state.automaticRefreshEvents.first?.occurredAt
                == start.addingTimeInterval(5)
        )
        #expect(
            state.automaticRefreshEvents.last?.occurredAt
                == start.addingTimeInterval(54)
        )
    }

    @Test
    func preservesUnknownLegacyOperationalValuesAcrossRoundTrip() throws {
        let data = Data(
            #"""
            {
              "lastResult": "future_result",
              "expirySource": "future_expiry_source",
              "currentDeviceStatus": "future_device_status",
              "isDeployRunning": false
            }
            """#.utf8
        )

        let state = try JSONDecoder().decode(AppState.self, from: data)
        #expect(state.lastResult == .unrecognized("future_result"))
        #expect(state.expirySource == .unknown("future_expiry_source"))
        #expect(state.currentDeviceStatus == .unrecognized("future_device_status"))

        let roundTripped = try JSONDecoder().decode(
            AppState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(roundTripped == state)
    }

    @Test
    @MainActor
    func bootstrapRecoversInterruptedDeployment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-bootstrap-state-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.lastAttemptAt = Date()
        try store.saveState(state)

        let result = AppBootstrapper(stateStore: store).bootstrap()
        let persisted = store.loadState()

        #expect(!result.state.isDeployRunning)
        #expect(result.state.lastResult == .interrupted)
        #expect(result.state.lastErrorSummary?.contains("未完成") == true)
        #expect(persisted == result.state)
    }

    @Test
    @MainActor
    func bootstrapBlocksRefreshWhenOrphanRecoveryCannotBeVerified() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-blocked-recovery-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_424
        state.activeDeploymentToken = "\(DeploymentProcessRecovery.deploymentTokenPrefix)\(UUID().uuidString)"
        try store.saveState(state)
        let recovery = DeploymentProcessRecovery { _, _, _, _ in
            .unresolved("permission denied")
        }

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: recovery
        ).bootstrap()

        #expect(!result.state.isDeployRunning)
        #expect(result.state.deploymentRecoveryBlocked)
        #expect(!result.state.commandRecoveryBlocked)
        #expect(result.state.activeDeployProcessGroupID == 42_424)
        #expect(result.state.activeDeploymentToken == state.activeDeploymentToken)
        #expect(result.state.lastErrorSummary?.contains("已阻止新续签") == true)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapRestoresProfileCacheOnlyAfterProcessRecoveryCompletes()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-profile-bootstrap-order-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_430
        state.activeDeploymentToken = deploymentToken
        try store.saveState(state)
        let recorder = BootstrapRecoveryEventRecorder()

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                token, _, _, processGroupID in
                recorder.record("process:\(token):\(processGroupID ?? -1)")
                return .terminated
            },
            deploymentWorkspaceCleanup: { token in
                recorder.record("workspace:\(token)")
            },
            provisioningProfileCacheRecovery: { token in
                recorder.record("profile:\(token)")
            }
        ).bootstrap()

        #expect(
            recorder.events == [
                "process:\(deploymentToken):42430",
                "workspace:\(deploymentToken)",
                "profile:\(deploymentToken)"
            ]
        )
        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeployProcessGroupID == nil)
        #expect(result.state.activeDeploymentToken == nil)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapDoesNotTouchProfileCacheWhenProcessRecoveryIsUnresolved()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-profile-bootstrap-process-blocked-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_431
        state.activeDeploymentToken = deploymentToken
        try store.saveState(state)
        let recorder = BootstrapRecoveryEventRecorder()

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                token, _, _, _ in
                recorder.record("process:\(token)")
                return .unresolved("ownership unavailable")
            },
            deploymentWorkspaceCleanup: { token in
                recorder.record("workspace:\(token)")
            },
            provisioningProfileCacheRecovery: { token in
                recorder.record("profile:\(token)")
            }
        ).bootstrap()

        #expect(recorder.events == ["process:\(deploymentToken)"])
        #expect(result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeployProcessGroupID == 42_431)
        #expect(result.state.activeDeploymentToken == deploymentToken)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapKeepsExactTokenWhenProfileCacheRecoveryFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-profile-bootstrap-failed-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_432
        state.activeDeploymentToken = deploymentToken
        try store.saveState(state)
        let diagnostic = String(repeating: "恢复诊断", count: 2_000)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .notFound
            },
            provisioningProfileCacheRecovery: { _ in
                throw BootstrapProfileRecoveryError.failed(diagnostic)
            }
        ).bootstrap()

        #expect(result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeployProcessGroupID == nil)
        #expect(result.state.activeDeploymentToken == deploymentToken)
        #expect(result.state.lastResult == .interrupted)
        #expect(
            result.state.lastErrorSummary?
                .contains("签名描述文件缓存恢复失败") == true
        )
        #expect(
            result.state.lastErrorSummary?.count
                == DiagnosticText.maximumCharacters + 1
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapDoesNotScanProfileTransactionsWithoutAnExactToken()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-profile-bootstrap-no-token-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        try store.saveState(state)
        let recorder = BootstrapRecoveryEventRecorder()

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .notFound
            },
            deploymentWorkspaceCleanup: { token in
                recorder.record("workspace:\(token)")
            },
            provisioningProfileCacheRecovery: { token in
                recorder.record("profile:\(token)")
            }
        ).bootstrap()

        #expect(recorder.events.isEmpty)
        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeploymentToken == nil)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapRestoresInstalledHostReceiptAfterProfileRecovery()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-installed-host-receipt-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "DEVICE-1"
        try store.saveConfig(config)
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_434
        state.activeDeploymentToken = deploymentToken
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "DEVICE-1"
        try store.saveState(state)
        let receipt = makeHostInstallReceipt(
            deploymentToken: deploymentToken,
            status: .installed
        )
        let recorder = BootstrapRecoveryEventRecorder()

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                token, _, _, _ in
                recorder.record("process:\(token)")
                return .notFound
            },
            deploymentWorkspaceCleanup: { token in
                recorder.record("workspace:\(token)")
            },
            provisioningProfileCacheRecovery: { token in
                recorder.record("profile:\(token)")
            },
            hostInstallReceiptLoader: { token in
                recorder.record("receipt:\(token)")
                return receipt
            }
        ).bootstrap()

        #expect(
            recorder.events == [
                "process:\(deploymentToken)",
                "workspace:\(deploymentToken)",
                "profile:\(deploymentToken)",
                "receipt:\(deploymentToken)"
            ]
        )
        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeploymentToken == nil)
        #expect(result.state.lastResult == .success)
        #expect(result.state.lastSuccessAt == receipt.installedAt)
        #expect(
            result.state.lastDetectedExpiryAt
                == receipt.profileExpirationDate
        )
        #expect(result.state.expirySource == .verifiedDeploymentProfile)
        #expect(result.state.lastExpiryVerifiedAt == receipt.installedAt)
        #expect(result.state.targetAppBundleID == "com.example.App")
        #expect(result.state.targetDeviceID == "DEVICE-1")
        #expect(result.state.targetAppVersion == "1.2.3")
        #expect(result.state.targetAppBuildVersion == "42")
        #expect(result.state.isTargetAppExpiryEvidenceVerified)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func workspaceCleanupFailureWarnsButDoesNotBlockOtherRecovery()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-workspace-cleanup-warning-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "DEVICE-1"
        try store.saveConfig(config)
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_436
        state.activeDeploymentToken = deploymentToken
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "DEVICE-1"
        try store.saveState(state)
        let receipt = makeHostInstallReceipt(
            deploymentToken: deploymentToken,
            status: .installed
        )
        let recorder = BootstrapRecoveryEventRecorder()

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                token, _, _, _ in
                recorder.record("process:\(token)")
                return .notFound
            },
            deploymentWorkspaceCleanup: { token in
                recorder.record("workspace:\(token)")
                throw BootstrapWorkspaceCleanupError.denied
            },
            provisioningProfileCacheRecovery: { token in
                recorder.record("profile:\(token)")
            },
            hostInstallReceiptLoader: { token in
                recorder.record("receipt:\(token)")
                return receipt
            }
        ).bootstrap()

        #expect(
            recorder.events == [
                "process:\(deploymentToken)",
                "workspace:\(deploymentToken)",
                "profile:\(deploymentToken)",
                "receipt:\(deploymentToken)"
            ]
        )
        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeploymentToken == nil)
        #expect(result.state.lastResult == .success)
        #expect(
            result.state.lastErrorSummary?
                .contains("构建缓存目录未能清理") == true
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapTreatsPreparedHostReceiptAsInterrupted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-prepared-host-receipt-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeploymentToken = deploymentToken
        try store.saveState(state)
        let receipt = makeHostInstallReceipt(
            deploymentToken: deploymentToken,
            status: .prepared
        )

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .notFound
            },
            provisioningProfileCacheRecovery: { _ in },
            hostInstallReceiptLoader: { _ in receipt }
        ).bootstrap()

        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeploymentToken == nil)
        #expect(result.state.lastResult == .interrupted)
        #expect(result.state.lastSuccessAt == nil)
        #expect(result.state.expirySource == nil)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapKeepsTokenForInstalledReceiptTargetMismatch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-host-receipt-mismatch-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let deploymentToken = DeploymentToken.make().rawValue
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "DEVICE-1"
        try store.saveConfig(config)
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = 42_435
        state.activeDeploymentToken = deploymentToken
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "DEVICE-1"
        try store.saveState(state)
        let mismatchedReceipt = makeHostInstallReceipt(
            deploymentToken: deploymentToken,
            status: .installed,
            deviceIdentifier: "DEVICE-2"
        )

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .terminated
            },
            provisioningProfileCacheRecovery: { _ in },
            hostInstallReceiptLoader: { _ in mismatchedReceipt }
        ).bootstrap()

        #expect(result.state.deploymentRecoveryBlocked)
        #expect(result.state.activeDeployProcessGroupID == nil)
        #expect(result.state.activeDeploymentToken == deploymentToken)
        #expect(result.state.lastResult == .interrupted)
        #expect(
            result.state.lastErrorSummary?
                .contains("宿主安装回执无法确认") == true
        )
        #expect(
            result.state.lastErrorSummary?
                .contains("设备 ID 与当前项目目标不一致") == true
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapBlocksRefreshWhenOrdinaryCommandRecoveryIsUnresolved()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-command-recovery-blocked-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        try store.saveState(.default)

        let result = AppBootstrapper(
            stateStore: store,
            commandProcessRecoveryOutcome:
                .unresolved("marker unavailable")
        ).bootstrap()

        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.commandRecoveryBlocked)
        #expect(
            result.state.lastErrorSummary?
                .contains("后台命令") == true
        )
        #expect(
            result.state.lastErrorSummary?
                .contains("已阻止新续签") == true
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapRecordsTerminatedOrdinaryCommandWithoutBlocking()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-command-recovery-complete-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        try store.saveState(.default)

        let result = AppBootstrapper(
            stateStore: store,
            commandProcessRecoveryOutcome: .terminated
        ).bootstrap()

        #expect(!result.state.processRecoveryBlocked)
        #expect(
            result.state.lastErrorSummary?
                .contains("后台命令已安全终止") == true
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func missingStateBlocksWhenDeploymentPrefixScanFindsAnOrphan()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-missing-state-deploy-prefix-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentPrefixRecoveryOutcome:
                .unresolved("deployment marker found")
        ).bootstrap()

        #expect(result.state.deploymentRecoveryBlocked)
        #expect(!result.state.commandRecoveryBlocked)
        #expect(result.state.lastResult == .interrupted)
        #expect(
            result.state.lastErrorSummary?
                .contains("缺少精确持久化令牌") == true
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func exactDeploymentRecoveryOverridesPrefixOnlyUncertainty()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-exact-over-prefix-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.isDeployRunning = true
        state.activeDeployProcessGroupID = 42_426
        state.activeDeploymentToken =
            "\(DeploymentProcessRecovery.deploymentTokenPrefix)\(UUID().uuidString)"
        try store.saveState(state)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .terminated
            },
            deploymentPrefixRecoveryOutcome:
                .unresolved("prefix marker found")
        ).bootstrap()

        #expect(!result.state.processRecoveryBlocked)
        #expect(result.state.lastResult == .interrupted)
        #expect(
            result.state.lastErrorSummary?
                .contains("可安全重试") == true
        )
    }

    @Test
    @MainActor
    func persistedCommandRecoveryBlockDoesNotTriggerDeploymentRecovery()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-command-recovery-separated-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.commandRecoveryBlocked = true
        state.lastErrorSummary =
            "无法确认或终止上次退出留下的后台命令，已阻止新续签：marker unavailable"
        try store.saveState(state)
        let recoveryRecorder = RecoveryInvocationRecorder(outcome: .notFound)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery(
                recoverMatchingProcesses: recoveryRecorder.recover
            )
        ).bootstrap()

        #expect(recoveryRecorder.callCount == 0)
        #expect(result.state.commandRecoveryBlocked)
        #expect(!result.state.deploymentRecoveryBlocked)
    }

    @Test
    @MainActor
    func successfulGlobalCommandScanClearsPersistedCommandBlock()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-command-recovery-cleared-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.commandRecoveryBlocked = true
        state.lastErrorSummary =
            "无法确认或终止上次退出留下的后台命令，已阻止新续签：marker unavailable"
        try store.saveState(state)

        let result = AppBootstrapper(
            stateStore: store,
            commandProcessRecoveryOutcome: .notFound
        ).bootstrap()

        #expect(!result.state.processRecoveryBlocked)
        #expect(
            result.state.lastErrorSummary?
                .contains("可安全继续") == true
        )
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func terminatedOrdinaryCommandDoesNotHideUnresolvedDeployment()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-recovery-priority-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.isDeployRunning = true
        state.activeDeployProcessGroupID = 42_425
        state.activeDeploymentToken =
            "\(DeploymentProcessRecovery.deploymentTokenPrefix)\(UUID().uuidString)"
        try store.saveState(state)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .unresolved("deployment marker unavailable")
            },
            commandProcessRecoveryOutcome: .terminated
        ).bootstrap()

        #expect(result.state.deploymentRecoveryBlocked)
        #expect(!result.state.commandRecoveryBlocked)
        #expect(
            result.state.lastErrorSummary?
                .contains("遗留续签") == true
        )
        #expect(
            result.state.lastErrorSummary?
                .contains("后台命令已安全终止") == false
        )
    }

    @Test
    @MainActor
    func terminatedOrdinaryCommandDoesNotHideCorruptStateRecovery()
        throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-corrupt-state-priority-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("{broken-json".utf8).write(
            to: directory.appendingPathComponent("state.json"),
            options: .atomic
        )
        let store = RefreshStateStore(appSupportDirectory: directory)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery {
                _, _, _, _ in .notFound
            },
            commandProcessRecoveryOutcome: .terminated
        ).bootstrap()

        #expect(!result.state.processRecoveryBlocked)
        #expect(
            result.state.lastErrorSummary?
                .contains("状态文件已损坏") == true
        )
        #expect(
            result.state.lastErrorSummary?
                .contains("后台命令已安全终止") == false
        )
    }

    @Test
    @MainActor
    func normalExitPreservesBlockedOrphanEvidenceForNextLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-preserve-blocked-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.lastResult = .interrupted
        state.deploymentRecoveryBlocked = true
        state.activeDeployProcessGroupID = 42_425
        state.activeDeploymentToken = "\(DeploymentProcessRecovery.deploymentTokenPrefix)\(UUID().uuidString)"
        state.lastErrorSummary = "已阻止新续签"
        try store.saveState(state)
        let recovery = DeploymentProcessRecovery { _, _, _, _ in
            .unresolved("still running")
        }
        let bootstrapper = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: recovery
        )
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: bootstrapper,
            stateStore: store
        )

        viewModel.prepareForTermination()
        let persistedAfterExit = store.loadState()
        let restarted = bootstrapper.bootstrap()

        #expect(persistedAfterExit.deploymentRecoveryBlocked)
        #expect(persistedAfterExit.activeDeployProcessGroupID == 42_425)
        #expect(persistedAfterExit.activeDeploymentToken == state.activeDeploymentToken)
        #expect(restarted.state.deploymentRecoveryBlocked)
        #expect(restarted.state.activeDeployProcessGroupID == 42_425)
        #expect(restarted.state.activeDeploymentToken == state.activeDeploymentToken)
    }

    @Test
    @MainActor
    func bootstrapScansForOrphansWhenStateFileIsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-corrupt-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{broken-json".utf8).write(
            to: directory.appendingPathComponent("state.json"),
            options: .atomic
        )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let recoveryRecorder = RecoveryInvocationRecorder(outcome: .notFound)

        let result = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery(
                recoverMatchingProcesses: recoveryRecorder.recover
            )
        ).bootstrap()

        #expect(recoveryRecorder.callCount == 1)
        #expect(!result.state.deploymentRecoveryBlocked)
        #expect(result.state.lastResult == .interrupted)
        #expect(result.state.lastErrorSummary?.contains("状态文件已损坏") == true)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapInvalidatesInstallationEvidenceForDifferentBundleID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-bundle-migration-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.bundleID = "com.example.NewApp"
        try store.saveConfig(config)

        var state = AppState.default
        state.lastSuccessAt = Date()
        state.lastDetectedExpiryAt = Date().addingTimeInterval(24 * 60 * 60)
        state.expirySource = .installMetadata("embedded_mobileprovision")
        state.lastExpiryVerifiedAt = Date()
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.OldApp"
        try store.saveState(state)

        let result = AppBootstrapper(stateStore: store).bootstrap()

        #expect(result.state.lastSuccessAt == nil)
        #expect(result.state.lastDetectedExpiryAt == nil)
        #expect(result.state.expirySource == nil)
        #expect(result.state.targetAppPresence == .unknown)
        #expect(result.state.targetAppBundleID == nil)
        #expect(store.loadState() == result.state)
    }

    @Test
    @MainActor
    func bootstrapRequiresLegacyInstalledStateToBeReconfirmed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-legacy-installation-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        try store.saveConfig(config)

        var state = AppState.default
        state.targetAppPresence = .installed
        state.targetAppBundleID = nil
        state.lastDetectedExpiryAt = Date().addingTimeInterval(60)
        try store.saveState(state)

        let result = AppBootstrapper(stateStore: store).bootstrap()

        #expect(result.state.targetAppPresence == .unknown)
        #expect(result.state.lastDetectedExpiryAt == nil)
    }

    @Test
    @MainActor
    func bootstrapInvalidatesExpiryAndReminderCooldownForDifferentDevice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-device-identity-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "iphone-b"
        try store.saveConfig(config)

        var state = AppState.default
        state.lastSuccessAt = Date()
        state.lastPromptAt = Date()
        state.lastAutomaticRecoveryFailureAt = Date()
        state.lastDetectedExpiryAt = Date().addingTimeInterval(60)
        state.expirySource = .deployTimeEstimate
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "iphone-a"
        try store.saveState(state)

        let result = AppBootstrapper(stateStore: store).bootstrap()

        #expect(result.state.lastSuccessAt == nil)
        #expect(result.state.lastPromptAt == nil)
        #expect(result.state.lastAutomaticRecoveryFailureAt == nil)
        #expect(result.state.lastDetectedExpiryAt == nil)
        #expect(result.state.targetAppPresence == .unknown)
        #expect(result.state.targetDeviceID == nil)
    }

    @Test
    @MainActor
    func bootstrapTerminatesVerifiedOrphanedDeploymentProcessGroup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-orphan-recovery-\(UUID().uuidString)", isDirectory: true)
        let deploymentToken = DeploymentToken.make().rawValue
        let command = try CommandRunner().start(
            "/bin/sleep",
            arguments: ["30"],
            environmentOverrides: [
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                    deploymentToken
            ]
        )

        let store = RefreshStateStore(appSupportDirectory: directory.appendingPathComponent("state"))
        var state = AppState.default
        state.isDeployRunning = true
        state.lastResult = .running
        state.activeDeployProcessGroupID = command.processGroupIdentifier
        state.activeDeploymentToken = deploymentToken
        try store.saveState(state)

        let processList = CommandResult(
            standardOutput: """
            \(command.processGroupIdentifier) \(command.processGroupIdentifier) /bin/sleep 30 \(deploymentToken)
            """,
            standardError: "",
            terminationStatus: 0
        )
        let recovered = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery(
                processListProvider: { processList }
            )
        ).bootstrap()
        _ = command.waitUntilExit(timeoutSeconds: 3)

        #expect(recovered.state.lastResult == .interrupted)
        #expect(recovered.state.lastErrorSummary?.contains("遗留续签进程已终止") == true)
        errno = 0
        #expect(kill(-command.processGroupIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    @MainActor
    func interruptedStateWriteInvalidatesPreviouslyInstalledEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-state-transaction-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "iphone-1"
        state.lastDetectedExpiryAt = Date().addingTimeInterval(-60)
        state.expirySource = .installMetadata("embedded_mobileprovision")
        try store.saveState(state)
        try Data("pending".utf8).write(
            to: directory.appendingPathComponent(".state-write-in-progress")
        )

        let recovered = AppBootstrapper(
            stateStore: store,
            deploymentProcessRecovery: DeploymentProcessRecovery(
                recoverMatchingProcesses: { _, _, _, _ in .notFound }
            )
        ).bootstrap()

        #expect(recovered.state.targetAppPresence == .unknown)
        #expect(recovered.state.lastDetectedExpiryAt == nil)
        #expect(recovered.state.lastResult == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".state-write-in-progress").path
            )
        )
    }
}

private final class RecoveryInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: DeploymentProcessRecoveryOutcome
    private var calls = 0

    init(outcome: DeploymentProcessRecoveryOutcome) {
        self.outcome = outcome
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recover(
        _ token: String,
        _ acceptsPrefix: Bool,
        _ shouldTerminate: Bool,
        _ processGroupID: Int32?
    ) -> DeploymentProcessRecoveryOutcome {
        lock.lock()
        calls += 1
        lock.unlock()
        return outcome
    }
}

private final class BootstrapRecoveryEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: String) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private enum BootstrapProfileRecoveryError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let diagnostic):
            return diagnostic
        }
    }
}

private enum BootstrapWorkspaceCleanupError: LocalizedError {
    case denied

    var errorDescription: String? {
        "permission denied"
    }
}

private func makeHostInstallReceipt(
    deploymentToken: String,
    status: HostInstallReceiptStatus,
    bundleIdentifier: String = "com.example.App",
    deviceIdentifier: String = "DEVICE-1"
) -> HostInstallReceipt {
    let preparedAt = Date(timeIntervalSince1970: 1_787_000_000)
    return HostInstallReceipt(
        schemaVersion: HostInstallReceipt.schemaVersion,
        deploymentToken: deploymentToken,
        bundleIdentifier: bundleIdentifier,
        deviceIdentifier: deviceIdentifier,
        teamIdentifier: "ABCDE12345",
        shortVersion: "1.2.3",
        buildVersion: "42",
        profileUUID: "3D4C69C7-798A-43FB-A7BB-A7E2DD80F5AB",
        profileDigest: String(repeating: "a", count: 64),
        profileExpirationDate:
            preparedAt.addingTimeInterval(7 * 24 * 60 * 60),
        preparedAt: preparedAt,
        status: status,
        installedAt: status == .installed
            ? preparedAt.addingTimeInterval(30)
            : nil
    )
}
