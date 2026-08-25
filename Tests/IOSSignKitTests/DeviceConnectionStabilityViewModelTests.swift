import Foundation
import Testing
@testable import IOSSignKit

struct DeviceConnectionStabilityViewModelTests {
    @Test
    @MainActor
    func pendingManualProfileChoiceIsInvalidatedWhenDeviceDisconnectsBeforeReturning() async throws {
        let runner = StabilityDeviceRunner(steps: [.absent, .online])
        let fixture = try StabilityViewModelFixture(runner: runner)
        let viewModel = fixture.makeViewModel()
        let device = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.5",
            isAvailable: true,
            isPaired: true
        )
        viewModel.environmentStatus = EnvironmentStatus(
            isXcodebuildAvailable: true,
            isXcrunAvailable: true,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "测试环境可用"
        )
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device

        viewModel.refreshNow()
        #expect(viewModel.manualRefreshPrompt != nil)

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        await viewModel.waitForEnvironmentRefreshToSettle()
        #expect(viewModel.manualRefreshPrompt == nil)

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        await viewModel.waitForEnvironmentRefreshToSettle()

        viewModel.confirmManualRefresh(profileRefreshMode: .automatic)
        #expect(viewModel.manualRefreshPrompt == nil)
        #expect(!viewModel.state.isDeployRunning)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func transientSuccessfulMissPreservesIdentityUntilDeviceReturns() async throws {
        let runner = StabilityDeviceRunner(steps: [.absent, .online])
        let fixture = try StabilityViewModelFixture(runner: runner)
        let viewModel = fixture.makeViewModel()
        let knownExpiry = try #require(
            viewModel.expiryInfo?.estimatedExpiryAt
        )

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(viewModel.state.currentDeviceStatus == "confirming")
        #expect(viewModel.state.currentDeviceName == "Example iPhone")
        #expect(
            abs(
                try #require(viewModel.expiryInfo?.estimatedExpiryAt)
                    .timeIntervalSince(knownExpiry)
            ) < 1
        )
        #expect(viewModel.matchedDevice == nil)

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(viewModel.matchedDevice?.id == "iphone-1")
        #expect(
            abs(
                try #require(viewModel.expiryInfo?.estimatedExpiryAt)
                    .timeIntervalSince(knownExpiry)
            ) < 1
        )
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func sustainedCommandFailuresBecomeScanFailedWithoutBecomingOffline() async throws {
        let runner = StabilityDeviceRunner(steps: [.failed, .failed])
        let fixture = try StabilityViewModelFixture(
            runner: runner,
            stabilizer: DeviceConnectionStabilizer(
                confirmationInterval: 0.02,
                requiredAbsenceCount: 2
            )
        )
        let viewModel = fixture.makeViewModel()
        let knownExpiry = viewModel.expiryInfo?.estimatedExpiryAt

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        await viewModel.waitForEnvironmentRefreshToSettle()
        await fixture.scheduler.waitUntilScheduled(count: 1)
        for _ in 0..<2 where viewModel.state.currentDeviceStatus == .confirming {
            fixture.scheduler.advance(by: .seconds(1))
            viewModel.refreshDeviceStatus(
                showCheckingMessage: false,
                mode: .connectionConfirmation
            )
            await viewModel.waitForEnvironmentRefreshToSettle()
        }

        #expect(viewModel.state.currentDeviceStatus != "offline")
        #expect(viewModel.state.currentDeviceName == "Example iPhone")
        #expect(viewModel.deviceStatusSummary == "检测异常（上次在线）")
        #expect(viewModel.expiryInfo?.estimatedExpiryAt == knownExpiry)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func completeAvailabilityConflictIsNotOverriddenByWeakConfirmation() async throws {
        let runner = StabilityDeviceRunner(steps: [.online])
        let fixture = try StabilityViewModelFixture(
            runner: runner,
            stabilizer: DeviceConnectionStabilizer(
                confirmationInterval: 0.02,
                requiredAbsenceCount: 2
            )
        )
        let viewModel = fixture.makeViewModel()
        let unavailableTarget = UnavailableDeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            osVersion: "18.5",
            pairingState: "paired",
            connectionState: "connected",
            tunnelState: "disconnected",
            developerModeStatus: "enabled",
            diagnosticMessage: "tunnelState=disconnected"
        )
        let conflictResult = DeviceScanResult(
            devices: [],
            source: .none,
            unavailableTarget: unavailableTarget,
            unavailableDevices: [unavailableTarget],
            conflictingDeviceIDs: ["iphone-1"],
            isCompleteInventory: true,
            diagnostics: DeviceScanDiagnostics(
                attempts: 1,
                message: "设备来源对同一稳定 ID 的可用状态不一致。",
                sourceOutcomes: [
                    DeviceScanSourceOutcome(
                        source: .xcdevice,
                        result: .matchedTarget,
                        message: nil
                    ),
                    DeviceScanSourceOutcome(
                        source: .devicectl,
                        result: .completedWithoutTarget,
                        message: nil
                    )
                ]
            )
        )

        viewModel.setupViewModel.onDeviceScanCompleted?(
            conflictResult,
            nil,
            nil
        )
        #expect(viewModel.matchedDevice == nil)
        #expect(viewModel.state.currentDeviceStatus == .scanFailed)
        #expect(viewModel.deviceStatusSummary == "检测异常（上次在线）")
        await viewModel.shutdown()
    }
}

@MainActor
private final class StabilityViewModelFixture {
    private let stateStore: RefreshStateStore
    private let runner: StabilityDeviceRunner
    private let stabilizer: DeviceConnectionStabilizer
    private let knownExpiry: Date
    let scheduler = ManualRefreshScheduler()

    init(
        runner: StabilityDeviceRunner,
        stabilizer: DeviceConnectionStabilizer = DeviceConnectionStabilizer()
    ) throws {
        self.runner = runner
        self.stabilizer = stabilizer
        self.knownExpiry = Date().addingTimeInterval(3_600)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-connection-stability-\(UUID().uuidString)", isDirectory: true)
        self.stateStore = RefreshStateStore(appSupportDirectory: directory)

        var config = AppConfig.default
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Example iPhone"
        try stateStore.saveConfig(config)

        var state = AppState.default
        state.currentDeviceStatus = "online"
        state.currentDeviceName = "Example iPhone"
        state.currentDeviceOS = "18.5"
        state.lastDeviceSeenAt = Date()
        state.lastDetectedExpiryAt = knownExpiry
        state.expirySource = "embedded_mobileprovision"
        state.lastExpiryVerifiedAt = Date()
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "iphone-1"
        state.isTargetAppExpiryEvidenceVerified = true
        try stateStore.saveState(state)
    }

    func makeViewModel() -> MenuBarViewModel {
        let knownExpiry = self.knownExpiry
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            deviceMonitor: DeviceMonitor(runCommand: runner.run),
            deviceConnectionStabilizer: stabilizer,
            refreshScheduler: scheduler.interface,
            inspectInstalledApp: { _, bundleID, _, _ in
                InstalledAppInfo(
                    bundleIdentifier: bundleID,
                    name: "Example App",
                    version: "1.0",
                    bundleVersion: "1",
                    appURL: "file:///private/var/containers/Bundle/Application/fixture/Example.app",
                    builtByDeveloper: true,
                    installMetadata: AppInstallMetadataSnapshot(
                        schemaVersion: 1,
                        recordedAt: Date(),
                        bundleIdentifier: bundleID,
                        shortVersion: "1.0",
                        buildVersion: "1",
                        expectedExpiryAt: knownExpiry,
                        profileSource: "embedded_mobileprovision"
                    ),
                    installMetadataValidation: .valid
                )
            },
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
        return viewModel
    }
}

private final class StabilityDeviceRunner: @unchecked Sendable {
    enum Step: Sendable {
        case online
        case absent
        case failed
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var currentStep: Step?

    init(steps: [Step]) {
        self.steps = steps
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        lock.lock()
        if arguments.first == "xcdevice" {
            currentStep = steps.isEmpty ? (currentStep ?? .failed) : steps.removeFirst()
        }
        let step = currentStep ?? .failed
        lock.unlock()

        switch (arguments.first, step) {
        case ("xcdevice", .online):
            return CommandResult(
                standardOutput: Self.onlineXCDeviceJSON,
                standardError: "",
                terminationStatus: 0
            )
        case ("xcdevice", .absent):
            return CommandResult(standardOutput: "[]", standardError: "", terminationStatus: 0)
        case ("devicectl", .absent):
            if let outputPath = jsonOutputPath(from: arguments) {
                try #"{"result":{"devices":[]}}"#.write(toFile: outputPath, atomically: true, encoding: .utf8)
            }
            return CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
        default:
            return CommandResult(standardOutput: "", standardError: "CoreDevice unavailable", terminationStatus: 1)
        }
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"), arguments.indices.contains(index + 1) else {
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
