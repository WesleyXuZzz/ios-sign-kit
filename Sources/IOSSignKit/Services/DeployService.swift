import Foundation

struct DeployService: Sendable {
    private let logStore: LogStore
    private let startStandardDeployment: @Sendable (
        StandardIOSDeploymentRequest,
        (@Sendable (String, Bool) -> Void)?
    ) throws -> any DeploymentExecution

    init(commandRunner: CommandRunner = CommandRunner(), logStore: LogStore = LogStore()) {
        self.logStore = logStore
        let executor = StandardIOSDeploymentExecutor(
            commandRunner: commandRunner
        )
        startStandardDeployment = { request, onOutput in
            try executor.start(request: request, onOutput: onOutput)
        }
    }

    init(
        logStore: LogStore = LogStore(),
        startStandardDeployment: @escaping @Sendable (
            StandardIOSDeploymentRequest,
            (@Sendable (String, Bool) -> Void)?
        ) throws -> any DeploymentExecution
    ) {
        self.logStore = logStore
        self.startStandardDeployment = startStandardDeployment
    }

    func startDeploy(
        config: AppConfig,
        target: DeploymentStartTarget,
        deploymentToken: String,
        profileRefreshMode: ProvisioningProfileRefreshMode = .automatic,
        onOutput: (@Sendable (String, Bool) -> Void)? = nil
    ) throws -> RunningDeploy {
        guard config.hasResolvedApplicationTarget else {
            throw DeployServiceError.unresolvedApplicationTarget
        }
        guard let projectRootPath = config.projectRootPath, !projectRootPath.isEmpty else {
            throw DeployServiceError.missingProjectRoot
        }
        guard let xcodeProjectPath = config.xcodeprojPath,
              let scheme = config.scheme,
              let targetName = config.targetName,
              let bundleID = config.bundleID,
              !xcodeProjectPath.contains("\0"),
              !scheme.contains("\0"),
              !targetName.contains("\0"),
              !bundleID.contains("\0") else {
            throw DeployServiceError.unresolvedApplicationTarget
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: projectRootPath,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw DeployServiceError.invalidProjectRoot(projectRootPath)
        }

        let resolvedProjectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard DeploymentToken(rawValue: deploymentToken) != nil else {
            throw DeployServiceError.invalidDeploymentToken
        }

        let resolvedXcodeContainer = URL(
            fileURLWithPath: xcodeProjectPath,
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        guard let xcodeContainer = XcodeContainer(
            path: resolvedXcodeContainer.path
        ),
              resolvedXcodeContainer.path.hasPrefix(
                  resolvedProjectRoot.path + "/"
              ) else {
            throw DeployServiceError.unresolvedApplicationTarget
        }
        let device = target.device
        let execution = try startStandardDeployment(
            StandardIOSDeploymentRequest(
                projectRootURL: resolvedProjectRoot,
                container: xcodeContainer,
                scheme: scheme,
                targetName: targetName,
                bundleIdentifier: bundleID,
                deviceID: device.id,
                deviceName: device.name,
                deploymentToken: deploymentToken,
                profileRefreshMode: profileRefreshMode
            ),
            onOutput
        )

        return RunningDeploy(
            startedAt: Date(),
            execution: execution,
            deploymentToken: deploymentToken,
            targetDeviceID: device.id,
            logStore: logStore
        )
    }

    func runDeploy(
        config: AppConfig,
        target: DeploymentStartTarget,
        profileRefreshMode: ProvisioningProfileRefreshMode = .automatic,
        onOutput: (@Sendable (String, Bool) -> Void)? = nil
    ) throws -> DeployResult {
        let deployment = try startDeploy(
            config: config,
            target: target,
            deploymentToken: DeploymentToken.make().rawValue,
            profileRefreshMode: profileRefreshMode,
            onOutput: onOutput
        )
        return deployment.waitUntilExit()
    }

    static func makeCombinedOutput(
        result: CommandResult,
        failureReason: DeployFailureReason? = nil,
        trigger: RefreshHistoryTrigger? = nil
    ) -> String {
        """
        \(DeployLogFormat.currentVersionHeader)
        exit_status=\(result.terminationStatus)
        trigger=\(trigger?.rawValue ?? "")
        failure_reason=\(failureReason?.rawValue ?? "")
        stdout_truncated=\(result.standardOutputWasTruncated)
        stderr_truncated=\(result.standardErrorWasTruncated)
        process_group_termination_confirmed=\(result.processGroupTerminationWasConfirmed)

        [stdout]
        \(escapedLogSection(result.standardOutput))

        [stderr]
        \(escapedLogSection(result.standardError))
        """
    }

    private static func escapedLogSection(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return "| " + normalized.replacingOccurrences(
            of: "\n",
            with: "\n| "
        )
    }

    static func failureAnalysis(
        from result: CommandResult,
        targetDeviceID: String? = nil
    ) -> DeployFailureAnalysis {
        DeployFailureAnalyzer().analyze(
            exitStatus: Int(result.terminationStatus),
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            targetDeviceID: targetDeviceID
        )
    }
}

enum DeployServiceError: Error, LocalizedError, Equatable {
    case unresolvedApplicationTarget
    case missingDeployScript
    case missingProjectRoot
    case invalidProjectRoot(String)
    case deployScriptOutsideProjectContract(expected: String, actual: String)
    case deployScriptNotExecutable(String)
    case invalidDeploymentToken

    var errorDescription: String? {
        switch self {
        case .unresolvedApplicationTarget:
            return "App 目标配置不完整，请重新识别并选择 Scheme。"
        case .missingDeployScript:
            return "当前版本不再使用目标仓库续签脚本。"
        case .missingProjectRoot:
            return "未配置项目根目录。"
        case .invalidProjectRoot(let path):
            return "项目根目录不存在或不是目录：\(path)"
        case .deployScriptOutsideProjectContract,
             .deployScriptNotExecutable:
            return "当前版本不再执行目标仓库续签脚本，请重新保存项目配置。"
        case .invalidDeploymentToken:
            return "续签事务令牌无效。"
        }
    }
}

enum DeployShutdownOutcome: Sendable {
    case settled(DeployResult)
    case processTerminatedResultPending
    case processUnresolved
}

final class RunningDeploy: @unchecked Sendable {
    private let startedAt: Date
    private let execution: any DeploymentExecution
    let deploymentToken: String
    private let targetDeviceID: String
    private let logStore: LogStore
    private let resolveCommandResult: (@Sendable (CommandResult) -> DeployResult)?
    private let resultLock = NSLock()
    private let resultReady = DispatchGroup()
    private var cachedResult: DeployResult?
    private var isResolvingResult = false
    private var historyTrigger: RefreshHistoryTrigger = .manual

    init(
        startedAt: Date,
        command: RunningCommand,
        deploymentToken: String,
        targetDeviceID: String,
        logStore: LogStore,
        resolveCommandResult: (@Sendable (CommandResult) -> DeployResult)? = nil
    ) {
        self.startedAt = startedAt
        self.execution = SingleCommandDeploymentExecution(command: command)
        self.deploymentToken = deploymentToken
        self.targetDeviceID = targetDeviceID
        self.logStore = logStore
        self.resolveCommandResult = resolveCommandResult
        resultReady.enter()
    }

    init(
        startedAt: Date,
        execution: any DeploymentExecution,
        deploymentToken: String,
        targetDeviceID: String,
        logStore: LogStore,
        resolveCommandResult: (@Sendable (CommandResult) -> DeployResult)? = nil
    ) {
        self.startedAt = startedAt
        self.execution = execution
        self.deploymentToken = deploymentToken
        self.targetDeviceID = targetDeviceID
        self.logStore = logStore
        self.resolveCommandResult = resolveCommandResult
        resultReady.enter()
    }

    var processGroupIdentifier: Int32 {
        execution.processGroupIdentifier
    }

    func cancel() {
        execution.cancel()
    }

    func setHistoryTrigger(_ trigger: RefreshHistoryTrigger) {
        resultLock.withLock {
            guard cachedResult == nil, !isResolvingResult else {
                return
            }
            historyTrigger = trigger
        }
    }

    @discardableResult
    func cancelAndWaitForTermination(
        timeoutSeconds: TimeInterval = 2.5
    ) -> DeployResult? {
        switch shutdown(timeoutSeconds: timeoutSeconds) {
        case .settled(let result):
            return result
        case .processTerminatedResultPending, .processUnresolved:
            return nil
        }
    }

    func shutdown(
        timeoutSeconds: TimeInterval = 2.5
    ) -> DeployShutdownOutcome {
        let deadline = DispatchTime.now() + max(timeoutSeconds, 0)
        guard execution.cancelAndWaitForTermination(
            timeoutSeconds: timeoutSeconds
        ) else {
            return .processUnresolved
        }

        beginResolvingResultIfNeeded()
        guard resultReady.wait(timeout: deadline) == .success,
              let result = cachedResultSnapshot() else {
            return .processTerminatedResultPending
        }
        return .settled(result)
    }

    func shutdownAsync(
        timeoutSeconds: TimeInterval = 2.5
    ) async -> DeployShutdownOutcome {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(
                    returning: self.shutdown(
                        timeoutSeconds: timeoutSeconds
                    )
                )
            }
        }
    }

    func waitUntilExit() -> DeployResult {
        beginResolvingResultIfNeeded()
        resultReady.wait()
        return cachedResultSnapshot()!
    }

    private func beginResolvingResultIfNeeded() {
        resultLock.lock()
        guard cachedResult == nil, !isResolvingResult else {
            resultLock.unlock()
            return
        }
        isResolvingResult = true
        resultLock.unlock()

        Thread.detachNewThread { [self] in
            let resolvedResult = resolveResult()
            resultLock.lock()
            cachedResult = resolvedResult
            isResolvingResult = false
            resultLock.unlock()
            resultReady.leave()
        }
    }

    private func cachedResultSnapshot() -> DeployResult? {
        resultLock.withLock { cachedResult }
    }

    private func resolveResult() -> DeployResult {
        let executionResult = execution.waitUntilExit()
        let result = executionResult.commandResult
        if let resolveCommandResult {
            return resolveCommandResult(result)
        }
        let finishedAt = Date()
        let outcome = Self.outcome(for: result.terminationStatus)
        let failureAnalysis = outcome == .success || outcome == .cancelled
            ? nil
            : DeployService.failureAnalysis(
                from: result,
                targetDeviceID: targetDeviceID
            )

        let combinedOutput = DeployService.makeCombinedOutput(
            result: result,
            failureReason: failureAnalysis?.reason,
            trigger: resultLock.withLock { historyTrigger }
        )
        let logPath: String?
        var warnings: [String] = []
        if result.standardOutputWasTruncated
            || result.standardErrorWasTruncated {
            warnings.append(
                "续签命令输出超过采集上限，日志仅保留头尾片段。"
            )
        }
        do {
            let logFileURL = try logStore.makeLogFileURL()
            try logStore.writeLog(combinedOutput, to: logFileURL)
            logPath = logFileURL.path
        } catch {
            logPath = nil
            warnings.append(
                "续签结果已确定，但日志保存失败：\(error.localizedDescription)"
            )
        }
        let logWarning = warnings.isEmpty
            ? nil
            : warnings.joined(separator: " ")

        return DeployResult(
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            failureReason: failureAnalysis?.reason,
            summary: outcome == .success
                ? "续签已完成。"
                : (outcome == .cancelled
                    ? "已取消。"
                    : failureAnalysis?.summary ?? "续签部署执行失败。"),
            logPath: logPath,
            logWarning: logWarning,
            verifiedProfileExpirationDate:
                executionResult.verifiedProfileExpirationDate,
            processGroupTerminationWasConfirmed:
                result.processGroupTerminationWasConfirmed,
            profileCacheRecoveryWasConfirmed:
                executionResult.profileCacheRecoveryWasConfirmed
        )
    }

    private static func outcome(for terminationStatus: Int32) -> DeployOutcome {
        switch terminationStatus {
        case 0:
            return .success
        case 130, 143:
            return .cancelled
        case 124:
            return .timedOut
        default:
            return .failure
        }
    }

    func result() async -> DeployResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: self.waitUntilExit())
                }
            }
        } onCancel: {
            cancel()
        }
    }
}

private final class SingleCommandDeploymentExecution:
    DeploymentExecution,
    @unchecked Sendable {
    private let command: RunningCommand

    init(command: RunningCommand) {
        self.command = command
    }

    var processGroupIdentifier: Int32 {
        command.processGroupIdentifier
    }

    func cancel() {
        command.cancel()
    }

    func cancelAndWaitForTermination(
        timeoutSeconds: TimeInterval
    ) -> Bool {
        command.cancelAndWaitForTermination(
            timeoutSeconds: timeoutSeconds
        )
    }

    func waitUntilExit() -> DeploymentExecutionResult {
        DeploymentExecutionResult(
            commandResult: command.waitUntilExit(),
            verifiedProfileExpirationDate: nil
        )
    }
}
