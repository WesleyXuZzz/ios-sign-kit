import Foundation
import AppKit

enum ReminderSettingsSaveState: Equatable {
    case enabled
    case saved
    case failed(String)
}

enum SetupValidationMessageContext: Equatable {
    case project
    case device
}

enum DeviceFeedbackUpdate: Equatable {
    case preserve
    case replace(String)
    case clear
}

@MainActor
final class SetupWizardViewModel: ObservableObject {
    @Published var projectRootPath: String
    @Published var xcodeprojPath: String
    @Published var scheme: String
    @Published var targetName: String
    @Published var bundleID: String
    @Published private(set) var projectCandidates: [XcodeProjectCandidate] = []
    @Published var selectedProjectCandidateID: String = ""
    @Published private(set) var isInferringProject: Bool = false
    @Published var checkIntervalMinutes: Int
    @Published var expiredCheckIntervalMinutes: Int
    @Published var reminderCooldownHours: Int
    @Published var startAtLogin: Bool
    @Published var autoRefreshPolicy: AutoRefreshPolicy
    @Published var lanControlEnabled: Bool
    @Published var lanControlHost: String
    @Published var lanControlPortText: String
    @Published var lanControlPassword: String = ""
    @Published var lanControlPasswordConfirmation: String = ""
    @Published var availableDevices: [DeviceInfo]
    @Published private(set) var deviceSelectionTargets: [DeviceSelectTarget]
    @Published var selectedDeviceID: String
    @Published var detectedDevice: DeviceInfo?
    @Published private(set) var validationMessage: String
    @Published private(set) var validationMessageContext:
        SetupValidationMessageContext
    @Published private(set) var projectValidationMessage: String
    @Published var isScanningDevices: Bool = false
    @Published private(set) var reminderSettingsSaveState: ReminderSettingsSaveState = .enabled
    @Published private(set) var deviceSelectionErrorMessage: String?

    var onSettingsSaved: ((AppConfig) -> Void)?
    var onDeviceScanStarted: (() -> Void)?
    var onDeviceScanCompleted: ((DeviceScanResult?, DeviceInfo?, String?) -> Void)?

    private let environmentValidator: EnvironmentValidator
    private let xcodeProjectResolver: XcodeProjectResolver
    private let stateStore: RefreshStateStore
    private let deviceMonitor: DeviceMonitor
    private let deviceMatcher: DeviceMatcher
    private let deviceDetectionComparisonSink:
        DeviceDetectionComparisonSink
    private let projectFolderOpener: (String) throws -> Void
    private let xcodeProjectOpener: (String) throws -> Void
    private let projectInferenceTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var persistedPreferredDeviceName: String?
    private var lastPersistedConfig: AppConfig
    private var deviceScanTask: Task<Void, Never>?
    private var projectInferenceWorkTask: Task<Void, Never>?
    private var projectInferenceDeadlineTask: Task<Void, Never>?
    private var projectInferenceGeneration: UInt64 = 0
    private var deviceScanSequence: Int = 0
    private var deviceDetectionRolloutMode:
        DeviceDetectionRolloutMode
    private var configurationRequiresRecovery: Bool
    private var projectResolutionIsComplete: Bool

    init(
        deviceDetectionRolloutMode: DeviceDetectionRolloutMode,
        initialConfig: AppConfig,
        environmentValidator: EnvironmentValidator,
        xcodeProjectResolver: XcodeProjectResolver = XcodeProjectResolver(),
        stateStore: RefreshStateStore,
        deviceMonitor: DeviceMonitor = DeviceMonitor(),
        deviceMatcher: DeviceMatcher = DeviceMatcher(),
        deviceDetectionComparisonSink:
            DeviceDetectionComparisonSink =
                DeviceDetectionComparisonSink(),
        configurationRequiresRecovery: Bool = false,
        projectInferenceTimeout: Duration = .seconds(45),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        projectFolderOpener: @escaping (String) throws -> Void = SetupWizardViewModel.openPathWithSystemOpen,
        xcodeProjectOpener: @escaping (String) throws -> Void = SetupWizardViewModel.openXcodeProjectWithSystemOpen
    ) {
        self.projectRootPath = initialConfig.projectRootPath ?? ""
        self.xcodeprojPath = initialConfig.xcodeprojPath ?? ""
        self.scheme = initialConfig.scheme ?? ""
        self.targetName = initialConfig.targetName ?? ""
        self.bundleID = initialConfig.bundleID ?? ""
        self.checkIntervalMinutes = initialConfig.checkIntervalMinutes
        self.expiredCheckIntervalMinutes =
            initialConfig.expiredCheckIntervalMinutes
        self.reminderCooldownHours = initialConfig.reminderCooldownHours
        self.startAtLogin = initialConfig.startAtLogin
        self.autoRefreshPolicy = initialConfig.autoRefreshPolicy
        self.lanControlEnabled = initialConfig.lanControl.isEnabled
        self.lanControlHost = initialConfig.lanControl.accessHost
        self.lanControlPortText = String(initialConfig.lanControl.port)
        self.availableDevices = []
        self.deviceSelectionTargets = []
        self.selectedDeviceID = initialConfig.preferredDeviceID ?? ""
        self.detectedDevice = nil
        let initialProjectMessage = "请选择本地 iOS 项目目录以开始配置。"
        self.validationMessage = initialProjectMessage
        self.validationMessageContext = .project
        self.projectValidationMessage = initialProjectMessage
        self.deviceSelectionErrorMessage = nil
        self.environmentValidator = environmentValidator
        self.xcodeProjectResolver = xcodeProjectResolver
        self.stateStore = stateStore
        self.deviceMonitor = deviceMonitor
        self.deviceMatcher = deviceMatcher
        self.deviceDetectionRolloutMode =
            deviceDetectionRolloutMode
        self.deviceDetectionComparisonSink =
            deviceDetectionComparisonSink
        self.configurationRequiresRecovery = configurationRequiresRecovery
        self.projectResolutionIsComplete = initialConfig.hasResolvedApplicationTarget
        self.projectInferenceTimeout = projectInferenceTimeout
        self.sleep = sleep
        self.projectFolderOpener = projectFolderOpener
        self.xcodeProjectOpener = xcodeProjectOpener
        self.persistedPreferredDeviceName = initialConfig.preferredDeviceName
        var normalizedInitialConfig = initialConfig
        normalizedInitialConfig.deployScriptPath = nil
        self.lastPersistedConfig = normalizedInitialConfig

        if initialConfig.projectRootPath != nil {
            let candidateConfig = makeConfig()
            publishValidationMessage(
                environmentValidator.validate(config: candidateConfig).summary,
                context: .project
            )
        }
    }

    func autofillFromProjectRoot() {
        projectInferenceGeneration &+= 1
        let generation = projectInferenceGeneration
        projectInferenceWorkTask?.cancel()
        projectInferenceDeadlineTask?.cancel()
        projectInferenceWorkTask = nil
        projectInferenceDeadlineTask = nil

        let normalizedRootPath = normalizedProjectRootPath(projectRootPath)
        if projectRootPath != normalizedRootPath {
            projectRootPath = normalizedRootPath
        }

        guard !normalizedRootPath.isEmpty else {
            isInferringProject = false
            xcodeprojPath = ""
            scheme = ""
            targetName = ""
            bundleID = ""
            projectCandidates = []
            selectedProjectCandidateID = ""
            projectResolutionIsComplete = false
            publishValidationMessage(
                "请先输入项目根目录。",
                context: .project
            )
            return
        }

        let requestedRootPath = normalizedRootPath
        xcodeprojPath = ""
        scheme = ""
        targetName = ""
        bundleID = ""
        projectCandidates = []
        selectedProjectCandidateID = ""
        projectResolutionIsComplete = false
        isInferringProject = true
        publishValidationMessage(
            "正在读取 Xcode Scheme 与构建设置…",
            context: .project
        )

        let resolver = xcodeProjectResolver
        projectInferenceWorkTask = Task.detached { [weak self] in
            let resolution = await resolver.resolve(projectRootPath: requestedRootPath)
            await self?.applyProjectInference(
                resolution: resolution,
                requestedRootPath: requestedRootPath,
                generation: generation
            )
        }

        let timeout = projectInferenceTimeout
        let sleep = sleep
        projectInferenceDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            self?.expireProjectInference(
                requestedRootPath: requestedRootPath,
                generation: generation
            )
        }
    }

    func waitForProjectInferenceToSettle() async {
        let workTask = projectInferenceWorkTask
        let deadlineTask = projectInferenceDeadlineTask
        await workTask?.value
        await deadlineTask?.value
    }

    func updateProjectRootPathFromManualInput(_ path: String) {
        guard projectRootPath != path else {
            return
        }

        projectInferenceGeneration &+= 1
        projectInferenceWorkTask?.cancel()
        projectInferenceDeadlineTask?.cancel()
        projectInferenceWorkTask = nil
        projectInferenceDeadlineTask = nil
        isInferringProject = false

        projectRootPath = path
        xcodeprojPath = ""
        scheme = ""
        targetName = ""
        bundleID = ""
        projectCandidates = []
        selectedProjectCandidateID = ""
        projectResolutionIsComplete = false

        let hasProjectRoot = !path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        publishValidationMessage(
            hasProjectRoot
                ? "项目路径已修改，请重新识别。"
                : "请输入或选择项目根目录。",
            context: .project
        )
    }

    private func applyProjectInference(
        resolution: XcodeProjectResolution,
        requestedRootPath: String,
        generation: UInt64
    ) {
        guard projectInferenceGeneration == generation,
              projectRootPath == requestedRootPath,
              isInferringProject else {
            return
        }
        projectInferenceDeadlineTask?.cancel()
        projectInferenceDeadlineTask = nil
        projectInferenceWorkTask = nil
        isInferringProject = false
        projectCandidates = resolution.candidates
        projectResolutionIsComplete = resolution.isComplete

        let persistedMatches = resolution.candidates.filter {
            candidateMatchesPersistedConfiguration($0)
        }
        let candidateToApply: XcodeProjectCandidate?
        if persistedMatches.count == 1 {
            candidateToApply = persistedMatches.first
        } else if resolution.isComplete,
                  resolution.candidates.count == 1 {
            candidateToApply = resolution.candidates.first
        } else {
            candidateToApply = nil
        }
        if let candidate = candidateToApply {
            applyProjectCandidate(candidate)
            publishValidationMessage(
                resolution.diagnosticMessage
                    ?? environmentValidator.validate(config: makeConfig()).summary,
                context: .project
            )
        } else if !resolution.candidates.isEmpty {
            xcodeprojPath = ""
            scheme = ""
            targetName = ""
            bundleID = ""
            selectedProjectCandidateID = ""
            publishValidationMessage(
                projectSelectionPrompt(for: resolution),
                context: .project
            )
        } else {
            xcodeprojPath = ""
            scheme = ""
            targetName = ""
            bundleID = ""
            publishValidationMessage(
                resolution.diagnosticMessage
                    ?? "无法从 Xcode 构建设置识别 App 目标。",
                context: .project
            )
        }
    }

    private func projectSelectionPrompt(
        for resolution: XcodeProjectResolution
    ) -> String {
        guard !resolution.isComplete else {
            return resolution.diagnosticMessage
                ?? "检测到多个 App 目标，请明确选择 Scheme。"
        }
        let prompt = "部分 Scheme 无法完成识别；请明确选择一个已核验的 App 目标。"
        guard let diagnostic = resolution.diagnosticMessage else {
            return prompt
        }
        return DiagnosticText.bounded("\(prompt) \(diagnostic)")
    }

    private func expireProjectInference(
        requestedRootPath: String,
        generation: UInt64
    ) {
        guard projectInferenceGeneration == generation,
              projectRootPath == requestedRootPath,
              isInferringProject else {
            return
        }
        projectInferenceGeneration &+= 1
        let workTask = projectInferenceWorkTask
        projectInferenceWorkTask = nil
        projectInferenceDeadlineTask = nil
        isInferringProject = false
        xcodeprojPath = ""
        scheme = ""
        targetName = ""
        bundleID = ""
        projectCandidates = []
        selectedProjectCandidateID = ""
        projectResolutionIsComplete = false
        publishValidationMessage(
            "项目识别超过 45 秒，本次结果已放弃；可立即重新识别。",
            context: .project
        )
        workTask?.cancel()
    }

    func selectProjectCandidate(id: String) {
        guard projectCandidateSelectionIsAvailable else {
            publishValidationMessage(
                "当前没有可选择的已核验 App 目标，请重新识别项目。",
                context: .project
            )
            return
        }
        guard let candidate = projectCandidates.first(where: { $0.id == id }) else {
            selectedProjectCandidateID = ""
            xcodeprojPath = ""
            scheme = ""
            targetName = ""
            bundleID = ""
            publishValidationMessage(
                "请选择明确的 App 目标。",
                context: .project
            )
            return
        }
        applyProjectCandidate(candidate)
        publishValidationMessage(
            environmentValidator.validate(config: makeConfig()).summary,
            context: .project
        )
    }

    var canSaveProjectConfiguration: Bool {
        guard !isInferringProject,
              projectSelectionIsTrusted,
              emptyToNil(projectRootPath) != nil,
              emptyToNil(xcodeprojPath) != nil,
              emptyToNil(scheme) != nil,
              emptyToNil(targetName) != nil,
              emptyToNil(bundleID) != nil else {
            return false
        }
        let status = environmentValidator.validate(config: makeConfig())
        return status.isProjectPathValid
            && status.isApplicationTargetResolved
    }

    private var projectSelectionIsTrusted: Bool {
        if projectCandidates.isEmpty {
            return projectResolutionIsComplete
        }
        return projectCandidates.contains {
            $0.id == selectedProjectCandidateID
        }
    }

    var canSaveSettings: Bool {
        canSaveProjectConfiguration && lanControlValidationMessage == nil
    }

    var lanControlPasswordIsSet: Bool {
        lastPersistedConfig.lanControl.passwordCredential != nil
    }

    var lanControlValidationMessage: String? {
        guard lanControlEnabled else {
            return nil
        }
        guard let port = Int(lanControlPortText),
              LANControlConfiguration.validationMessage(
                  host: lanControlHost,
                  port: port
              ) == nil else {
            return LANControlConfiguration.validationMessage(
                host: lanControlHost,
                port: Int(lanControlPortText) ?? 0
            ) ?? "端口需为 1024–65535 之间的数字。"
        }

        if lanControlPassword.isEmpty,
           lanControlPasswordConfirmation.isEmpty {
            return lanControlPasswordIsSet
                ? nil
                : "启用局域网控制前请设置控制密码。"
        }
        guard lanControlPassword.count >= 6 else {
            return "控制密码至少需要 6 个字符。"
        }
        guard lanControlPassword == lanControlPasswordConfirmation else {
            return "两次输入的控制密码不一致。"
        }
        return nil
    }

    var lanControlDraftURL: URL? {
        LANControlConfiguration(
            isEnabled: lanControlEnabled,
            accessHost: lanControlHost,
            port: Int(lanControlPortText) ?? 0,
            passwordCredential:
                lastPersistedConfig.lanControl.passwordCredential
        ).accessURL
    }

    var hasUnsavedLANControlChanges: Bool {
        makeConfig().lanControl != lastPersistedConfig.lanControl
            || !lanControlPassword.isEmpty
            || !lanControlPasswordConfirmation.isEmpty
    }

    var projectCandidateSelectionIsAvailable: Bool {
        !isInferringProject && !projectCandidates.isEmpty
    }

    var requiresExplicitProjectCandidateSelection: Bool {
        !projectCandidates.isEmpty
            && (!projectResolutionIsComplete || projectCandidates.count > 1)
    }

    /// 设置页使用的轻量脏状态指示；不改变现有保存时机，只比较当前草稿与最近一次持久化配置。
    var hasUnsavedChanges: Bool {
        makeConfig() != lastPersistedConfig
            || !lanControlPassword.isEmpty
            || !lanControlPasswordConfirmation.isEmpty
    }

    var isDeviceDetectionReadOnly: Bool {
        deviceDetectionRolloutMode == .readOnly
    }

    @discardableResult
    func saveSettings() -> Bool {
        guard !isInferringProject else {
            publishValidationMessage(
                "请等待 Xcode 项目识别完成后再存储设置。",
                context: .project
            )
            return false
        }
        guard canSaveProjectConfiguration else {
            if !projectCandidates.isEmpty,
               !projectCandidates.contains(where: {
                   $0.id == selectedProjectCandidateID
               }) {
                publishValidationMessage(
                    "请先明确选择一个 App Scheme。",
                    context: .project
                )
            } else {
                publishValidationMessage(
                    environmentValidator.validate(config: makeConfig()).summary,
                    context: .project
                )
            }
            return false
        }
        if let lanControlValidationMessage {
            publishValidationMessage(
                lanControlValidationMessage,
                context: .project
            )
            return false
        }

        checkIntervalMinutes = AppConfigConstraints.normalizeCheckInterval(
            checkIntervalMinutes
        )
        expiredCheckIntervalMinutes =
            AppConfigConstraints.normalizeExpiredCheckInterval(
                expiredCheckIntervalMinutes
            )
        reminderCooldownHours = AppConfigConstraints.normalizeReminderCooldown(
            reminderCooldownHours
        )
        var config = makeConfig()
        if !lanControlPassword.isEmpty {
            do {
                config.lanControl.passwordCredential = try
                    LANControlPasswordCredential.make(
                        password: lanControlPassword
                    )
            } catch {
                publishValidationMessage(
                    error.localizedDescription,
                    context: .project
                )
                return false
            }
        }
        do {
            try stateStore.saveConfig(config)
            configurationRequiresRecovery = false
            lastPersistedConfig = config
            lanControlPassword = ""
            lanControlPasswordConfirmation = ""
            reminderSettingsSaveState = .saved
            deviceSelectionErrorMessage = nil
            onSettingsSaved?(config)
            publishValidationMessage("设置已存储。", context: .project)
            return true
        } catch {
            let errorMessage = "存储设置失败：\(error.localizedDescription)"
            reminderSettingsSaveState = .failed(errorMessage)
            deviceSelectionErrorMessage = errorMessage
            publishValidationMessage(errorMessage, context: .project)
            return false
        }
    }

    func chooseProjectRootDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "选择项目目录"
        panel.message = "请选择 iOS 项目根目录"

        if panel.runModal() == .OK, let url = panel.url {
            updateProjectRootPathFromManualInput(url.path)
            autofillFromProjectRoot()
        }
    }

    func openXcodeProject() {
        guard let projectPath = xcodeProjectPathForOpening() else {
            publishValidationMessage(
                "请先自动识别 Xcode 工程或工作区路径。",
                context: .project
            )
            return
        }

        guard FileManager.default.fileExists(atPath: projectPath) else {
            publishValidationMessage(
                "Xcode 工程或工作区路径不存在：\(projectPath)",
                context: .project
            )
            return
        }

        do {
            try xcodeProjectOpener(projectPath)
        } catch {
            publishValidationMessage(
                "打开 Xcode 工程或工作区失败：\(error.localizedDescription)",
                context: .project
            )
        }
    }

    func openProjectFolder() {
        guard let projectRootPath = emptyToNil(projectRootPath) else {
            publishValidationMessage(
                "请先选择项目根目录。",
                context: .project
            )
            return
        }

        guard FileManager.default.fileExists(atPath: projectRootPath) else {
            publishValidationMessage(
                "项目根目录不存在：\(projectRootPath)",
                context: .project
            )
            return
        }

        do {
            try projectFolderOpener(projectRootPath)
        } catch {
            publishValidationMessage(
                "打开项目失败：\(error.localizedDescription)",
                context: .project
            )
        }
    }

    func scanDevices() {
        deviceScanSequence += 1
        let scanSequence = deviceScanSequence
        let selectedDeviceID = self.selectedDeviceID
        let preferredDeviceName = persistedPreferredDeviceName
        let deviceMonitor = self.deviceMonitor
        let deviceMatcher = self.deviceMatcher
        let rolloutMode = deviceDetectionRolloutMode

        isScanningDevices = true
        onDeviceScanStarted?()
        publishValidationMessage(
            "正在扫描可用 iPhone…",
            context: .device
        )
        deviceScanTask?.cancel()

        deviceScanTask = Task { [weak self] in
            let snapshot: DeviceScanSnapshot

            do {
                let scanResult: DeviceScanResult
                let comparisonSample:
                    DeviceDetectionComparisonSample?
                switch rolloutMode {
                case .fallback:
                    scanResult =
                        try await deviceMonitor.scanAvailableIPhones(
                            options: .reliable(
                                preferredDeviceID:
                                    selectedDeviceID.isEmpty
                                        ? nil
                                        : selectedDeviceID,
                                preferredDeviceName:
                                    preferredDeviceName
                            )
                        )
                    comparisonSample = nil
                case .shadow:
                    let compared =
                        try await deviceMonitor
                            .scanAvailableIPhonesWithCanonicalComparison(
                                options: .reliable(
                                    preferredDeviceID:
                                        selectedDeviceID.isEmpty
                                            ? nil
                                            : selectedDeviceID,
                                    preferredDeviceName:
                                        preferredDeviceName
                                )
                            )
                    scanResult = compared.primary
                    comparisonSample =
                        DeviceDetectionComparisonSample(
                            rolloutMode: .shadow,
                            primaryEngine: .compatibility,
                            comparisonEngine: .canonical,
                            primaryDevice:
                                compared.projections.compatibility,
                            comparisonDevice:
                                compared.projections.canonical,
                            primaryWork: .fullInteractiveCheck,
                            comparisonWork: .fullInteractiveCheck,
                            sourceCommandCount:
                                compared.projections.sourceCommandCount
                        )
                case .readOnly:
                    let compared =
                        try await deviceMonitor
                            .scanInventoryWithCompatibilityComparison(
                                purpose: .interactive,
                                compatibilityOptions: .reliable(
                                    preferredDeviceID:
                                        selectedDeviceID.isEmpty
                                            ? nil
                                            : selectedDeviceID,
                                    preferredDeviceName:
                                        preferredDeviceName
                                )
                            )
                    let inventory = compared.canonical
                    scanResult = DeviceScanResult(
                        devices: inventory.devices,
                        source: inventory.diagnostics.source,
                        unavailableTarget: nil,
                        unavailableDevices: inventory.unavailableDevices,
                        isCompleteInventory:
                            inventory.identityResolution == .complete,
                        diagnostics: DeviceScanDiagnostics(
                            attempts: 1,
                            message: inventory.diagnostics.summary
                        )
                    )
                    comparisonSample =
                        DeviceDetectionComparisonSample(
                            rolloutMode: .readOnly,
                            primaryEngine: .canonical,
                            comparisonEngine: .compatibility,
                            primaryDevice:
                                compared.projections.canonical,
                            comparisonDevice:
                                compared.projections.compatibility,
                            primaryWork: .fullInteractiveCheck,
                            comparisonWork: .fullInteractiveCheck,
                            sourceCommandCount:
                                compared.projections.sourceCommandCount
                        )
                case .production:
                    let inventory =
                        try await deviceMonitor.scanInventory(
                            purpose: .interactive
                        )
                    scanResult = DeviceScanResult(
                        devices: inventory.devices,
                        source: inventory.diagnostics.source,
                        unavailableTarget: nil,
                        unavailableDevices: inventory.unavailableDevices,
                        isCompleteInventory:
                            inventory.identityResolution == .complete,
                        diagnostics: DeviceScanDiagnostics(
                            attempts: 1,
                            message: inventory.diagnostics.summary
                        )
                    )
                    comparisonSample = nil
                }
                let devices = scanResult.devices
                let matchResult = deviceMatcher.match(
                    preferredDeviceID: selectedDeviceID.isEmpty ? nil : selectedDeviceID,
                    preferredDeviceName: nil,
                    devices: devices
                )
                snapshot = DeviceScanSnapshot(
                    scanResult: scanResult,
                    matchedDevice: matchResult.device,
                    matchDiagnostic: matchResult.diagnosticMessage,
                    comparisonSample: comparisonSample,
                    errorMessage: nil
                )
            } catch {
                snapshot = DeviceScanSnapshot(
                    scanResult: nil,
                    matchedDevice: nil,
                    matchDiagnostic: nil,
                    comparisonSample: nil,
                    errorMessage: "扫描设备失败：\(error.localizedDescription)"
                )
            }

            guard let self else { return }
            guard !Task.isCancelled else { return }

            self.applyDeviceScanSnapshot(snapshot, scanSequence: scanSequence)
        }
    }

    func transitionDeviceDetectionRollout(
        to requestedVersion: DeviceDetectionRolloutMode
    ) {
        guard requestedVersion != deviceDetectionRolloutMode else {
            return
        }
        deviceDetectionRolloutMode = requestedVersion
        deviceScanSequence &+= 1
        deviceScanTask?.cancel()
        deviceScanTask = nil
        isScanningDevices = false
    }

    func selectDeviceDraft(id: String?) {
        selectedDeviceID = id?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        deviceSelectionErrorMessage = nil
    }

    func syncDetectedDevices(
        devices: [DeviceInfo],
        matchedDevice: DeviceInfo?,
        feedback: DeviceFeedbackUpdate
    ) {
        applyDetectedDevices(devices, matchedDevice: matchedDevice)

        switch feedback {
        case .preserve:
            break
        case .replace(let message):
            publishValidationMessage(message, context: .device)
        case .clear:
            clearDeviceValidationMessage()
        }
    }

    func syncPersistedDeviceSelection(_ config: AppConfig) {
        selectedDeviceID = config.preferredDeviceID ?? ""
        persistedPreferredDeviceName = config.preferredDeviceName
        lastPersistedConfig = config
        deviceSelectionErrorMessage = nil
    }

    func restoreSettingsDefaults() {
        checkIntervalMinutes = AppConfig.default.checkIntervalMinutes
        expiredCheckIntervalMinutes =
            AppConfig.default.expiredCheckIntervalMinutes
        reminderCooldownHours = AppConfig.default.reminderCooldownHours
        autoRefreshPolicy = AppConfig.default.autoRefreshPolicy
        lanControlEnabled = AppConfig.default.lanControl.isEnabled
        lanControlHost = AppConfig.default.lanControl.accessHost
        lanControlPortText = String(AppConfig.default.lanControl.port)
        lanControlPassword = ""
        lanControlPasswordConfirmation = ""
    }

    var hasPinnedDeviceSelection: Bool {
        !selectedDeviceID.isEmpty
    }

    var selectedDevice: DeviceInfo? {
        if let device = availableDevices.first(where: { $0.id == selectedDeviceID }) {
            return device
        }

        if detectedDevice?.id == selectedDeviceID {
            return detectedDevice
        }

        return nil
    }

    var deviceSelectionPrimaryText: String {
        if hasPinnedDeviceSelection {
            return selectedDeviceDisplayName
        }

        if let detectedDevice {
            return detectedDevice.name
        }

        return availableDevices.isEmpty ? "未检测到 iPhone" : "请选择设备"
    }

    private func makeConfig() -> AppConfig {
        let selectedDevice = self.selectedDevice
        let selectedTarget = deviceSelectionTargets.first {
            $0.id == selectedDeviceID
        }
        let normalizedSelectedDeviceID = emptyToNil(selectedDeviceID)
        let preservedDeviceName: String?
        if selectedDevice == nil,
           selectedTarget == nil,
           normalizedSelectedDeviceID == lastPersistedConfig.preferredDeviceID {
            preservedDeviceName = persistedPreferredDeviceName
        } else {
            preservedDeviceName = nil
        }

        return AppConfig(
            projectRootPath: emptyToNil(projectRootPath),
            deployScriptPath: nil,
            xcodeprojPath: emptyToNil(xcodeprojPath),
            scheme: emptyToNil(scheme),
            targetName: emptyToNil(targetName),
            bundleID: emptyToNil(bundleID),
            preferredDeviceID: normalizedSelectedDeviceID,
            preferredDeviceName: selectedDevice?.name
                ?? selectedTarget?.name
                ?? preservedDeviceName,
            checkIntervalMinutes: checkIntervalMinutes,
            expiredCheckIntervalMinutes: expiredCheckIntervalMinutes,
            reminderCooldownHours: reminderCooldownHours,
            startAtLogin: startAtLogin,
            autoRefreshPolicy: autoRefreshPolicy,
            lanControl: LANControlConfiguration(
                isEnabled: lanControlEnabled,
                accessHost: lanControlHost,
                port: Int(lanControlPortText) ?? 0,
                passwordCredential:
                    lastPersistedConfig.lanControl.passwordCredential
            )
        )
    }

    private func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedProjectRootPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return (trimmed as NSString).expandingTildeInPath
    }

    private func applyProjectCandidate(_ candidate: XcodeProjectCandidate) {
        selectedProjectCandidateID = candidate.id
        xcodeprojPath = candidate.projectPath
        scheme = candidate.scheme
        targetName = candidate.targetName
        bundleID = candidate.bundleID
    }

    private func candidateMatchesPersistedConfiguration(
        _ candidate: XcodeProjectCandidate
    ) -> Bool {
        guard let projectPath = lastPersistedConfig.xcodeprojPath,
              let scheme = lastPersistedConfig.scheme,
              let targetName = lastPersistedConfig.targetName,
              let bundleID = lastPersistedConfig.bundleID else {
            return false
        }
        return URL(fileURLWithPath: projectPath).standardizedFileURL.path
                == URL(fileURLWithPath: candidate.projectPath)
                    .standardizedFileURL.path
            && scheme == candidate.scheme
            && targetName == candidate.targetName
            && bundleID == candidate.bundleID
    }

    private func xcodeProjectPathForOpening() -> String? {
        if let projectPath = emptyToNil(xcodeprojPath) {
            return projectPath
        }

        guard let projectRootPath = emptyToNil(projectRootPath) else {
            return nil
        }

        guard let inferredPath = environmentValidator.inferProjectDetails(from: projectRootPath).xcodeprojPath else {
            return nil
        }

        xcodeprojPath = inferredPath
        return inferredPath
    }

    nonisolated private static func openXcodeProjectWithSystemOpen(_ path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Xcode", path]
        try process.run()
    }

    nonisolated private static func openPathWithSystemOpen(_ path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try process.run()
    }

    private func applyDeviceScanSnapshot(_ snapshot: DeviceScanSnapshot, scanSequence: Int) {
        guard scanSequence == deviceScanSequence else {
            return
        }

        if let comparisonSample = snapshot.comparisonSample {
            deviceDetectionComparisonSink.record(comparisonSample)
        }
        deviceScanTask = nil
        isScanningDevices = false

        if let errorMessage = snapshot.errorMessage {
            availableDevices = []
            deviceSelectionTargets = []
            detectedDevice = nil
            publishValidationMessage(errorMessage, context: .device)
            onDeviceScanCompleted?(nil, nil, errorMessage)
            return
        }

        let scannedDevices = snapshot.scanResult?.devices ?? []
        applyDetectedDevices(
            scannedDevices,
            unavailableDevices: snapshot.scanResult?.unavailableDevices ?? [],
            matchedDevice: snapshot.matchedDevice
        )
        let devices = availableDevices

        let diagnosticSuffix = snapshot.scanResult?.diagnostics.message.map { " \($0)" } ?? ""
        let message: String
        if devices.isEmpty {
            message = "没有找到可用的 iPhone。\(diagnosticSuffix)"
        } else if hasPinnedDeviceSelection {
            message = selectedDevice != nil
                ? "已更新设备列表，固定设备当前在线。"
                : "已更新设备列表，固定设备暂未在线。\(diagnosticSuffix)"
        } else if let detectedDevice {
            message = "已检测到目标设备：\(detectedDevice.name)。"
        } else {
            message = snapshot.matchDiagnostic
                ?? "已更新设备列表，可选择固定目标设备或保持自动匹配。"
        }
        publishValidationMessage(message, context: .device)

        onDeviceScanCompleted?(snapshot.scanResult, detectedDevice, nil)
    }

    private func applyDetectedDevices(
        _ devices: [DeviceInfo],
        unavailableDevices: [UnavailableDeviceInfo] = [],
        matchedDevice: DeviceInfo?
    ) {
        deviceSelectionTargets = DeviceSelectTarget.selectableTargets(
            devices: devices,
            unavailableDevices: unavailableDevices,
            matcher: deviceMatcher
        )
        let verifiedDevices = devices.filter {
            $0.isAvailable && $0.isPaired
        }
        availableDevices = verifiedDevices

        guard let matchedDevice,
              matchedDevice.isAvailable,
              matchedDevice.isPaired else {
            detectedDevice = nil
            return
        }
        detectedDevice = verifiedDevices.first {
            $0.id == matchedDevice.id
        }
    }

    private func clearDeviceValidationMessage() {
        guard validationMessageContext == .device else {
            return
        }
        validationMessage = projectValidationMessage
        validationMessageContext = .project
    }

    private func publishValidationMessage(
        _ message: String,
        context: SetupValidationMessageContext
    ) {
        validationMessage = message
        validationMessageContext = context
        if context == .project {
            projectValidationMessage = message
        }
    }

    private var selectedDeviceDisplayName: String {
        selectedDevice?.name
            ?? deviceSelectionTargets.first { $0.id == selectedDeviceID }?.name
            ?? persistedPreferredDeviceName
            ?? selectedDeviceID
    }
}

private struct DeviceScanSnapshot: Sendable {
    let scanResult: DeviceScanResult?
    let matchedDevice: DeviceInfo?
    let matchDiagnostic: String?
    let comparisonSample: DeviceDetectionComparisonSample?
    let errorMessage: String?
}
