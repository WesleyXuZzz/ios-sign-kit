import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct SetupWizardViewModelTests {
    @Test
    @MainActor
    func deviceFeedbackDoesNotReplaceProjectFeedback() {
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )
        let initialProjectMessage = viewModel.projectValidationMessage

        viewModel.syncDetectedDevices(
            devices: [],
            matchedDevice: nil,
            feedback: .replace("扫描设备失败：测试错误。")
        )

        #expect(viewModel.validationMessageContext == .device)
        #expect(viewModel.validationMessage == "扫描设备失败：测试错误。")
        #expect(viewModel.projectValidationMessage == initialProjectMessage)

        #expect(!viewModel.projectValidationMessage.contains("扫描设备失败"))
    }

    @Test
    @MainActor
    func saveIsBlockedWhileStructuredProjectInferenceIsRunning() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-delayed-project-\(UUID().uuidString)", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let store = RefreshStateStore(appSupportDirectory: rootURL.appendingPathComponent("state"))
        var initialConfig = AppConfig.default
        initialConfig.projectRootPath = rootURL.path
        initialConfig.scheme = "Persisted"
        initialConfig.targetName = "Persisted"
        initialConfig.bundleID = "com.example.persisted"
        try store.saveConfig(initialConfig)

        let gate = SequencedProjectCommandGate()
        defer { gate.releaseAll() }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: initialConfig,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: gatedProjectResolver(
                rootURL: rootURL,
                gate: gate
            ),
            stateStore: store
        )

        viewModel.autofillFromProjectRoot()
        try await gate.waitForListInvocation(1)
        #expect(viewModel.isInferringProject)
        viewModel.saveSettings()

        let savedDuringInference = try #require(store.loadConfigIfPresent())
        #expect(savedDuringInference.scheme == "Persisted")
        #expect(savedDuringInference.bundleID == "com.example.persisted")
        #expect(viewModel.validationMessage.contains("等待"))

        gate.release(0)
        await viewModel.waitForProjectInferenceToSettle()
        #expect(!viewModel.isInferringProject)
    }

    @Test
    func saveRequiresExplicitSelectionWhenMultipleAppCandidatesExist() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-multiple-projects-\(UUID().uuidString)", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("App.xcodeproj", isDirectory: true)
        let scriptURL = rootURL.appendingPathComponent("scripts/deploy/ios-device.command")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let store = RefreshStateStore(appSupportDirectory: rootURL.appendingPathComponent("state"))
        var persistedConfig = AppConfig.default
        persistedConfig.scheme = "Persisted"
        persistedConfig.targetName = "Persisted"
        persistedConfig.bundleID = "com.example.persisted"
        try store.saveConfig(persistedConfig)
        let resolver = XcodeProjectResolver { _, arguments, _ in
            if arguments.contains("-list") {
                return CommandResult(
                    standardOutput:
                        #"{"project":{"schemes":["Consumer","Internal"],"targets":["Consumer","Internal"]}}"#,
                    standardError: "",
                    terminationStatus: 0
                )
            }
            let schemeIndex = arguments.firstIndex(of: "-scheme")!
            let scheme = arguments[schemeIndex + 1]
            return CommandResult(
                standardOutput: """
                [{"target":"\(scheme)","buildSettings":{
                  "PRODUCT_TYPE":"com.apple.product-type.application",
                  "PLATFORM_NAME":"iphoneos",
                  "PRODUCT_BUNDLE_IDENTIFIER":"com.example.\(scheme.lowercased())"
                }}]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: persistedConfig,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: resolver,
            stateStore: store
        )
        viewModel.projectRootPath = rootURL.path

        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard { !viewModel.isInferringProject }
        #expect(viewModel.projectCandidates.count == 2)
        #expect(!viewModel.canSaveProjectConfiguration)

        viewModel.saveSettings()
        #expect(store.loadConfig().scheme == "Persisted")
        #expect(viewModel.validationMessage.contains("明确选择"))

        let candidate = try #require(viewModel.projectCandidates.first)
        viewModel.selectProjectCandidate(id: candidate.id)
        #expect(viewModel.canSaveProjectConfiguration)
        viewModel.saveSettings()

        #expect(store.loadConfig().scheme == candidate.scheme)
        #expect(store.loadConfig().targetName == candidate.targetName)
        #expect(store.loadConfig().bundleID == candidate.bundleID)
    }

    @Test
    func restoresUniquePersistedSelectionWhenMultipleAppCandidatesExist() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-restored-project-selection-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent(
            "App.xcodeproj",
            isDirectory: true
        )
        let scriptURL = rootURL.appendingPathComponent(
            "scripts/deploy/ios-device.command"
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        var persistedConfig = AppConfig.default
        persistedConfig.projectRootPath = rootURL.path
        persistedConfig.deployScriptPath = scriptURL.path
        persistedConfig.xcodeprojPath = projectURL.path
        persistedConfig.scheme = "Consumer"
        persistedConfig.targetName = "Consumer"
        persistedConfig.bundleID = "com.example.consumer"
        let store = RefreshStateStore(
            appSupportDirectory: rootURL.appendingPathComponent("state")
        )
        try store.saveConfig(persistedConfig)

        let resolver = XcodeProjectResolver { _, arguments, _ in
            if arguments.contains("-list") {
                return CommandResult(
                    standardOutput:
                        #"{"project":{"schemes":["Consumer","Internal"],"targets":["Consumer","Internal"]}}"#,
                    standardError: "",
                    terminationStatus: 0
                )
            }
            let schemeIndex = arguments.firstIndex(of: "-scheme")!
            let scheme = arguments[schemeIndex + 1]
            return CommandResult(
                standardOutput: """
                [{"target":"\(scheme)","buildSettings":{
                  "PRODUCT_TYPE":"com.apple.product-type.application",
                  "PLATFORM_NAME":"iphoneos",
                  "PRODUCT_BUNDLE_IDENTIFIER":"com.example.\(scheme.lowercased())"
                }}]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: persistedConfig,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: resolver,
            stateStore: store
        )
        #expect(!viewModel.hasUnsavedChanges)

        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard { !viewModel.isInferringProject }

        #expect(viewModel.projectCandidates.count == 2)
        #expect(viewModel.selectedProjectCandidateID != "")
        #expect(viewModel.scheme == "Consumer")
        #expect(viewModel.targetName == "Consumer")
        #expect(viewModel.bundleID == "com.example.consumer")
        #expect(viewModel.canSaveProjectConfiguration)
        #expect(viewModel.saveSettings())
        #expect(store.loadConfig().deployScriptPath == nil)
    }

    @Test
    func partialResolutionAllowsExplicitSelectionOfVerifiedCandidate()
        async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-partial-project-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(
                "App.xcodeproj",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        let resolver = XcodeProjectResolver { _, arguments, _ in
            if arguments.contains("-list") {
                return CommandResult(
                    standardOutput:
                        #"{"project":{"schemes":["Available","Broken"],"targets":["Consumer"]}}"#,
                    standardError: "",
                    terminationStatus: 0
                )
            }
            guard arguments.contains("Available") else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "scheme inspection failed",
                    terminationStatus: 1
                )
            }
            return CommandResult(
                standardOutput: """
                [
                  {"target":"Consumer","buildSettings":{
                    "PRODUCT_TYPE":"com.apple.product-type.application",
                    "PLATFORM_NAME":"iphoneos",
                    "PRODUCT_BUNDLE_IDENTIFIER":"com.example.consumer"
                  }}
                ]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: resolver,
            stateStore: RefreshStateStore(
                appSupportDirectory: rootURL.appendingPathComponent("state")
            )
        )
        viewModel.projectRootPath = rootURL.path

        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard { !viewModel.isInferringProject }
        let candidate = try #require(viewModel.projectCandidates.first)

        #expect(viewModel.projectCandidates.count == 1)
        #expect(viewModel.projectCandidateSelectionIsAvailable)
        #expect(viewModel.requiresExplicitProjectCandidateSelection)
        #expect(!viewModel.canSaveProjectConfiguration)
        viewModel.selectProjectCandidate(id: candidate.id)
        #expect(viewModel.selectedProjectCandidateID == candidate.id)
        #expect(viewModel.scheme == candidate.scheme)
        #expect(viewModel.targetName == candidate.targetName)
        #expect(viewModel.bundleID == candidate.bundleID)
        #expect(viewModel.requiresExplicitProjectCandidateSelection)
        #expect(viewModel.canSaveProjectConfiguration)
    }

    @Test(arguments: [false, true])
    func saveAcceptsStandardProjectWithoutExecutableDeployScript(
        scriptExists: Bool
    ) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-optional-script-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL
            .appendingPathComponent("App.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        if scriptExists {
            let scriptURL = rootURL
                .appendingPathComponent("scripts/deploy/ios-device.command")
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "#!/bin/zsh\nexit 0\n".write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: scriptURL.path
            )
        }

        let store = RefreshStateStore(
            appSupportDirectory: rootURL.appendingPathComponent("state")
        )
        var persistedConfig = AppConfig.default
        persistedConfig.scheme = "Persisted"
        persistedConfig.targetName = "Persisted"
        persistedConfig.bundleID = "com.example.persisted"
        try store.saveConfig(persistedConfig)
        let resolver = XcodeProjectResolver { _, arguments, _ in
            if arguments.contains("-list") {
                return CommandResult(
                    standardOutput:
                        #"{"project":{"schemes":["App"],"targets":["App"]}}"#,
                    standardError: "",
                    terminationStatus: 0
                )
            }
            return CommandResult(
                standardOutput: #"[{"target":"App","buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","PLATFORM_NAME":"iphoneos","PRODUCT_BUNDLE_IDENTIFIER":"com.example.app"}}]"#,
                standardError: "",
                terminationStatus: 0
            )
        }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: persistedConfig,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: resolver,
            stateStore: store
        )
        viewModel.projectRootPath = rootURL.path

        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard { !viewModel.isInferringProject }

        #expect(viewModel.canSaveProjectConfiguration)
        viewModel.saveSettings()
        let savedConfig = store.loadConfig()
        #expect(savedConfig.scheme == "App")
        #expect(savedConfig.targetName == "App")
        #expect(savedConfig.bundleID == "com.example.app")
        #expect(savedConfig.deployScriptPath == nil)
        #expect(viewModel.validationMessage == "设置已存储。")
    }

    @Test
    func projectInferenceTimeoutEndsUIWithoutWaitingForBlockedWork() async throws {
        let rootURL = try makeProjectInferenceFixture()
        let gate = SequencedProjectCommandGate()
        defer { gate.releaseAll() }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: gatedProjectResolver(
                rootURL: rootURL,
                gate: gate
            ),
            stateStore: makeStateStore(),
            projectInferenceTimeout: .milliseconds(60)
        )
        viewModel.projectRootPath = rootURL.path

        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard(timeout: .seconds(1)) {
            gate.listInvocationCount == 1
        }
        try await waitForSetupWizard(timeout: .seconds(1)) {
            !viewModel.isInferringProject
        }

        #expect(!viewModel.canSaveProjectConfiguration)
        #expect(viewModel.validationMessage.contains("本次结果已放弃"))
        #expect(viewModel.scheme.isEmpty)

        gate.release(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(viewModel.scheme.isEmpty)
        #expect(viewModel.validationMessage.contains("本次结果已放弃"))
    }

    @Test
    func sameRootRetryAcceptsOnlyNewestInferenceGeneration() async throws {
        let rootURL = try makeProjectInferenceFixture()
        let gate = SequencedProjectCommandGate()
        defer { gate.releaseAll() }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: gatedProjectResolver(
                rootURL: rootURL,
                gate: gate
            ),
            stateStore: makeStateStore(),
            projectInferenceTimeout: .seconds(2)
        )
        viewModel.projectRootPath = rootURL.path

        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard {
            gate.listInvocationCount == 1
        }
        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard {
            gate.listInvocationCount == 2
        }

        gate.release(1)
        try await waitForSetupWizard {
            !viewModel.isInferringProject
        }
        #expect(viewModel.scheme == "New")
        #expect(viewModel.bundleID == "com.example.new")

        gate.release(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(viewModel.scheme == "New")
        #expect(viewModel.bundleID == "com.example.new")
    }

    @Test
    func manualRootEditInvalidatesResolvedProjectState() throws {
        let rootURL = try makeProjectInferenceFixture()
        let scriptURL = rootURL
            .appendingPathComponent("scripts/deploy/ios-device.command")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let projectURL = rootURL.appendingPathComponent(
            "App.xcodeproj",
            isDirectory: true
        )
        var config = makeConfig(
            projectRootPath: rootURL.path,
            xcodeprojPath: projectURL.path
        )
        config.deployScriptPath = scriptURL.path
        config.scheme = "App"
        config.targetName = "App"
        config.bundleID = "com.example.app"
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: config,
            environmentValidator: EnvironmentValidator(),
            stateStore: makeStateStore()
        )
        #expect(viewModel.canSaveProjectConfiguration)

        let replacementRoot = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        viewModel.updateProjectRootPathFromManualInput(replacementRoot.path)

        #expect(viewModel.projectRootPath == replacementRoot.path)
        #expect(viewModel.xcodeprojPath.isEmpty)
        #expect(viewModel.scheme.isEmpty)
        #expect(viewModel.targetName.isEmpty)
        #expect(viewModel.bundleID.isEmpty)
        #expect(viewModel.projectCandidates.isEmpty)
        #expect(viewModel.selectedProjectCandidateID.isEmpty)
        #expect(!viewModel.canSaveProjectConfiguration)
        #expect(
            viewModel.validationMessage
                == "项目路径已修改，请重新识别。"
        )
    }

    @Test
    func manualRootEditInvalidatesPendingProjectInference() async throws {
        let rootURL = try makeProjectInferenceFixture()
        let gate = SequencedProjectCommandGate()
        defer { gate.releaseAll() }
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: gatedProjectResolver(
                rootURL: rootURL,
                gate: gate
            ),
            stateStore: makeStateStore(),
            projectInferenceTimeout: .seconds(2)
        )
        viewModel.projectRootPath = rootURL.path
        viewModel.autofillFromProjectRoot()
        try await waitForSetupWizard {
            gate.listInvocationCount == 1
        }

        let replacementRoot = rootURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        viewModel.updateProjectRootPathFromManualInput(replacementRoot.path)

        #expect(!viewModel.isInferringProject)
        #expect(
            viewModel.validationMessage
                == "项目路径已修改，请重新识别。"
        )
        #expect(viewModel.projectCandidates.isEmpty)
        #expect(viewModel.scheme.isEmpty)

        gate.release(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(viewModel.scheme.isEmpty)
        #expect(viewModel.bundleID.isEmpty)
        #expect(
            viewModel.validationMessage
                == "项目路径已修改，请重新识别。"
        )
    }

    @Test
    func whitespaceOnlyManualRootDoesNotStartInference() {
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: makeStateStore()
        )
        viewModel.updateProjectRootPathFromManualInput(" \n\t ")

        viewModel.autofillFromProjectRoot()

        #expect(viewModel.projectRootPath.isEmpty)
        #expect(!viewModel.isInferringProject)
        #expect(viewModel.validationMessage == "请先输入项目根目录。")
        #expect(viewModel.projectCandidates.isEmpty)
    }

    @Test
    func manualRootInputIsNormalizedBeforeInference() async throws {
        let resolver = XcodeProjectResolver(
            locateProjectPaths: { _ in [] },
            runCommand: { _, _, _ in
                return CommandResult(
                    standardOutput: "",
                    standardError: "",
                    terminationStatus: 1
                )
            }
        )
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: resolver,
            stateStore: makeStateStore()
        )
        let typedPath = "  ~/Projects/Example App \n"
        let expectedPath = (
            "~/Projects/Example App" as NSString
        ).expandingTildeInPath
        viewModel.updateProjectRootPathFromManualInput(typedPath)

        viewModel.autofillFromProjectRoot()

        #expect(viewModel.projectRootPath == expectedPath)
        try await waitForSetupWizard { !viewModel.isInferringProject }
    }

    @Test
    func opensConfiguredProjectRootPath() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var openedPath: String?
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: makeConfig(projectRootPath: rootURL.path),
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(),
            projectFolderOpener: { path in
                openedPath = path
            }
        )

        viewModel.openProjectFolder()

        #expect(openedPath == rootURL.path)
    }

    @Test
    func doesNotOpenMissingProjectRootPath() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("MissingProject", isDirectory: true)
        var didOpen = false
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: makeConfig(projectRootPath: missingURL.path),
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(),
            projectFolderOpener: { _ in
                didOpen = true
            }
        )

        viewModel.openProjectFolder()

        #expect(!didOpen)
        #expect(viewModel.validationMessage == "项目根目录不存在：\(missingURL.path)")
    }

    @Test
    func opensConfiguredXcodeProjectPath() throws {
        let xcodeprojURL = try makeXcodeprojDirectory(named: "ConfiguredApp.xcodeproj")
        var openedPath: String?
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: makeConfig(xcodeprojPath: xcodeprojURL.path),
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(),
            xcodeProjectOpener: { path in
                openedPath = path
            }
        )

        viewModel.openXcodeProject()

        #expect(openedPath == xcodeprojURL.path)
    }

    @Test
    func doesNotGuessXcodeProjectPathBeforeStructuredResolution() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
        let xcodeprojURL = rootURL.appendingPathComponent("InferredApp.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
        var openedPath: String?
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: makeConfig(projectRootPath: rootURL.path),
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(),
            xcodeProjectOpener: { path in
                openedPath = path
            }
        )

        viewModel.openXcodeProject()

        #expect(openedPath == nil)
        #expect(viewModel.xcodeprojPath.isEmpty)
        #expect(viewModel.validationMessage.contains("自动识别"))
    }

    @Test
    func doesNotOpenWhenXcodeProjectCannotBeResolved() {
        var didOpen = false
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(),
            xcodeProjectOpener: { _ in
                didOpen = true
            }
        )

        viewModel.openXcodeProject()

        #expect(!didOpen)
        #expect(
            viewModel.validationMessage
                == "请先自动识别 Xcode 工程或工作区路径。"
        )
    }

    @Test
    func doesNotOpenMissingXcodeProjectPath() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("MissingApp.xcodeproj", isDirectory: true)
        var didOpen = false
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: makeConfig(xcodeprojPath: missingURL.path),
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore(),
            xcodeProjectOpener: { _ in
                didOpen = true
            }
        )

        viewModel.openXcodeProject()

        #expect(!didOpen)
        #expect(
            viewModel.validationMessage
                == "Xcode 工程或工作区路径不存在：\(missingURL.path)"
        )
    }

    @Test
    func showsAutoMatchedDeviceFromSyncedRefreshSnapshot() {
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )
        let device = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.4",
            isAvailable: true,
            isPaired: true
        )

        viewModel.syncDetectedDevices(
            devices: [device],
            matchedDevice: device,
            feedback: .clear
        )

        #expect(viewModel.deviceSelectionPrimaryText == "Example iPhone")
    }

    @Test
    func showsPinnedDeviceNameWhenPinnedDeviceIsOnline() {
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Example iPhone"
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: config,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )
        let device = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.4",
            isAvailable: true,
            isPaired: true
        )

        viewModel.syncDetectedDevices(
            devices: [device],
            matchedDevice: device,
            feedback: .clear
        )

        #expect(viewModel.deviceSelectionPrimaryText == "Example iPhone")
    }

    @Test
    func unavailablePinnedDeviceIsNeverPresentedAsOnline() {
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Example iPhone"
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: config,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )
        let unavailableDevice = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.4",
            isAvailable: false,
            isPaired: true
        )

        viewModel.syncDetectedDevices(
            devices: [unavailableDevice],
            matchedDevice: nil,
            feedback: .replace("没有找到可用的 iPhone。")
        )

        #expect(viewModel.deviceSelectionPrimaryText == "Example iPhone")
        #expect(viewModel.validationMessage == "没有找到可用的 iPhone。")
    }

    @Test
    func newerSilentDeviceSnapshotClearsStaleScanConflictFeedback() {
        var config = AppConfig.default
        config.preferredDeviceID = "iphone-1"
        config.preferredDeviceName = "Example iPhone"
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: config,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )
        let onlineDevice = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.4",
            isAvailable: true,
            isPaired: true
        )

        viewModel.syncDetectedDevices(
            devices: [],
            matchedDevice: nil,
            feedback: .replace(
                "没有找到可用的 iPhone。设备来源对同一稳定 ID 的可用状态不一致。"
            )
        )
        viewModel.syncDetectedDevices(
            devices: [onlineDevice],
            matchedDevice: onlineDevice,
            feedback: .clear
        )

        #expect(viewModel.validationMessageContext != .device)
        #expect(!viewModel.validationMessage.contains("可用状态不一致"))
    }

    @Test
    func showsPinnedDeviceNameWhenPinnedDeviceIsOffline() {
        let config = AppConfig(
            projectRootPath: nil,
            deployScriptPath: nil,
            xcodeprojPath: nil,
            scheme: nil,
            bundleID: nil,
            preferredDeviceID: "iphone-2",
            preferredDeviceName: "Example iPhone",
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: config,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )

        viewModel.syncDetectedDevices(
            devices: [],
            matchedDevice: nil,
            feedback: .clear
        )

        #expect(viewModel.deviceSelectionPrimaryText == "Example iPhone")
    }

    @Test
    func savingProjectConfigPreservesOfflinePinnedDeviceName() throws {
        let stateStore = makeStateStore()
        var config = makeConfig(
            projectRootPath: "/existing/project",
            xcodeprojPath: "/existing/project/Example.xcodeproj"
        )
        config.deployScriptPath = "/existing/project/scripts/deploy/ios-device.command"
        config.scheme = "Example"
        config.targetName = "Example"
        config.bundleID = "com.example.App"
        config.preferredDeviceID = "iphone-offline"
        config.preferredDeviceName = "Offline iPhone"
        try stateStore.saveConfig(config)
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: config,
            environmentValidator: EnvironmentValidator(),
            stateStore: stateStore
        )
        viewModel.syncDetectedDevices(
            devices: [],
            matchedDevice: nil,
            feedback: .clear
        )

        viewModel.saveSettings()

        let savedConfig = stateStore.loadConfig()
        #expect(savedConfig.preferredDeviceID == "iphone-offline")
        #expect(savedConfig.preferredDeviceName == "Offline iPhone")
    }

    @Test
    func showsEmptyDeviceSelectionStateBeforeScanning() {
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )

        #expect(viewModel.deviceSelectionPrimaryText == "未检测到 iPhone")
    }

    @Test
    func setupDeviceScanFollowsDetectionPolicyAndRecordsShadowComparison()
        async throws
    {
        let cases: [
            (
                policy: DeviceDetectionRolloutMode,
                expectsDevice: Bool,
                expectedComparisons: Int
            )
        ] = [
            (.fallback, false, 0),
            (.shadow, false, 1),
            (.readOnly, true, 1),
            (.production, true, 0)
        ]

        for item in cases {
            let runner = SetupDevicePolicyRunner()
            let comparisonRecorder =
                SetupDevicePolicyComparisonRecorder()
            let viewModel = SetupWizardViewModel(
                deviceDetectionRolloutMode: item.policy,
                initialConfig: .default,
                environmentValidator: EnvironmentValidator(),
                stateStore: makeStateStore(),
                deviceMonitor: DeviceMonitor(
                    runCommand: runner.run
                ),
                deviceDetectionComparisonSink:
                    DeviceDetectionComparisonSink {
                        comparisonRecorder.record($0)
                    }
            )

            viewModel.scanDevices()
            try await waitForSetupWizard {
                !viewModel.isScanningDevices
            }

            #expect(
                (viewModel.detectedDevice?.id == "setup-policy-iphone")
                    == item.expectsDevice
            )
            #expect(runner.xcdeviceCount == 1)
            #expect(runner.devicectlCount == 1)
            #expect(
                comparisonRecorder.samples.count
                    == item.expectedComparisons
            )
        }
    }

    @Test
    func promptsForSelectionWhenMultipleDevicesAreAvailable() {
        let viewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode: .production,
            initialConfig: .default,
            environmentValidator: EnvironmentValidator(),
            stateStore: RefreshStateStore()
        )
        let devices = [
            DeviceInfo(
                id: "iphone-1",
                name: "Primary iPhone",
                platform: "com.apple.platform.iphoneos",
                osVersion: "18.4",
                isAvailable: true,
                isPaired: true
            ),
            DeviceInfo(
                id: "iphone-2",
                name: "Secondary iPhone",
                platform: "com.apple.platform.iphoneos",
                osVersion: "18.5",
                isAvailable: true,
                isPaired: true
            )
        ]

        viewModel.syncDetectedDevices(
            devices: devices,
            matchedDevice: nil,
            feedback: .clear
        )

        #expect(viewModel.deviceSelectionPrimaryText == "请选择设备")
    }

    @Test
    func numericSettingInputRejectsEmptyTextAndClampsValidValues() {
        #expect(NumericSettingInput.committedValue(from: "", in: 1...60) == nil)
        #expect(NumericSettingInput.committedValue(from: "abc", in: 1...60) == nil)
        #expect(NumericSettingInput.committedValue(from: "0", in: 1...60) == 1)
        #expect(NumericSettingInput.committedValue(from: "10", in: 1...60) == 10)
        #expect(NumericSettingInput.committedValue(from: "99", in: 1...60) == 60)
    }

    private func makeXcodeprojDirectory(named name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
        let xcodeprojURL = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
        return xcodeprojURL
    }

    private func makeProjectInferenceFixture() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-project-inference-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("App.xcodeproj"),
            withIntermediateDirectories: true
        )
        let scriptURL = rootURL
            .appendingPathComponent("scripts/deploy/ios-device.command")
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 0\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        return rootURL
    }

    private func gatedProjectResolver(
        rootURL: URL,
        gate: SequencedProjectCommandGate
    ) -> XcodeProjectResolver {
        XcodeProjectResolver(
            locateProjectPaths: { _ in
                [rootURL.appendingPathComponent("App.xcodeproj").path]
            },
            runCommand: gate.run
        )
    }

    private func makeStateStore() -> RefreshStateStore {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
        return RefreshStateStore(appSupportDirectory: directoryURL)
    }

    private func makeConfig(
        projectRootPath: String? = nil,
        xcodeprojPath: String? = nil,
        checkIntervalMinutes: Int = 5,
        reminderCooldownHours: Int = 24,
        autoRefreshPolicy: AutoRefreshPolicy = .reminderOnly
    ) -> AppConfig {
        AppConfig(
            projectRootPath: projectRootPath,
            deployScriptPath: nil,
            xcodeprojPath: xcodeprojPath,
            scheme: nil,
            bundleID: nil,
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: checkIntervalMinutes,
            reminderCooldownHours: reminderCooldownHours,
            startAtLogin: false,
            autoRefreshPolicy: autoRefreshPolicy
        )
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

private final class SetupDevicePolicyRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var xcdeviceCommands = 0
    private var devicectlCommands = 0

    var xcdeviceCount: Int {
        lock.withLock { xcdeviceCommands }
    }

    var devicectlCount: Int {
        lock.withLock { devicectlCommands }
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        if arguments.first == "xcdevice" {
            lock.withLock {
                xcdeviceCommands += 1
            }
            return CommandResult(
                standardOutput: """
                [{
                  "simulator": false,
                  "available": true,
                  "platform": "com.apple.platform.iphoneos",
                  "identifier": "setup-policy-iphone",
                  "name": "Setup Policy iPhone",
                  "modelCode": "iPhone18,1",
                  "modelName": "iPhone",
                  "operatingSystemVersion": "27.0"
                }]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }

        lock.withLock {
            devicectlCommands += 1
        }
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return CommandResult(
                standardOutput: "",
                standardError: "missing output path",
                terminationStatus: 1
            )
        }
        try """
        {"result":{"devices":[{
          "identifier":"setup-policy-coredevice",
          "deviceProperties":{
            "name":"Setup Policy iPhone",
            "osVersionNumber":"27.0",
            "deviceClass":"iPhone",
            "developerModeStatus":"enabled"
          },
          "hardwareProperties":{
            "udid":"setup-policy-iphone",
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            "pairingState":"paired",
            "transportType":"localNetwork",
            "tunnelState":"disconnected"
          }
        }]}}
        """.write(
            toFile: arguments[index + 1],
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

private final class SetupDevicePolicyComparisonRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedSamples:
        [DeviceDetectionComparisonSample] = []

    var samples: [DeviceDetectionComparisonSample] {
        lock.withLock { recordedSamples }
    }

    func record(_ sample: DeviceDetectionComparisonSample) {
        lock.withLock {
            recordedSamples.append(sample)
        }
    }
}

private final class SequencedProjectCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var listCalls = 0
    private let listInvocations = TestEventRecorder<Int>()
    private let releases = [
        DispatchSemaphore(value: 0),
        DispatchSemaphore(value: 0)
    ]

    var listInvocationCount: Int {
        lock.withLock { listCalls }
    }

    func release(_ index: Int) {
        guard releases.indices.contains(index) else {
            return
        }
        releases[index].signal()
    }

    func releaseAll() {
        releases.forEach { $0.signal() }
    }

    func waitForListInvocation(_ expectedCount: Int) async throws {
        while try await listInvocations.next() < expectedCount {}
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        if arguments.contains("-list") {
            let index = lock.withLock {
                defer { listCalls += 1 }
                return listCalls
            }
            listInvocations.record(index + 1)
            guard releases.indices.contains(index) else {
                return CommandResult(
                    standardOutput: "",
                    standardError: "unexpected list invocation",
                    terminationStatus: 1
                )
            }
            releases[index].wait()
            let scheme = index == 0 ? "Old" : "New"
            return CommandResult(
                standardOutput:
                    #"{"project":{"schemes":["\#(scheme)"],"targets":["\#(scheme)"]}}"#,
                standardError: "",
                terminationStatus: 0
            )
        }

        let schemeIndex = arguments.firstIndex(of: "-scheme")
        let target = schemeIndex
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? "Unknown"
        return CommandResult(
            standardOutput: """
            [{"target":"\(target)","buildSettings":{
              "PRODUCT_TYPE":"com.apple.product-type.application",
              "PLATFORM_NAME":"iphoneos",
              "PRODUCT_BUNDLE_IDENTIFIER":"com.example.\(target.lowercased())"
            }}]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}
