import Foundation
import Testing
@testable import IOSSignKit

struct BackgroundExpiryBootstrapTests {
    @Test
    @MainActor
    func postDeployInspectionHasAnAbsoluteDeadlineAndRemainsCancellable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-post-deploy-deadline-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "iphone-1"
        try store.saveConfig(config)
        let device = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            inspectInstalledApp: { _, _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return nil
            },
            notificationService: ScheduledNotificationStub(),
            installedAppRetryDelays: [60],
            postDeployInspectionTimeoutSeconds: 0.1
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.matchedDevice = device
        viewModel.availableDevices = [device]
        let now = Date()

        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                outcome: .success,
                summary: "续签已完成。",
                logPath: nil
            ),
            device: device,
            previousExpiry: nil
        )

        #expect(viewModel.state.lastResult == .success)
        #expect(viewModel.deployMessage?.contains("同步真机安装信息超时") == true)
    }

    @Test
    @MainActor
    func postDeployDeadlineDoesNotWaitForNonCooperativeInspector() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-post-deploy-hard-deadline-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "iphone-1"
        try store.saveConfig(config)
        let device = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        let scheduler = ManualRefreshScheduler()
        let blockedInspector = DeferredInspectionGate()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            refreshScheduler: scheduler.interface,
            inspectInstalledApp: { _, _, _, _ in
                await blockedInspector.wait()
                return nil
            },
            notificationService: ScheduledNotificationStub(),
            installedAppRetryDelays: [60],
            postDeployInspectionTimeoutSeconds: 0.1
        )
        viewModel.stopPolling()
        viewModel.matchedDevice = device
        viewModel.availableDevices = [device]
        let startedAt = Date()

        let settlement = Task { @MainActor in
            await viewModel.handleDeployResult(
                DeployResult(
                    startedAt: startedAt.addingTimeInterval(-1),
                    finishedAt: startedAt,
                    outcome: .success,
                    summary: "续签已完成。",
                    logPath: nil
                ),
                device: device,
                previousExpiry: nil
            )
        }
        await blockedInspector.waitUntilStarted()
        await scheduler.waitUntilScheduled(count: 1)
        scheduler.resumeNextSleep()
        await settlement.value

        #expect(await blockedInspector.pendingWaiterCount == 1)
        #expect(viewModel.deployMessage?.contains("同步真机安装信息超时") == true)
        await blockedInspector.release()
        await viewModel.shutdown()
        scheduler.cancelAll()
        #expect(await blockedInspector.pendingWaiterCount == 0)
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    @Test
    @MainActor
    func backgroundPollReconfirmsInstallationBeforeStartingAutomaticRefresh() async throws {
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(expectedExpiryAt: Date().addingTimeInterval(-60))
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: Date().addingTimeInterval(-60),
            autoRefreshPolicy: .autoRefreshWhenExpired
        )
        let viewModel = fixture.makeViewModel()
        defer {
            viewModel.cancelPendingAutoRefresh()
            viewModel.stopPolling()
        }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(recorder.callCount == 1)
        #expect(viewModel.state.targetAppPresence == .installed)
        #expect(viewModel.pendingAutoRefreshCountdown != nil)
    }

    @Test
    @MainActor
    func backgroundPollFetchesAndPersistsExpiryWhenFreshStateHasNoExpiry() async throws {
        let expectedExpiry = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(expectedExpiryAt: expectedExpiry)
        )
        let fixture = try BackgroundExpiryFixture(inspectionRecorder: recorder)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(recorder.callCount == 1)
        #expect(viewModel.matchedDevice?.id == "iphone-1")
        #expect(viewModel.state.currentDeviceStatus == "online")
        #expect(viewModel.expiryInfo?.estimatedExpiryAt == expectedExpiry)
        #expect(viewModel.state.lastDetectedExpiryAt == expectedExpiry)
        #expect(viewModel.state.lastExpiryVerifiedAt != nil)
        #expect(viewModel.state.lastAppInspectionAt != nil)
        #expect(viewModel.state.lastAppInspectionFailure == nil)
        #expect(fixture.stateStore.loadState().lastDetectedExpiryAt == expectedExpiry)
    }

    @Test
    @MainActor
    func backgroundPollRevalidatesInstallationEvenWhenExpiryIsKnown() async throws {
        let knownExpiry = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = InstalledAppInspectionRecorder(appInfo: nil)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: knownExpiry,
            targetAppPresence: .installed
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(recorder.callCount == 1)
        #expect(viewModel.matchedDevice?.id == "iphone-1")
        #expect(viewModel.expiryInfo?.estimatedExpiryAt == knownExpiry)
    }

    @Test
    @MainActor
    func backgroundPollRetriesWhileInstalledAppMetadataHasNoExpiry() async throws {
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(expectedExpiryAt: nil)
        )
        let fixture = try BackgroundExpiryFixture(inspectionRecorder: recorder)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment && recorder.callCount == 1 }

        #expect(viewModel.state.currentDeviceStatus == "online")
        #expect(viewModel.expiryInfo == nil)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment && recorder.callCount == 2 }

        #expect(recorder.callCount == 2)
        #expect(viewModel.state.currentDeviceStatus == "online")
        #expect(viewModel.expiryInfo == nil)
    }

    @Test
    @MainActor
    func appWithoutCurrentMetadataInvalidatesOldMetadataExpiryAndSuppressesActions() async throws {
        let oldExpiry = Date().addingTimeInterval(-60)
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(expectedExpiryAt: nil)
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: oldExpiry,
            autoRefreshPolicy: .autoRefreshWhenExpired,
            installedAppRetryDelays: [60],
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.expirySource = .installMetadata("embedded_mobileprovision")
        state.lastExpiryVerifiedAt = Date().addingTimeInterval(-3_600)
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer {
            viewModel.cancelPendingAutoRefresh()
            viewModel.stopPolling()
        }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(viewModel.state.lastDetectedExpiryAt == nil)
        #expect(viewModel.state.expirySource == nil)
        #expect(viewModel.state.lastExpiryVerifiedAt == nil)
        #expect(viewModel.expiryInfo == nil)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        #expect(fixture.stateStore.loadState().lastDetectedExpiryAt == nil)
    }

    @Test
    @MainActor
    func missingMetadataAutomaticallyRetriesUntilExpiryIsAvailable() async throws {
        let expectedExpiry = Date(timeIntervalSince1970: 1_800_000_800)
        let recorder = InstalledAppInspectionRecorder(
            appInfos: [
                makeInstalledAppInfo(expectedExpiryAt: nil),
                makeInstalledAppInfo(expectedExpiryAt: expectedExpiry)
            ]
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            installedAppRetryDelays: [0.01],
            installedAppRetrySleep: { _ in }
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap(timeout: .seconds(10)) {
            recorder.callCount >= 2 && viewModel.expiryInfo?.estimatedExpiryAt == expectedExpiry
        }

        #expect(viewModel.state.currentDeviceStatus == "online")
        #expect(viewModel.installedAppInspectionFailure == nil)
        #expect(viewModel.state.lastExpiryVerifiedAt != nil)
    }

    @Test
    @MainActor
    func inspectionFailurePreservesOnlineDeviceAndSuppressesAutomaticRefresh() async throws {
        let recorder = InstalledAppInspectionRecorder(appInfo: nil, throwsError: true)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: Date().addingTimeInterval(-60),
            autoRefreshPolicy: .autoRefreshWhenExpired,
            targetAppPresence: .installed
        )
        let viewModel = fixture.makeViewModel()
        defer {
            viewModel.cancelPendingAutoRefresh()
            viewModel.stopPolling()
        }

        let cachedApp = makeInstalledAppInfo(expectedExpiryAt: viewModel.expiryInfo?.estimatedExpiryAt)
        viewModel.installedAppInfo = cachedApp
        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(recorder.callCount == 1)
        #expect(viewModel.matchedDevice?.id == "iphone-1")
        #expect(viewModel.state.currentDeviceStatus == "online")
        #expect(viewModel.installedAppInfo == cachedApp)
        #expect(viewModel.expiryInfo?.estimatedExpiryAt == cachedApp.installMetadata?.expectedExpiryAt)
        #expect(viewModel.installedAppInspectionFailure != nil)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
    }

    @Test
    @MainActor
    func manualDeepCheckAlwaysInspectsInstalledAppWhenExpiryIsKnown() async throws {
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(expectedExpiryAt: Date(timeIntervalSince1970: 1_800_000_500))
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(recorder.callCount == 1)
    }

    @Test
    @MainActor
    func laterInspectionCannotRestoreMetadataFromBeforeLatestDeploy() async throws {
        let deployFinishedAt = Date()
        let deployedEstimate = deployFinishedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let staleMetadataExpiry = deployFinishedAt.addingTimeInterval(24 * 60 * 60)
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(
                expectedExpiryAt: staleMetadataExpiry,
                recordedAt: deployFinishedAt.addingTimeInterval(-60)
            )
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: deployedEstimate,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = deployFinishedAt
        state.activeInstallationSuccessAt = deployFinishedAt
        state.expirySource = .deployTimeEstimate
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(recorder.callCount == 1)
        #expect(abs(
            try #require(viewModel.expiryInfo?.estimatedExpiryAt)
                .timeIntervalSince(deployedEstimate)
        ) < 1.001)
        #expect(viewModel.expiryInfo?.source == .deployTimeEstimate)
        #expect(viewModel.installedAppInspectionFailure?.contains("早于最近一次续签") == true)
        #expect(viewModel.state.lastExpiryVerifiedAt == nil)
    }

    @Test
    @MainActor
    func staleMetadataCannotPreserveUnidentifiedDeploymentEvidenceIndefinitely()
        async throws {
        let deployFinishedAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let deployedEstimate = deployFinishedAt.addingTimeInterval(
            7 * 24 * 60 * 60
        )
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(
                expectedExpiryAt: deployedEstimate,
                recordedAt: deployFinishedAt.addingTimeInterval(-60)
            )
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: deployedEstimate,
            autoRefreshPolicy: .autoRefreshWhenExpired,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = deployFinishedAt
        state.activeInstallationSuccessAt = deployFinishedAt
        state.expirySource = .deployTimeEstimate
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer {
            viewModel.cancelPendingAutoRefresh()
            viewModel.stopPolling()
        }

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        try await waitForExpiryBootstrap {
            !viewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }

        #expect(!viewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(viewModel.expiryInfo == nil)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        #expect(
            viewModel.installedAppInspectionFailure?
                .contains("早于最近一次续签") == true
        )
    }

    @Test
    @MainActor
    func missingMetadataCannotPreserveFullIdentityWithoutActiveDeployment()
        async throws {
        var appInfo = makeInstalledAppInfo(expectedExpiryAt: nil)
        appInfo.installMetadata = nil
        appInfo.installMetadataValidation = .notFound
        let recorder = InstalledAppInspectionRecorder(appInfo: appInfo)
        let oldEstimate = Date().addingTimeInterval(-60)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: oldEstimate,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.activeInstallationSuccessAt = nil
        state.expirySource = .deployTimeEstimate
        state.targetAppVersion = appInfo.version
        state.targetAppBuildVersion = appInfo.bundleVersion
        state.targetAppURL = appInfo.appURL
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !viewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }

        #expect(!viewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(viewModel.expiryInfo == nil)
    }

    @Test(arguments: [TimeInterval(590), TimeInterval(610)])
    @MainActor
    func missingMetadataUsesABoundedUnidentifiedDeploymentGracePeriod(
        elapsedSeconds: TimeInterval
    ) async throws {
        var appInfo = makeInstalledAppInfo(expectedExpiryAt: nil)
        appInfo.installMetadata = nil
        appInfo.installMetadataValidation = .notFound
        let recorder = InstalledAppInspectionRecorder(appInfo: appInfo)
        let deploymentAt = Date().addingTimeInterval(-elapsedSeconds)
        let deployedEstimate = deploymentAt.addingTimeInterval(
            7 * 24 * 60 * 60
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: deployedEstimate,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = deploymentAt
        state.activeInstallationSuccessAt = deploymentAt
        state.expirySource = .deployTimeEstimate
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !viewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }

        let shouldPreserve = elapsedSeconds < 600
        #expect(
            viewModel.state.isTargetAppExpiryEvidenceVerified
                == shouldPreserve
        )
        #expect((viewModel.expiryInfo != nil) == shouldPreserve)
    }

    @Test(arguments: ["matching", "version", "build", "url"])
    @MainActor
    func fullIdentityPreservesOldDeploymentOnlyWhileEveryFieldMatches(
        mismatch: String
    ) async throws {
        var appInfo = makeInstalledAppInfo(expectedExpiryAt: nil)
        appInfo.installMetadata = nil
        appInfo.installMetadataValidation = .notFound
        let recorder = InstalledAppInspectionRecorder(appInfo: appInfo)
        let deploymentAt = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let deployedEstimate = deploymentAt.addingTimeInterval(
            7 * 24 * 60 * 60
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: deployedEstimate,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = deploymentAt
        state.activeInstallationSuccessAt = deploymentAt
        state.lastAutomaticRecoveryFailureAt = deploymentAt
        state.expirySource = .deployTimeEstimate
        state.targetAppVersion =
            mismatch == "version" ? "0.9" : appInfo.version
        state.targetAppBuildVersion =
            mismatch == "build" ? "0" : appInfo.bundleVersion
        state.targetAppURL =
            mismatch == "url"
                ? "file:///private/var/containers/Bundle/Application/"
                    + "00000000-0000-0000-0000-000000000000/Example.app/"
                : appInfo.appURL
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !viewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }

        let shouldPreserve = mismatch == "matching"
        #expect(
            viewModel.state.isTargetAppExpiryEvidenceVerified
                == shouldPreserve
        )
        #expect((viewModel.expiryInfo != nil) == shouldPreserve)
        #expect(
            (viewModel.state.lastAutomaticRecoveryFailureAt != nil)
                == shouldPreserve
        )
    }

    @Test(arguments: [
        InstallMetadataValidation.invalid("invalid metadata"),
        InstallMetadataValidation.unavailable("metadata unavailable")
    ])
    @MainActor
    func untrustedMetadataCannotPreserveDeploymentEvidence(
        validation: InstallMetadataValidation
    ) async throws {
        var appInfo = makeInstalledAppInfo(expectedExpiryAt: nil)
        appInfo.installMetadataValidation = validation
        let recorder = InstalledAppInspectionRecorder(appInfo: appInfo)
        let deploymentAt = Date().addingTimeInterval(-60)
        let deployedEstimate = deploymentAt.addingTimeInterval(
            7 * 24 * 60 * 60
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: deployedEstimate,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = deploymentAt
        state.activeInstallationSuccessAt = deploymentAt
        state.expirySource = .deployTimeEstimate
        state.targetAppVersion = appInfo.version
        state.targetAppBuildVersion = appInfo.bundleVersion
        state.targetAppURL = appInfo.appURL
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }
        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !viewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }

        #expect(!viewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(viewModel.expiryInfo == nil)
    }

    @Test
    @MainActor
    func deploymentGracePersistsFullIdentityAcrossRestart() async throws {
        var appInfo = makeInstalledAppInfo(expectedExpiryAt: nil)
        appInfo.installMetadata = nil
        appInfo.installMetadataValidation = .notFound
        let recorder = InstalledAppInspectionRecorder(appInfo: appInfo)
        let deploymentAt = Date().addingTimeInterval(-60)
        let deployedEstimate = deploymentAt.addingTimeInterval(
            7 * 24 * 60 * 60
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: deployedEstimate,
            targetAppPresence: .installed
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = deploymentAt
        state.activeInstallationSuccessAt = deploymentAt
        state.expirySource = .deployTimeEstimate
        try fixture.stateStore.saveState(state)

        let firstViewModel = fixture.makeViewModel()
        firstViewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !firstViewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }
        #expect(firstViewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(firstViewModel.state.targetAppVersion == appInfo.version)
        #expect(
            firstViewModel.state.targetAppBuildVersion
                == appInfo.bundleVersion
        )
        #expect(firstViewModel.state.targetAppURL != nil)
        firstViewModel.prepareForTermination()

        let restartedViewModel = fixture.makeViewModel()
        defer { restartedViewModel.prepareForTermination() }
        restartedViewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !restartedViewModel.isReloadingEnvironment
                && recorder.callCount == 2
        }

        #expect(restartedViewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(
            abs(
                try #require(
                    restartedViewModel.expiryInfo?.estimatedExpiryAt
                ).timeIntervalSince(deployedEstimate)
            ) < 1.001
        )
    }

    @Test
    @MainActor
    func historicalSuccessDoesNotRejectMetadataForAReinstalledApp() async throws {
        let historicalSuccessAt = Date()
        let metadataRecordedAt = historicalSuccessAt.addingTimeInterval(-60)
        let metadataExpiryAt = historicalSuccessAt.addingTimeInterval(24 * 60 * 60)
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(
                expectedExpiryAt: metadataExpiryAt,
                recordedAt: metadataRecordedAt
            )
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            targetAppPresence: .confirmedNotInstalled
        )
        var state = fixture.stateStore.loadState()
        state.lastSuccessAt = historicalSuccessAt
        state.activeInstallationSuccessAt = nil
        try fixture.stateStore.saveState(state)
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .manualDeepCheck
        )
        try await waitForExpiryBootstrap {
            !viewModel.isReloadingEnvironment
                && recorder.callCount == 1
        }

        #expect(viewModel.state.targetAppPresence == .installed)
        #expect(viewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(viewModel.state.lastAppInspectionFailure == nil)
        #expect(
            viewModel.expiryInfo?.source
                == .installMetadata("embedded_mobileprovision")
        )
        #expect(abs(
            try #require(viewModel.expiryInfo?.estimatedExpiryAt)
                .timeIntervalSince(metadataExpiryAt)
        ) < 1.001)
    }

    @Test
    @MainActor
    func uniqueOnlineDeviceIsAutomaticallyPinned() async throws {
        let recorder = InstalledAppInspectionRecorder(
            appInfo: makeInstalledAppInfo(expectedExpiryAt: Date(timeIntervalSince1970: 1_800_000_500))
        )
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            startsWithPinnedDevice: false
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(viewModel.config.preferredDeviceID == "iphone-1")
        #expect(viewModel.config.preferredDeviceName == "Example iPhone")
        #expect(fixture.stateStore.loadConfig().preferredDeviceID == "iphone-1")
        #expect(viewModel.setupViewModel.selectedDeviceID == "iphone-1")
    }

    @Test
    @MainActor
    func automaticPinFailureFeedbackSurvivesTheSameOnlineSnapshot() async throws {
        let recorder = InstalledAppInspectionRecorder(appInfo: nil)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            startsWithPinnedDevice: false
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }
        try fixture.blockConfigPersistence()

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(viewModel.config.preferredDeviceID == nil)
        #expect(viewModel.setupViewModel.validationMessageContext == .device)
        #expect(
            viewModel.setupViewModel.validationMessage
                .contains("已检测到唯一设备，但自动固定失败")
        )
    }

    @Test
    @MainActor
    func backgroundSnapshotPreservesActiveSetupScanFeedback() async throws {
        let recorder = InstalledAppInspectionRecorder(appInfo: nil)
        let fixture = try BackgroundExpiryFixture(inspectionRecorder: recorder)
        let viewModel = fixture.makeViewModel()
        defer {
            viewModel.setupViewModel.isScanningDevices = false
            viewModel.stopPolling()
        }
        viewModel.setupViewModel.syncDetectedDevices(
            devices: [],
            matchedDevice: nil,
            feedback: .replace("正在扫描可用 iPhone...")
        )
        viewModel.setupViewModel.isScanningDevices = true

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(viewModel.setupViewModel.validationMessageContext == .device)
        #expect(
            viewModel.setupViewModel.validationMessage
                == "正在扫描可用 iPhone..."
        )
    }

    @Test
    @MainActor
    func multipleOnlineDevicesAreNotAutomaticallyPinned() async throws {
        let recorder = InstalledAppInspectionRecorder(appInfo: nil)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            startsWithPinnedDevice: false,
            includesSecondDevice: true
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment }

        #expect(viewModel.availableDevices.count == 2)
        #expect(viewModel.matchedDevice == nil)
        #expect(viewModel.config.preferredDeviceID == nil)
        #expect(fixture.stateStore.loadConfig().preferredDeviceID == nil)
    }

    @Test
    @MainActor
    func installedAppIsClearedOnlyAfterTwoConfirmedAbsences() async throws {
        let knownExpiry = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = InstalledAppInspectionRecorder(appInfo: nil)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: knownExpiry,
            installedAppRetryDelays: [60],
            targetAppPresence: .installed
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.stopPolling() }
        viewModel.state.lastAutomaticRecoveryFailureAt = Date()
        let cachedApp = makeInstalledAppInfo(expectedExpiryAt: knownExpiry)
        viewModel.installedAppInfo = cachedApp

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment && recorder.callCount == 1 }
        #expect(viewModel.installedAppInfo == cachedApp)
        #expect(viewModel.state.targetAppPresence == .confirmingNotInstalled)
        #expect(fixture.stateStore.loadState().targetAppPresence == .confirmingNotInstalled)
        #expect(
            viewModel.state.lastAutomaticRecoveryFailureAt != nil
        )

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap { !viewModel.isReloadingEnvironment && recorder.callCount == 2 }
        #expect(viewModel.installedAppInfo == nil)
        #expect(viewModel.expiryInfo == nil)
        #expect(viewModel.state.targetAppPresence == .confirmedNotInstalled)
        #expect(viewModel.state.lastDetectedExpiryAt == nil)
        #expect(
            viewModel.state.lastAutomaticRecoveryFailureAt == nil
        )
    }

    @Test
    @MainActor
    func firstAbsenceSurvivesRestartAndBlocksAutomaticRefreshUntilReconfirmed() async throws {
        let recorder = InstalledAppInspectionRecorder(appInfo: nil)
        let fixture = try BackgroundExpiryFixture(
            inspectionRecorder: recorder,
            storedExpiry: Date(timeIntervalSince1970: 1),
            autoRefreshPolicy: .autoRefreshWhenExpired,
            installedAppRetryDelays: [60],
            targetAppPresence: .installed
        )
        var firstViewModel: MenuBarViewModel? = fixture.makeViewModel()
        firstViewModel?.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        try await waitForExpiryBootstrap {
            firstViewModel?.isReloadingEnvironment == false && recorder.callCount == 1
        }

        #expect(firstViewModel?.state.targetAppPresence == .confirmingNotInstalled)
        #expect(firstViewModel?.pendingAutoRefreshCountdown == nil)
        firstViewModel?.prepareForTermination()
        firstViewModel = nil

        let restartedViewModel = fixture.makeViewModel()
        defer { restartedViewModel.prepareForTermination() }
        #expect(restartedViewModel.state.targetAppPresence == .confirmingNotInstalled)
        #expect(restartedViewModel.pendingAutoRefreshCountdown == nil)

        restartedViewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await waitForExpiryBootstrap {
            !restartedViewModel.isReloadingEnvironment && recorder.callCount == 2
        }

        #expect(restartedViewModel.state.targetAppPresence == .confirmedNotInstalled)
        #expect(restartedViewModel.expiryInfo == nil)
        #expect(restartedViewModel.pendingAutoRefreshCountdown == nil)
    }
}

@MainActor
private final class BackgroundExpiryFixture {
    let stateStore: RefreshStateStore
    private let appSupportDirectory: URL
    private let deviceRunner: OnlineDeviceCommandRunner
    private let inspectionRecorder: InstalledAppInspectionRecorder
    private let installedAppRetryDelays: [TimeInterval]
    private let installedAppRetrySleep: AsyncSleepHandler

    init(
        inspectionRecorder: InstalledAppInspectionRecorder,
        storedExpiry: Date? = nil,
        autoRefreshPolicy: AutoRefreshPolicy = .reminderOnly,
        installedAppRetryDelays: [TimeInterval] = [5, 30, 120, 600],
        installedAppRetrySleep: @escaping AsyncSleepHandler = {
            try await Task.sleep(for: $0)
        },
        targetAppPresence: TargetAppPresence = .unknown,
        startsWithPinnedDevice: Bool = true,
        includesSecondDevice: Bool = false
    ) throws {
        self.inspectionRecorder = inspectionRecorder
        self.installedAppRetryDelays = installedAppRetryDelays
        self.installedAppRetrySleep = installedAppRetrySleep
        self.deviceRunner = OnlineDeviceCommandRunner(includesSecondDevice: includesSecondDevice)

        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-expiry-bootstrap-tests-\(UUID().uuidString)", isDirectory: true)
        appSupportDirectory = stateDirectory
        stateStore = RefreshStateStore(appSupportDirectory: stateDirectory)
        let projectRoot = stateDirectory.appendingPathComponent("project", isDirectory: true)
        let deployScript = projectRoot
            .appendingPathComponent("scripts/deploy/ios-device.command")
        let xcodeProject = projectRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: deployScript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: xcodeProject,
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(
            to: deployScript,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: deployScript.path
        )

        var config = AppConfig.default
        config.projectRootPath = projectRoot.path
        config.deployScriptPath = deployScript.path
        config.xcodeprojPath = xcodeProject.path
        config.scheme = "App"
        config.targetName = "App"
        config.bundleID = "com.example.App"
        config.preferredDeviceID = startsWithPinnedDevice ? "iphone-1" : nil
        config.preferredDeviceName = startsWithPinnedDevice ? "Example iPhone" : nil
        config.autoRefreshPolicy = autoRefreshPolicy
        try stateStore.saveConfig(config)

        var state = AppState.default
        state.currentDeviceStatus = "offline"
        state.lastDetectedExpiryAt = storedExpiry
        state.expirySource = storedExpiry == nil ? nil : "stored_estimate"
        state.targetAppPresence = targetAppPresence
        state.targetAppBundleID = targetAppPresence == .unknown ? nil : "com.example.App"
        state.targetDeviceID = targetAppPresence == .unknown ? nil : "iphone-1"
        state.isTargetAppExpiryEvidenceVerified = targetAppPresence == .installed
        try stateStore.saveState(state)
    }

    func makeViewModel() -> MenuBarViewModel {
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: backgroundProjectResolver,
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            refreshScheduler: RefreshScheduler(
                wallNow: Date.init,
                sleep: installedAppRetrySleep
            ),
            inspectInstalledApp: inspectionRecorder.inspect,
            notificationService: ScheduledNotificationStub(),
            installedAppRetryDelays: installedAppRetryDelays
        )
        viewModel.stopPolling()
        return viewModel
    }

    func blockConfigPersistence() throws {
        let configURL = appSupportDirectory.appendingPathComponent("config.json")
        let backupURL = appSupportDirectory.appendingPathComponent("config.backup.json")
        try FileManager.default.moveItem(at: configURL, to: backupURL)
        try FileManager.default.createDirectory(
            at: configURL,
            withIntermediateDirectories: false
        )
    }
}

private var backgroundProjectResolver: XcodeProjectResolver {
    XcodeProjectResolver { _, arguments, _ in
        if arguments.contains("-list") {
            return CommandResult(
                standardOutput:
                    #"{"project":{"schemes":["App"],"targets":["App"]}}"#,
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [{
              "target": "App",
              "buildSettings": {
                "PRODUCT_TYPE": "com.apple.product-type.application",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.example.App",
                "PLATFORM_NAME": "iphoneos"
              }
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private final class InstalledAppInspectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var appInfos: [InstalledAppInfo?]
    private let throwsError: Bool
    private var calls = 0

    init(appInfo: InstalledAppInfo?, throwsError: Bool = false) {
        self.appInfos = [appInfo]
        self.throwsError = throwsError
    }

    init(appInfos: [InstalledAppInfo?], throwsError: Bool = false) {
        self.appInfos = appInfos.isEmpty ? [nil] : appInfos
        self.throwsError = throwsError
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func inspect(
        _ device: DeviceInfo,
        _ bundleID: String,
        _ retryCount: Int,
        _ retryDelaySeconds: TimeInterval
    ) throws -> InstalledAppInfo? {
        lock.lock()
        calls += 1
        let appInfo = appInfos.count > 1 ? appInfos.removeFirst() : appInfos[0]
        lock.unlock()

        if throwsError {
            throw ExpiryBootstrapInspectionError.unavailable
        }
        return appInfo
    }
}

private actor DeferredInspectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    var pendingWaiterCount: Int {
        continuation == nil ? 0 : 1
    }

    func wait() async {
        hasStarted = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ExpiryBootstrapInspectionError: Error {
    case unavailable
}

private final class OnlineDeviceCommandRunner: @unchecked Sendable {
    private let includesSecondDevice: Bool

    init(includesSecondDevice: Bool = false) {
        self.includesSecondDevice = includesSecondDevice
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        if arguments.first == "devicectl" {
            guard let outputIndex = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(outputIndex + 1) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "Missing json output path",
                    terminationStatus: 1
                )
            }
            let secondDevice = includesSecondDevice
                ? """
                ,{
                  "identifier": "coredevice-2",
                  "name": "Second iPhone",
                  "available": true,
                  "operatingSystemVersion": "18.5",
                  "deviceProperties": {"name":"Second iPhone","deviceClass":"iPhone"},
                  "hardwareProperties": {"udid":"iphone-2","deviceType":"iPhone"},
                  "connectionProperties": {"pairingState":"paired","connectionState":"connected"}
                }
                """
                : ""
            try """
            {"result":{"devices":[{
              "identifier": "coredevice-1",
              "name": "Example iPhone",
              "available": true,
              "operatingSystemVersion": "18.5",
              "deviceProperties": {"name":"Example iPhone","deviceClass":"iPhone"},
              "hardwareProperties": {"udid":"iphone-1","deviceType":"iPhone"},
              "connectionProperties": {"pairingState":"paired","connectionState":"connected"}
            }\(secondDevice)]}}
            """.write(
                toFile: arguments[outputIndex + 1],
                atomically: true,
                encoding: .utf8
            )
            return CommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        }
        guard arguments.first == "xcdevice" else {
            return CommandResult(standardOutput: "", standardError: "Unexpected command", terminationStatus: 1)
        }

        let secondDevice = includesSecondDevice
            ? """
            ,{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-2",
              "name": "Second iPhone",
              "modelCode": "iPhone16,2",
              "modelName": "iPhone",
              "operatingSystemVersion": "18.5"
            }
            """
            : ""
        return CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-1",
              "name": "Example iPhone",
              "modelCode": "iPhone16,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "18.5"
            }\(secondDevice)]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private func makeInstalledAppInfo(
    expectedExpiryAt: Date?,
    recordedAt: Date = Date()
) -> InstalledAppInfo {
    InstalledAppInfo(
        bundleIdentifier: "com.example.App",
        name: "Example App",
        version: "1.0",
        bundleVersion: "1",
        appURL: "file:///private/var/containers/Bundle/Application/UUID/Example.app/",
        builtByDeveloper: true,
        installMetadata: AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: recordedAt,
            bundleIdentifier: "com.example.App",
            shortVersion: "1.0",
            buildVersion: "1",
            expectedExpiryAt: expectedExpiryAt,
            profileSource: "embedded_mobileprovision"
        ),
        installMetadataValidation: .valid
    )
}
