import Foundation
import Testing
@testable import IOSSignKit

struct StandardIOSDeploymentTests {
    @Test(arguments: [
        XcodeContainer.Kind.project,
        XcodeContainer.Kind.workspace
    ])
    func standardPipelineUsesContainerSpecificArgumentsAndStableDeviceID(
        kind: XcodeContainer.Kind
    ) async throws {
        let fixture = try StandardDeploymentFixture(kind: kind)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let inspectorRequests = LockedValue<[SignedIOSAppInspectionRequest]>([])
        let script = DeploymentCommandScript { call in
            if call.arguments.contains("-showBuildSettings") {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            return .result(.success(output: call.stage.rawValue))
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                inspectorRequests.withValue { $0.append(request) }
                return fixture.verifiedApplication(
                    at: request.candidate.applicationURL,
                    expiry: expiry
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)
        let calls = script.recordedCalls

        #expect(result.commandResult.terminationStatus == 0)
        #expect(result.verifiedProfileExpirationDate == expiry)
        #expect(calls.map(\.stage) == [.settings, .build, .install, .launch])
        #expect(calls.allSatisfy { $0.launchPath != "/bin/sh" })
        #expect(calls.allSatisfy { $0.launchPath != "/bin/zsh" })
        #expect(calls.allSatisfy { !$0.arguments.contains("-c") })
        #expect(calls.allSatisfy { $0.currentDirectoryPath == fixture.rootURL.path })
        #expect(calls.allSatisfy {
            $0.environment[
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey
            ] == fixture.deploymentToken
        })

        let settings = try #require(calls.first)
        let build = try #require(calls.dropFirst().first)
        switch kind {
        case .project:
            #expect(settings.arguments.prefix(2) == [
                "-project", fixture.containerURL.path
            ])
            #expect(build.arguments.prefix(2) == [
                "-project", fixture.containerURL.path
            ])
        case .workspace:
            #expect(settings.arguments.prefix(2) == [
                "-workspace", fixture.containerURL.path
            ])
            #expect(build.arguments.prefix(2) == [
                "-workspace", fixture.containerURL.path
            ])
        }
        #expect(settings.launchPath == "/usr/bin/xcodebuild")
        #expect(settings.arguments.contains("-showBuildSettings"))
        #expect(settings.arguments.contains("-json"))
        #expect(settings.arguments.value(after: "-destination") == "id=device-id")
        let derivedDataPath = try #require(
            settings.arguments.value(after: "-derivedDataPath")
        )
        #expect(derivedDataPath.hasPrefix(fixture.workspaceURL.path + "/"))
        #expect(
            try FileManager.default.attributesOfItem(
                atPath: fixture.workspaceURL.path
            )[.posixPermissions] as? NSNumber == NSNumber(value: 0o700)
        )
        #expect(
            try FileManager.default.attributesOfItem(
                atPath: derivedDataPath
            )[.posixPermissions] as? NSNumber == NSNumber(value: 0o700)
        )

        #expect(build.launchPath == "/usr/bin/xcodebuild")
        #expect(build.arguments.suffix(3) == [
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "build"
        ])

        let install = calls[2]
        #expect(install.launchPath == "/usr/bin/xcrun")
        #expect(install.arguments.prefix(4) == [
            "devicectl", "device", "install", "app"
        ])
        #expect(install.arguments.value(after: "--device") == "device-id")

        let launch = calls[3]
        #expect(launch.launchPath == "/usr/bin/xcrun")
        #expect(launch.arguments == [
            "devicectl", "device", "process", "launch",
            "--device", "device-id", "com.example.App"
        ])

        let inspection = try #require(inspectorRequests.value.first)
        #expect(inspection.expectedBundleIdentifier == "com.example.App")
        #expect(inspection.expectedTeamIdentifier == "TEAM123456")
        #expect(inspection.targetDeviceID == "device-id")
        #expect(inspection.deploymentToken == fixture.deploymentToken)
        #expect(inspection.profileRefreshMode == .force)
        #expect(inspection.derivedDataRootURL.path == derivedDataPath)
    }

    @Test
    func everyExternalDeploymentStageUsesAFiniteTimeout() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let waits = LockedValue<[DeploymentStageWait]>([])
        let script = DeploymentCommandScript { call in
            let result = call.stage == .settings
                ? try fixture.buildSettingsResult(for: call)
                : .success()
            return .command(
                TimeoutRecordingDeploymentStageCommand(
                    processGroupIdentifier: 700
                        + Int32(waits.value.count),
                    result: result,
                    onWait: { timeoutSeconds in
                        waits.withValue {
                            $0.append(
                                DeploymentStageWait(
                                    stage: call.stage,
                                    timeoutSeconds: timeoutSeconds
                                )
                            )
                        }
                    }
                )
            )
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(waits.value == [
            DeploymentStageWait(stage: .settings, timeoutSeconds: 60),
            DeploymentStageWait(stage: .build, timeoutSeconds: 1_800),
            DeploymentStageWait(stage: .install, timeoutSeconds: 300),
            DeploymentStageWait(stage: .launch, timeoutSeconds: 60)
        ])
    }

    @Test
    func workspaceCleanupFailureIsVisibleWithoutRewritingInstallSuccess()
        async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let liveErrors = LockedValue("")
        let script = DeploymentCommandScript { call in
            if call.stage == .settings {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            },
            removeWorkspace: { _ in
                throw StandardDeploymentTestError.workspaceCleanupFailed
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: { output, isError in
                if isError {
                    liveErrors.withValue { $0.append(output) }
                }
            }
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(
            result.commandResult.standardError.contains(
                "构建缓存目录未能清理"
            )
        )
        #expect(liveErrors.value.contains("后续部署会再次尝试"))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.workspaceURL.path
            )
        )
    }

    @Test
    func rejectsMissingAndOutsideContainersBeforeStartingCommands() throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let script = DeploymentCommandScript { _ in
            Issue.record("无效容器不应启动任何命令。")
            return .result(.success())
        }

        let missingURL = fixture.rootURL
            .appendingPathComponent("Missing.xcodeproj", isDirectory: true)
        let missingExecutor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                throw StandardDeploymentTestError.unexpectedInspection
            }
        )
        #expect(throws: StandardIOSDeploymentError.invalidContainer) {
            _ = try missingExecutor.start(
                request: fixture.request(
                    container: .project(path: missingURL.path)
                ),
                onOutput: nil
            )
        }

        let outsideURL = fixture.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Outside-\(UUID().uuidString).xcodeproj",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )
        #expect(throws: StandardIOSDeploymentError.invalidContainer) {
            _ = try missingExecutor.start(
                request: fixture.request(
                    container: .project(path: outsideURL.path)
                ),
                onOutput: nil
            )
        }
        #expect(script.recordedCalls.isEmpty)
    }

    @Test
    func rejectsInvalidDeploymentTokenBeforeCreatingWorkspace() throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let workspaceFactoryWasCalled = LockedValue(false)
        let script = DeploymentCommandScript { _ in
            Issue.record("无效事务令牌不应启动命令。")
            return .result(.success())
        }
        let executor = StandardIOSDeploymentExecutor(
            startCommand: script.start,
            inspectApplication: { _ in
                throw StandardDeploymentTestError.unexpectedInspection
            },
            makeWorkspaceURL: { _ in
                workspaceFactoryWasCalled.withValue { $0 = true }
                return fixture.workspaceURL
            }
        )

        #expect(throws: StandardIOSDeploymentError.invalidDeploymentToken) {
            _ = try executor.start(
                request: fixture.request(deploymentToken: "../../unsafe"),
                onOutput: nil
            )
        }
        #expect(!workspaceFactoryWasCalled.value)
        #expect(script.recordedCalls.isEmpty)
    }

    @Test
    func recoveredWorkspaceCleanupRemovesOnlyTheExactTokenDirectory() throws {
        let cachesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-workspace-cleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        let deploymentsRootURL = cachesURL
            .appendingPathComponent("iOSSignKit", isDirectory: true)
            .appendingPathComponent("Deployments", isDirectory: true)
        let token = DeploymentToken.make().rawValue
        let siblingToken = DeploymentToken.make().rawValue
        let workspaceURL = deploymentsRootURL.appendingPathComponent(
            token,
            isDirectory: true
        )
        let siblingURL = deploymentsRootURL.appendingPathComponent(
            siblingToken,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent(
                "DerivedData/Build/Products/Debug-iphoneos/Example.app",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: siblingURL,
            withIntermediateDirectories: true
        )
        let cleaner = StandardIOSDeploymentWorkspaceCleaner(
            testingCachesDirectoryProvider: { cachesURL }
        )

        try cleaner.cleanup(deploymentToken: token)

        #expect(!FileManager.default.fileExists(atPath: workspaceURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    @Test
    func recoveredWorkspaceCleanupRejectsInvalidTokenAndSymbolicLink() throws {
        let cachesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-workspace-cleanup-safety-\(UUID().uuidString)",
                isDirectory: true
            )
        let deploymentsRootURL = cachesURL
            .appendingPathComponent("iOSSignKit", isDirectory: true)
            .appendingPathComponent("Deployments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: deploymentsRootURL,
            withIntermediateDirectories: true
        )
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-workspace-cleanup-external-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: externalURL,
            withIntermediateDirectories: true
        )
        let token = DeploymentToken.make().rawValue
        let workspaceURL = deploymentsRootURL.appendingPathComponent(
            token,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: workspaceURL,
            withDestinationURL: externalURL
        )
        let cleaner = StandardIOSDeploymentWorkspaceCleaner(
            testingCachesDirectoryProvider: { cachesURL }
        )

        #expect(throws: StandardIOSDeploymentError.invalidDeploymentToken) {
            try cleaner.cleanup(deploymentToken: "../../unsafe")
        }
        #expect(throws: StandardIOSDeploymentError.invalidWorkspace) {
            try cleaner.cleanup(deploymentToken: token)
        }
        #expect(FileManager.default.fileExists(atPath: externalURL.path))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: workspaceURL.path
            ) == externalURL.path
        )
    }

    @Test
    func buildSettingsMustUniquelyMatchSelectedIOSApplication() async throws {
        for mismatch in BuildSettingsMismatch.allCases {
            for mode in [
                ProvisioningProfileRefreshMode.automatic,
                ProvisioningProfileRefreshMode.force
            ] {
                let fixture = try StandardDeploymentFixture(kind: .project)
                let profileCachePreparations = LockedValue(0)
                let script = DeploymentCommandScript { call in
                    if call.stage == .settings {
                        return .result(
                            try fixture.buildSettingsResult(
                                for: call,
                                mismatch: mismatch
                            )
                        )
                    }
                    Issue.record(
                        "无效构建设置不应继续到构建阶段：\(mismatch)"
                    )
                    return .result(.success())
                }
                let executor = fixture.makeExecutor(
                    script: script,
                    inspectApplication: { _ in
                        throw StandardDeploymentTestError.unexpectedInspection
                    },
                    prepareProfileCache: { _, _, _, _, _ in
                        profileCachePreparations.withValue { $0 += 1 }
                        throw StandardDeploymentTestError
                            .unexpectedProfileCachePreparation
                    }
                )

                let execution = try executor.start(
                    request: fixture.request(profileRefreshMode: mode),
                    onOutput: nil
                )
                let result = await waitForDeploymentExecution(execution)

                #expect(result.commandResult.terminationStatus != 0)
                #expect(result.verifiedProfileExpirationDate == nil)
                #expect(script.recordedCalls.map(\.stage) == [.settings])
                #expect(profileCachePreparations.value == 0)
                #expect(
                    result.commandResult.standardError.contains(
                        "无法从 Xcode 构建设置确定唯一 App 产物"
                    )
                )
            }
        }
    }

    @Test
    func settingsFailureStopsBeforeBuildAndInspection() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let inspections = LockedValue(0)
        let script = DeploymentCommandScript { call in
            if call.stage == .settings {
                return .result(.failure(status: 65, error: "settings failed"))
            }
            Issue.record("设置读取失败后不应启动后续命令。")
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                inspections.withValue { $0 += 1 }
                throw StandardDeploymentTestError.unexpectedInspection
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 65)
        #expect(script.recordedCalls.map(\.stage) == [.settings])
        #expect(inspections.value == 0)
    }

    @Test
    func buildFailureStopsBeforeInspectionAndInstallation() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let inspections = LockedValue(0)
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                return .result(.failure(status: 65, error: "build failed"))
            case .install, .launch:
                Issue.record("构建失败后不应安装或启动 App。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                inspections.withValue { $0 += 1 }
                throw StandardDeploymentTestError.unexpectedInspection
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 65)
        #expect(script.recordedCalls.map(\.stage) == [.settings, .build])
        #expect(inspections.value == 0)
    }

    @Test
    func inspectionFailureStopsBeforeInstallation() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let inspections = LockedValue(0)
        let script = DeploymentCommandScript { call in
            if call.stage == .settings {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            if call.stage == .build {
                return .result(.success())
            }
            Issue.record("产物核验失败后不应安装或启动 App。")
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                inspections.withValue { $0 += 1 }
                throw SignedIOSAppInspectionError.applicationUnavailable
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus != 0)
        #expect(script.recordedCalls.map(\.stage) == [.settings, .build])
        #expect(inspections.value == 1)
        #expect(
            result.commandResult.standardError.contains(
                "没有找到唯一可核验的 iPhone App 构建产物"
            )
        )
    }

    @Test(arguments: [
        UnconfirmedInternalCommandStage.profilePreparation,
        UnconfirmedInternalCommandStage.artifactInspection
    ])
    func unconfirmedInternalCommandProcessTreeBlocksRecovery(
        stage: UnconfirmedInternalCommandStage
    ) async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let profileCache = try ProfileTransactionHarness()
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                return .result(.success())
            case .install, .launch:
                Issue.record("内部命令进程树未结束后不应继续安装。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                if stage == .artifactInspection {
                    throw SignedIOSAppInspectionError
                        .commandProcessTreeUnresolved("codesign child remains")
                }
                return fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                if stage == .profilePreparation {
                    throw ProvisioningProfileCacheError
                        .commandProcessTreeUnresolved("security child remains")
                }
                return try await profileCache.manager.prepareTransaction(
                    bundleIdentifier: bundleIdentifier,
                    expectedTeamIdentifier: teamIdentifier,
                    refreshMode: mode,
                    deploymentToken: token,
                    now: now
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution).commandResult

        #expect(result.terminationStatus != 0)
        #expect(!result.processGroupTerminationWasConfirmed)
        #expect(script.recordedCalls.map(\.stage) == (
            stage == .profilePreparation
                ? [.settings]
                : [.settings, .build]
        ))
    }

    @Test(arguments: [
        UnconfirmedExternalCommandStage.build,
        UnconfirmedExternalCommandStage.install
    ])
    func unconfirmedExternalCommandProcessTreeKeepsProfileTransactionActive(
        stage: UnconfirmedExternalCommandStage
    ) async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let profileCache = try ProfileTransactionHarness()
        let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(
            nil
        )
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                if stage == .build {
                    return .result(
                        .failure(
                            status: 124,
                            error: "build timed out",
                            processGroupTerminationWasConfirmed: false
                        )
                    )
                }
                return .result(.success())
            case .install:
                #expect(stage == .install)
                return .result(
                    .failure(
                        status: 124,
                        error: "install timed out",
                        processGroupTerminationWasConfirmed: false
                    )
                )
            case .launch:
                Issue.record("进程树未确认结束后不应继续启动 App。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                let prepared = try await profileCache.manager
                    .prepareTransaction(
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: teamIdentifier,
                        refreshMode: mode,
                        deploymentToken: token,
                        now: now
                    )
                transaction.withValue { $0 = prepared }
                return prepared
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 124)
        #expect(!result.commandResult.processGroupTerminationWasConfirmed)
        #expect(!result.profileCacheRecoveryWasConfirmed)
        #expect(transaction.value?.state == .active)
        #expect(script.recordedCalls.map(\.stage) == (
            stage == .build
                ? [.settings, .build]
                : [.settings, .build, .install]
        ))
        #expect(
            result.commandResult.standardError.contains(
                "已保留 provisioning profile 缓存事务"
            )
        )
    }

    @Test
    func installFailureStopsBeforeLaunch() async throws {
        let fixture = try StandardDeploymentFixture(kind: .workspace)
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                return .result(.success())
            case .install:
                return .result(.failure(status: 1, error: "install failed"))
            case .launch:
                Issue.record("安装失败后不应启动 App。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 1)
        #expect(result.verifiedProfileExpirationDate == nil)
        #expect(script.recordedCalls.map(\.stage) == [
            .settings, .build, .install
        ])
    }

    @Test
    func launchFailurePreservesInstallationSuccessAndExactProfileExpiry() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let expiry = Date(timeIntervalSince1970: 1_810_000_000)
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build, .install:
                return .result(.success())
            case .launch:
                return .result(
                    .failure(
                        status: 1,
                        error: "device locked",
                        processGroupTerminationWasConfirmed: false
                    )
                )
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL,
                    expiry: expiry
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(!result.commandResult.processGroupTerminationWasConfirmed)
        #expect(result.verifiedProfileExpirationDate == expiry)
        #expect(script.recordedCalls.map(\.stage) == [
            .settings, .build, .install, .launch
        ])
        #expect(
            result.commandResult.standardError.contains(
                "App 已安装，但自动启动失败"
            )
        )
    }

    @Test
    func hostInstallReceiptRecordsVerifiedArtifactBeforeInstallAndMarksInstalledBeforeLaunch() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let receiptRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-standard-receipt-\(UUID().uuidString)",
                isDirectory: true
            )
        let receiptStore = HostInstallReceiptStore(rootURL: receiptRootURL)
        let events = LockedValue<[String]>([])
        let expiry = Date(timeIntervalSince1970: 1_820_000_000)
        let application = fixture.verifiedApplication(
            at: fixture.workspaceURL
                .appendingPathComponent("DerivedData", isDirectory: true)
                .appendingPathComponent(
                    "Build/Products/Debug-iphoneos/Example.app",
                    isDirectory: true
                ),
            expiry: expiry
        )
        let script = DeploymentCommandScript { call in
            events.withValue { $0.append(call.stage.rawValue) }
            if call.stage == .settings {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                events.withValue { $0.append("inspect") }
                return fixture.verifiedApplication(
                    at: request.candidate.applicationURL,
                    expiry: expiry
                )
            },
            recordPreparedReceipt: { request, verified, team, preparedAt in
                events.withValue { $0.append("receipt-prepared") }
                _ = try receiptStore.recordPrepared(
                    deploymentToken: request.deploymentToken,
                    bundleIdentifier: request.bundleIdentifier,
                    deviceIdentifier: request.deviceID,
                    teamIdentifier: team,
                    shortVersion: verified.shortVersion,
                    buildVersion: verified.buildVersion,
                    profileUUID: verified.profileUUID,
                    profileDigest: verified.profileDigest,
                    profileExpirationDate:
                        verified.profileExpirationDate,
                    preparedAt: preparedAt
                )
            },
            markInstalledReceipt: { token, installedAt in
                events.withValue { $0.append("receipt-installed") }
                _ = try receiptStore.markInstalled(
                    deploymentToken: token,
                    installedAt: installedAt
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)
        let loadedReceipt = try receiptStore.load(
            deploymentToken: fixture.deploymentToken
        )
        let receipt = try #require(loadedReceipt)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(result.verifiedProfileExpirationDate == expiry)
        #expect(receipt.status == .installed)
        #expect(receipt.deploymentToken == fixture.deploymentToken)
        #expect(receipt.bundleIdentifier == application.bundleIdentifier)
        #expect(receipt.deviceIdentifier == "device-id")
        #expect(receipt.teamIdentifier == application.profileTeamIdentifier)
        #expect(receipt.shortVersion == application.shortVersion)
        #expect(receipt.buildVersion == application.buildVersion)
        #expect(receipt.profileUUID == application.profileUUID)
        #expect(receipt.profileDigest == application.profileDigest)
        #expect(receipt.profileExpirationDate == expiry)
        #expect(receipt.installedAt != nil)
        #expect(events.value == [
            "settings", "build", "inspect", "receipt-prepared",
            "install", "receipt-installed", "launch"
        ])
    }

    @Test
    func preparedReceiptFailureStopsBeforeInstallAndRollsBackProfileCache() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let profileCache = try ProfileTransactionHarness(profileCount: 1)
        let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(nil)
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                return .result(.success())
            case .install, .launch:
                Issue.record("安装前回执失败后不应修改设备。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                let prepared = try await profileCache.manager
                    .prepareTransaction(
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: teamIdentifier,
                        refreshMode: mode,
                        deploymentToken: token,
                        now: now
                    )
                transaction.withValue { $0 = prepared }
                return prepared
            },
            recordPreparedReceipt: { _, _, _, _ in
                throw StandardDeploymentTestError.receiptWriteFailed
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)
        let prepared = try #require(transaction.value)

        #expect(result.commandResult.terminationStatus != 0)
        #expect(result.verifiedProfileExpirationDate == nil)
        #expect(result.profileCacheRecoveryWasConfirmed)
        #expect(prepared.state == .rolledBack)
        #expect(script.recordedCalls.map(\.stage) == [.settings, .build])
        #expect(
            result.commandResult.standardError.contains(
                "无法持久化安装前宿主回执"
            )
        )
    }

    @Test
    func installedReceiptFailureKeepsVerifiedInstallSuccessAndWarning() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let expiry = Date(timeIntervalSince1970: 1_825_000_000)
        let preparedWrites = LockedValue(0)
        let installedWrites = LockedValue(0)
        let script = DeploymentCommandScript { call in
            if call.stage == .settings {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL,
                    expiry: expiry
                )
            },
            recordPreparedReceipt: { _, _, _, _ in
                preparedWrites.withValue { $0 += 1 }
            },
            markInstalledReceipt: { _, _ in
                installedWrites.withValue { $0 += 1 }
                throw StandardDeploymentTestError.receiptWriteFailed
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(result.verifiedProfileExpirationDate == expiry)
        #expect(result.profileCacheRecoveryWasConfirmed)
        #expect(preparedWrites.value == 1)
        #expect(installedWrites.value == 1)
        #expect(script.recordedCalls.map(\.stage) == [
            .settings, .build, .install, .launch
        ])
        #expect(
            result.commandResult.standardError.contains(
                "宿主安装回执未能标记为已安装"
            )
        )
    }

    @Test
    func cumulativeTranscriptIsBoundedWithoutSuppressingLiveOutput() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let liveByteCounts = LockedValue((standardOutput: 0, standardError: 0))
        let largeOutput = "BUILD_HEAD" + String(
            repeating: "B",
            count: 5 * 1_024 * 1_024
        )
        let largeInstallOutput = String(
            repeating: "I",
            count: 5 * 1_024 * 1_024
        ) + "INSTALL_TAIL"
        let largeError = "SETTINGS_ERROR_HEAD" + String(
            repeating: "E",
            count: 5 * 1_024 * 1_024
        )
        let largeInstallError = String(
            repeating: "R",
            count: 5 * 1_024 * 1_024
        ) + "INSTALL_ERROR_TAIL"
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                let settings = try fixture.buildSettingsResult(for: call)
                return .result(CommandResult(
                    standardOutput: settings.standardOutput,
                    standardError: largeError,
                    terminationStatus: 0
                ))
            case .build:
                return .result(CommandResult(
                    standardOutput: largeOutput,
                    standardError: "",
                    terminationStatus: 0
                ))
            case .install:
                return .result(CommandResult(
                    standardOutput: largeInstallOutput,
                    standardError: largeInstallError,
                    terminationStatus: 0
                ))
            case .launch:
                return .result(.success(output: "LAUNCH_TAIL"))
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(),
            onOutput: { output, isError in
                liveByteCounts.withValue {
                    if isError {
                        $0.standardError += output.utf8.count
                    } else {
                        $0.standardOutput += output.utf8.count
                    }
                }
            }
        )
        let result = await waitForDeploymentExecution(execution).commandResult

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputWasTruncated)
        #expect(result.standardErrorWasTruncated)
        #expect(result.standardOutput.utf8.count <= 8 * 1_024 * 1_024)
        #expect(result.standardError.utf8.count <= 8 * 1_024 * 1_024)
        #expect(result.standardOutput.contains("BUILD_HEAD"))
        #expect(result.standardOutput.contains("LAUNCH_TAIL"))
        #expect(result.standardError.contains("SETTINGS_ERROR_HEAD"))
        #expect(result.standardError.contains("INSTALL_ERROR_TAIL"))
        #expect(liveByteCounts.value.standardOutput > 10 * 1_024 * 1_024)
        #expect(liveByteCounts.value.standardError > 10 * 1_024 * 1_024)
    }

    @Test
    func cancellationStopsCurrentStageAndConfirmsSettlement() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let waitStarted = TestEventRecorder<Void>()
        let blockingCommand = BlockingDeploymentStageCommand(
            processGroupIdentifier: 314,
            onWaitStarted: { waitStarted.record(()) }
        )
        let script = DeploymentCommandScript { call in
            #expect(call.stage == .settings)
            return .command(blockingCommand)
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                throw StandardDeploymentTestError.unexpectedInspection
            }
        )
        let execution = try executor.start(
            request: fixture.request(),
            onOutput: nil
        )

        #expect(execution.processGroupIdentifier == 314)
        _ = try await waitForTestEvent(waitStarted)
        #expect(
            await cancelAndWaitForDeploymentExecution(
                execution,
                timeoutSeconds: 1
            )
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(blockingCommand.cancelCount == 1)
        #expect(result.commandResult.terminationStatus == 130)
        #expect(result.commandResult.processGroupTerminationWasConfirmed)
        #expect(script.recordedCalls.map(\.stage) == [.settings])
    }

    @Test
    func profileCacheTransactionRollsBackOnBuildInspectionAndInstallFailure() async throws {
        for failureStage in ProfileTransactionFailureStage.allCases {
            let fixture = try StandardDeploymentFixture(kind: .project)
            let profileCache = try ProfileTransactionHarness()
            let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(nil)
            let script = DeploymentCommandScript { call in
                switch call.stage {
                case .settings:
                    return .result(try fixture.buildSettingsResult(for: call))
                case .build:
                    return .result(
                        failureStage == .build
                            ? .failure(status: 65, error: "build failed")
                            : .success()
                    )
                case .install:
                    return .result(
                        failureStage == .install
                            ? .failure(status: 1, error: "install failed")
                            : .success()
                    )
                case .launch:
                    Issue.record(
                        "事务失败后不应进入 launch：\(failureStage)"
                    )
                    return .result(.success())
                }
            }
            let executor = fixture.makeExecutor(
                script: script,
                inspectApplication: { request in
                    if failureStage == .inspection {
                        throw SignedIOSAppInspectionError.applicationUnavailable
                    }
                    return fixture.verifiedApplication(
                        at: request.candidate.applicationURL
                    )
                },
                prepareProfileCache: {
                    bundleIdentifier, teamIdentifier, mode, token, now in
                    let prepared = try await profileCache.manager
                        .prepareTransaction(
                            bundleIdentifier: bundleIdentifier,
                            expectedTeamIdentifier: teamIdentifier,
                            refreshMode: mode,
                            deploymentToken: token,
                            now: now
                        )
                    transaction.withValue { $0 = prepared }
                    return prepared
                }
            )

            let execution = try executor.start(
                request: fixture.request(profileRefreshMode: .force),
                onOutput: nil
            )
            let result = await waitForDeploymentExecution(execution)
            guard let prepared = transaction.value else {
                Issue.record(
                    "profile cache 未准备成功：\(result.commandResult.standardError) moves=\(String(describing: profileCache.moveCalls.value)) manifests=\(String(describing: profileCache.manifestWriteURLs.value))"
                )
                continue
            }

            #expect(result.commandResult.terminationStatus != 0)
            #expect(prepared.state == .rolledBack)
            #expect(profileCache.originalProfileURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
            #expect(result.verifiedProfileExpirationDate == nil)
        }
    }

    @Test
    func incompleteProfileCacheRollbackIsReportedSeparatelyFromProcessTermination() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let profileCache = try ProfileTransactionHarness()
        let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(nil)
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                return .result(.failure(status: 65, error: "build failed"))
            case .install, .launch:
                Issue.record("构建失败后不应继续安装。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                throw StandardDeploymentTestError.unexpectedInspection
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                let prepared = try await profileCache.manager
                    .prepareTransaction(
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: teamIdentifier,
                        refreshMode: mode,
                        deploymentToken: token,
                        now: now
                    )
                transaction.withValue { $0 = prepared }
                let conflictingOriginal = try #require(
                    prepared.backups.first?.originalURL
                )
                try Data("unexpected replacement".utf8).write(
                    to: conflictingOriginal
                )
                return prepared
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus != 0)
        #expect(result.commandResult.processGroupTerminationWasConfirmed)
        #expect(!result.profileCacheRecoveryWasConfirmed)
        #expect(transaction.value?.state == .active)
        #expect(
            result.commandResult.standardError.contains(
                "无法完整恢复 provisioning profile 缓存"
            )
        )
    }

    @Test
    func profilePreparationWithIncompleteRollbackBlocksCacheRecovery() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let script = DeploymentCommandScript { call in
            if call.stage == .settings {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            Issue.record("缓存准备回滚不完整后不应开始构建。")
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                throw StandardDeploymentTestError.unexpectedInspection
            },
            prepareProfileCache: { _, _, _, _, _ in
                throw ProvisioningProfileCacheError.preparationFailed(
                    reason: "second move failed",
                    rollbackFailures: ["first profile restore failed"]
                )
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus != 0)
        #expect(result.commandResult.processGroupTerminationWasConfirmed)
        #expect(!result.profileCacheRecoveryWasConfirmed)
        #expect(script.recordedCalls.map(\.stage) == [.settings])
        #expect(
            result.commandResult.standardError.contains(
                "first profile restore failed"
            )
        )
    }

    @Test
    func cancellationDuringBuildRollsBackProfileCacheTransaction() async throws {
        let fixture = try StandardDeploymentFixture(kind: .project)
        let profileCache = try ProfileTransactionHarness()
        let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(nil)
        let buildStarted = TestEventRecorder<Void>()
        let blockingBuild = BlockingDeploymentStageCommand(
            processGroupIdentifier: 515,
            onWaitStarted: { buildStarted.record(()) }
        )
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build:
                return .command(blockingBuild)
            case .install, .launch:
                Issue.record("取消构建后不应继续安装或启动。")
                return .result(.success())
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { _ in
                throw StandardDeploymentTestError.unexpectedInspection
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                let prepared = try await profileCache.manager
                    .prepareTransaction(
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: teamIdentifier,
                        refreshMode: mode,
                        deploymentToken: token,
                        now: now
                    )
                transaction.withValue { $0 = prepared }
                return prepared
            }
        )
        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )

        _ = try await waitForTestEvent(buildStarted)
        #expect(
            await cancelAndWaitForDeploymentExecution(
                execution,
                timeoutSeconds: 2
            )
        )
        let result = await waitForDeploymentExecution(execution)
        let prepared = try #require(transaction.value)

        #expect(result.commandResult.terminationStatus == 130)
        #expect(prepared.state == .rolledBack)
        #expect(profileCache.originalProfileURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(blockingBuild.cancelCount == 1)
    }

    @Test
    func successfulInstallCommitsProfileCacheAndPassesAllPreviousDigestsToInspector() async throws {
        let fixture = try StandardDeploymentFixture(kind: .workspace)
        let profileCache = try ProfileTransactionHarness()
        let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(nil)
        let inspectionRequests = LockedValue<[SignedIOSAppInspectionRequest]>([])
        let expiry = Date(timeIntervalSince1970: 1_830_000_000)
        let script = DeploymentCommandScript { call in
            switch call.stage {
            case .settings:
                return .result(try fixture.buildSettingsResult(for: call))
            case .build, .install:
                return .result(.success())
            case .launch:
                return .result(.failure(status: 1, error: "device locked"))
            }
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                inspectionRequests.withValue { $0.append(request) }
                return fixture.verifiedApplication(
                    at: request.candidate.applicationURL,
                    expiry: expiry
                )
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                let prepared = try await profileCache.manager
                    .prepareTransaction(
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: teamIdentifier,
                        refreshMode: mode,
                        deploymentToken: token,
                        now: now
                    )
                transaction.withValue { $0 = prepared }
                return prepared
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)
        let prepared = try #require(transaction.value)
        let inspection = try #require(inspectionRequests.value.first)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(result.verifiedProfileExpirationDate == expiry)
        #expect(prepared.state == .committed)
        #expect(prepared.previousProfileDigests.count == 2)
        #expect(
            inspection.previousProfileDigests
                == prepared.previousProfileDigests
        )
        #expect(profileCache.originalProfileURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(script.recordedCalls.map(\.stage) == [
            .settings, .build, .install, .launch
        ])
    }

    @Test(arguments: [true, false])
    func commitFailureKeepsInstalledOutcomeAndReportsWhetherCacheWasRecovered(
        rollbackSucceeds: Bool
    ) async throws {
        let manifestWriter = FailingManifestWriter(
            failingWriteNumbers: rollbackSucceeds ? [5] : [5, 6]
        )
        let profileCache = try ProfileTransactionHarness(
            profileCount: 1,
            manifestWriter: manifestWriter.write
        )
        let fixture = try StandardDeploymentFixture(kind: .project)
        let transaction = LockedValue<ProvisioningProfileCacheTransaction?>(nil)
        let expiry = Date(timeIntervalSince1970: 1_840_000_000)
        let script = DeploymentCommandScript { call in
            if call.stage == .settings {
                return .result(try fixture.buildSettingsResult(for: call))
            }
            return .result(.success())
        }
        let executor = fixture.makeExecutor(
            script: script,
            inspectApplication: { request in
                fixture.verifiedApplication(
                    at: request.candidate.applicationURL,
                    expiry: expiry
                )
            },
            prepareProfileCache: {
                bundleIdentifier, teamIdentifier, mode, token, now in
                let prepared = try await profileCache.manager
                    .prepareTransaction(
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: teamIdentifier,
                        refreshMode: mode,
                        deploymentToken: token,
                        now: now
                    )
                transaction.withValue { $0 = prepared }
                return prepared
            }
        )

        let execution = try executor.start(
            request: fixture.request(profileRefreshMode: .force),
            onOutput: nil
        )
        let result = await waitForDeploymentExecution(execution)

        #expect(result.commandResult.terminationStatus == 0)
        #expect(result.verifiedProfileExpirationDate == expiry)
        #expect(
            result.profileCacheRecoveryWasConfirmed == rollbackSucceeds
        )
        #expect(
            transaction.value?.state
                == (rollbackSucceeds ? .rolledBack : .active)
        )
        #expect(
            result.commandResult.standardError.contains(
                "App 已安装，但无法提交 provisioning profile 缓存事务"
            )
        )
        if rollbackSucceeds {
            #expect(profileCache.originalProfileURLs.allSatisfy {
                FileManager.default.fileExists(atPath: $0.path)
            })
        } else {
            #expect(
                result.commandResult.standardError.contains(
                    "provisioning profile 缓存未完成恢复"
                )
            )
        }
    }
}

private func waitForDeploymentExecution(
    _ execution: any DeploymentExecution
) async -> DeploymentExecutionResult {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(
                returning: execution.waitUntilExit()
            )
        }
    }
}

private func cancelAndWaitForDeploymentExecution(
    _ execution: any DeploymentExecution,
    timeoutSeconds: TimeInterval
) async -> Bool {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(
                returning: execution.cancelAndWaitForTermination(
                    timeoutSeconds: timeoutSeconds
                )
            )
        }
    }
}

private func waitForTestEvent<Event: Sendable>(
    _ recorder: TestEventRecorder<Event>,
    timeout: Duration = .seconds(10)
) async throws -> Event {
    try await withThrowingTaskGroup(of: Event.self) { group in
        group.addTask {
            try await recorder.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw StandardDeploymentTestError.eventWaitTimedOut
        }
        defer { group.cancelAll() }
        guard let event = try await group.next() else {
            throw StandardDeploymentTestError.eventWaitTimedOut
        }
        return event
    }
}

private enum ProfileTransactionFailureStage: CaseIterable, Sendable {
    case build
    case inspection
    case install
}

enum UnconfirmedInternalCommandStage: Sendable {
    case profilePreparation
    case artifactInspection
}

enum UnconfirmedExternalCommandStage: Sendable {
    case build
    case install
}

private enum BuildSettingsMismatch: CaseIterable, Sendable {
    case target
    case bundleIdentifier
    case productType
    case sdk
    case productName
    case missingCodeSignStyle
    case manualCodeSignStyle
    case missingDevelopmentTeam
    case unsafeDevelopmentTeam
    case outsideDerivedData
    case multipleProducts
}

private enum DeploymentCommandStage: String, Equatable, Sendable {
    case settings
    case build
    case install
    case launch
}

private struct DeploymentCommandCall: Equatable, Sendable {
    let launchPath: String
    let arguments: [String]
    let currentDirectoryPath: String?
    let environment: [String: String]

    var stage: DeploymentCommandStage {
        if arguments.contains("-showBuildSettings") {
            return .settings
        }
        if launchPath == "/usr/bin/xcodebuild" {
            return .build
        }
        if arguments.contains("install") {
            return .install
        }
        return .launch
    }
}

private struct DeploymentStageWait: Equatable, Sendable {
    let stage: DeploymentCommandStage
    let timeoutSeconds: TimeInterval?
}

private enum DeploymentCommandBehavior {
    case result(CommandResult)
    case command(any DeploymentStageCommand)
}

private final class DeploymentCommandScript: @unchecked Sendable {
    typealias Handler = @Sendable (
        DeploymentCommandCall
    ) throws -> DeploymentCommandBehavior

    private let lock = NSLock()
    private let handler: Handler
    private var calls: [DeploymentCommandCall] = []
    private var nextProcessGroupIdentifier: Int32 = 1_000

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var recordedCalls: [DeploymentCommandCall] {
        lock.withLock { calls }
    }

    func start(
        _ launchPath: String,
        _ arguments: [String],
        _ currentDirectoryPath: String?,
        _ environment: [String: String],
        _ onOutput: (@Sendable (String, Bool) -> Void)?
    ) throws -> any DeploymentStageCommand {
        let call = DeploymentCommandCall(
            launchPath: launchPath,
            arguments: arguments,
            currentDirectoryPath: currentDirectoryPath,
            environment: environment
        )
        let processGroupIdentifier = lock.withLock {
            calls.append(call)
            defer { nextProcessGroupIdentifier += 1 }
            return nextProcessGroupIdentifier
        }
        switch try handler(call) {
        case .result(let result):
            onOutput?(result.standardOutput, false)
            onOutput?(result.standardError, true)
            return ImmediateDeploymentStageCommand(
                processGroupIdentifier: processGroupIdentifier,
                result: result
            )
        case .command(let command):
            return command
        }
    }
}

private final class ImmediateDeploymentStageCommand:
    DeploymentStageCommand,
    @unchecked Sendable {
    let processGroupIdentifier: Int32
    private let result: CommandResult

    init(processGroupIdentifier: Int32, result: CommandResult) {
        self.processGroupIdentifier = processGroupIdentifier
        self.result = result
    }

    func cancel() {}

    func waitUntilExit(timeoutSeconds: TimeInterval?) -> CommandResult {
        result
    }
}

private final class TimeoutRecordingDeploymentStageCommand:
    DeploymentStageCommand,
    @unchecked Sendable {
    let processGroupIdentifier: Int32
    private let result: CommandResult
    private let onWait: @Sendable (TimeInterval?) -> Void

    init(
        processGroupIdentifier: Int32,
        result: CommandResult,
        onWait: @escaping @Sendable (TimeInterval?) -> Void
    ) {
        self.processGroupIdentifier = processGroupIdentifier
        self.result = result
        self.onWait = onWait
    }

    func cancel() {}

    func waitUntilExit(timeoutSeconds: TimeInterval?) -> CommandResult {
        onWait(timeoutSeconds)
        return result
    }
}

private final class BlockingDeploymentStageCommand:
    DeploymentStageCommand,
    @unchecked Sendable {
    let processGroupIdentifier: Int32
    private let condition = NSCondition()
    private let onWaitStarted: @Sendable () -> Void
    private var wasCancelled = false
    private var cancellations = 0

    init(
        processGroupIdentifier: Int32,
        onWaitStarted: @escaping @Sendable () -> Void = {}
    ) {
        self.processGroupIdentifier = processGroupIdentifier
        self.onWaitStarted = onWaitStarted
    }

    var cancelCount: Int {
        condition.withLock { cancellations }
    }

    func cancel() {
        condition.withLock {
            cancellations += 1
            wasCancelled = true
            condition.broadcast()
        }
    }

    func waitUntilExit(timeoutSeconds: TimeInterval?) -> CommandResult {
        onWaitStarted()
        condition.lock()
        while !wasCancelled {
            condition.wait()
        }
        condition.unlock()
        return CommandResult(
            standardOutput: "",
            standardError: "cancelled",
            terminationStatus: 130
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    @discardableResult
    func withValue<Result>(
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result {
        try lock.withLock {
            try body(&storedValue)
        }
    }
}

private final class FailingManifestWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let failingWriteNumbers: Set<Int>
    private var writeCount = 0

    init(failingWriteNumbers: Set<Int>) {
        self.failingWriteNumbers = failingWriteNumbers
    }

    func write(_ data: Data, _ url: URL) throws {
        let shouldFail = lock.withLock {
            writeCount += 1
            return failingWriteNumbers.contains(writeCount)
        }
        if shouldFail {
            throw StandardDeploymentTestError.manifestWriteFailed
        }
        try data.write(to: url, options: .atomic)
    }
}

private struct StandardDeploymentFixture: Sendable {
    let rootURL: URL
    let containerURL: URL
    let container: XcodeContainer
    let workspaceURL: URL
    let deploymentToken: String

    init(kind: XcodeContainer.Kind) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-standard-deploy-\(UUID().uuidString)",
                isDirectory: true
            )
        let extensionName = kind == .project ? "xcodeproj" : "xcworkspace"
        containerURL = rootURL.appendingPathComponent(
            "Example.\(extensionName)",
            isDirectory: true
        )
        workspaceURL = rootURL.appendingPathComponent(
            "DeploymentWorkspace",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        container = try #require(XcodeContainer(path: containerURL.path))
        deploymentToken = DeploymentToken.make().rawValue
    }

    func request(
        container: XcodeContainer? = nil,
        deploymentToken: String? = nil,
        profileRefreshMode: ProvisioningProfileRefreshMode = .automatic
    ) -> StandardIOSDeploymentRequest {
        StandardIOSDeploymentRequest(
            projectRootURL: rootURL,
            container: container ?? self.container,
            scheme: "Example",
            targetName: "Example",
            bundleIdentifier: "com.example.App",
            deviceID: "device-id",
            deviceName: "测试 iPhone",
            deploymentToken: deploymentToken ?? self.deploymentToken,
            profileRefreshMode: profileRefreshMode
        )
    }

    func makeExecutor(
        script: DeploymentCommandScript,
        inspectApplication: @escaping @Sendable (
            SignedIOSAppInspectionRequest
        ) async throws -> VerifiedSignedIOSApp,
        prepareProfileCache: (@Sendable (
            String,
            String,
            ProvisioningProfileRefreshMode,
            String,
            Date
        ) async throws -> ProvisioningProfileCacheTransaction)? = nil,
        recordPreparedReceipt: @escaping
            StandardIOSDeploymentExecutor.RecordPreparedReceipt = {
                _, _, _, _ in
            },
        markInstalledReceipt: @escaping
            StandardIOSDeploymentExecutor.MarkInstalledReceipt = { _, _ in },
        removeWorkspace: @escaping @Sendable (URL) throws -> Void = {
            _ in
        }
    ) -> StandardIOSDeploymentExecutor {
        StandardIOSDeploymentExecutor(
            startCommand: script.start,
            inspectApplication: inspectApplication,
            prepareProfileCache: prepareProfileCache,
            recordPreparedReceipt: recordPreparedReceipt,
            markInstalledReceipt: markInstalledReceipt,
            makeWorkspaceURL: { _ in workspaceURL },
            removeWorkspace: removeWorkspace
        )
    }

    func buildSettingsResult(
        for call: DeploymentCommandCall,
        mismatch: BuildSettingsMismatch? = nil
    ) throws -> CommandResult {
        let derivedDataPath = try #require(
            call.arguments.value(after: "-derivedDataPath")
        )
        var target = "Example"
        var bundleIdentifier = "com.example.App"
        var productType = "com.apple.product-type.application"
        var sdkName = "iphoneos27.0"
        var targetBuildDirectory = URL(fileURLWithPath: derivedDataPath)
            .appendingPathComponent("Build/Products/Debug-iphoneos")
            .path
        var fullProductName = "Example.app"
        var developmentTeam: String? = "TEAM123456"
        var codeSignStyle: String? = "Automatic"

        switch mismatch {
        case .target:
            target = "Other"
        case .bundleIdentifier:
            bundleIdentifier = "com.example.Other"
        case .productType:
            productType = "com.apple.product-type.framework"
        case .sdk:
            sdkName = "iphonesimulator27.0"
        case .productName:
            fullProductName = "../Example.app"
        case .missingCodeSignStyle:
            codeSignStyle = nil
        case .manualCodeSignStyle:
            codeSignStyle = "Manual"
        case .missingDevelopmentTeam:
            developmentTeam = nil
        case .unsafeDevelopmentTeam:
            developmentTeam = "team 123"
        case .outsideDerivedData:
            targetBuildDirectory = rootURL
                .appendingPathComponent("UncontrolledProducts")
                .path
        case .multipleProducts, .none:
            break
        }

        func entry(
            targetBuildDirectory: String,
            fullProductName: String
        ) -> [String: Any] {
            var buildSettings = [
                "PRODUCT_TYPE": productType,
                "PRODUCT_BUNDLE_IDENTIFIER": bundleIdentifier,
                "SDK_NAME": sdkName,
                "TARGET_BUILD_DIR": targetBuildDirectory,
                "FULL_PRODUCT_NAME": fullProductName
            ]
            buildSettings["DEVELOPMENT_TEAM"] = developmentTeam
            buildSettings["CODE_SIGN_STYLE"] = codeSignStyle
            return [
                "target": target,
                "buildSettings": buildSettings
            ]
        }

        var entries = [entry(
            targetBuildDirectory: targetBuildDirectory,
            fullProductName: fullProductName
        )]
        if mismatch == .multipleProducts {
            entries.append(entry(
                targetBuildDirectory: URL(fileURLWithPath: derivedDataPath)
                    .appendingPathComponent("Build/Products/Release-iphoneos")
                    .path,
                fullProductName: "Example.app"
            ))
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        return CommandResult(
            standardOutput: String(decoding: data, as: UTF8.self),
            standardError: "",
            terminationStatus: 0
        )
    }

    func verifiedApplication(
        at applicationURL: URL,
        expiry: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> VerifiedSignedIOSApp {
        VerifiedSignedIOSApp(
            applicationURL: applicationURL,
            bundleIdentifier: "com.example.App",
            shortVersion: "1.0",
            buildVersion: "1",
            profileUUID: "3D4C69C7-798A-43FB-A7BB-A7E2DD80F5AB",
            profileExpirationDate: expiry,
            profileTeamIdentifier: "TEAM123456",
            profileDigest: String(repeating: "d", count: 64)
        )
    }
}

private struct ProfileTransactionHarness: Sendable {
    let manager: ProvisioningProfileCacheManager
    let originalProfileURLs: [URL]
    let moveCalls: LockedValue<[(source: String, destination: String)]>
    let manifestWriteURLs: LockedValue<[String]>

    init(
        profileCount: Int = 2,
        manifestWriter: @escaping ProvisioningProfileCacheManager
            .ManifestWriter = { data, url in
                try data.write(to: url, options: .atomic)
            }
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "ios-sign-kit-profile-transaction-contract-\(UUID().uuidString)",
                isDirectory: true
            )
        let xcodeDirectoryURL = rootURL
            .appendingPathComponent("XcodeProfiles", isDirectory: true)
        let mobileDeviceDirectoryURL = rootURL
            .appendingPathComponent("MobileDeviceProfiles", isDirectory: true)
        let backupRootURL = rootURL
            .appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: xcodeDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: mobileDeviceDirectoryURL,
            withIntermediateDirectories: true
        )

        let firstURL = xcodeDirectoryURL
            .appendingPathComponent("first.mobileprovision")
        var profileURLs = [firstURL]
        try Data("first-profile-cache-entry".utf8).write(to: firstURL)
        if profileCount > 1 {
            let secondURL = mobileDeviceDirectoryURL
                .appendingPathComponent("second.mobileprovision")
            try Data("second-profile-cache-entry".utf8).write(to: secondURL)
            profileURLs.append(secondURL)
        }
        originalProfileURLs = profileURLs
        let recordedMoves = LockedValue<[(source: String, destination: String)]>([])
        let recordedManifestURLs = LockedValue<[String]>([])
        moveCalls = recordedMoves
        manifestWriteURLs = recordedManifestURLs

        let decodedProfile = try PropertyListSerialization.data(
            fromPropertyList: [
                "Entitlements": [
                    "application-identifier": "TEAM123456.com.example.App"
                ],
                "ExpirationDate": Date(timeIntervalSince1970: 1_900_000_000)
            ],
            format: .xml,
            options: 0
        )
        manager = ProvisioningProfileCacheManager(
            directories: ProvisioningProfileCacheDirectories(
                xcodeUserDataURL: xcodeDirectoryURL,
                mobileDeviceURL: mobileDeviceDirectoryURL
            ),
            backupRootURL: backupRootURL,
            decodeProvisioningProfile: { _, _ in decodedProfile },
            moveItem: { sourceURL, destinationURL in
                recordedMoves.withValue {
                    $0.append((sourceURL.path, destinationURL.path))
                }
                try FileManager.default.moveItem(
                    at: sourceURL,
                    to: destinationURL
                )
            },
            manifestWriter: { data, url in
                recordedManifestURLs.withValue { $0.append(url.path) }
                try manifestWriter(data, url)
            }
        )
    }
}

private enum StandardDeploymentTestError: Error {
    case unexpectedInspection
    case unexpectedProfileCachePreparation
    case manifestWriteFailed
    case receiptWriteFailed
    case workspaceCleanupFailed
    case eventWaitTimedOut
}

private extension SignedIOSAppCandidate {
    var applicationURL: URL {
        switch self {
        case .application(let url), .productsDirectory(let url):
            return url
        }
    }
}

private extension Array where Element == String {
    func value(after marker: String) -> String? {
        guard let index = firstIndex(of: marker),
              indices.contains(index + 1) else {
            return nil
        }
        return self[index + 1]
    }
}

private extension CommandResult {
    static func success(output: String = "") -> CommandResult {
        CommandResult(
            standardOutput: output,
            standardError: "",
            terminationStatus: 0
        )
    }

    static func failure(
        status: Int32,
        error: String,
        processGroupTerminationWasConfirmed: Bool = true
    ) -> CommandResult {
        CommandResult(
            standardOutput: "",
            standardError: error,
            terminationStatus: status,
            processGroupTerminationWasConfirmed:
                processGroupTerminationWasConfirmed
        )
    }
}
