import Foundation
import Testing
@testable import IOSSignKit

struct DeployServiceTests {
    @Test
    func standardProjectAndWorkspaceNeedNoTargetRepositoryScript() throws {
        for (kind, mode) in [
            (XcodeContainer.Kind.project, ProvisioningProfileRefreshMode.automatic),
            (XcodeContainer.Kind.workspace, ProvisioningProfileRefreshMode.force)
        ] {
            let fixture = try DeployServiceFixture(kind: kind)
            let expiry = Date(timeIntervalSince1970: 1_820_000_000)
            let execution = FakeDeploymentExecutionForService(
                processGroupIdentifier: 431,
                result: DeploymentExecutionResult(
                    commandResult: .serviceTestResult(
                        output: "installed",
                        status: 0
                    ),
                    verifiedProfileExpirationDate: expiry
                )
            )
            let requests = ServiceRequestRecorder(execution: execution)
            let service = DeployService(
                logStore: LogStore(
                    logsDirectoryURL: fixture.rootURL
                        .appendingPathComponent("logs", isDirectory: true)
                ),
                startStandardDeployment: requests.start
            )
            let token = DeploymentToken.make().rawValue

            let deployment = try service.startDeploy(
                config: fixture.config,
                target: fixture.target,
                deploymentToken: token,
                profileRefreshMode: mode
            )
            let result = deployment.waitUntilExit()
            let request = try #require(requests.requests.first)

            #expect(fixture.config.deployScriptPath == nil)
            #expect(requests.requests.count == 1)
            #expect(request.projectRootURL.path == fixture.rootURL.path)
            #expect(request.container.kind == kind)
            #expect(request.container.path == fixture.containerURL.path)
            #expect(request.scheme == "Example")
            #expect(request.targetName == "Example")
            #expect(request.bundleIdentifier == "com.example.App")
            #expect(request.deviceID == "device-id")
            #expect(request.deviceName == "测试 iPhone")
            #expect(request.deploymentToken == token)
            #expect(request.profileRefreshMode == mode)
            #expect(deployment.processGroupIdentifier == 431)
            #expect(result.isSuccess)
            #expect(result.verifiedProfileExpirationDate == expiry)
            #expect(execution.waitCount == 1)
        }
    }

    @Test
    func rejectsOutsideOrUnsupportedContainerBeforeCallingExecutor() throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let execution = FakeDeploymentExecutionForService.success()
        let requests = ServiceRequestRecorder(execution: execution)
        let service = DeployService(startStandardDeployment: requests.start)

        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-outside-container-\(UUID().uuidString)",
                isDirectory: true
            )
        let outsideContainer = outsideRoot.appendingPathComponent(
            "Outside.xcodeproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideContainer,
            withIntermediateDirectories: true
        )
        var outsideConfig = fixture.config
        outsideConfig.xcodeprojPath = outsideContainer.path

        #expect(throws: DeployServiceError.unresolvedApplicationTarget) {
            _ = try service.startDeploy(
                config: outsideConfig,
                target: fixture.target,
                deploymentToken: DeploymentToken.make().rawValue
            )
        }

        let unsupportedContainer = fixture.rootURL
            .appendingPathComponent("Package.swift")
        try "// fixture".write(
            to: unsupportedContainer,
            atomically: true,
            encoding: .utf8
        )
        var unsupportedConfig = fixture.config
        unsupportedConfig.xcodeprojPath = unsupportedContainer.path

        #expect(throws: DeployServiceError.unresolvedApplicationTarget) {
            _ = try service.startDeploy(
                config: unsupportedConfig,
                target: fixture.target,
                deploymentToken: DeploymentToken.make().rawValue
            )
        }
        #expect(requests.requests.isEmpty)
    }

    @Test
    func defaultExecutorRejectsMissingContainerWithoutLaunchingXcode() throws {
        let fixture = try DeployServiceFixture(kind: .project)
        var config = fixture.config
        config.xcodeprojPath = fixture.rootURL
            .appendingPathComponent("Missing.xcodeproj", isDirectory: true)
            .path

        #expect(throws: StandardIOSDeploymentError.invalidContainer) {
            _ = try DeployService().startDeploy(
                config: config,
                target: fixture.target,
                deploymentToken: DeploymentToken.make().rawValue
            )
        }
    }

    @Test
    func invalidDeploymentTokenFailsBeforeCallingExecutor() throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let execution = FakeDeploymentExecutionForService.success()
        let requests = ServiceRequestRecorder(execution: execution)
        let service = DeployService(startStandardDeployment: requests.start)

        #expect(throws: DeployServiceError.invalidDeploymentToken) {
            _ = try service.startDeploy(
                config: fixture.config,
                target: fixture.target,
                deploymentToken: "invalid/token"
            )
        }
        #expect(requests.requests.isEmpty)
    }

    @Test
    func capturedDestinationFailureProducesTypedActionableResult() throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let commandResult = CommandResult.serviceTestResult(
            output: """
            xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
            { platform:iOS, id:device-id, name:测试 iPhone, error:测试 iPhone may need to be unlocked to recover from previously reported preparation errors }
            """,
            status: 70
        )
        let execution = FakeDeploymentExecutionForService(
            result: DeploymentExecutionResult(
                commandResult: commandResult,
                verifiedProfileExpirationDate: nil
            )
        )
        let recorder = ServiceRequestRecorder(execution: execution)
        let result = try DeployService(
            logStore: LogStore(
                logsDirectoryURL: fixture.rootURL
                    .appendingPathComponent("logs", isDirectory: true)
            ),
            startStandardDeployment: recorder.start
        ).runDeploy(config: fixture.config, target: fixture.target)

        #expect(result.outcome == .failure)
        #expect(result.failureReason == .devicePreparationRequired)
        #expect(
            result.summary
                == "Xcode 无法准备目标 iPhone；请解锁设备，等待 Xcode 完成设备准备后重试。"
        )
    }

    @Test
    func logFailureDoesNotRewriteSuccessfulDeploymentAsFailure() throws {
        let fixture = try DeployServiceFixture(kind: .workspace)
        let blockedLogDirectory = fixture.rootURL
            .appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedLogDirectory)
        let execution = FakeDeploymentExecutionForService.success()
        let recorder = ServiceRequestRecorder(execution: execution)
        let result = try DeployService(
            logStore: LogStore(logsDirectoryURL: blockedLogDirectory),
            startStandardDeployment: recorder.start
        ).runDeploy(config: fixture.config, target: fixture.target)

        #expect(result.isSuccess)
        #expect(result.logPath == nil)
        #expect(result.logWarning?.contains("日志保存失败") == true)
    }

    @Test
    func truncatedOutputKeepsDeploymentOutcomeAndReturnsVisibleWarning() throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let execution = FakeDeploymentExecutionForService(
            result: DeploymentExecutionResult(
                commandResult: CommandResult(
                    standardOutput: "HEAD…TAIL",
                    standardError: "",
                    terminationStatus: 0,
                    standardOutputWasTruncated: true
                ),
                verifiedProfileExpirationDate: nil
            )
        )
        let recorder = ServiceRequestRecorder(execution: execution)
        let logDirectoryURL = fixture.rootURL
            .appendingPathComponent("logs", isDirectory: true)
        let result = try DeployService(
            logStore: LogStore(logsDirectoryURL: logDirectoryURL),
            startStandardDeployment: recorder.start
        ).runDeploy(config: fixture.config, target: fixture.target)

        #expect(result.isSuccess)
        #expect(result.logWarning?.contains("仅保留头尾片段") == true)
        let logPath = try #require(result.logPath)
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(log.contains("stdout_truncated=true"))
    }

    @Test
    func concurrentResultWaitersWriteOnlyOneLogAndWaitOnce() async throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let logURL = fixture.rootURL
            .appendingPathComponent("logs", isDirectory: true)
        let execution = FakeDeploymentExecutionForService.success()
        let recorder = ServiceRequestRecorder(execution: execution)
        let deployment = try DeployService(
            logStore: LogStore(logsDirectoryURL: logURL),
            startStandardDeployment: recorder.start
        ).startDeploy(
            config: fixture.config,
            target: fixture.target,
            deploymentToken: DeploymentToken.make().rawValue
        )

        async let first = deployment.result()
        async let second = deployment.result()
        let (firstResult, secondResult) = await (first, second)
        let logs = try LogStore(logsDirectoryURL: logURL).listLogFiles()

        #expect(firstResult == secondResult)
        #expect(execution.waitCount == 1)
        #expect(logs.count == 1)
    }

    @Test
    func cancelAndWaitCompletesSingleFlightLogSettlement() async throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let logURL = fixture.rootURL
            .appendingPathComponent("logs", isDirectory: true)
        let execution = FakeDeploymentExecutionForService(
            processGroupIdentifier: 777,
            result: nil
        )
        let recorder = ServiceRequestRecorder(execution: execution)
        let deployment = try DeployService(
            logStore: LogStore(logsDirectoryURL: logURL),
            startStandardDeployment: recorder.start
        ).startDeploy(
            config: fixture.config,
            target: fixture.target,
            deploymentToken: DeploymentToken.make().rawValue
        )
        let existingWaiter = Task {
            await deployment.result()
        }

        let cancellationResult = try #require(
            deployment.cancelAndWaitForTermination()
        )
        let existingResult = await existingWaiter.value
        let logs = try LogStore(logsDirectoryURL: logURL).listLogFiles()

        #expect(cancellationResult == existingResult)
        #expect(cancellationResult.outcome == .cancelled)
        #expect(cancellationResult.processGroupTerminationWasConfirmed)
        #expect(execution.cancelCount == 1)
        #expect(execution.waitCount == 1)
        #expect(logs.count == 1)
    }

    @Test
    func unconfirmedProcessGroupIsPreservedInResultAndLog() throws {
        let fixture = try DeployServiceFixture(kind: .project)
        let execution = FakeDeploymentExecutionForService(
            result: DeploymentExecutionResult(
                commandResult: CommandResult(
                    standardOutput: "",
                    standardError: "child still alive",
                    terminationStatus: 1,
                    processGroupTerminationWasConfirmed: false
                ),
                verifiedProfileExpirationDate: nil
            )
        )
        let recorder = ServiceRequestRecorder(execution: execution)
        let result = try DeployService(
            logStore: LogStore(
                logsDirectoryURL: fixture.rootURL
                    .appendingPathComponent("logs", isDirectory: true)
            ),
            startStandardDeployment: recorder.start
        ).runDeploy(config: fixture.config, target: fixture.target)

        #expect(!result.processGroupTerminationWasConfirmed)
        let logPath = try #require(result.logPath)
        let log = try String(contentsOfFile: logPath, encoding: .utf8)
        #expect(log.contains("process_group_termination_confirmed=false"))
    }

    @Test
    func shutdownDoesNotWaitPastDeadlineForResultSettlement() async throws {
        let blockingResolver = BlockingDeployResultResolver()
        defer { blockingResolver.release() }
        let execution = FakeDeploymentExecutionForService.success()
        let deployment = RunningDeploy(
            startedAt: Date(),
            execution: execution,
            deploymentToken: DeploymentToken.make().rawValue,
            targetDeviceID: "device-id",
            logStore: LogStore(),
            resolveCommandResult: blockingResolver.resolve
        )
        let resultTask = Task.detached {
            deployment.waitUntilExit()
        }
        for _ in 0..<100 where !blockingResolver.wasEntered {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(blockingResolver.wasEntered)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let outcome = deployment.shutdown(timeoutSeconds: 0.05)
        let elapsed = startedAt.duration(to: clock.now)

        guard case .processTerminatedResultPending = outcome else {
            Issue.record("日志结算仍在阻塞时应返回 pending，而不是无限等待。")
            blockingResolver.release()
            _ = await resultTask.value
            return
        }
        #expect(elapsed < .milliseconds(500))

        blockingResolver.release()
        #expect((await resultTask.value).isSuccess)
    }

    @Test
    func legacyDeployResultDefaultsProcessGroupConfirmationToTrue() throws {
        let json = """
        {
          "startedAt": "2026-07-27T00:00:00Z",
          "finishedAt": "2026-07-27T00:01:00Z",
          "outcome": "success",
          "summary": "续签已完成。",
          "logPath": null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let result = try decoder.decode(
            DeployResult.self,
            from: Data(json.utf8)
        )

        #expect(result.processGroupTerminationWasConfirmed)
    }

    @Test
    func deploymentTargetRejectsUnverifiedOrUnsafeDevices() {
        let valid = makeDeployDevice()
        let cases: [(DeviceInfo, DeploymentTargetError)] = [
            (
                DeviceInfo(
                    id: " ", name: valid.name, platform: valid.platform,
                    osVersion: valid.osVersion, isAvailable: true,
                    isPaired: true
                ),
                .invalidDeviceIdentity
            ),
            (
                DeviceInfo(
                    id: valid.id, name: " ", platform: valid.platform,
                    osVersion: valid.osVersion, isAvailable: true,
                    isPaired: true
                ),
                .invalidDeviceIdentity
            ),
            (
                DeviceInfo(
                    id: valid.id, name: valid.name, platform: valid.platform,
                    osVersion: valid.osVersion, isAvailable: false,
                    isPaired: true
                ),
                .deviceUnavailable(valid.name)
            ),
            (
                DeviceInfo(
                    id: valid.id, name: valid.name, platform: valid.platform,
                    osVersion: valid.osVersion, isAvailable: true,
                    isPaired: false
                ),
                .deviceNotPaired(valid.name)
            ),
            (valid, .deviceNotVerified(valid.name))
        ]

        for (device, expectedError) in cases {
            do {
                let scannedDevices = expectedError == .deviceNotVerified(valid.name)
                    ? []
                    : [device]
                _ = try CompatibilityDeploymentTarget(
                    device: device,
                    availableDevices: scannedDevices
                )
                Issue.record("不安全的设备目标不应通过验证：\(device)")
            } catch let error as DeploymentTargetError {
                #expect(error == expectedError)
            } catch {
                Issue.record("收到非预期错误：\(error)")
            }
        }
    }

    @Test
    func logRetentionKeepsNewestDeployLogsWithoutDeletingUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-log-retention-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = LogStore(
            logsDirectoryURL: directory,
            maximumLogCount: 2,
            maximumTotalBytes: 1_024
        )
        let dates = [100.0, 200.0, 300.0].map(
            Date.init(timeIntervalSince1970:)
        )
        for date in dates {
            let url = directory.appendingPathComponent(
                DeployLogFilename.make(for: date)
            )
            try store.writeLog("log-\(date.timeIntervalSince1970)", to: url)
        }
        let unrelated = directory.appendingPathComponent("manual-notes.log")
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)

        let names = Set(try store.listLogFiles().map(\.lastPathComponent))

        #expect(!names.contains(DeployLogFilename.make(for: dates[0])))
        #expect(names.contains(DeployLogFilename.make(for: dates[1])))
        #expect(names.contains(DeployLogFilename.make(for: dates[2])))
        #expect(names.contains(unrelated.lastPathComponent))
    }
}

private final class ServiceRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let execution: any DeploymentExecution
    private var capturedRequests: [StandardIOSDeploymentRequest] = []

    init(execution: any DeploymentExecution) {
        self.execution = execution
    }

    var requests: [StandardIOSDeploymentRequest] {
        lock.withLock { capturedRequests }
    }

    func start(
        _ request: StandardIOSDeploymentRequest,
        _ onOutput: (@Sendable (String, Bool) -> Void)?
    ) throws -> any DeploymentExecution {
        lock.withLock { capturedRequests.append(request) }
        return execution
    }
}

private final class FakeDeploymentExecutionForService:
    DeploymentExecution,
    @unchecked Sendable {
    let processGroupIdentifier: Int32
    private let condition = NSCondition()
    private var storedResult: DeploymentExecutionResult?
    private var waits = 0
    private var cancellations = 0

    init(
        processGroupIdentifier: Int32 = 100,
        result: DeploymentExecutionResult?
    ) {
        self.processGroupIdentifier = processGroupIdentifier
        storedResult = result
    }

    static func success() -> FakeDeploymentExecutionForService {
        FakeDeploymentExecutionForService(
            result: DeploymentExecutionResult(
                commandResult: .serviceTestResult(output: "done", status: 0),
                verifiedProfileExpirationDate: nil
            )
        )
    }

    var waitCount: Int { condition.withLock { waits } }
    var cancelCount: Int { condition.withLock { cancellations } }

    func cancel() {
        condition.withLock {
            cancellations += 1
            guard storedResult == nil else { return }
            storedResult = DeploymentExecutionResult(
                commandResult: CommandResult(
                    standardOutput: "",
                    standardError: "cancelled",
                    terminationStatus: 130
                ),
                verifiedProfileExpirationDate: nil
            )
            condition.broadcast()
        }
    }

    func cancelAndWaitForTermination(
        timeoutSeconds: TimeInterval
    ) -> Bool {
        cancel()
        return condition.withLock {
            storedResult?.commandResult
                .processGroupTerminationWasConfirmed == true
        }
    }

    func waitUntilExit() -> DeploymentExecutionResult {
        condition.lock()
        waits += 1
        while storedResult == nil { condition.wait() }
        let result = storedResult!
        condition.unlock()
        return result
    }
}

private final class BlockingDeployResultResolver: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var entered = false

    var wasEntered: Bool { lock.withLock { entered } }
    func release() { releaseSemaphore.signal() }

    func resolve(_ commandResult: CommandResult) -> DeployResult {
        lock.withLock { entered = true }
        releaseSemaphore.wait()
        return DeployResult(
            startedAt: Date(),
            finishedAt: Date(),
            outcome: commandResult.terminationStatus == 0
                ? .success
                : .failure,
            summary: "续签已完成。",
            logPath: nil
        )
    }
}

private struct DeployServiceFixture {
    let rootURL: URL
    let containerURL: URL
    let config: AppConfig
    let target: DeploymentStartTarget

    init(kind: XcodeContainer.Kind) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-deploy-service-\(UUID().uuidString)",
                isDirectory: true
            )
        let extensionName = kind == .project ? "xcodeproj" : "xcworkspace"
        containerURL = rootURL.appendingPathComponent(
            "Example.\(extensionName)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        config = AppConfig(
            projectRootPath: rootURL.path,
            deployScriptPath: nil,
            xcodeprojPath: containerURL.path,
            scheme: "Example",
            targetName: "Example",
            bundleID: "com.example.App",
            preferredDeviceID: "device-id",
            preferredDeviceName: "测试 iPhone",
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        let device = makeDeployDevice()
        target = .compatibility(
            try CompatibilityDeploymentTarget(
                device: device,
                availableDevices: [device]
            )
        )
    }
}

private func makeDeployDevice() -> DeviceInfo {
    DeviceInfo(
        id: "device-id",
        name: "测试 iPhone",
        platform: "com.apple.platform.iphoneos",
        osVersion: "27.0",
        isAvailable: true,
        isPaired: true
    )
}

private extension CommandResult {
    static func serviceTestResult(
        output: String,
        status: Int32
    ) -> CommandResult {
        CommandResult(
            standardOutput: output,
            standardError: "",
            terminationStatus: status
        )
    }
}
