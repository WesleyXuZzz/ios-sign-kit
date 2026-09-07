import Darwin
import Foundation

enum DeploymentProcessRecoveryOutcome: Equatable, Sendable {
    case notFound
    case terminated
    case unresolved(String)
}

struct CommandProcessRecovery: Sendable {
    static let commandTokenPrefix =
        CommandProcessOwnershipTracker.commandTokenPrefix

    private let recoverAnyCommandClosure:
        @Sendable () -> DeploymentProcessRecoveryOutcome

    init(
        commandTokenPrefix: String = Self.commandTokenPrefix
    ) {
        let ownershipTracker =
            CommandProcessOwnershipTracker(
                environmentKey:
                    CommandProcessOwnershipTracker.environmentKey,
                valuePrefix: commandTokenPrefix,
                onlyAbandonedCreators: true
            )
        recoverAnyCommandClosure = {
            switch ownershipTracker.recoverAllOwnedProcesses() {
            case .notFound:
                return .notFound
            case .terminated:
                return .terminated
            case .unresolved:
                return .unresolved(
                    "无法核验或终止所有携带归属标记的遗留普通命令。"
                )
            }
        }
    }

    init(
        recoverAnyCommand:
            @escaping @Sendable ()
                -> DeploymentProcessRecoveryOutcome
    ) {
        recoverAnyCommandClosure = recoverAnyCommand
    }

    func recoverAnyCommand()
        -> DeploymentProcessRecoveryOutcome {
        recoverAnyCommandClosure()
    }
}

struct DeploymentProcessRecovery: Sendable {
    static let deploymentTokenPrefix = DeploymentToken.prefix
    static let deploymentTokenEnvironmentKey =
        "IOS_SIGN_KIT_DEPLOYMENT_TOKEN"

    private let recoverMatchingProcesses: @Sendable (
        String,
        Bool,
        Bool,
        Int32?
    ) -> DeploymentProcessRecoveryOutcome

    init(commandRunner: CommandRunner = CommandRunner()) {
        let processListProvider: @Sendable () throws -> CommandResult = {
            try commandRunner.run(
                "/bin/ps",
                arguments: ["-axo", "pid=,pgid=,command="],
                timeoutSeconds: 3
            )
        }
        recoverMatchingProcesses = { token, acceptsPrefix, shouldTerminate, recordedProcessGroupID in
            let processGroupOutcome = Self.recoverProcesses(
                matching: token,
                acceptsPrefix: acceptsPrefix,
                shouldTerminate: shouldTerminate,
                recordedProcessGroupID: recordedProcessGroupID,
                processListProvider: processListProvider
            )
            let ownershipTracker = acceptsPrefix
                ? CommandProcessOwnershipTracker(
                    environmentKey: Self.deploymentTokenEnvironmentKey,
                    valuePrefix: token,
                    onlyAbandonedCreators: true
                )
                : CommandProcessOwnershipTracker(
                    environmentKey: Self.deploymentTokenEnvironmentKey,
                    exactValue: token
                )

            if acceptsPrefix {
                switch ownershipTracker.discoverAllOwnedProcesses() {
                case .notFound:
                    return processGroupOutcome
                case .found:
                    return .unresolved(
                        "检测到携带续签令牌前缀的遗留进程，但没有精确令牌可安全终止。"
                    )
                case .unavailable:
                    return .unresolved(
                        "无法核验是否仍有携带续签令牌前缀的遗留进程。"
                    )
                }
            }
            guard shouldTerminate else {
                return processGroupOutcome
            }

            switch ownershipTracker.recoverAllOwnedProcesses() {
            case .notFound:
                return processGroupOutcome
            case .terminated:
                return .terminated
            case .unresolved:
                if case .terminated = processGroupOutcome {
                    switch ownershipTracker.recoverAllOwnedProcesses() {
                    case .notFound, .terminated:
                        return .terminated
                    case .unresolved:
                        break
                    }
                }
                return .unresolved(
                    "无法核验或终止所有携带续签令牌的遗留进程。"
                )
            }
        }
    }

    init(
        processListProvider: @escaping @Sendable () throws -> CommandResult
    ) {
        recoverMatchingProcesses = { token, acceptsPrefix, shouldTerminate, recordedProcessGroupID in
            Self.recoverProcesses(
                matching: token,
                acceptsPrefix: acceptsPrefix,
                shouldTerminate: shouldTerminate,
                recordedProcessGroupID: recordedProcessGroupID,
                processListProvider: processListProvider
            )
        }
    }

    init(
        recoverMatchingProcesses: @escaping @Sendable (
            String,
            Bool,
            Bool,
            Int32?
        ) -> DeploymentProcessRecoveryOutcome
    ) {
        self.recoverMatchingProcesses = recoverMatchingProcesses
    }

    func recover(processGroupID: Int32?, token: String) -> DeploymentProcessRecoveryOutcome {
        guard let deploymentToken = DeploymentToken(rawValue: token) else {
            return .unresolved("持久化的续签令牌无效，无法安全识别遗留进程。")
        }
        let normalizedToken = deploymentToken.rawValue
        return recoverMatchingProcesses(
            normalizedToken,
            false,
            true,
            processGroupID
        )
    }

    func recoverAnyDeployment() -> DeploymentProcessRecoveryOutcome {
        recoverMatchingProcesses(Self.deploymentTokenPrefix, true, false, nil)
    }

    private static func recoverProcesses(
        matching token: String,
        acceptsPrefix: Bool,
        shouldTerminate: Bool,
        recordedProcessGroupID: Int32?,
        processListProvider: @Sendable () throws -> CommandResult
    ) -> DeploymentProcessRecoveryOutcome {
        let result: CommandResult
        do {
            var latest = try processListProvider()
            // Retry only settled read failures. An unresolved process tree must
            // keep recovery blocked; starting another command cannot prove it safe.
            for _ in 1..<3 {
                guard latest.terminationStatus != 0,
                      latest.processGroupTerminationWasConfirmed else {
                    break
                }
                latest = try processListProvider()
            }
            result = latest
        } catch {
            return .unresolved("无法读取进程表：\(error.localizedDescription)")
        }

        guard result.completedSuccessfullyAndFullyTerminated else {
            let diagnostic = result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unresolved(
                diagnostic.isEmpty ? "读取进程表失败。" : "读取进程表失败：\(diagnostic)"
            )
        }
        guard !result.standardOutputWasTruncated else {
            return .unresolved("进程表输出过大且已被截断，无法安全确认遗留续签。")
        }

        let processGroups = Set(result.standardOutput.split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let processGroupID = Int32(fields[1]),
                  processGroupID > 1 else {
                return nil
            }
            let commandFields = fields[2].split(whereSeparator: \.isWhitespace)
            let matches = acceptsPrefix
                ? commandFields.contains(where: { $0.hasPrefix(token) })
                : commandFields.contains(where: { $0 == Substring(token) })
            return matches ? processGroupID : nil
        })

        guard !processGroups.isEmpty else {
            return .notFound
        }
        guard shouldTerminate else {
            return .unresolved(
                "检测到无精确令牌的续签进程，无法证明其属于已中断实例。"
            )
        }
        // A deployment crosses several commands (xcodebuild, security and
        // devicectl), each of which owns a new process group. The persisted
        // process group is therefore only a diagnostic hint from the first
        // stage. The validated high-entropy exact token is the stable identity
        // and authorizes recovery of every group carrying that exact value.
        let processGroupDiagnostic: String
        if let recordedProcessGroupID,
           processGroups != Set([recordedProcessGroupID]) {
            let currentProcessGroups = processGroups.sorted()
                .map(String.init)
                .joined(separator: ", ")
            processGroupDiagnostic =
                "；持久化记录的初始进程组为 \(recordedProcessGroupID)，当前精确令牌匹配进程组为 \(currentProcessGroups)"
        } else {
            processGroupDiagnostic = ""
        }

        for processGroupID in processGroups {
            if kill(-processGroupID, SIGTERM) != 0, errno != ESRCH {
                return .unresolved(
                    "无法终止遗留续签进程组 \(processGroupID)：\(String(cString: strerror(errno)))\(processGroupDiagnostic)"
                )
            }
        }
        if waitForProcessGroupsToExit(processGroups, attempts: 25) {
            return .terminated
        }

        for processGroupID in processGroups {
            if kill(-processGroupID, SIGKILL) != 0, errno != ESRCH {
                return .unresolved(
                    "无法强制终止遗留续签进程组 \(processGroupID)：\(String(cString: strerror(errno)))\(processGroupDiagnostic)"
                )
            }
        }
        return waitForProcessGroupsToExit(processGroups, attempts: 25)
            ? .terminated
            : .unresolved(
                "遗留续签进程未在终止信号后退出\(processGroupDiagnostic)。"
            )
    }

    private static func waitForProcessGroupsToExit(
        _ processGroups: Set<Int32>,
        attempts: Int
    ) -> Bool {
        for _ in 0..<attempts {
            if processGroups.allSatisfy({ !processGroupExists($0) }) {
                return true
            }
            usleep(20_000)
        }
        return processGroups.allSatisfy { !processGroupExists($0) }
    }

    private static func processGroupExists(_ processGroupID: Int32) -> Bool {
        errno = 0
        if kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }
}
