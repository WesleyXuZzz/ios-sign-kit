import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct MenuBarViewModelDeploymentVerificationTests {
    @Test
    func readOnlyRejectsBothDirectAndRefreshNowDeploymentRequests()
        async throws
    {
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: .readOnly,
            finalEvidence: .complete
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )
        let refreshNowOutcome = fixture.viewModel.refreshNow()

        #expect(refreshNowOutcome == .rejected)
        #expect(fixture.transactionRecorder.startDeployCount == 0)
        #expect(fixture.deviceRunner.xcdeviceInvocationCount == 0)
        #expect(fixture.deviceRunner.devicectlInvocationCount == 0)
        #expect(!fixture.viewModel.state.isDeployRunning)
        #expect(fixture.viewModel.state.activeDeploymentToken == nil)
        #expect(!fixture.stateStore.loadState().isDeployRunning)
        #expect(fixture.stateStore.loadState().activeDeploymentToken == nil)
        await fixture.shutdown()
    }

    @Test
    func canonicalRunsOneCompleteFinalVerificationAfterSlowPreflightBeforeStartDeploy()
        async throws
    {
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: .production,
            finalEvidence: .complete
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )

        await fixture.viewModel.waitForDeploymentToSettle()
        let startSnapshot = try #require(
            fixture.transactionRecorder.startSnapshot
        )
        let events = fixture.sequence.events

        #expect(startSnapshot.xcdeviceCountAtStart == 2)
        #expect(startSnapshot.devicectlCountAtStart == 2)
        #expect(startSnapshot.persistedState.isDeployRunning)
        #expect(
            startSnapshot.persistedState.activeDeploymentToken
                == startSnapshot.deploymentToken
        )
        await fixture.shutdown()
        #expect(startSnapshot.targetDeviceID == fixture.device.id)
        #expect(
            orderedDeploymentVerificationEvents(
                [
                    "device:xcdevice:1",
                    "device:devicectl:1",
                    "lock",
                    "project:list",
                    "project:settings",
                    "destination",
                    "device:xcdevice:2",
                    "device:devicectl:2",
                    "startDeploy"
                ],
                in: events
            )
        )
    }

    @Test
    func canonicalDeploymentDoesNotUseCompatibilityConflictForWirelessTunnelUncertainty()
        async throws
    {
        let productionPolicy = DeviceDetectionRolloutConfiguration(
            processEnvironment: [:]
        ).mode
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: productionPolicy,
            preliminaryEvidence: .transportUncertain,
            finalEvidence: .transportUncertain
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )

        await fixture.viewModel.waitForDeploymentToSettle()

        #expect(fixture.transactionRecorder.startDeployCount == 1)
        let startSnapshot = try #require(
            fixture.transactionRecorder.startSnapshot
        )
        #expect(startSnapshot.xcdeviceCountAtStart == 2)
        #expect(startSnapshot.devicectlCountAtStart == 2)
        #expect(
            orderedDeploymentVerificationEvents(
                [
                    "device:xcdevice:1",
                    "device:devicectl:1",
                    "lock",
                    "project:list",
                    "project:settings",
                    "destination",
                    "device:xcdevice:2",
                    "device:devicectl:2",
                    "startDeploy"
                ],
                in: fixture.sequence.events
            )
        )
        await fixture.shutdown()
    }

    @Test
    func canonicalDeploymentStopsOnExplicitUnavailabilityBeforeSlowPreflight()
        async throws
    {
        let productionPolicy = DeviceDetectionRolloutConfiguration(
            processEnvironment: [:]
        ).mode
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: productionPolicy,
            preliminaryEvidence: .conflict,
            finalEvidence: .complete
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )

        await fixture.viewModel.waitForDeploymentToSettle()

        #expect(fixture.transactionRecorder.startDeployCount == 0)
        #expect(fixture.deviceRunner.xcdeviceInvocationCount >= 1)
        #expect(fixture.deviceRunner.devicectlInvocationCount >= 1)
        #expect(
            Array(fixture.sequence.events.prefix(2))
                == [
                    "device:xcdevice:1",
                    "device:devicectl:1"
                ]
        )
        #expect(!fixture.sequence.events.contains("lock"))
        #expect(!fixture.sequence.events.contains("destination"))
        #expect(!fixture.sequence.events.contains("startDeploy"))
        #expect(fixture.viewModel.state.activeDeploymentToken == nil)
        #expect(!fixture.stateStore.loadState().isDeployRunning)
        #expect(
            fixture.stateStore.loadState().activeDeploymentToken == nil
        )
        await fixture.shutdown()
    }

    @Test
    func policyRollbackDuringPreflightCancelsBeforeDeploymentStarts()
        async throws
    {
        let lockStateGate = DeploymentVerificationCommandGate()
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: .production,
            finalEvidence: .complete,
            lockStateGate: lockStateGate
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )
        try await fixture.sequence.wait(for: "lock")

        fixture.viewModel.transitionDeviceDetectionRollout(to: .fallback)
        lockStateGate.release()
        await fixture.viewModel.waitForDeploymentToSettle()

        #expect(fixture.transactionRecorder.startDeployCount == 0)
        #expect(!fixture.sequence.events.contains("project:list"))
        #expect(!fixture.sequence.events.contains("destination"))
        #expect(!fixture.sequence.events.contains("startDeploy"))
        #expect(!fixture.viewModel.state.isDeployRunning)
        #expect(fixture.viewModel.state.activeDeploymentToken == nil)
        #expect(!fixture.stateStore.loadState().isDeployRunning)
        #expect(
            fixture.stateStore.loadState().activeDeploymentToken == nil
        )
        await fixture.shutdown()
    }

    @Test
    func policyChangeDuringRunningDeploymentIsAppliedAfterSettlement()
        async throws
    {
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: .production,
            finalEvidence: .complete,
            returnsRunningDeployment: true
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )
        try await fixture.sequence.wait(for: "startDeploy")
        await fixture.viewModel.waitForDeploymentToStartOrSettle()

        fixture.viewModel.transitionDeviceDetectionRollout(
            to: .readOnly
        )
        #expect(fixture.viewModel.state.isDeployRunning)
        #expect(fixture.viewModel.canCancelRefresh)

        fixture.viewModel.cancelRefresh()
        await fixture.viewModel.waitForDeploymentToSettle()

        let commandsBeforeRejectedStart =
            fixture.deviceRunner.xcdeviceInvocationCount
                + fixture.deviceRunner.devicectlInvocationCount
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )

        #expect(fixture.transactionRecorder.startDeployCount == 1)
        #expect(
            fixture.deviceRunner.xcdeviceInvocationCount
                + fixture.deviceRunner.devicectlInvocationCount
                == commandsBeforeRejectedStart
        )
        await fixture.shutdown()
        #expect(
            fixture.viewModel.deployMessage?
                .contains("只读验证阶段") == true
        )
    }

    @Test(arguments: [
        Canonical3FinalEvidence.partial,
        Canonical3FinalEvidence.conflict,
        Canonical3FinalEvidence.absent,
        Canonical3FinalEvidence.unavailable,
        Canonical3FinalEvidence.failed
    ])
    func invalidFinalEvidenceCannotPersistTokenOrStartDeploy(
        finalEvidence: Canonical3FinalEvidence
    ) async throws {
        let fixture = try DeploymentVerificationFixture(
            rolloutMode: .production,
            finalEvidence: finalEvidence
        )
        fixture.viewModel.beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )

        await fixture.viewModel.waitForDeploymentToSettle()
        let persistedState = fixture.stateStore.loadState()
        let events = fixture.sequence.events

        #expect(fixture.deviceRunner.xcdeviceInvocationCount >= 2)
        #expect(fixture.deviceRunner.devicectlInvocationCount >= 2)
        #expect(fixture.transactionRecorder.startDeployCount == 0)
        #expect(!fixture.viewModel.state.isDeployRunning)
        #expect(fixture.viewModel.state.activeDeploymentToken == nil)
        #expect(!persistedState.isDeployRunning)
        #expect(persistedState.activeDeploymentToken == nil)
        #expect(
            orderedDeploymentVerificationEvents(
                [
                    "lock",
                    "project:list",
                    "project:settings",
                    "destination",
                    "device:xcdevice:2",
                    "device:devicectl:2"
                ],
                in: events
            )
        )
        #expect(!events.contains("startDeploy"))
        await fixture.shutdown()
    }

    @Test(arguments: [
        Canonical3FinalEvidence.partial,
        Canonical3FinalEvidence.conflict,
        Canonical3FinalEvidence.absent,
        Canonical3FinalEvidence.unavailable,
        Canonical3FinalEvidence.failed
    ])
    func automaticPathsAlsoFailClosedOnInvalidFinalEvidence(
        finalEvidence: Canonical3FinalEvidence
    ) async throws {
        for source in [
            RefreshTriggerSource.automaticInitial,
            .automaticRecovery
        ] {
            let fixture = try DeploymentVerificationFixture(
                rolloutMode: .production,
                finalEvidence: finalEvidence
            )
            fixture.viewModel.config.autoRefreshPolicy =
                .autoRefreshWhenExpired

            fixture.viewModel.beginRefresh(
                source: source,
                profileRefreshMode: .automatic
            )

            await fixture.viewModel.waitForDeploymentToSettle()
            let persistedState = fixture.stateStore.loadState()

            #expect(fixture.transactionRecorder.startDeployCount == 0)
            #expect(!fixture.viewModel.state.isDeployRunning)
            #expect(
                fixture.viewModel.state.activeDeploymentToken == nil
            )
            #expect(!persistedState.isDeployRunning)
            #expect(persistedState.activeDeploymentToken == nil)
            #expect(!fixture.sequence.events.contains("startDeploy"))

            await fixture.shutdown()
        }
    }
}

enum Canonical3FinalEvidence: Equatable, Sendable {
    case complete
    case partial
    case conflict
    case transportUncertain
    case absent
    case unavailable
    case failed
}

@MainActor
private final class DeploymentVerificationFixture {
    let device = DeviceInfo(
        id: "iphone-verification-deploy",
        name: "Verification Deployment iPhone",
        platform: "com.apple.platform.iphoneos",
        osVersion: "27.0",
        isAvailable: true,
        isPaired: true
    )
    let stateStore: RefreshStateStore
    let sequence = DeploymentVerificationSequence()
    let deviceRunner: DeploymentVerificationDeviceRunner
    let transactionRecorder: DeploymentVerificationTransactionRecorder
    let viewModel: MenuBarViewModel

    init(
        rolloutMode: DeviceDetectionRolloutMode,
        preliminaryEvidence: Canonical3FinalEvidence = .complete,
        finalEvidence: Canonical3FinalEvidence,
        lockStateGate: DeploymentVerificationCommandGate? = nil,
        returnsRunningDeployment: Bool = false
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-canonical3-deployment-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        let scriptURL = projectURL.appendingPathComponent(
            "scripts/deploy/ios-device.command"
        )
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 1\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let xcodeProjectURL = projectURL.appendingPathComponent(
            "Verification.xcodeproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: xcodeProjectURL,
            withIntermediateDirectories: true
        )

        let config = AppConfig(
            projectRootPath: projectURL.path,
            deployScriptPath: scriptURL.path,
            xcodeprojPath: xcodeProjectURL.path,
            scheme: "Verification",
            targetName: "Verification",
            bundleID: "com.example.verificationdeployment",
            preferredDeviceID: device.id,
            preferredDeviceName: device.name,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        var state = AppState.default
        state.currentDeviceStatus = "online"
        state.currentDeviceName = device.name
        state.currentDeviceOS = device.osVersion
        state.lastDeviceSeenAt = Date()
        state.targetAppPresence = .installed
        state.targetAppBundleID = config.bundleID
        state.targetDeviceID = device.id
        state.targetAppVersion = "1.0"
        state.targetAppBuildVersion = "1"
        state.targetAppURL =
            "file:///private/var/containers/Bundle/Application/11111111-1111-1111-1111-111111111111/Verification.app"
        state.isTargetAppExpiryEvidenceVerified = true
        state.lastDetectedExpiryAt = Date().addingTimeInterval(-60)
        state.expirySource = "test"

        stateStore = RefreshStateStore(
            appSupportDirectory: rootURL.appendingPathComponent(
                "State",
                isDirectory: true
            )
        )
        try stateStore.saveConfig(config)
        try stateStore.saveState(state)

        deviceRunner = DeploymentVerificationDeviceRunner(
            sequence: sequence,
            preliminaryEvidence: preliminaryEvidence,
            finalEvidence: finalEvidence
        )
        transactionRecorder = DeploymentVerificationTransactionRecorder(
            stateStore: stateStore,
            sequence: sequence
        )
        let sequence = self.sequence
        let transactionRecorder = self.transactionRecorder
        let deviceRunner = self.deviceRunner
        let runningDeployLogStore = LogStore(
            logsDirectoryURL: rootURL.appendingPathComponent(
                "RunningLogs",
                isDirectory: true
            )
        )

        viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: rolloutMode,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver: DeploymentVerificationProjectResolver.make(
                sequence: sequence
            ),
            xcodeDestinationReadinessInspector:
                DeploymentVerificationDestinationInspector.make(
                    sequence: sequence
            ),
            deviceMonitor: DeviceMonitor(runCommand: deviceRunner.run),
            inspectInstalledApp: {
                @Sendable _, bundleID, _, _ in
                InstalledAppInfo(
                    bundleIdentifier: bundleID,
                    name: "Verification",
                    version: "1.0",
                    bundleVersion: "1",
                    appURL:
                        "file:///private/var/containers/Bundle/Application/11111111-1111-1111-1111-111111111111/Verification.app",
                    builtByDeveloper: true,
                    installMetadata: AppInstallMetadataSnapshot(
                        schemaVersion: 1,
                        recordedAt: Date(),
                        bundleIdentifier: bundleID,
                        shortVersion: "1.0",
                        buildVersion: "1",
                        expectedExpiryAt:
                            Date().addingTimeInterval(-60),
                        profileSource: "test"
                    ),
                    installMetadataValidation: .valid
                )
            },
            deviceLockStateInspector:
                DeploymentVerificationLockInspector.make(
                    sequence: sequence,
                    gate: lockStateGate
                ),
            startDeploy: {
                _,
                target,
                deploymentToken,
                _,
                _ in
                transactionRecorder.recordStart(
                    deploymentToken: deploymentToken,
                    targetDeviceID: target.device.id,
                    xcdeviceCount:
                        deviceRunner.xcdeviceInvocationCount,
                    devicectlCount:
                        deviceRunner.devicectlInvocationCount
                )
                if returnsRunningDeployment {
                    let command = try CommandRunner().start(
                        "/bin/sh",
                        arguments: ["-c", "sleep 30"]
                    )
                    return RunningDeploy(
                        startedAt: Date(),
                        command: command,
                        deploymentToken: deploymentToken,
                        targetDeviceID: target.device.id,
                        logStore: runningDeployLogStore
                    )
                }
                throw DeployServiceError.missingDeployScript
            }
        )
        viewModel.stopPolling()
        viewModel.config = config
        viewModel.state = state
        viewModel.environmentStatus = EnvironmentStatus(
            isXcodebuildAvailable: true,
            isXcrunAvailable: true,
            isProjectPathValid: true,
            isApplicationTargetResolved: true,
            summary: "测试环境可用"
        )
        viewModel.availableDevices = [device]
        viewModel.matchedDevice = device
        viewModel.expiryInfo = ExpiryInfo(
            estimatedExpiryAt: Date().addingTimeInterval(-60),
            source: "test",
            detectedAt: Date(),
            isFallbackValue: false
        )
    }

    func shutdown() async {
        viewModel.cancelRefresh()
        await viewModel.shutdown()
    }
}

private final class DeploymentVerificationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private let eventRecorder = TestEventRecorder<String>()

    var events: [String] {
        lock.withLock { values }
    }

    func record(_ event: String) {
        lock.withLock {
            values.append(event)
        }
        eventRecorder.record(event)
    }

    func wait(for expectedEvent: String) async throws {
        while try await eventRecorder.next() != expectedEvent {}
    }
}

private final class DeploymentVerificationDeviceRunner: @unchecked Sendable {
    private let lock = NSLock()
    private let sequence: DeploymentVerificationSequence
    private let preliminaryEvidence: Canonical3FinalEvidence
    private let finalEvidence: Canonical3FinalEvidence
    private var xcdeviceCount = 0
    private var devicectlCount = 0

    init(
        sequence: DeploymentVerificationSequence,
        preliminaryEvidence: Canonical3FinalEvidence,
        finalEvidence: Canonical3FinalEvidence
    ) {
        self.sequence = sequence
        self.preliminaryEvidence = preliminaryEvidence
        self.finalEvidence = finalEvidence
    }

    var xcdeviceInvocationCount: Int {
        lock.withLock { xcdeviceCount }
    }

    var devicectlInvocationCount: Int {
        lock.withLock { devicectlCount }
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        if arguments.first == "xcdevice" {
            let invocation = lock.withLock {
                xcdeviceCount += 1
                return xcdeviceCount
            }
            sequence.record("device:xcdevice:\(invocation)")
            let evidence = invocation == 1
                ? preliminaryEvidence
                : finalEvidence
            return CommandResult(
                standardOutput:
                    evidence == .absent
                        || evidence == .unavailable
                        ? "[]"
                        : DeploymentVerificationDeviceOutput.xcdevice,
                standardError: "",
                terminationStatus: 0
            )
        }

        guard arguments.first == "devicectl",
              let outputPath = DeploymentVerificationDeviceOutput.jsonOutputPath(
                from: arguments
              ) else {
            return CommandResult(
                standardOutput: "",
                standardError: "Unexpected fake device command",
                terminationStatus: 1
            )
        }
        let invocation = lock.withLock {
            devicectlCount += 1
            return devicectlCount
        }
        sequence.record("device:devicectl:\(invocation)")
        let evidence = invocation == 1
            ? preliminaryEvidence
            : finalEvidence
        let output = DeploymentVerificationDeviceOutput.devicectl(
            for: evidence
        )
        try output.write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: evidence == .failed
                ? "CoreDevice unavailable"
                : "",
            terminationStatus: evidence == .failed ? 1 : 0
        )
    }
}

private enum DeploymentVerificationDeviceOutput {
    static let xcdevice = """
    [{
      "simulator": false,
      "available": true,
      "platform": "com.apple.platform.iphoneos",
      "identifier": "iphone-verification-deploy",
      "name": "Verification Deployment iPhone",
      "modelCode": "iPhone18,1",
      "modelName": "iPhone",
      "operatingSystemVersion": "27.0"
    }]
    """

    static let devicectlComplete = devicectl(
        includesCanonicalID: true,
        explicitAvailability: true
    )
    static let devicectlPartial = devicectl(
        includesCanonicalID: false,
        explicitAvailability: true
    )
    static let devicectlConflict = devicectl(
        includesCanonicalID: true,
        explicitAvailability: false
    )
    static let devicectlTransportUncertain = """
    {"result":{"devices":[{
      "identifier":"coredevice-canonical3-deploy",
      "deviceProperties":{
        "name":"Verification Deployment iPhone",
        "osVersionNumber":"27.0",
        "deviceClass":"iPhone",
        "developerModeStatus":"enabled"
      },
      "hardwareProperties":{
        "udid":"iphone-verification-deploy",
        "platform":"iOS",
        "deviceType":"iPhone"
      },
      "connectionProperties":{
        "pairingState":"paired",
        "transportType":"localNetwork",
        "tunnelState":"disconnected"
      }
    }]}}
    """

    static func devicectl(
        for evidence: Canonical3FinalEvidence
    ) -> String {
        switch evidence {
        case .complete:
            return devicectlComplete
        case .partial:
            return devicectlPartial
        case .conflict:
            return devicectlConflict
        case .transportUncertain:
            return devicectlTransportUncertain
        case .unavailable:
            return devicectlConflict
        case .absent, .failed:
            return #"{"result":{"devices":[]}}"#
        }
    }

    static func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func devicectl(
        includesCanonicalID: Bool,
        explicitAvailability: Bool
    ) -> String {
        let udid = includesCanonicalID
            ? #""udid":"iphone-verification-deploy","# : ""
        let connectionState = explicitAvailability
            ? "connected"
            : "unavailable"
        let tunnelState = explicitAvailability
            ? "connected"
            : "disconnected"
        return """
        {"result":{"devices":[{
          "identifier":"coredevice-canonical3-deploy",
          "available":\(explicitAvailability),
          "deviceProperties":{
            "name":"Verification Deployment iPhone",
            "osVersionNumber":"27.0",
            "deviceClass":"iPhone",
            "developerModeStatus":"enabled"
          },
          "hardwareProperties":{
            \(udid)
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            "connectionState":"\(connectionState)",
            "pairingState":"paired",
            "transportType":"localNetwork",
            "tunnelState":"\(tunnelState)"
          }
        }]}}
        """
    }
}

private enum DeploymentVerificationProjectResolver {
    static func make(
        sequence: DeploymentVerificationSequence
    ) -> XcodeProjectResolver {
        XcodeProjectResolver { _, arguments, _ in
            if arguments.contains("-list") {
                sequence.record("project:list")
                return CommandResult(
                    standardOutput:
                        #"{"project":{"schemes":["Verification"],"targets":["Verification"]}}"#,
                    standardError: "",
                    terminationStatus: 0
                )
            }
            sequence.record("project:settings")
            return CommandResult(
                standardOutput: """
                [{
                  "target": "Verification",
                  "buildSettings": {
                    "PRODUCT_TYPE":
                      "com.apple.product-type.application",
                    "PRODUCT_BUNDLE_IDENTIFIER":
                      "com.example.verificationdeployment",
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

private enum DeploymentVerificationDestinationInspector {
    static func make(
        sequence: DeploymentVerificationSequence
    ) -> XcodeDestinationReadinessInspector {
        XcodeDestinationReadinessInspector { _, _, _ in
            sequence.record("destination")
            return CommandResult(
                standardOutput: """
                Available destinations:
                    { platform:iOS, id:iphone-verification-deploy, name:Verification Deployment iPhone }
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
    }
}

private enum DeploymentVerificationLockInspector {
    static func make(
        sequence: DeploymentVerificationSequence,
        gate: DeploymentVerificationCommandGate? = nil
    ) -> DeviceLockStateInspector {
        DeviceLockStateInspector { _, arguments, _ in
            sequence.record("lock")
            gate?.wait()
            guard let outputPath =
                    DeploymentVerificationDeviceOutput.jsonOutputPath(
                        from: arguments
                    ) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "Missing lock-state output",
                    terminationStatus: 1
                )
            }
            try #"{"result":{"locked":false}}"#.write(
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
}

private final class DeploymentVerificationCommandGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didRelease = false

    func wait() {
        let alreadyReleased = lock.withLock { didRelease }
        guard !alreadyReleased else {
            return
        }
        semaphore.wait()
    }

    func release() {
        let shouldSignal = lock.withLock {
            guard !didRelease else {
                return false
            }
            didRelease = true
            return true
        }
        if shouldSignal {
            semaphore.signal()
        }
    }
}

private final class DeploymentVerificationTransactionRecorder:
    @unchecked Sendable
{
    struct StartSnapshot: Sendable {
        let deploymentToken: String
        let targetDeviceID: String
        let xcdeviceCountAtStart: Int
        let devicectlCountAtStart: Int
        let persistedState: AppState
    }

    private let lock = NSLock()
    private let stateStore: RefreshStateStore
    private let sequence: DeploymentVerificationSequence
    private var starts = 0
    private var snapshot: StartSnapshot?

    init(
        stateStore: RefreshStateStore,
        sequence: DeploymentVerificationSequence
    ) {
        self.stateStore = stateStore
        self.sequence = sequence
    }

    var startDeployCount: Int {
        lock.withLock { starts }
    }

    var startSnapshot: StartSnapshot? {
        lock.withLock { snapshot }
    }

    func recordStart(
        deploymentToken: String,
        targetDeviceID: String,
        xcdeviceCount: Int,
        devicectlCount: Int
    ) {
        sequence.record("startDeploy")
        let persistedState = stateStore.loadState()
        lock.withLock {
            starts += 1
            snapshot = StartSnapshot(
                deploymentToken: deploymentToken,
                targetDeviceID: targetDeviceID,
                xcdeviceCountAtStart: xcdeviceCount,
                devicectlCountAtStart: devicectlCount,
                persistedState: persistedState
            )
        }
    }
}

private func orderedDeploymentVerificationEvents(
    _ expected: [String],
    in events: [String]
) -> Bool {
    var searchStart = events.startIndex
    for event in expected {
        guard let index = events[searchStart...].firstIndex(of: event) else {
            return false
        }
        searchStart = events.index(after: index)
    }
    return true
}
