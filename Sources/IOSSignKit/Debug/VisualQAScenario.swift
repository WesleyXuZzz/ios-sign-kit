#if DEBUG
import Foundation
import SwiftUI

enum VisualQAScenarioError: Error {
    case externalOperationDisabled
}

enum VisualQAPage: String {
    case statusOffline = "status-offline"
    case settingsDevice = "settings-device"
    case settingsReminders = "settings-reminders"

    var initialTab: MainPanelView.PanelTab {
        self == .statusOffline ? .status : .settings
    }

    var settingsScrollAnchor: UnitPoint {
        self == .settingsReminders ? .bottom : .top
    }

}

@MainActor
enum VisualQAScenario {
    static let environmentKey = "IOS_SIGN_KIT_VISUAL_QA"
    static let compactEnvironmentKey = "IOS_SIGN_KIT_VISUAL_QA_COMPACT"
    static let darkEnvironmentKey = "IOS_SIGN_KIT_VISUAL_QA_DARK"
    static let pageEnvironmentKey = "IOS_SIGN_KIT_VISUAL_QA_PAGE"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static var usesCompactWindow: Bool {
        ProcessInfo.processInfo.environment[compactEnvironmentKey] == "1"
    }

    static var usesDarkAppearance: Bool {
        ProcessInfo.processInfo.environment[darkEnvironmentKey] == "1"
    }

    static var page: VisualQAPage {
        VisualQAPage(
            rawValue: ProcessInfo.processInfo.environment[pageEnvironmentKey]
                ?? ""
        ) ?? .statusOffline
    }

    static func makeViewModel(now: Date = Date()) throws -> MenuBarViewModel {
        let qaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-visual-qa-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
        let projectDirectory = qaDirectory
            .appendingPathComponent("ExampleApp", isDirectory: true)
        let xcodeProjectURL = projectDirectory
            .appendingPathComponent("ExampleApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: xcodeProjectURL,
            withIntermediateDirectories: true
        )
        let config = AppConfig(
            projectRootPath: projectDirectory.path,
            deployScriptPath: nil,
            xcodeprojPath: xcodeProjectURL.path,
            scheme: "ExampleApp",
            targetName: "ExampleApp",
            bundleID: "dev.example.visualqa",
            preferredDeviceID: "visual-qa-device",
            preferredDeviceName: "示例 iPhone 14 Pro Max",
            checkIntervalMinutes: 60,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        let expectedExpiryAt = now.addingTimeInterval(24 * 60 * 60)
        let lastVerifiedAt = now.addingTimeInterval(-8 * 60 * 60)
        let appURL = "application-container:00000000-0000-0000-0000-000000000000"
        let metadata = AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: lastVerifiedAt,
            bundleIdentifier: "dev.example.visualqa",
            shortVersion: "1.4.0",
            buildVersion: "108",
            expectedExpiryAt: expectedExpiryAt,
            profileSource: "embedded_mobileprovision"
        )
        let installedApp = InstalledAppInfo(
            bundleIdentifier: "dev.example.visualqa",
            name: "ExampleApp",
            version: "1.4.0",
            bundleVersion: "108",
            appURL: appURL,
            builtByDeveloper: true,
            installMetadata: metadata,
            installMetadataValidation: .valid
        )

        var state = AppState.default
        state.lastAttemptAt = lastVerifiedAt
        state.lastResult = .failure
        state.lastErrorSummary = "目标设备离线，上次续签未完成。"
        state.lastDetectedExpiryAt = expectedExpiryAt
        state.expirySource = .installMetadata("embedded_mobileprovision")
        state.lastExpiryVerifiedAt = lastVerifiedAt
        state.lastAppInspectionAt = lastVerifiedAt
        state.currentDeviceStatus = .offline
        state.currentDeviceName = "示例 iPhone 14 Pro Max"
        state.currentDeviceOS = "27.0"
        state.lastDeviceSeenAt = lastVerifiedAt
        state.lastDeviceScanSource = "xcrun xcdevice"
        state.targetAppPresence = .installed
        state.targetAppBundleID = "dev.example.visualqa"
        state.targetDeviceID = "visual-qa-device"
        state.targetAppVersion = "1.4.0"
        state.targetAppBuildVersion = "108"
        state.targetAppURL = appURL
        state.isTargetAppExpiryEvidenceVerified = true

        let stateStore = RefreshStateStore(
            appSupportDirectory: qaDirectory.appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
        )
        try stateStore.saveConfig(config)
        try stateStore.saveState(state)

        let successfulEmptyCommand = CommandResult(
            standardOutput: "[]",
            standardError: "",
            terminationStatus: 0
        )
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .production,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: XcodeProjectResolver(
                locateProjectPaths: { _ in [] },
                runCommand: { _, _, _ in successfulEmptyCommand }
            ),
            xcodeDestinationReadinessInspector:
                XcodeDestinationReadinessInspector { _, _, _ in
                    successfulEmptyCommand
                },
            deviceMonitor: DeviceMonitor { _, _, _ in
                successfulEmptyCommand
            },
            inspectInstalledApp: { _, _, _, _ in installedApp },
            deviceLockStateInspector: DeviceLockStateInspector { _, _, _ in
                successfulEmptyCommand
            },
            startDeploy: { _, _, _, _, _ in
                throw VisualQAScenarioError.externalOperationDisabled
            },
            pairDevice: { _ in
                .failed("视觉验证模式已禁用设备配对。")
            },
            notificationService: VisualQANotificationService(),
            launchAtLoginService: LaunchAtLoginService(
                sync: { _ in },
                currentStatus: { false }
            )
        )
        viewModel.stopPolling()
        viewModel.freezeVisualQAClock(at: now)
        viewModel.environmentStatus = EnvironmentStatus(
            isXcodebuildAvailable: true,
            isXcrunAvailable: true,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "环境已就绪"
        )
        viewModel.state = state
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: expectedExpiryAt,
            source: .installMetadata("embedded_mobileprovision"),
            detectedAt: lastVerifiedAt,
            isFallbackValue: false
        )
        viewModel.installedAppInfo = installedApp
        viewModel.historyEntries = [
            RefreshHistoryEntry(
                id: "visual-qa-history",
                startedAt: lastVerifiedAt,
                outcome: .failure,
                summary: "续签失败",
                detailSummary: "目标设备离线，上次续签未完成。",
                logExcerpt: "Visual QA：未执行任何真实续签。",
                logPath: qaDirectory
                    .appendingPathComponent("visual-qa.log")
                    .path,
                rawFilename: "visual-qa.log"
            )
        ]
        viewModel.deployMessage = nil

        let connectedDevice = DeviceInfo(
            id: "visual-qa-connected-device",
            name: "工作 iPhone 15 Pro",
            platform: "com.apple.platform.iphoneos",
            osVersion: "26.5",
            isAvailable: true,
            isPaired: true
        )
        let pairingDevice = DeviceInfo(
            id: "visual-qa-pairing-device",
            name: "备用 iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.2",
            isAvailable: false,
            isPaired: false
        )
        viewModel.setupViewModel.syncDetectedDevices(
            devices: [connectedDevice, pairingDevice],
            matchedDevice: nil,
            feedback: .clear
        )
        if page == .settingsDevice {
            viewModel.setupViewModel.selectDeviceDraft(id: connectedDevice.id)
        }
        if page != .statusOffline {
            viewModel.setupViewModel.reminderCooldownHours = 12
        }
        return viewModel
    }
}

@MainActor
private final class VisualQANotificationService: NotificationSending {
    func send(
        _ notification: AppNotification
    ) async -> NotificationDeliveryResult {
        .scheduled
    }
}
#endif
