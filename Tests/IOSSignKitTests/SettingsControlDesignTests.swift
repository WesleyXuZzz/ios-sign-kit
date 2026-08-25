import Foundation
import Testing
@testable import IOSSignKit

struct SettingsControlDesignTests {
    @Test
    func settingsPanelUsesSharedTypographyTokens() throws {
        let sourceURL = testRepositoryRoot
            .appendingPathComponent(
                "Sources/IOSSignKit/Views/SettingsPanelView.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let compactSource = source.filter { !$0.isWhitespace }

        #expect(!compactSource.contains(".font(.system(size:"))
        #expect(source.contains("TypeTokens.controlLabelEmphasized"))
        #expect(source.contains("TypeTokens.controlLabel"))
        #expect(source.contains("TypeTokens.auxiliary"))
        #expect(source.contains("TypeTokens.controlIcon"))
    }

    @Test
    func lanControlPairingSheetIsDrivenByNonOptionalContent() throws {
        let sourceURL = testRepositoryRoot
            .appendingPathComponent(
                "Sources/IOSSignKit/Views/LANControlSettingsSection.swift"
            )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains(".sheet(item: $pairingSheet)"))
        #expect(!source.contains(".sheet(isPresented: $showsPairingCode)"))
        #expect(source.contains("@Environment(\\.dismiss)"))
        #expect(source.contains("Button(\"关闭\")"))
    }

    @Test
    func settingsCategoriesKeepTheApprovedOrder() {
        #expect(
            SettingsPanelCategory.allCases.map(\.rawValue)
                == ["目标", "续期", "局域网", "通用"]
        )
    }

    @Test
    func saveFailureRoutesToTheOwningCategory() {
        #expect(
            SettingsPanelCategory.categoryForSaveFailure(
                canSaveProjectConfiguration: false,
                lanControlValidationMessage: "端口无效"
            ) == .target
        )
        #expect(
            SettingsPanelCategory.categoryForSaveFailure(
                canSaveProjectConfiguration: true,
                lanControlValidationMessage: "端口无效"
            ) == .localNetwork
        )
        #expect(
            SettingsPanelCategory.categoryForSaveFailure(
                canSaveProjectConfiguration: true,
                lanControlValidationMessage: nil
            ) == nil
        )
    }

    @Test
    func settingsRouteCanSelectAnExplicitCategory() {
        var navigation = MainPanelView.NavigationState(
            selectedTab: .history,
            settingsCategory: .general
        )

        navigation.showSettings(category: .target)

        #expect(navigation.selectedTab == .settings)
        #expect(navigation.settingsCategory == .target)
    }

    @Test
    func numberStepperClampsDirectInputAndDisablesBoundaryMovement() {
        let policy = NumberStepperValuePolicy(min: 1, max: 60, step: 1)

        #expect(policy.adjusted(1, direction: -1) == 1)
        #expect(policy.adjusted(1, direction: 1) == 2)
        #expect(policy.adjusted(60, direction: 1) == 60)
        #expect(policy.committedValue(from: "0") == 1)
        #expect(policy.committedValue(from: "37") == 37)
        #expect(policy.committedValue(from: "99") == 60)
        #expect(policy.committedValue(from: "") == nil)
    }

    @Test
    func deviceSelectTargetsKeepConnectionStatesAndRejectAmbiguousNames() {
        let connected = DeviceInfo(
            id: "connected-0001",
            name: "主力 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        let ambiguousOnline = DeviceInfo(
            id: "duplicate-0001",
            name: "同名 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "26.0",
            isAvailable: true,
            isPaired: true
        )
        let offline = UnavailableDeviceInfo(
            id: "offline-0001",
            name: "备用 iPhone",
            osVersion: "18.2",
            pairingState: "paired",
            connectionState: "disconnected",
            tunnelState: nil,
            developerModeStatus: nil,
            diagnosticMessage: nil
        )
        let ambiguousOffline = UnavailableDeviceInfo(
            id: "duplicate-0002",
            name: "同名 iPhone",
            osVersion: "18.1",
            pairingState: "unpaired",
            connectionState: "disconnected",
            tunnelState: nil,
            developerModeStatus: nil,
            diagnosticMessage: nil
        )

        let targets = DeviceSelectTarget.selectableTargets(
            devices: [connected, ambiguousOnline],
            unavailableDevices: [offline, ambiguousOffline]
        )

        #expect(targets.map(\.id) == [connected.id, offline.id])
        #expect(targets[0].status == .connected)
        #expect(targets[1].status == .offline)
        #expect(!targets.contains { $0.name == "同名 iPhone" })
    }

    @MainActor
    @Test
    func settingsDraftWaitsForTheSharedSaveAction() throws {
        let fixture = try makeValidSettingsFixture()
        let viewModel = fixture.viewModel
        let device = DeviceInfo(
            id: "settings-device",
            name: "设置测试 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        viewModel.syncDetectedDevices(
            devices: [device],
            matchedDevice: nil,
            feedback: .clear
        )

        viewModel.selectDeviceDraft(id: device.id)
        viewModel.checkIntervalMinutes = 9
        viewModel.expiredCheckIntervalMinutes = 2
        viewModel.reminderCooldownHours = 12
        viewModel.autoRefreshPolicy = .autoRefreshWhenExpired

        let beforeSave = fixture.stateStore.loadConfig()
        #expect(beforeSave.preferredDeviceID == nil)
        #expect(beforeSave.checkIntervalMinutes == 5)
        #expect(beforeSave.expiredCheckIntervalMinutes == 1)
        #expect(beforeSave.reminderCooldownHours == 24)
        #expect(beforeSave.autoRefreshPolicy == .reminderOnly)
        #expect(viewModel.hasUnsavedChanges)

        var callbackConfig: AppConfig?
        viewModel.onSettingsSaved = { callbackConfig = $0 }
        #expect(viewModel.saveSettings())

        let savedConfig = fixture.stateStore.loadConfig()
        #expect(savedConfig.preferredDeviceID == device.id)
        #expect(savedConfig.preferredDeviceName == device.name)
        #expect(savedConfig.checkIntervalMinutes == 9)
        #expect(savedConfig.expiredCheckIntervalMinutes == 2)
        #expect(savedConfig.reminderCooldownHours == 12)
        #expect(savedConfig.autoRefreshPolicy == .autoRefreshWhenExpired)
        #expect(callbackConfig == savedConfig)
        #expect(!viewModel.hasUnsavedChanges)
    }

    @MainActor
    @Test
    func readOnlyDetectionDisablesSettingsControls() throws {
        let fixture = try makeValidSettingsFixture(
            deviceDetectionRolloutMode: .readOnly
        )
        #expect(fixture.viewModel.isDeviceDetectionReadOnly)
    }

    @MainActor
    private func makeValidSettingsFixture(
        deviceDetectionRolloutMode: DeviceDetectionRolloutMode = .production
    ) throws -> (
        viewModel: SetupWizardViewModel,
        stateStore: RefreshStateStore
    ) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-settings-controls-\(UUID().uuidString)",
                isDirectory: true
            )
        let scriptURL = rootURL
            .appendingPathComponent("scripts/deploy/ios-device.command")
        let projectURL = rootURL
            .appendingPathComponent("ExampleApp.xcodeproj", isDirectory: true)
        let supportURL = rootURL
            .appendingPathComponent("Application Support", isDirectory: true)

        try fileManager.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: scriptURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let config = AppConfig(
            projectRootPath: rootURL.path,
            deployScriptPath: scriptURL.path,
            xcodeprojPath: projectURL.path,
            scheme: "ExampleApp",
            targetName: "ExampleApp",
            bundleID: "dev.example.settingscontrols",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        let stateStore = RefreshStateStore(appSupportDirectory: supportURL)
        try stateStore.saveConfig(config)

        return (
            SetupWizardViewModel(
                deviceDetectionRolloutMode: deviceDetectionRolloutMode,
                initialConfig: config,
                environmentValidator: EnvironmentValidator(),
                stateStore: stateStore
            ),
            stateStore
        )
    }
}
