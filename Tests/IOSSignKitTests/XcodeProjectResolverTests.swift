import Foundation
import Testing
@testable import IOSSignKit

struct XcodeProjectResolverTests {
    @Test
    func resolvesAndValidatesIPhoneTargetThroughSchemeWithoutDestination() async throws {
        let root = try makeProjectRoot(named: "Offline")
        let projectPath =
            root.appendingPathComponent("Offline.xcodeproj").path
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(
                    stdout: projectListJSON(
                        schemes: ["Offline"],
                        targets: ["OfflineApp"]
                    )
                )
            }

            #expect(value(after: "-scheme", in: arguments) == "Offline")
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: buildSettingsJSON(
                target: "OfflineApp",
                bundleID: "com.example.offline"
            ))
        }
        let resolver = XcodeProjectResolver(runCommand: runner.run)

        let resolution = await resolver.resolve(
            projectRootPath: root.path
        )
        let config = AppConfig(
            projectRootPath: root.path,
            deployScriptPath:
                root.appendingPathComponent(
                    "scripts/deploy/ios-device.command"
                ).path,
            xcodeprojPath: projectPath,
            scheme: "Offline",
            targetName: "OfflineApp",
            bundleID: "com.example.offline",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )

        #expect(resolution.candidates == [
            XcodeProjectCandidate(
                projectPath: projectPath,
                scheme: "Offline",
                targetName: "OfflineApp",
                bundleID: "com.example.offline"
            )
        ])
        #expect(
            await resolver.validateSelectedTarget(config: config).isValid
        )
    }

    @Test
    func exposesOnlyApplicationTargetsReportedByEachScheme()
        async throws {
        let root = try makeProjectRoot(named: "Container")
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(
                    stdout: projectListJSON(
                        schemes: ["Consumer", "Internal"],
                        targets: ["ConsumerApp", "InternalApp"]
                    )
                )
            }
            let scheme = value(after: "-scheme", in: arguments) ?? ""
            let target = scheme == "Consumer"
                ? "ConsumerApp"
                : "InternalApp"
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: buildSettingsJSON(
                target: target,
                bundleID: "com.example.\(target.lowercased())"
            ))
        }

        let resolution = await XcodeProjectResolver(
            runCommand: runner.run
        ).resolve(projectRootPath: root.path)

        #expect(
            resolution.candidates.map {
                "\($0.scheme)|\($0.targetName)"
            } == [
                "Consumer|ConsumerApp",
                "Internal|InternalApp"
            ]
        )
        #expect(
            resolution.diagnosticMessage?
                .contains("明确选择") == true
        )
    }

    @Test
    func mixedWorkspaceKeepsIOSCandidateWhenMacOnlySchemeRejectsIPhoneSDK()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-mixed-workspace-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
                "Shared.xcworkspace",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(
                    stdout: workspaceListJSON(
                        schemes: ["iOSApp", "MacTool"],
                        targets: ["iOSApp", "MacTool"]
                    )
                )
            }
            let scheme = value(after: "-scheme", in: arguments)
            if scheme == "iOSApp" {
                return .success(
                    stdout: buildSettingsJSON(
                        target: "iOSApp",
                        bundleID: "com.example.ios"
                    )
                )
            }
            if arguments.contains("-sdk") {
                return CommandResult(
                    standardOutput: "",
                    standardError:
                        "MacTool does not support the iphoneos SDK.",
                    terminationStatus: 65
                )
            }
            return .success(stdout: """
            [{
              "target":"MacTool",
              "buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"macosx",
                "SDKROOT":"macosx",
                "SUPPORTED_PLATFORMS":"macosx",
                "PRODUCT_BUNDLE_IDENTIFIER":"com.example.mac"
              }
            }]
            """)
        }

        let resolution = await XcodeProjectResolver(
            runCommand: runner.run
        ).resolve(projectRootPath: root.path)

        #expect(resolution.isComplete)
        #expect(resolution.diagnosticMessage == nil)
        #expect(resolution.candidates.map(\.scheme) == ["iOSApp"])
        #expect(
            resolution.candidates.first?.container.kind == .workspace
        )
    }

    @Test
    func rejectsTargetThatIsNotReportedBySelectedScheme() async throws {
        let root = try makeProjectRoot(named: "Mapped")
        let projectPath = root
            .appendingPathComponent("Mapped.xcodeproj")
            .path
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(stdout: projectListJSON(
                    schemes: ["Consumer", "Internal"],
                    targets: ["ConsumerApp", "InternalApp"]
                ))
            }
            let scheme = value(after: "-scheme", in: arguments) ?? ""
            let target = scheme == "Consumer"
                ? "ConsumerApp"
                : "InternalApp"
            return .success(stdout: buildSettingsJSON(
                target: target,
                bundleID: "com.example.\(target.lowercased())"
            ))
        }
        var config = AppConfig.default
        config.projectRootPath = root.path
        config.deployScriptPath = root
            .appendingPathComponent("scripts/deploy/ios-device.command")
            .path
        config.xcodeprojPath = projectPath
        config.scheme = "Consumer"
        config.targetName = "InternalApp"
        config.bundleID = "com.example.internalapp"

        let validation = await XcodeProjectResolver(
            runCommand: runner.run
        ).validateSelectedTarget(config: config)

        #expect(!validation.isValid)
        #expect(validation.diagnosticMessage?.contains("不再匹配") == true)
    }

    @Test
    func candidateSelectionLabelsDistinguishProjectAndTarget() {
        let first = XcodeProjectCandidate(
            projectPath: "/workspace/Client/App.xcodeproj",
            scheme: "App",
            targetName: "ClientApp",
            bundleID: "com.example.app"
        )
        let second = XcodeProjectCandidate(
            projectPath: "/workspace/Admin/App.xcodeproj",
            scheme: "App",
            targetName: "AdminApp",
            bundleID: "com.example.app"
        )

        #expect(first.selectionDisplayName != second.selectionDisplayName)
        #expect(first.selectionDisplayName.contains(first.projectPath))
        #expect(first.selectionDisplayName.contains(first.targetName))
        #expect(second.selectionDisplayName.contains(second.projectPath))
        #expect(second.selectionDisplayName.contains(second.targetName))
    }

    @Test
    func resolvesApplicationBundleIDFromBuildSettings() async throws {
        let root = try makeProjectRoot(named: "Example")
        let argumentsRecorder = XcodeResolverArgumentsRecorder()
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(stdout: projectListJSON(
                    schemes: ["Example"],
                    targets: ["Example"]
                ))
            }
            argumentsRecorder.record(arguments)
            return .success(stdout: buildSettingsJSON(
                target: "Example",
                bundleID: "com.example.app"
            ))
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates.count == 1)
        #expect(resolution.candidates.first?.scheme == "Example")
        #expect(resolution.candidates.first?.bundleID == "com.example.app")
        #expect(
            value(after: "-scheme", in: argumentsRecorder.arguments)
                == "Example"
        )
        #expect(
            value(after: "-sdk", in: argumentsRecorder.arguments)
                == "iphoneos"
        )
        #expect(!argumentsRecorder.arguments.contains("-target"))
        #expect(
            !argumentsRecorder.arguments.contains("-destination")
        )
    }

    @Test
    func rejectsMacOSSettingsThatOnlyDeclareIPhoneOSAsSupported() async throws {
        let root = try makeProjectRoot(named: "Multiplatform")
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(
                    stdout: projectListJSON(
                        schemes: ["Multiplatform"],
                        targets: ["Multiplatform"]
                    )
                )
            }
            #expect(
                value(after: "-scheme", in: arguments)
                    == "Multiplatform"
            )
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: """
            [{
              "target":"Multiplatform",
              "buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"macosx",
                "SDKROOT":"macosx",
                "SUPPORTED_PLATFORMS":"iphoneos macosx",
                "PRODUCT_BUNDLE_IDENTIFIER":"com.example.mac"
              }
            }]
            """)
        }

        let resolution = await XcodeProjectResolver(
            runCommand: runner.run
        ).resolve(projectRootPath: root.path)

        #expect(resolution.candidates.isEmpty)
        #expect(
            resolution.diagnosticMessage?
                .contains("可续签的 iOS App 目标") == true
        )
    }

    @Test
    func returnsAllApplicationCandidatesInsteadOfGuessing() async throws {
        let root = try makeProjectRoot(named: "Container")
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(stdout: projectListJSON(
                    schemes: ["Container"],
                    targets: ["Consumer", "Internal"]
                ))
            }
            #expect(value(after: "-scheme", in: arguments) == "Container")
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: """
            [
              {"target":"Consumer","buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"iphoneos",
                "PRODUCT_BUNDLE_IDENTIFIER":"com.example.consumer"
              }},
              {"target":"Internal","buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"iphoneos",
                "PRODUCT_BUNDLE_IDENTIFIER":"com.example.internal"
              }}
            ]
            """)
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(
            resolution.candidates.map(\.targetName)
                == ["Consumer", "Internal"]
        )
        #expect(
            resolution.candidates.map(\.scheme)
                == ["Container", "Container"]
        )
        #expect(
            resolution.diagnosticMessage?
                .contains("明确选择") == true
        )
    }

    @Test
    func validatesExactTargetWhenSchemeAndBundleIDAmbiguous()
        async throws {
        let root = try makeProjectRoot(named: "Shared")
        let projectPath =
            root.appendingPathComponent("Shared.xcodeproj").path
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(
                    stdout: projectListJSON(
                        schemes: ["Shared"],
                        targets: ["ConsumerApp", "InternalApp"]
                    )
                )
            }
            #expect(value(after: "-scheme", in: arguments) == "Shared")
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: """
            [
              {"target":"ConsumerApp","buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"iphoneos",
                "PRODUCT_BUNDLE_IDENTIFIER":"com.example.shared"
              }},
              {"target":"InternalApp","buildSettings":{
                "PRODUCT_TYPE":"com.apple.product-type.application",
                "PLATFORM_NAME":"iphoneos",
                "PRODUCT_BUNDLE_IDENTIFIER":"com.example.shared"
              }}
            ]
            """)
        }
        let resolver = XcodeProjectResolver(runCommand: runner.run)
        let resolution = await resolver.resolve(
            projectRootPath: root.path
        )
        #expect(
            resolution.candidates.map(\.targetName)
                == ["ConsumerApp", "InternalApp"]
        )

        var config = AppConfig(
            projectRootPath: root.path,
            deployScriptPath:
                root.appendingPathComponent(
                    "scripts/deploy/ios-device.command"
                ).path,
            xcodeprojPath: projectPath,
            scheme: "Shared",
            targetName: "InternalApp",
            bundleID: "com.example.shared",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        #expect(
            await resolver.validateSelectedTarget(config: config)
                .isValid
        )

        config.bundleID = "com.example.changed"
        let bundleMismatch = await resolver.validateSelectedTarget(
            config: config
        )
        #expect(!bundleMismatch.isValid)
        #expect(
            bundleMismatch.diagnosticMessage?
                .contains("Bundle ID") == true
        )

        config.bundleID = "com.example.shared"
        config.targetName = "MissingApp"
        let invalid = await resolver.validateSelectedTarget(
            config: config
        )
        #expect(!invalid.isValid)
        #expect(
            invalid.diagnosticMessage?
                .contains("App Target") == true
        )
    }

    @Test
    func rejectsSavedSchemeThatNoLongerExistsWithoutInspectingTarget()
        async throws {
        let root = try makeProjectRoot(named: "Renamed")
        let projectPath =
            root.appendingPathComponent("Renamed.xcodeproj").path
        let runner = XcodeResolverRunner { arguments in
            guard arguments.contains("-list") else {
                Issue.record(
                    "Scheme 不存在时不应继续查询 Target 构建设置"
                )
                return .success(stdout: "")
            }
            return .success(stdout: projectListJSON(
                schemes: ["Current"],
                targets: ["RenamedApp"]
            ))
        }
        let config = AppConfig(
            projectRootPath: root.path,
            deployScriptPath:
                root.appendingPathComponent(
                    "scripts/deploy/ios-device.command"
                ).path,
            xcodeprojPath: projectPath,
            scheme: "Legacy",
            targetName: "RenamedApp",
            bundleID: "com.example.renamed",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )

        let validation = await XcodeProjectResolver(
            runCommand: runner.run
        ).validateSelectedTarget(config: config)

        #expect(!validation.isValid)
        #expect(
            validation.diagnosticMessage?
                .contains("Scheme") == true
        )
    }

    @Test
    func resolvesCandidatesAcrossMultipleProjects() async throws {
        let root = try makeProjectRoot(named: "Consumer")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Admin.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runner = XcodeResolverRunner { arguments in
            let project = value(after: "-project", in: arguments) ?? ""
            let name = URL(fileURLWithPath: project).deletingPathExtension().lastPathComponent
            if arguments.contains("-list") {
                return .success(stdout: projectListJSON(
                    schemes: [name],
                    targets: [name]
                ))
            }
            #expect(value(after: "-scheme", in: arguments) == name)
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: buildSettingsJSON(
                target: name,
                bundleID: "com.example.\(name.lowercased())"
            ))
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates.map(\.scheme) == ["Admin", "Consumer"])
        #expect(resolution.candidates.map(\.bundleID) == ["com.example.admin", "com.example.consumer"])
    }

    @Test
    func resolvesWorkspaceWithWorkspaceArgumentsAndKeepsContainerIdentity()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-workspace-resolver-\(UUID().uuidString)",
                isDirectory: true
            )
        let workspacePath = root
            .appendingPathComponent("Sample.xcworkspace", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: workspacePath,
            withIntermediateDirectories: true
        )
        let runner = XcodeResolverRunner { arguments in
            #expect(value(after: "-workspace", in: arguments) == workspacePath)
            #expect(!arguments.contains("-project"))
            if arguments.contains("-list") {
                return .success(stdout: workspaceListJSON(
                    schemes: ["Sample"],
                    targets: ["SampleApp"]
                ))
            }
            return .success(stdout: buildSettingsJSON(
                target: "SampleApp",
                bundleID: "com.example.sample"
            ))
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates == [
            XcodeProjectCandidate(
                container: .workspace(path: workspacePath),
                scheme: "Sample",
                targetName: "SampleApp",
                bundleID: "com.example.sample"
            )
        ])
        #expect(resolution.candidates.first?.projectPath == workspacePath)
    }

    @Test
    func doesNotMergeEquivalentCandidatesFromDifferentContainers() async {
        let projectPath = "/repo/Sample.xcodeproj"
        let workspacePath = "/repo/Sample.xcworkspace"
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                let payload = arguments.contains("-workspace")
                    ? workspaceListJSON(
                        schemes: ["Sample"],
                        targets: ["SampleApp"]
                    )
                    : projectListJSON(
                        schemes: ["Sample"],
                        targets: ["SampleApp"]
                    )
                return .success(stdout: payload)
            }
            return .success(stdout: buildSettingsJSON(
                target: "SampleApp",
                bundleID: "com.example.sample"
            ))
        }
        let resolver = XcodeProjectResolver(
            locateContainers: { _ in [
                .project(path: projectPath),
                .workspace(path: workspacePath)
            ] },
            runCommand: runner.run
        )

        let resolution = await resolver.resolve(projectRootPath: "/repo")

        #expect(resolution.candidates.map(\.container) == [
            .project(path: projectPath),
            .workspace(path: workspacePath)
        ])
    }

    @Test
    func commandTimeoutDoesNotProduceGuessedCandidate() async throws {
        let root = try makeProjectRoot(named: "TimedOut")
        let runner = XcodeResolverRunner { _ in
            CommandResult(
                standardOutput: "",
                standardError: "Command timed out after 15.0 seconds.",
                terminationStatus: 124
            )
        }

        let resolution = await XcodeProjectResolver(
            locateProjectPaths: { _ in
                [root.appendingPathComponent("TimedOut.xcodeproj").path]
            },
            runCommand: runner.run
        ).resolve(projectRootPath: root.path)

        #expect(resolution.candidates.isEmpty)
        #expect(
            resolution.diagnosticMessage?.contains("timed out") == true,
            "实际诊断：\(resolution.diagnosticMessage ?? "nil")"
        )
    }

    @Test
    func malformedXcodeJSONProducesDiagnosticWithoutCandidate() async throws {
        let root = try makeProjectRoot(named: "Broken")
        let runner = XcodeResolverRunner { _ in
            .success(stdout: "{not-json")
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates.isEmpty)
        #expect(resolution.diagnosticMessage != nil)
    }

    @Test
    func truncatedStructuredOutputProducesDiagnosticWithoutCandidate() async throws {
        let root = try makeProjectRoot(named: "Huge")
        let runner = XcodeResolverRunner { _ in
            CommandResult(
                standardOutput: projectListJSON(
                    schemes: ["Huge"],
                    targets: ["Huge"]
                ),
                standardError: "",
                terminationStatus: 0,
                standardOutputWasTruncated: true
            )
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates.isEmpty)
        #expect(resolution.diagnosticMessage?.contains("结构化结果过大") == true)
    }

    @Test
    func ignoresGeneratedDependencyTreesDuringProjectDiscovery() async throws {
        let root = try makeProjectRoot(named: "Real")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules/Dependency.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(stdout: projectListJSON(
                    schemes: ["Real"],
                    targets: ["Real"]
                ))
            }
            #expect(value(after: "-scheme", in: arguments) == "Real")
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: buildSettingsJSON(
                target: "Real",
                bundleID: "com.example.real"
            ))
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates.count == 1)
        #expect(resolution.candidates.first?.projectPath.hasSuffix("Real.xcodeproj") == true)
    }

    @Test
    func discoversProjectWhenConfiguredRootNameIsHidden() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-hidden-resolver-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = parent.appendingPathComponent(".workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Hidden.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runner = XcodeResolverRunner { arguments in
            if arguments.contains("-list") {
                return .success(stdout: projectListJSON(
                    schemes: ["Hidden"],
                    targets: ["Hidden"]
                ))
            }
            #expect(value(after: "-scheme", in: arguments) == "Hidden")
            #expect(value(after: "-sdk", in: arguments) == "iphoneos")
            #expect(!arguments.contains("-target"))
            #expect(!arguments.contains("-destination"))
            return .success(stdout: buildSettingsJSON(
                target: "Hidden",
                bundleID: "com.example.hidden"
            ))
        }

        let resolution = await XcodeProjectResolver(runCommand: runner.run)
            .resolve(projectRootPath: root.path)

        #expect(resolution.candidates.map(\.bundleID) == ["com.example.hidden"])
    }

    @Test
    func projectLocatorUsesFindWithoutShellAndParsesNULTerminatedPaths() async throws {
        let recorder = XcodeLocatorInvocationRecorder()
        let locator = XcodeProjectLocator { launchPath, arguments, timeoutSeconds in
            await recorder.record(
                launchPath: launchPath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
            return CommandResult(
                standardOutput: "/repo/B.xcodeproj\0/repo/A Project.xcodeproj\0/repo/B.xcodeproj\0",
                standardError: "",
                terminationStatus: 0
            )
        }

        let paths = try await locator.locate(projectRootPath: "/repo")
        let invocation = await recorder.invocation

        #expect(paths == ["/repo/A Project.xcodeproj", "/repo/B.xcodeproj"])
        #expect(invocation?.launchPath == "/usr/bin/find")
        #expect(invocation?.arguments.prefix(2) == ["-H", "/repo"])
        #expect(invocation?.arguments.contains("-print0") == true)
        #expect(invocation?.arguments.contains("node_modules") == true)
        #expect(invocation?.arguments.contains("DerivedData") == true)
        #expect(invocation?.timeoutSeconds == 45)
    }

    @Test
    func projectLocatorDiscoversProjectAndWorkspaceContainersWhileFilteringGeneratedTrees()
        async throws {
        let locator = XcodeProjectLocator { _, _, _ in
            CommandResult(
                standardOutput: [
                    "/repo/App.xcodeproj",
                    "/repo/App.xcworkspace",
                    "/repo/App.xcodeproj/project.xcworkspace",
                    "/repo/Pods/Pods.xcodeproj",
                    "/repo/DerivedData/Generated.xcworkspace",
                    "/repo/.hidden/Hidden.xcodeproj"
                ].joined(separator: "\0") + "\0",
                standardError: "",
                terminationStatus: 0
            )
        }

        let containers = try await locator.locateContainers(
            projectRootPath: "/repo"
        )

        #expect(containers == [
            .project(path: "/repo/App.xcodeproj"),
            .workspace(path: "/repo/App.xcworkspace")
        ])
    }

    @Test
    func projectLocatorFollowsOnlyASymbolicLinkUsedAsTheConfiguredRoot() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-symlink-resolver-\(UUID().uuidString)",
                isDirectory: true
            )
        let realRoot = container.appendingPathComponent(
            "real-workspace",
            isDirectory: true
        )
        let linkedRoot = container.appendingPathComponent(
            "configured-workspace",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realRoot.appendingPathComponent(
                "App.xcodeproj",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: realRoot
        )

        let paths = try await XcodeProjectLocator().locate(
            projectRootPath: linkedRoot.path
        )

        #expect(paths == [
            linkedRoot.appendingPathComponent("App.xcodeproj").path
        ])
    }

    @Test
    func projectLocatorFailsClosedWhenFindOutputIsTruncated() async {
        let locator = XcodeProjectLocator { _, _, _ in
            CommandResult(
                standardOutput: "/repo/App.xcodeproj\0",
                standardError: "",
                terminationStatus: 0,
                standardOutputWasTruncated: true
            )
        }

        do {
            _ = try await locator.locate(projectRootPath: "/repo")
            Issue.record("截断的 find 输出不应被接受")
        } catch {
            #expect(error.localizedDescription.contains("过大"))
        }
    }

    @Test
    func projectLocatorFailsClosedWhenOwnedProcessesRemain() async {
        let locator = XcodeProjectLocator { _, _, _ in
            CommandResult(
                standardOutput: "/repo/App.xcodeproj\0",
                standardError: "",
                terminationStatus: 0,
                processGroupTerminationWasConfirmed: false
            )
        }

        do {
            _ = try await locator.locate(projectRootPath: "/repo")
            Issue.record("存在未确认后代进程时不应接受 find 输出")
        } catch {
            #expect(error.localizedDescription.contains("进程树"))
        }
    }

    @Test
    func projectLocatorFailsClosedWhenFindExitsNonzero() async {
        let locator = XcodeProjectLocator { _, _, _ in
            CommandResult(
                standardOutput: "/repo/App.xcodeproj\0",
                standardError: "permission denied",
                terminationStatus: 1
            )
        }

        do {
            _ = try await locator.locate(projectRootPath: "/repo")
            Issue.record("失败的 find 不应产生候选工程")
        } catch {
            #expect(error.localizedDescription.contains("permission denied"))
        }
    }

    @Test
    func projectLocatorFailsClosedWhenFindTimesOut() async {
        let locator = XcodeProjectLocator { _, _, _ in
            CommandResult(
                standardOutput: "",
                standardError: "Command timed out after 45.0 seconds.",
                terminationStatus: 124
            )
        }

        do {
            _ = try await locator.locate(projectRootPath: "/repo")
            Issue.record("超时的 find 不应产生候选工程")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
    }

    @Test
    func resolverStopsBeforeXcodebuildWhenProjectLimitIsExceeded() async {
        let runner = XcodeResolverRunner { _ in
            Issue.record("工程数量超过上限时不应执行 xcodebuild")
            return .success(stdout: "")
        }
        let projectPaths = (0...20).map {
            "/repo/Project\($0).xcodeproj"
        }
        let resolver = XcodeProjectResolver(
            locateProjectPaths: { _ in projectPaths },
            runCommand: runner.run
        )

        let resolution = await resolver.resolve(projectRootPath: "/repo")

        #expect(resolution.candidates.isEmpty)
        #expect(resolution.diagnosticMessage?.contains("超过 20 个") == true)
        #expect(!resolution.isComplete)
    }

    @Test
    func resolverStopsBeforeTargetInspectionWhenSchemeLimitIsExceeded()
        async {
        let runner = XcodeResolverRunner { arguments in
            guard arguments.contains("-list") else {
                Issue.record("Scheme 数量超过上限时不应查询 Target")
                return .success(stdout: "")
            }
            return .success(stdout: projectListJSON(
                schemes: (0...100).map { "Scheme\($0)" },
                targets: ["App"]
            ))
        }
        let resolver = XcodeProjectResolver(
            locateProjectPaths: { _ in ["/repo/App.xcodeproj"] },
            runCommand: runner.run
        )

        let resolution = await resolver.resolve(projectRootPath: "/repo")

        #expect(resolution.candidates.isEmpty)
        #expect(
            resolution.diagnosticMessage?
                .contains("Scheme 总数超过 100") == true
        )
        #expect(!resolution.isComplete)
    }

    @Test
    func resolverPropagatesCancellationWithoutWaitingForSyntheticDeadline() async throws {
        let runner = XcodeResolverRunner { _ in
            Issue.record("locator 取消后不应执行 xcodebuild")
            return .success(stdout: "")
        }
        let resolver = XcodeProjectResolver(
            locateProjectPaths: { _ in
                try await Task.sleep(for: .seconds(30))
                return []
            },
            runCommand: runner.run
        )
        let task = Task {
            await resolver.resolve(projectRootPath: "/repo")
        }

        await Task.yield()
        task.cancel()
        let resolution = await task.value

        #expect(resolution.candidates.isEmpty)
        #expect(resolution.diagnosticMessage == "项目识别已取消。")
        #expect(!resolution.isComplete)
    }
}

private actor XcodeLocatorInvocationRecorder {
    struct Invocation: Sendable {
        let launchPath: String
        let arguments: [String]
        let timeoutSeconds: TimeInterval?
    }

    private(set) var invocation: Invocation?

    func record(
        launchPath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval?
    ) {
        invocation = Invocation(
            launchPath: launchPath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )
    }
}

private final class XcodeResolverRunner: @unchecked Sendable {
    private let response: @Sendable ([String]) -> CommandResult

    init(response: @escaping @Sendable ([String]) -> CommandResult) {
        self.response = response
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        response(arguments)
    }
}

private final class XcodeResolverArgumentsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedArguments: [String] = []

    var arguments: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedArguments
    }

    func record(_ arguments: [String]) {
        lock.lock()
        storedArguments = arguments
        lock.unlock()
    }
}

private func makeProjectRoot(named name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ios-sign-kit-xcode-resolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("\(name).xcodeproj", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func buildSettingsJSON(target: String, bundleID: String) -> String {
    """
    [{
      "target":"\(target)",
      "buildSettings":{
        "PRODUCT_TYPE":"com.apple.product-type.application",
        "WRAPPER_EXTENSION":"app",
        "PLATFORM_NAME":"iphoneos",
        "PRODUCT_BUNDLE_IDENTIFIER":"\(bundleID)"
      }
    }]
    """
}

private func projectListJSON(
    schemes: [String],
    targets: [String]
) -> String {
    let encodedSchemes = schemes
        .map { "\"\($0)\"" }
        .joined(separator: ",")
    let encodedTargets = targets
        .map { "\"\($0)\"" }
        .joined(separator: ",")
    return """
    {
      "project":{
        "schemes":[\(encodedSchemes)],
        "targets":[\(encodedTargets)]
      }
    }
    """
}

private func workspaceListJSON(
    schemes: [String],
    targets: [String]
) -> String {
    let encodedSchemes = schemes
        .map { "\"\($0)\"" }
        .joined(separator: ",")
    let encodedTargets = targets
        .map { "\"\($0)\"" }
        .joined(separator: ",")
    return """
    {
      "workspace":{
        "schemes":[\(encodedSchemes)],
        "targets":[\(encodedTargets)]
      }
    }
    """
}

private func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private extension CommandResult {
    static func success(stdout: String) -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: "", terminationStatus: 0)
    }
}
