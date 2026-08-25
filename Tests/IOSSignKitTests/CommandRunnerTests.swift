import Darwin
import Foundation
import Testing
@testable import IOSSignKit

struct CommandRunnerTests {
    @Test
    func preservesSplitUTF8InLiveOutput() throws {
        let recorder = OutputRecorder()
        let result = try CommandRunner().run(
            "/bin/sh",
            arguments: [
                "-c",
                "printf '\\344'; sleep 0.03; printf '\\270\\255'; sleep 0.03; printf '\\360\\237'; sleep 0.03; printf '\\230\\200'"
            ],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            },
            timeoutSeconds: 2
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput == "中😀")
        #expect(recorder.standardOutput == "中😀")
        #expect(recorder.standardError.isEmpty)
    }

    @Test
    func replacesMalformedUTF8WithoutDroppingFollowingText() throws {
        let recorder = OutputRecorder()
        let result = try CommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "printf '\\377ok'"],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            },
            timeoutSeconds: 2
        )

        #expect(result.standardOutput == "�ok")
        #expect(recorder.standardOutput == "�ok")
    }

    @Test
    func timeoutTerminatesTheWholeProcessGroup() throws {
        let result = try CommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "sleep 30 & child=$!; echo $child; wait"],
            timeoutSeconds: 0.2
        )

        #expect(result.terminationStatus == 124)
        let childPID = try #require(
            result.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .first
                .flatMap { pid_t($0) }
        )

        var isGone = false
        for _ in 0..<20 {
            errno = 0
            if kill(childPID, 0) == -1, errno == ESRCH {
                isGone = true
                break
            }
            usleep(25_000)
        }
        #expect(isGone)
    }

    @Test
    func cancellationWinsWhenScriptTrapsTermAndExitsZero() throws {
        let recorder = OutputRecorder()
        let command = try CommandRunner().start(
            "/bin/sh",
            arguments: [
                "-c",
                "trap 'exit 0' TERM; echo ready; while :; do sleep 1; done"
            ],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            }
        )

        for _ in 0..<100 where !recorder.standardOutput.contains("ready") {
            usleep(10_000)
        }
        command.cancel()
        let result = command.waitUntilExit(timeoutSeconds: 3)

        #expect(result.terminationStatus == 130)
    }

    @Test
    func cancellationAfterLeaderExitStillWinsWhileAChildIsSettling() throws {
        let recorder = OutputRecorder()
        let command = try CommandRunner().start(
            "/bin/sh",
            arguments: [
                "-c",
                "(trap '' TERM; exec /usr/bin/tail -f /dev/null) & echo ready; exit 0"
            ],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            }
        )

        for _ in 0..<100 where !recorder.standardOutput.contains("ready") {
            usleep(10_000)
        }
        usleep(50_000)
        command.cancel()
        let result = command.waitUntilExit(timeoutSeconds: 3)

        #expect(result.terminationStatus == 130)
        #expect(result.processGroupTerminationWasConfirmed)
    }

    @Test
    func cancellationKillsChildThatIgnoresTermAndClosesOutputPipes() throws {
        let recorder = OutputRecorder()
        let command = try CommandRunner().start(
            "/bin/sh",
            arguments: [
                "-c",
                "(trap '' TERM; exec /usr/bin/tail -f /dev/null >/dev/null 2>&1) & child=$!; echo $child; wait"
            ],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            }
        )

        for _ in 0..<100 where recorder.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            usleep(10_000)
        }
        let childPID = try #require(
            pid_t(recorder.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        )

        command.cancel()
        let result = command.waitUntilExit(timeoutSeconds: 3)

        #expect(result.terminationStatus == 130)
        #expect(waitUntilProcessIsGone(childPID))
    }

    @Test
    func leaderExitDoesNotWaitForBackgroundChildHoldingPipes() throws {
        let startedAt = Date()
        let result = try CommandRunner().run(
            "/bin/sh",
            arguments: ["-c", "sleep 30 & echo done"],
            timeoutSeconds: 2
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.contains("done"))
        #expect(Date().timeIntervalSince(startedAt) < 1.5)
    }

    @Test
    func normalLeaderExitStillCleansChildThatClosedPipes() throws {
        let result = try CommandRunner().run(
            "/bin/sh",
            arguments: [
                "-c",
                "(trap '' TERM; exec /usr/bin/tail -f /dev/null >/dev/null 2>&1) & echo $!"
            ],
            timeoutSeconds: 2
        )
        let childPID = try #require(
            pid_t(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        )

        #expect(result.terminationStatus == 0)
        #expect(waitUntilProcessIsGone(childPID))
    }

    @Test
    func normalLeaderExitCleansAChildThatEscapedIntoANewSession() throws {
        let result = try CommandRunner().run(
            "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os, time
                child = os.fork()
                if child == 0:
                    os.setsid()
                    os.close(1)
                    os.close(2)
                    time.sleep(30)
                    os._exit(0)
                print(child, flush=True)
                """
            ],
            timeoutSeconds: 3
        )
        let childPID = try #require(
            pid_t(
                result.standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
        defer {
            if !waitUntilProcessIsGone(childPID) {
                _ = kill(childPID, SIGKILL)
            }
        }

        #expect(result.terminationStatus == 0)
        #expect(result.processGroupTerminationWasConfirmed)
        #expect(waitUntilProcessIsGone(childPID))
    }

    @Test
    func ownershipFileMarkerSurvivesExec() throws {
        let result = try CommandRunner().run(
            "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os
                os.fstat(198)
                try:
                    os.write(198, b'x')
                    print('marker-writable')
                except OSError:
                    print('marker-open-read-only')
                """
            ],
            timeoutSeconds: 2
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.contains("marker-open-read-only"))
        #expect(!result.standardOutput.contains("marker-writable"))
        #expect(result.processGroupTerminationWasConfirmed)
    }

    @Test
    func ownershipDescriptorEnvironmentCannotBeOverriddenByCaller() throws {
        let result = try CommandRunner().run(
            "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os
                os.fstat(198)
                print(os.environ['IOS_SIGN_KIT_OWNERSHIP_FD'])
                """
            ],
            environmentOverrides: [
                "IOS_SIGN_KIT_OWNERSHIP_FD": "999"
            ],
            timeoutSeconds: 2
        )

        #expect(result.completedSuccessfullyAndFullyTerminated)
        #expect(
            result.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "198"
        )
    }

    @Test
    func completedOrdinaryCommandRemovesItsFileMarker() throws {
        let result = try CommandRunner().run(
            "/bin/sh",
            arguments: [
                "-c",
                "printf %s \"$IOS_SIGN_KIT_COMMAND_TOKEN\""
            ],
            timeoutSeconds: 2
        )
        let commandToken = result.standardOutput

        #expect(result.completedSuccessfullyAndFullyTerminated)
        #expect(commandToken.hasPrefix("ios-sign-kit-command-"))
        #expect(
            !FileManager.default.fileExists(
                atPath: CommandProcessOwnershipTracker
                    .markerFileURL(for: commandToken)
                    .path
            )
        )
    }

    @Test
    func concurrentCommandsUseDistinctPersistentMarkerIdentities() throws {
        var commands: [(DeploymentToken, RunningCommand)] = []
        defer {
            commands.forEach { $0.1.cancel() }
            commands.forEach {
                _ = $0.1.waitUntilExit(timeoutSeconds: 3)
            }
        }

        for _ in 0..<25 {
            let token = DeploymentToken.make()
            let command = try CommandRunner().start(
                "/bin/sleep",
                arguments: ["30"],
                environmentOverrides: [
                    DeploymentProcessRecovery
                        .deploymentTokenEnvironmentKey:
                        token.rawValue
                ]
            )
            commands.append((token, command))
        }
        usleep(50_000)

        let identities = try Set(commands.map {
            try markerIdentityKey(
                at: CommandProcessOwnershipTracker.markerFileURL(
                    for: $0.0.rawValue
                )
            )
        })
        #expect(identities.count == commands.count)
    }

    @Test
    func cancellingOneCommandCannotTerminateAnotherMarkerOwner() throws {
        let firstToken = DeploymentToken.make()
        let secondToken = DeploymentToken.make()
        let first = try CommandRunner().start(
            "/bin/sleep",
            arguments: ["30"],
            environmentOverrides: [
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                    firstToken.rawValue
            ]
        )
        let second = try CommandRunner().start(
            "/bin/sleep",
            arguments: ["30"],
            environmentOverrides: [
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                    secondToken.rawValue
            ]
        )
        defer {
            first.cancel()
            second.cancel()
            _ = first.waitUntilExit(timeoutSeconds: 3)
            _ = second.waitUntilExit(timeoutSeconds: 3)
        }

        first.cancel()
        let firstResult = first.waitUntilExit(timeoutSeconds: 3)

        #expect(firstResult.terminationStatus == 130)
        #expect(
            CommandProcessOwnershipTracker(
                environmentKey:
                    DeploymentProcessRecovery
                        .deploymentTokenEnvironmentKey,
                exactValue: secondToken.rawValue
            ).discoverAllOwnedProcesses() == .found
        )
    }

    @Test
    func injectedTrackerDoesNotReadOrDeleteProductionMarkers() throws {
        let token = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(for: token)
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-production-marker".utf8).write(
            to: markerURL,
            options: .atomic
        )
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }
        let tracker = CommandProcessOwnershipTracker(
            match: .exact(
                environmentKey:
                    DeploymentProcessRecovery
                        .deploymentTokenEnvironmentKey,
                value: token
            ),
            processListProvider: { .available([]) },
            processOwnerInspector: { _ in .currentUser },
            processTokenInspector: { _, _ in .absent }
        )

        #expect(tracker.discoverAllOwnedProcesses() == .notFound)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func childCloseActionsNeverCloseTheInheritedMarkerDescriptor() {
        #expect(
            CommandProcessOwnershipTracker.childDescriptorsToClose(
                [1, 2, 198, 199]
            ) == [1, 2, 199]
        )
    }

    @Test
    func commandPipeDescriptorsAreCloseOnExec() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer {
            descriptors.forEach { close($0) }
        }

        try RunningCommand.configureCloseOnExec(descriptors)

        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            try #require(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0)
        }
    }

    @Test
    func ownershipMarkerSourceAvoidsStandardAndTargetDescriptors() throws {
        let token = DeploymentToken.make().rawValue
        let prepared =
            try CommandProcessOwnershipTracker.prepareOwnershipFile(
                token: token
            )
        defer {
            close(prepared.descriptor)
            _ = CommandProcessOwnershipTracker(
                environmentKey:
                    DeploymentProcessRecovery
                        .deploymentTokenEnvironmentKey,
                exactValue: token
            ).removeMarkerIfPresent()
        }

        #expect(
            prepared.descriptor >
                CommandProcessOwnershipTracker
                    .inheritedMarkerDescriptor
        )
    }

    @Test
    func ownershipMarkerPermissionsDoNotDependOnCreationMask() throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-strict-mask-\(UUID().uuidString)"
            )
        let descriptor = markerURL.path.withCString {
            open(
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
                0
            )
        }
        try #require(descriptor >= 0)
        defer {
            close(descriptor)
            _ = markerURL.path.withCString { unlink($0) }
        }

        try CommandProcessOwnershipTracker
            .secureOwnershipMarkerPermissions(descriptor)

        var fileStatus = stat()
        try #require(fstat(descriptor, &fileStatus) == 0)
        #expect((fileStatus.st_mode & 0o777) == 0o600)
    }

    @Test
    func completeTerminationWaitCannotUpgradeAnUnverifiedResult() throws {
        let coordinator = CommandExecutionCoordinator()
        let runner = CommandRunner(
            executionCoordinator: coordinator
        )
        let deploymentToken = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: deploymentToken
            )
        let releaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-release-leader-\(UUID().uuidString)"
            )
        let recorder = OutputRecorder()
        var command: RunningCommand? = try runner.start(
            "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os, sys, time
                child = os.fork()
                if child == 0:
                    os.close(198)
                    os.setsid()
                    os.close(1)
                    os.close(2)
                    time.sleep(30)
                    os._exit(0)
                print(child, flush=True)
                while not os.path.exists(sys.argv[1]):
                    time.sleep(0.01)
                """,
                releaseURL.path
            ],
            environmentOverrides: [
                DeploymentProcessRecovery
                    .deploymentTokenEnvironmentKey:
                    deploymentToken
            ],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            }
        )
        for _ in 0..<100 where recorder.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            usleep(10_000)
        }
        guard let escapedPID = pid_t(
            recorder.standardOutput
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
        ) else {
            Issue.record("未获得逃逸子进程 PID")
            command?.cancel()
            _ = command?.waitUntilExit(timeoutSeconds: 3)
            return
        }
        let markerDescriptor = markerURL.path.withCString {
            open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        }
        try #require(markerDescriptor >= 0)
        defer { close(markerDescriptor) }
        try Data("{}".utf8).withUnsafeBytes { storage in
            try #require(
                Darwin.write(
                    markerDescriptor,
                    storage.baseAddress,
                    storage.count
                ) == storage.count
            )
        }
        try #require(fsync(markerDescriptor) == 0)
        #expect(
            FileManager.default.createFile(
                atPath: releaseURL.path,
                contents: Data()
            )
        )
        let result = try #require(
            command?.waitUntilExit(timeoutSeconds: 3)
        )
        defer {
            if !waitUntilProcessIsGone(escapedPID) {
                _ = kill(escapedPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: releaseURL)
            try? FileManager.default.removeItem(at: markerURL)
        }

        #expect(!result.processGroupTerminationWasConfirmed)
        #expect(
            !(command?.cancelAndWaitForTermination(
                timeoutSeconds: 0.1
            ) ?? true)
        )
        command = nil
        #expect(
            !runner.cancelAllRunningCommandsAndWait(
                timeoutSeconds: 0.1
            )
        )
        do {
            _ = try runner.start(
                "/usr/bin/true",
                arguments: []
            )
            Issue.record("未确认终止后不得启动新命令")
        } catch {
            #expect(
                error.localizedDescription
                    .contains("已阻止启动新命令")
            )
        }
    }

    @Test
    func confirmedNonzeroExitDoesNotLatchCommandRunner() throws {
        let runner = CommandRunner()
        let failed = try runner.run(
            "/bin/sh",
            arguments: ["-c", "exit 7"],
            timeoutSeconds: 2
        )
        let next = try runner.run(
            "/usr/bin/true",
            arguments: [],
            timeoutSeconds: 2
        )

        #expect(failed.terminationStatus == 7)
        #expect(failed.processGroupTerminationWasConfirmed)
        #expect(next.completedSuccessfullyAndFullyTerminated)
        #expect(runner.cancelAllRunningCommandsAndWait())
    }

    @Test
    func unconfirmedTimeoutLatchesCommandRunner() throws {
        let runner = CommandRunner()
        let deploymentToken = DeploymentToken.make().rawValue
        let markerURL =
            CommandProcessOwnershipTracker.markerFileURL(
                for: deploymentToken
            )
        let recorder = OutputRecorder()
        let command = try runner.start(
            "/bin/sh",
            arguments: [
                "-c",
                "trap '' TERM; echo ready; while :; do sleep 1; done"
            ],
            environmentOverrides: [
                DeploymentProcessRecovery
                    .deploymentTokenEnvironmentKey:
                    deploymentToken
            ],
            onOutput: { text, isError in
                recorder.append(text, isError: isError)
            }
        )
        defer {
            command.cancel()
            _ = command.waitUntilExit(timeoutSeconds: 3)
            try? FileManager.default.removeItem(at: markerURL)
        }
        for _ in 0..<100 where
            !recorder.standardOutput.contains("ready") {
            usleep(10_000)
        }
        let descriptor = markerURL.path.withCString {
            open($0, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        }
        try #require(descriptor >= 0)
        let malformedData = Data("{}".utf8)
        let written = malformedData.withUnsafeBytes {
            Darwin.write(
                descriptor,
                $0.baseAddress,
                $0.count
            )
        }
        try #require(written == malformedData.count)
        try #require(fsync(descriptor) == 0)
        close(descriptor)

        let result = command.waitUntilExit(
            timeoutSeconds: 0.05
        )

        #expect(result.terminationStatus == 124)
        #expect(!result.processGroupTerminationWasConfirmed)
        do {
            _ = try runner.start(
                "/usr/bin/true",
                arguments: []
            )
            Issue.record("未确认的超时不得允许后续命令")
        } catch {
            #expect(
                error.localizedDescription
                    .contains("已阻止启动新命令")
            )
        }
    }

    @Test
    func ownedProcessDiscoveryFailsClosedWhenArgumentsCannotBeVerified() {
        let tracker = CommandProcessOwnershipTracker(
            match: .exact(
                environmentKey: "IOS_SIGN_KIT_COMMAND_TOKEN",
                value: "test-token"
            ),
            processListProvider: {
                .available([42])
            },
            processOwnerInspector: { _ in
                .currentUser
            },
            processTokenInspector: { _, _ in
                .unavailable
            }
        )

        #expect(tracker.discoverAllOwnedProcesses() == .unavailable)
        #expect(tracker.recoverAllOwnedProcesses() == .unresolved)
    }

    @Test
    func ownedProcessDiscoverySkipsProcessesOwnedByAnotherUser() {
        let tracker = CommandProcessOwnershipTracker(
            match: .prefix(
                environmentKey: "IOS_SIGN_KIT_DEPLOYMENT_TOKEN",
                value: "ios-sign-kit-deploy-"
            ),
            processListProvider: {
                .available([42])
            },
            processOwnerInspector: { _ in
                .otherUser
            },
            processTokenInspector: { _, _ in
                .unavailable
            }
        )

        #expect(tracker.discoverAllOwnedProcesses() == .notFound)
    }

    @Test
    func malformedProcessArgumentsCannotBeTreatedAsTokenAbsence() {
        let result =
            CommandProcessOwnershipTracker.inspectProcessArgumentsPayload(
                [0x01, 0x02][...],
                match: .exact(
                    environmentKey: "IOS_SIGN_KIT_COMMAND_TOKEN",
                    value: "test-token"
                )
            )

        #expect(result == .unavailable)
    }

    @Test
    func capturedOutputIsBoundedAndPreservesHeadAndTail() throws {
        let result = try CommandRunner(maximumCapturedOutputBytes: 1_024).run(
            "/usr/bin/printf",
            arguments: ["HEAD%02000dTAIL", "0"],
            timeoutSeconds: 2
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.contains("HEAD"))
        #expect(result.standardOutput.contains("TAIL"))
        #expect(result.standardOutput.contains("已省略"))
        #expect(result.standardOutput.utf8.count < 1_200)
        #expect(result.standardOutputWasTruncated)
        #expect(!result.standardErrorWasTruncated)
    }

    @Test
    func forcedCollectorDrainPreservesPendingTailAfterDelayedReadCallback() throws {
        let pipe = Pipe()
        let collector = CommandOutputCollector(
            handle: pipe.fileHandleForReading,
            isError: false,
            maximumCapturedBytes: 4_096,
            onOutput: nil
        )
        try pipe.fileHandleForWriting.write(
            contentsOf: Data(
                "tail\nIOS_SIGN_KIT_FAILURE_REASON=device_preparation_required\n".utf8
            )
        )
        try pipe.fileHandleForWriting.close()

        collector.forceFinish()
        collector.waitUntilFinished()

        #expect(
            collector.stringValue
                .contains("IOS_SIGN_KIT_FAILURE_REASON=device_preparation_required")
        )
        #expect(!collector.wasTruncated)
    }

    @Test
    func forcedCollectorDrainMarksOpenPipeAsTruncated() throws {
        let pipe = Pipe()
        let collector = CommandOutputCollector(
            handle: pipe.fileHandleForReading,
            isError: false,
            maximumCapturedBytes: 4_096,
            onOutput: nil
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("available tail".utf8))

        collector.forceFinish()
        collector.waitUntilFinished()
        try pipe.fileHandleForWriting.close()

        #expect(collector.stringValue == "available tail")
        #expect(collector.wasTruncated)
    }

    @Test
    func forcedCollectorDrainIsTimeAndMemoryBoundedWhileWriterContinues() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        let reader = FileHandle(
            fileDescriptor: descriptors[0],
            closeOnDealloc: true
        )
        let writer = descriptors[1]
        let existingFlags = fcntl(writer, F_GETFL)
        try #require(existingFlags >= 0)
        try #require(
            fcntl(writer, F_SETFL, existingFlags | O_NONBLOCK) == 0
        )
        try #require(fcntl(writer, F_SETNOSIGPIPE, 1) == 0)
        let writerFinished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer {
                close(writer)
                writerFinished.signal()
            }
            var bytes = [UInt8](repeating: 65, count: 64 * 1_024)
            let deadline = DispatchTime.now() + 1
            while DispatchTime.now() < deadline {
                let result = bytes.withUnsafeMutableBytes { storage in
                    Darwin.write(
                        writer,
                        storage.baseAddress,
                        storage.count
                    )
                }
                if result >= 0 {
                    continue
                }
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1_000)
                    continue
                }
                break
            }
        }
        let collector = CommandOutputCollector(
            handle: reader,
            isError: false,
            maximumCapturedBytes: 1_024,
            onOutput: nil
        )
        usleep(10_000)

        let startedAt = DispatchTime.now().uptimeNanoseconds
        collector.forceFinish()
        collector.waitUntilFinished()
        let elapsedNanoseconds =
            DispatchTime.now().uptimeNanoseconds - startedAt

        #expect(elapsedNanoseconds < 500_000_000)
        #expect(collector.wasTruncated)
        #expect(collector.stringValue.utf8.count < 1_200)
        #expect(
            writerFinished.wait(timeout: .now() + 1) == .success
        )
    }

    @Test
    func concurrentCommandsDoNotInheritEachOthersOutputPipes() async throws {
        let results = try await withThrowingTaskGroup(
            of: CommandResult.self,
            returning: [CommandResult].self
        ) { group in
            for index in 0..<100 {
                group.addTask {
                    try CommandRunner().run(
                        "/bin/sh",
                        arguments: [
                            "-c",
                            """
                            printf 'command-\(index) %s' \
                              "$IOS_SIGN_KIT_COMMAND_TOKEN"
                            """
                        ],
                        timeoutSeconds: 2
                    )
                }
            }
            var results: [CommandResult] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        #expect(results.count == 100)
        #expect(
            results.allSatisfy {
                $0.completedSuccessfullyAndFullyTerminated
            }
        )
        #expect(results.allSatisfy { !$0.standardErrorWasTruncated })
        let commandTokens = results.compactMap {
            $0.standardOutput.split(
                whereSeparator: \.isWhitespace
            ).last.map(String.init)
        }
        #expect(commandTokens.count == results.count)
        #expect(
            commandTokens.allSatisfy {
                !FileManager.default.fileExists(
                    atPath: CommandProcessOwnershipTracker
                        .markerFileURL(for: $0)
                        .path
                )
            }
        )
    }

    @Test
    func blockedLiveOutputCallbackCannotBlockCommandSettlement() throws {
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let resultReady = DispatchSemaphore(value: 0)
        let resultBox = CommandResultBox()
        let command = try CommandRunner().start(
            "/bin/sh",
            arguments: [
                "-c",
                "printf HEAD; sleep 0.05; printf TAIL"
            ],
            onOutput: { text, isError in
                guard !isError, text.contains("HEAD") else {
                    return
                }
                callbackEntered.signal()
                releaseCallback.wait()
            }
        )
        defer {
            releaseCallback.signal()
        }

        #expect(callbackEntered.wait(timeout: .now() + 1) == .success)
        Thread.detachNewThread {
            resultBox.store(command.waitUntilExit(timeoutSeconds: 2))
            resultReady.signal()
        }

        #expect(resultReady.wait(timeout: .now() + 1.5) == .success)
        let result = try #require(resultBox.value)
        #expect(result.terminationStatus == 0)
        #expect(result.processGroupTerminationWasConfirmed)
        #expect(result.standardOutput.contains("HEAD"))
        #expect(
            result.standardOutput.contains("TAIL")
                || result.standardOutputWasTruncated
        )
    }

    @Test
    @MainActor
    func deployOutputSinkCoalescesBurstWithoutUnboundedMainActorJobs() async throws {
        var deliveries: [String] = []
        let (deliveryEvents, deliveryContinuation) =
            AsyncStream.makeStream(of: String.self)
        let sink = DeployOutputSink(maximumPendingCharacters: 1_000) { text, _ in
            deliveries.append(text)
            deliveryContinuation.yield(text)
        }

        for index in 0..<10_000 {
            sink.enqueue("line-\(index)\n", isError: index.isMultiple(of: 2))
        }
        let timeoutTask = Task.detached {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            deliveryContinuation.finish()
        }
        defer {
            timeoutTask.cancel()
            deliveryContinuation.finish()
        }
        var deliveryIterator = deliveryEvents.makeAsyncIterator()
        let firstDelivery = try #require(await deliveryIterator.next())

        #expect(deliveries.count == 1)
        #expect(firstDelivery.contains("已省略"))
        #expect(firstDelivery.count < 1_100)
        #expect(firstDelivery.contains("line-9999"))

        sink.enqueue("tail-before-exit\n", isError: true)
        sink.flushNow()
        #expect(deliveries.last == "tail-before-exit\n")
    }

    @Test
    @MainActor
    func invalidatedDeployOutputSinkRejectsLateCommandCallbacks() async throws {
        var deliveries: [String] = []
        let sink = DeployOutputSink { text, _ in
            deliveries.append(text)
        }
        sink.enqueue("before-close\n", isError: false)
        sink.flushNow()
        sink.invalidate()

        sink.enqueue("late-old-command\n", isError: true)
        try await Task.sleep(for: .milliseconds(200))

        #expect(deliveries == ["before-close\n"])
    }
}

private final class CommandResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: CommandResult?

    func store(_ value: CommandResult) {
        lock.withLock {
            storedValue = value
        }
    }

    var value: CommandResult? {
        lock.withLock { storedValue }
    }
}

private func waitUntilProcessIsGone(_ processIdentifier: pid_t) -> Bool {
    for _ in 0..<80 {
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
        if kill(processIdentifier, 0) == -1, errno == ESRCH {
            return true
        }
        usleep(25_000)
    }
    return false
}

private func markerIdentityKey(at url: URL) throws -> String {
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    )
    let root = try #require(object as? [String: Any])
    let identity = try #require(root["identity"] as? [String: Any])
    let fields = [
        "device",
        "inode",
        "generation",
        "birthSeconds",
        "birthNanoseconds"
    ]
    return try fields.map {
        String(describing: try #require(identity[$0]))
    }.joined(separator: ":")
}

private final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var error = ""

    func append(_ text: String, isError: Bool) {
        lock.lock()
        if isError {
            error.append(text)
        } else {
            output.append(text)
        }
        lock.unlock()
    }

    var standardOutput: String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    var standardError: String {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
