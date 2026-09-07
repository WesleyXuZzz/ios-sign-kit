import Foundation
import Testing
@testable import IOSSignKit

struct DeploymentProcessRecoveryTests {
    @Test
    func transientProcessListFailureIsRetried() {
        let sequence = RecoveryProcessListSequence([
            CommandResult(standardOutput: "", standardError: "timeout", terminationStatus: 1),
            CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
        ])
        let outcome = DeploymentProcessRecovery(processListProvider: { sequence.next() })
            .recoverAnyDeployment()
        #expect(outcome == .notFound)
        #expect(sequence.count == 2)
    }

    @Test
    func repeatedProcessListFailureRemainsBlocked() {
        let sequence = RecoveryProcessListSequence([
            CommandResult(standardOutput: "", standardError: "timeout", terminationStatus: 1)
        ])
        let outcome = DeploymentProcessRecovery(processListProvider: { sequence.next() })
            .recoverAnyDeployment()
        #expect(outcome == .unresolved("读取进程表失败：timeout"))
        #expect(sequence.count == 3)
    }

    @Test
    func unresolvedProcessListCommandIsNotRetried() {
        let sequence = RecoveryProcessListSequence([
            CommandResult(standardOutput: "", standardError: "unresolved", terminationStatus: 1,
                          processGroupTerminationWasConfirmed: false)
        ])
        let outcome = DeploymentProcessRecovery(processListProvider: { sequence.next() })
            .recoverAnyDeployment()
        #expect(outcome == .unresolved("读取进程表失败：unresolved"))
        #expect(sequence.count == 1)
    }

    @Test
    func startupRecoveryTerminatesOrdinaryCommandAcrossNewSession() throws {
        let creatorHarness =
            try spawnZombieCreatorHarness()
        defer {
            creatorHarness.cleanUp()
        }
        let orphan = try spawnSimulatedOrdinaryCommandOrphan(
            creatorProcessIdentifier:
                creatorHarness.creatorProcessIdentifier
        )
        defer {
            orphan.cleanUp()
        }
        creatorHarness.releaseCreator()
        #expect(
            creatorHarness
                .waitUntilCreatorExitedWithoutBeingReaped()
        )

        let outcome = CommandProcessRecovery(
            commandTokenPrefix: orphan.commandToken
        ).recoverAnyCommand()
        orphan.reapLeader()

        #expect(outcome == .terminated)
        #expect(
            recoveryWaitUntilProcessIsGone(
                orphan.escapedChildProcessIdentifier
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: orphan.markerURL.path
            )
        )
    }

    @Test
    func startupRecoveryDoesNotTerminateAnActiveCreatorCommand()
        throws {
        let orphan = try spawnSimulatedOrdinaryCommandOrphan()
        defer {
            orphan.cleanUp()
        }

        let outcome = CommandProcessRecovery(
            commandTokenPrefix: orphan.commandToken
        ).recoverAnyCommand()

        #expect(outcome == .notFound)
        #expect(
            !recoveryWaitUntilProcessIsGone(
                orphan.escapedChildProcessIdentifier,
                attempts: 2
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: orphan.markerURL.path
            )
        )
    }

    @Test
    func startupRecoveryTreatsReusedCreatorIdentityAsAbandoned()
        throws {
        let orphan = try spawnSimulatedOrdinaryCommandOrphan()
        defer {
            orphan.cleanUp()
        }
        try changeRecordedCreatorStartTime(
            markerURL: orphan.markerURL
        )

        let outcome = CommandProcessRecovery(
            commandTokenPrefix: orphan.commandToken
        ).recoverAnyCommand()
        orphan.reapLeader()

        #expect(outcome == .terminated)
        #expect(
            recoveryWaitUntilProcessIsGone(
                orphan.escapedChildProcessIdentifier
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: orphan.markerURL.path
            )
        )
    }

    @Test
    func startupRecoveryWithoutOrdinaryCommandMarkerIsANoOp() {
        let absentToken =
            CommandProcessOwnershipTracker.makeToken()

        let outcome = CommandProcessRecovery(
            commandTokenPrefix: absentToken
        ).recoverAnyCommand()

        #expect(outcome == .notFound)
    }

    @Test
    func malformedOrdinaryCommandMarkerFailsClosed() throws {
        let commandToken =
            CommandProcessOwnershipTracker.makeToken()
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: commandToken
            )
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }

        let outcome = CommandProcessRecovery(
            commandTokenPrefix: commandToken
        ).recoverAnyCommand()

        guard case .unresolved(let diagnostic) = outcome else {
            Issue.record("畸形普通命令标记必须阻止后续命令")
            return
        }
        #expect(diagnostic.contains("普通命令"))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func corruptedStateDetectsDeploymentThroughInheritedFileMarker() throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let command = try CommandRunner().start(
            "/bin/sleep",
            arguments: ["30"],
            environmentOverrides: [
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                    deploymentToken
            ]
        )
        usleep(50_000)
        defer {
            command.cancel()
            _ = command.waitUntilExit(timeoutSeconds: 2)
        }
        try changeRecordedCreatorStartTime(
            markerURL:
                CommandProcessOwnershipTracker.markerFileURL(
                    for: deploymentToken
                )
        )

        let outcome = DeploymentProcessRecovery().recoverAnyDeployment()

        guard case .unresolved(let diagnostic) = outcome else {
            Issue.record("应阻断缺少精确令牌的遗留续签进程")
            return
        }
        #expect(diagnostic.contains("续签令牌前缀"))
    }

    @Test
    func completedDeploymentCommandRemovesItsFileMarker() throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: deploymentToken
            )

        let result = try CommandRunner().run(
            "/usr/bin/true",
            arguments: [],
            environmentOverrides: [
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                    deploymentToken
            ],
            timeoutSeconds: 2
        )

        #expect(result.completedSuccessfullyAndFullyTerminated)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func exactRecoveryTerminatesOwnerAndRemovesItsFileMarker() throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: deploymentToken
            )
        let command = try CommandRunner().start(
            "/bin/sleep",
            arguments: ["30"],
            environmentOverrides: [
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                    deploymentToken
            ]
        )
        defer {
            command.cancel()
            _ = command.waitUntilExit(timeoutSeconds: 3)
        }
        usleep(50_000)

        let outcome = DeploymentProcessRecovery().recover(
            processGroupID: command.processGroupIdentifier,
            token: deploymentToken
        )
        _ = command.waitUntilExit(timeoutSeconds: 3)

        #expect(outcome == .terminated)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func exactRecoveryFollowsTokenWhenDeploymentMovesToANewProcessGroup()
        throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let command = try CommandRunner().start(
            "/bin/sh",
            arguments: ["-c", "exec /bin/sleep 30", deploymentToken]
        )
        defer {
            command.cancel()
            _ = command.waitUntilExit(timeoutSeconds: 3)
        }
        usleep(50_000)
        let currentProcessGroupID = command.processGroupIdentifier
        let recordedEarlierProcessGroupID = currentProcessGroupID + 100_000
        let processList = CommandResult(
            standardOutput: """
            \(currentProcessGroupID) \(currentProcessGroupID) /bin/sh -c deploy \(deploymentToken)
            """,
            standardError: "",
            terminationStatus: 0
        )

        let outcome = DeploymentProcessRecovery(
            processListProvider: { processList }
        ).recover(
            processGroupID: recordedEarlierProcessGroupID,
            token: deploymentToken
        )
        _ = command.waitUntilExit(timeoutSeconds: 3)

        #expect(outcome == .terminated)
        errno = 0
        #expect(kill(-currentProcessGroupID, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func exactRecoveryTerminatesEveryGroupCarryingTheSameExactToken()
        throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let first = try CommandRunner().start(
            "/bin/sh",
            arguments: ["-c", "exec /bin/sleep 30", deploymentToken]
        )
        let second = try CommandRunner().start(
            "/bin/sh",
            arguments: ["-c", "exec /bin/sleep 30", deploymentToken]
        )
        defer {
            first.cancel()
            second.cancel()
            _ = first.waitUntilExit(timeoutSeconds: 3)
            _ = second.waitUntilExit(timeoutSeconds: 3)
        }
        usleep(50_000)
        let firstGroup = first.processGroupIdentifier
        let secondGroup = second.processGroupIdentifier
        let processList = CommandResult(
            standardOutput: """
            \(firstGroup) \(firstGroup) /bin/sh -c deploy \(deploymentToken)
            \(secondGroup) \(secondGroup) /bin/sh -c deploy \(deploymentToken)
            """,
            standardError: "",
            terminationStatus: 0
        )

        let outcome = DeploymentProcessRecovery(
            processListProvider: { processList }
        ).recover(
            processGroupID: firstGroup,
            token: deploymentToken
        )
        _ = first.waitUntilExit(timeoutSeconds: 3)
        _ = second.waitUntilExit(timeoutSeconds: 3)

        #expect(outcome == .terminated)
        errno = 0
        #expect(kill(-firstGroup, 0) == -1)
        #expect(errno == ESRCH)
        errno = 0
        #expect(kill(-secondGroup, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func exactRecoveryRejectsInvalidOrPrefixOnlyTokens() {
        let recovery = DeploymentProcessRecovery(
            recoverMatchingProcesses: { _, _, _, _ in
                Issue.record("无效令牌不得进入进程恢复")
                return .terminated
            }
        )

        let malformed = recovery.recover(
            processGroupID: nil,
            token: "ios-sign-kit-deploy-not-a-uuid"
        )
        let prefixOnly = recovery.recover(
            processGroupID: nil,
            token: DeploymentProcessRecovery.deploymentTokenPrefix
        )

        guard case .unresolved = malformed else {
            Issue.record("畸形续签令牌必须失败关闭")
            return
        }
        guard case .unresolved = prefixOnly else {
            Issue.record("令牌前缀不得作为精确恢复身份")
            return
        }
    }

    @Test
    func prefixScanIsDetectionOnlyAndNeverRequestsTermination() {
        let recovery = DeploymentProcessRecovery(
            recoverMatchingProcesses: {
                token,
                acceptsPrefix,
                shouldTerminate,
                expectedProcessGroupID in
                #expect(
                    token
                        == DeploymentProcessRecovery.deploymentTokenPrefix
                )
                #expect(acceptsPrefix)
                #expect(!shouldTerminate)
                #expect(expectedProcessGroupID == nil)
                return .unresolved("只读检测")
            }
        )

        let outcome = recovery.recoverAnyDeployment()

        #expect(outcome == .unresolved("只读检测"))
    }

    @Test
    func exactRecoveryDoesNotInferOwnershipFromAProcessNameSubstring() {
        let deploymentToken = DeploymentToken.make().rawValue
        let processList = CommandResult(
            standardOutput: """
            123 2000000 /tmp/worker-\(deploymentToken)-helper
            """,
            standardError: "",
            terminationStatus: 0
        )

        let outcome = DeploymentProcessRecovery(
            processListProvider: { processList }
        ).recover(
            processGroupID: 2_000_000,
            token: deploymentToken
        )

        #expect(outcome == .notFound)
    }

    @Test
    func malformedDeploymentMarkerFailsClosed() throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: deploymentToken
            )
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path
        )
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }

        let outcome = CommandProcessOwnershipTracker(
            environmentKey:
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey,
            exactValue: deploymentToken
        ).discoverAllOwnedProcesses()

        #expect(outcome == .unavailable)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func unreadableDeploymentMarkerFailsClosed() throws {
        let deploymentToken = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: deploymentToken
            )
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: markerURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: markerURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: markerURL.path
            )
            try? FileManager.default.removeItem(at: markerURL)
        }

        let outcome = CommandProcessOwnershipTracker(
            environmentKey:
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey,
            exactValue: deploymentToken
        ).discoverAllOwnedProcesses()

        #expect(outcome == .unavailable)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }
}

private struct SimulatedOrdinaryCommandOrphan {
    let commandToken: String
    let leaderProcessIdentifier: pid_t
    let escapedChildProcessIdentifier: pid_t
    let markerURL: URL
    let childPIDFileURL: URL

    func reapLeader() {
        var status: Int32 = 0
        while waitpid(leaderProcessIdentifier, &status, 0) == -1,
              errno == EINTR {}
    }

    func cleanUp() {
        _ = kill(-leaderProcessIdentifier, SIGKILL)
        _ = kill(escapedChildProcessIdentifier, SIGKILL)
        reapLeader()
        _ = CommandProcessOwnershipTracker(
            token: commandToken
        ).removeMarkerIfPresent()
        try? FileManager.default.removeItem(at: childPIDFileURL)
    }
}

private func spawnSimulatedOrdinaryCommandOrphan(
    creatorProcessIdentifier: pid_t = getpid()
) throws
    -> SimulatedOrdinaryCommandOrphan {
    let commandToken =
        CommandProcessOwnershipTracker.makeToken()
    let markerURL =
        CommandProcessOwnershipTracker.markerFileURL(
            for: commandToken
        )
    let childPIDFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ios-sign-kit-orphan-child-\(UUID().uuidString)"
        )
    let ownershipFile =
        try CommandProcessOwnershipTracker.prepareOwnershipFile(
            token: commandToken,
            creatorProcessIdentifier:
                creatorProcessIdentifier
        )
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var didInitializeFileActions = false
    var didInitializeAttributes = false
    var didSpawn = false
    var leaderProcessIdentifier: pid_t = 0
    defer {
        close(ownershipFile.descriptor)
        if didInitializeFileActions {
            posix_spawn_file_actions_destroy(&fileActions)
        }
        if didInitializeAttributes {
            posix_spawnattr_destroy(&attributes)
        }
        if !didSpawn {
            _ = CommandProcessOwnershipTracker(
                token: commandToken
            ).removeMarkerIfPresent()
            try? FileManager.default.removeItem(
                at: childPIDFileURL
            )
        }
    }

    try #require(
        posix_spawn_file_actions_init(&fileActions) == 0
    )
    didInitializeFileActions = true
    try #require(posix_spawnattr_init(&attributes) == 0)
    didInitializeAttributes = true
    try #require(
        posix_spawn_file_actions_adddup2(
            &fileActions,
            ownershipFile.descriptor,
            CommandProcessOwnershipTracker
                .inheritedMarkerDescriptor
        ) == 0
    )
    try #require(
        posix_spawn_file_actions_addclose(
            &fileActions,
            ownershipFile.descriptor
        ) == 0
    )
    try #require(
        posix_spawnattr_setflags(
            &attributes,
            Int16(
                POSIX_SPAWN_SETPGROUP
                    | POSIX_SPAWN_CLOEXEC_DEFAULT
            )
        ) == 0
    )
    try #require(
        posix_spawnattr_setpgroup(&attributes, 0) == 0
    )
    let arguments = ProcessRecoveryCStringArray([
        "/usr/bin/python3",
        "-c",
        """
        import os, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            for descriptor in (1, 2):
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            time.sleep(30)
            os._exit(0)
        with open(sys.argv[1], 'w') as output:
            output.write(str(child))
            output.flush()
            os.fsync(output.fileno())
        time.sleep(30)
        """,
        childPIDFileURL.path
    ])
    var environment = ProcessInfo.processInfo.environment
    environment[
        CommandProcessOwnershipTracker.environmentKey
    ] = commandToken
    environment[
        CommandProcessOwnershipTracker
            .ownershipDescriptorEnvironmentKey
    ] = String(
        CommandProcessOwnershipTracker.inheritedMarkerDescriptor
    )
    let environmentStorage = ProcessRecoveryCStringArray(
        environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    )
    let spawnStatus = "/usr/bin/python3".withCString {
        posix_spawn(
            &leaderProcessIdentifier,
            $0,
            &fileActions,
            &attributes,
            arguments.pointer,
            environmentStorage.pointer
        )
    }
    try #require(spawnStatus == 0)
    didSpawn = true

    var escapedChildProcessIdentifier: pid_t?
    for _ in 0..<500 {
        if let data = try? Data(contentsOf: childPIDFileURL),
           let value = String(data: data, encoding: .utf8),
           let processIdentifier = pid_t(
                value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
           ) {
            escapedChildProcessIdentifier = processIdentifier
            break
        }
        usleep(10_000)
    }
    guard let escapedChildProcessIdentifier else {
        _ = kill(-leaderProcessIdentifier, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(leaderProcessIdentifier, &status, 0)
        throw ProcessRecoveryTestError.childPIDUnavailable
    }
    return SimulatedOrdinaryCommandOrphan(
        commandToken: commandToken,
        leaderProcessIdentifier: leaderProcessIdentifier,
        escapedChildProcessIdentifier:
            escapedChildProcessIdentifier,
        markerURL: markerURL,
        childPIDFileURL: childPIDFileURL
    )
}

private enum ProcessRecoveryTestError: Error {
    case childPIDUnavailable
    case malformedMarker
    case spawnFailed(Int32)
}

private struct ZombieCreatorHarness {
    let helperProcessIdentifier: pid_t
    let creatorProcessIdentifier: pid_t
    let creatorPIDFileURL: URL
    let releaseFileURL: URL
    let exitedUnreapedFileURL: URL

    func releaseCreator() {
        _ = FileManager.default.createFile(
            atPath: releaseFileURL.path,
            contents: Data()
        )
    }

    func waitUntilCreatorExitedWithoutBeingReaped() -> Bool {
        for _ in 0..<500 {
            if FileManager.default.fileExists(
                atPath: exitedUnreapedFileURL.path
            ) {
                usleep(50_000)
                return true
            }
            usleep(10_000)
        }
        return false
    }

    func cleanUp() {
        _ = kill(-helperProcessIdentifier, SIGKILL)
        reapTestProcess(helperProcessIdentifier)
        try? FileManager.default.removeItem(
            at: creatorPIDFileURL
        )
        try? FileManager.default.removeItem(
            at: releaseFileURL
        )
        try? FileManager.default.removeItem(
            at: exitedUnreapedFileURL
        )
    }
}

private final class ProcessRecoveryCStringArray {
    private let pointers:
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

    var pointer: UnsafeMutablePointer<
        UnsafeMutablePointer<CChar>?
    > {
        pointers
    }

    init(_ strings: [String]) {
        pointers = .allocate(capacity: strings.count + 1)
        for (index, value) in strings.enumerated() {
            pointers[index] = strdup(value)
        }
        pointers[strings.count] = nil
    }

    deinit {
        var index = 0
        while let pointer = pointers[index] {
            free(pointer)
            index += 1
        }
        pointers.deallocate()
    }
}

private func recoveryWaitUntilProcessIsGone(
    _ processIdentifier: pid_t,
    attempts: Int = 80
) -> Bool {
    for _ in 0..<attempts {
        var processInfo = proc_bsdinfo()
        let expectedByteCount =
            Int32(MemoryLayout<proc_bsdinfo>.size)
        let byteCount = withUnsafeMutablePointer(to: &processInfo) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                expectedByteCount
            )
        }
        if byteCount == expectedByteCount,
           processInfo.pbi_status == SZOMB {
            return true
        }
        errno = 0
        if kill(processIdentifier, 0) == -1,
           errno == ESRCH {
            return true
        }
        usleep(25_000)
    }
    return false
}

private func spawnZombieCreatorHarness() throws
    -> ZombieCreatorHarness {
    let creatorPIDFileURL =
        FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ios-sign-kit-zombie-creator-\(UUID().uuidString)"
        )
    let releaseFileURL =
        FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ios-sign-kit-release-creator-\(UUID().uuidString)"
        )
    let exitedUnreapedFileURL =
        FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ios-sign-kit-unreaped-creator-\(UUID().uuidString)"
        )
    let arguments = ProcessRecoveryCStringArray([
        "/usr/bin/python3",
        "-c",
        """
        import os, sys, time
        for descriptor in (1, 2):
            try:
                os.close(descriptor)
            except OSError:
                pass
        child = os.fork()
        if child == 0:
            with open(sys.argv[1], 'w') as output:
                output.write(str(os.getpid()))
                output.flush()
                os.fsync(output.fileno())
            while not os.path.exists(sys.argv[2]):
                time.sleep(0.01)
            with open(sys.argv[3], 'w') as output:
                output.write('exiting-unreaped')
                output.flush()
                os.fsync(output.fileno())
            os._exit(0)
        time.sleep(30)
        """,
        creatorPIDFileURL.path,
        releaseFileURL.path,
        exitedUnreapedFileURL.path
    ])
    let environment = ProcessRecoveryCStringArray(
        ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    )
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
        throw ProcessRecoveryTestError.spawnFailed(EINVAL)
    }
    defer {
        posix_spawnattr_destroy(&attributes)
    }
    let attributeStatus = posix_spawnattr_setflags(
        &attributes,
        Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
        )
    )
    guard attributeStatus == 0 else {
        throw ProcessRecoveryTestError
            .spawnFailed(attributeStatus)
    }
    let processGroupStatus =
        posix_spawnattr_setpgroup(&attributes, 0)
    guard processGroupStatus == 0 else {
        throw ProcessRecoveryTestError
            .spawnFailed(processGroupStatus)
    }
    var processIdentifier: pid_t = 0
    let status = "/usr/bin/python3".withCString {
        posix_spawn(
            &processIdentifier,
            $0,
            nil,
            &attributes,
            arguments.pointer,
            environment.pointer
        )
    }
    guard status == 0 else {
        throw ProcessRecoveryTestError.spawnFailed(status)
    }
    var creatorProcessIdentifier: pid_t?
    for _ in 0..<500 {
        if let data = try? Data(
            contentsOf: creatorPIDFileURL
        ),
        let value = String(data: data, encoding: .utf8),
        let identifier = pid_t(
            value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) {
            creatorProcessIdentifier = identifier
            break
        }
        usleep(10_000)
    }
    guard let creatorProcessIdentifier else {
        _ = kill(-processIdentifier, SIGKILL)
        reapTestProcess(processIdentifier)
        throw ProcessRecoveryTestError
            .childPIDUnavailable
    }
    return ZombieCreatorHarness(
        helperProcessIdentifier: processIdentifier,
        creatorProcessIdentifier:
            creatorProcessIdentifier,
        creatorPIDFileURL: creatorPIDFileURL,
        releaseFileURL: releaseFileURL,
        exitedUnreapedFileURL:
            exitedUnreapedFileURL
    )
}

private func reapTestProcess(_ processIdentifier: pid_t) {
    var status: Int32 = 0
    while waitpid(processIdentifier, &status, 0) == -1,
          errno == EINTR {}
}

private func changeRecordedCreatorStartTime(
    markerURL: URL
) throws {
    let data = try Data(contentsOf: markerURL)
    guard var root = try JSONSerialization.jsonObject(
        with: data
    ) as? [String: Any],
    var creator = root["creator"] as? [String: Any],
    let startSeconds = creator["startSeconds"] as? NSNumber
    else {
        throw ProcessRecoveryTestError.malformedMarker
    }
    creator["startSeconds"] =
        startSeconds.uint64Value &+ 1
    root["creator"] = creator
    let changedData = try JSONSerialization.data(
        withJSONObject: root
    )
    let descriptor = markerURL.path.withCString {
        open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
        throw ProcessRecoveryTestError.malformedMarker
    }
    defer { close(descriptor) }
    try changedData.withUnsafeBytes { storage in
        var offset = 0
        while offset < storage.count {
            let byteCount = Darwin.write(
                descriptor,
                storage.baseAddress?.advanced(by: offset),
                storage.count - offset
            )
            if byteCount > 0 {
                offset += byteCount
            } else if byteCount < 0, errno == EINTR {
                continue
            } else {
                throw ProcessRecoveryTestError.malformedMarker
            }
        }
    }
    guard fsync(descriptor) == 0 else {
        throw ProcessRecoveryTestError.malformedMarker
    }
}

private final class RecoveryProcessListSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [CommandResult]
    private var calls = 0

    init(_ results: [CommandResult]) { self.results = results }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func next() -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        let result = results[min(calls, results.count - 1)]
        calls += 1
        return result
    }
}
