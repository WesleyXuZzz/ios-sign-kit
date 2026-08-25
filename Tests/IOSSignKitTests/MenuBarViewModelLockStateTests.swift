import Foundation
import Testing
@testable import IOSSignKit

struct MenuBarViewModelLockStateTests {
    @Test
    @MainActor
    func refreshPreflightShowsActionableMessageWhenTargetDeviceGoesOffline() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: offlineDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            }
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]

        viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .automatic
        )
        for _ in 0..<600
            where viewModel.canCancelRefresh || viewModel.isReloadingEnvironment {
            try await Task.sleep(for: .milliseconds(10))
        }

        let expectedMessage =
            "未检测到目标 iPhone“Example iPhone”，请连接并解锁设备后重试。"
        #expect(!viewModel.canCancelRefresh)
        #expect(!viewModel.isReloadingEnvironment)
        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.deployMessage == expectedMessage)
        #expect(viewModel.operationFeedbackMessage == expectedMessage)
        #expect(viewModel.operationActivityPresentation.detail == expectedMessage)
    }

    @Test
    @MainActor
    func genericFeedbackDoesNotReuseHistoricalDeploymentFailure() throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector
        )
        viewModel.stopPolling()
        viewModel.state.lastResult = .failure
        viewModel.state.lastErrorSummary = "旧续签签名失败。"

        viewModel.deployMessage = "更新启动自启失败：没有权限。"

        #expect(viewModel.operationActivityPresentation.kind == .info)
        #expect(viewModel.operationActivityPresentation.actions == .dismiss)
        #expect(
            viewModel.operationActivityPresentation.detail
                == "更新启动自启失败：没有权限。"
        )
    }

    @Test
    @MainActor
    func cancellingDuringLockPreflightReleasesRefreshLock() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                usleep(250_000)
                return CommandResult(
                    standardOutput: "",
                    standardError: "delayed lock check",
                    terminationStatus: 1
                )
            },
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        try await Task.sleep(for: .milliseconds(30))
        viewModel.cancelRefresh()
        try await Task.sleep(for: .milliseconds(300))

        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.canRefreshNow)
        #expect(!viewModel.state.isDeployRunning)
        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.deployMessage == "已取消本次续签。")
    }

    @Test
    @MainActor
    func reloadDuringActivePreflightKeepsProgressAndCancelActionVisible() throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        #expect(viewModel.canCancelRefresh)
        let progressBeforeReload = viewModel.deployProgressText

        viewModel.reloadEnvironment()

        #expect(viewModel.deployProgressText == progressBeforeReload)
        #expect(viewModel.canCancelRefresh)
        viewModel.cancelRefresh()
    }

    @Test
    @MainActor
    func deploymentTokenIsPersistedBeforeProcessSpawn() async throws {
        let stateStore = try makeTemporaryStateStore()
        let transactionRecorder = DeployTransactionRecorder(stateStore: stateStore)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                CommandResult(standardOutput: "", standardError: "unavailable", terminationStatus: 1)
            },
            startDeploy: { _, _, deploymentToken, _, _ in
                transactionRecorder.record(token: deploymentToken)
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        for _ in 0..<50 where transactionRecorder.snapshot == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let snapshot = try #require(transactionRecorder.snapshot)
        #expect(snapshot.persistedState.isDeployRunning)
        #expect(snapshot.persistedState.activeDeployProcessGroupID == nil)
        #expect(snapshot.persistedState.activeDeploymentToken == snapshot.token)
        #expect(snapshot.token.hasPrefix(DeploymentProcessRecovery.deploymentTokenPrefix))
    }

    @Test
    @MainActor
    func successfulDeployStartsAbsenceConfirmationForNewInstallInstance() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-new-install-absence-\(UUID().uuidString)", isDirectory: true)
        var config = readyConfig
        config.projectRootPath = rootURL.path
        config.deployScriptPath = nil
        config.xcodeprojPath = rootURL.appendingPathComponent("App.xcodeproj").path
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        let stateStore = RefreshStateStore(
            appSupportDirectory: rootURL.appendingPathComponent("state")
        )
        try stateStore.saveConfig(config)
        var initialState = AppState.default
        initialState.lastDetectedExpiryAt = Date().addingTimeInterval(-60)
        initialState.expirySource = .storedEstimate
        initialState.targetAppPresence = .confirmingNotInstalled
        initialState.targetAppBundleID = config.bundleID
        initialState.targetDeviceID = exampleDevice.id
        try stateStore.saveState(initialState)
        let inspectionRecorder = NilInspectionRecorder()
        let logStore = LogStore(
            logsDirectoryURL: rootURL.appendingPathComponent("logs")
        )
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: inspectionRecorder.inspect,
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                CommandResult(standardOutput: "", standardError: "unavailable", terminationStatus: 1)
            },
            startDeploy: { _, target, deploymentToken, _, _ in
                let command = try CommandRunner().start(
                    "/usr/bin/true",
                    arguments: [],
                    environmentOverrides: [
                        DeploymentProcessRecovery
                            .deploymentTokenEnvironmentKey: deploymentToken
                    ]
                )
                return RunningDeploy(
                    startedAt: Date(),
                    command: command,
                    deploymentToken: deploymentToken,
                    targetDeviceID: target.device.id,
                    logStore: logStore
                )
            },
            installedAppRetryDelays: [0.01],
            postDeployInspectionTimeoutSeconds: 0.1
        )
        defer { viewModel.prepareForTermination() }
        viewModel.stopPolling()
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]

        viewModel.refreshNow()
        viewModel.confirmManualRefresh(profileRefreshMode: .force)
        for _ in 0..<300 {
            if viewModel.state.lastResult == .success,
               viewModel.state.targetAppPresence == .confirmingNotInstalled,
               inspectionRecorder.callCount >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.state.lastResult == .success)
        #expect(viewModel.state.targetAppPresence == .confirmingNotInstalled)
        #expect(viewModel.state.lastDetectedExpiryAt != nil)
        #expect(inspectionRecorder.callCount >= 2)
    }

    @Test
    @MainActor
    func targetChangeDuringLockPreflightStopsBeforeDeployStarts() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: DeviceLockStateInspector(runCommand: { _, _, _ in
                usleep(250_000)
                return CommandResult(
                    standardOutput: "",
                    standardError: "delayed lock check",
                    terminationStatus: 1
                )
            }),
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        try await Task.sleep(for: .milliseconds(30))
        viewModel.setupViewModel.bundleID = "com.example.changed"
        viewModel.setupViewModel.saveSettings()
        try await Task.sleep(for: .milliseconds(350))

        #expect(!deployRecorder.wasCalled)
        #expect(!viewModel.state.isDeployRunning)
    }

    @Test
    @MainActor
    func deploymentFinishingAfterTargetConfigChangeCannotPolluteNewTarget() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-deploy-generation-\(UUID().uuidString)", isDirectory: true)
        var config = readyConfig
        config.projectRootPath = rootURL.path
        config.deployScriptPath = nil
        config.xcodeprojPath = rootURL.appendingPathComponent("App.xcodeproj").path
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        config.bundleID = "com.example.old"
        config.targetName = "OldApp"
        let store = RefreshStateStore(appSupportDirectory: rootURL.appendingPathComponent("state"))
        try store.saveConfig(config)
        let logStore = LogStore(
            logsDirectoryURL: rootURL.appendingPathComponent("logs")
        )
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                CommandResult(standardOutput: "", standardError: "unavailable", terminationStatus: 1)
            },
            startDeploy: { _, target, deploymentToken, _, _ in
                let command = try CommandRunner().start(
                    "/bin/sleep",
                    arguments: ["0.2"],
                    environmentOverrides: [
                        DeploymentProcessRecovery
                            .deploymentTokenEnvironmentKey: deploymentToken
                    ]
                )
                return RunningDeploy(
                    startedAt: Date(),
                    command: command,
                    deploymentToken: deploymentToken,
                    targetDeviceID: target.device.id,
                    logStore: logStore
                )
            },
            notificationService: LockStateNotificationRecorder()
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        for _ in 0..<100 where viewModel.state.activeDeployProcessGroupID == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.state.activeDeployProcessGroupID != nil)
        viewModel.setupViewModel.bundleID = "com.example.new"
        viewModel.setupViewModel.targetName = "NewApp"
        viewModel.setupViewModel.saveSettings()

        for _ in 0..<100 where viewModel.deployMessage?.contains("目标配置已变更") != true {
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(viewModel.config.bundleID == "com.example.new")
        #expect(viewModel.state.lastResult == nil)
        #expect(viewModel.state.lastSuccessAt == nil)
        #expect(viewModel.state.lastDetectedExpiryAt == nil)
        #expect(viewModel.state.targetAppBundleID == nil)
        #expect(viewModel.deployMessage?.contains("目标配置已变更") == true)
        #expect(viewModel.deployMessage?.contains("脚本") == false)
    }

    @Test
    @MainActor
    func manualRefreshDoesNotStartDeployWhenDeviceIsLocked() async throws {
        let stateStore = try makeTemporaryStateStore()
        let device = exampleDevice
        let deployRecorder = DeployCallRecorder()
        let notificationRecorder = LockStateNotificationRecorder()
        let lockRunner = ScriptedViewModelLockStateCommandRunner(responses: [
            .init(
                result: .success(),
                outputFileContents: viewModelCoreDeviceLockStateJSON(
                    passcodeRequired: true
                )
            )
        ])
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: DeviceLockStateInspector(runCommand: lockRunner.run),
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: notificationRecorder
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = device
        viewModel.availableDevices = [device]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        #expect(viewModel.expiryStatusTone == .critical)
        viewModel.refreshNow()

        for _ in 0..<40
            where viewModel.deployMessage != "请解锁 iPhone 后再续签。"
                || notificationRecorder.notifications.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(viewModel.deployMessage == "请解锁 iPhone 后再续签。")
        #expect(viewModel.state.isDeployRunning == false)
        #expect(deployRecorder.wasCalled == false)
        #expect(
            notificationRecorder.notifications
                == [.manualRefreshBlockedByLock(deviceName: device.name)]
        )
        #expect(viewModel.menuBarPresentation.state == .waitingForUnlock)
        #expect(viewModel.menuBarPresentation.title == "待解锁")
        #expect(
            viewModel.statusMenuHeaderPresentation.headline
                == "请解锁 iPhone"
        )
    }

    @Test
    @MainActor
    func manualRefreshContinuesWhenLockStateIsUnknown() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let lockRunner = ScriptedViewModelLockStateCommandRunner(responses: [
            .init(result: .failure(stderr: "CoreDevice unavailable"))
        ])
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: DeviceLockStateInspector(runCommand: lockRunner.run),
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()

        for _ in 0..<20 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(deployRecorder.wasCalled)
        #expect(
            viewModel.state.lastErrorSummary
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
        #expect(viewModel.state.isDeployRunning == false)
    }

    @Test(arguments: [
        ProvisioningProfileRefreshMode.force,
        ProvisioningProfileRefreshMode.automatic
    ])
    @MainActor
    func manualRefreshBeforeExpiryUsesSelectedProfileMode(
        profileRefreshMode: ProvisioningProfileRefreshMode
    ) async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiryAt = now.addingTimeInterval(60 * 60)
        let lockRunner = ScriptedViewModelLockStateCommandRunner(responses: [
            .init(result: .failure(stderr: "CoreDevice unavailable"))
        ])
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            deviceLockStateInspector: DeviceLockStateInspector(runCommand: lockRunner.run),
            startDeploy: { _, _, _, actualMode, _ in
                deployRecorder.record(profileRefreshMode: actualMode)
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(at: expiryAt)
        markInstallationVerified(in: viewModel)

        #expect(viewModel.manualRefreshActionTitle == "立即续签")
        let requestOutcome = viewModel.refreshNow()

        #expect(requestOutcome == .profileChoiceRequired)
        #expect(viewModel.manualRefreshPrompt?.reason == .notExpired(expiryAt))
        #expect(!deployRecorder.wasCalled)
        #expect(
            viewModel.manualRefreshPromptMessage.contains(
                absoluteDateTimeStringForTest(expiryAt)
            )
        )
        #expect(viewModel.manualRefreshPromptMessage.contains("不保证延长"))

        viewModel.confirmManualRefresh(
            profileRefreshMode: profileRefreshMode
        )
        for _ in 0..<20 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(deployRecorder.wasCalled)
        #expect(deployRecorder.profileRefreshModes == [profileRefreshMode])
        #expect(viewModel.manualRefreshPrompt == nil)
    }

    @Test(arguments: [
        ProvisioningProfileRefreshMode.force,
        ProvisioningProfileRefreshMode.automatic
    ])
    @MainActor
    func lanControlRefreshBeforeExpiryUsesWebSelectedProfileMode(
        profileRefreshMode: ProvisioningProfileRefreshMode
    ) async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiryAt = now.addingTimeInterval(60 * 60)
        let lockRunner = ScriptedViewModelLockStateCommandRunner(responses: [
            .init(result: .failure(stderr: "CoreDevice unavailable"))
        ])
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            deviceLockStateInspector: DeviceLockStateInspector(runCommand: lockRunner.run),
            startDeploy: { _, _, _, actualMode, _ in
                deployRecorder.record(profileRefreshMode: actualMode)
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(at: expiryAt)
        markInstallationVerified(in: viewModel)

        let choiceOutcome = viewModel.requestLANControlRenewal(
            profileRefreshMode: nil
        )

        #expect(!choiceOutcome.accepted)
        #expect(choiceOutcome.requiresProfileChoice)
        #expect(choiceOutcome.message.contains(absoluteDateTimeStringForTest(expiryAt)))
        #expect(viewModel.manualRefreshPrompt == nil)
        #expect(!deployRecorder.wasCalled)

        let renewalOutcome = viewModel.requestLANControlRenewal(
            profileRefreshMode: profileRefreshMode
        )
        for _ in 0..<20 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(renewalOutcome.accepted)
        #expect(!renewalOutcome.requiresProfileChoice)
        #expect(deployRecorder.profileRefreshModes == [profileRefreshMode])
        #expect(viewModel.manualRefreshPrompt == nil)
    }

    @Test(arguments: [
        ProvisioningProfileRefreshMode.force,
        ProvisioningProfileRefreshMode.automatic
    ])
    @MainActor
    func taskBarUsesExactProfileRefreshModeCopy(
        profileRefreshMode: ProvisioningProfileRefreshMode
    ) throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor
        )
        defer {
            viewModel.cancelRefresh()
            viewModel.stopPolling()
        }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        let expectedCopy = profileRefreshMode == .force
            ? "正在更新签名描述文件…"
            : "正在优先复用现有签名描述文件…"

        viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: profileRefreshMode
        )

        #expect(viewModel.deployProgressText == expectedCopy)
        #expect(viewModel.operationActivityPresentation.detail == expectedCopy)
    }

    @Test
    @MainActor
    func manualRefreshAtExactExpiryForcesProfileUpdate() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                CommandResult(
                    standardOutput: "",
                    standardError: "unavailable",
                    terminationStatus: 1
                )
            },
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(at: now)
        markInstallationVerified(in: viewModel)

        #expect(viewModel.manualRefreshActionTitle == "立即续签")
        let requestOutcome = viewModel.refreshNow()

        #expect(requestOutcome == .deploymentRequested)
        for _ in 0..<20 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(viewModel.manualRefreshPrompt == nil)
        #expect(deployRecorder.profileRefreshModes == [.force])
    }

    @Test
    @MainActor
    func cancellingManualProfileChoiceDoesNotStartDeploy() throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(
            at: now.addingTimeInterval(60 * 60)
        )
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()

        #expect(viewModel.manualRefreshPrompt != nil)
        #expect(!deployRecorder.wasCalled)

        viewModel.cancelManualRefreshProfileChoice()
        #expect(viewModel.manualRefreshPrompt == nil)
        #expect(!deployRecorder.wasCalled)
    }

    @Test
    @MainActor
    func manualRefreshWithUnknownExpiryRequiresProfileChoice() throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = nil
        markInstallationVerified(in: viewModel)
        viewModel.state.isTargetAppExpiryEvidenceVerified = false

        #expect(viewModel.expiryStatusTone == .warning)
        viewModel.refreshNow()

        #expect(viewModel.manualRefreshPrompt?.reason == .expiryUnknown)
        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.manualRefreshPromptMessage.contains("无法确认 App 的到期时间"))
    }

    @Test
    @MainActor
    func manualRefreshWithUnconfirmedInstallationRequiresProfileChoice() throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)

        viewModel.refreshNow()

        #expect(viewModel.manualRefreshPrompt?.reason == .installationUnconfirmed)
        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.manualRefreshPromptMessage.contains("尚未确认目标 App 的安装状态"))
    }

    @Test
    @MainActor
    func automaticProfileChoiceUpgradesToForceWhenAppExpiresWhilePromptIsOpen() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let expiryAt = now.addingTimeInterval(60)
        let clock = ManualRefreshTestClock(now: now)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { clock.now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                CommandResult(
                    standardOutput: "",
                    standardError: "unavailable",
                    terminationStatus: 1
                )
            },
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(at: expiryAt)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        #expect(viewModel.manualRefreshPrompt?.reason == .notExpired(expiryAt))

        clock.setNow(expiryAt)
        viewModel.confirmManualRefresh(profileRefreshMode: .automatic)
        for _ in 0..<20 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(deployRecorder.profileRefreshModes == [.force])
    }

    @Test
    @MainActor
    func pendingManualProfileChoiceIsCancelledAfterTargetChanges() throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            }
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(
            at: now.addingTimeInterval(60 * 60)
        )
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        #expect(viewModel.manualRefreshPrompt != nil)

        viewModel.setupViewModel.bundleID = "com.example.changed"
        viewModel.setupViewModel.saveSettings()
        #expect(viewModel.manualRefreshPrompt == nil)
        viewModel.confirmManualRefresh(profileRefreshMode: .force)

        #expect(viewModel.manualRefreshPrompt == nil)
        #expect(!deployRecorder.wasCalled)
    }

    @Test
    @MainActor
    func pendingManualProfileChoiceIsRejectedAfterInstallationStateChanges() throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            refreshScheduler: RefreshScheduler(
                wallNow: { now },
                sleep: RefreshScheduler.continuous.sleep
            ),
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(
            at: now.addingTimeInterval(60 * 60)
        )
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        #expect(viewModel.manualRefreshPrompt?.reason == .notExpired(
            now.addingTimeInterval(60 * 60)
        ))

        viewModel.state.targetAppPresence = .confirmedNotInstalled
        viewModel.confirmManualRefresh(profileRefreshMode: .automatic)

        #expect(viewModel.manualRefreshPrompt == nil)
        #expect(!viewModel.canCancelRefresh)
        #expect(!deployRecorder.wasCalled)
        #expect(
            viewModel.deployMessage
                == "设备或安装状态已变化，请重新选择“立即续签”。"
        )
    }

    @Test
    @MainActor
    func currentFailureRetryReevaluatesManualProfileChoice() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let expiryAt = Date().addingTimeInterval(60 * 60)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: { _, bundleID, _, _ in
                matchingInstalledAppInfo(
                    bundleID: bundleID,
                    expectedExpiryAt: expiryAt
                )
            },
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.state = .default
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(at: expiryAt)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: Date().addingTimeInterval(-1),
                finishedAt: Date(),
                outcome: .failure,
                summary: "签名失败，请重试。",
                logPath: nil
            ),
            device: exampleDevice,
            previousExpiry: expiryAt
        )
        for _ in 0..<200
            where viewModel.isReloadingEnvironment
                || viewModel.operationActivityPresentation.actions != .retry {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.operationActivityPresentation.actions == .retry)

        let requestOutcome = viewModel.refreshNow()
        #expect(requestOutcome == .profileChoiceRequired)
        #expect(viewModel.manualRefreshPrompt?.reason == .expiryUnknown)
        #expect(!deployRecorder.wasCalled)

        viewModel.confirmManualRefresh(profileRefreshMode: .automatic)
        for _ in 0..<100 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.profileRefreshModes == [.automatic])
    }

    @Test
    @MainActor
    func automaticRefreshStopsWhenDestinationReadinessIsUnknown() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(
                .unknown("destination probe failed")
            ),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
        for _ in 0..<100 where viewModel.canCancelRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!deployRecorder.wasCalled)
        #expect(!viewModel.state.isDeployRunning)
        #expect(viewModel.deployMessage?.contains("自动续期已停止") == true)
        #expect(viewModel.deployMessage?.contains("destination probe failed") == true)
        #expect(
            viewModel.operationFeedbackMessage
                == viewModel.deployMessage
        )
        #expect(
            viewModel.menuBarPresentation.state
                == .refreshResult(.failed)
        )
        #expect(
            viewModel.statusMenuHeaderPresentation.headline
                == "续签失败"
        )
        #expect(
            viewModel.statusMenuHeaderPresentation.detail
                .contains("destination probe failed")
        )
    }

    @Test
    @MainActor
    func automaticRefreshWaitsWhenDeviceLockStateIsUnknown() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unknownDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
        for _ in 0..<100
            where viewModel.deployProgressText
                != "等待确认 iPhone 已解锁" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(
            viewModel.deployProgressText == "等待确认 iPhone 已解锁"
        )
        #expect(
            viewModel.deployMessage?.contains(
                "CoreDevice 锁屏状态查询失败"
            ) == true
        )
    }

    @Test
    @MainActor
    func automaticRefreshStopsForUnsupportedLockStateSchema() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unsupportedSchemaDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
        for _ in 0..<100
            where viewModel.deployProgressText != "自动续期已跳过" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(viewModel.deployProgressText == "自动续期已跳过")
        #expect(
            viewModel.deployMessage?.contains(
                "CoreDevice 锁屏状态格式暂不受支持"
            ) == true
        )
    }

    @Test
    @MainActor
    func automaticRefreshStopsIfDeviceRelocksBeforeCommit() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let lockRunner = ScriptedViewModelLockStateCommandRunner(
            responses: [
                .init(
                    result: .success(),
                    outputFileContents: viewModelCoreDeviceLockStateJSON(
                        passcodeRequired: false
                    )
                ),
                .init(
                    result: .success(),
                    outputFileContents: viewModelCoreDeviceLockStateJSON(
                        passcodeRequired: true
                    )
                ),
            ]
        )
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: matchingInstalledAppInspector,
            deviceLockStateInspector: DeviceLockStateInspector(
                runCommand: lockRunner.run
            ),
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
        for _ in 0..<200
            where viewModel.deployProgressText != "等待 iPhone 解锁" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!deployRecorder.wasCalled)
        #expect(viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(viewModel.deployProgressText == "等待 iPhone 解锁")
    }

    @Test
    @MainActor
    func manualRefreshMayContinueWhenDestinationReadinessIsUnknown() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(
                .unknown("destination probe failed")
            ),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.refreshNow()
        for _ in 0..<100 where !deployRecorder.wasCalled {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.wasCalled)
        #expect(
            viewModel.state.lastErrorSummary
                == "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
        )
    }

    @Test
    @MainActor
    func automaticPreparationFailureSchedulesOnlyOneRecoveryAttempt() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let notifications = LockStateNotificationRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: matchingInstalledAppInspector,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(profileRefreshMode: profileRefreshMode)
                throw DeployServiceError.missingDeployScript
            },
            notificationService: notifications,
            deployRecoveryDelaySeconds: 0.02
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<100 where deployRecorder.callCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(deployRecorder.callCount == 1)
        #expect(deployRecorder.profileRefreshModes == [.automatic])
        #expect(notifications.notifications == [
            .automaticRefreshWaitingForUnlock(
                deviceName: exampleDevice.name
            ),
            .refreshFailed(
                summary: "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
            )
        ])
    }

    @Test
    @MainActor
    func automaticRecoveryFailureRecordsBackoffAndSettlement()
        async throws
    {
        let stateStore = try makeTemporaryStateStore()
        let notifications = LockStateNotificationRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                throw DeployServiceError.missingDeployScript
            },
            notificationService: notifications
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticRecovery
        )

        #expect(viewModel.state.lastAutomaticRecoveryFailureAt != nil)
        #expect(
            viewModel.state.automaticRefreshEvents.last?.kind
                == .settled
        )
        #expect(notifications.notifications.isEmpty)
        let persisted = stateStore.loadState()
        #expect(persisted.lastAutomaticRecoveryFailureAt != nil)
        #expect(persisted.automaticRefreshEvents.last?.kind == .settled)
    }

    @Test
    @MainActor
    func canonicalAutomaticRecoveryKeepsTrustedMatchForTunnelUncertainty()
        async throws
    {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let productionPolicy = DeviceDetectionRolloutConfiguration(
            processEnvironment: [:]
        ).mode
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: productionPolicy,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: transportUncertainDeviceMonitor,
            inspectInstalledApp: matchingInstalledAppInspector,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, profileRefreshMode, _ in
                deployRecorder.record(
                    profileRefreshMode: profileRefreshMode
                )
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.01
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<300
            where deployRecorder.callCount == 0
                && viewModel.canCancelRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 1)
        #expect(deployRecorder.profileRefreshModes == [.automatic])
    }

    @Test
    @MainActor
    func overlappingBackgroundRefreshCannotConsumeTheOnlyRecoveryAttempt() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let scanRunner = DelayedFirstViewModelDeviceScanRunner()
        let expectedExpiryAt = Date().addingTimeInterval(-60)
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: DeviceMonitor(runCommandAsync: scanRunner.run),
            inspectInstalledApp: { _, bundleID, _, _ in
                matchingInstalledAppInfo(
                    bundleID: bundleID,
                    expectedExpiryAt: expectedExpiryAt
                )
            },
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.05
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: expectedExpiryAt,
            source: "test",
            detectedAt: Date(),
            isFallbackValue: false
        )
        markInstallationVerified(in: viewModel)
        viewModel.state.targetAppVersion = "1.0"
        viewModel.state.targetAppBuildVersion = "1"
        viewModel.state.targetAppURL = "/Example.app"

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        #expect(viewModel.isReloadingEnvironment)

        for _ in 0..<100 where deployRecorder.callCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        if deployRecorder.callCount == 0 {
            Issue.record("恢复未启动：message=\(viewModel.deployMessage ?? "nil")；progress=\(viewModel.deployProgressText ?? "nil")；canRefresh=\(viewModel.canRefreshNow)；scanCalls=\(scanRunner.totalInvocationCount)")
        }
        #expect(deployRecorder.callCount == 1)
        #expect(scanRunner.cancelledInvocationCount == 0)
        #expect(!viewModel.canCancelRefresh)
    }

    @Test
    @MainActor
    func overlappingRefreshThatLosesInstallationEvidenceStopsRecovery() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let scanRunner = DelayedFirstViewModelDeviceScanRunner()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: DeviceMonitor(runCommandAsync: scanRunner.run),
            inspectInstalledApp: { _, _, _, _ in nil },
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.05
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )

        for _ in 0..<200
            where viewModel.canCancelRefresh
                || viewModel.state.targetAppPresence == .installed {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        #expect(viewModel.state.targetAppPresence != .installed)
        #expect(
            viewModel.deployMessage
                == "自动恢复重试条件已变化，未再次续签。"
        )
    }

    @Test
    @MainActor
    func automaticRecoveryActivelyStopsWhenTheAppWasRemoved() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: { _, _, _, _ in nil },
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.01
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<100 where viewModel.canCancelRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.state.targetAppPresence == .confirmingNotInstalled)
        #expect(viewModel.state.lastAppInspectionAt != nil)
        #expect(
            stateStore.loadState().targetAppPresence
                == .confirmingNotInstalled
        )
        #expect(stateStore.loadState().lastAppInspectionAt != nil)
        #expect(
            viewModel.deployMessage
                == "自动恢复前无法确认原 App 安装实例，未再次续签。"
        )
    }

    @Test
    @MainActor
    func automaticRecoveryActivelyStopsWhenTheInstallIdentityChanged() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: { _, bundleID, _, _ in
                var appInfo = matchingInstalledAppInfo(
                    bundleID: bundleID,
                    expectedExpiryAt: Date().addingTimeInterval(-60)
                )
                appInfo.version = "2.0"
                return appInfo
            },
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.01
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<100 where viewModel.canCancelRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.state.targetAppPresence == .installed)
        #expect(viewModel.state.targetAppVersion == "2.0")
        #expect(!viewModel.state.isTargetAppExpiryEvidenceVerified)
        #expect(viewModel.state.lastDetectedExpiryAt == nil)
        let persistedState = stateStore.loadState()
        #expect(persistedState.targetAppVersion == "2.0")
        #expect(!persistedState.isTargetAppExpiryEvidenceVerified)
        #expect(persistedState.lastDetectedExpiryAt == nil)
        #expect(
            viewModel.deployMessage
                == "自动恢复前无法确认原 App 安装实例，未再次续签。"
        )
    }

    @Test
    @MainActor
    func automaticRecoveryRechecksInstallationImmediatelyBeforeDeploy() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let inspector = InstallationDisappearsBeforeDeployInspector()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: inspector.inspect,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.01
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<200
            where viewModel.canCancelRefresh
                || inspector.invocationCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(inspector.invocationCount == 2)
        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.state.targetAppPresence == .confirmingNotInstalled)
        #expect(
            stateStore.loadState().targetAppPresence
                == .confirmingNotInstalled
        )
        #expect(
            viewModel.deployMessage
                == "自动续期前无法确认原 App 安装实例，本次续签已停止。"
        )
    }

    @Test(arguments: [
        RefreshTriggerSource.manual,
        RefreshTriggerSource.automaticRecovery
    ])
    @MainActor
    func preparationFailureDoesNotRetryForManualOrRecoveryAttempt(
        source: RefreshTriggerSource
    ) async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.01
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: source
        )
        try await Task.sleep(for: .milliseconds(100))

        #expect(deployRecorder.callCount == 0)
    }

    @Test
    @MainActor
    func cancellingPendingAutomaticRecoveryPreventsRetry() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.2
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        #expect(viewModel.canCancelRefresh)
        viewModel.cancelRefresh()
        try await Task.sleep(for: .milliseconds(300))

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.deployMessage == "已取消自动恢复重试。")
    }

    @Test
    @MainActor
    func recheckingWhileAutomaticRecoveryIsPendingKeepsRecoveryScheduled() async throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 60
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        #expect(viewModel.canCancelRefresh)
        #expect(viewModel.operationActivityPresentation.actions == .recovery)
        let actionIDs = viewModel.primaryJourneyPresentation.currentTask?
            .actions.map(\.id) ?? []
        #expect(actionIDs.contains(.recoveryPreservingRecheck))
        #expect(!actionIDs.contains(.recheck))

        #expect(
            viewModel.performPrimaryJourneyAction(
                .recoveryPreservingRecheck
            ) == .performed
        )

        #expect(viewModel.canCancelRefresh)
        #expect(viewModel.operationActivityPresentation.actions == .recovery)
        viewModel.cancelRefresh()
    }

    @Test
    @MainActor
    func systemWakeKeepsPendingAutomaticRecoveryScheduled() async throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 60
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        #expect(viewModel.canCancelRefresh)

        viewModel.handleSystemWake()

        #expect(viewModel.canCancelRefresh)
        #expect(viewModel.operationActivityPresentation.actions == .recovery)
        viewModel.cancelRefresh()
    }

    @Test
    @MainActor
    func targetConfigurationChangeCancelsPendingAutomaticRecovery() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.2
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        #expect(viewModel.canCancelRefresh)

        viewModel.setupViewModel.bundleID = "com.example.changed"
        viewModel.setupViewModel.saveSettings()
        try await Task.sleep(for: .milliseconds(300))

        #expect(viewModel.config.bundleID == "com.example.changed")
        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(!viewModel.state.isDeployRunning)
    }

    @Test
    @MainActor
    func expiryBecomingValidStopsPendingAutomaticRecoveryWithConsistentUI() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.1
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        #expect(viewModel.canCancelRefresh)
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: 60 * 60)
        for _ in 0..<200 where viewModel.canCancelRefresh {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.deployProgressText == nil)
        #expect(viewModel.deployMessage == "自动恢复重试条件已变化，未再次续签。")
    }

    @Test
    @MainActor
    func recoveryStillRequiringUnlockDoesNotSendDuplicateNotification() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let notifications = LockStateNotificationRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(
                .requiresUnlock("Device is locked")
            ),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: matchingInstalledAppInspector,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: notifications,
            deployRecoveryDelaySeconds: 0.02
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<100
            where viewModel.deployProgressText
                != "等待 Xcode 完成设备准备" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 0)
        #expect(notifications.notifications == [
            .automaticRefreshWaitingForUnlock(
                deviceName: exampleDevice.name
            )
        ])
        #expect(viewModel.deployProgressText == "等待 Xcode 完成设备准备")
    }

    @Test
    @MainActor
    func recoveryBlockedByLockInspectorDoesNotSendDuplicateNotification() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let notifications = LockStateNotificationRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: matchingInstalledAppInspector,
            deviceLockStateInspector: lockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: notifications,
            deployRecoveryDelaySeconds: 0.02
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        for _ in 0..<100
            where viewModel.deployProgressText != "等待 iPhone 解锁" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(deployRecorder.callCount == 0)
        #expect(notifications.notifications == [
            .automaticRefreshWaitingForUnlock(
                deviceName: exampleDevice.name
            )
        ])
        #expect(viewModel.deployProgressText == "等待 iPhone 解锁")
    }

    @Test
    @MainActor
    func changingToReminderOnlyCancelsPendingRecoveryImmediately() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector: destinationReadinessInspector(.ready),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder(),
            deployRecoveryDelaySeconds: 0.2
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        await viewModel.handleDeployResult(
            preparationFailureResult(),
            device: exampleDevice,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt,
            source: .automaticInitial
        )
        #expect(viewModel.canCancelRefresh)

        viewModel.setupViewModel.autoRefreshPolicy = .reminderOnly
        #expect(viewModel.setupViewModel.saveSettings())
        try await Task.sleep(for: .milliseconds(300))

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(viewModel.deployProgressText == nil)
        #expect(viewModel.deployMessage == "提醒策略已变更，自动恢复重试已停止。")
    }

    @Test
    @MainActor
    func changingToReminderOnlyCancelsAnAutomaticPreflightAlreadyInProgress() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let destinationRunner = DelayedDestinationReadinessRunner()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                XcodeDestinationReadinessInspector(
                    runCommand: destinationRunner.run
                ),
            deviceMonitor: verifiedDeviceMonitor,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
        for _ in 0..<100 where !destinationRunner.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(destinationRunner.hasStarted)

        viewModel.setupViewModel.autoRefreshPolicy = .reminderOnly
        #expect(viewModel.setupViewModel.saveSettings())
        #expect(viewModel.canCancelRefresh)
        #expect(!viewModel.canRefreshNow)
        try await Task.sleep(for: .milliseconds(350))

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.canCancelRefresh)
        #expect(!viewModel.state.isDeployRunning)
        #expect(
            viewModel.deployMessage
                == "提醒策略已变更，本次自动续期已在续签前停止。"
        )
    }

    @Test
    @MainActor
    func setupDeviceConflictCancelsAnAutomaticPreflightAlreadyInProgress() async throws {
        let stateStore = try makeTemporaryStateStore()
        let deployRecorder = DeployCallRecorder()
        let destinationRunner = DelayedDestinationReadinessRunner()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver,
            xcodeDestinationReadinessInspector:
                XcodeDestinationReadinessInspector(
                    runCommand: destinationRunner.run
                ),
            deviceMonitor: verifiedDeviceMonitor,
            inspectInstalledApp: matchingInstalledAppInspector,
            deviceLockStateInspector: unlockedDeviceInspector,
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: LockStateNotificationRecorder()
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.config.autoRefreshPolicy = .autoRefreshWhenExpired
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.expiryInfo = makeViewModelExpiryInfo(offset: -60)
        markInstallationVerified(in: viewModel)

        viewModel.beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
        for _ in 0..<100 where !destinationRunner.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(destinationRunner.hasStarted)

        viewModel.setupViewModel.onDeviceScanCompleted?(
            lockStateAvailabilityConflictResult(),
            nil,
            nil
        )
        #expect(viewModel.state.currentDeviceStatus == .scanFailed)
        try await Task.sleep(for: .milliseconds(350))

        #expect(deployRecorder.callCount == 0)
        #expect(!viewModel.state.isDeployRunning)
        #expect(!viewModel.canCancelRefresh)
    }

    @Test
    @MainActor
    func scanFailureBlocksRefreshEvenWhenMatchedDeviceEvidenceRemains() throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            notificationService: LockStateNotificationRecorder()
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        viewModel.environmentStatus = .readyForTests
        viewModel.matchedDevice = exampleDevice
        viewModel.availableDevices = [exampleDevice]
        viewModel.state.currentDeviceStatus = .scanFailed

        #expect(!viewModel.canRefreshNow)
    }

    @Test
    @MainActor
    func unresolvedProcessGroupPreservesRecoveryEvidenceAndRejectsSuccess() async throws {
        let stateStore = try makeTemporaryStateStore()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            notificationService: LockStateNotificationRecorder()
        )
        viewModel.stopPolling()
        let token =
            "\(DeploymentProcessRecovery.deploymentTokenPrefix)\(UUID().uuidString)"
        viewModel.state.isDeployRunning = true
        viewModel.state.lastResult = .running
        viewModel.state.activeDeployProcessGroupID = 42_426
        viewModel.state.activeDeploymentToken = token

        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: Date().addingTimeInterval(-1),
                finishedAt: Date(),
                outcome: .success,
                summary: "续签已完成。",
                logPath: "/tmp/unresolved.log",
                processGroupTerminationWasConfirmed: false
            ),
            device: exampleDevice,
            previousExpiry: nil
        )

        let persistedState = stateStore.loadState()
        #expect(!viewModel.state.isDeployRunning)
        #expect(viewModel.state.deploymentRecoveryBlocked)
        #expect(viewModel.state.lastResult == .interrupted)
        #expect(viewModel.state.lastSuccessAt == nil)
        #expect(viewModel.state.activeDeployProcessGroupID == 42_426)
        #expect(viewModel.state.activeDeploymentToken == token)
        #expect(persistedState == viewModel.state)
        #expect(
            viewModel.operationFeedbackMessage?
                .contains("无法确认完整进程树已退出") == true
        )
    }

    @Test
    @MainActor
    func unconfirmedProfileCacheRecoveryCannotPublishInstallSuccess() async throws {
        let stateStore = try makeTemporaryStateStore()
        let notificationRecorder = LockStateNotificationRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            notificationService: notificationRecorder
        )
        viewModel.stopPolling()
        viewModel.config = readyConfig
        let token = DeploymentToken.make().rawValue
        viewModel.state.isDeployRunning = true
        viewModel.state.lastResult = .running
        viewModel.state.activeDeployProcessGroupID = 42_427
        viewModel.state.activeDeploymentToken = token

        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: Date().addingTimeInterval(-1),
                finishedAt: Date(),
                outcome: .success,
                summary: "App 已安装。",
                logPath: "/tmp/profile-cache-recovery.log",
                verifiedProfileExpirationDate:
                    Date().addingTimeInterval(6 * 24 * 60 * 60),
                processGroupTerminationWasConfirmed: true,
                profileCacheRecoveryWasConfirmed: false
            ),
            device: exampleDevice,
            previousExpiry: nil
        )

        #expect(viewModel.state.deploymentRecoveryBlocked)
        #expect(viewModel.state.lastResult == .interrupted)
        #expect(viewModel.state.activeDeployProcessGroupID == nil)
        #expect(viewModel.state.activeDeploymentToken == token)
        #expect(viewModel.state.lastSuccessAt == nil)
        #expect(
            viewModel.deployProgressText
                == "签名描述文件缓存恢复未完成"
        )
        #expect(notificationRecorder.notifications.isEmpty)
    }
}

@MainActor
private final class LockStateNotificationRecorder: NotificationSending {
    private(set) var notifications: [AppNotification] = []

    func send(_ notification: AppNotification) async -> NotificationDeliveryResult {
        notifications.append(notification)
        return .scheduled
    }
}

private final class DeployCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var modes: [ProvisioningProfileRefreshMode] = []

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls > 0
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var profileRefreshModes: [ProvisioningProfileRefreshMode] {
        lock.lock()
        defer { lock.unlock() }
        return modes
    }

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    func record(profileRefreshMode: ProvisioningProfileRefreshMode) {
        lock.lock()
        calls += 1
        modes.append(profileRefreshMode)
        lock.unlock()
    }
}

private final class ManualRefreshTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.withLock { value }
    }

    func setNow(_ now: Date) {
        lock.withLock {
            value = now
        }
    }
}

private final class DelayedDestinationReadinessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        lock.withLock {
            started = true
        }
        try? await Task.sleep(for: .milliseconds(250))
        return CommandResult(
            standardOutput: """
            Available destinations:
                { platform:iOS, id:iphone-1, name:Example iPhone }
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private final class InstallationDisappearsBeforeDeployInspector:
    @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var invocationCount: Int {
        lock.withLock { calls }
    }

    func inspect(
        _ device: DeviceInfo,
        _ bundleID: String,
        _ retryCount: Int,
        _ retryDelaySeconds: TimeInterval
    ) async throws -> InstalledAppInfo? {
        let invocation = lock.withLock {
            calls += 1
            return calls
        }
        guard invocation == 1 else {
            return nil
        }
        return matchingInstalledAppInfo(
            bundleID: bundleID,
            expectedExpiryAt: Date().addingTimeInterval(-60)
        )
    }
}

private final class DeployTransactionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let stateStore: RefreshStateStore
    private var value: (token: String, persistedState: AppState)?

    init(stateStore: RefreshStateStore) {
        self.stateStore = stateStore
    }

    var snapshot: (token: String, persistedState: AppState)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(token: String) {
        let persistedState = stateStore.loadState()
        lock.lock()
        value = (token, persistedState)
        lock.unlock()
    }
}

private final class NilInspectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

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
    ) async throws -> InstalledAppInfo? {
        lock.withLock {
            calls += 1
        }
        return nil
    }
}

private final class ScriptedViewModelLockStateCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [ViewModelLockStateResponse]

    init(responses: [ViewModelLockStateResponse]) {
        self.responses = responses
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        let response: ViewModelLockStateResponse
        lock.lock()
        response = responses.isEmpty ? .init(result: .failure(stderr: "missing scripted response")) : responses.removeFirst()
        lock.unlock()

        if let outputFileContents = response.outputFileContents,
           let outputPath = jsonOutputPath(from: arguments) {
            try outputFileContents.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }

        return response.result
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }
}

private final class DelayedFirstViewModelDeviceScanRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0
    private var cancellations = 0

    var cancelledInvocationCount: Int {
        lock.withLock { cancellations }
    }

    var totalInvocationCount: Int {
        lock.withLock { invocationCount }
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        let invocation = lock.withLock {
            invocationCount += 1
            return invocationCount
        }
        if invocation == 1 {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                lock.withLock {
                    cancellations += 1
                }
                throw error
            }
        }
        return try verifiedDeviceCommand(arguments: arguments)
    }

    private func verifiedDeviceCommand(
        arguments: [String]
    ) throws -> CommandResult {
        if arguments.first == "devicectl" {
            guard let index = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(index + 1) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "missing json output",
                    terminationStatus: 1
                )
            }
            try """
            {
              "result": {
                "devices": [{
                  "identifier": "coredevice-1",
                  "name": "Example iPhone",
                  "available": true,
                  "operatingSystemVersion": "26.5",
                  "deviceProperties": {
                    "name": "Example iPhone",
                    "deviceClass": "iPhone"
                  },
                  "hardwareProperties": {
                    "udid": "iphone-1",
                    "deviceType": "iPhone"
                  },
                  "connectionProperties": {
                    "pairingState": "paired",
                    "connectionState": "connected"
                  }
                }]
              }
            }
            """.write(
                toFile: arguments[index + 1],
                atomically: true,
                encoding: .utf8
            )
            return CommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-1",
              "name": "Example iPhone",
              "modelCode": "iPhone17,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "26.5",
              "interface": "usb"
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private struct ViewModelLockStateResponse: Sendable {
    let result: CommandResult
    let outputFileContents: String?

    init(result: CommandResult, outputFileContents: String? = nil) {
        self.result = result
        self.outputFileContents = outputFileContents
    }
}

private extension CommandResult {
    static func success(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 0)
    }

    static func failure(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 1)
    }
}

private extension EnvironmentStatus {
    static let readyForTests = EnvironmentStatus(
        isXcodebuildAvailable: true,
        isXcrunAvailable: true,
        isProjectPathValid: true,
        isApplicationTargetResolved: true,
        summary: "测试环境可用"
    )
}

private var readyConfig: AppConfig {
    AppConfig(
        projectRootPath: "/tmp/project",
        deployScriptPath: "/tmp/project/scripts/deploy/ios-device.command",
        xcodeprojPath: "/tmp/project/App.xcodeproj",
        scheme: "App",
        targetName: "App",
        bundleID: "com.example.App",
        preferredDeviceID: "iphone-1",
        preferredDeviceName: "Example iPhone",
        checkIntervalMinutes: 5,
        reminderCooldownHours: 24,
        startAtLogin: false,
        autoRefreshPolicy: .reminderOnly
    )
}

private var exampleDevice: DeviceInfo {
    DeviceInfo(
        id: "iphone-1",
        name: "Example iPhone",
        platform: "com.apple.platform.iphoneos",
        osVersion: "26.5",
        isAvailable: true,
        isPaired: true
    )
}

private var verifiedDeviceMonitor: DeviceMonitor {
    DeviceMonitor { _, arguments, _ in
        if arguments.first == "devicectl" {
            guard let index = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(index + 1) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "missing json output",
                    terminationStatus: 1
                )
            }
            try """
            {
              "result": {
                "devices": [{
                  "identifier": "coredevice-1",
                  "name": "Example iPhone",
                  "available": true,
                  "operatingSystemVersion": "26.5",
                  "deviceProperties": {
                    "name": "Example iPhone",
                    "deviceClass": "iPhone"
                  },
                  "hardwareProperties": {
                    "udid": "iphone-1",
                    "deviceType": "iPhone"
                  },
                  "connectionProperties": {
                    "pairingState": "paired",
                    "connectionState": "connected"
                  }
                }]
              }
            }
            """.write(toFile: arguments[index + 1], atomically: true, encoding: .utf8)
            return CommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-1",
              "name": "Example iPhone",
              "modelCode": "iPhone17,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "26.5"
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var transportUncertainDeviceMonitor: DeviceMonitor {
    DeviceMonitor { _, arguments, _ in
        if arguments.first == "devicectl" {
            guard let index = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(index + 1) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "missing json output",
                    terminationStatus: 1
                )
            }
            try """
            {
              "result": {
                "devices": [{
                  "identifier": "coredevice-1",
                  "deviceProperties": {
                    "name": "Example iPhone",
                    "osVersionNumber": "26.5",
                    "deviceClass": "iPhone",
                    "developerModeStatus": "enabled"
                  },
                  "hardwareProperties": {
                    "udid": "iphone-1",
                    "deviceType": "iPhone"
                  },
                  "connectionProperties": {
                    "pairingState": "paired",
                    "transportType": "localNetwork",
                    "tunnelState": "disconnected"
                  }
                }]
              }
            }
            """.write(
                toFile: arguments[index + 1],
                atomically: true,
                encoding: .utf8
            )
            return CommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-1",
              "name": "Example iPhone",
              "modelCode": "iPhone17,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "26.5"
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var verifiedProjectResolver: XcodeProjectResolver {
    XcodeProjectResolver { _, arguments, _ in
        if arguments.contains("-list") {
            return CommandResult(
                standardOutput:
                    #"{"project":{"schemes":["App"],"targets":["App","OldApp","NewApp"]}}"#,
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [
              {
                "target": "App",
                "buildSettings": {
                  "PRODUCT_TYPE": "com.apple.product-type.application",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.example.App",
                  "PLATFORM_NAME": "iphoneos"
                }
              },
              {
                "target": "OldApp",
                "buildSettings": {
                  "PRODUCT_TYPE": "com.apple.product-type.application",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.example.old",
                  "PLATFORM_NAME": "iphoneos"
                }
              },
              {
                "target": "NewApp",
                "buildSettings": {
                  "PRODUCT_TYPE": "com.apple.product-type.application",
                  "PRODUCT_BUNDLE_IDENTIFIER": "com.example.new",
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

@MainActor
private func markInstallationVerified(in viewModel: MenuBarViewModel) {
    viewModel.state.targetAppPresence = .installed
    viewModel.state.targetAppBundleID = viewModel.config.bundleID
    viewModel.state.targetDeviceID = exampleDevice.id
    viewModel.state.isTargetAppExpiryEvidenceVerified = true
    viewModel.state.targetAppVersion = "1.0"
    viewModel.state.targetAppBuildVersion = "1"
    viewModel.state.targetAppURL = "/Example.app"
}

private func makeViewModelExpiryInfo(offset: TimeInterval) -> ExpiryInfo {
    makeViewModelExpiryInfo(at: Date().addingTimeInterval(offset))
}

private func makeViewModelExpiryInfo(at date: Date) -> ExpiryInfo {
    ExpiryInfo(
        estimatedExpiryAt: date,
        source: "test",
        detectedAt: Date(),
        isFallbackValue: false
    )
}

private func absoluteDateTimeStringForTest(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = .current
    return formatter.string(from: date)
}

private var unlockedDeviceInspector: DeviceLockStateInspector {
    DeviceLockStateInspector { _, arguments, _ in
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return CommandResult(
                standardOutput: "",
                standardError: "missing json output",
                terminationStatus: 1
            )
        }
        try viewModelCoreDeviceLockStateJSON(
            passcodeRequired: false
        ).write(
            toFile: arguments[index + 1],
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var offlineDeviceMonitor: DeviceMonitor {
    DeviceMonitor { _, arguments, _ in
        if arguments.first == "devicectl" {
            guard let index = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(index + 1) else {
                return .failure(stderr: "missing json output")
            }
            try #"{"result":{"devices":[]}}"#.write(
                toFile: arguments[index + 1],
                atomically: true,
                encoding: .utf8
            )
            return .success()
        }
        return .success(stdout: "[]")
    }
}

private var lockedDeviceInspector: DeviceLockStateInspector {
    DeviceLockStateInspector { _, arguments, _ in
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return CommandResult(
                standardOutput: "",
                standardError: "missing json output",
                terminationStatus: 1
            )
        }
        try viewModelCoreDeviceLockStateJSON(
            passcodeRequired: true
        ).write(
            toFile: arguments[index + 1],
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var unknownDeviceInspector: DeviceLockStateInspector {
    DeviceLockStateInspector { _, _, _ in
        CommandResult(
            standardOutput: "",
            standardError: "lock state unavailable",
            terminationStatus: 1
        )
    }
}

private var unsupportedSchemaDeviceInspector: DeviceLockStateInspector {
    DeviceLockStateInspector { _, arguments, _ in
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return CommandResult(
                standardOutput: "",
                standardError: "missing json output",
                terminationStatus: 1
            )
        }
        try """
        {
          "info": {
            "jsonVersion": 3,
            "outcome": "success",
            "version": "518.33"
          },
          "result": {"unlockedSinceBoot": true}
        }
        """.write(
            toFile: arguments[index + 1],
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }
}

private func viewModelCoreDeviceLockStateJSON(
    passcodeRequired: Bool
) -> String {
    """
    {
      "info": {
        "jsonVersion": 3,
        "outcome": "success",
        "version": "518.33"
      },
      "result": {
        "deviceIdentifier": "CORE-DEVICE-ID",
        "passcodeRequired": \(passcodeRequired),
        "unlockedSinceBoot": true
      }
    }
    """
}

private func matchingInstalledAppInfo(
    bundleID: String,
    expectedExpiryAt: Date
) -> InstalledAppInfo {
    InstalledAppInfo(
        bundleIdentifier: bundleID,
        name: "Example",
        version: "1.0",
        bundleVersion: "1",
        appURL: "file:///Example.app",
        builtByDeveloper: true,
        installMetadata: AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: Date(),
            bundleIdentifier: bundleID,
            shortVersion: "1.0",
            buildVersion: "1",
            expectedExpiryAt: expectedExpiryAt,
            profileSource: "test"
        ),
        installMetadataValidation: .valid
    )
}

private var matchingInstalledAppInspector: InspectInstalledAppHandler {
    { _, bundleID, _, _ in
        matchingInstalledAppInfo(
            bundleID: bundleID,
            expectedExpiryAt: Date().addingTimeInterval(-60)
        )
    }
}

private func destinationReadinessInspector(
    _ readiness: XcodeDestinationReadiness
) -> XcodeDestinationReadinessInspector {
    XcodeDestinationReadinessInspector { _, _, _ in
        switch readiness {
        case .ready:
            return CommandResult(
                standardOutput: """
                Available destinations:
                    { platform:iOS, id:iphone-1, name:Example iPhone }
                """,
                standardError: "",
                terminationStatus: 0
            )
        case .requiresUnlock(let error), .unavailable(let error):
            return CommandResult(
                standardOutput: """
                Available destinations:
                    { platform:iOS, id:iphone-1, name:Example iPhone, error:\(error) }
                """,
                standardError: "",
                terminationStatus: 0
            )
        case .unknown(let diagnostic):
            return CommandResult(
                standardOutput: "",
                standardError: diagnostic,
                terminationStatus: 65
            )
        }
    }
}

private func preparationFailureResult() -> DeployResult {
    DeployResult(
        startedAt: Date().addingTimeInterval(-60),
        finishedAt: Date(),
        outcome: .failure,
        failureReason: .devicePreparationRequired,
        summary: "Xcode 无法准备目标 iPhone；请解锁设备，等待 Xcode 完成设备准备后重试。",
        logPath: nil
    )
}

private func lockStateAvailabilityConflictResult() -> DeviceScanResult {
    let unavailableTarget = UnavailableDeviceInfo(
        id: "iphone-1",
        name: "Example iPhone",
        osVersion: "26.5",
        pairingState: "paired",
        connectionState: "connected",
        tunnelState: "disconnected",
        developerModeStatus: "enabled",
        diagnosticMessage: "tunnelState=disconnected"
    )
    return DeviceScanResult(
        devices: [],
        source: .none,
        unavailableTarget: unavailableTarget,
        unavailableDevices: [unavailableTarget],
        conflictingDeviceIDs: ["iphone-1"],
        isCompleteInventory: true,
        diagnostics: DeviceScanDiagnostics(
            attempts: 1,
            message: "设备来源对同一稳定 ID 的可用状态不一致。",
            sourceOutcomes: []
        )
    )
}

private func makeTemporaryStateStore() throws -> RefreshStateStore {
    let fixtureRoot = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    let fixtureScript = fixtureRoot
        .appendingPathComponent("scripts/deploy/ios-device.command")
    try FileManager.default.createDirectory(
        at: fixtureScript.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: fixtureRoot.appendingPathComponent("App.xcodeproj"),
        withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: fixtureScript.path) {
        try "#!/bin/zsh\nexit 0\n".write(
            to: fixtureScript,
            atomically: true,
            encoding: .utf8
        )
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fixtureScript.path
    )
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
    let store = RefreshStateStore(appSupportDirectory: url)
    try store.saveConfig(readyConfig)
    try store.saveState(.default)
    return store
}
