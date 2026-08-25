import Foundation
import Testing
@testable import IOSSignKit

struct RefreshSequenceTests {
    @Test
    @MainActor
    func changingPinnedDeviceInvalidatesOldMatchBeforeRescanCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-device-switch-\(UUID().uuidString)", isDirectory: true)
        let script = root.appendingPathComponent("scripts/deploy/ios-device.command")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        let store = RefreshStateStore(appSupportDirectory: root.appendingPathComponent("state"))
        var config = AppConfig.default
        config.projectRootPath = root.path
        config.deployScriptPath = script.path
        config.xcodeprojPath = root.appendingPathComponent("App.xcodeproj").path
        config.scheme = "App"
        config.targetName = "App"
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "iphone-a"
        config.preferredDeviceName = "Old iPhone"
        try store.saveConfig(config)

        let runner = DeviceSwitchCommandRunner()
        let deployRecorder = RefreshDeployRecorder()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            xcodeProjectResolver: refreshSequenceProjectResolver,
            deviceMonitor: DeviceMonitor(runCommandAsync: runner.run),
            inspectInstalledApp: { _, _, _, _ in nil },
            startDeploy: { _, _, _, _, _ in
                deployRecorder.record()
                throw DeployServiceError.missingDeployScript
            },
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .manualDeepCheck)
        await viewModel.waitForEnvironmentRefreshToSettle()

        let newDevice = DeviceInfo(
            id: "iphone-b",
            name: "New iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        viewModel.setupViewModel.syncDetectedDevices(
            devices: [newDevice],
            matchedDevice: nil,
            feedback: .clear
        )
        viewModel.setupViewModel.selectDeviceDraft(id: newDevice.id)
        #expect(viewModel.setupViewModel.saveSettings())

        #expect(viewModel.matchedDevice == nil)
        #expect(viewModel.availableDevices.isEmpty)
        #expect(viewModel.isReloadingEnvironment)
        #expect(!viewModel.canRefreshNow)
        viewModel.refreshNow()
        #expect(!deployRecorder.wasCalled)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func cancelledOlderRefreshCannotOverwriteNewerDeviceState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-refresh-sequence-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Current iPhone"
        try store.saveConfig(config)

        let runner = StaleRefreshCommandRunner()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            deviceMonitor: DeviceMonitor(runCommandAsync: runner.run),
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await runner.waitForInvocation(1)

        viewModel.refreshDeviceStatus(showCheckingMessage: false, mode: .backgroundPoll)
        try await runner.waitForInvocation(2)
        await viewModel.waitForCurrentEnvironmentRefreshToSettle()

        runner.releaseFirstCall()
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(viewModel.matchedDevice?.id == "iphone-1")
        #expect(viewModel.state.currentDeviceStatus == .online)
        #expect(viewModel.state.currentDeviceName == "Current iPhone")
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func olderBackgroundOnlineSnapshotCannotOverrideSetupConflict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-cross-scan-sequence-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Current iPhone"
        try store.saveConfig(config)

        let runner = StaleRefreshCommandRunner()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            deviceMonitor: DeviceMonitor(runCommandAsync: runner.run),
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        try await runner.waitForInvocation(1)

        viewModel.setupViewModel.onDeviceScanCompleted?(
            makeRefreshSequenceConflictResult(),
            nil,
            nil
        )
        #expect(viewModel.state.currentDeviceStatus == .scanFailed)

        runner.releaseFirstCall(result: .onlineDevice)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(viewModel.matchedDevice == nil)
        #expect(viewModel.state.currentDeviceStatus == .scanFailed)
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func setupScanStartInvalidatesOlderBackgroundSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-setup-scan-start-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Current iPhone"
        try store.saveConfig(config)

        let runner = InterleavedSetupScanRunner()
        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            deviceMonitor: DeviceMonitor(runCommandAsync: runner.run),
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
        viewModel.refreshDeviceStatus(
            showCheckingMessage: false,
            mode: .backgroundPoll
        )
        try await runner.waitForInvocation(1)

        viewModel.setupViewModel.scanDevices()
        try await runner.waitForInvocation(2)
        #expect(viewModel.setupViewModel.isScanningDevices)

        runner.releaseCall(1, result: .onlineDevice)
        await viewModel.waitForEnvironmentRefreshToSettle()

        #expect(viewModel.matchedDevice == nil)
        #expect(viewModel.state.currentDeviceStatus != .online)
        #expect(viewModel.pendingAutoRefreshCountdown == nil)
        runner.releaseCall(
            2,
            result: CommandResult(
                standardOutput: "",
                standardError: "test cleanup",
                terminationStatus: 1
            )
        )
        await viewModel.shutdown()
    }

    @Test
    @MainActor
    func incompleteAndFailedSetupInventoriesNeverContributeDeviceAbsence()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-incomplete-setup-inventory-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Current iPhone"
        var initialState = AppState.default
        initialState.currentDeviceStatus = .online
        initialState.currentDeviceName = "Current iPhone"
        initialState.currentDeviceOS = "27.0"
        initialState.lastDeviceSeenAt = Date()
        try store.saveConfig(config)
        try store.saveState(initialState)

        let viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .fallback,
            bootstrapper: AppBootstrapper(stateStore: store),
            stateStore: store,
            deviceConnectionStabilizer: DeviceConnectionStabilizer(
                confirmationInterval: 0,
                requiredAbsenceCount: 2
            ),
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
        defer { viewModel.stopPolling() }

        let incompleteResult = DeviceScanResult(
            devices: [],
            source: .xcdevice,
            unavailableTarget: nil,
            isCompleteInventory: false,
            diagnostics: DeviceScanDiagnostics(
                attempts: 1,
                message: "设备清单不完整"
            )
        )
        viewModel.setupViewModel.onDeviceScanCompleted?(
            incompleteResult,
            nil,
            nil
        )
        viewModel.setupViewModel.onDeviceScanCompleted?(
            nil,
            nil,
            "设备源暂时失败"
        )
        viewModel.setupViewModel.onDeviceScanCompleted?(
            incompleteResult,
            nil,
            nil
        )

        #expect(viewModel.state.currentDeviceStatus == .scanFailed)
        #expect(viewModel.state.lastDeviceSeenAt != nil)

        let completeAbsence = DeviceScanResult(
            devices: [],
            source: .none,
            unavailableTarget: nil,
            isCompleteInventory: true,
            diagnostics: DeviceScanDiagnostics(
                attempts: 1,
                message: "完整清单未找到目标设备"
            )
        )
        viewModel.setupViewModel.onDeviceScanCompleted?(
            completeAbsence,
            nil,
            nil
        )

        #expect(viewModel.state.currentDeviceStatus != .offline)
    }
}

private func makeRefreshSequenceConflictResult() -> DeviceScanResult {
    let unavailableTarget = UnavailableDeviceInfo(
        id: "iphone-1",
        name: "Current iPhone",
        osVersion: "27.0",
        pairingState: "paired",
        connectionState: nil,
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
}

private final class DeviceSwitchCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var scanRound = 0

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        let round = lock.withLock {
            if arguments.first == "xcdevice" {
                scanRound += 1
            }
            return scanRound
        }
        if round > 1 {
            try await Task.sleep(for: .seconds(30))
        }
        if arguments.first == "devicectl" {
            guard let outputIndex = arguments.firstIndex(of: "--json-output"),
                  arguments.indices.contains(outputIndex + 1) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "missing json output",
                    terminationStatus: 1
                )
            }
            try """
            {"result":{"devices":[{
              "identifier":"coredevice-a",
              "deviceProperties":{"name":"Old iPhone","deviceClass":"iPhone"},
              "hardwareProperties":{"udid":"iphone-a","platform":"iOS","deviceType":"iPhone"},
              "connectionProperties":{"pairingState":"paired","connectionState":"connected"}
            }]}}
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
        return CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-a",
              "name": "Old iPhone",
              "modelCode": "iPhone17,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "27.0"
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}

private var refreshSequenceProjectResolver: XcodeProjectResolver {
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

private final class RefreshDeployRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }

    func record() {
        lock.lock()
        called = true
        lock.unlock()
    }
}

private final class StaleRefreshCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var firstContinuation: CheckedContinuation<CommandResult, Never>?
    private let invocationEvents = TestEventRecorder<Int>()

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        let invocation = lock.withLock {
            calls += 1
            return calls
        }
        invocationEvents.record(invocation)

        if invocation == 1 {
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    firstContinuation = continuation
                }
            }
        }

        return CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-1",
              "name": "Current iPhone",
              "modelCode": "iPhone17,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "27.0"
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }

    func waitForInvocation(_ invocation: Int) async throws {
        while try await invocationEvents.next() != invocation {}
    }

    func releaseFirstCall(
        result: CommandResult = CommandResult(
            standardOutput: "[]",
            standardError: "",
            terminationStatus: 0
        )
    ) {
        lock.lock()
        let continuation = firstContinuation
        firstContinuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private final class InterleavedSetupScanRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0
    private var continuations:
        [Int: CheckedContinuation<CommandResult, Never>] = [:]
    private var pendingResults: [Int: CommandResult] = [:]
    private let invocationEvents = TestEventRecorder<Int>()

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        let invocation = lock.withLock {
            invocations += 1
            return invocations
        }
        invocationEvents.record(invocation)
        guard invocation <= 2 else {
            return CommandResult(
                standardOutput: "",
                standardError: "test cleanup",
                terminationStatus: 1
            )
        }
        return await withCheckedContinuation { continuation in
            let pendingResult: CommandResult? = lock.withLock {
                if let result = pendingResults.removeValue(
                    forKey: invocation
                ) {
                    return result
                }
                continuations[invocation] = continuation
                return nil
            }
            if let pendingResult {
                continuation.resume(returning: pendingResult)
            }
        }
    }

    func waitForInvocation(_ invocation: Int) async throws {
        while try await invocationEvents.next() != invocation {}
    }

    func releaseCall(_ invocation: Int, result: CommandResult) {
        let continuation: CheckedContinuation<CommandResult, Never>? =
            lock.withLock {
            guard let continuation = continuations.removeValue(
                forKey: invocation
            ) else {
                pendingResults[invocation] = result
                return nil
            }
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

private extension CommandResult {
    static var onlineDevice: CommandResult {
        CommandResult(
            standardOutput: """
            [{
              "simulator": false,
              "available": true,
              "platform": "com.apple.platform.iphoneos",
              "identifier": "iphone-1",
              "name": "Current iPhone",
              "modelCode": "iPhone17,1",
              "modelName": "iPhone",
              "operatingSystemVersion": "27.0"
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}
