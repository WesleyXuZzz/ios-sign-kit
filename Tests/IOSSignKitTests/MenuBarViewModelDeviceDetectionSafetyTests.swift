import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct MenuBarViewModelDeviceDetectionSafetyTests {
    @Test
    func canonicalCompleteUniqueInventoryPersistsCanonicalDeviceIdentity()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: nil
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )

        await fixture.settleRefreshAndSideEffects()

        let persistedConfig = fixture.stateStore.loadConfig()
        #expect(persistedConfig.preferredDeviceID == fixture.device.id)
        #expect(persistedConfig.preferredDeviceName == fixture.device.name)
        let sample = try #require(
            fixture.comparisonRecorder.samples.first
        )
        #expect(sample.rolloutMode == .readOnly)
        #expect(sample.primaryEngine == .canonical)
        #expect(sample.comparisonEngine == .compatibility)
        #expect(sample.sourceCommandCount == 2)
        #expect(fixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(fixture.deviceRunner.devicectlInvocationCount == 1)
        await fixture.shutdown()
    }

    @Test
    func productionCanonicalRecoversUnpinnedTargetFromPersistedCompatibilityConflict()
        async throws
    {
        let productionPolicy = DeviceDetectionRolloutConfiguration(
            processEnvironment: [:]
        ).mode
        let fixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            deviceDetectionRolloutMode: productionPolicy,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected",
            initialDeviceStatus: .scanFailed,
            initialLastDeviceScanSource: "未检测到",
            initialLastDeviceScanFailure:
                "设备来源对同一稳定 ID 的可用状态不一致。"
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )

        await fixture.settleRefreshAndSideEffects()

        let persistedConfig = fixture.stateStore.loadConfig()
        #expect(persistedConfig.preferredDeviceID == fixture.device.id)
        #expect(persistedConfig.preferredDeviceName == fixture.device.name)
        #expect(fixture.viewModel.state.lastDeviceScanSource == "xcdevice")
        #expect(
            fixture.viewModel.state.lastDeviceScanFailure?
                .contains("tunnelState=disconnected") == true
        )
        #expect(
            fixture.viewModel.state.lastDeviceScanFailure?
                .contains("可用状态不一致") != true
        )
        #expect(fixture.comparisonRecorder.samples.isEmpty)
        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        await fixture.shutdown()
    }

    @Test
    func canonicalCompleteCompatibilityNameMatchMigratesToCanonicalDeviceIdentity()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: "Safety iPhone"
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )

        await fixture.settleRefreshAndSideEffects()

        let persistedConfig = fixture.stateStore.loadConfig()
        #expect(persistedConfig.preferredDeviceID == fixture.device.id)
        #expect(persistedConfig.preferredDeviceName == fixture.device.name)
        await fixture.shutdown()
    }

    @Test
    func readOnlyPublishesMatchedTargetWithoutStartingCriticalActions()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture()
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )

        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.viewModel.availableDevices.map(\.id) == [fixture.device.id])
        #expect(fixture.viewModel.matchedDevice == fixture.device)
        #expect(fixture.deviceRunner.devicectlInvocationCount == 1)
        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        let sample = try #require(
            fixture.comparisonRecorder.samples.first
        )
        #expect(sample.rolloutMode == .readOnly)
        #expect(sample.primaryEngine == .canonical)
        #expect(sample.comparisonEngine == .compatibility)
        #expect(sample.primaryDevice.classification == .matched)
        #expect(sample.comparisonDevice.classification == .matched)
        #expect(sample.sourceCommandCount == 2)
        #expect(sample.primaryWork == .verifyAppThenEvaluate)
        #expect(sample.comparisonWork == .fullInteractiveCheck)
        #expect(sample.hasWorkDifference)
        await fixture.shutdown()
    }

    @Test
    func readOnlyRecordsCompatibilityConflictAgainstCanonicalMatchWithoutActions()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )

        await fixture.settleRefreshAndSideEffects()

        let sample = try #require(
            fixture.comparisonRecorder.samples.first
        )
        #expect(sample.rolloutMode == .readOnly)
        #expect(sample.primaryEngine == .canonical)
        #expect(sample.comparisonEngine == .compatibility)
        #expect(sample.primaryDevice.classification == .matched)
        #expect(sample.comparisonDevice.classification == .conflict)
        #expect(sample.hasDeviceDifference)
        #expect(sample.sourceCommandCount == 2)
        #expect(fixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(fixture.deviceRunner.devicectlInvocationCount == 1)
        #expect(fixture.viewModel.matchedDevice?.id == fixture.device.id)
        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        await fixture.shutdown()
    }

    @Test
    func productionCanonicalKeepsXCDeviceMatchWhenWirelessTunnelIsDisconnected()
        async throws
    {
        let productionPolicy = DeviceDetectionRolloutConfiguration(
            processEnvironment: [:]
        ).mode
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: productionPolicy,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected",
            expiryOffset: 3_600
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )

        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.viewModel.state.currentDeviceStatus == .online)
        #expect(fixture.viewModel.state.lastDeviceScanSource == "xcdevice")
        #expect(
            fixture.viewModel.state.lastDeviceScanFailure?
                .contains("tunnelState=disconnected") == true
        )
        #expect(
            fixture.viewModel.state.lastDeviceScanFailure?
                .contains("可用状态不一致") != true
        )
        #expect(fixture.comparisonRecorder.samples.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        await fixture.shutdown()
    }

    @Test
    func shadowPreservesPinnedCompatibilityPrimaryWithoutExtraScanning()
        async throws
    {
        let compatibilityFixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .fallback,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        let shadowFixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .shadow,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        defer {
            compatibilityFixture.viewModel.cancelPendingAutoRefresh()
            compatibilityFixture.viewModel.stopPolling()
            shadowFixture.viewModel.cancelPendingAutoRefresh()
            shadowFixture.viewModel.stopPolling()
        }

        compatibilityFixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )
        shadowFixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )

        await compatibilityFixture.settleRefreshAndSideEffects()
        await shadowFixture.settleRefreshAndSideEffects()

        let sample = try #require(
            shadowFixture.comparisonRecorder.samples.first
        )
        #expect(sample.rolloutMode == .shadow)
        #expect(sample.primaryEngine == .compatibility)
        #expect(sample.comparisonEngine == .canonical)
        #expect(sample.primaryDevice.classification == .matched)
        #expect(sample.comparisonDevice.classification == .matched)
        #expect(sample.sourceCommandCount == 1)
        #expect(!sample.hasDeviceDifference)
        #expect(compatibilityFixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(compatibilityFixture.deviceRunner.devicectlInvocationCount == 0)
        #expect(shadowFixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(shadowFixture.deviceRunner.devicectlInvocationCount == 0)
        #expect(
            shadowFixture.viewModel.availableDevices
                == compatibilityFixture.viewModel.availableDevices
        )
        #expect(
            shadowFixture.viewModel.matchedDevice
                == compatibilityFixture.viewModel.matchedDevice
        )
        #expect(
            shadowFixture.viewModel.state.currentDeviceStatus
                == compatibilityFixture.viewModel.state.currentDeviceStatus
        )
        #expect(
            shadowFixture.actionRecorder.pairCount
                == compatibilityFixture.actionRecorder.pairCount
        )
        #expect(
            shadowFixture.actionRecorder.deployCount
                == compatibilityFixture.actionRecorder.deployCount
        )
        await compatibilityFixture.shutdown()
        await shadowFixture.shutdown()
    }

    @Test
    func shadowPreservesCompatibilityNameBackgroundPrimaryWithoutExtraScanning()
        async throws
    {
        let compatibilityFixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: "Safety iPhone",
            deviceDetectionRolloutMode: .fallback,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        let shadowFixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: "Safety iPhone",
            deviceDetectionRolloutMode: .shadow,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        defer {
            compatibilityFixture.viewModel.cancelPendingAutoRefresh()
            compatibilityFixture.viewModel.stopPolling()
            shadowFixture.viewModel.cancelPendingAutoRefresh()
            shadowFixture.viewModel.stopPolling()
        }

        compatibilityFixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        shadowFixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )

        await compatibilityFixture.settleRefreshAndSideEffects()
        await shadowFixture.settleRefreshAndSideEffects()

        let sample = try #require(
            shadowFixture.comparisonRecorder.samples.first
        )
        #expect(sample.primaryDevice.classification == .matched)
        #expect(sample.comparisonDevice.classification == .matched)
        #expect(sample.sourceCommandCount == 1)
        #expect(!sample.hasDeviceDifference)
        #expect(compatibilityFixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(compatibilityFixture.deviceRunner.devicectlInvocationCount == 0)
        #expect(shadowFixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(shadowFixture.deviceRunner.devicectlInvocationCount == 0)
        #expect(
            shadowFixture.viewModel.availableDevices
                == compatibilityFixture.viewModel.availableDevices
        )
        #expect(
            shadowFixture.viewModel.matchedDevice
                == compatibilityFixture.viewModel.matchedDevice
        )
        #expect(
            shadowFixture.viewModel.state.currentDeviceStatus
                == compatibilityFixture.viewModel.state.currentDeviceStatus
        )
        await compatibilityFixture.shutdown()
        await shadowFixture.shutdown()
    }

    @Test
    func shadowUnconfiguredInventoryUsesCompatibilityPrimaryFromSharedSnapshot()
        async throws
    {
        let compatibilityFixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            deviceDetectionRolloutMode: .fallback,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        let shadowFixture = try DeviceDetectionSafetyFixture(
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            deviceDetectionRolloutMode: .shadow,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        defer {
            compatibilityFixture.viewModel.cancelPendingAutoRefresh()
            compatibilityFixture.viewModel.stopPolling()
            shadowFixture.viewModel.cancelPendingAutoRefresh()
            shadowFixture.viewModel.stopPolling()
        }

        compatibilityFixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )
        shadowFixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )

        await compatibilityFixture.settleRefreshAndSideEffects()
        await shadowFixture.settleRefreshAndSideEffects()

        let sample = try #require(
            shadowFixture.comparisonRecorder.samples.first
        )
        #expect(sample.rolloutMode == .shadow)
        #expect(sample.primaryEngine == .compatibility)
        #expect(sample.comparisonEngine == .canonical)
        #expect(sample.primaryDevice.classification == .conflict)
        #expect(sample.comparisonDevice.classification == .matched)
        #expect(sample.sourceCommandCount == 2)
        #expect(sample.hasDeviceDifference)
        #expect(compatibilityFixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(compatibilityFixture.deviceRunner.devicectlInvocationCount == 1)
        #expect(shadowFixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(shadowFixture.deviceRunner.devicectlInvocationCount == 1)
        #expect(
            shadowFixture.viewModel.availableDevices
                == compatibilityFixture.viewModel.availableDevices
        )
        #expect(
            shadowFixture.viewModel.matchedDevice
                == compatibilityFixture.viewModel.matchedDevice
        )
        #expect(
            shadowFixture.viewModel.config.preferredDeviceID
                == compatibilityFixture.viewModel.config.preferredDeviceID
        )
        #expect(
            shadowFixture.viewModel.state.currentDeviceStatus
                == compatibilityFixture.viewModel.state.currentDeviceStatus
        )
        #expect(
            shadowFixture.actionRecorder.pairCount
                == compatibilityFixture.actionRecorder.pairCount
        )
        #expect(
            shadowFixture.actionRecorder.deployCount
                == compatibilityFixture.actionRecorder.deployCount
        )
        #expect(
            shadowFixture.viewModel.pendingAutoRefreshCountdown
                == compatibilityFixture.viewModel.pendingAutoRefreshCountdown
        )
        await compatibilityFixture.shutdown()
        await shadowFixture.shutdown()
    }

    @Test
    func cancelledShadowRefreshDoesNotRecordStaleComparisonSample()
        async throws
    {
        let commandGate = DeviceDetectionSafetyCommandGate()
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .shadow,
            firstXcdeviceCommandGate: commandGate
        )
        defer {
            commandGate.release()
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )
        try await fixture.deviceRunner.waitForXcdeviceInvocation(1)

        fixture.viewModel.transitionDeviceDetectionRollout(to: .fallback)
        commandGate.release()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.comparisonRecorder.samples.isEmpty)
        #expect(fixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(fixture.deviceRunner.devicectlInvocationCount <= 1)
        #expect(!fixture.viewModel.isReloadingEnvironment)
        await fixture.shutdown()
    }

    @Test
    func repeatedSystemWakeEventsCoalesceIntoOneDelayedPassiveRecheck()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            systemWakeRecheckDelay: .milliseconds(40)
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.handleSystemWake()
        fixture.viewModel.handleSystemWake()
        fixture.viewModel.handleSystemWake()
        await fixture.scheduler.waitUntilScheduled(count: 1)

        fixture.scheduler.advance(by: .milliseconds(40))
        try await fixture.deviceRunner.waitForXcdeviceInvocation(1)
        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.deviceRunner.xcdeviceInvocationCount == 1)
        #expect(fixture.deviceRunner.devicectlInvocationCount == 1)
        #expect(fixture.viewModel.matchedDevice?.id == fixture.device.id)
        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        await fixture.shutdown()
    }

    @Test
    func systemWakeInvalidatesForegroundRefreshAndStillRunsOneDelayedRecheck()
        async throws
    {
        let commandGate = DeviceDetectionSafetyCommandGate()
        let fixture = try DeviceDetectionSafetyFixture(
            systemWakeRecheckDelay: .milliseconds(40),
            firstXcdeviceCommandGate: commandGate
        )
        defer {
            commandGate.release()
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .foreground,
            mode: .manualDeepCheck
        )
        try await fixture.deviceRunner.waitForXcdeviceInvocation(1)

        fixture.viewModel.handleSystemWake()
        await fixture.scheduler.waitUntilScheduled(count: 1)
        fixture.scheduler.advance(by: .milliseconds(40))

        try await fixture.deviceRunner.waitForXcdeviceInvocation(2)
        commandGate.release()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.deviceRunner.xcdeviceInvocationCount == 2)
        #expect(fixture.deviceRunner.devicectlInvocationCount == 1)
        #expect(fixture.viewModel.matchedDevice?.id == fixture.device.id)
        await fixture.shutdown()
    }

    @Test
    func readOnlyTransitionInvalidatesForegroundRefreshWithoutLeavingFlagsStuck()
        async throws
    {
        let commandGate = DeviceDetectionSafetyCommandGate()
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .production,
            firstXcdeviceCommandGate: commandGate
        )
        defer {
            commandGate.release()
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .foreground,
            mode: .manualDeepCheck
        )
        try await fixture.deviceRunner.waitForXcdeviceInvocation(1)

        fixture.viewModel.transitionDeviceDetectionRollout(to: .readOnly)

        #expect(!fixture.viewModel.isReloadingEnvironment)
        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        try await fixture.deviceRunner.waitForXcdeviceInvocation(2)
        commandGate.release()
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.viewModel.matchedDevice?.id == fixture.device.id)
        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        await fixture.shutdown()
    }

    @Test
    func systemWakeCancelsPendingCountdownImmediatelyWithoutStartingDeployment()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            systemWakeRecheckDelay: .seconds(10),
            deviceDetectionRolloutMode: .production
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.scheduler.waitUntilScheduled(count: 1)

        fixture.viewModel.handleSystemWake()

        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(fixture.actionRecorder.deployCount == 0)
        await fixture.shutdown()
    }

    @Test
    func degradedMatchedObservationWithFreshExpiredAppStartsAutomaticCountdown()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .production,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected"
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )
        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.viewModel.matchedDevice?.id == fixture.device.id)
        #expect(fixture.viewModel.state.currentDeviceStatus == "online")
        #expect(fixture.notificationRecorder.notifications.isEmpty)
        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown != nil)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)
        let authorizationEvent = fixture.viewModel.state
            .automaticRefreshEvents.first(where: {
                $0.kind == .authorizationProceeded
            })
        #expect(
            authorizationEvent?.reason
                == .freshVerifiedAppOnExactDevice
        )
        #expect(
            fixture.viewModel.automaticRefreshAuthorizationSummary
                == "已允许：固定设备与过期 App 已在同轮核验"
        )
        await fixture.shutdown()
    }

    @Test
    func freshInconclusiveRecoveryCandidateCanStartControlledPairing()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .production,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected",
            xcdeviceIncludesTarget: false
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )
        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.actionRecorder.pairCount == 1)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.state.currentDeviceStatus != .offline)
        await fixture.shutdown()
    }

    @Test
    func inconclusiveObservationWithoutRecoveryCandidateNeverPairs()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .production,
            devicectlConnectionState: nil,
            devicectlTunnelState: "connecting",
            xcdeviceIncludesTarget: false
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )
        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        #expect(fixture.viewModel.state.currentDeviceStatus != .offline)
        await fixture.shutdown()
    }

    @Test
    func foreignRecoveryCandidateCannotPairConfiguredCanonicalTarget()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            deviceDetectionRolloutMode: .production,
            devicectlConnectionState: nil,
            devicectlTunnelState: "disconnected",
            devicectlUDID: "other-iphone",
            xcdeviceIncludesTarget: false
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .automaticRecoveryCheck
        )
        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.actionRecorder.pairCount == 0)
        #expect(fixture.actionRecorder.deployCount == 0)
        await fixture.shutdown()
    }

    @Test
    func completeTypedDiagnosticsReplaceOldFailureAndPersistSource()
        async throws
    {
        let fixture = try DeviceDetectionSafetyFixture(
            initialLastDeviceScanSource: "失败",
            initialLastDeviceScanFailure: "旧设备检测错误"
        )
        defer {
            fixture.viewModel.cancelPendingAutoRefresh()
            fixture.viewModel.stopPolling()
        }

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )
        await fixture.settleRefreshAndSideEffects()

        #expect(fixture.viewModel.state.lastDeviceScanSource == "xcdevice")
        #expect(fixture.viewModel.state.lastDeviceScanFailure == nil)
        let persistedState = fixture.stateStore.loadState()
        #expect(persistedState.lastDeviceScanSource == "xcdevice")
        #expect(persistedState.lastDeviceScanFailure == nil)
        await fixture.shutdown()
    }
}

@MainActor
private final class DeviceDetectionSafetyFixture {
    let device = DeviceInfo(
        id: "iphone-safety",
        name: "Safety iPhone",
        platform: "com.apple.platform.iphoneos",
        osVersion: "27.0",
        isAvailable: true,
        isPaired: true
    )
    let deviceRunner: DeviceDetectionSafetyCommandRecorder
    let actionRecorder = DeviceDetectionSafetyActionRecorder()
    let notificationRecorder = DeviceDetectionSafetyNotificationRecorder()
    let comparisonRecorder =
        DeviceDetectionSafetyComparisonRecorder()
    let stateStore: RefreshStateStore
    let viewModel: MenuBarViewModel
    let scheduler = ManualRefreshScheduler()

    init(
        systemWakeRecheckDelay: Duration = .seconds(5),
        preferredDeviceID: String? = "iphone-safety",
        preferredDeviceName: String? = "Safety iPhone",
        deviceDetectionRolloutMode: DeviceDetectionRolloutMode =
            .readOnly,
        devicectlConnectionState: String? = "connected",
        devicectlTunnelState: String = "connected",
        devicectlUDID: String = "iphone-safety",
        xcdeviceIncludesTarget: Bool = true,
        initialDeviceStatus: DeviceStatus = .online,
        initialLastDeviceScanSource: String? = nil,
        initialLastDeviceScanFailure: String? = nil,
        firstXcdeviceCommandGate: DeviceDetectionSafetyCommandGate? = nil,
        expiryOffset: TimeInterval = -60
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-device-detection-canonical3-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        let scriptURL = projectURL.appendingPathComponent(
            "scripts/deploy/ios-device.command"
        )
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 1\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let xcodeProjectURL = projectURL.appendingPathComponent(
            "Safety.xcodeproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: xcodeProjectURL,
            withIntermediateDirectories: true
        )

        let bundleID = "com.example.safety"
        let config = AppConfig(
            projectRootPath: projectURL.path,
            deployScriptPath: scriptURL.path,
            xcodeprojPath: xcodeProjectURL.path,
            scheme: "Safety",
            targetName: "Safety",
            bundleID: bundleID,
            preferredDeviceID: preferredDeviceID,
            preferredDeviceName: preferredDeviceName,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .autoRefreshWhenExpired
        )

        var state = AppState.default
        state.currentDeviceStatus = initialDeviceStatus
        state.currentDeviceName = device.name
        state.currentDeviceOS = device.osVersion
        state.lastDeviceSeenAt = Date()
        state.targetAppPresence = .installed
        state.targetAppBundleID = bundleID
        state.targetDeviceID = device.id
        state.lastDetectedExpiryAt = Date().addingTimeInterval(expiryOffset)
        state.expirySource = "test"
        state.isTargetAppExpiryEvidenceVerified = true
        state.lastDeviceScanSource = initialLastDeviceScanSource
        state.lastDeviceScanFailure = initialLastDeviceScanFailure

        stateStore = RefreshStateStore(
            appSupportDirectory: rootURL.appendingPathComponent(
                "State",
                isDirectory: true
            )
        )
        try stateStore.saveConfig(config)
        try stateStore.saveState(state)

        deviceRunner = DeviceDetectionSafetyCommandRecorder(
            devicectlConnectionState: devicectlConnectionState,
            devicectlTunnelState: devicectlTunnelState,
            devicectlUDID: devicectlUDID,
            xcdeviceIncludesTarget: xcdeviceIncludesTarget,
            firstXcdeviceCommandGate: firstXcdeviceCommandGate
        )
        let actionRecorder = self.actionRecorder
        let comparisonRecorder = self.comparisonRecorder
        viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: deviceDetectionRolloutMode,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: deviceDetectionSafetyProjectResolver,
            xcodeDestinationReadinessInspector:
                deviceDetectionSafetyDestinationInspector,
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            deviceConnectionReducer: DeviceConnectionReducer(
                wakeRecheckDelay: systemWakeRecheckDelay
            ),
            deviceDetectionComparisonSink:
                DeviceDetectionComparisonSink(
                    record: comparisonRecorder.record
                ),
            refreshScheduler: scheduler.interface,
            inspectInstalledApp: {
                @Sendable _, inspectedBundleID, _, _ in
                InstalledAppInfo(
                    bundleIdentifier: inspectedBundleID,
                    name: "Safety App",
                    version: "1.0",
                    bundleVersion: "1",
                    appURL:
                        "file:///private/var/containers/Bundle/Application/test/Safety.app",
                    builtByDeveloper: true,
                    installMetadata: AppInstallMetadataSnapshot(
                        schemaVersion: 1,
                        recordedAt: Date().addingTimeInterval(-60),
                        bundleIdentifier: inspectedBundleID,
                        shortVersion: "1.0",
                        buildVersion: "1",
                        expectedExpiryAt:
                            Date().addingTimeInterval(expiryOffset),
                        profileSource: "embedded_mobileprovision"
                    ),
                    installMetadataValidation: .valid
                )
            },
            startDeploy: { _, _, _, _, _ in
                actionRecorder.recordDeploy()
                throw DeployServiceError.missingDeployScript
            },
            pairDevice: { _ in
                actionRecorder.recordPair()
                return .failed("测试中禁止配对")
            },
            notificationService: notificationRecorder
        )
        viewModel.stopPolling()
    }

    func settleRefreshAndSideEffects() async {
        await viewModel.waitForEnvironmentRefreshToSettle()
        await viewModel.waitForPairingToSettle()
    }

    func shutdown() async {
        viewModel.cancelPendingAutoRefresh()
        await viewModel.shutdown()
        scheduler.cancelAll()
    }
}

private var deviceDetectionSafetyProjectResolver: XcodeProjectResolver {
    XcodeProjectResolver { _, arguments, _ in
        if arguments.contains("-list") {
            return CommandResult(
                standardOutput:
                    #"{"project":{"schemes":["Safety"],"targets":["Safety"]}}"#,
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [{
              "target": "Safety",
              "buildSettings": {
                "PRODUCT_TYPE": "com.apple.product-type.application",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.example.safety",
                "PLATFORM_NAME": "iphoneos"
              }
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var deviceDetectionSafetyDestinationInspector:
    XcodeDestinationReadinessInspector
{
    XcodeDestinationReadinessInspector { _, _, _ in
        CommandResult(
            standardOutput: """
            Available destinations:
                { platform:iOS, id:iphone-safety, name:Safety iPhone }
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private final class DeviceDetectionSafetyCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let devicectlConnectionState: String?
    private let devicectlTunnelState: String
    private let devicectlUDID: String
    private let xcdeviceIncludesTarget: Bool
    private let firstXcdeviceCommandGate: DeviceDetectionSafetyCommandGate?
    private var xcdeviceCount = 0
    private var devicectlCount = 0
    private let xcdeviceEvents = TestEventRecorder<Int>()

    init(
        devicectlConnectionState: String? = "connected",
        devicectlTunnelState: String = "connected",
        devicectlUDID: String = "iphone-safety",
        xcdeviceIncludesTarget: Bool = true,
        firstXcdeviceCommandGate: DeviceDetectionSafetyCommandGate? = nil
    ) {
        self.devicectlConnectionState = devicectlConnectionState
        self.devicectlTunnelState = devicectlTunnelState
        self.devicectlUDID = devicectlUDID
        self.xcdeviceIncludesTarget = xcdeviceIncludesTarget
        self.firstXcdeviceCommandGate = firstXcdeviceCommandGate
    }

    var xcdeviceInvocationCount: Int {
        lock.withLock { xcdeviceCount }
    }

    var devicectlInvocationCount: Int {
        lock.withLock { devicectlCount }
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        if arguments.first == "xcdevice" {
            let invocationCount = lock.withLock {
                xcdeviceCount += 1
                return xcdeviceCount
            }
            xcdeviceEvents.record(invocationCount)
            if invocationCount == 1 {
                firstXcdeviceCommandGate?.wait()
            }
            let output = xcdeviceIncludesTarget
                ? """
                  [{
                    "simulator": false,
                    "available": true,
                    "platform": "com.apple.platform.iphoneos",
                    "identifier": "iphone-safety",
                    "name": "Safety iPhone",
                    "modelCode": "iPhone18,1",
                    "modelName": "iPhone",
                    "operatingSystemVersion": "27.0"
                  }]
                  """
                : "[]"
            return CommandResult(
                standardOutput: output,
                standardError: "",
                terminationStatus: 0
            )
        }

        guard arguments.first == "devicectl",
              let outputPath = jsonOutputPath(from: arguments) else {
            return CommandResult(
                standardOutput: "",
                standardError: "Unexpected test command",
                terminationStatus: 1
            )
        }
        lock.withLock {
            devicectlCount += 1
        }
        let connectionStateLine = devicectlConnectionState.map {
            #""connectionState":"\#($0)","#
        } ?? ""
        try """
        {"result":{"devices":[{
          "identifier":"coredevice-canonical3",
          "deviceProperties":{
            "name":"Safety iPhone",
            "osVersionNumber":"27.0",
            "deviceClass":"iPhone",
            "developerModeStatus":"enabled"
          },
          "hardwareProperties":{
            "udid":"\(devicectlUDID)",
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            \(connectionStateLine)
            "pairingState":"paired",
            "tunnelState":"\(devicectlTunnelState)",
            "transportType":"localNetwork"
          }
        }]}}
        """.write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }

    func waitForXcdeviceInvocation(_ count: Int) async throws {
        while try await xcdeviceEvents.next() != count {}
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private final class DeviceDetectionSafetyCommandGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didRelease = false

    func wait() {
        let alreadyReleased = lock.withLock { didRelease }
        guard !alreadyReleased else {
            return
        }
        semaphore.wait()
    }

    func release() {
        let shouldSignal = lock.withLock {
            guard !didRelease else {
                return false
            }
            didRelease = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}

private final class DeviceDetectionSafetyComparisonRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedSamples: [DeviceDetectionComparisonSample] = []

    var samples: [DeviceDetectionComparisonSample] {
        lock.withLock { recordedSamples }
    }

    func record(_ sample: DeviceDetectionComparisonSample) {
        lock.withLock {
            recordedSamples.append(sample)
        }
    }
}

private final class DeviceDetectionSafetyActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pairs = 0
    private var deploys = 0

    var pairCount: Int {
        lock.withLock { pairs }
    }

    var deployCount: Int {
        lock.withLock { deploys }
    }

    func recordPair() {
        lock.withLock {
            pairs += 1
        }
    }

    func recordDeploy() {
        lock.withLock {
            deploys += 1
        }
    }
}

@MainActor
private final class DeviceDetectionSafetyNotificationRecorder:
    NotificationSending
{
    private(set) var notifications: [AppNotification] = []

    func send(
        _ notification: AppNotification
    ) async -> NotificationDeliveryResult {
        notifications.append(notification)
        return .scheduled
    }
}
