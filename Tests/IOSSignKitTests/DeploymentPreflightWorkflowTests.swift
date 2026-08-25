import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct DeploymentPreflightWorkflowTests {
    @Test
    func manualUnknownDestinationContinuesToAuthorizedTarget()
        async throws
    {
        let fixture = PreflightFixture(
            source: .manual,
            lockStates: [.unlocked],
            destinationIsReady: false
        )
        var progress: [DeploymentPreflightProgress] = []

        let outcome = try await fixture.workflow.run(
            fixture.request,
            callbacks: fixture.callbacks { progress.append($0) }
        )

        guard case .ready(let target) = outcome else {
            Issue.record("手动续签应允许在 destination 状态未知时继续")
            return
        }
        #expect(target.device.id == fixture.device.id)
        #expect(target.device.name == fixture.device.name)
        #expect(target.isAuthorized(for: .fallback))
        #expect(progress.contains(.confirmingDevice))
        #expect(progress.contains(.confirmingLockState))
        #expect(progress.contains(.confirmingDestination))
        #expect(progress.contains(where: {
            if case .manualDestinationUnknown = $0 {
                return true
            }
            return false
        }))
    }

    @Test
    func automaticPreflightStopsWhenDestinationIsUnknown()
        async throws
    {
        let fixture = PreflightFixture(
            source: .automaticInitial,
            lockStates: [.unlocked],
            destinationIsReady: false
        )

        let outcome = try await fixture.workflow.run(
            fixture.request,
            callbacks: fixture.callbacks { _ in }
        )

        guard case .destinationBlocked(let device, let readiness) =
                outcome else {
            Issue.record("自动续签必须在 destination 未知时失败关闭")
            return
        }
        #expect(device.id == fixture.device.id)
        #expect(device.name == fixture.device.name)
        guard case .unknown = readiness else {
            Issue.record("应保留 destination 未知诊断")
            return
        }
        #expect(fixture.installationVerificationCount == 0)
    }

    @Test
    func automaticPreflightRechecksLockImmediatelyBeforeCommit()
        async throws
    {
        let fixture = PreflightFixture(
            source: .automaticInitial,
            lockStates: [.unlocked, .locked],
            destinationIsReady: true
        )

        let outcome = try await fixture.workflow.run(
            fixture.request,
            callbacks: fixture.callbacks { _ in }
        )

        guard case .deviceLocked(let device) = outcome else {
            Issue.record("提交前重新锁屏必须阻止自动续签")
            return
        }
        #expect(device.id == fixture.device.id)
        #expect(device.name == fixture.device.name)
        #expect(fixture.installationVerificationCount == 1)
        #expect(fixture.lockInspectionCount == 2)
    }
}

@MainActor
private final class PreflightFixture {
    let device: DeviceInfo
    let workflow: DeploymentPreflightWorkflow
    let request: DeploymentPreflightWorkflow.Request
    private let lockRunner: PreflightLockRunner
    private(set) var installationVerificationCount = 0

    var lockInspectionCount: Int {
        lockRunner.invocationCount
    }

    init(
        source: RefreshTriggerSource,
        lockStates: [DeviceLockState],
        destinationIsReady: Bool
    ) {
        let device = DeviceInfo(
            id: "iphone-preflight",
            name: "Preflight iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        self.device = device
        let deviceRunner = PreflightDeviceRunner(
            deviceID: device.id,
            deviceName: device.name
        )
        let lockRunner = PreflightLockRunner(states: lockStates)
        self.lockRunner = lockRunner
        let projectResolver = XcodeProjectResolver {
            _, arguments, _ in
            if arguments.contains("-list") {
                return CommandResult(
                    standardOutput:
                        #"{"project":{"schemes":["Preflight"],"targets":["Preflight"]}}"#,
                    standardError: "",
                    terminationStatus: 0
                )
            }
            return CommandResult(
                standardOutput: """
                [{
                  "target": "Preflight",
                  "buildSettings": {
                    "PRODUCT_TYPE":
                      "com.apple.product-type.application",
                    "PRODUCT_BUNDLE_IDENTIFIER":
                      "com.example.preflight",
                    "PLATFORM_NAME": "iphoneos"
                  }
                }]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
        let destinationInspector = XcodeDestinationReadinessInspector {
            _, _, _ in
            CommandResult(
                standardOutput: destinationIsReady
                    ? "Available destinations:\n"
                        + "{ platform:iOS, id:\(device.id), name:\(device.name) }"
                    : "",
                standardError: destinationIsReady
                    ? ""
                    : "模拟 destination 不可确认",
                terminationStatus: destinationIsReady ? 0 : 1
            )
        }
        self.workflow = DeploymentPreflightWorkflow(
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            deviceMatcher: DeviceMatcher(),
            deviceLockStateInspector: DeviceLockStateInspector(
                runCommand: lockRunner.run
            ),
            xcodeProjectResolver: projectResolver,
            xcodeDestinationReadinessInspector: destinationInspector,
            validateEnvironment: { _ in
                EnvironmentStatus(
                    isXcodebuildAvailable: true,
                    isXcrunAvailable: true,
                    isProjectPathValid: true,
                    isApplicationTargetResolved: true,
                    summary: "测试环境通过"
                )
            }
        )
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-preflight-\(UUID().uuidString)",
                isDirectory: true
            )
        let config = AppConfig(
            projectRootPath: projectRoot.path,
            deployScriptPath: projectRoot
                .appendingPathComponent(
                    "scripts/deploy/ios-device.command"
                ).path,
            xcodeprojPath: projectRoot
                .appendingPathComponent("Preflight.xcodeproj").path,
            scheme: "Preflight",
            targetName: "Preflight",
            bundleID: "com.example.preflight",
            preferredDeviceID: device.id,
            preferredDeviceName: device.name,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: source.isAutomatic
                ? .autoRefreshWhenExpired
                : .reminderOnly
        )
        let context = DeploymentContext(
            generation: 1,
            config: config,
            device: device,
            deviceDetectionRollout: .init(
                mode: .fallback,
                generation: 1
            ),
            source: source,
            profileRefreshMode: .automatic,
            installationIdentity: .init(state: .default)
        )
        self.request = DeploymentPreflightWorkflow.Request(
            context: context,
            expectedDeviceID: StableDeviceID(device.id)!,
            targetStrategy: .compatibility
        )
    }

    func callbacks(
        progress: @escaping @MainActor (
            DeploymentPreflightProgress
        ) -> Void
    ) -> DeploymentPreflightWorkflow.Callbacks {
        DeploymentPreflightWorkflow.Callbacks(
            isCurrent: { true },
            verifyAutomaticInstallation: { [weak self] _, _ in
                self?.installationVerificationCount += 1
                return true
            },
            isAutomaticRefreshEligible: { true },
            reportProgress: progress
        )
    }
}

private final class PreflightDeviceRunner: @unchecked Sendable {
    private let deviceID: String
    private let deviceName: String

    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeout: TimeInterval?
    ) throws -> CommandResult {
        if arguments.first == "xcdevice" {
            return CommandResult(
                standardOutput: """
                [{
                  "simulator": false,
                  "available": true,
                  "platform": "com.apple.platform.iphoneos",
                  "identifier": "\(deviceID)",
                  "name": "\(deviceName)",
                  "modelCode": "iPhone18,1",
                  "modelName": "iPhone",
                  "operatingSystemVersion": "27.0"
                }]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
        guard let outputPath = Self.outputPath(arguments) else {
            return CommandResult(
                standardOutput: "",
                standardError: "缺少 devicectl 输出路径",
                terminationStatus: 1
            )
        }
        let output = """
        {"result":{"devices":[{
          "identifier":"coredevice-preflight",
          "available":true,
          "deviceProperties":{
            "name":"\(deviceName)",
            "osVersionNumber":"27.0",
            "deviceClass":"iPhone"
          },
          "hardwareProperties":{
            "udid":"\(deviceID)",
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            "connectionState":"connected",
            "pairingState":"paired",
            "transportType":"localNetwork",
            "tunnelState":"connected"
          }
        }]}}
        """
        try output.write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }

    fileprivate static func outputPath(
        _ arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private final class PreflightLockRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let states: [DeviceLockState]
    private var count = 0

    init(states: [DeviceLockState]) {
        self.states = states
    }

    var invocationCount: Int {
        lock.withLock { count }
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeout: TimeInterval?
    ) throws -> CommandResult {
        let state = lock.withLock {
            let index = min(count, max(states.count - 1, 0))
            count += 1
            return states.isEmpty ? .unknown : states[index]
        }
        guard let outputPath = PreflightDeviceRunner.outputPath(arguments)
        else {
            return CommandResult(
                standardOutput: "",
                standardError: "缺少锁态输出路径",
                terminationStatus: 1
            )
        }
        let result: String
        switch state {
        case .locked:
            result = #"{"result":{"locked":true}}"#
        case .unlocked:
            result = #"{"result":{"locked":false}}"#
        case .unknown:
            result = #"{"result":{"locked":"unknown"}}"#
        }
        try result.write(
            toFile: outputPath,
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
