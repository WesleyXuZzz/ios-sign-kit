import Foundation
import Darwin

final class RunningCommand: @unchecked Sendable {
    private let processIdentifier: pid_t
    private let outputCollector: CommandOutputCollector
    private let errorCollector: CommandOutputCollector
    private let processOwnershipTracker: CommandProcessOwnershipTracker
    private let executionCoordinator: CommandExecutionCoordinator
    private let stateCondition = NSCondition()
    private let terminationGroup = DispatchGroup()
    private var terminationStatus: Int32?
    private var processGroupTerminationWasConfirmed: Bool?
    private var cancellationRequested = false

    var processGroupIdentifier: pid_t {
        processIdentifier
    }

    private init(
        processIdentifier: pid_t,
        outputHandle: FileHandle,
        errorHandle: FileHandle,
        maximumCapturedOutputBytes: Int,
        onOutput: (@Sendable (String, Bool) -> Void)?,
        ownershipToken: String,
        executionCoordinator: CommandExecutionCoordinator
    ) {
        self.processIdentifier = processIdentifier
        self.outputCollector = CommandOutputCollector(
            handle: outputHandle,
            isError: false,
            maximumCapturedBytes: maximumCapturedOutputBytes,
            onOutput: onOutput
        )
        self.errorCollector = CommandOutputCollector(
            handle: errorHandle,
            isError: true,
            maximumCapturedBytes: maximumCapturedOutputBytes,
            onOutput: onOutput
        )
        self.processOwnershipTracker =
            CommandProcessOwnershipTracker(token: ownershipToken)
        self.executionCoordinator = executionCoordinator
        terminationGroup.enter()
    }

    private func startMonitoring() {
        outputCollector.start()
        errorCollector.start()
        Thread.detachNewThread { [weak self] in
            self?.reapProcess()
        }
    }

    static func spawn(
        launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environment: [String: String],
        maximumCapturedOutputBytes: Int,
        onOutput: (@Sendable (String, Bool) -> Void)?,
        ownershipToken: String,
        executionCoordinator: CommandExecutionCoordinator
    ) throws -> RunningCommand {
        let ownershipFile =
            try CommandProcessOwnershipTracker.prepareOwnershipFile(
                token: ownershipToken
            )
        var didSpawnProcess = false
        defer {
            close(ownershipFile.descriptor)
            if !didSpawnProcess {
                CommandProcessOwnershipTracker(
                    token: ownershipToken
                ).removeMarkerIfPresent()
            }
        }
        var outputDescriptors: [Int32] = [0, 0]
        var errorDescriptors: [Int32] = [0, 0]
        guard pipe(&outputDescriptors) == 0 else {
            throw CommandRunnerError.pipeCreationFailed(errno)
        }
        do {
            try Self.configureCloseOnExec(outputDescriptors)
        } catch {
            Self.closeAll(outputDescriptors)
            throw error
        }
        guard pipe(&errorDescriptors) == 0 else {
            let code = errno
            Self.closeAll(outputDescriptors)
            throw CommandRunnerError.pipeCreationFailed(code)
        }
        do {
            try Self.configureCloseOnExec(errorDescriptors)
        } catch {
            Self.closeAll(outputDescriptors + errorDescriptors)
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var didInitializeFileActions = false
        var didInitializeAttributes = false

        defer {
            if didInitializeFileActions {
                posix_spawn_file_actions_destroy(&fileActions)
            }
            if didInitializeAttributes {
                posix_spawnattr_destroy(&attributes)
            }
        }

        var setupStatus = posix_spawn_file_actions_init(&fileActions)
        guard setupStatus == 0 else {
            Self.closeAll(outputDescriptors + errorDescriptors)
            throw CommandRunnerError.spawnSetupFailed(setupStatus)
        }
        didInitializeFileActions = true

        setupStatus = posix_spawnattr_init(&attributes)
        guard setupStatus == 0 else {
            Self.closeAll(outputDescriptors + errorDescriptors)
            throw CommandRunnerError.spawnSetupFailed(setupStatus)
        }
        didInitializeAttributes = true

        for (from, to) in [
            (outputDescriptors[1], STDOUT_FILENO),
            (errorDescriptors[1], STDERR_FILENO),
            (
                ownershipFile.descriptor,
                CommandProcessOwnershipTracker.inheritedMarkerDescriptor
            )
        ] {
            setupStatus = posix_spawn_file_actions_adddup2(&fileActions, from, to)
            guard setupStatus == 0 else {
                Self.closeAll(outputDescriptors + errorDescriptors)
                throw CommandRunnerError.spawnSetupFailed(setupStatus)
            }
        }

        for descriptor in
            CommandProcessOwnershipTracker.childDescriptorsToClose(
                outputDescriptors
                    + errorDescriptors
                    + [ownershipFile.descriptor]
            ) {
            setupStatus = posix_spawn_file_actions_addclose(&fileActions, descriptor)
            guard setupStatus == 0 else {
                Self.closeAll(outputDescriptors + errorDescriptors)
                throw CommandRunnerError.spawnSetupFailed(setupStatus)
            }
        }

        if let currentDirectoryPath {
            setupStatus = currentDirectoryPath.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
            guard setupStatus == 0 else {
                Self.closeAll(outputDescriptors + errorDescriptors)
                throw CommandRunnerError.spawnSetupFailed(setupStatus)
            }
        }

        setupStatus = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        guard setupStatus == 0 else {
            Self.closeAll(outputDescriptors + errorDescriptors)
            throw CommandRunnerError.spawnSetupFailed(setupStatus)
        }
        setupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        guard setupStatus == 0 else {
            Self.closeAll(outputDescriptors + errorDescriptors)
            throw CommandRunnerError.spawnSetupFailed(setupStatus)
        }

        let argumentStorage = CStringArray([launchPath] + arguments)
        let environmentStorage = CStringArray(
            environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        )
        var processIdentifier: pid_t = 0
        let spawnStatus = launchPath.withCString { executablePath in
            posix_spawn(
                &processIdentifier,
                executablePath,
                &fileActions,
                &attributes,
                argumentStorage.pointer,
                environmentStorage.pointer
            )
        }

        close(outputDescriptors[1])
        close(errorDescriptors[1])

        guard spawnStatus == 0 else {
            close(outputDescriptors[0])
            close(errorDescriptors[0])
            throw CommandRunnerError.spawnFailed(spawnStatus)
        }
        didSpawnProcess = true

        let outputHandle = FileHandle(
            fileDescriptor: outputDescriptors[0],
            closeOnDealloc: true
        )
        let errorHandle = FileHandle(
            fileDescriptor: errorDescriptors[0],
            closeOnDealloc: true
        )
        let command = RunningCommand(
            processIdentifier: processIdentifier,
            outputHandle: outputHandle,
            errorHandle: errorHandle,
            maximumCapturedOutputBytes: maximumCapturedOutputBytes,
            onOutput: onOutput,
            ownershipToken: ownershipToken,
            executionCoordinator: executionCoordinator
        )
        executionCoordinator.register(command)
        command.startMonitoring()
        return command
    }

    func waitUntilExit(timeoutSeconds: TimeInterval? = nil) -> CommandResult {
        if let timeoutSeconds, timeoutSeconds > 0 {
            let deadline = DispatchTime.now() + timeoutSeconds
            let didTimeout = !waitForTermination(until: deadline)

            if didTimeout {
                cancel()
                _ = waitForTermination(until: .now() + 2)
                return makeResult(
                    forcedStatus: 124,
                    appendedError: "Command timed out after \(String(format: "%.1f", timeoutSeconds)) seconds."
                )
            }
        } else {
            _ = waitForTermination(until: nil)
        }

        return makeResult()
    }

    func cancel() {
        stateCondition.lock()
        guard terminationStatus == nil else {
            stateCondition.unlock()
            return
        }
        cancellationRequested = true
        let identifier = processIdentifier
        stateCondition.unlock()

        _ = kill(-identifier, SIGTERM)
        Thread.detachNewThread { [weak self] in
            usleep(1_200_000)
            guard let self else { return }
            self.stateCondition.lock()
            let isStillRunning = self.terminationStatus == nil
            self.stateCondition.unlock()
            if isStillRunning, self.processGroupExists() {
                _ = kill(-identifier, SIGKILL)
            }
        }
    }

    private func reapProcess() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result == -1 && errno == EINTR

        let leaderStatus = result == processIdentifier
            ? normalizedTerminationStatus(from: status)
            : 1

        let processGroupDidTerminate =
            finishProcessGroupAndOutputAfterLeaderExit()

        stateCondition.lock()
        processGroupTerminationWasConfirmed = processGroupDidTerminate
        terminationStatus = leaderStatus
        stateCondition.broadcast()
        stateCondition.unlock()
        terminationGroup.leave()
        if processGroupDidTerminate {
            executionCoordinator.unregister(processIdentifier: processIdentifier)
        } else {
            executionCoordinator.recordUnresolvedTermination(
                processIdentifier: processIdentifier
            )
        }
    }

    @discardableResult
    func cancelAndWaitForTermination(timeoutSeconds: TimeInterval = 2.5) -> Bool {
        cancel()
        let didTerminate = waitForCompleteTermination(
            until: .now() + max(timeoutSeconds, 0)
        )
        if !didTerminate {
            executionCoordinator.recordUnresolvedTermination(
                processIdentifier: processIdentifier
            )
        }
        return didTerminate
    }

    fileprivate func waitForCompleteTermination(
        until deadline: DispatchTime
    ) -> Bool {
        _ = waitForTermination(until: deadline)
        stateCondition.lock()
        let didTerminate = terminationStatus != nil
        let terminationWasConfirmed =
            processGroupTerminationWasConfirmed == true
        stateCondition.unlock()
        guard didTerminate,
              terminationWasConfirmed,
              !processGroupExists() else {
            return false
        }
        executionCoordinator.unregister(processIdentifier: processIdentifier)
        return true
    }

    fileprivate func forceKillProcessGroupIfRunning() {
        if processGroupExists() {
            _ = kill(-processIdentifier, SIGKILL)
        }
    }

    private func finishProcessGroupAndOutputAfterLeaderExit() -> Bool {
        // The process group, rather than the shell leader or its output pipes,
        // defines the command lifecycle. A descendant can ignore TERM and close
        // both pipes before the leader exits, so neither waitpid nor EOF proves
        // that the complete command tree is gone.
        _ = waitForProcessGroupToExit(within: 0.15)
        if processGroupExists() {
            _ = kill(-processIdentifier, SIGTERM)
            _ = waitForProcessGroupToExit(within: 0.25)
        }
        if processGroupExists() {
            _ = kill(-processIdentifier, SIGKILL)
            _ = waitForProcessGroupToExit(within: 0.25)
        }
        let ownedProcessesDidTerminate =
            processOwnershipTracker.terminateAllOwnedProcesses()

        if !collectorsFinished(within: 0.5) {
            outputCollector.forceFinish()
            errorCollector.forceFinish()
        }
        return !processGroupExists()
            && ownedProcessesDidTerminate
            && !outputCollector.wasForcedBeforeEndOfFile
            && !errorCollector.wasForcedBeforeEndOfFile
    }

    private func collectorsFinished(within seconds: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + seconds
        guard outputCollector.waitUntilFinished(until: deadline) else {
            return false
        }
        return errorCollector.waitUntilFinished(until: deadline)
    }

    private func waitForProcessGroupToExit(within seconds: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + max(seconds, 0)
        repeat {
            if !processGroupExists() {
                return true
            }
            usleep(10_000)
        } while DispatchTime.now() < deadline
        return !processGroupExists()
    }

    private func processGroupExists() -> Bool {
        errno = 0
        if kill(-processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    @discardableResult
    private func waitForTermination(until deadline: DispatchTime?) -> Bool {
        if let deadline {
            return terminationGroup.wait(timeout: deadline) == .success
        }
        terminationGroup.wait()
        return true
    }

    private func makeResult(forcedStatus: Int32? = nil, appendedError: String? = nil) -> CommandResult {
        if !collectorsFinished(within: 0.25) {
            outputCollector.forceFinish()
            errorCollector.forceFinish()
            _ = collectorsFinished(within: 0.35)
        }

        stateCondition.lock()
        let recordedStatus = cancellationRequested ? 130 : (terminationStatus ?? 1)
        let recordedProcessGroupTermination =
            processGroupTerminationWasConfirmed ?? false
        stateCondition.unlock()

        var standardError = errorCollector.stringValue
        if let appendedError {
            let trimmed = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            standardError = trimmed.isEmpty ? appendedError : "\(trimmed)\n\(appendedError)"
        }
        let result = CommandResult(
            standardOutput: outputCollector.stringValue,
            standardError: standardError,
            terminationStatus: forcedStatus ?? recordedStatus,
            standardOutputWasTruncated: outputCollector.wasTruncated,
            standardErrorWasTruncated: errorCollector.wasTruncated,
            processGroupTerminationWasConfirmed:
                recordedProcessGroupTermination
        )
        if !result.processGroupTerminationWasConfirmed {
            executionCoordinator.recordUnresolvedTermination(
                processIdentifier: processIdentifier
            )
        }
        return result
    }

    private func normalizedTerminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors {
            close(descriptor)
        }
    }

    static func configureCloseOnExec(
        _ descriptors: [Int32]
    ) throws {
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0,
                  fcntl(
                    descriptor,
                    F_SETFD,
                    flags | FD_CLOEXEC
                  ) == 0 else {
                throw CommandRunnerError.pipeCreationFailed(errno)
            }
        }
    }
}

final class CommandExecutionCoordinator: @unchecked Sendable {
    private final class WeakCommand {
        weak var value: RunningCommand?

        init(_ value: RunningCommand) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var commands: [pid_t: WeakCommand] = [:]
    private var unresolvedTerminationDiagnostic: String?

    func requireCommandStartAllowed() throws {
        lock.lock()
        let diagnostic = unresolvedTerminationDiagnostic
        lock.unlock()
        if let diagnostic {
            throw CommandRunnerError
                .unresolvedProcessOwnership(diagnostic)
        }
    }

    func recordUnresolvedTermination(
        processIdentifier: pid_t
    ) {
        lock.lock()
        if unresolvedTerminationDiagnostic == nil {
            unresolvedTerminationDiagnostic =
                "无法确认此前命令（PID \(processIdentifier)）的全部后代已终止；"
                + "已阻止启动新命令，请重启 iOSSignKit 完成遗留进程恢复。"
        }
        lock.unlock()
    }

    func register(_ command: RunningCommand) {
        lock.lock()
        commands[command.processGroupIdentifier] = WeakCommand(command)
        lock.unlock()
    }

    func unregister(processIdentifier: pid_t) {
        lock.lock()
        commands.removeValue(forKey: processIdentifier)
        lock.unlock()
    }

    func cancelAllAndWait(timeoutSeconds: TimeInterval) -> Bool {
        lock.lock()
        commands = commands.filter { $0.value.value != nil }
        let runningCommands = commands.values.compactMap(\.value)
        lock.unlock()

        runningCommands.forEach { $0.cancel() }

        let totalTimeout = max(timeoutSeconds, 0)
        let startedAt = DispatchTime.now()
        let deadline = startedAt + totalTimeout
        let killGrace = min(0.75, totalTimeout / 3)
        let gracefulDeadline = startedAt + max(totalTimeout - killGrace, 0)
        var survivors: [RunningCommand] = []
        for command in runningCommands {
            if !command.waitForCompleteTermination(until: gracefulDeadline) {
                survivors.append(command)
            }
        }
        guard !survivors.isEmpty else {
            lock.lock()
            let isUnresolved =
                unresolvedTerminationDiagnostic != nil
            lock.unlock()
            return !isUnresolved
        }

        survivors.forEach { $0.forceKillProcessGroupIfRunning() }
        var allTerminated = true
        for survivor in survivors {
            if !survivor.waitForCompleteTermination(until: deadline) {
                allTerminated = false
                recordUnresolvedTermination(
                    processIdentifier:
                        survivor.processGroupIdentifier
                )
            }
        }
        lock.lock()
        let isUnresolved =
            unresolvedTerminationDiagnostic != nil
        lock.unlock()
        return allTerminated && !isUnresolved
    }
}

private final class CStringArray {
    private let storage: [UnsafeMutablePointer<CChar>?]
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

    init(_ values: [String]) {
        storage = values.map { strdup($0) }
        pointer = .allocate(capacity: storage.count + 1)
        for (index, value) in storage.enumerated() {
            pointer[index] = value
        }
        pointer[storage.count] = nil
    }

    deinit {
        for value in storage {
            free(value)
        }
        pointer.deallocate()
    }
}
