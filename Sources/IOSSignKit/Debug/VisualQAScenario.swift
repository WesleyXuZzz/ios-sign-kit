#if DEBUG
import Foundation
import SwiftUI

enum VisualQAScenarioError: Error {
    case externalOperationDisabled
}

enum VisualQAPhase: String, CaseIterable {
    case offline, ready, deploying, success, failure, cancelled, countdown
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

    static var phase: VisualQAPhase {
        VisualQAPhase(rawValue: ProcessInfo.processInfo.environment["IOS_SIGN_KIT_VISUAL_QA_PHASE"] ?? "") ?? .offline
    }

    static func makeViewModel(now: Date = Date(), phase selectedPhase: VisualQAPhase? = nil) throws -> MenuBarViewModel {
        let selectedPhase = selectedPhase ?? phase
        let qaDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-visual-qa-\(UUID().uuidString)",
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
            historyService: RefreshHistoryService(logStore: LogStore(logsDirectoryURL: qaDirectory.appendingPathComponent("Logs"))),
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
        if selectedPhase != .offline {
            apply(selectedPhase, to: viewModel, now: now)
            let currentLogURL = qaDirectory.appendingPathComponent("mock-current.log")
            try viewModel.deployLogText.write(to: currentLogURL, atomically: true, encoding: .utf8)
            viewModel.state.lastLogPath = currentLogURL.path
            let outcomes: [RefreshHistoryOutcome] = [.success, .failure, .cancelled, .success]
            viewModel.historyEntries = try outcomes.enumerated().map { index, outcome in
                let logURL = qaDirectory.appendingPathComponent("mock-history-\(index).log")
                let excerpt = "[MOCK] ExampleApp / 示例 iPhone — \(outcome)\n[MOCK] 未运行外部构建、签名或安装命令。"
                try excerpt.write(to: logURL, atomically: true, encoding: .utf8)
                return RefreshHistoryEntry(
                    id: logURL.path, startedAt: now.addingTimeInterval(Double(-index - 1) * 3600),
                    outcome: outcome, trigger: index.isMultiple(of: 2) ? .manual : .automatic,
                    summary: outcome == .success ? "ExampleApp 续签成功" : outcome == .failure ? "ExampleApp 续签失败" : "ExampleApp 已取消",
                    detailSummary: "模拟验收记录：未操作真实设备。",
                    logExcerpt: excerpt, logPath: logURL.path, rawFilename: logURL.lastPathComponent)
            }
        }
        return viewModel
    }
    static func apply(_ phase: VisualQAPhase, to viewModel: MenuBarViewModel, now: Date) {
        guard let deviceID = viewModel.config.preferredDeviceID else { return }
        let device = DeviceInfo(id: deviceID, name: "示例 iPhone 14 Pro Max",
            platform: "com.apple.platform.iphoneos", osVersion: "27.0", isAvailable: true, isPaired: true)
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device
        viewModel.state.currentDeviceStatus = .online
        viewModel.state.lastDeviceSeenAt = now
        viewModel.state.lastExpiryVerifiedAt = now
        viewModel.state.lastAppInspectionAt = now
        viewModel.state.lastAttemptAt = now.addingTimeInterval(-30)
        viewModel.state.lastErrorSummary = nil
        viewModel.state.isDeployRunning = phase == .deploying
        viewModel.state.lastResult = phase == .deploying ? .running : phase == .failure ? .failure : phase == .cancelled ? .cancelled : .success
        viewModel.setupViewModel.syncDetectedDevices(devices: [device], matchedDevice: device, feedback: .clear)
        viewModel.deployLogText = (1...36).map { "[MOCK] 检查步骤 \($0)：ExampleApp，未执行外部命令。" }.joined(separator: "\n")
        viewModel.deployProgressText = phase == .deploying ? "模拟构建与安装输出 · 不连接真实设备" : nil
        viewModel.pendingAutoRefreshCountdown = phase == .countdown ? 5 : nil
        let message: String? = switch phase {
        case .success: "模拟续签成功，已验证界面反馈；未操作真实设备。"
        case .failure: "模拟构建失败：用于验收长错误说明、重试入口与日志查看；没有执行真实构建或安装。"
        case .cancelled: "已取消模拟续签，未操作真实设备。"
        default: nil
        }
        viewModel.configureVisualQAFeedback(message, result: message == nil ? nil : viewModel.state.lastResult)
    }

    static func appendMockOutput(to viewModel: MenuBarViewModel, sequence: Int) {
        guard viewModel.state.isDeployRunning else { return }
        viewModel.deployLogText += "\n[MOCK] 实时输出 \(sequence)：模拟进度更新，不调用 xcodebuild 或 devicectl。"
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
