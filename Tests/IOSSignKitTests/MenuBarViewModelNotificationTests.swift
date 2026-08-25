import Foundation
import Testing
@testable import IOSSignKit

struct MenuBarViewModelNotificationTests {
    @Test(arguments: [
        AutoRefreshPolicy.reminderOnly,
        AutoRefreshPolicy.autoRefreshWhenExpired
    ])
    @MainActor
    func nonDeveloperInstallCannotPromptOrStartAutomaticRefresh(
        policy: AutoRefreshPolicy
    ) async throws {
        let fixture = try NotificationFixture(
            policy: policy,
            scanBehavior: .online,
            appWasBuiltByDeveloper: false
        )
        fixture.viewModel.state.lastAutomaticRecoveryFailureAt = Date()

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(!fixture.viewModel.reminderDecision.shouldPrompt)
        #expect(!fixture.viewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(fixture.viewModel.expiryInfo == nil)
        #expect(fixture.viewModel.state.lastDetectedExpiryAt == nil)
        #expect(fixture.viewModel.state.expirySource == nil)
        #expect(
            fixture.viewModel.state.lastAutomaticRecoveryFailureAt == nil
        )
        let persistedState = fixture.stateStore.loadState()
        #expect(!persistedState.isTargetAppExpiryEvidenceVerified)
        #expect(persistedState.lastDetectedExpiryAt == nil)
        #expect(
            persistedState.lastAppInspectionFailure?
                .contains("不是开发者签名安装") == true
        )
        await fixture.shutdown()
    }

    @Test(arguments: RecoveryBlockKind.allCases)
    @MainActor
    func recoveryBlockSuppressesReminderDelivery(
        recoveryBlock: RecoveryBlockKind
    ) async throws {
        let fixture = try NotificationFixture(
            policy: .reminderOnly,
            scanBehavior: .online,
            recoveryBlock: recoveryBlock
        )

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(!fixture.viewModel.reminderDecision.shouldPrompt)
        #expect(
            fixture.viewModel.reminderDecision.reason
                .contains("已阻止新续签")
        )
        #expect(!fixture.viewModel.canRefreshNow)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func reminderOnlySendsExpiredReminderAndRecordsPromptTime() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.viewModel.waitForReminderDeliveryToSettle()

        #expect(
            fixture.notificationRecorder.notifications
                == [.refreshReminder(reason: fixture.viewModel.reminderDecision.reason, isExpired: true)]
        )
        #expect(fixture.viewModel.state.lastPromptAt != nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func deniedReminderDoesNotStartCooldownAndCanRetry() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.notificationRecorder.deliveryResult = .denied

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.viewModel.waitForReminderDeliveryToSettle()
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        #expect(
            fixture.viewModel.operationFeedbackMessage?
                .contains("权限已关闭") == true
        )

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.viewModel.waitForReminderDeliveryToSettle()
        #expect(fixture.notificationRecorder.notifications.count == 2)
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func concurrentRefreshesShareOneInFlightReminderDelivery() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.notificationRecorder.suspendDelivery = true

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()
        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.count == 1)
        fixture.notificationRecorder.resumeDelivery()
        await fixture.viewModel.waitForReminderDeliveryToSettle()
        #expect(fixture.viewModel.state.lastPromptAt != nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func ineligibleRefreshInvalidatesAnInFlightReminderCooldown() async throws {
        let fixture = try NotificationFixture(
            policy: .reminderOnly,
            scanBehavior: .online
        )
        fixture.notificationRecorder.suspendDelivery = true

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()

        fixture.setScanBehavior(.offline)
        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.viewModel.waitForReminderDeliveryToSettle()
        fixture.notificationRecorder.resumeDelivery()

        #expect(fixture.viewModel.state.lastPromptAt == nil)
        #expect(!fixture.viewModel.reminderDecision.shouldPrompt)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func reminderAcceptedAfterTargetChangeDoesNotCoolDownNewTarget() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.notificationRecorder.suspendDelivery = true

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()
        fixture.viewModel.setupViewModel.bundleID = "com.example.Other"
        fixture.viewModel.setupViewModel.saveSettings()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()
        fixture.notificationRecorder.resumeDelivery()
        await fixture.viewModel.waitForReminderDeliveryToSettle()

        #expect(fixture.viewModel.config.bundleID == "com.example.Other")
        #expect(fixture.viewModel.state.targetAppBundleID == "com.example.Other")
        #expect(fixture.viewModel.state.lastPromptAt != nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func oldDeniedReminderDoesNotOverwriteNewTargetMessage() async throws {
        let fixture = try NotificationFixture(
            policy: .reminderOnly,
            scanBehavior: .online
        )
        fixture.notificationRecorder.suspendDelivery = true
        fixture.notificationRecorder.deliveryResult = .denied

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()
        fixture.viewModel.setupViewModel.bundleID = "com.example.Other"
        fixture.viewModel.setupViewModel.saveSettings()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()
        fixture.notificationRecorder.resumeDelivery()
        await fixture.viewModel.waitForReminderDeliveryToSettle()

        #expect(fixture.viewModel.config.bundleID == "com.example.Other")
        #expect(
            fixture.notificationRecorder.notifications[1]
                == .refreshReminder(
                    reason: fixture.viewModel.reminderDecision.reason,
                    isExpired: true
                )
        )
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func failedReminderSubmissionDoesNotStartCooldown() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.notificationRecorder.deliveryResult = .failed("submission failed")

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.viewModel.waitForReminderDeliveryToSettle()

        #expect(fixture.viewModel.state.lastPromptAt == nil)
        #expect(
            fixture.viewModel.operationFeedbackMessage?
                .contains("submission failed") == true
        )
        await fixture.shutdown()
    }

    @Test(arguments: [true, false])
    @MainActor
    func automaticRefreshCountdownPathsUseAutomaticProfileMode(
        startsImmediately: Bool
    ) async throws {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            usesManualRefreshScheduler: true
        )

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        if startsImmediately {
            fixture.viewModel.startPendingAutoRefreshNow()
        } else {
            await fixture.advanceAutomaticRefreshCountdown()
        }

        _ = try await fixture.notificationRecorder.nextNotification()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(
            fixture.notificationRecorder.notifications
                == [
                    .refreshFailed(
                        summary: "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
                    )
                ]
        )
        #expect(fixture.deployRecorder.wasCalled)
        #expect(fixture.deployRecorder.profileRefreshModes == [.automatic])
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func manualFailureNotifiesWhenSameDeviceIsConfirmedOnline() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.prepareForManualRefresh()

        await fixture.recordManualDeploymentFailure()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()

        #expect(fixture.viewModel.state.lastResult == "failure")
        #expect(
            fixture.viewModel.state.lastErrorSummary
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func cancelledDeployRefreshesDeviceStatusWithoutSendingNotification() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.prepareForManualRefresh()
        let now = Date()

        await fixture.viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                outcome: .cancelled,
                summary: "已取消。",
                logPath: nil
            ),
            device: fixture.device,
            previousExpiry: fixture.viewModel.expiryInfo?.estimatedExpiryAt
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.viewModel.state.lastPromptAt == nil)
        #expect(fixture.viewModel.state.currentDeviceStatus == "online")
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func failureTextContainingCancelledDoesNotChangeTypedOutcome() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.prepareForManualRefresh()
        let now = Date()

        await fixture.viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                outcome: .failure,
                summary: "已取消，但清理失败。",
                logPath: nil
            ),
            device: fixture.device,
            previousExpiry: fixture.viewModel.expiryInfo?.estimatedExpiryAt
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        _ = try await fixture.notificationRecorder.nextNotification()

        #expect(fixture.viewModel.state.lastResult == .failure)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func successfulDeploySendsCompletionNotification() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .online)
        fixture.prepareForManualRefresh()
        fixture.viewModel.config.bundleID = nil
        let now = Date()

        await fixture.viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                isSuccess: true,
                summary: "续签已完成。",
                logPath: nil
            ),
            device: fixture.device,
            previousExpiry: fixture.viewModel.expiryInfo?.estimatedExpiryAt
        )
        _ = try await fixture.notificationRecorder.nextNotification()

        #expect(
            fixture.notificationRecorder.notifications
                == [.refreshSucceeded(deviceName: fixture.device.name)]
        )
        #expect(fixture.viewModel.state.lastResult == "success")
        #expect(fixture.viewModel.state.lastErrorSummary == nil)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func successfulDeploySettlementDoesNotWaitForNotificationDelivery() async throws {
        let fixture = try NotificationFixture(
            policy: .reminderOnly,
            scanBehavior: .online
        )
        fixture.prepareForManualRefresh()
        fixture.viewModel.config.bundleID = nil
        fixture.notificationRecorder.suspendDelivery = true
        let completion = NotificationDeployRecorder()
        let now = Date()

        let settlementTask = Task { @MainActor in
            await fixture.viewModel.handleDeployResult(
                DeployResult(
                    startedAt: now.addingTimeInterval(-1),
                    finishedAt: now,
                    isSuccess: true,
                    summary: "续签已完成。",
                    logPath: nil
                ),
                device: fixture.device,
                previousExpiry:
                    fixture.viewModel.expiryInfo?.estimatedExpiryAt
            )
            completion.record()
        }
        _ = try await fixture.notificationRecorder.nextNotification()
        try await completion.waitUntilRecorded()

        #expect(fixture.viewModel.state.lastResult == .success)
        #expect(completion.wasCalled)
        fixture.notificationRecorder.resumeDelivery()
        await settlementTask.value
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func manualFailureIsSilentWhenTargetDeviceIsOffline() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .offline)
        fixture.prepareForManualRefresh()

        await fixture.recordManualDeploymentFailure()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(
            fixture.viewModel.state.lastErrorSummary
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
        #expect(
            fixture.viewModel.deployMessage
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func manualFailureIsSilentWhenDeviceScanFails() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .failure)
        fixture.prepareForManualRefresh()

        await fixture.recordManualDeploymentFailure()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(
            fixture.viewModel.state.lastErrorSummary
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
        #expect(
            fixture.viewModel.deployMessage
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func manualFailureDoesNotNotifyForDifferentDeviceWithSameName() async throws {
        let fixture = try NotificationFixture(policy: .reminderOnly, scanBehavior: .differentDeviceWithSameName)
        fixture.prepareForManualRefresh()

        await fixture.recordManualDeploymentFailure()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.viewModel.state.currentDeviceStatus == "confirming")
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func tenMinuteAutomaticRefreshWaitsForUnlockWithoutRecordingAttempt()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            deviceIsLocked: true,
            checkIntervalMinutes: 10,
            usesManualRefreshScheduler: true
        )

        fixture.viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        #expect(fixture.notificationRecorder.notifications.isEmpty)

        await fixture.advanceAutomaticRefreshCountdown()
        _ = try await fixture.notificationRecorder.nextNotification()
        await fixture.viewModel.waitForAutomaticUnlockNotificationToSettle()

        #expect(!fixture.deployRecorder.wasCalled)
        #expect(fixture.viewModel.state.isDeployRunning == false)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(fixture.stateStore.loadState().lastAutomaticAttemptAt == nil)
        #expect(fixture.viewModel.state.lastResult != "failure")
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func deniedUnlockNotificationIsVisibleWhileAutomaticRefreshWaits()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            deviceIsLocked: true,
            usesManualRefreshScheduler: true
        )
        fixture.notificationRecorder.deliveryResult = .denied

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        let scheduler = try #require(fixture.manualRefreshScheduler)
        for scheduledCount in 1...5 {
            await scheduler.waitUntilScheduled(count: scheduledCount)
            scheduler.advance(by: .seconds(1))
        }
        await scheduler.waitUntilScheduled(count: 6)
        await fixture.viewModel.waitForDeploymentToStartOrSettle()
        await fixture.viewModel
            .waitForAutomaticUnlockNotificationToSettle()

        #expect(!fixture.deployRecorder.wasCalled)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(
            fixture.viewModel.state.automaticRefreshEvents.last?.kind
                == .notificationDenied
        )
        #expect(
            fixture.viewModel.deployMessage?.contains(
                "系统通知未获授权"
            ) == true
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func automaticRefreshResumesSoonAfterDeviceUnlocks() async throws {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            deviceIsLocked: true,
            usesManualRefreshScheduler: true
        )

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.advanceAutomaticRefreshCountdown()
        _ = try await fixture.notificationRecorder.nextNotification()
        await fixture.viewModel.waitForAutomaticUnlockNotificationToSettle()
        #expect(!fixture.deployRecorder.wasCalled)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)

        fixture.unlockDevice()
        let scheduler = try #require(fixture.manualRefreshScheduler)
        await scheduler.waitUntilScheduled(count: 6)
        scheduler.resumeNextSleep()
        try await fixture.deployRecorder.waitUntilRecorded()

        #expect(fixture.deployRecorder.profileRefreshModes == [.automatic])
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt != nil)
        #expect(fixture.stateStore.loadState().lastAutomaticAttemptAt != nil)
        let eventKinds = fixture.viewModel.state.automaticRefreshEvents
            .map(\.kind)
        #expect(eventKinds.contains(.expiryDetected))
        #expect(eventKinds.contains(.waitingLocked))
        #expect(eventKinds.contains(.unlockObserved))
        #expect(eventKinds.contains(.deploymentCommitted))
        #expect(eventKinds.count <= 50)
        #expect(
            fixture.notificationRecorder.notifications.first
                == .automaticRefreshWaitingForUnlock(
                    deviceName: "Example iPhone"
                )
        )
        #expect(
            fixture.notificationRecorder.notifications.filter {
                $0 == .automaticRefreshWaitingForUnlock(
                    deviceName: "Example iPhone"
                )
            }.count == 1
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func pollWakeAndImmediateCheckShareWaitCoordinatorWithoutDeviceScan()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            deviceIsLocked: true,
            usesManualRefreshScheduler: true
        )
        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.advanceAutomaticRefreshCountdown()
        _ = try await fixture.notificationRecorder.nextNotification()
        let scanCountBeforeWake = fixture.deviceRunner.callCount

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        fixture.viewModel.handleSystemWake()
        fixture.viewModel.reloadEnvironment()
        await fixture.viewModel
            .waitForCurrentAutomaticRefreshWaitProbeToSettle()

        #expect(fixture.deviceRunner.callCount == scanCountBeforeWake)
        #expect(
            fixture.viewModel.state.automaticRefreshEvents
                .map(\.kind).contains(.wakeObserved)
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func reminderPolicyChangeCancelsActiveAutomaticUnlockWait()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            deviceIsLocked: true,
            usesManualRefreshScheduler: true
        )
        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.advanceAutomaticRefreshCountdown()
        _ = try await fixture.notificationRecorder.nextNotification()

        fixture.viewModel.setupViewModel.autoRefreshPolicy = .reminderOnly
        #expect(
            fixture.viewModel.setupViewModel.saveSettings()
        )
        fixture.unlockDevice()

        #expect(!fixture.deployRecorder.wasCalled)
        #expect(
            fixture.viewModel.state.automaticRefreshEvents
                .map(\.kind).contains(.cancelled)
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func installationIdentityChangeCancelsActiveAutomaticUnlockWait()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            deviceIsLocked: true,
            usesManualRefreshScheduler: true
        )
        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.advanceAutomaticRefreshCountdown()
        _ = try await fixture.notificationRecorder.nextNotification()

        fixture.viewModel.state.targetAppURL =
            "file:///changed-installation/Example.app"
        fixture.viewModel.reloadEnvironment()
        await fixture.viewModel
            .waitForCurrentAutomaticRefreshWaitProbeToSettle()

        fixture.unlockDevice()
        #expect(!fixture.deployRecorder.wasCalled)
        #expect(
            fixture.viewModel.state.automaticRefreshEvents
                .map(\.kind).contains(.cancelled)
        )
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func recentAutomaticRecoveryFailureBlocksNewAutomaticCountdown()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online
        )
        fixture.viewModel.state.lastAutomaticAttemptAt = nil
        fixture.viewModel.state.lastAutomaticRecoveryFailureAt = Date()

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(!fixture.deployRecorder.wasCalled)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func configuredFifteenMinuteIntervalOutlastsRecoveryBackoff()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            checkIntervalMinutes: 15,
            expiredCheckIntervalMinutes: 15
        )
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        fixture.viewModel.state.lastAutomaticAttemptAt = nil
        fixture.viewModel.state.lastAutomaticRecoveryFailureAt =
            elevenMinutesAgo

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(!fixture.deployRecorder.wasCalled)
        await fixture.shutdown()
    }

    @Test
    @MainActor
    func expiredCheckIntervalControlsAutomaticAttemptCooldown()
        async throws
    {
        let fixture = try NotificationFixture(
            policy: .autoRefreshWhenExpired,
            scanBehavior: .online,
            checkIntervalMinutes: 15,
            expiredCheckIntervalMinutes: 2
        )
        fixture.viewModel.state.lastAutomaticAttemptAt =
            Date().addingTimeInterval(-3 * 60)
        fixture.viewModel.state.lastAutomaticRecoveryFailureAt = nil

        fixture.viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.viewModel.pendingAutoRefreshCountdown == 5)
        #expect(!fixture.deployRecorder.wasCalled)
        await fixture.shutdown()
    }
}

@MainActor
private final class NotificationFixture {
    let viewModel: MenuBarViewModel
    let notificationRecorder = ViewModelNotificationRecorder()
    let deployRecorder = NotificationDeployRecorder()
    let deviceRunner: NotificationDeviceRunner
    private let lockRunner: NotificationLockRunner
    let stateStore: RefreshStateStore
    let manualRefreshScheduler: ManualRefreshScheduler?
    let device = DeviceInfo(
        id: "iphone-1",
        name: "Example iPhone",
        platform: "com.apple.platform.iphoneos",
        osVersion: "26.5",
        isAvailable: true,
        isPaired: true
    )

    init(
        policy: AutoRefreshPolicy,
        scanBehavior: NotificationScanBehavior,
        deviceIsLocked: Bool = false,
        checkIntervalMinutes: Int = 5,
        expiredCheckIntervalMinutes: Int? = nil,
        recoveryBlock: RecoveryBlockKind? = nil,
        appWasBuiltByDeveloper: Bool = true,
        usesManualRefreshScheduler: Bool = false
    ) throws {
        let manualRefreshScheduler = usesManualRefreshScheduler
            ? ManualRefreshScheduler()
            : nil
        self.manualRefreshScheduler = manualRefreshScheduler
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ios-sign-kit-notification-tests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("Project", isDirectory: true)
        let scriptURL = projectURL.appendingPathComponent("scripts/deploy/ios-device.command")
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 1\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let xcodeProjectURL = projectURL.appendingPathComponent(
            "Example.xcodeproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: xcodeProjectURL,
            withIntermediateDirectories: true
        )

        let config = AppConfig(
            projectRootPath: projectURL.path,
            deployScriptPath: scriptURL.path,
            xcodeprojPath: xcodeProjectURL.path,
            scheme: "Example",
            targetName: "Example",
            bundleID: "com.example.App",
            preferredDeviceID: device.id,
            preferredDeviceName: device.name,
            checkIntervalMinutes: checkIntervalMinutes,
            expiredCheckIntervalMinutes: expiredCheckIntervalMinutes,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: policy
        )

        var state = AppState.default
        state.lastDetectedExpiryAt = Date().addingTimeInterval(-60)
        state.expirySource = "stored_estimate"
        state.currentDeviceStatus = "online"
        state.currentDeviceName = device.name
        state.currentDeviceOS = device.osVersion
        state.lastDeviceSeenAt = Date()
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "iphone-1"
        switch recoveryBlock {
        case .deployment:
            state.deploymentRecoveryBlocked = true
            state.activeDeployProcessGroupID = 42_424
            state.activeDeploymentToken =
                "\(DeploymentProcessRecovery.deploymentTokenPrefix)\(UUID().uuidString)"
            state.lastErrorSummary =
                "无法确认或终止遗留续签，已阻止新续签。"
        case .command:
            state.commandRecoveryBlocked = true
            state.lastErrorSummary =
                "无法确认或终止后台命令，已阻止新续签。"
        case nil:
            break
        }

        stateStore = RefreshStateStore(
            appSupportDirectory:
                rootURL.appendingPathComponent("State")
        )
        try stateStore.saveConfig(config)
        try stateStore.saveState(state)

        deviceRunner = NotificationDeviceRunner(behavior: scanBehavior)
        lockRunner = NotificationLockRunner(isLocked: deviceIsLocked)
        let deployRecorder = self.deployRecorder
        let inspectInstalledApp: InspectInstalledAppHandler = {
            @Sendable _, bundleID, _, _ in
            InstalledAppInfo(
                bundleIdentifier: bundleID,
                name: "Example App",
                version: "1.0",
                bundleVersion: "1",
                appURL: "file:///private/var/containers/Bundle/Application/fixture/Example.app",
                builtByDeveloper: appWasBuiltByDeveloper,
                installMetadata: AppInstallMetadataSnapshot(
                    schemaVersion: 1,
                    recordedAt: Date().addingTimeInterval(-6 * 24 * 60 * 60),
                    bundleIdentifier: bundleID,
                    shortVersion: "1.0",
                    buildVersion: "1",
                    expectedExpiryAt: Date().addingTimeInterval(-60),
                    profileSource: "embedded_mobileprovision"
                ),
                installMetadataValidation: .valid
            )
        }
        let bootstrapper: AppBootstrapper
        if recoveryBlock == .deployment {
            bootstrapper = AppBootstrapper(
                stateStore: stateStore,
                deploymentProcessRecovery: DeploymentProcessRecovery {
                    _, _, _, _ in .unresolved("marker unavailable")
                }
            )
        } else {
            bootstrapper = AppBootstrapper(stateStore: stateStore)
        }
        viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: bootstrapper,
            stateStore: stateStore,
            xcodeProjectResolver: notificationProjectResolver,
            xcodeDestinationReadinessInspector: notificationDestinationInspector,
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            refreshScheduler: manualRefreshScheduler?.interface
                ?? .continuous,
            inspectInstalledApp: inspectInstalledApp,
            deviceLockStateInspector: DeviceLockStateInspector(runCommand: lockRunner.run),
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            },
            notificationService: notificationRecorder
        )
        viewModel.stopPolling()
    }

    func shutdown() async {
        notificationRecorder.resumeDelivery()
        await viewModel.shutdown()
        manualRefreshScheduler?.cancelAll()
        #expect(
            manualRefreshScheduler?.snapshot.pendingSleepCount ?? 0 == 0
        )
        #expect(notificationRecorder.pendingWaiterCount == 0)
    }

    func advanceAutomaticRefreshCountdown(seconds: Int = 5) async {
        guard let manualRefreshScheduler else {
            Issue.record("自动续期倒计时测试缺少手动 scheduler。")
            return
        }
        for scheduledCount in 1...seconds {
            await manualRefreshScheduler.waitUntilScheduled(
                count: scheduledCount
            )
            manualRefreshScheduler.advance(by: .seconds(1))
        }
    }

    func setScanBehavior(_ behavior: NotificationScanBehavior) {
        deviceRunner.setBehavior(behavior)
    }

    func unlockDevice() {
        lockRunner.setLocked(false)
    }

    func prepareForManualRefresh() {
        viewModel.matchedDevice = device
        viewModel.availableDevices = [device]
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: Date().addingTimeInterval(-60),
            source: "test",
            detectedAt: Date(),
            isFallbackValue: false
        )
    }

    func recordManualDeploymentFailure() async {
        let now = Date()
        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                outcome: .failure,
                summary: "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。",
                logPath: nil
            ),
            device: device,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt
        )
    }
}

enum RecoveryBlockKind: CaseIterable, Sendable {
    case deployment
    case command
}

private var notificationProjectResolver: XcodeProjectResolver {
    XcodeProjectResolver { _, arguments, _ in
        if arguments.contains("-list") {
            return CommandResult(
                standardOutput:
                    #"{"project":{"schemes":["Example"],"targets":["Example"]}}"#,
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [
              {
                "target": "Example",
                "buildSettings": {
                  "PRODUCT_TYPE": "com.apple.product-type.application",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.example.App",
                  "PLATFORM_NAME": "iphoneos"
                }
              },
              {
                "target": "Other",
                "buildSettings": {
                  "PRODUCT_TYPE": "com.apple.product-type.application",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Other",
                  "PLATFORM_NAME": "iphoneos"
                }
              }
            ]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var notificationDestinationInspector: XcodeDestinationReadinessInspector {
    XcodeDestinationReadinessInspector { _, _, _ in
        CommandResult(
            standardOutput: """
            Available destinations:
                { platform:iOS, id:iphone-1, name:Example iPhone }
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

@MainActor
private final class ViewModelNotificationRecorder: NotificationSending {
    private(set) var notifications: [AppNotification] = []
    var deliveryResult: NotificationDeliveryResult = .scheduled
    var suspendDelivery = false
    private let notificationEvents = TestEventRecorder<AppNotification>()
    private let deliveryReleaseEvents = TestEventRecorder<Void>()

    func send(_ notification: AppNotification) async -> NotificationDeliveryResult {
        notifications.append(notification)
        notificationEvents.record(notification)
        if suspendDelivery {
            _ = try? await deliveryReleaseEvents.next()
        }
        return deliveryResult
    }

    func nextNotification() async throws -> AppNotification {
        try await notificationEvents.next()
    }

    func resumeDelivery() {
        suspendDelivery = false
        if deliveryReleaseEvents.pendingWaiterCount() > 0 {
            deliveryReleaseEvents.record(())
        }
    }

    var pendingWaiterCount: Int {
        notificationEvents.pendingWaiterCount()
            + deliveryReleaseEvents.pendingWaiterCount()
    }
}

private final class NotificationDeployRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var modes: [ProvisioningProfileRefreshMode] = []
    private let recordedEvents = TestEventRecorder<Void>()

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }

    var profileRefreshModes: [ProvisioningProfileRefreshMode] {
        lock.lock()
        defer { lock.unlock() }
        return modes
    }

    func record(profileRefreshMode: ProvisioningProfileRefreshMode) {
        lock.lock()
        called = true
        modes.append(profileRefreshMode)
        lock.unlock()
        recordedEvents.record(())
    }

    func record() {
        lock.lock()
        called = true
        lock.unlock()
        recordedEvents.record(())
    }

    func waitUntilRecorded() async throws {
        _ = try await recordedEvents.next()
    }
}

private enum NotificationScanBehavior: Equatable, Sendable {
    case online
    case offline
    case failure
    case differentDeviceWithSameName
}

private final class NotificationDeviceRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var behavior: NotificationScanBehavior
    private var recordedCallCount = 0

    init(behavior: NotificationScanBehavior) {
        self.behavior = behavior
    }

    func setBehavior(_ behavior: NotificationScanBehavior) {
        lock.lock()
        self.behavior = behavior
        lock.unlock()
    }

    var callCount: Int {
        lock.withLock { recordedCallCount }
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        lock.withLock {
            recordedCallCount += 1
        }
        let behavior = currentBehavior
        if behavior == .failure {
            return CommandResult(
                standardOutput: "",
                standardError: "设备服务不可用",
                terminationStatus: 1
            )
        }

        if arguments.first == "xcdevice" {
            return CommandResult(
                standardOutput: xcdeviceOutput(for: behavior),
                standardError: "",
                terminationStatus: 0
            )
        }

        guard arguments.first == "devicectl",
              let outputPath = jsonOutputPath(from: arguments) else {
            return CommandResult(standardOutput: "", standardError: "Unexpected command", terminationStatus: 1)
        }

        try deviceCtlOutput(for: behavior).write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
    }

    private var currentBehavior: NotificationScanBehavior {
        lock.lock()
        defer { lock.unlock() }
        return behavior
    }

    private func xcdeviceOutput(
        for behavior: NotificationScanBehavior
    ) -> String {
        let isAvailable = behavior == .online || behavior == .differentDeviceWithSameName
        let identifier = behavior == .differentDeviceWithSameName ? "iphone-2" : "iphone-1"
        return """
        [{
          "simulator": false,
          "available": \(isAvailable),
          "platform": "com.apple.platform.iphoneos",
          "identifier": "\(identifier)",
          "name": "Example iPhone",
          "modelCode": "iPhone17,1",
          "modelName": "iPhone",
          "operatingSystemVersion": "26.5",
          "error": {
            "description": "Browsing on the local network",
            "recoverySuggestion": "Unlock the device or reconnect it."
          }
        }]
        """
    }

    private func deviceCtlOutput(
        for behavior: NotificationScanBehavior
    ) -> String {
        let isAvailable = behavior == .online || behavior == .differentDeviceWithSameName
        let identifier = behavior == .differentDeviceWithSameName ? "iphone-2" : "iphone-1"
        let connectionState = isAvailable ? "connected" : "unavailable"
        return """
        {"result":{"devices":[{
          "identifier":"coredevice-1",
          "deviceProperties":{
            "name":"Example iPhone",
            "osVersionNumber":"26.5",
            "deviceClass":"iPhone",
            "developerModeStatus":"enabled"
          },
          "hardwareProperties":{
            "udid":"\(identifier)",
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            "connectionState":"\(connectionState)",
            "pairingState":"paired",
            "tunnelState":"\(connectionState)"
          }
        }]}}
        """
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private final class NotificationLockRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var isLocked: Bool

    init(isLocked: Bool) {
        self.isLocked = isLocked
    }

    func setLocked(_ isLocked: Bool) {
        lock.withLock {
            self.isLocked = isLocked
        }
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        guard let outputPath = jsonOutputPath(from: arguments) else {
            return CommandResult(standardOutput: "", standardError: "Missing output path", terminationStatus: 1)
        }

        let locked = lock.withLock { isLocked }
        try "{\"result\":{\"locked\":\(locked)}}".write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
