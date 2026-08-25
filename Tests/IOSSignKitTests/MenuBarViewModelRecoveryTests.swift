import Foundation
import Testing
@testable import IOSSignKit

struct MenuBarViewModelRecoveryTests {
    @Test
    @MainActor
    func doesNotAttemptAutomaticRecoveryBeforeExpiry() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .success,
            expiryOffset: 60 * 60
        )
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 0)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func ios26UnavailableTargetRequiresCableWithoutPairingAttempt() async throws {
        let fixture = try RecoveryFixture(osVersion: "26.5.2", pairingResult: .success)
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 0)
        #expect(viewModel.menuBarPresentation.title == "需连线")
        #expect(viewModel.deployMessage?.contains("数据线连接 Mac") == true)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func ios27SuccessfulPairRescansAndStartsAutomaticCountdown() async throws {
        let fixture = try RecoveryFixture(osVersion: "27.0", pairingResult: .success)
        fixture.pairingRecorder.onPair = {
            fixture.deviceRunner.markAvailable()
        }
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()
        await viewModel.waitForPairingToSettle()
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 1)
        #expect(viewModel.state.currentDeviceStatus == "online")
        #expect(viewModel.matchedDevice?.id == "iphone-1")
        #expect(viewModel.pendingAutoRefreshCountdown != nil)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func ios27ConfirmationRequirementStopsBeforeDeploy() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .confirmationRequired("Trust This Computer")
        )
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()
        await viewModel.waitForPairingToSettle()
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 1)
        #expect(viewModel.menuBarPresentation.title == "需确认")
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        #expect(viewModel.state.isDeployRunning == false)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func successfulPairThatIsStillUnavailableDoesNotRemainStuckAsPairing() async throws {
        let fixture = try RecoveryFixture(osVersion: "27.0", pairingResult: .success)
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()
        await viewModel.waitForPairingToSettle()
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 1)
        #expect(viewModel.state.currentDeviceStatus == "wireless_pairing_required")
        #expect(viewModel.menuBarPresentation.title == "需配对")
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func automaticPairingCooldownCanBeBypassedByManualReload() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .networkUnavailable("local network unavailable"),
            lastPairingAttemptAt: Date()
        )
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()
        #expect(fixture.pairingRecorder.callCount == 0)

        viewModel.reloadEnvironment()
        await viewModel.waitForEnvironmentRefreshToSettle()
        await viewModel.waitForPairingToSettle()

        #expect(fixture.pairingRecorder.callCount == 1)
        #expect(viewModel.state.currentDeviceStatus == "wireless_pairing_required")
        #expect(viewModel.menuBarPresentation.title == "需配对")
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func futurePairingTimestampDoesNotBlockAutomaticRecovery() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .networkUnavailable("local network unavailable"),
            lastPairingAttemptAt: Date().addingTimeInterval(365 * 24 * 60 * 60)
        )
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await viewModel.waitForEnvironmentRefreshToSettle()
        await viewModel.waitForPairingToSettle()

        #expect(fixture.pairingRecorder.callCount == 1)
        #expect(viewModel.state.currentDeviceStatus == "wireless_pairing_required")
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func futureAutomaticAttemptTimestampDoesNotBlockCountdown() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .success,
            lastAutomaticAttemptAt:
                Date().addingTimeInterval(365 * 24 * 60 * 60)
        )
        fixture.deviceRunner.markAvailable()
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .automaticRecoveryCheck
        )
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 0)
        #expect(viewModel.pendingAutoRefreshCountdown != nil)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func unavailableStateStorageBlocksAutomaticWirelessPairing() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .success,
            stateStorageIsReadOnly: true
        )
        defer { fixture.restoreStateStoragePermissions() }
        let viewModel = fixture.makeViewModel()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(!viewModel.canRefreshNow)
        #expect(fixture.pairingRecorder.callCount == 0)
        #expect(viewModel.deployMessage?.contains("已阻止续签与自动配对") == true)
        fixture.restoreStateStoragePermissions()
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func pairingAttemptIsNotStartedWhenItsStateWriteFails() async throws {
        let fixture = try RecoveryFixture(
            osVersion: "27.0",
            pairingResult: .success
        )
        let viewModel = fixture.makeViewModel()
        try fixture.makeStateStorageReadOnly()

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .automaticRecoveryCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.pairingRecorder.callCount == 0)
        #expect(!viewModel.canRefreshNow)
        fixture.restoreStateStoragePermissions()
        await viewModel.shutdown()
    }
}

@MainActor
private final class RecoveryFixture {
    let stateStore: RefreshStateStore
    let config: AppConfig
    let deviceRunner: RecoveryDeviceCommandRunner
    let pairingRecorder: PairingRecorder
    private let stateDirectory: URL
    private let expectedExpiryAt: Date

    init(
        osVersion: String,
        pairingResult: DevicePairingResult,
        lastPairingAttemptAt: Date? = nil,
        lastAutomaticAttemptAt: Date? = nil,
        expiryOffset: TimeInterval = -60,
        stateStorageIsReadOnly: Bool = false
    ) throws {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ios-sign-kit-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("Project", isDirectory: true)
        let scriptURL = projectURL.appendingPathComponent("scripts/deploy/ios-device.command")
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("Example.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        config = AppConfig(
            projectRootPath: projectURL.path,
            deployScriptPath: scriptURL.path,
            xcodeprojPath: projectURL.appendingPathComponent("Example.xcodeproj").path,
            scheme: "Example",
            targetName: "Example",
            bundleID: "com.example.App",
            preferredDeviceID: "iphone-1",
            preferredDeviceName: "Example iPhone",
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .autoRefreshWhenExpired
        )

        expectedExpiryAt = Date().addingTimeInterval(expiryOffset)
        var state = AppState.default
        state.lastDetectedExpiryAt = expectedExpiryAt
        state.expirySource = "stored_estimate"
        state.currentDeviceStatus = lastPairingAttemptAt == nil ? "offline" : "wireless_pairing_required"
        state.lastPairingAttemptAt = lastPairingAttemptAt
        state.lastPairingDeviceID = lastPairingAttemptAt == nil ? nil : "iphone-1"
        state.lastAutomaticAttemptAt = lastAutomaticAttemptAt
        state.targetAppPresence = .installed
        state.targetAppBundleID = "com.example.App"
        state.targetDeviceID = "iphone-1"
        state.isTargetAppExpiryEvidenceVerified = true

        stateDirectory = rootURL.appendingPathComponent("State")
        stateStore = RefreshStateStore(appSupportDirectory: stateDirectory)
        try stateStore.saveConfig(config)
        try stateStore.saveState(state)
        if stateStorageIsReadOnly {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: stateDirectory.path
            )
        }

        deviceRunner = RecoveryDeviceCommandRunner(osVersion: osVersion)
        pairingRecorder = PairingRecorder(result: pairingResult)
    }

    func makeViewModel() -> MenuBarViewModel {
        MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: verifiedProjectResolver(config: config),
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            inspectInstalledApp: { [expectedExpiryAt] _, bundleID, _, _ in
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
            },
            pairDevice: pairingRecorder.pair
        )
    }

    func restoreStateStoragePermissions() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stateDirectory.path
        )
    }

    func makeStateStorageReadOnly() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: stateDirectory.path
        )
    }
}

private func verifiedProjectResolver(config: AppConfig) -> XcodeProjectResolver {
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
            [{
              "target":"Example",
              "buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"iphoneos",
                "PRODUCT_BUNDLE_IDENTIFIER":"\(config.bundleID ?? "")"
              }
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private final class RecoveryDeviceCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let osVersion: String
    private var isAvailable = false

    init(osVersion: String) {
        self.osVersion = osVersion
    }

    func markAvailable() {
        lock.lock()
        isAvailable = true
        lock.unlock()
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        lock.lock()
        let available = isAvailable
        lock.unlock()

        if arguments.first == "xcdevice" {
            return CommandResult(
                standardOutput: xcdeviceOutput(available: available),
                standardError: "",
                terminationStatus: 0
            )
        }

        guard arguments.first == "devicectl",
              let outputPath = jsonOutputPath(from: arguments) else {
            return CommandResult(standardOutput: "", standardError: "Unexpected command", terminationStatus: 1)
        }

        try devicectlOutput(available: available).write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
    }

    private func xcdeviceOutput(available: Bool) -> String {
        """
        [{
          "simulator": false,
          "available": \(available),
          "platform": "com.apple.platform.iphoneos",
          "identifier": "iphone-1",
          "name": "Example iPhone",
          "modelCode": "iPhone17,1",
          "modelName": "iPhone",
          "operatingSystemVersion": "\(osVersion)",
          "error": {
            "description": "Browsing on the local network",
            "recoverySuggestion": "Unlock the device or reconnect it."
          }
        }]
        """
    }

    private func devicectlOutput(available: Bool) -> String {
        let connectionState = available ? "connected" : "unavailable"
        let tunnelState = available ? "connected" : "unavailable"
        return """
        {"result":{"devices":[{
          "identifier":"coredevice-1",
          "deviceProperties":{
            "name":"Example iPhone",
            "osVersionNumber":"\(osVersion)",
            "deviceClass":"iPhone",
            "developerModeStatus":"enabled"
          },
          "hardwareProperties":{
            "udid":"iphone-1",
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            "connectionState":"\(connectionState)",
            "pairingState":"paired",
            "tunnelState":"\(tunnelState)"
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

private final class PairingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: DevicePairingResult
    private var calls = 0
    var onPair: (@Sendable () -> Void)?

    init(result: DevicePairingResult) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func pair(_ device: UnavailableDeviceInfo) -> DevicePairingResult {
        lock.lock()
        calls += 1
        let callback = onPair
        lock.unlock()
        callback?()
        return result
    }
}
