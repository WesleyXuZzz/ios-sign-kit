import Foundation
import Testing
@testable import IOSSignKit

struct MenuBarViewModelSettingsTests {
    @Test
    @MainActor
    func launchAtLoginSettingPersistsBothDirectionsImmediately() throws {
        let fixture = try SettingsFixture()
        let recorder = LaunchAtLoginSettingsRecorder()
        let viewModel = makeViewModel(
            stateStore: fixture.stateStore,
            recorder: recorder
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        recorder.reset()

        viewModel.setLaunchAtLogin(true)

        #expect(viewModel.launchAtLoginEnabled)
        #expect(viewModel.config.startAtLogin)
        #expect(viewModel.setupViewModel.startAtLogin)
        #expect(fixture.stateStore.loadConfig().startAtLogin)
        #expect(viewModel.launchAtLoginUpdateError == nil)
        #expect(recorder.synchronizedValues == [true])

        recorder.reset()
        viewModel.setLaunchAtLogin(false)

        #expect(!viewModel.launchAtLoginEnabled)
        #expect(!viewModel.config.startAtLogin)
        #expect(!viewModel.setupViewModel.startAtLogin)
        #expect(!fixture.stateStore.loadConfig().startAtLogin)
        #expect(viewModel.launchAtLoginUpdateError == nil)
        #expect(recorder.synchronizedValues == [false])
    }

    @Test
    @MainActor
    func successfulRetryClearsTheAssociatedFailureAfterRollback() throws {
        let fixture = try SettingsFixture()
        let recorder = LaunchAtLoginSettingsRecorder(
            failsWhenEnabling: true
        )
        let viewModel = makeViewModel(
            stateStore: fixture.stateStore,
            recorder: recorder
        )
        defer { viewModel.stopPolling() }
        viewModel.stopPolling()
        recorder.reset()

        viewModel.setLaunchAtLogin(true)

        let failureMessage = try #require(
            viewModel.launchAtLoginUpdateError
        )
        #expect(!viewModel.launchAtLoginEnabled)
        #expect(!viewModel.config.startAtLogin)
        #expect(!viewModel.setupViewModel.startAtLogin)
        #expect(!fixture.stateStore.loadConfig().startAtLogin)
        #expect(viewModel.deployMessage == failureMessage)
        #expect(recorder.synchronizedValues == [true, false])

        recorder.setFailsWhenEnabling(false)
        recorder.reset()
        viewModel.setLaunchAtLogin(true)

        #expect(viewModel.launchAtLoginEnabled)
        #expect(viewModel.config.startAtLogin)
        #expect(viewModel.setupViewModel.startAtLogin)
        #expect(fixture.stateStore.loadConfig().startAtLogin)
        #expect(viewModel.launchAtLoginUpdateError == nil)
        #expect(viewModel.deployMessage == nil)
        #expect(recorder.synchronizedValues == [true])
    }

    @Test
    @MainActor
    func autoSavedReminderSettingsApplyWithoutEnvironmentReloadAndControlCountdown() throws {
        let appSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-reminder-save-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let stateStore = RefreshStateStore(
            appSupportDirectory: appSupportDirectory
        )
        let projectRoot = appSupportDirectory
            .appendingPathComponent("Project", isDirectory: true)
        let scriptURL = projectRoot
            .appendingPathComponent("scripts/deploy/ios-device.command")
        let projectURL = projectRoot
            .appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        var initialConfig = AppConfig.default
        initialConfig.projectRootPath = projectRoot.path
        initialConfig.deployScriptPath = scriptURL.path
        initialConfig.xcodeprojPath = projectURL.path
        initialConfig.scheme = "App"
        initialConfig.targetName = "App"
        initialConfig.bundleID = "com.example.app"
        initialConfig.preferredDeviceID = settingsAutoRefreshDevice.id
        initialConfig.preferredDeviceName = settingsAutoRefreshDevice.name
        initialConfig.autoRefreshPolicy = .reminderOnly
        try stateStore.saveConfig(initialConfig)

        var initialState = AppState.default
        initialState.lastDetectedExpiryAt = Date().addingTimeInterval(-60)
        initialState.expirySource = "stored_estimate"
        initialState.targetAppPresence = .installed
        initialState.targetAppBundleID = "com.example.app"
        initialState.targetDeviceID = settingsAutoRefreshDevice.id
        initialState.isTargetAppExpiryEvidenceVerified = true
        try stateStore.saveState(initialState)

        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore
        )
        defer {
            viewModel.cancelPendingAutoRefresh()
            viewModel.stopPolling()
        }

        viewModel.stopPolling()
        viewModel.environmentStatus = EnvironmentStatus(
            isXcodebuildAvailable: true,
            isXcrunAvailable: true,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "测试环境已就绪"
        )
        viewModel.matchedDevice = settingsAutoRefreshDevice
        viewModel.availableDevices = [settingsAutoRefreshDevice]
        viewModel.setupViewModel.checkIntervalMinutes = 10
        viewModel.setupViewModel.expiredCheckIntervalMinutes = 2
        viewModel.setupViewModel.reminderCooldownHours = 12
        viewModel.setupViewModel.autoRefreshPolicy = .autoRefreshWhenExpired

        #expect(viewModel.setupViewModel.saveSettings())
        #expect(viewModel.config.checkIntervalMinutes == 10)
        #expect(viewModel.config.expiredCheckIntervalMinutes == 2)
        #expect(viewModel.config.reminderCooldownHours == 12)
        #expect(viewModel.config.autoRefreshPolicy == .autoRefreshWhenExpired)
        #expect(!viewModel.isReloadingEnvironment)
        #expect(viewModel.pendingAutoRefreshCountdown == 5)

        viewModel.setupViewModel.autoRefreshPolicy = .reminderOnly

        #expect(viewModel.setupViewModel.saveSettings())
        #expect(viewModel.config.autoRefreshPolicy == .reminderOnly)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        #expect(!viewModel.isReloadingEnvironment)
    }

    @MainActor
    private func makeViewModel(
        stateStore: RefreshStateStore,
        recorder: LaunchAtLoginSettingsRecorder
    ) -> MenuBarViewModel {
        MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            launchAtLoginService: LaunchAtLoginService(
                sync: { enabled in
                    try recorder.sync(isEnabled: enabled)
                },
                currentStatus: {
                    recorder.currentStatus
                }
            )
        )
    }
}

private let settingsAutoRefreshDevice = DeviceInfo(
    id: "settings-auto-refresh-device",
    name: "Settings iPhone",
    platform: "com.apple.platform.iphoneos",
    osVersion: "27.0",
    isAvailable: true,
    isPaired: true
)

private struct SettingsFixture {
    let stateStore: RefreshStateStore

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-settings-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        try store.saveConfig(.default)
        try store.saveState(.default)
        self.stateStore = store
    }
}

private final class LaunchAtLoginSettingsRecorder: @unchecked Sendable {
    private enum RecorderError: Error {
        case enablingFailed
    }

    private let lock = NSLock()
    private var failsWhenEnabling: Bool
    private var status = false
    private var values: [Bool] = []

    init(failsWhenEnabling: Bool = false) {
        self.failsWhenEnabling = failsWhenEnabling
    }

    var currentStatus: Bool {
        lock.withLock { status }
    }

    var synchronizedValues: [Bool] {
        lock.withLock { values }
    }

    func setFailsWhenEnabling(_ shouldFail: Bool) {
        lock.withLock {
            failsWhenEnabling = shouldFail
        }
    }

    func reset() {
        lock.withLock {
            values.removeAll(keepingCapacity: true)
        }
    }

    func sync(isEnabled: Bool) throws {
        try lock.withLock {
            values.append(isEnabled)
            if isEnabled && failsWhenEnabling {
                throw RecorderError.enablingFailed
            }
            status = isEnabled
        }
    }
}
