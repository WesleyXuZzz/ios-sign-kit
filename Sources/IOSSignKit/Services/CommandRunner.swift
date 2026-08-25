import Foundation
import Darwin

struct CommandResult: Equatable, Sendable {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32
    let standardOutputWasTruncated: Bool
    let standardErrorWasTruncated: Bool
    let processGroupTerminationWasConfirmed: Bool

    var completedSuccessfullyAndFullyTerminated: Bool {
        terminationStatus == 0 && processGroupTerminationWasConfirmed
    }

    init(
        standardOutput: String,
        standardError: String,
        terminationStatus: Int32,
        standardOutputWasTruncated: Bool = false,
        standardErrorWasTruncated: Bool = false,
        processGroupTerminationWasConfirmed: Bool = true
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
        self.standardOutputWasTruncated = standardOutputWasTruncated
        self.standardErrorWasTruncated = standardErrorWasTruncated
        self.processGroupTerminationWasConfirmed =
            processGroupTerminationWasConfirmed
    }
}
protocol CommandExecuting: Sendable {
    func run(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String],
        onOutput: (@Sendable (String, Bool) -> Void)?,
        timeoutSeconds: TimeInterval?
    ) throws -> CommandResult

    func runAsync(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String],
        onOutput: (@Sendable (String, Bool) -> Void)?,
        timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult

    func start(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String],
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) throws -> RunningCommand
}

struct CommandRunner: CommandExecuting {
    private let maximumCapturedOutputBytes: Int
    private let executionCoordinator: CommandExecutionCoordinator

    init(
        maximumCapturedOutputBytes: Int = 8 * 1_024 * 1_024,
        executionCoordinator: CommandExecutionCoordinator = CommandExecutionCoordinator()
    ) {
        self.maximumCapturedOutputBytes = max(maximumCapturedOutputBytes, 1_024)
        self.executionCoordinator = executionCoordinator
    }

    @discardableResult
    func cancelAllRunningCommandsAndWait(
        timeoutSeconds: TimeInterval = 2.5
    ) -> Bool {
        executionCoordinator.cancelAllAndWait(
            timeoutSeconds: timeoutSeconds
        )
    }

    func run(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environmentOverrides: [String: String] = [:],
        onOutput: (@Sendable (String, Bool) -> Void)? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) throws -> CommandResult {
        let command = try start(
            launchPath,
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            environmentOverrides: environmentOverrides,
            onOutput: onOutput
        )
        return command.waitUntilExit(timeoutSeconds: timeoutSeconds)
    }

    func runAsync(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environmentOverrides: [String: String] = [:],
        onOutput: (@Sendable (String, Bool) -> Void)? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> CommandResult {
        let command = try start(
            launchPath,
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            environmentOverrides: environmentOverrides,
            onOutput: onOutput
        )

        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(
                        returning: command.waitUntilExit(timeoutSeconds: timeoutSeconds)
                    )
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            command.cancel()
        }
    }

    func start(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String? = nil,
        environmentOverrides: [String: String] = [:],
        onOutput: (@Sendable (String, Bool) -> Void)? = nil
    ) throws -> RunningCommand {
        try Self.validateCommandInput(
            launchPath: launchPath,
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            environmentOverrides: environmentOverrides
        )
        try executionCoordinator.requireCommandStartAllowed()
        var environment = mergedEnvironment(overriding: environmentOverrides)
        let ownershipToken = CommandProcessOwnershipTracker.makeToken()
        environment[CommandProcessOwnershipTracker.environmentKey] =
            ownershipToken
        environment[
            CommandProcessOwnershipTracker
                .ownershipDescriptorEnvironmentKey
        ] = String(
            CommandProcessOwnershipTracker.inheritedMarkerDescriptor
        )
        let markerToken =
            environmentOverrides[
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey
            ]
            .flatMap(DeploymentToken.init(rawValue:))?
            .rawValue
            ?? ownershipToken
        try Self.validateEnvironment(environment)
        return try RunningCommand.spawn(
            launchPath: launchPath,
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            environment: environment,
            maximumCapturedOutputBytes: maximumCapturedOutputBytes,
            onOutput: onOutput,
            ownershipToken: markerToken,
            executionCoordinator: executionCoordinator
        )
    }

    private func mergedEnvironment(overriding environmentOverrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let existingPath = environment["PATH"] ?? ""
        let existingComponents = existingPath.split(separator: ":").map(String.init)
        let mergedComponents = Array(NSOrderedSet(array: fallbackPaths + existingComponents)) as? [String]
            ?? (fallbackPaths + existingComponents)
        environment["PATH"] = mergedComponents.joined(separator: ":")
        environment.merge(environmentOverrides) { _, override in override }
        return environment
    }

    private static func validateCommandInput(
        launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String]
    ) throws {
        guard isCStringSafe(launchPath), !launchPath.isEmpty else {
            throw CommandRunnerError.invalidCStringInput("可执行文件路径")
        }
        guard arguments.allSatisfy(isCStringSafe) else {
            throw CommandRunnerError.invalidCStringInput("命令参数")
        }
        if let currentDirectoryPath,
           !isCStringSafe(currentDirectoryPath) || currentDirectoryPath.isEmpty {
            throw CommandRunnerError.invalidCStringInput("工作目录")
        }
        try validateEnvironment(environmentOverrides)
    }

    private static func validateEnvironment(_ environment: [String: String]) throws {
        guard environment.allSatisfy({ key, value in
            !key.isEmpty
                && !key.contains("=")
                && isCStringSafe(key)
                && isCStringSafe(value)
        }) else {
            throw CommandRunnerError.invalidCStringInput("环境变量")
        }
    }

    private static func isCStringSafe(_ value: String) -> Bool {
        !value.utf8.contains(0) && value.utf8.count <= 1_048_576
    }
}

enum CommandRunnerError: Error, LocalizedError {
    case invalidCStringInput(String)
    case unresolvedProcessOwnership(String)
    case pipeCreationFailed(Int32)
    case spawnSetupFailed(Int32)
    case spawnFailed(Int32)

    var errorDescription: String? {
        if case .invalidCStringInput(let field) = self {
            return "\(field)包含无法安全传递给系统命令的内容。"
        }
        if case .unresolvedProcessOwnership(let diagnostic) = self {
            return diagnostic
        }
        let code: Int32
        let operation: String
        switch self {
        case .invalidCStringInput, .unresolvedProcessOwnership:
            preconditionFailure("已在上方处理")
        case .pipeCreationFailed(let value):
            code = value
            operation = "创建输出管道"
        case .spawnSetupFailed(let value):
            code = value
            operation = "配置命令进程"
        case .spawnFailed(let value):
            code = value
            operation = "启动命令"
        }
        return "\(operation)失败：\(String(cString: strerror(code)))"
    }
}
