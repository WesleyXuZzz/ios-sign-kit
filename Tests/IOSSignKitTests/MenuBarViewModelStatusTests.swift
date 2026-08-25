import Foundation
import Testing
@testable import IOSSignKit

struct MenuBarViewModelStatusTests {
    @Test
    @MainActor
    func startupDoesNotPresentCachedExpiryBeforeConfirmingDeviceThisSession() throws {
        let fixture = try MenuBarStatusViewModelFixture(steps: [.online])
        let viewModel = fixture.makeViewModel()
        defer { viewModel.prepareForTermination() }

        #expect(viewModel.expiryInfo?.estimatedExpiryAt != nil)
        #expect(!viewModel.hasConfirmedTargetDeviceThisSession)
        #expect(!viewModel.environmentStatus.isValidationComplete)
        #expect(viewModel.menuBarPresentation.title == "检查中")
        #expect(viewModel.menuBarPresentation.iconTransitionIdentity == .progress)
    }

    @Test
    @MainActor
    func foregroundCheckKeepsTrustedExpiryAfterDeviceIsConfirmed() async throws {
        let fixture = try MenuBarStatusViewModelFixture(steps: [.online])
        let viewModel = fixture.makeViewModel()
        defer { viewModel.prepareForTermination() }

        viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        try await waitForMenuBarStatus {
            !viewModel.isReloadingEnvironment
                && viewModel.hasConfirmedTargetDeviceThisSession
        }
        let stableTitle = viewModel.menuBarPresentation.title
        #expect(viewModel.menuBarPresentation.iconTransitionIdentity == .online)

        viewModel.refreshDeviceStatus(
            presentation: .foreground,
            mode: .manualDeepCheck
        )

        #expect(viewModel.isForegroundEnvironmentCheck)
        #expect(viewModel.menuBarPresentation.title == stableTitle)
        #expect(viewModel.menuBarPresentation.iconTransitionIdentity == .progress)
    }

    @Test
    @MainActor
    func backgroundConfirmationKeepsExpiryTitleAndOnlineIconStable() async throws {
        let fixture = try MenuBarStatusViewModelFixture(
            steps: [.online, .absent]
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.prepareForTermination() }

        viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        try await waitForMenuBarStatus {
            !viewModel.isReloadingEnvironment
                && viewModel.hasConfirmedTargetDeviceThisSession
        }
        let stableTitle = viewModel.menuBarPresentation.title
        #expect(viewModel.menuBarPresentation.iconTransitionIdentity == .online)

        viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        try await waitForMenuBarStatus {
            !viewModel.isReloadingEnvironment
                && viewModel.state.currentDeviceStatus == .confirming
        }

        #expect(viewModel.matchedDevice == nil)
        #expect(viewModel.menuBarPresentation.title == stableTitle)
        #expect(viewModel.menuBarPresentation.iconTransitionIdentity == .online)
    }

    @Test
    @MainActor
    func transientResultAutomaticallyReturnsToStableExpiry() async throws {
        let fixture = try MenuBarStatusViewModelFixture(
            steps: [.online],
            resultDisplayDuration: .milliseconds(30)
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.prepareForTermination() }

        viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        try await waitForMenuBarStatus {
            !viewModel.isReloadingEnvironment
                && viewModel.hasConfirmedTargetDeviceThisSession
        }
        let stableTitle = viewModel.menuBarPresentation.title
        let now = Date()

        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                outcome: .cancelled,
                summary: "用户已取消续签。",
                logPath: nil
            ),
            device: fixture.device,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt
        )

        #expect(viewModel.menuBarTransientResult == .cancelled)
        #expect(viewModel.menuBarPresentation.title == "已取消")

        try await waitForMenuBarStatus {
            viewModel.menuBarTransientResult == nil
        }
        #expect(viewModel.menuBarPresentation.title == stableTitle)
    }

    @Test
    @MainActor
    func currentFailureSurvivesTransientDisplayDuration() async throws {
        let fixture = try MenuBarStatusViewModelFixture(
            steps: [.online, .online],
            resultDisplayDuration: .milliseconds(30)
        )
        let viewModel = fixture.makeViewModel()
        defer { viewModel.prepareForTermination() }

        viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        try await waitForMenuBarStatus {
            !viewModel.isReloadingEnvironment
                && viewModel.hasConfirmedTargetDeviceThisSession
        }
        let stableTitle = viewModel.menuBarPresentation.title
        let now = Date()

        await viewModel.handleDeployResult(
            DeployResult(
                startedAt: now.addingTimeInterval(-1),
                finishedAt: now,
                outcome: .failure,
                failureReason: .generic,
                summary: "签名失败，请检查开发者账号。",
                logPath: nil
            ),
            device: fixture.device,
            previousExpiry: viewModel.expiryInfo?.estimatedExpiryAt
        )

        #expect(viewModel.menuBarTransientResult == .failure)
        #expect(viewModel.menuBarPresentation.title == stableTitle)
        #expect(
            viewModel.menuBarPresentation.iconTransitionIdentity
                == .error
        )
        #expect(
            viewModel.statusMenuHeaderPresentation.headline
                == "续签失败"
        )

        try await waitForMenuBarStatus {
            viewModel.menuBarTransientResult == nil
        }
        #expect(viewModel.menuBarPresentation.title == stableTitle)
        #expect(
            viewModel.menuBarPresentation.iconTransitionIdentity
                == .error
        )
        #expect(
            viewModel.statusMenuHeaderPresentation.headline
                == "续签失败"
        )
    }
}

@MainActor
private final class MenuBarStatusViewModelFixture {
    let device = DeviceInfo(
        id: "iphone-1",
        name: "Example iPhone",
        platform: "com.apple.platform.iphoneos",
        osVersion: "18.5",
        isAvailable: true,
        isPaired: true
    )

    private let stateStore: RefreshStateStore
    private let deviceRunner: MenuBarStatusDeviceRunner
    private let expectedExpiry: Date
    private let resultDisplayDuration: Duration

    init(
        steps: [MenuBarStatusDeviceRunner.Step],
        resultDisplayDuration: Duration = .seconds(3)
    ) throws {
        self.deviceRunner = MenuBarStatusDeviceRunner(steps: steps)
        self.expectedExpiry = Date().addingTimeInterval(4 * 24 * 60 * 60)
        self.resultDisplayDuration = resultDisplayDuration

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-menu-bar-status-\(UUID().uuidString)",
                isDirectory: true
            )
        stateStore = RefreshStateStore(appSupportDirectory: directory)

        let projectRoot = directory.appendingPathComponent(
            "project",
            isDirectory: true
        )
        let deployScript = projectRoot.appendingPathComponent(
            "scripts/deploy/ios-device.command"
        )
        let xcodeProject = projectRoot.appendingPathComponent(
            "App.xcodeproj",
            isDirectory: true
        )
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
        config.preferredDeviceID = device.id
        config.preferredDeviceName = device.name
        try stateStore.saveConfig(config)

        var state = AppState.default
        state.currentDeviceStatus = .online
        state.currentDeviceName = device.name
        state.currentDeviceOS = device.osVersion
        state.lastDeviceSeenAt = Date()
        state.lastDetectedExpiryAt = expectedExpiry
        state.expirySource = .installMetadata("embedded_mobileprovision")
        state.lastExpiryVerifiedAt = Date()
        state.lastAppInspectionAt = Date()
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = device.id
        state.targetAppVersion = "1.0"
        state.targetAppBuildVersion = "1"
        state.targetAppURL =
            "file:///private/var/containers/Bundle/Application/fixture/Example.app"
        state.isTargetAppExpiryEvidenceVerified = true
        try stateStore.saveState(state)
    }

    func makeViewModel() -> MenuBarViewModel {
        let expectedExpiry = self.expectedExpiry
        let device = self.device
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: MenuBarStatusViewModelFixture.projectResolver,
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            inspectInstalledApp: { _, bundleID, _, _ in
                InstalledAppInfo(
                    bundleIdentifier: bundleID,
                    name: "Example App",
                    version: "1.0",
                    bundleVersion: "1",
                    appURL:
                        "file:///private/var/containers/Bundle/Application/fixture/Example.app",
                    builtByDeveloper: true,
                    installMetadata: AppInstallMetadataSnapshot(
                        schemaVersion: 1,
                        recordedAt: Date(),
                        bundleIdentifier: bundleID,
                        shortVersion: "1.0",
                        buildVersion: "1",
                        expectedExpiryAt: expectedExpiry,
                        profileSource: "embedded_mobileprovision"
                    ),
                    installMetadataValidation: .valid
                )
            },
            notificationService: ScheduledNotificationStub(),
            menuBarResultDisplayDuration: resultDisplayDuration
        )
        viewModel.stopPolling()
        viewModel.availableDevices = [device]
        return viewModel
    }

    private static var projectResolver: XcodeProjectResolver {
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
}

private final class MenuBarStatusDeviceRunner: @unchecked Sendable {
    enum Step: Sendable {
        case online
        case absent
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var currentStep: Step?

    init(steps: [Step]) {
        self.steps = steps
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        lock.lock()
        if arguments.first == "xcdevice" {
            currentStep = steps.isEmpty
                ? (currentStep ?? .online)
                : steps.removeFirst()
        }
        let step = currentStep ?? .online
        lock.unlock()

        switch (arguments.first, step) {
        case ("xcdevice", .online):
            return CommandResult(
                standardOutput: Self.onlineXCDeviceJSON,
                standardError: "",
                terminationStatus: 0
            )
        case ("xcdevice", .absent):
            return CommandResult(
                standardOutput: "[]",
                standardError: "",
                terminationStatus: 0
            )
        case ("devicectl", .absent):
            if let outputPath = jsonOutputPath(from: arguments) {
                try #"{"result":{"devices":[]}}"#.write(
                    toFile: outputPath,
                    atomically: true,
                    encoding: .utf8
                )
            }
            return CommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        default:
            return CommandResult(
                standardOutput: "",
                standardError: "",
                terminationStatus: 0
            )
        }
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static let onlineXCDeviceJSON = """
    [{
      "simulator": false,
      "available": true,
      "platform": "com.apple.platform.iphoneos",
      "identifier": "iphone-1",
      "name": "Example iPhone",
      "modelCode": "iPhone17,1",
      "modelName": "iPhone",
      "operatingSystemVersion": "18.5"
    }]
    """
}
