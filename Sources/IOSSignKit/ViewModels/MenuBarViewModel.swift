import Foundation
import AppKit
import OSLog
import SwiftUI


enum RefreshTriggerSource: Hashable, Sendable {
    case manual
    case automaticInitial
    case automaticRecovery

    var isAutomatic: Bool {
        self != .manual
    }
}

enum ManualRefreshRequestOutcome: Equatable, Sendable {
    case profileChoiceRequired
    case deploymentRequested
    case rejected
}

enum ManualRefreshPromptReason: Equatable, Sendable {
    case notExpired(Date)
    case expiryUnknown
    case installationUnconfirmed
    case appNotInstalled
}

struct ManualRefreshPrompt: Equatable, Sendable {
    let reason: ManualRefreshPromptReason
    let targetGeneration: Int
    let deviceID: String
}

private struct ManualRefreshPromptEvidence: Equatable, Sendable {
    let installationIdentity: InstallationIdentitySnapshot
    let estimatedExpiryAt: Date?
}

private struct PendingDeployFailureNotification: Sendable {
    let refreshSequence: Int
    let deviceID: String
    let deviceName: String
    let summary: String
}

private enum MenuBarCurrentIssue: Equatable {
    case waitingForUnlock
    case refreshPreflightFailed
}

typealias StartDeployHandler = @Sendable (
    AppConfig,
    DeploymentStartTarget,
    String,
    ProvisioningProfileRefreshMode,
    (@Sendable (String, Bool) -> Void)?
) throws -> RunningDeploy

typealias PairDeviceHandler = @Sendable (UnavailableDeviceInfo) async -> DevicePairingResult

typealias InspectInstalledAppHandler = @Sendable (
    DeviceInfo,
    String,
    Int,
    TimeInterval
) async throws -> InstalledAppInfo?

@MainActor
final class MenuBarViewModel: ObservableObject {
    private static let automaticRefreshLogger = Logger(
        subsystem: "com.xuzw.iossignkit",
        category: "AutomaticRefresh"
    )

    @Published var config: AppConfig
    @Published var state: AppState
    @Published var environmentStatus: EnvironmentStatus
    @Published var setupViewModel: SetupWizardViewModel
    @Published var availableDevices: [DeviceInfo] = []
    @Published var matchedDevice: DeviceInfo?
    @Published var reminderDecision: ReminderDecision = ReminderDecision(
        shouldPrompt: false,
        reason: "尚未检查。",
        nextEligibleAt: nil
    ) {
        didSet {
            if !reminderDecision.shouldPrompt {
                invalidateReminderDelivery()
            }
        }
    }
    private var isOperationFeedbackDismissed = false
    @Published private var menuBarCurrentIssue: MenuBarCurrentIssue?
    @Published var deployMessage: String? {
        didSet {
            let normalizedMessage = deployMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedMessage, !normalizedMessage.isEmpty {
                isOperationFeedbackDismissed = false
            }
            if !isPublishingAssociatedOperationFeedback {
                operationFeedbackAssociation = nil
            }
            if menuBarCurrentIssue != nil {
                menuBarCurrentIssue = nil
            }
        }
    }
    @Published var expiryInfo: ExpiryInfo?
    @Published var installedAppInfo: InstalledAppInfo?
    @Published var deployLogText: String = ""
    @Published var deployProgressText: String?
    @Published private(set) var installedAppInspectionFailure: String?
    @Published var historyEntries: [RefreshHistoryEntry] = []
    @Published var hasMoreHistoryEntries: Bool = false
    @Published var isLoadingMoreHistory: Bool = false
    @Published var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginUpdateError: String? = nil
    @Published var pendingAutoRefreshCountdown: Int?
    @Published private(set) var manualRefreshPrompt: ManualRefreshPrompt?
    @Published var isReloadingEnvironment: Bool = false
    @Published private(set) var isForegroundEnvironmentCheck: Bool = false
    @Published private(set) var hasConfirmedTargetDeviceThisSession: Bool = false
    @Published private(set) var menuBarTransientResult: RefreshResult?
    @Published private var remainingExpiryNow: Date = Date()

    private let bootstrapper: AppBootstrapper
    private let stateStore: RefreshStateStore
    private let stateSettlement: RefreshStateSettlement
    private let commandRunner: CommandRunner
    private let xcodeProjectResolver: XcodeProjectResolver
    private let xcodeDestinationReadinessInspector: XcodeDestinationReadinessInspector
    private let deviceMonitor: DeviceMonitor
    private let deviceMatcher: DeviceMatcher
    private let inspectInstalledApp: InspectInstalledAppHandler
    private let deviceLockStateInspector: DeviceLockStateInspector
    private let reminderPolicy: ReminderPolicy
    private let expiryInspector: ExpiryInspector
    private let startDeploy: StartDeployHandler
    private let pairDevice: PairDeviceHandler
    private let notificationService: any NotificationSending
    private let historyService: RefreshHistoryService
    private let launchAtLoginService: LaunchAtLoginService
    let lanControlServer: LANControlServerController
    private let deviceConnectionStabilizer: DeviceConnectionStabilizer
    private let deviceConnectionReducer: DeviceConnectionReducer
    private let deviceRefreshSnapshotReducer: DeviceRefreshSnapshotReducer
    private let deviceDetectionRolloutController: DeviceDetectionRolloutController
    private let deviceDetectionComparisonSink:
        DeviceDetectionComparisonSink
    private let refreshScheduler: RefreshScheduler
    private let installedAppRetryDelays: [TimeInterval]
    private let postDeployInspectionTimeoutSeconds: TimeInterval
    private let deployRecoveryDelaySeconds: TimeInterval
    private let refreshTimingPolicy: RefreshTimingPolicy
    private let menuBarResultDisplayDuration: Duration
    private var pollingTimer: Timer?
    private var scheduledPollingIntervalMinutes: Int?
    private var remainingExpiryTimer: Timer?
    private let deviceRefreshWorkflow: DeviceRefreshWorkflow
    private let deploymentPreflightWorkflow: DeploymentPreflightWorkflow
    private let deviceRefreshSession = DeviceRefreshSession()
    private var deviceVerificationGeneration: Int = 0
    private var confirmedDeviceAbsenceCount: Int = 0
    private var connectionConfirmationStartedAt: Date?
    private var connectionConfirmationTask: Task<Void, Never>?
    private var systemWakeRecheckTask: Task<Void, Never>?
    private var deviceConnectionState: DeviceConnectionState
    private var deviceDetectionRolloutState: DeviceDetectionRolloutState
    private var deferredDeviceDetectionRolloutMode: DeviceDetectionRolloutMode?
    private var refreshSessionCaches: RefreshSessionCaches
    private var passiveObservationGeneration: UInt64 = 0
    private var activeEnvironmentRefreshPresentation: EnvironmentRefreshPresentation?
    private var consecutiveInstalledAppAbsences: Int = 0
    private var installedAppRetryIndex: Int = 0
    private var installedAppRetryTask: Task<Void, Never>?
    private let deploymentTransaction =
        DeploymentTransactionCoordinator()
    private var historyPageSize: Int = 10
    private var historyOffset: Int = 0
    private var historyLoadTask: Task<Void, Never>?
    private var pendingDeployLogBuffer: String = ""
    private var deployLogFlushTask: Task<Void, Never>?
    private var menuBarTransientResultTask: Task<Void, Never>?
    private var deployOutputSink: DeployOutputSink?
    private var pendingDeployRecoveryTask: Task<Void, Never>?
    private var pendingDeployRecoveryIdentifier: UUID?
    private var operationFeedbackAssociation: (
        message: String,
        result: RefreshResult
    )?
    private var isPublishingAssociatedOperationFeedback = false
    private var reminderDeliveryTask: Task<Void, Never>?
    private var reminderDeliveryGeneration: Int?
    private var reminderDeliveryIdentifier: UUID?
    private var supersededReminderDeliveryTasks:
        [UUID: Task<Void, Never>] = [:]
    private var automaticUnlockNotificationTasks:
        [UUID: Task<Void, Never>] = [:]
    private var backgroundNotificationTasks:
        [UUID: Task<Void, Never>] = [:]
    private var pairingTask: Task<Void, Never>?
    private var pairingTaskIdentifier: UUID?
    private var manualPairingRefreshSequence: Int?
    private var pendingDeployFailureNotification: PendingDeployFailureNotification?
    private var passiveRefreshSequence: Int?
    private var latestDeployInstalledAppMetadataWasStale = false
    private var latestDeployInstalledAppInspectionTimedOut = false
    private var hasPreparedForTermination = false
    private var lanControlOperationPhase: LANControlOperationPhase?
    private var lanControlOperationStartedAt: Date?
    private var lanControlLastOperationElapsedSeconds = 0
    private var targetConfigurationGeneration = 0
    private var statePersistenceFailureActive = false
    private var manualRefreshPromptEvidence: ManualRefreshPromptEvidence?
    private var automaticWaitNotifiedKeys: Set<AutomaticRefreshWaitKey> = []
    private let automaticRefreshCoordinator: AutomaticRefreshCoordinator

    init(
        deviceDetectionRolloutMode: DeviceDetectionRolloutMode,
        deviceDetectionRolloutDiagnostic: RolloutDiagnostic? = nil,
        bootstrapper: AppBootstrapper = AppBootstrapper(),
        stateStore: RefreshStateStore = RefreshStateStore(),
        commandRunner: CommandRunner = CommandRunner(),
        xcodeProjectResolver: XcodeProjectResolver? = nil,
        xcodeDestinationReadinessInspector: XcodeDestinationReadinessInspector? = nil,
        deviceMonitor: DeviceMonitor? = nil,
        deviceMatcher: DeviceMatcher = DeviceMatcher(),
        deviceConnectionStabilizer: DeviceConnectionStabilizer = DeviceConnectionStabilizer(),
        deviceConnectionReducer: DeviceConnectionReducer = DeviceConnectionReducer(),
        deviceDetectionComparisonSink:
            DeviceDetectionComparisonSink =
                DeviceDetectionComparisonSink(),
        refreshPolicy: RefreshPolicy = RefreshPolicy(),
        refreshSessionCaches: RefreshSessionCaches = RefreshSessionCaches(),
        refreshScheduler: RefreshScheduler = .continuous,
        deviceAppInspector: DeviceAppInspector? = nil,
        inspectInstalledApp: InspectInstalledAppHandler? = nil,
        deviceLockStateInspector: DeviceLockStateInspector? = nil,
        reminderPolicy: ReminderPolicy = ReminderPolicy(),
        expiryInspector: ExpiryInspector = ExpiryInspector(),
        deployService: DeployService? = nil,
        startDeploy: StartDeployHandler? = nil,
        devicePairingService: DevicePairingService? = nil,
        pairDevice: PairDeviceHandler? = nil,
        notificationService: any NotificationSending = NotificationService(),
        historyService: RefreshHistoryService = RefreshHistoryService(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        lanControlServer: LANControlServerController? = nil,
        refreshTimingPolicy: RefreshTimingPolicy = .production,
        installedAppRetryDelays: [TimeInterval]? = nil,
        postDeployInspectionTimeoutSeconds: TimeInterval? = nil,
        deployRecoveryDelaySeconds: TimeInterval? = nil,
        menuBarResultDisplayDuration: Duration = .seconds(3)
    ) {
        let resolvedDeviceMonitor = deviceMonitor
            ?? DeviceMonitor(commandRunner: commandRunner)
        let resolvedXcodeProjectResolver = xcodeProjectResolver
            ?? XcodeProjectResolver(commandRunner: commandRunner)
        let resolvedXcodeDestinationReadinessInspector =
            xcodeDestinationReadinessInspector
            ?? XcodeDestinationReadinessInspector(commandExecutor: commandRunner)
        let resolvedDeviceAppInspector = deviceAppInspector
            ?? DeviceAppInspector(commandRunner: commandRunner)
        let resolvedDeviceLockStateInspector = deviceLockStateInspector
            ?? DeviceLockStateInspector(commandRunner: commandRunner)
        let resolvedDeployService = deployService
            ?? DeployService(commandRunner: commandRunner)
        let resolvedDevicePairingService = devicePairingService
            ?? DevicePairingService(commandRunner: commandRunner)
        let resolvedInspectInstalledApp = inspectInstalledApp
            ?? { device, bundleID, retryCount, retryDelaySeconds in
                try await resolvedDeviceAppInspector.inspectInstalledApp(
                    device: device,
                    bundleID: bundleID,
                    retryCount: retryCount,
                    retryDelaySeconds: retryDelaySeconds
                )
            }

        self.bootstrapper = bootstrapper
        self.stateStore = stateStore
        let resolvedStateSettlement = RefreshStateSettlement(
            stateStore: stateStore
        )
        self.stateSettlement = resolvedStateSettlement
        self.commandRunner = commandRunner
        self.xcodeProjectResolver = resolvedXcodeProjectResolver
        self.xcodeDestinationReadinessInspector =
            resolvedXcodeDestinationReadinessInspector
        self.deviceMonitor = resolvedDeviceMonitor
        self.deviceMatcher = deviceMatcher
        self.deviceConnectionStabilizer = deviceConnectionStabilizer
        self.deviceConnectionReducer = deviceConnectionReducer
        self.deviceRefreshSnapshotReducer = DeviceRefreshSnapshotReducer(
            connectionReducer: deviceConnectionReducer,
            connectionStabilizer: deviceConnectionStabilizer,
            stateSettlement: resolvedStateSettlement,
            expiryInspector: expiryInspector,
            requiredAbsenceCount:
                refreshTimingPolicy.requiredAbsenceCount,
            unidentifiedEvidenceGracePeriod:
                refreshTimingPolicy.installedAppCacheTTL.timeInterval
        )
        self.deviceConnectionState = deviceConnectionReducer.reduce(
            state: .initial,
            event: .sessionStarted
        ).state
        self.deviceDetectionRolloutController =
            DeviceDetectionRolloutController()
        self.deviceDetectionRolloutState = DeviceDetectionRolloutState(
            mode: deviceDetectionRolloutMode,
            generation: 0
        )
        self.deviceDetectionComparisonSink =
            deviceDetectionComparisonSink
        self.deviceRefreshWorkflow = DeviceRefreshWorkflow(
            deviceMonitor: resolvedDeviceMonitor,
            deviceMatcher: deviceMatcher,
            xcodeProjectResolver: resolvedXcodeProjectResolver,
            inspectInstalledApp: resolvedInspectInstalledApp,
            refreshPolicy: refreshPolicy
        )
        self.deploymentPreflightWorkflow = DeploymentPreflightWorkflow(
            deviceMonitor: resolvedDeviceMonitor,
            deviceMatcher: deviceMatcher,
            deviceLockStateInspector:
                resolvedDeviceLockStateInspector,
            xcodeProjectResolver: resolvedXcodeProjectResolver,
            xcodeDestinationReadinessInspector:
                resolvedXcodeDestinationReadinessInspector
        )
        self.refreshSessionCaches = refreshSessionCaches
        self.refreshScheduler = refreshScheduler
        self.automaticRefreshCoordinator = AutomaticRefreshCoordinator(
            scheduler: refreshScheduler,
            waitPolicy: refreshTimingPolicy.automaticWaitPolicy
        )
        self.refreshTimingPolicy = refreshTimingPolicy
        if let installedAppRetryDelays, !installedAppRetryDelays.isEmpty {
            self.installedAppRetryDelays = installedAppRetryDelays
        } else {
            self.installedAppRetryDelays =
                refreshTimingPolicy.installedAppRetryDelays
        }
        self.postDeployInspectionTimeoutSeconds = max(
            postDeployInspectionTimeoutSeconds
                ?? refreshTimingPolicy.postDeployInspectionTimeout,
            0.1
        )
        self.deployRecoveryDelaySeconds = max(
            deployRecoveryDelaySeconds
                ?? refreshTimingPolicy.automaticRecoveryDelay,
            0
        )
        self.menuBarResultDisplayDuration = menuBarResultDisplayDuration
        self.inspectInstalledApp = resolvedInspectInstalledApp
        self.deviceLockStateInspector = resolvedDeviceLockStateInspector
        self.reminderPolicy = reminderPolicy
        self.expiryInspector = expiryInspector
        self.startDeploy = startDeploy ?? {
            config,
            device,
            deploymentToken,
            profileRefreshMode,
            onOutput in
            try resolvedDeployService.startDeploy(
                config: config,
                target: device,
                deploymentToken: deploymentToken,
                profileRefreshMode: profileRefreshMode,
                onOutput: onOutput
            )
        }
        self.pairDevice = pairDevice ?? { device in
            await resolvedDevicePairingService.pairWirelessly(device: device)
        }
        self.notificationService = notificationService
        self.historyService = historyService
        self.launchAtLoginService = launchAtLoginService
        self.lanControlServer = lanControlServer
            ?? LANControlServerController()

        let result = bootstrapper.bootstrap()
        self.config = result.config
        self.state = result.state
        self.deployMessage = result.configurationLoadFailure
            ?? result.statePersistenceFailureMessage
            ?? deviceDetectionRolloutDiagnostic?.message
        self.statePersistenceFailureActive = result.statePersistenceUnavailable
        self.consecutiveInstalledAppAbsences = result.state.targetAppPresence == .confirmingNotInstalled ? 1 : 0
        self.installedAppInspectionFailure = result.state.lastAppInspectionFailure
        var initialEnvironmentStatus = result.environmentStatus
        if result.config.hasResolvedApplicationTarget {
            initialEnvironmentStatus.isApplicationTargetResolved = false
            initialEnvironmentStatus.summary = "正在重新验证 Xcode App 目标…"
            initialEnvironmentStatus.isValidationComplete = false
        }
        self.environmentStatus = initialEnvironmentStatus
        self.launchAtLoginEnabled = result.config.startAtLogin
        self.setupViewModel = SetupWizardViewModel(
            deviceDetectionRolloutMode:
                deviceDetectionRolloutMode,
            initialConfig: result.config,
            environmentValidator: EnvironmentValidator(),
            xcodeProjectResolver: resolvedXcodeProjectResolver,
            stateStore: stateStore,
            deviceMonitor: resolvedDeviceMonitor,
            deviceMatcher: deviceMatcher,
            deviceDetectionComparisonSink:
                deviceDetectionComparisonSink,
            configurationRequiresRecovery: result.configurationLoadFailure != nil
        )
        self.setupViewModel.onSettingsSaved = { [weak self] config in
            self?.handleSavedSettings(config)
        }
        self.setupViewModel.onDeviceScanStarted = { [weak self] in
            self?.handleSetupDeviceScanStarted()
        }
        self.setupViewModel.onDeviceScanCompleted = { [weak self] scanResult, matchedDevice, errorMessage in
            self?.handleSetupDeviceScan(scanResult: scanResult, matchedDevice: matchedDevice, errorMessage: errorMessage)
        }
        self.expiryInfo = result.state
            .isTargetAppExpiryEvidenceVerified
            ? expiryInspector.inspect(
                state: result.state,
                installedAppInfo: nil,
                minimumInstallMetadataRecordedAt:
                    result.state.activeInstallationSuccessAt?
                        .addingTimeInterval(-5)
            )
            : nil
        syncLaunchAtLoginFromConfig()
        self.lanControlServer.configure(
            snapshotProvider: { [weak self] in
                self?.makeLANControlSnapshot()
                    ?? MenuBarViewModel.unavailableLANControlSnapshot()
            },
            actionHandler: { [weak self] action in
                self?.handleLANControlAction(action)
                    ?? .rejected("iOSSignKit 当前不可用。")
            }
        )
        self.lanControlServer.apply(result.config.lanControl)
        startPolling()
        restartRemainingExpiryTimer()
    }

    var needsSetup: Bool {
        !config.hasResolvedApplicationTarget
    }

    private var remainingExpiryPresentation: RemainingExpiryPresentation {
        RemainingExpiryPresentation.make(
            expiryDate: expiryInfo?.estimatedExpiryAt,
            now: remainingExpiryNow
        )
    }

    var menuBarPresentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation.make(
            context: MenuBarStatusContext(
                isBlocked: state.processRecoveryBlocked || statePersistenceFailureActive,
                needsSetup: needsSetup,
                environmentStatus: environmentStatus,
                currentDeviceStatus: state.currentDeviceStatus,
                matchedDevice: matchedDevice,
                hasConfirmedDeviceThisSession: hasConfirmedTargetDeviceThisSession,
                hasTrustedExpiry:
                    state.isTargetAppExpiryEvidenceVerified
                    && expiryInfo?.estimatedExpiryAt != nil
            ),
            activity: menuBarActivity,
            remainingExpiry: remainingExpiryPresentation
        )
    }

    var statusMenuHeaderPresentation: StatusMenuHeaderPresentation {
        StatusMenuHeaderPresentation.make(
            menuBar: menuBarPresentation,
            environmentSummary: environmentStatus.summary,
            deviceName: deviceIdentitySummary,
            operationActivity: operationActivityPresentation,
            lastErrorSummary: state.lastErrorSummary,
            remainingExpiry: remainingExpiryPresentation,
            lastDeviceSeenAt: state.lastDeviceSeenAt
        )
    }

    private var menuBarActivity: MenuBarActivity {
        if pendingDeployRecoveryTask != nil {
            return .waitingForUnlock
        }

        if let pendingAutoRefreshCountdown {
            return .countdown(seconds: pendingAutoRefreshCountdown)
        }

        if state.isDeployRunning || deploymentTransaction.hasRunningDeployment {
            return .deploying
        }

        if deploymentTransaction.hasActiveTask {
            return .preparing
        }

        switch menuBarCurrentIssue {
        case .waitingForUnlock:
            return .waitingForUnlock
        case .refreshPreflightFailed:
            return .result(.failed)
        case nil:
            break
        }

        if let menuBarTransientResult {
            return .result(MenuBarRefreshResult(menuBarTransientResult))
        }

        if let persistentMenuBarProblemResult {
            return .result(MenuBarRefreshResult(persistentMenuBarProblemResult))
        }

        if isForegroundEnvironmentCheck {
            return .checking
        }

        return .idle
    }

    private var persistentMenuBarProblemResult: RefreshResult? {
        guard !isOperationFeedbackDismissed,
              let result = operationFeedbackResult else {
            return nil
        }

        switch result {
        case .failure, .interrupted, .unrecognized:
            return result
        case .running, .success, .cancelled:
            return nil
        }
    }

    private var deviceStatusPresentation: DeviceStatusPresentation {
        DeviceStatusPresentation.make(
            status: state.currentDeviceStatus,
            hasPersistedIdentity: state.currentDeviceName != nil
        )
    }

    var setupSummary: String {
        environmentStatus.summary
    }

    var setupStatusTone: StatusTone {
        guard environmentStatus.isValidationComplete else {
            return .warning
        }

        return environmentStatus.areAllChecksPassing ? .good : .critical
    }

    var heroSubtitle: String {
        if matchedDevice != nil {
            return "目标设备已连接，可以直接检查过期时间或执行续签。"
        }
        return deviceStatusPresentation.heroSubtitle
    }

    var deviceIdentitySummary: String? {
        if let matchedDevice {
            return formattedDeviceSummary(name: matchedDevice.name, osVersion: matchedDevice.osVersion)
        }

        if let currentDeviceName = normalizedSummaryValue(state.currentDeviceName) {
            return formattedDeviceSummary(name: currentDeviceName, osVersion: state.currentDeviceOS)
        }

        if let preferredDeviceName = normalizedSummaryValue(config.preferredDeviceName) {
            return preferredDeviceName
        }

        return nil
    }

    var deviceStatusSummary: String {
        if matchedDevice != nil {
            return "在线"
        }
        return deviceStatusPresentation.disconnectedSummary
    }

    var deviceStatusTone: StatusTone {
        if matchedDevice != nil {
            return .good
        }
        return deviceStatusPresentation.disconnectedTone
    }

    var deviceStatusRowValue: String {
        deviceIdentitySummary ?? deviceStatusSummary
    }

    var deviceStatusRowAnnotation: String? {
        deviceIdentitySummary == nil ? nil : deviceStatusSummary
    }

    var heroDeviceText: String {
        if let matchedDevice {
            return matchedDevice.name
        }
        return deviceStatusPresentation.heroDeviceText
    }

    var lastDeviceSeenSummary: String {
        guard let lastDeviceSeenAt = state.lastDeviceSeenAt else {
            return "暂无记录"
        }

        return VerificationTimePresentation.make(
            date: lastDeviceSeenAt,
            now: remainingExpiryNow
        ).compactSummary
    }

    private var lastDeviceSeenCardSummary: String {
        guard let lastDeviceSeenAt = state.lastDeviceSeenAt else {
            return "暂无记录"
        }

        return VerificationTimePresentation.make(
            date: lastDeviceSeenAt,
            now: remainingExpiryNow
        ).absoluteText
    }

    var deviceScanSourceSummary: String {
        guard let source = normalizedSummaryValue(state.lastDeviceScanSource) else {
            return deviceScanDiagnosticSummary == nil ? "尚未执行" : "未知（扫描失败）"
        }

        return source == "失败" ? "未知（扫描失败）" : source
    }

    var deviceScanDiagnosticSummary: String? {
        if let diagnostic = normalizedSummaryValue(state.lastDeviceScanFailure) {
            return diagnostic
        }

        guard let source = normalizedSummaryValue(state.lastDeviceScanSource) else {
            return nil
        }

        return source == "失败" ? "未提供诊断信息" : "未发现异常"
    }

    var expiryStatusTone: StatusTone {
        guard let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return .warning
        }

        return estimatedExpiryAt <= remainingExpiryNow ? .critical : .good
    }

    var lastErrorSummary: String {
        state.lastErrorSummary ?? "无"
    }

    var expirySummary: String {
        guard let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return "尚未确认"
        }

        return absoluteDateTimeString(for: estimatedExpiryAt)
    }

    private var expiryCardSummary: String? {
        guard let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return nil
        }

        return compactMonthDayTimeString(for: estimatedExpiryAt)
    }

    var expirySourceSummary: String {
        guard let expiryInfo else {
            return "暂无过期信息"
        }

        if let installedAppInfo,
           let metadata = installedAppInfo.installMetadata,
           expiryInfo.source == .installMetadata(metadata.profileSource) {
            return "已安装 App 元信息 · \(readableProfileSource(.installMetadata(metadata.profileSource)))"
        }

        if let lastExpiryVerifiedAt = state.lastExpiryVerifiedAt,
           installedAppInfo?.installMetadata?.expectedExpiryAt == nil {
            return "上次确认 · \(readableProfileSource(expiryInfo.source)) · \(relativeDateTimeString(for: lastExpiryVerifiedAt))"
        }

        return expiryInfo.isFallbackValue ? "最近一次成功安装时间估算" : readableProfileSource(expiryInfo.source)
    }

    var expiryDetailSummary: String? {
        guard expiryInfo?.estimatedExpiryAt != nil else {
            return nil
        }

        return "来源：\(expirySourceSummary)"
    }

    var manualRefreshActionTitle: String {
        if deploymentTransaction.hasActiveTask || state.isDeployRunning {
            return "刷新中…"
        }
        return "立即续签"
    }

    var remainingExpirySummary: String {
        remainingExpiryPresentation.panelText
    }

    var consumedExpiryProgress: Double? {
        remainingExpiryPresentation.consumedFraction
    }

    var isRemainingExpiryExpired: Bool {
        remainingExpiryPresentation.isExpired
    }

    var operationFeedbackMessage: String? {
        normalizedSummaryValue(deployMessage)
    }

    var operationActivityPresentation: OperationActivityPresentation {
        OperationActivityPresentation.make(
            isReloadingEnvironment: isReloadingEnvironment,
            pendingAutoRefreshCountdown: pendingAutoRefreshCountdown,
            isDeploymentActive: deploymentTransaction.hasActiveTask || state.isDeployRunning,
            isAwaitingDeployRecovery: pendingDeployRecoveryTask != nil,
            isProcessRecoveryBlocked: state.processRecoveryBlocked,
            isFeedbackDismissed: isOperationFeedbackDismissed,
            deployProgressText: deployProgressText,
            feedbackMessage: operationFeedbackMessage,
            feedbackResult: operationFeedbackResult,
            lastResult: state.lastResult,
            lastErrorSummary: state.lastErrorSummary
        )
    }

    var primaryJourneyPresentation: PrimaryJourneyPresentation {
        PrimaryJourneyPresentation.make(
            context: PrimaryJourneyPresentationContext(
                needsSetup: needsSetup,
                environmentSummary: environmentStatus.areAllChecksPassing
                    ? "\(environmentStatus.checkItems.count) 项检查已通过"
                    : setupSummary,
                environmentTone: setupStatusTone,
                deviceValue: deviceStatusRowValue,
                deviceDetail: deviceStatusRowAnnotation,
                lastDeviceSeenCardSummary: lastDeviceSeenCardSummary,
                deviceTone: deviceStatusTone,
                deviceIsPinned:
                    normalizedSummaryValue(config.preferredDeviceID) != nil
                    || normalizedSummaryValue(config.preferredDeviceName) != nil,
                installationTone: primaryJourneyInstallationTone,
                expirySummary: expirySummary,
                expiryCardSummary: expiryCardSummary,
                expiryDetail: expiryDetailSummary,
                expiryTone: expiryStatusTone,
                lastFullVerificationSummary:
                    primaryJourneyLastFullVerificationSummary,
                remainingExpiryText: remainingExpirySummary,
                remainingExpiryComponents:
                    remainingExpiryPresentation.metricComponents,
                consumedExpiryProgress: consumedExpiryProgress,
                expiredDurationText:
                    remainingExpiryPresentation.expiredDurationText,
                expiryUrgency: remainingExpiryPresentation.urgency,
                isExpired: isRemainingExpiryExpired,
                activity: operationActivityPresentation,
                isProcessRecoveryBlocked: state.processRecoveryBlocked,
                isCountdownActive: pendingAutoRefreshCountdown != nil,
                isRecoveryActive: pendingDeployRecoveryTask != nil,
                isDeploymentActive: deploymentTransaction.hasActiveTask || state.isDeployRunning,
                isChecking: isReloadingEnvironment,
                hasManualSigningChoice: manualRefreshPrompt != nil,
                canRefresh: canRefreshNow,
                canCancelRefresh: canCancelRefresh,
                refreshDisabledReason: primaryJourneyRefreshDisabledReason,
                canPairDevice: primaryJourneyPairingDisabledReason == nil,
                pairDeviceDisabledReason: primaryJourneyPairingDisabledReason,
                previousResult: primaryJourneyPreviousResult,
                deployLogText: deployLogText
            )
        )
    }

    @discardableResult
    func performPrimaryJourneyAction(
        _ action: PrimaryJourneyAction
    ) -> PrimaryJourneyActionOutcome {
        if case .disabled(let reason) = action.availability {
            return .rejected(reason: reason)
        }
        return performPrimaryJourneyAction(action.id)
    }

    @discardableResult
    func performPrimaryJourneyAction(
        _ actionID: PrimaryJourneyAction.ID
    ) -> PrimaryJourneyActionOutcome {
        let presentation = primaryJourneyPresentation
        let actions = presentation.headerActions
            + (presentation.currentTask?.actions ?? [])
        let matchingActions = actions.filter { $0.id == actionID }

        if actionID == .openHistory,
           presentation.previousResult != nil {
            return .openHistory
        }

        guard let action = matchingActions.first(where: \.isEnabled)
                ?? matchingActions.first else {
            return .rejected(reason: "当前界面没有提供此操作。")
        }
        if case .disabled(let reason) = action.availability {
            return .rejected(reason: reason)
        }

        switch actionID {
        case .recheck:
            reloadEnvironment()
            return .performed
        case .recoveryPreservingRecheck:
            recheckPendingDeployRecovery()
            return .performed
        case .pairDevice:
            return requestManualPairing()
        case .requestRefresh, .retryCurrentRefresh:
            switch refreshNow() {
            case .profileChoiceRequired:
                return .manualSigningChoiceRequired
            case .deploymentRequested:
                return .performed
            case .rejected:
                return .rejected(
                    reason: primaryJourneyRefreshDisabledReason
                        ?? "当前条件不允许开始续签。"
                )
            }
        case .startCountdownNow:
            startPendingAutoRefreshNow()
            return .performed
        case .cancelCountdown:
            cancelPendingAutoRefreshFromUser()
            return .performed
        case .cancelRefresh, .cancelRecovery:
            cancelRefresh()
            return .performed
        case .dismissFeedback:
            dismissOperationFeedback()
            return .performed
        case .openHistory:
            return .openHistory
        case .showDeployLog:
            return .showDeployLog(deployLogText)
        }
    }

    private var primaryJourneyInstallationTone: StatusTone {
        if state.targetAppPresence == .confirmedNotInstalled {
            return .critical
        }
        if installedAppInspectionFailure != nil {
            return .warning
        }
        return installedAppInfo == nil ? .neutral : .good
    }

    private var primaryJourneyLastFullVerificationSummary: String {
        guard let verifiedAt = state.lastExpiryVerifiedAt
                ?? state.lastAppInspectionAt else {
            return "尚无完整核验记录"
        }
        return VerificationTimePresentation.make(
            date: verifiedAt,
            now: remainingExpiryNow
        ).fullVerificationSummary
    }

    private var primaryJourneyPreviousResult: PrimaryJourneyPreviousResult? {
        switch state.lastResult {
        case .success:
            return PrimaryJourneyPreviousResult(
                outcome: .success,
                title: "续签成功",
                detail: nil,
                tone: .good,
                occurredAt: state.lastSuccessAt ?? state.lastAttemptAt,
                logPath: state.lastLogPath
            )
        case .failure:
            return PrimaryJourneyPreviousResult(
                outcome: .failure,
                title: "续签失败",
                detail: state.lastErrorSummary,
                tone: .critical,
                occurredAt: state.lastAttemptAt,
                logPath: state.lastLogPath
            )
        case .cancelled:
            return PrimaryJourneyPreviousResult(
                outcome: .cancelled,
                title: "已取消",
                detail: state.lastErrorSummary,
                tone: .neutral,
                occurredAt: state.lastAttemptAt,
                logPath: state.lastLogPath
            )
        case .interrupted:
            return PrimaryJourneyPreviousResult(
                outcome: .interrupted,
                title: "已取消",
                detail: state.lastErrorSummary,
                tone: .warning,
                occurredAt: state.lastAttemptAt,
                logPath: state.lastLogPath
            )
        case .unrecognized:
            return PrimaryJourneyPreviousResult(
                outcome: .unknown,
                title: "续签结果待确认",
                detail: state.lastErrorSummary,
                tone: .warning,
                occurredAt: state.lastAttemptAt,
                logPath: state.lastLogPath
            )
        case .running, nil:
            return nil
        }
    }

    private var primaryJourneyRefreshDisabledReason: String? {
        guard !canRefreshNow else {
            return nil
        }
        if state.processRecoveryBlocked {
            return "续签进程状态尚未恢复，暂时不能开始新的续签。"
        }
        if statePersistenceFailureActive {
            return "运行状态无法安全保存，暂时不能开始新的续签。"
        }
        if isReloadingEnvironment {
            return "正在检查设备与安装状态，请稍候。"
        }
        if setupViewModel.isScanningDevices {
            return "正在重新核验目标 iPhone，请稍候。"
        }
        if state.currentDeviceStatus == .scanFailed {
            return "目标 iPhone 的检测结果存在冲突，请重新检查。"
        }
        if deploymentTransaction.hasActiveTask || state.isDeployRunning {
            return "续签正在进行中。"
        }
        if pendingDeployRecoveryTask != nil {
            return "正在等待自动恢复，请先处理当前任务。"
        }
        if pairingTask != nil {
            return "正在恢复设备连接，请稍候。"
        }
        if !environmentStatus.areAllChecksPassing {
            return "运行环境尚未通过检查。"
        }
        if !hasCurrentMatchedDeploymentDevice {
            if normalizedSummaryValue(config.preferredDeviceID) != nil
                || normalizedSummaryValue(config.preferredDeviceName) != nil {
                return "连接固定 iPhone 后可用。"
            }
            return "请先连接并选择一台可用的目标 iPhone。"
        }
        return "当前条件不允许开始续签。"
    }

    private var primaryJourneyPairingDisabledReason: String? {
        guard allowsCriticalDeviceActions else {
            return "当前设备检测策略处于只读验证状态，暂不能尝试配对。"
        }
        if state.processRecoveryBlocked {
            return "续签进程状态尚未恢复，暂不能尝试配对。"
        }
        if statePersistenceFailureActive {
            return "运行状态无法安全保存，暂不能尝试配对。"
        }
        if isReloadingEnvironment || deviceRefreshSession.isRunning {
            return "正在检查设备与安装状态，请稍候。"
        }
        if setupViewModel.isScanningDevices {
            return "正在重新核验目标 iPhone，请稍候。"
        }
        if deploymentTransaction.hasActiveTask || state.isDeployRunning {
            return "续签正在进行中，请先等待当前任务结束。"
        }
        if automaticRefreshCoordinator.isWaiting {
            return "自动恢复正在等待设备，请稍候。"
        }
        if pairingTask != nil {
            return "正在尝试恢复设备连接，请稍候。"
        }
        guard normalizedSummaryValue(config.preferredDeviceID) != nil
                || normalizedSummaryValue(config.preferredDeviceName) != nil else {
            return "请先固定目标 iPhone 后再尝试配对。"
        }
        guard matchedDevice == nil else {
            return "目标 iPhone 已连接。"
        }
        return nil
    }

    var canRefreshNow: Bool {
        !deploymentTransaction.hasActiveTask
            && pairingTask == nil
            && !state.isDeployRunning
            && !state.processRecoveryBlocked
            && !statePersistenceFailureActive
            && !isReloadingEnvironment
            && !setupViewModel.isScanningDevices
            && state.currentDeviceStatus != .scanFailed
            && environmentStatus.areAllChecksPassing
            && hasCurrentMatchedDeploymentDevice
    }

    var canCancelRefresh: Bool {
        deploymentTransaction.hasActiveTask || pendingDeployRecoveryTask != nil
    }

    func issueLANControlPairingURL() throws -> URL {
        try lanControlServer.issuePairingURL()
    }

    private func handleLANControlAction(
        _ action: LANControlAction
    ) -> LANControlActionOutcome {
        switch action {
        case .recheck:
            guard !deploymentTransaction.hasActiveTask,
                  !state.isDeployRunning else {
                return .rejected("续签正在进行，无需重复检查。")
            }
            reloadEnvironment()
            return .accepted("已开始重新检查。")
        case .renew(let profileRefreshMode):
            return requestLANControlRenewal(
                profileRefreshMode: profileRefreshMode
            )
        case .dismissResult:
            dismissOperationFeedback()
            return .accepted("已返回当前状态。")
        }
    }

    func requestLANControlRenewal(
        profileRefreshMode: ProvisioningProfileRefreshMode?
    ) -> LANControlActionOutcome {
        guard deviceDetectionRolloutController.decision(
            for: deviceDetectionRolloutState.mode
        ).allowsCriticalActions else {
            return .rejected(
                "当前处于设备检测只读验证阶段，已禁止重新签名和安装。"
            )
        }
        guard canRefreshNow else {
            return .rejected(
                primaryJourneyRefreshDisabledReason
                    ?? "当前条件不允许开始续签。"
            )
        }

        let now = refreshScheduler.wallNow()
        if let reason = manualRefreshPromptReason(at: now),
           profileRefreshMode == nil {
            return .profileChoiceRequired(
                manualRefreshPromptMessage(for: reason)
            )
        }

        cancelManualRefreshProfileChoice()
        let resolvedProfileRefreshMode =
            isConfirmedCurrentTargetAppExpired(at: now)
                ? .force
                : profileRefreshMode ?? .force
        beginRefresh(
            source: .manual,
            profileRefreshMode: resolvedProfileRefreshMode
        )
        return .accepted("已开始续签并安装。")
    }

    private func makeLANControlSnapshot() -> LANControlSnapshot {
        let now = refreshScheduler.wallNow()
        let isOperationActive = deploymentTransaction.hasActiveTask
            || state.isDeployRunning
            || pendingDeployRecoveryTask != nil
            || pendingAutoRefreshCountdown != nil
        let pageState: LANControlPageState
        if isReloadingEnvironment {
            pageState = .checking
        } else if isOperationActive {
            pageState = .progress
        } else {
            let activity = operationActivityPresentation
            switch (activity.source, activity.kind) {
            case (.currentActivity, .failure),
                 (.currentActivity, .warning),
                 (.currentFeedback, .failure),
                 (.currentFeedback, .cancelled):
                pageState = .failure
            case (.currentFeedback, .success):
                pageState = .success
            default:
                if isRemainingExpiryExpired {
                    pageState = .ready
                } else {
                    pageState = environmentStatus.areAllChecksPassing
                        ? .ready
                        : .unavailable
                }
            }
        }

        let appName = normalizedSummaryValue(config.targetName)
            ?? normalizedSummaryValue(config.bundleID)?.split(separator: ".")
                .last.map(String.init)
            ?? "目标 App"
        let deviceName = matchedDevice?.name
            ?? normalizedSummaryValue(config.preferredDeviceName)
            ?? state.currentDeviceName
            ?? "目标 iPhone"
        let deviceStatus = deviceStatusSummary
        let lanControlDeviceStatusTone: LANControlStatusTone = switch deviceStatusTone {
        case .good: .good
        case .warning: .warning
        case .critical: .critical
        case .info: .info
        case .neutral: .neutral
        }
        let expiryDate = expiryInfo?.estimatedExpiryAt
        let signatureStatus: String
        if let expiryDate {
            signatureStatus = expiryDate <= now
                ? "已过期 · \(absoluteDateTimeString(for: expiryDate))"
                : "有效至 \(absoluteDateTimeString(for: expiryDate))"
        } else {
            signatureStatus = "有效期尚未确认"
        }

        let message: String
        switch pageState {
        case .ready:
            message = isRemainingExpiryExpired
                ? "个人签名已过期，续签后即可继续使用。"
                : "可以从此页面重新检查或在符合条件时开始续签。"
        case .checking:
            message = "正在核对设备连接与签名状态。"
        case .progress:
            message = deployProgressText ?? "续签正在进行。"
        case .success:
            message = "目标 App 已完成续签安装。"
        case .failure:
            message = "续签未完成，请在 Mac 上查看完整日志后重试。"
        case .unavailable:
            message = "当前环境尚未准备完成，请先在 Mac 上检查设置。"
        }

        let elapsedSeconds: Int
        if let startedAt = lanControlOperationStartedAt, isOperationActive {
            elapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        } else if pageState == .success || pageState == .failure {
            elapsedSeconds = lanControlLastOperationElapsedSeconds
        } else {
            elapsedSeconds = 0
        }

        return LANControlSnapshot(
            pageState: pageState,
            appName: appName,
            deviceName: deviceName,
            deviceStatus: deviceStatus,
            deviceStatusTone: lanControlDeviceStatusTone,
            signatureStatus: signatureStatus,
            message: message,
            canRenew: pageState == .ready && canRefreshNow,
            canRecheck: !isOperationActive,
            phaseIndex: isOperationActive
                ? (lanControlOperationPhase ?? .verifyingTarget).rawValue
                : nil,
            phases: LANControlOperationPhase.allCases.map(\.title),
            elapsedSeconds: elapsedSeconds,
            expectedExpiryAt: expiryDate,
            checkedAt: state.lastAppInspectionAt
                ?? state.lastDeviceSeenAt
                ?? now
        )
    }

    private static func unavailableLANControlSnapshot() -> LANControlSnapshot {
        LANControlSnapshot(
            pageState: .unavailable,
            appName: "目标 App",
            deviceName: "目标 iPhone",
            deviceStatus: "不可用",
            deviceStatusTone: .neutral,
            signatureStatus: "有效期尚未确认",
            message: "iOSSignKit 当前不可用。",
            canRenew: false,
            canRecheck: false,
            phaseIndex: nil,
            phases: LANControlOperationPhase.allCases.map(\.title),
            elapsedSeconds: 0,
            expectedExpiryAt: nil,
            checkedAt: Date()
        )
    }

    func performStartupRefresh() {
        reloadHistoryAsync()
        refreshDeviceStatus(
            presentation: .foreground,
            mode: preferredBackgroundRefreshMode
        )
    }

    func reloadEnvironment() {
        cancelPendingDeployRecovery(clearProgress: true)
        refreshDeviceStatus(mode: .manualDeepCheck)
    }

    func recheckPendingDeployRecovery() {
        guard pendingDeployRecoveryTask != nil else {
            reloadEnvironment()
            return
        }

        refreshDeviceStatus(mode: .manualDeepCheck)
    }

    private func requestManualPairing() -> PrimaryJourneyActionOutcome {
        guard let reason = primaryJourneyPairingDisabledReason else {
            refreshDeviceStatus(
                presentation: .foreground,
                mode: .manualDeepCheck,
                manualPairingRequested: true
            )
            return .performed
        }

        deployMessage = reason
        return .rejected(reason: reason)
    }

    func startPolling() {
        stopPolling()

        schedulePollingTimer()
    }

    private func schedulePollingTimer() {
        let intervalMinutes = config.backgroundCheckIntervalMinutes(
            isExpired: remainingExpiryPresentation.isExpired
        )
        scheduledPollingIntervalMinutes = intervalMinutes

        let interval = intervalMinutes * 60
        pollingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.deviceRefreshSession.isRunning,
                      !self.isReloadingEnvironment,
                      !self.automaticRefreshCoordinator.isWaiting else {
                    return
                }
                self.refreshDeviceStatus(
                    presentation: .background,
                    mode: self.preferredBackgroundRefreshMode
                )
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        scheduledPollingIntervalMinutes = nil
        connectionConfirmationTask?.cancel()
        connectionConfirmationTask = nil
        installedAppRetryTask?.cancel()
        installedAppRetryTask = nil
    }

    func handleSystemWake() {
        let hadActiveAutomaticWait =
            automaticRefreshCoordinator.isWaiting
        let transition = deviceConnectionReducer.reduce(
            state: deviceConnectionState,
            event: .systemWoke
        )
        deviceConnectionState = transition.state
        passiveObservationGeneration &+= 1
        refreshSessionCaches.invalidate(.systemWake)
        cancelConnectionConfirmation(resetEvidence: true)
        cancelInstalledAppRetry(resetBackoff: false)

        cancelPendingAutoRefresh()
        automaticRefreshCoordinator.observeWake()
        invalidateReminderDelivery()
        cancelPairingTask()
        pendingDeployFailureNotification = nil
        cancelManualRefreshProfileChoice()
        invalidateEnvironmentRefresh()

        if !deploymentTransaction.hasRunningDeployment,
           !state.isDeployRunning,
           deploymentTransaction.hasActiveTask {
            deviceVerificationGeneration &+= 1
            deploymentTransaction.cancelPreflight()
            closeDeployOutputSink(flush: false)
            deployProgressText = nil
        }

        systemWakeRecheckTask?.cancel()
        systemWakeRecheckTask = nil
        if hadActiveAutomaticWait {
            return
        }
        let delay = transition.nextCheckAfter
            ?? refreshTimingPolicy.connectionRetryDelay
        let sleep = refreshScheduler.sleep
        let wakeGeneration = passiveObservationGeneration
        let secondWakeDelay = max(
            refreshTimingPolicy.automaticWaitPolicy.wakeSecondProbeDelay
                - delay,
            .zero
        )
        systemWakeRecheckTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.passiveObservationGeneration == wakeGeneration else {
                return
            }
            if !self.isWakeRecheckBusy {
                self.refreshDeviceStatus(
                    presentation: .background,
                    mode: self.preferredBackgroundRefreshMode
                )
            }

            do {
                try await sleep(secondWakeDelay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.passiveObservationGeneration == wakeGeneration else {
                return
            }
            while self.isWakeRecheckBusy {
                do {
                    try await sleep(.seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.passiveObservationGeneration
                        == wakeGeneration else {
                    return
                }
            }
            self.refreshDeviceStatus(
                presentation: .background,
                mode: self.preferredBackgroundRefreshMode
            )
            self.systemWakeRecheckTask = nil
        }
    }

    private var isWakeRecheckBusy: Bool {
        deploymentTransaction.hasActiveTask
            || state.isDeployRunning
            || deviceRefreshSession.isRunning
            || isReloadingEnvironment
            || pairingTask != nil
            || setupViewModel.isScanningDevices
            || automaticRefreshCoordinator.isWaiting
    }

    func transitionDeviceDetectionRollout(
        to requestedVersion: DeviceDetectionRolloutMode
    ) {
        let hasRunningDeployment = deploymentTransaction.hasRunningDeployment
            || state.isDeployRunning
        let transition = deviceDetectionRolloutController.transition(
            from: deviceDetectionRolloutState,
            to: requestedVersion,
            hasActiveDeployment: hasRunningDeployment
        )
        deferredDeviceDetectionRolloutMode = transition.deferredMode
        guard transition.nextState != deviceDetectionRolloutState else {
            return
        }

        if !hasRunningDeployment, deploymentTransaction.hasActiveTask {
            deviceVerificationGeneration &+= 1
            deploymentTransaction.cancelPreflight()
            closeDeployOutputSink(flush: false)
            deployProgressText = nil
            deployMessage =
                "设备检测策略已切换，本次续签已在续签启动前停止。"
        }

        deviceDetectionRolloutState = transition.nextState
        setupViewModel.transitionDeviceDetectionRollout(
            to: transition.nextState.mode
        )
        if transition.invalidatesSessionCaches {
            refreshSessionCaches.removeAll()
        }
        if transition.resetsConnectionState {
            deviceConnectionState = deviceConnectionReducer.reduce(
                state: deviceConnectionState,
                event: .sessionStarted
            ).state
        }
        if transition.discardsOlderPassiveResults {
            passiveObservationGeneration &+= 1
            invalidateEnvironmentRefresh()
        }
        if !deviceDetectionRolloutController.decision(
            for: deviceDetectionRolloutState.mode
        ).allowsCriticalActions {
            cancelPendingAutoRefresh()
            cancelAutomaticRefreshWait(clearNotificationKeys: false)
            cancelPendingDeployRecovery(clearProgress: true)
            invalidateReminderDelivery()
            cancelPairingTask()
            pendingDeployFailureNotification = nil
        }
    }

    private func invalidateEnvironmentRefresh() {
        deviceRefreshSession.invalidate()
        activeEnvironmentRefreshPresentation = nil
        isReloadingEnvironment = false
        isForegroundEnvironmentCheck = false
        passiveRefreshSequence = nil
    }

    private func applyDeferredDeviceDetectionRolloutIfPossible() {
        guard !deploymentTransaction.hasActiveTask,
              !state.isDeployRunning,
              let deferredMode = deferredDeviceDetectionRolloutMode else {
            return
        }
        deferredDeviceDetectionRolloutMode = nil
        transitionDeviceDetectionRollout(to: deferredMode)
    }

#if DEBUG
    func freezeVisualQAClock(at date: Date) {
        remainingExpiryTimer?.invalidate()
        remainingExpiryTimer = nil
        remainingExpiryNow = date
    }
#endif

    private func restartRemainingExpiryTimer() {
        remainingExpiryNow = Date()
        refreshPollingIntervalForCurrentExpiryState()
        scheduleRemainingExpiryTimer()
    }

    private func refreshPollingIntervalForCurrentExpiryState() {
        guard pollingTimer != nil else {
            return
        }
        let intervalMinutes = config.backgroundCheckIntervalMinutes(
            isExpired: remainingExpiryPresentation.isExpired
        )
        guard scheduledPollingIntervalMinutes != intervalMinutes else {
            return
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
        schedulePollingTimer()
    }

    private func scheduleRemainingExpiryTimer() {
        remainingExpiryTimer?.invalidate()
        remainingExpiryTimer = nil

        guard let interval = remainingExpiryPresentation.nextUpdateInterval else {
            return
        }

        remainingExpiryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleRemainingExpiryTimer()
            }
        }
    }

    private func handleRemainingExpiryTimer() {
        remainingExpiryNow = Date()
        refreshPollingIntervalForCurrentExpiryState()
        scheduleRemainingExpiryTimer()
    }

    func refreshDeviceStatus(
        presentation: EnvironmentRefreshPresentation = .foreground,
        mode: EnvironmentRefreshMode = .manualDeepCheck,
        manualPairingRequested: Bool = false
    ) {
        if automaticRefreshCoordinator.isWaiting {
            if presentation == .foreground {
                automaticRefreshCoordinator.probeNow()
            }
            return
        }
        guard !setupViewModel.isScanningDevices else {
            return
        }
        guard !deploymentTransaction.hasActiveTask,
              !state.isDeployRunning else {
            return
        }
        cancelPendingAutoRefresh()
        cancelPairingTask()

        let resetsRecoveryEvidence = mode == .manualDeepCheck
        cancelConnectionConfirmation(
            resetEvidence: resetsRecoveryEvidence
        )
        cancelInstalledAppRetry(
            resetBackoff: resetsRecoveryEvidence
        )

        let effectiveMode =
            mode == .backgroundPoll
                && isAutomaticRefreshConditionMet
            ? EnvironmentRefreshMode.automaticRecoveryCheck
            : mode
        isReloadingEnvironment = true
        isForegroundEnvironmentCheck = presentation == .foreground
        activeEnvironmentRefreshPresentation = presentation

        if presentation == .foreground {
            clearMenuBarTransientResult()
            deployMessage = "正在检查设备与安装状态…"
        }

        let refreshSequence = deviceRefreshSession.begin()
        manualPairingRefreshSequence = manualPairingRequested
            ? refreshSequence
            : nil
        if pendingDeployFailureNotification?.refreshSequence
            != refreshSequence {
            pendingDeployFailureNotification = nil
        }
        if passiveRefreshSequence != refreshSequence {
            passiveRefreshSequence = nil
        }

        if effectiveMode == .manualDeepCheck {
            refreshSessionCaches.invalidate(.manualDeepCheck)
        }

        var criticalActions: Set<CriticalRefreshAction> = []
        if reminderDecision.shouldPrompt {
            criticalActions.insert(.reminder)
        }
        if isAutomaticRefreshConditionMet {
            criticalActions.insert(.automaticRefreshCountdown)
        }
        if isConnectionRecoveryStatus {
            criticalActions.insert(.wirelessPairing)
        }

        let targetOverride = pendingDeployFailureNotification.map {
            DeviceRefreshTargetOverride(
                deviceID: $0.deviceID,
                deviceName: $0.deviceName
            )
        }
        let request = DeviceRefreshRequest(
            config: config,
            mode: effectiveMode,
            rolloutState: deviceDetectionRolloutState,
            targetGeneration: targetConfigurationGeneration,
            observationGeneration: passiveObservationGeneration,
            sessionCaches: refreshSessionCaches,
            criticalActionCandidates: criticalActions,
            hasKnownExpiry: expiryInfo?.estimatedExpiryAt != nil,
            hasConfirmedInstallation:
                hasConfirmedCurrentTargetAppInstallation,
            lastResult: state.lastResult,
            isDeployRunning: state.isDeployRunning,
            isPassiveRefresh:
                passiveRefreshSequence == refreshSequence,
            targetOverride: targetOverride
        )
        let workflow = deviceRefreshWorkflow
        let comparisonSink = deviceDetectionComparisonSink

        deviceRefreshSession.run(sequence: refreshSequence) {
            [weak self] in
            do {
                let transition = try await workflow.refresh(request)
                guard let self,
                      !Task.isCancelled,
                      self.deviceRefreshSession.isCurrent(
                        refreshSequence
                      ),
                      transition.snapshot.policyGeneration
                        == self.deviceDetectionRolloutState.generation,
                      transition.snapshot.observationGeneration
                        == self.passiveObservationGeneration else {
                    return
                }
                if let sample = transition.comparisonSample {
                    comparisonSink.record(sample)
                }
                self.applyRefreshSnapshot(
                    transition.snapshot,
                    refreshSequence: refreshSequence
                )
            } catch is CancellationError {
                return
            } catch {
                assertionFailure(
                    "DeviceRefreshWorkflow returned an unexpected error: \(error)"
                )
            }
        }
    }
    func refreshDeviceStatus(
        showCheckingMessage: Bool,
        mode: EnvironmentRefreshMode = .manualDeepCheck
    ) {
        refreshDeviceStatus(
            presentation: showCheckingMessage ? .foreground : .background,
            mode: mode
        )
    }

    /// Waits for the refresh work owned by this view model, including work
    /// superseded by a newer refresh, to reach a terminal state.
    func waitForEnvironmentRefreshToSettle() async {
        await deviceRefreshSession.waitUntilSettled()
    }

    func waitForCurrentEnvironmentRefreshToSettle() async {
        await deviceRefreshSession.waitUntilCurrentSettled()
    }

    func waitForDeploymentToSettle() async {
        await deploymentTransaction.waitUntilSettled()
    }

    func waitForDeploymentToStartOrSettle() async {
        await deploymentTransaction.waitUntilRunningOrSettled()
    }

    func waitForPairingToSettle() async {
        await pairingTask?.value
    }

    func waitForAutomaticUnlockNotificationToSettle() async {
        let tasks = Array(automaticUnlockNotificationTasks.values)
        for task in tasks {
            await task.value
        }
    }

    func waitForCurrentAutomaticRefreshWaitProbeToSettle() async {
        await automaticRefreshCoordinator
            .waitUntilCurrentProbeSettled()
    }

    func waitForReminderDeliveryToSettle() async {
        let activeTask = reminderDeliveryTask
        let supersededTasks = Array(
            supersededReminderDeliveryTasks.values
        )
        await activeTask?.value
        for task in supersededTasks {
            await task.value
        }
    }

    /// Cancels and settles the asynchronous refresh work owned by the view
    /// model. Test fixtures and non-App lifecycle hosts use this to prevent
    /// work from escaping its owner.
    func shutdown() async {
        let connectionTask = connectionConfirmationTask
        let wakeTask = systemWakeRecheckTask
        let retryTask = installedAppRetryTask
        let activePairingTask = pairingTask
        let activeReminderDeliveryTask = reminderDeliveryTask
        let supersededReminderTasks = Array(
            supersededReminderDeliveryTasks.values
        )
        let unlockNotificationTasks = Array(
            automaticUnlockNotificationTasks.values
        )
        let backgroundNotificationTasks = Array(
            self.backgroundNotificationTasks.values
        )
        lanControlServer.stop()
        stopPolling()
        cancelPendingAutoRefresh()
        cancelAutomaticRefreshWait(clearNotificationKeys: true)
        cancelConnectionConfirmation(resetEvidence: false)
        cancelInstalledAppRetry(resetBackoff: false)
        systemWakeRecheckTask?.cancel()
        systemWakeRecheckTask = nil
        cancelPairingTask()
        invalidateReminderDelivery()
        supersededReminderTasks.forEach { $0.cancel() }
        unlockNotificationTasks.forEach { $0.cancel() }
        backgroundNotificationTasks.forEach { $0.cancel() }
        await connectionTask?.value
        await wakeTask?.value
        await retryTask?.value
        await activePairingTask?.value
        await activeReminderDeliveryTask?.value
        for task in supersededReminderTasks {
            await task.value
        }
        for task in unlockNotificationTasks {
            await task.value
        }
        for task in backgroundNotificationTasks {
            await task.value
        }
        await deviceRefreshSession.cancelAndWait()
        await deploymentTransaction.waitUntilSettled()
    }

    @discardableResult
    func refreshNow() -> ManualRefreshRequestOutcome {
        guard deviceDetectionRolloutController.decision(
            for: deviceDetectionRolloutState.mode
        ).allowsCriticalActions else {
            deployMessage =
                "当前处于设备检测只读验证阶段，已禁止重新签名和安装。"
            return .rejected
        }
        guard canRefreshNow else {
            deployMessage = "请先选择一台可用的 iPhone。"
            return .rejected
        }

        let now = refreshScheduler.wallNow()
        if let reason = manualRefreshPromptReason(at: now) {
            manualRefreshPromptEvidence = ManualRefreshPromptEvidence(
                installationIdentity: InstallationIdentitySnapshot(state: state),
                estimatedExpiryAt: expiryInfo?.estimatedExpiryAt
            )
            manualRefreshPrompt = ManualRefreshPrompt(
                reason: reason,
                targetGeneration: targetConfigurationGeneration,
                deviceID: matchedDevice?.id ?? ""
            )
            return .profileChoiceRequired
        }

        beginRefresh(
            source: .manual,
            profileRefreshMode: .force
        )
        return .deploymentRequested
    }

    var manualRefreshPromptMessage: String {
        guard let manualRefreshPrompt else {
            return ""
        }

        return manualRefreshPromptMessage(for: manualRefreshPrompt.reason)
    }

    private func manualRefreshPromptMessage(
        for reason: ManualRefreshPromptReason
    ) -> String {
        switch reason {
        case .notExpired(let expiryAt):
            return """
            当前 App 预计于 \(absoluteDateTimeString(for: expiryAt)) 到期。更新签名描述文件通常会获得新的个人签名有效期；优先复用现有描述文件只会重新签名并安装，不保证延长到期时间。
            """
        case .expiryUnknown:
            return """
            当前无法确认 App 的到期时间。更新签名描述文件更适合续期；优先复用现有描述文件不保证延长有效期。
            """
        case .installationUnconfirmed:
            return """
            当前尚未确认目标 App 的安装状态。更新签名描述文件更适合续期；优先复用现有描述文件不保证延长有效期。
            """
        case .appNotInstalled:
            return """
            已确认目标 App 尚未安装。本次操作将重新签名并安装；更新签名描述文件通常会获得新的有效期，优先复用现有描述文件不保证获得新的 7 天。
            """
        }
    }

    func confirmManualRefresh(
        profileRefreshMode: ProvisioningProfileRefreshMode
    ) {
        guard let prompt = manualRefreshPrompt else {
            return
        }
        let promptEvidence = manualRefreshPromptEvidence
        manualRefreshPrompt = nil
        manualRefreshPromptEvidence = nil

        guard prompt.targetGeneration == targetConfigurationGeneration,
              matchedDevice?.id == prompt.deviceID else {
            deployMessage = "目标配置或设备已变更，请重新选择“立即续签”。"
            return
        }
        guard canRefreshNow else {
            deployMessage = "续签条件已变化，请确认目标 iPhone 可用后重试。"
            return
        }
        guard let promptEvidence,
              promptEvidence == currentManualRefreshPromptEvidence else {
            deployMessage = "设备或安装状态已变化，请重新选择“立即续签”。"
            return
        }

        let resolvedProfileRefreshMode =
            isConfirmedCurrentTargetAppExpired(
                at: refreshScheduler.wallNow()
            )
                ? .force
                : profileRefreshMode
        beginRefresh(
            source: .manual,
            profileRefreshMode: resolvedProfileRefreshMode
        )
    }

    func cancelManualRefreshProfileChoice() {
        manualRefreshPrompt = nil
        manualRefreshPromptEvidence = nil
    }

    func beginRefresh(
        source: RefreshTriggerSource,
        profileRefreshMode: ProvisioningProfileRefreshMode
    ) {
        let policyDecision = deviceDetectionRolloutController.decision(
            for: deviceDetectionRolloutState.mode
        )
        guard policyDecision.allowsCriticalActions else {
            deployMessage =
                "当前处于设备检测只读验证阶段，已禁止重新签名和安装。"
            return
        }
        menuBarCurrentIssue = nil
        clearMenuBarTransientResult()
        if source != .automaticRecovery {
            cancelPendingDeployRecovery()
        }
        cancelPendingAutoRefresh()

        guard canRefreshNow, let matchedDevice else {
            deployMessage = "请先选择一台可用的 iPhone。"
            return
        }
        if source.isAutomatic {
            recordAutomaticRefreshEvent(.preflightStarted)
        }

        let config = self.config
        guard let expectedStableDeviceID = StableDeviceID(
            matchedDevice.id
        ) else {
            deployMessage = DeploymentTargetError.invalidDeviceIdentity
                .localizedDescription
            return
        }
        let deploymentPolicyState = deviceDetectionRolloutState
        let preflightTargetStrategy: DeploymentPreflightTargetStrategy
        if deploymentPolicyState.mode == .production {
            guard let configuredDeviceID =
                    normalizedSummaryValue(config.preferredDeviceID),
                  configuredDeviceID == expectedStableDeviceID.value else {
                deployMessage =
                    "续签前核验要求先固定目标设备 ID；请在项目配置中重新选择目标 iPhone。"
                return
            }
            preflightTargetStrategy = .canonical(
                .stableID(
                    expectedStableDeviceID,
                    displayName: matchedDevice.name
                )
            )
        } else {
            preflightTargetStrategy = .compatibility
        }

        if deploymentPolicyState.mode != .production {
            do {
                _ = try CompatibilityDeploymentTarget(
                        device: matchedDevice,
                        availableDevices: availableDevices
                )
            } catch {
                deployMessage = error.localizedDescription
                return
            }
        }

        let previousExpiry = expiryInfo?.estimatedExpiryAt
        lanControlOperationStartedAt = refreshScheduler.wallNow()
        lanControlOperationPhase = .verifyingTarget
        lanControlLastOperationElapsedSeconds = 0
        invalidateEnvironmentRefreshForDeployment()
        deployLogText = ""
        deployProgressText = profileRefreshProgressText(
            for: profileRefreshMode
        )
        resetDeployLogBuffer()

        let deploymentContext = DeploymentContext(
            generation: targetConfigurationGeneration,
            config: config,
            device: matchedDevice,
            deviceDetectionRollout: deploymentPolicyState,
            source: source,
            profileRefreshMode: profileRefreshMode,
            installationIdentity: InstallationIdentitySnapshot(state: state)
        )
        let deploymentDeviceVerificationGeneration =
            deviceVerificationGeneration
        let preflightWorkflow = deploymentPreflightWorkflow
        let device = matchedDevice
        let outputSink = DeployOutputSink { [weak self] text, isError in
            self?.enqueueDeployOutput(text, isError: isError)
        }
        deployOutputSink = outputSink
        let outputHandler: @Sendable (String, Bool) -> Void = { [weak self] text, isError in
            outputSink.enqueue(text, isError: isError)
            Task { @MainActor [weak self] in
                self?.observeLANControlDeployOutput(text)
            }
        }

        deploymentTransaction.begin(
            isAutomatic: source.isAutomatic
        ) { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                applyDeferredDeviceDetectionRolloutIfPossible()
            }
            do {
                let preflightOutcome = try await preflightWorkflow.run(
                    .init(
                        context: deploymentContext,
                        expectedDeviceID: expectedStableDeviceID,
                        targetStrategy: preflightTargetStrategy
                    ),
                    callbacks: .init(
                        isCurrent: { [weak self] in
                            guard let self else {
                                return false
                            }
                            return deploymentContext.generation
                                    == self.targetConfigurationGeneration
                                && deploymentDeviceVerificationGeneration
                                    == self.deviceVerificationGeneration
                        },
                        verifyAutomaticInstallation: {
                            [weak self] context, device in
                            guard let self else {
                                return false
                            }
                            return await self
                                .inspectAndRecordAutomaticInstallationIdentity(
                                    context: context,
                                    device: device
                                )
                        },
                        isAutomaticRefreshEligible: { [weak self] in
                            self?.isAutomaticRefreshConditionMet == true
                        },
                        reportProgress: { [weak self] progress in
                            self?.applyDeploymentPreflightProgress(progress)
                        }
                    )
                )
                let deploymentTarget: DeploymentStartTarget
                switch preflightOutcome {
                case .ready(let target):
                    deploymentTarget = target
                case .deviceLocked(let lockedDevice):
                    handleLockedDeviceBeforeDeploy(
                        device: lockedDevice,
                        context: deploymentContext
                    )
                    return
                case .lockStateUnknown(
                    let unknownDevice,
                    let failure
                ):
                    handleUnknownLockStateBeforeDeploy(
                        device: unknownDevice,
                        context: deploymentContext,
                        failure: failure
                    )
                    return
                case .destinationBlocked(
                    let blockedDevice,
                    let readiness
                ):
                    _ = handleDestinationReadiness(
                        readiness,
                        device: blockedDevice,
                        context: deploymentContext
                    )
                    return
                case .automaticInstallationChanged:
                    stopDeployPreflight(
                        message: "自动续期前无法确认原 App 安装实例，本次续签已停止。",
                        progress: "自动续期已停止",
                        menuBarIssue: .refreshPreflightFailed,
                        notification: nil
                    )
                    return
                }
                let committedStart = try commitVerifiedDeploymentStart(
                    target: deploymentTarget,
                    expectedDeviceID: expectedStableDeviceID,
                    context: deploymentContext,
                    expectedDeviceVerificationGeneration:
                        deploymentDeviceVerificationGeneration,
                    expectedPolicyGeneration:
                        deploymentPolicyState.generation,
                    outputHandler: outputHandler
                )
                let deployment = committedStart.deployment
                deploymentTransaction.markRunning(
                    deployment,
                    context: deploymentContext
                )
                lanControlOperationPhase = .signingAndBuilding
                do {
                    try recordActiveDeploymentProcess(deployment)
                } catch {
                    let shutdownOutcome = await deployment.shutdownAsync()
                    switch shutdownOutcome {
                    case .processUnresolved:
                        state.activeDeployProcessGroupID =
                            deployment.processGroupIdentifier
                        state.activeDeploymentToken =
                            deployment.deploymentToken
                        markUnresolvedDeploymentForRecovery()
                        deploymentTransaction.settle()
                        return
                    case .settled(let result)
                        where !result.processGroupTerminationWasConfirmed:
                        state.activeDeployProcessGroupID =
                            deployment.processGroupIdentifier
                        state.activeDeploymentToken =
                            deployment.deploymentToken
                        markUnresolvedDeploymentForRecovery(
                            logPath: result.logPath
                        )
                        deploymentTransaction.settle()
                        return
                    case .settled, .processTerminatedResultPending:
                        break
                    }
                    throw error
                }
                let result = await deployment.result()
                guard !hasPreparedForTermination else {
                    return
                }
                await handleDeployResult(
                    result,
                    context: deploymentContext,
                    previousExpiry: previousExpiry
                )
            } catch is CancellationError {
                guard deploymentContext.generation
                        == targetConfigurationGeneration,
                      deploymentDeviceVerificationGeneration
                        == deviceVerificationGeneration else {
                    return
                }
                closeDeployOutputSink(flush: false)
                deployProgressText = nil
                deploymentTransaction.clearPreflight()
                if !hasPreparedForTermination {
                    let message = source.isAutomatic
                            && self.config.autoRefreshPolicy == .reminderOnly
                        ? "提醒策略已变更，本次自动续期已在续签前停止。"
                        : "已取消本次续签。"
                    publishOperationFeedback(message, result: .cancelled)
                }
            } catch {
                guard !hasPreparedForTermination else {
                    return
                }
                guard deploymentContext.generation
                        == targetConfigurationGeneration,
                      deploymentDeviceVerificationGeneration
                        == deviceVerificationGeneration else {
                    return
                }
                handleDeployError(
                    error,
                    device: device,
                    context: deploymentContext
                )
            }
        }
    }

    private func commitVerifiedDeploymentStart(
        target: DeploymentStartTarget,
        expectedDeviceID: StableDeviceID,
        context: DeploymentContext,
        expectedDeviceVerificationGeneration: Int,
        expectedPolicyGeneration: UInt64,
        outputHandler: @escaping @Sendable (String, Bool) -> Void
    ) throws -> CommittedDeploymentStart {
        try Task.checkCancellation()
        guard context.generation == targetConfigurationGeneration,
              expectedDeviceVerificationGeneration
                == deviceVerificationGeneration,
              expectedPolicyGeneration
                == deviceDetectionRolloutState.generation,
              context.config == config,
              target.isAuthorized(
                for: context.deviceDetectionRollout.mode
              ),
              target.device.id == expectedDeviceID.value else {
            throw CancellationError()
        }
        if context.source.isAutomatic {
            guard isAutomaticRefreshConditionMet else {
                throw CancellationError()
            }
        }

        refreshSessionCaches.invalidate(
            .deployment(
                .started,
                target: cacheKeys(
                    for: context.config,
                    deviceID: target.device.id,
                    targetGeneration: context.generation
                )
            )
        )
        let deploymentToken = DeploymentToken.make().rawValue
        try markDeployRunning(
            deploymentToken: deploymentToken,
            source: context.source
        )
        deployProgressText = profileRefreshProgressText(
            for: context.profileRefreshMode
        )
        deployMessage = context.profileRefreshMode == .force
            ? "正在更新签名描述文件并重新安装到 \(target.device.name)…"
            : "正在优先复用现有签名描述文件并重新安装到 \(target.device.name)…"
        let deployment = try startDeploy(
            context.config,
            target,
            deploymentToken,
            context.profileRefreshMode,
            outputHandler
        )
        deployment.setHistoryTrigger(
            context.source.isAutomatic ? .automatic : .manual
        )
        return CommittedDeploymentStart(
            deployment: deployment
        )
    }

    private func invalidateEnvironmentRefreshForDeployment() {
        invalidateEnvironmentRefresh()
        connectionConfirmationTask?.cancel()
        connectionConfirmationTask = nil
        installedAppRetryTask?.cancel()
        installedAppRetryTask = nil
        cancelPairingTask()
    }

    func cancelRefresh() {
        if pendingDeployRecoveryTask != nil {
            cancelPendingDeployRecovery()
            deployProgressText = nil
            publishOperationFeedback(
                "已取消自动恢复重试。",
                result: .cancelled
            )
            return
        }
        guard deploymentTransaction.hasActiveTask else {
            return
        }

        deployProgressText = "正在停止续签…"
        deployMessage = "正在停止当前续签流程…"
        deploymentTransaction.requestCancellation()
    }

    private func markDeployRunning(
        deploymentToken: String,
        source: RefreshTriggerSource
    ) throws {
        try commitStateEvents([
            .deploymentStarted(
                token: deploymentToken,
                source: source,
                startedAt: Date()
            )
        ])
        if source.isAutomatic {
            logAutomaticRefreshEvent(.deploymentCommitted)
        }
    }

    private func recordActiveDeploymentProcess(_ deployment: RunningDeploy) throws {
        try commitStateEvents([
            .deploymentProcessRecorded(
                processGroupID: deployment.processGroupIdentifier,
                token: deployment.deploymentToken
            )
        ])
    }

    private func applyDeploymentPreflightProgress(
        _ progress: DeploymentPreflightProgress
    ) {
        switch progress {
        case .confirmingDestination, .manualDestinationUnknown:
            lanControlOperationPhase = .confirmingDestination
        case .preparing:
            lanControlOperationPhase = .preparingSigning
        case .confirmingDevice,
             .confirmingLockState,
             .manualLockStateUnknown,
             .verifyingInstallation,
             .finalDeviceVerification,
             .finalUnlockConfirmation:
            lanControlOperationPhase = .verifyingTarget
        }
        switch progress {
        case .confirmingDevice:
            deployProgressText = "正在最终确认目标 iPhone…"
        case .confirmingLockState:
            deployProgressText = "正在确认 iPhone 锁屏状态…"
        case .manualLockStateUnknown(let deviceName, let failure):
            deployMessage =
                "无法确认 \(deviceName) 的锁屏状态："
                + "\(failure.localizedDescription)将继续手动续签…"
            deployProgressText = "无法确认锁屏状态，继续手动续签…"
        case .preparing:
            deployProgressText = "准备开始续签…"
        case .confirmingDestination:
            deployProgressText = "正在确认 Xcode destination…"
        case .manualDestinationUnknown(let diagnostic):
            deployMessage =
                "无法确认 Xcode destination 状态，继续手动续签：\(diagnostic)"
            deployProgressText = "无法确认 destination，继续手动续签…"
        case .verifyingInstallation:
            deployProgressText = "正在最终确认目标 App 安装实例…"
        case .finalDeviceVerification:
            deployProgressText = "正在执行续签启动前的最终设备核验…"
        case .finalUnlockConfirmation:
            deployProgressText = "正在提交前再次确认 iPhone 已解锁…"
        }
    }

    private func observeLANControlDeployOutput(_ text: String) {
        guard lanControlOperationPhase == .signingAndBuilding else {
            return
        }
        let normalized = text.lowercased()
        let installationMarkers = [
            "installing application",
            "device install app",
            "install app",
            "deploying to",
            "正在安装",
            "开始安装",
            "安装到"
        ]
        if installationMarkers.contains(where: normalized.contains) {
            lanControlOperationPhase = .installing
        }
    }

    private func finishLANControlOperation(at date: Date) {
        if let startedAt = lanControlOperationStartedAt {
            lanControlLastOperationElapsedSeconds = max(
                0,
                Int(date.timeIntervalSince(startedAt))
            )
        }
        lanControlOperationPhase = nil
        lanControlOperationStartedAt = nil
    }

    private func handleLockedDeviceBeforeDeploy(
        device: DeviceInfo,
        context: DeploymentContext
    ) {
        let source = context.source
        let message = source.isAutomatic
            ? "请保持 iPhone 解锁，iOSSignKit 将自动继续检查并续签。"
            : "请解锁 iPhone 后再续签。"
        deployProgressText = source.isAutomatic ? "等待 iPhone 解锁" : nil
        deployMessage = message
        closeDeployOutputSink(flush: false)
        deploymentTransaction.clearPreflight()
        menuBarCurrentIssue = .waitingForUnlock

        if source.isAutomatic {
            scheduleAutomaticRefreshWait(
                blocker: .deviceLocked,
                device: device,
                context: context
            )
        } else {
            deliverBackgroundNotification(
                .manualRefreshBlockedByLock(deviceName: device.name)
            )
        }
    }

    private func handleUnknownLockStateBeforeDeploy(
        device: DeviceInfo,
        context: DeploymentContext,
        failure: DeviceLockStateInspectionFailure
    ) {
        guard failure.isTransient else {
            stopAutomaticRefreshForLockInspectionFailure(failure)
            return
        }
        deployMessage =
            "暂时无法确认 iPhone 是否已解锁："
            + "\(failure.localizedDescription)iOSSignKit 将自动继续检查。"
        deployProgressText = "等待确认 iPhone 已解锁"
        closeDeployOutputSink(flush: false)
        deploymentTransaction.clearPreflight()
        menuBarCurrentIssue = .waitingForUnlock
        scheduleAutomaticRefreshWait(
            blocker: .lockStateUnknown,
            device: device,
            context: context
        )
    }

    private func stopAutomaticRefreshForLockInspectionFailure(
        _ failure: DeviceLockStateInspectionFailure
    ) {
        let message = "自动续期已停止：\(failure.localizedDescription)"
        stopDeployPreflight(
            message: message,
            progress: "自动续期已跳过",
            menuBarIssue: .refreshPreflightFailed,
            notification: .refreshFailed(summary: message)
        )
    }

    private func handleDestinationReadiness(
        _ readiness: XcodeDestinationReadiness,
        device: DeviceInfo,
        context: DeploymentContext
    ) -> Bool {
        let source = context.source
        switch readiness {
        case .ready:
            deployProgressText = "准备开始续签…"
            return true
        case .unknown(let diagnostic) where source == .manual:
            deployMessage = "无法确认 Xcode destination 状态，继续手动续签：\(diagnostic)"
            deployProgressText = "无法确认 destination，继续手动续签…"
            return true
        case .requiresUnlock(let diagnostic):
            stopDeployPreflight(
                message: source.isAutomatic
                    ? "请保持 iPhone 解锁，iOSSignKit 将等待 Xcode 完成设备准备后自动续期：\(diagnostic)"
                    : "请解锁 iPhone 并等待 Xcode 完成设备准备后再续签：\(diagnostic)",
                progress: source.isAutomatic ? "等待 Xcode 完成设备准备" : nil,
                menuBarIssue: .waitingForUnlock,
                notification: nil
            )
            if source.isAutomatic {
                scheduleAutomaticRefreshWait(
                    blocker: .destinationPreparation,
                    device: device,
                    context: context
                )
            }
            return false
        case .unavailable(let diagnostic):
            let prefix = source.isAutomatic
                ? "自动续期已停止"
                : "续签已停止"
            let message = "\(prefix)：Xcode destination 尚不可用：\(diagnostic)"
            stopDeployPreflight(
                message: message,
                progress: source.isAutomatic ? "自动续期已跳过" : nil,
                menuBarIssue: .refreshPreflightFailed,
                notification: .refreshFailed(summary: message)
            )
            return false
        case .unknown(let diagnostic):
            let message = "自动续期已停止：无法安全确认 Xcode destination 状态：\(diagnostic)"
            stopDeployPreflight(
                message: message,
                progress: "自动续期已跳过",
                menuBarIssue: .refreshPreflightFailed,
                notification: .refreshFailed(summary: message)
            )
            return false
        }
    }

    private func scheduleAutomaticRefreshWait(
        blocker: AutomaticRefreshWaitBlocker,
        device: DeviceInfo,
        context: DeploymentContext
    ) {
        guard let key = automaticRefreshWaitKey(
            device: device,
            context: context
        ) else {
            return
        }
        let started = automaticRefreshCoordinator.wait(
            key: key,
            blocker: blocker,
            probe: { [weak self] in
                guard let self else {
                    return .cancel
                }
                guard self.isAutomaticWaitContextCurrent(
                    key: key,
                    context: context
                ) else {
                    return .cancel
                }
                guard self.canRefreshNow else {
                    return .stillWaiting(blocker)
                }
                if blocker == .destinationPreparation {
                    return .resume
                }

                let lockObservation = await self.deviceLockStateInspector
                    .inspectObservation(device: device)
                guard self.isAutomaticWaitContextCurrent(
                    key: key,
                    context: context
                ) else {
                    return .cancel
                }
                switch lockObservation.state {
                case .locked:
                    return .stillWaiting(.deviceLocked)
                case .unknown:
                    let failure = lockObservation.failure
                        ?? .malformedOutput
                    guard failure.isTransient else {
                        self.stopAutomaticRefreshForLockInspectionFailure(
                            failure
                        )
                        return .cancel
                    }
                    return .stillWaiting(.lockStateUnknown)
                case .unlocked:
                    return .resume
                }
            },
            resume: { [weak self] in
                guard let self,
                      self.isAutomaticWaitContextCurrent(
                        key: key,
                        context: context
                      ),
                      self.canRefreshNow else {
                    return false
                }
                self.beginRefresh(
                    source: context.source,
                    profileRefreshMode: context.profileRefreshMode
                )
                return true
            },
            transition: { [weak self] transition in
                self?.recordAutomaticWaitTransition(transition)
            }
        )
        guard started else {
            return
        }
        deliverAutomaticUnlockNotificationOnce(
            deviceName: device.name,
            key: key,
            context: context
        )
    }

    private func automaticRefreshWaitKey(
        device: DeviceInfo,
        context: DeploymentContext
    ) -> AutomaticRefreshWaitKey? {
        guard let bundleID = normalizedSummaryValue(context.config.bundleID)
        else {
            return nil
        }
        return AutomaticRefreshWaitKey(
            targetGeneration: context.generation,
            deviceID: device.id,
            bundleID: bundleID,
            installationIdentity: context.installationIdentity,
            source: context.source
        )
    }

    private func isAutomaticWaitContextCurrent(
        key: AutomaticRefreshWaitKey,
        context: DeploymentContext
    ) -> Bool {
        guard context.source.isAutomatic,
              context.generation == targetConfigurationGeneration,
              context.config == config,
              config.autoRefreshPolicy == .autoRefreshWhenExpired,
              matchedDevice?.id == key.deviceID,
              InstallationIdentitySnapshot(state: state)
                == context.installationIdentity,
              isAutomaticRefreshConditionMet else {
            return false
        }
        return true
    }

    private func deliverBackgroundNotification(
        _ notification: AppNotification
    ) {
        let identifier = UUID()
        let task = Task { @MainActor [weak self, notificationService] in
            defer {
                self?.backgroundNotificationTasks.removeValue(
                    forKey: identifier
                )
            }
            _ = await notificationService.send(notification)
        }
        backgroundNotificationTasks[identifier] = task
    }

    private func deliverAutomaticUnlockNotificationOnce(
        deviceName: String,
        key: AutomaticRefreshWaitKey,
        context: DeploymentContext
    ) {
        guard context.source != .automaticRecovery,
              automaticWaitNotifiedKeys.insert(key).inserted else {
            return
        }
        let identifier = UUID()
        let task = Task { @MainActor [weak self, notificationService] in
            defer {
                self?.automaticUnlockNotificationTasks.removeValue(
                    forKey: identifier
                )
            }
            let result = await notificationService.send(
                .automaticRefreshWaitingForUnlock(
                    deviceName: deviceName
                )
            )
            guard let self,
                  self.targetConfigurationGeneration
                    == context.generation,
                  self.config == context.config,
                  self.automaticWaitNotifiedKeys.contains(key) else {
                return
            }
            switch result {
            case .scheduled:
                self.recordAutomaticRefreshEvent(
                    .notificationScheduled
                )
            case .denied:
                self.recordAutomaticRefreshEvent(.notificationDenied)
                if self.automaticRefreshCoordinator.isWaiting {
                    self.deployMessage =
                        "\(self.deployMessage ?? "正在等待 iPhone 解锁。") 系统通知未获授权，请留意菜单栏状态。"
                }
            case .failed(let reason):
                self.recordAutomaticRefreshEvent(.notificationFailed)
                if self.automaticRefreshCoordinator.isWaiting {
                    self.deployMessage =
                        "\(self.deployMessage ?? "正在等待 iPhone 解锁。") 系统通知发送失败：\(reason)"
                }
            }
        }
        automaticUnlockNotificationTasks[identifier] = task
    }

    private func recordAutomaticWaitTransition(
        _ transition: AutomaticRefreshWaitTransition
    ) {
        let eventKind: AutomaticRefreshEventKind
        switch transition {
        case .waitingLocked:
            eventKind = .waitingLocked
        case .waitingForLockState:
            eventKind = .waitingForLockState
        case .waitingForDestination:
            eventKind = .waitingForDestination
        case .wakeObserved:
            eventKind = .wakeObserved
        case .unlockObserved:
            eventKind = .unlockObserved
        case .preflightDeferred:
            eventKind = .preflightDeferred
        case .resumed:
            eventKind = .resumed
        case .cancelled:
            eventKind = .cancelled
        }
        recordAutomaticRefreshEvent(eventKind)
        guard transition != .waitingLocked
                || deployProgressText != "等待 iPhone 解锁" else {
            return
        }
        switch transition {
        case .waitingLocked:
            deployProgressText = "等待 iPhone 解锁"
        case .waitingForLockState:
            deployProgressText = "等待确认 iPhone 已解锁"
        case .waitingForDestination:
            deployProgressText = "等待 Xcode 完成设备准备"
        case .wakeObserved:
            deployProgressText = "Mac 已唤醒，即将重新检查 iPhone"
        case .unlockObserved:
            deployProgressText = "检测到 iPhone 已解锁"
        case .preflightDeferred:
            deployProgressText = "系统正忙，稍后继续自动续期"
        case .resumed:
            deployProgressText = "正在恢复自动续期"
        case .cancelled:
            break
        }
    }

    private func cancelAutomaticRefreshWait(
        clearNotificationKeys: Bool
    ) {
        automaticRefreshCoordinator.cancelWait()
        if clearNotificationKeys {
            automaticWaitNotifiedKeys.removeAll(keepingCapacity: true)
        }
    }

    private func recordAutomaticRefreshEvent(
        _ kind: AutomaticRefreshEventKind
    ) {
        var updatedState = state
        guard appendAutomaticRefreshEvent(kind, to: &updatedState) else {
            return
        }
        defer { logAutomaticRefreshEvent(kind) }
        do {
            try stateStore.saveState(updatedState)
            state = updatedState
        } catch {
            // Diagnostics are best effort and must never authorize or block
            // deployment. Operational state writes keep their stricter path.
        }
    }

    @discardableResult
    private func appendAutomaticRefreshEvent(
        _ kind: AutomaticRefreshEventKind,
        to state: inout AppState
    ) -> Bool {
        guard state.automaticRefreshEvents.last?.kind != kind else {
            return false
        }
        state.appendAutomaticRefreshEvent(kind)
        return true
    }

    private func logAutomaticRefreshEvent(
        _ kind: AutomaticRefreshEventKind
    ) {
        Self.automaticRefreshLogger.info(
            "automatic refresh event: \(kind.rawValue, privacy: .public)"
        )
    }

    private func stopDeployPreflight(
        message: String,
        progress: String?,
        menuBarIssue: MenuBarCurrentIssue,
        notification: AppNotification?
    ) {
        deployMessage = message
        deployProgressText = progress
        closeDeployOutputSink(flush: false)
        deploymentTransaction.clearPreflight()
        menuBarCurrentIssue = menuBarIssue
        if let notification {
            deliverBackgroundNotification(notification)
        }
    }

    private func handleSavedConfig(_ config: AppConfig) {
        if self.config != config {
            targetConfigurationGeneration += 1
            cancelAutomaticRefreshWait(clearNotificationKeys: true)
            deviceConnectionState = deviceConnectionReducer.reduce(
                state: deviceConnectionState,
                event: .targetChanged
            ).state
            hasConfirmedTargetDeviceThisSession = false
            cancelManualRefreshProfileChoice()
            cancelReminderDeliveryForTargetChange()
            cancelDeployPreflightForTargetChange()
        }
        let didChangeTargetApp = normalizedSummaryValue(self.config.bundleID)
            != normalizedSummaryValue(config.bundleID)
        self.config = config
        refreshSessionCaches.invalidate(
            .targetChanged(
                retaining: cacheKeys(
                    for: config,
                    deviceID: config.preferredDeviceID
                )
            )
        )
        if didChangeTargetApp {
            invalidatePersistedTargetAppEvidence()
        }
        self.launchAtLoginEnabled = config.startAtLogin
        syncLaunchAtLoginFromConfig()
        reloadEnvironment()
        startPolling()
    }

    private func handleSavedSettings(_ savedConfig: AppConfig) {
        let didChangeDevice =
            normalizedSummaryValue(config.preferredDeviceID)
                != normalizedSummaryValue(savedConfig.preferredDeviceID)
            || normalizedSummaryValue(config.preferredDeviceName)
                != normalizedSummaryValue(savedConfig.preferredDeviceName)
        let didChangeReminderSettings =
            config.checkIntervalMinutes != savedConfig.checkIntervalMinutes
            || config.expiredCheckIntervalMinutes
                != savedConfig.expiredCheckIntervalMinutes
            || config.reminderCooldownHours
                != savedConfig.reminderCooldownHours
            || config.autoRefreshPolicy != savedConfig.autoRefreshPolicy
        let didChangeProject =
            config.projectRootPath != savedConfig.projectRootPath
            || config.xcodeprojPath != savedConfig.xcodeprojPath
            || config.scheme != savedConfig.scheme
            || config.targetName != savedConfig.targetName
            || config.bundleID != savedConfig.bundleID
            || config.applicationTargetResolutionSchemaVersion
                != savedConfig.applicationTargetResolutionSchemaVersion
        let didChangeLANControl =
            config.lanControl != savedConfig.lanControl

        if didChangeDevice {
            handleSavedDeviceSelection(savedConfig)
        }
        if didChangeReminderSettings {
            handleSavedReminderSettings(savedConfig)
        }
        if didChangeProject {
            handleSavedConfig(savedConfig)
        }
        if didChangeLANControl {
            config.lanControl = savedConfig.lanControl
            lanControlServer.apply(savedConfig.lanControl)
        }
    }

    private func invalidatePersistedTargetAppEvidence() {
        cancelPendingDeployRecovery(clearProgress: true)
        cancelAutomaticRefreshWait(clearNotificationKeys: true)
        do {
            try commitStateEvents([.targetEvidenceInvalidated])
        } catch {
            enterStatePersistenceFailure(error)
        }
        installedAppInfo = nil
        installedAppInspectionFailure = nil
        expiryInfo = nil
        consecutiveInstalledAppAbsences = 0
        cancelInstalledAppRetry(resetBackoff: true)
        cancelPendingAutoRefresh()
    }

    private func handleSavedReminderSettings(_ savedConfig: AppConfig) {
        let didCheckIntervalChange =
            config.checkIntervalMinutes != savedConfig.checkIntervalMinutes
            || config.expiredCheckIntervalMinutes
                != savedConfig.expiredCheckIntervalMinutes
        let didPolicyChange = config.autoRefreshPolicy != savedConfig.autoRefreshPolicy

        config.checkIntervalMinutes = savedConfig.checkIntervalMinutes
        config.expiredCheckIntervalMinutes =
            savedConfig.expiredCheckIntervalMinutes
        config.reminderCooldownHours = savedConfig.reminderCooldownHours
        config.autoRefreshPolicy = savedConfig.autoRefreshPolicy

        if didPolicyChange {
            cancelReminderDeliveryForTargetChange()
            if savedConfig.autoRefreshPolicy == .reminderOnly {
                cancelAutomaticRefreshWait(clearNotificationKeys: true)
            }
            if cancelPendingDeployRecovery(clearProgress: true) {
                deployMessage = "提醒策略已变更，自动恢复重试已停止。"
            }
            if savedConfig.autoRefreshPolicy == .reminderOnly,
               deploymentTransaction.isAutomaticPreflight,
               deploymentTransaction.hasActiveTask,
               !deploymentTransaction.hasRunningDeployment {
                deploymentTransaction.requestPreflightCancellation()
                closeDeployOutputSink(flush: false)
                deployProgressText = nil
                deployMessage =
                    "提醒策略已变更，本次自动续期已在续签前停止。"
            }
        }

        if didCheckIntervalChange {
            startPolling()
        }

        expiryInfo = inspectVerifiedExpiry()
        restartRemainingExpiryTimer()

        if state.currentDeviceStatus == .confirming {
            reminderDecision = ReminderDecision(
                shouldPrompt: false,
                reason: "正在重新确认目标设备连接。",
                nextEligibleAt: nil
            )
        } else {
            reminderDecision = reminderPolicy.evaluate(
                config: config,
                state: state,
                matchedDevice: matchedDevice,
                installedAppInfo: installedAppInfo,
                expiryInfo: expiryInfo,
                hasConfirmedInstallation: hasConfirmedCurrentTargetAppInstallation
            )
        }

        attemptAutomaticRefreshIfNeeded()
    }

    private func handleSetupDeviceScanStarted() {
        invalidateForSetupDeviceScan(
            preflightCancellationMessage:
                "目标设备正在重新核验，本次续签已在续签前停止。"
        )
        clearMenuBarTransientResult()
        isForegroundEnvironmentCheck = true
    }

    private func handleSetupDeviceScan(scanResult: DeviceScanResult?, matchedDevice: DeviceInfo?, errorMessage: String?) {
        invalidateForSetupDeviceScan(
            preflightCancellationMessage:
                "目标设备核验结果已更新，本次续签已在续签前停止。"
        )
        isForegroundEnvironmentCheck = false

        let devices = scanResult?.devices ?? []
        availableDevices = devices
        self.matchedDevice = matchedDevice

        if let errorMessage {
            reminderDecision = ReminderDecision(shouldPrompt: false, reason: errorMessage, nextEligibleAt: nil)
            persistState(status: .scanFailed, device: nil, scanFailure: errorMessage)
            return
        }

        if scanResult?.hasAvailabilityConflict(
            preferredDeviceID: config.preferredDeviceID,
            preferredDeviceName: config.preferredDeviceName
        ) == true {
            cancelConnectionConfirmation(resetEvidence: true)
            updateStateFromMatch(
                recordPrompt: false,
                attemptAutomaticRefresh: false,
                connectionStatus: .scanFailed,
                scanResult: scanResult
            )
            return
        }

        if matchedDevice == nil,
           let scanResult,
           !scanResult.isCompleteInventory {
            cancelConnectionConfirmation(resetEvidence: false)
            updateStateFromMatch(
                recordPrompt: false,
                attemptAutomaticRefresh: false,
                connectionStatus: .scanFailed,
                scanResult: scanResult
            )
            return
        }

        let now = refreshScheduler.wallNow()
        let lastSeenAt = self.matchedDevice != nil || state.currentDeviceStatus == .online
            ? now
            : (state.currentDeviceStatus == .offline ? nil : state.lastDeviceSeenAt)
        let evidence: DeviceConnectionEvidence
        if matchedDevice == nil {
            evidence = .targetAbsent
            confirmedDeviceAbsenceCount += 1
            if lastSeenAt != nil, connectionConfirmationStartedAt == nil {
                connectionConfirmationStartedAt = now
            }
        } else {
            evidence = .online
            cancelConnectionConfirmation(resetEvidence: true)
        }

        let connectionResolution = deviceConnectionStabilizer.resolve(
            evidence: evidence,
            lastSeenAt: lastSeenAt,
            confirmationStartedAt: connectionConfirmationStartedAt,
            confirmedAbsenceCount: confirmedDeviceAbsenceCount,
            now: now
        )
        updateStateFromMatch(
            recordPrompt: false,
            attemptAutomaticRefresh: false,
            connectionStatus: connectionResolution.deviceStatus,
            scanResult: scanResult
        )
        if connectionResolution == .confirming {
            scheduleConnectionConfirmation()
        }
    }

    private func invalidateForSetupDeviceScan(
        preflightCancellationMessage: String
    ) {
        refreshSessionCaches.invalidate(.manualDeepCheck)
        deviceVerificationGeneration += 1
        deviceRefreshSession.invalidate()
        isReloadingEnvironment = false
        isForegroundEnvironmentCheck = false
        activeEnvironmentRefreshPresentation = nil
        passiveRefreshSequence = nil
        cancelPendingAutoRefresh()
        cancelConnectionConfirmation(resetEvidence: false)
        cancelInstalledAppRetry(resetBackoff: false)

        guard deploymentTransaction.hasActiveTask,
              !deploymentTransaction.hasRunningDeployment else {
            return
        }
        deploymentTransaction.cancelPreflight()
        closeDeployOutputSink(flush: false)
        deployProgressText = nil
        deployMessage = preflightCancellationMessage
    }

    private func updateStateFromMatch(
        recordPrompt: Bool = true,
        attemptAutomaticRefresh: Bool = true,
        connectionStatus: DeviceStatus? = nil,
        scanResult: DeviceScanResult? = nil,
        observationDiagnostics: DeviceObservationDiagnostics? = nil
    ) {
        expiryInfo = inspectVerifiedExpiry()
        restartRemainingExpiryTimer()
        let status = connectionStatus ?? (matchedDevice == nil ? .offline : .online)
        if status == .online, matchedDevice != nil {
            hasConfirmedTargetDeviceThisSession = true
        }
        if status == .confirming {
            reminderDecision = ReminderDecision(shouldPrompt: false, reason: "正在重新确认目标设备连接。", nextEligibleAt: nil)
        } else {
            reminderDecision = reminderPolicy.evaluate(
                config: config,
                state: state,
                matchedDevice: matchedDevice,
                installedAppInfo: installedAppInfo,
                expiryInfo: expiryInfo,
                hasConfirmedInstallation: hasConfirmedCurrentTargetAppInstallation
            )
        }
        let shouldSendReminder = recordPrompt
            && config.autoRefreshPolicy == .reminderOnly
            && reminderDecision.shouldPrompt
        let didPersistState = persistState(
            status: status,
            device: matchedDevice,
            detectedExpiryAt: expiryInfo?.estimatedExpiryAt,
            expirySource: expiryInfo?.source,
            scanResult: scanResult,
            observationDiagnostics: observationDiagnostics
        )
        guard didPersistState else {
            return
        }
        if shouldSendReminder {
            deployMessage = reminderDecision.reason
            deliverReminder(.refreshReminder(
                reason: reminderDecision.reason,
                isExpired: isCurrentReminderExpired()
            ))
        }

        if attemptAutomaticRefresh {
            attemptAutomaticRefreshIfNeeded()
        }
    }

    private func handleSavedDeviceSelection(_ savedConfig: AppConfig) {
        let didChangeTargetDevice = normalizedSummaryValue(config.preferredDeviceID)
            != normalizedSummaryValue(savedConfig.preferredDeviceID)
            || normalizedSummaryValue(config.preferredDeviceName)
                != normalizedSummaryValue(savedConfig.preferredDeviceName)
        config.preferredDeviceID = savedConfig.preferredDeviceID
        config.preferredDeviceName = savedConfig.preferredDeviceName
        if didChangeTargetDevice {
            targetConfigurationGeneration += 1
            deviceConnectionState = deviceConnectionReducer.reduce(
                state: deviceConnectionState,
                event: .targetChanged
            ).state
            hasConfirmedTargetDeviceThisSession = false
            cancelManualRefreshProfileChoice()
            cancelReminderDeliveryForTargetChange()
            cancelDeployPreflightForTargetChange()
            invalidatePersistedTargetAppEvidence()
            availableDevices = []
            matchedDevice = nil
            setupViewModel.syncDetectedDevices(
                devices: [],
                matchedDevice: nil,
                feedback: .replace("目标设备已变更，正在重新扫描…")
            )
            refreshSessionCaches.invalidate(
                .targetChanged(
                    retaining: cacheKeys(
                        for: config,
                        deviceID: config.preferredDeviceID
                    )
                )
            )
        }
        reloadEnvironment()
        startPolling()
    }

    private func cancelDeployPreflightForTargetChange() {
        cancelPendingDeployRecovery(clearProgress: true)
        guard deploymentTransaction.hasActiveTask, !deploymentTransaction.hasRunningDeployment else {
            return
        }
        deploymentTransaction.cancelPreflight()
        closeDeployOutputSink(flush: false)
        deployProgressText = nil
        deployMessage = "目标配置已变更，本次续签已在续签前停止。"
    }

    private func cancelReminderDeliveryForTargetChange() {
        invalidateReminderDelivery()
    }

    private func invalidateReminderDelivery() {
        if let reminderDeliveryTask {
            reminderDeliveryTask.cancel()
            retainReminderDeliveryUntilSettled(reminderDeliveryTask)
        }
        reminderDeliveryTask = nil
        reminderDeliveryGeneration = nil
        reminderDeliveryIdentifier = nil
    }

    private func retainReminderDeliveryUntilSettled(
        _ task: Task<Void, Never>
    ) {
        let identifier = UUID()
        supersededReminderDeliveryTasks[identifier] = task
        Task { @MainActor [weak self] in
            await task.value
            self?.supersededReminderDeliveryTasks.removeValue(
                forKey: identifier
            )
        }
    }

    private func cancelPairingTask() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingTaskIdentifier = nil
    }

    private func deliverReminder(_ notification: AppNotification) {
        guard allowsCriticalDeviceActions else {
            invalidateReminderDelivery()
            return
        }
        if reminderDeliveryTask != nil {
            guard reminderDeliveryGeneration != targetConfigurationGeneration else {
                return
            }
            invalidateReminderDelivery()
        }

        let notificationService = self.notificationService
        let deliveryGeneration = targetConfigurationGeneration
        let deliveryIdentifier = UUID()
        reminderDeliveryGeneration = deliveryGeneration
        reminderDeliveryIdentifier = deliveryIdentifier
        reminderDeliveryTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.reminderDeliveryIdentifier == deliveryIdentifier,
                  deliveryGeneration == self.targetConfigurationGeneration,
                  self.allowsCriticalDeviceActions else {
                return
            }
            let result = await notificationService.send(notification)
            guard self.reminderDeliveryIdentifier == deliveryIdentifier else {
                return
            }
            self.reminderDeliveryTask = nil
            self.reminderDeliveryGeneration = nil
            self.reminderDeliveryIdentifier = nil
            guard deliveryGeneration == self.targetConfigurationGeneration,
                  self.allowsCriticalDeviceActions else {
                return
            }
            let currentDecision = self.reminderPolicy.evaluate(
                config: self.config,
                state: self.state,
                matchedDevice: self.matchedDevice,
                installedAppInfo: self.installedAppInfo,
                expiryInfo: self.expiryInfo,
                hasConfirmedInstallation:
                    self.hasConfirmedCurrentTargetAppInstallation
            )
            guard self.config.autoRefreshPolicy == .reminderOnly,
                  self.reminderDecision.shouldPrompt,
                  currentDecision.shouldPrompt else {
                return
            }

            switch result {
            case .scheduled:
                let deliveredAt = Date()
                do {
                    try self.commitStateEvents([
                        .reminderDelivered(deliveredAt)
                    ])
                } catch {
                    self.state.lastPromptAt = deliveredAt
                    self.enterStatePersistenceFailure(
                        error,
                        prefix: "提醒已发送，但无法保存冷却时间"
                    )
                }
            case .denied:
                self.deployMessage = "系统通知权限已关闭，提醒未送达；可在系统设置中允许 iOSSignKit 通知。"
            case .failed(let reason):
                self.deployMessage = "系统提醒未送达：\(reason)"
            }
        }
    }

    @discardableResult
    private func persistState(
        status: DeviceStatus,
        device: DeviceInfo?,
        unavailableDevice: UnavailableDeviceInfo? = nil,
        detectedExpiryAt: Date? = nil,
        expirySource: ExpirySource? = nil,
        scanResult: DeviceScanResult? = nil,
        observationDiagnostics: DeviceObservationDiagnostics? = nil,
        scanFailure: String? = nil,
        diagnosticMessage: String? = nil,
        pairingAttemptAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        let pairingDeviceID = normalizedSummaryValue(
            unavailableDevice?.id ?? device?.id ?? config.preferredDeviceID
        )
        let stateUpdate = RefreshStateSettlement.DeviceObservationUpdate(
            status: status,
            device: device,
            unavailableDevice: unavailableDevice,
            detectedExpiryAt: detectedExpiryAt,
            expirySource: expirySource,
            scanResult: scanResult,
            observationDiagnostics: observationDiagnostics,
            scanFailure: scanFailure,
            diagnosticMessage: diagnosticMessage,
            pairingAttemptAt: pairingAttemptAt,
            pairingDeviceID: pairingDeviceID,
            now: now
        )
        do {
            try commitStateEvents([.deviceObservation(stateUpdate)])
            return true
        } catch {
            enterStatePersistenceFailure(error)
            return false
        }
    }

    private func isCurrentReminderExpired(now: Date = Date()) -> Bool {
        guard let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return false
        }

        return estimatedExpiryAt <= now
    }

    private func minimumMetadataDate(for state: AppState) -> Date? {
        state.activeInstallationSuccessAt?.addingTimeInterval(-5)
    }

    private func inspectVerifiedExpiry() -> ExpiryInfo? {
        guard state.isTargetAppExpiryEvidenceVerified else {
            return nil
        }
        return expiryInspector.inspect(
            state: state,
            installedAppInfo: installedAppInfo,
            minimumInstallMetadataRecordedAt:
                minimumMetadataDate(for: state)
        )
    }

    func handleDeployResult(
        _ result: DeployResult,
        device: DeviceInfo,
        previousExpiry: Date?,
        source: RefreshTriggerSource = .manual
    ) async {
        await handleDeployResult(
            result,
            context: DeploymentContext(
                generation: targetConfigurationGeneration,
                config: config,
                device: device,
                deviceDetectionRollout: deviceDetectionRolloutState,
                source: source,
                profileRefreshMode: .automatic,
                installationIdentity: InstallationIdentitySnapshot(state: state)
            ),
            previousExpiry: previousExpiry
        )
    }

    private func handleDeployResult(
        _ result: DeployResult,
        context: DeploymentContext,
        previousExpiry: Date?
    ) async {
        refreshSessionCaches.invalidate(
            .deployment(
                .settled,
                target: cacheKeys(
                    for: context.config,
                    deviceID: context.device.id,
                    targetGeneration: context.generation
                )
            )
        )
        let isCurrentTarget = context.generation == targetConfigurationGeneration
        if !result.processGroupTerminationWasConfirmed {
            handleUnresolvedDeployProcessGroup(
                result,
                context: context,
                isCurrentTarget: isCurrentTarget
            )
            return
        }
        let event = RefreshStateSettlement.Event.deploymentResult(
            result,
            context: context,
            isCurrentTarget: isCurrentTarget,
            cancellationResult: .cancelled
        )
        do {
            try commitStateEvents([event])
        } catch {
            stateSettlement.apply(event, to: &state)
            enterStatePersistenceFailure(error)
        }
        if context.source.isAutomatic {
            logAutomaticRefreshEvent(.settled)
        }

        if !result.profileCacheRecoveryWasConfirmed {
            closeDeployOutputSink(flush: true)
            flushPendingDeployOutput()
            cancelPendingDeployRecovery()
            deployProgressText = "签名描述文件缓存恢复未完成"
            deployMessage = state.lastErrorSummary
            deploymentTransaction.settle()
            reloadHistoryAsync()
            return
        }

        closeDeployOutputSink(flush: true)
        deployMessage = result.summary
        flushPendingDeployOutput()
        if !isCurrentTarget {
            deployProgressText = result.isSuccess ? "旧配置的续签已完成" : "旧配置的续签已结束"
            deployMessage = result.isSuccess
                ? "续签流程已完成，但目标配置已变更；结果未写入当前 App 的有效期状态。"
                : "旧配置的续签已结束，但目标配置已变更；结果未写入当前状态。"
            deploymentTransaction.settle()
            reloadHistoryAsync()
            refreshDeviceStatus(
                presentation: .background,
                mode: .manualDeepCheck
            )
            return
        }

        if result.isSuccess {
            consecutiveInstalledAppAbsences = 0
            installedAppInfo = nil
            cancelInstalledAppRetry(resetBackoff: true)
            lanControlOperationPhase = .synchronizingInstallation
            deployProgressText = "续签完成，正在同步真机安装信息…"
            let inspectedAppInfo = await fetchInstalledAppAfterDeploy(
                device: context.device,
                bundleID: context.config.bundleID,
                deployFinishedAt: result.finishedAt
            )
            guard context.generation == targetConfigurationGeneration else {
                deployProgressText = "旧配置的续签已完成"
                deployMessage = "续签完成后目标配置发生变更；安装信息未写入当前状态。"
                deploymentTransaction.settle()
                reloadHistoryAsync()
                refreshDeviceStatus(
                    presentation: .background,
                    mode: .manualDeepCheck
                )
                return
            }
            installedAppInfo = inspectedAppInfo
            if let inspectedAppInfo {
                persistInstalledAppInspection(
                    .found(inspectedAppInfo),
                    confirmedAbsent: false,
                    inspectedAt: Date(),
                    inspectedDeviceID: context.device.id
                )
            }
            updateStateFromMatch(recordPrompt: false, attemptAutomaticRefresh: false)
            if latestDeployInstalledAppInspectionTimedOut || inspectedAppInfo == nil {
                scheduleInstalledAppRetry()
            }
            deployProgressText = "续签完成"
            finishLANControlOperation(at: refreshScheduler.wallNow())
            deployMessage = successSummary(
                previousExpiry: previousExpiry,
                latestExpiry: expiryInfo?.estimatedExpiryAt,
                metadataWasStale: latestDeployInstalledAppMetadataWasStale
            )
            if latestDeployInstalledAppInspectionTimedOut {
                deployMessage = "续签完成，但同步真机安装信息超时；已暂按本次续签时间估算，稍后将自动重试。"
            }
            if let logWarning = result.logWarning {
                deployMessage = "\(deployMessage ?? "续签已完成。") \(logWarning)"
            }
            deliverBackgroundNotification(
                .refreshSucceeded(deviceName: context.device.name)
            )
        } else {
            let isCancelled = result.outcome == .cancelled
            deployProgressText = isCancelled ? "已取消" : "续签失败"
            finishLANControlOperation(at: refreshScheduler.wallNow())
            deploymentTransaction.settle()
            if result.failureReason == .devicePreparationRequired {
                handleDevicePreparationFailure(
                    result,
                    context: context
                )
            } else if !isCancelled {
                confirmDeviceConnectionBeforeSendingFailure(
                    summary: result.summary,
                    device: context.device
                )
            } else {
                refreshDeviceStatusWithoutActions()
            }
            if let logWarning = result.logWarning {
                deployMessage =
                    "\(deployMessage ?? result.summary) \(logWarning)"
            }
        }
        if statePersistenceFailureActive {
            deployMessage = state.lastErrorSummary
        } else {
            publishOperationFeedback(
                deployMessage,
                result: state.lastResult
            )
        }
        deploymentTransaction.settle()
        reloadHistoryAsync()
    }

    private func handleUnresolvedDeployProcessGroup(
        _ result: DeployResult,
        context: DeploymentContext,
        isCurrentTarget: Bool
    ) {
        let update: (inout AppState) -> Void = { state in
            self.stateSettlement.applyDeploymentResult(
                result,
                context: context,
                isCurrentTarget: isCurrentTarget,
                cancellationResult: .interrupted,
                to: &state
            )
        }
        do {
            try updateStateAndPersist(update)
        } catch {
            update(&state)
            enterStatePersistenceFailure(error)
        }
        if context.source.isAutomatic {
            logAutomaticRefreshEvent(.settled)
        }

        closeDeployOutputSink(flush: true)
        flushPendingDeployOutput()
        cancelPendingDeployRecovery()
        deployProgressText = "续签进程树未确认结束"
        deployMessage = state.lastErrorSummary
        deploymentTransaction.settle()
        reloadHistoryAsync()
    }

    private func handleDevicePreparationFailure(
        _ result: DeployResult,
        context: DeploymentContext
    ) {
        let willRetry = context.source == .automaticInitial
            && !statePersistenceFailureActive
            && isAutomaticRefreshConditionMet
        if willRetry {
            deployProgressText = "等待 iPhone 完成设备准备…"
            deployMessage = "\(result.summary) 解锁后将自动恢复重试一次。"
            scheduleDeployRecovery(context: context)
        } else {
            deployProgressText = context.source.isAutomatic
                ? "自动恢复重试已停止"
                : "续签失败"
            deployMessage = result.summary
            refreshDeviceStatusWithoutActions()
        }

        if context.source == .manual {
            deliverBackgroundNotification(
                .manualRefreshBlockedByLock(
                    deviceName: context.device.name
                )
            )
        } else if context.source == .automaticInitial,
                  let key = automaticRefreshWaitKey(
                    device: context.device,
                    context: context
                  ) {
            deliverAutomaticUnlockNotificationOnce(
                deviceName: context.device.name,
                key: key,
                context: context
            )
        }
    }

    private func scheduleDeployRecovery(context: DeploymentContext) {
        cancelPendingDeployRecovery()
        refreshSessionCaches.invalidate(
            .deployment(
                .recovery,
                target: cacheKeys(
                    for: context.config,
                    deviceID: context.device.id,
                    targetGeneration: context.generation
                )
            )
        )
        let identifier = UUID()
        pendingDeployRecoveryIdentifier = identifier
        pendingDeployRecoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await Task.sleep(
                    for: .seconds(self.deployRecoveryDelaySeconds)
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.pendingDeployRecoveryIdentifier == identifier else {
                return
            }

            while self.isReloadingEnvironment {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.pendingDeployRecoveryIdentifier == identifier else {
                    return
                }
            }

            guard self.isDeployRecoveryContextCurrent(context),
                  self.isAutomaticRefreshConditionMet else {
                self.pendingDeployRecoveryTask = nil
                self.pendingDeployRecoveryIdentifier = nil
                if !self.statePersistenceFailureActive {
                    self.deployProgressText = nil
                    self.deployMessage =
                        "自动恢复重试条件已变化，未再次续签。"
                }
                return
            }
            self.deployProgressText =
                "正在重新确认目标 App 安装实例…"
            let installationIdentityIsCurrent =
                await self.verifyInstallationIdentityForAutomaticRecovery(
                    context
                )
            guard !Task.isCancelled,
                  self.pendingDeployRecoveryIdentifier == identifier else {
                return
            }
            guard installationIdentityIsCurrent,
                  self.isDeployRecoveryContextCurrent(context),
                  self.isAutomaticRefreshConditionMet else {
                self.pendingDeployRecoveryTask = nil
                self.pendingDeployRecoveryIdentifier = nil
                if !self.statePersistenceFailureActive {
                    self.deployProgressText = nil
                    self.deployMessage =
                        "自动恢复前无法确认原 App 安装实例，未再次续签。"
                }
                return
            }
            guard self.canRefreshNow else {
                self.pendingDeployRecoveryTask = nil
                self.pendingDeployRecoveryIdentifier = nil
                if !self.statePersistenceFailureActive {
                    self.deployProgressText = nil
                    self.deployMessage =
                        "自动恢复重试条件已变化，未再次续签。"
                }
                return
            }
            self.pendingDeployRecoveryTask = nil
            self.pendingDeployRecoveryIdentifier = nil
            self.beginRefresh(
                source: .automaticRecovery,
                profileRefreshMode: .automatic
            )
        }
    }

    private func verifyInstallationIdentityForAutomaticRecovery(
        _ context: DeploymentContext
    ) async -> Bool {
        do {
            let device: DeviceInfo
            if context.deviceDetectionRollout.mode == .production {
                guard let configuredDeviceID = normalizedSummaryValue(
                    context.config.preferredDeviceID
                ),
                configuredDeviceID == context.device.id,
                let stableDeviceID = StableDeviceID(configuredDeviceID)
                else {
                    return false
                }
                let observation = try await deviceMonitor.observeTarget(
                    .stableID(
                        stableDeviceID,
                        displayName: context.device.name
                    ),
                    purpose: .recovery
                )
                guard case .matched(let observedDevice) =
                        observation.evidence,
                      observedDevice.id == context.device.id else {
                    return false
                }
                device = observedDevice
            } else {
                let scanResult =
                    try await deviceMonitor.scanAvailableIPhones(
                        options: .reliable(
                            preferredDeviceID:
                                context.config.preferredDeviceID,
                            preferredDeviceName:
                                context.config.preferredDeviceName
                        )
                    )
                guard let matchedDevice = deviceMatcher.match(
                    preferredDeviceID:
                        context.config.preferredDeviceID,
                    preferredDeviceName:
                        context.config.preferredDeviceName,
                    devices: scanResult.devices
                ).device,
                matchedDevice.id == context.device.id else {
                    return false
                }
                device = matchedDevice
            }
            try Task.checkCancellation()
            guard isDeployRecoveryContextCurrent(context) else {
                return false
            }
            return await inspectAndRecordAutomaticInstallationIdentity(
                context: context,
                device: device
            )
        } catch {
            return false
        }
    }

    private func inspectAndRecordAutomaticInstallationIdentity(
        context: DeploymentContext,
        device: DeviceInfo
    ) async -> Bool {
        guard let bundleID = normalizedSummaryValue(context.config.bundleID),
              context.installationIdentity.presence == .installed,
              context.installationIdentity.expiryEvidenceIsVerified,
              normalizedSummaryValue(context.installationIdentity.bundleID)
                == bundleID,
              normalizedSummaryValue(context.installationIdentity.deviceID)
                == device.id,
              let recordedVersion = normalizedSummaryValue(
                  context.installationIdentity.version
              ),
              let recordedBuildVersion = normalizedSummaryValue(
                  context.installationIdentity.buildVersion
              ),
              let recordedAppURL = context.installationIdentity.appURL
                .flatMap(InstalledAppIdentity.normalizedAppURL) else {
            return false
        }

        let outcome: InstalledAppInspectionOutcome
        do {
            let appInfo = try await inspectInstalledApp(
                device,
                bundleID,
                1,
                0
            )
            try Task.checkCancellation()
            outcome = appInfo.map(InstalledAppInspectionOutcome.found)
                ?? .notInstalled
        } catch is CancellationError {
            return false
        } catch {
            outcome = .failed(
                "自动续期前读取已安装 App 失败：\(error.localizedDescription)"
            )
        }

        let inspectedAt = Date()
        let confirmedAbsent = consecutiveInstalledAppAbsences
            + (outcome.isNotInstalled ? 1 : 0)
            >= refreshTimingPolicy.requiredAbsenceCount
        var preparedState = state
        var preparedAbsenceCount = consecutiveInstalledAppAbsences
        var preparedInstalledAppInfo = installedAppInfo
        var preparedInspectionFailure = installedAppInspectionFailure
        var reduction = stateSettlement.applyInstallationInspection(
            installationInspectionUpdate(
                outcome: outcome,
                confirmedAbsent: confirmedAbsent,
                inspectedAt: inspectedAt,
                inspectedDeviceID: device.id
            ),
            to: &preparedState
        )
        switch outcome {
        case .notRequested:
            break
        case .found(let appInfo):
            preparedAbsenceCount = 0
            preparedInstalledAppInfo = appInfo
            if !appInfo.builtByDeveloper {
                preparedState.isTargetAppExpiryEvidenceVerified = false
                preparedState.activeInstallationSuccessAt = nil
                preparedState.lastDetectedExpiryAt = nil
                preparedState.expirySource = nil
                preparedState.lastExpiryVerifiedAt = nil
                preparedState.lastAppInspectionFailure =
                    "目标 App 不是可确认的开发者构建，已停止自动续期。"
                reduction = InstalledAppStateReduction(
                    expiryEvidenceVerified: false,
                    failureMessage: preparedState.lastAppInspectionFailure
                )
            }
            preparedInspectionFailure = reduction.failureMessage
        case .notInstalled:
            preparedAbsenceCount += 1
            preparedInspectionFailure = reduction.failureMessage
            if confirmedAbsent {
                preparedInstalledAppInfo = nil
            }
        case .failed(let failure):
            preparedInspectionFailure = failure
        }
        guard persistPreparedState(preparedState) else {
            return false
        }
        consecutiveInstalledAppAbsences = preparedAbsenceCount
        installedAppInfo = preparedInstalledAppInfo
        installedAppInspectionFailure = preparedInspectionFailure
        expiryInfo = reduction.expiryEvidenceVerified
            ? inspectVerifiedExpiry()
            : nil
        restartRemainingExpiryTimer()

        guard case .found(let appInfo) = outcome else {
            return false
        }
        return reduction.expiryEvidenceVerified
            && appInfo.builtByDeveloper
            && normalizedSummaryValue(appInfo.bundleIdentifier) == bundleID
            && normalizedSummaryValue(appInfo.version) == recordedVersion
            && normalizedSummaryValue(appInfo.bundleVersion)
                == recordedBuildVersion
            && InstalledAppIdentity.normalizedAppURL(appInfo.appURL)
                == recordedAppURL
    }

    private func isDeployRecoveryContextCurrent(
        _ context: DeploymentContext
    ) -> Bool {
        !hasPreparedForTermination
            && context.generation == targetConfigurationGeneration
            && context.config == config
            && context.deviceDetectionRollout
                == deviceDetectionRolloutState
            && matchedDevice?.id == context.device.id
            && InstallationIdentitySnapshot(state: state)
                == context.installationIdentity
    }

    @discardableResult
    private func cancelPendingDeployRecovery(
        clearProgress: Bool = false
    ) -> Bool {
        let hadPendingRecovery = pendingDeployRecoveryTask != nil
        pendingDeployRecoveryTask?.cancel()
        pendingDeployRecoveryTask = nil
        pendingDeployRecoveryIdentifier = nil
        if clearProgress, hadPendingRecovery {
            deployProgressText = nil
        }
        return hadPendingRecovery
    }

    private func handleDeployError(
        _ error: Error,
        device: DeviceInfo,
        context: DeploymentContext
    ) {
        refreshSessionCaches.invalidate(
            .deployment(
                .settled,
                target: cacheKeys(
                    for: context.config,
                    deviceID: device.id,
                    targetGeneration: context.generation
                )
            )
        )
        let summary = deployErrorSummary(error)
        closeDeployOutputSink(flush: true)
        flushPendingDeployOutput()

        do {
            try updateStateAndPersist { state in
                state.isDeployRunning = false
                state.deploymentRecoveryBlocked = false
                state.activeDeployProcessGroupID = nil
                state.activeDeploymentToken = nil
                state.lastResult = .failure
                state.lastErrorSummary = summary
            }
        } catch {
            state.isDeployRunning = false
            state.activeDeployProcessGroupID = nil
            state.activeDeploymentToken = nil
            state.lastResult = .failure
            state.lastErrorSummary = summary
            enterStatePersistenceFailure(error)
        }

        if !statePersistenceFailureActive {
            publishOperationFeedback(summary, result: .failure)
        }
        deployProgressText = "续签失败"
        deploymentTransaction.settle()
        confirmDeviceConnectionBeforeSendingFailure(summary: summary, device: device)
        reloadHistoryAsync()
    }

    private func confirmDeviceConnectionBeforeSendingFailure(summary: String, device: DeviceInfo) {
        pendingDeployFailureNotification = PendingDeployFailureNotification(
            refreshSequence: deviceRefreshSession.nextSequence,
            deviceID: device.id,
            deviceName: device.name,
            summary: summary
        )
        refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )
    }

    private func refreshDeviceStatusWithoutActions() {
        passiveRefreshSequence = deviceRefreshSession.nextSequence
        refreshDeviceStatus(
            presentation: .background,
            mode: .manualDeepCheck
        )
    }

    private func deployErrorSummary(_ error: Error) -> String {
        if let deployError = error as? DeployServiceError {
            switch deployError {
            case .unresolvedApplicationTarget:
                return "App 目标配置不完整，请重新识别并选择 Scheme。"
            case .missingDeployScript,
                 .deployScriptOutsideProjectContract,
                 .deployScriptNotExecutable:
                return "项目配置与内置续签要求不一致，请重新识别并保存 App 目标。"
            case .missingProjectRoot:
                return "未配置项目根目录。"
            case .invalidProjectRoot,
                 .invalidDeploymentToken:
                return deployError.localizedDescription
            }
        }

        return DiagnosticText.bounded(error.localizedDescription)
    }

    private func enqueueDeployOutput(_ text: String, isError _: Bool) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        pendingDeployLogBuffer.append(normalized)
        if pendingDeployLogBuffer.count > 48_000 {
            pendingDeployLogBuffer = "… 较早的实时输出已省略 …\n"
                + String(pendingDeployLogBuffer.suffix(48_000))
        }

        guard deployLogFlushTask == nil else {
            return
        }

        deployLogFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.flushPendingDeployOutput()
        }
    }

    private func flushPendingDeployOutput() {
        deployLogFlushTask?.cancel()
        deployLogFlushTask = nil

        if !pendingDeployLogBuffer.isEmpty {
            deployLogText.append(pendingDeployLogBuffer)
            pendingDeployLogBuffer = ""

            if deployLogText.count > 12_000 {
                deployLogText = String(deployLogText.suffix(12_000))
            }
        }
    }

    private func resetDeployLogBuffer() {
        closeDeployOutputSink(flush: false)
        deployLogFlushTask?.cancel()
        deployLogFlushTask = nil
        pendingDeployLogBuffer = ""
    }

    private func fetchInstalledAppAfterDeploy(
        device: DeviceInfo,
        bundleID: String?,
        deployFinishedAt: Date
    ) async -> InstalledAppInfo? {
        guard let bundleID, !bundleID.isEmpty else {
            return nil
        }

        var latestCandidate: InstalledAppInfo?
        var latestStaleMetadataCandidate: InstalledAppInfo?
        latestDeployInstalledAppMetadataWasStale = false
        latestDeployInstalledAppInspectionTimedOut = false
        let inspectInstalledApp = self.inspectInstalledApp
        let minimumMetadataRecordedAt = deployFinishedAt.addingTimeInterval(-5)
        let deadline = Date().addingTimeInterval(postDeployInspectionTimeoutSeconds)
        for attempt in 1...8 {
            guard !Task.isCancelled, deadline > Date() else {
                break
            }
            deployProgressText = "正在同步真机安装信息（\(attempt)/8）…"

            let inspectionResult = await inspectInstalledAppBeforeDeadline(
                inspectInstalledApp,
                device: device,
                bundleID: bundleID,
                deadline: deadline
            )
            if case .cancelled = inspectionResult {
                return nil
            }
            if case .deadlineReached = inspectionResult {
                latestDeployInstalledAppInspectionTimedOut = true
                break
            }
            if case .completed(let appInfo?) = inspectionResult {
                latestCandidate = appInfo

                if let installMetadata = appInfo.installMetadata {
                    if installMetadata.recordedAt >= minimumMetadataRecordedAt {
                        latestDeployInstalledAppMetadataWasStale = false
                        return appInfo
                    }

                    latestDeployInstalledAppMetadataWasStale = true
                    latestStaleMetadataCandidate = appInfo
                }
            }

            do {
                let remaining = max(deadline.timeIntervalSinceNow, 0)
                try await Task.sleep(for: .seconds(min(2, remaining)))
            } catch {
                return nil
            }
        }

        if let latestStaleMetadataCandidate {
            return appInfoWithoutInstallMetadata(latestStaleMetadataCandidate)
        }

        return latestCandidate
    }

    private func inspectInstalledAppBeforeDeadline(
        _ inspect: @escaping InspectInstalledAppHandler,
        device: DeviceInfo,
        bundleID: String,
        deadline: Date
    ) async -> PostDeployInspectionResult {
        let remaining = max(deadline.timeIntervalSinceNow, 0)
        guard remaining > 0 else {
            return .deadlineReached
        }

        let race = PostDeployInspectionRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation: continuation)
                let inspectionTask = Task.detached {
                    do {
                        race.finish(.completed(try await inspect(device, bundleID, 1, 0)))
                    } catch is CancellationError {
                        race.finish(.cancelled)
                    } catch {
                        race.finish(.failed)
                    }
                }
                let deadlineWorkItem = race.makeDeadlineWorkItem()
                race.install(
                    inspectionTask: inspectionTask,
                    deadlineWorkItem: deadlineWorkItem
                )
                PostDeployInspectionRace.deadlineQueue.asyncAfter(
                    deadline: .now() + remaining,
                    execute: deadlineWorkItem
                )
            }
        } onCancel: {
            race.finish(.cancelled)
        }
    }

    private func appInfoWithoutInstallMetadata(_ appInfo: InstalledAppInfo) -> InstalledAppInfo {
        InstalledAppInfo(
            bundleIdentifier: appInfo.bundleIdentifier,
            name: appInfo.name,
            version: appInfo.version,
            bundleVersion: appInfo.bundleVersion,
            appURL: appInfo.appURL,
            builtByDeveloper: appInfo.builtByDeveloper,
            installMetadata: nil
        )
    }

    private func successSummary(previousExpiry: Date?, latestExpiry: Date?, metadataWasStale: Bool = false) -> String {
        guard let latestExpiry else {
            if metadataWasStale {
                return "续签完成，但真机安装元信息尚未更新。"
            }
            return "续签完成，但暂时还没拿到新的过期时间。"
        }

        if metadataWasStale {
            return "续签完成，但真机安装元信息尚未更新，暂按本次续签时间估算为 \(absoluteDateTimeString(for: latestExpiry))。"
        }

        if let previousExpiry, previousExpiry == latestExpiry {
            return "续签完成，但签名过期时间没有变化。通常是因为 Xcode 继续复用了同一份个人开发签名。"
        }

        return "续签完成，新的预计过期时间是 \(absoluteDateTimeString(for: latestExpiry))。"
    }

    func openProjectFolder() {
        guard let projectRootPath = config.projectRootPath else {
            deployMessage = "项目路径尚未配置。"
            return
        }

        guard FileManager.default.fileExists(atPath: projectRootPath) else {
            deployMessage = "项目路径不存在：\(projectRootPath)"
            return
        }

        do {
            try runOpenCommandAsync(arguments: [projectRootPath])
        } catch {
            deployMessage = "打开项目失败：\(error.localizedDescription)"
        }
    }

    func openHistoryEntry(_ entry: RefreshHistoryEntry) {
        do {
            try runOpenCommandAsync(arguments: [entry.logPath])
        } catch {
            deployMessage = "打开历史日志失败：\(error.localizedDescription)"
        }
    }

    func quitApp() {
        prepareForTermination()
        NSApp.terminate(nil)
    }

    func prepareForTermination() {
        guard !hasPreparedForTermination else {
            return
        }
        hasPreparedForTermination = true

        lanControlServer.stop()
        stopPolling()
        remainingExpiryTimer?.invalidate()
        remainingExpiryTimer = nil
        deviceRefreshSession.cancel()
        activeEnvironmentRefreshPresentation = nil
        connectionConfirmationTask?.cancel()
        systemWakeRecheckTask?.cancel()
        systemWakeRecheckTask = nil
        installedAppRetryTask?.cancel()
        cancelPairingTask()
        cancelPendingAutoRefresh()
        cancelAutomaticRefreshWait(clearNotificationKeys: true)
        pendingDeployRecoveryTask?.cancel()
        menuBarTransientResultTask?.cancel()
        menuBarTransientResultTask = nil
        cancelManualRefreshProfileChoice()
        invalidateReminderDelivery()
        automaticUnlockNotificationTasks.values.forEach { $0.cancel() }
        backgroundNotificationTasks.values.forEach { $0.cancel() }
        historyLoadTask?.cancel()
        deployLogFlushTask?.cancel()
        pendingDeployRecoveryTask = nil
        pendingDeployRecoveryIdentifier = nil

        let transactionSnapshot =
            deploymentTransaction.detachForTermination()
        let deployment = transactionSnapshot.deployment
        let deploymentContext = transactionSnapshot.context
        let terminationDeadline = DispatchTime.now() + 2.5
        var deploymentShutdownOutcome = deployment?.shutdown(
            timeoutSeconds: remainingSeconds(until: terminationDeadline)
        )
        let didTerminateAllCommands =
            commandRunner.cancelAllRunningCommandsAndWait(
                timeoutSeconds: remainingSeconds(until: terminationDeadline)
            )
        if case .processUnresolved? = deploymentShutdownOutcome,
           didTerminateAllCommands {
            deploymentShutdownOutcome = .processTerminatedResultPending
        }
        closeDeployOutputSink(flush: true)
        flushPendingDeployOutput()

        if case .processUnresolved? = deploymentShutdownOutcome {
            markUnresolvedDeploymentForRecovery()
            return
        }

        if state.deploymentRecoveryBlocked, deployment == nil {
            return
        }

        if case .settled(let deploymentResult)? = deploymentShutdownOutcome,
           !deploymentResult.processGroupTerminationWasConfirmed {
            markUnresolvedDeploymentForRecovery(
                logPath: deploymentResult.logPath
            )
            return
        }

        if case .processTerminatedResultPending? = deploymentShutdownOutcome {
            markTerminatedDeploymentAsInterrupted(
                isCurrentTarget: deploymentContext?.generation
                    == targetConfigurationGeneration
            )
            return
        }

        if case .settled(let deploymentResult)? = deploymentShutdownOutcome,
           let deploymentContext,
           deploymentContext.generation == targetConfigurationGeneration {
            settleDeploymentForTermination(
                deploymentResult,
                context: deploymentContext
            )
            return
        }

        if deployment != nil,
           let deploymentContext,
           deploymentContext.generation != targetConfigurationGeneration {
            let clearStaleDeployment: (inout AppState) -> Void = { state in
                state.isDeployRunning = false
                state.activeDeployProcessGroupID = nil
                state.activeDeploymentToken = nil
            }
            do {
                try updateStateAndPersist(clearStaleDeployment)
            } catch {
                clearStaleDeployment(&state)
                enterStatePersistenceFailure(error)
            }
            return
        }

        if !state.isDeployRunning,
           state.activeDeployProcessGroupID == nil,
           state.activeDeploymentToken == nil,
           !state.deploymentRecoveryBlocked {
            return
        }
        let interruptedMessage = "续签因 iOSSignKit 退出而中断。"
        do {
            try updateStateAndPersist { state in
                state.isDeployRunning = false
                state.deploymentRecoveryBlocked = false
                state.activeDeployProcessGroupID = nil
                state.activeDeploymentToken = nil
                state.lastResult = .interrupted
                state.lastErrorSummary = interruptedMessage
            }
        } catch {
            state.isDeployRunning = false
            state.activeDeployProcessGroupID = nil
            state.activeDeploymentToken = nil
            state.lastResult = .interrupted
            state.lastErrorSummary = interruptedMessage
            enterStatePersistenceFailure(error)
        }
    }

    private func remainingSeconds(
        until deadline: DispatchTime
    ) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else {
            return 0
        }
        return TimeInterval(deadline.uptimeNanoseconds - now)
            / 1_000_000_000
    }

    private func closeDeployOutputSink(flush: Bool) {
        guard let deployOutputSink else {
            return
        }
        if flush {
            deployOutputSink.flushNow()
        }
        deployOutputSink.invalidate()
        self.deployOutputSink = nil
    }

    private func markUnresolvedDeploymentForRecovery(
        logPath: String? = nil
    ) {
        let message =
            "续签进程树未能确认结束；已阻止新的续签，重启 iOSSignKit 后将再次核验。"
        let update: (inout AppState) -> Void = { state in
            state.isDeployRunning = false
            state.deploymentRecoveryBlocked = true
            state.lastResult = .interrupted
            state.lastErrorSummary = message
            if let logPath {
                state.lastLogPath = logPath
            }
        }
        do {
            try updateStateAndPersist(update)
        } catch {
            update(&state)
            enterStatePersistenceFailure(error)
        }
        cancelPendingDeployRecovery()
        deployProgressText = "续签进程树未确认结束"
        deployMessage = state.lastErrorSummary
    }

    private func markTerminatedDeploymentAsInterrupted(
        isCurrentTarget: Bool
    ) {
        let message = "续签因 iOSSignKit 退出而中断。"
        let update: (inout AppState) -> Void = { state in
            state.isDeployRunning = false
            state.deploymentRecoveryBlocked = false
            state.activeDeployProcessGroupID = nil
            state.activeDeploymentToken = nil
            if isCurrentTarget || state.lastResult == .running {
                state.lastResult = .interrupted
                state.lastErrorSummary = message
            }
        }
        do {
            try updateStateAndPersist(update)
        } catch {
            update(&state)
            enterStatePersistenceFailure(error)
        }
    }

    private func settleDeploymentForTermination(
        _ result: DeployResult,
        context: DeploymentContext
    ) {
        let event = RefreshStateSettlement.Event.deploymentResult(
            result,
            context: context,
            isCurrentTarget: true,
            cancellationResult: .interrupted
        )
        do {
            try commitStateEvents([event])
        } catch {
            stateSettlement.apply(event, to: &state)
            enterStatePersistenceFailure(error)
        }
        if context.source.isAutomatic {
            logAutomaticRefreshEvent(.settled)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let previousUpdateError = launchAtLoginUpdateError
        launchAtLoginUpdateError = nil
        if deployMessage == previousUpdateError {
            deployMessage = nil
        }
        let previousConfig = config
        let previousSystemStatus = launchAtLoginService.currentStatus()
        var updatedConfig = config
        updatedConfig.startAtLogin = enabled

        do {
            try stateStore.saveConfig(updatedConfig)
        } catch {
            let message = "更新启动自启失败：\(error.localizedDescription)"
            deployMessage = message
            launchAtLoginUpdateError = message
            config = previousConfig
            launchAtLoginEnabled = launchAtLoginService.currentStatus()
            setupViewModel.startAtLogin = launchAtLoginEnabled
            return
        }

        do {
            try launchAtLoginService.sync(isEnabled: enabled)
        } catch {
            let originalFailure = error
            var rollbackFailures: [String] = []
            do {
                try stateStore.saveConfig(previousConfig)
            } catch {
                rollbackFailures.append("配置回滚失败：\(error.localizedDescription)")
            }
            do {
                try launchAtLoginService.sync(isEnabled: previousSystemStatus)
            } catch {
                rollbackFailures.append("系统状态回滚失败：\(error.localizedDescription)")
            }

            if rollbackFailures.isEmpty {
                config = previousConfig
                launchAtLoginEnabled = previousSystemStatus
                setupViewModel.startAtLogin = previousConfig.startAtLogin
                let message =
                    "更新启动自启失败：\(originalFailure.localizedDescription)"
                deployMessage = message
                launchAtLoginUpdateError = message
            } else {
                config = stateStore.loadConfigIfPresent() ?? previousConfig
                launchAtLoginEnabled = launchAtLoginService.currentStatus()
                setupViewModel.startAtLogin = config.startAtLogin
                let message =
                    "更新启动自启失败且回滚不完整："
                    + "\(originalFailure.localizedDescription)；"
                    + "\(rollbackFailures.joined(separator: "；"))。"
                    + "当前配置与系统状态已重新读取。"
                deployMessage = message
                launchAtLoginUpdateError = message
            }
            return
        }

        config = updatedConfig
        launchAtLoginEnabled = enabled
        setupViewModel.startAtLogin = enabled
    }

    func reloadHistoryAsync() {
        historyLoadTask?.cancel()
        isLoadingMoreHistory = true
        historyOffset = 0

        let historyService = self.historyService
        let historyPageSize = self.historyPageSize

        historyLoadTask = Task { @MainActor [weak self] in
            let entries = await historyService.loadRecentEntriesAsync(
                offset: 0,
                limit: historyPageSize
            )

            guard let self else { return }
            guard !Task.isCancelled else { return }

            self.historyEntries = entries
            self.historyOffset = entries.count
            self.hasMoreHistoryEntries = entries.count == historyPageSize
            self.isLoadingMoreHistory = false
            self.historyLoadTask = nil
        }
    }

    func loadMoreHistory() {
        guard !isLoadingMoreHistory, hasMoreHistoryEntries else {
            return
        }

        isLoadingMoreHistory = true

        let historyService = self.historyService
        let offset = self.historyOffset
        let historyPageSize = self.historyPageSize

        historyLoadTask = Task { @MainActor [weak self] in
            let nextEntries = await historyService.loadRecentEntriesAsync(
                offset: offset,
                limit: historyPageSize
            )

            guard let self else { return }
            guard !Task.isCancelled else { return }

            self.historyEntries.append(contentsOf: nextEntries)
            self.historyOffset += nextEntries.count
            self.hasMoreHistoryEntries = nextEntries.count == historyPageSize
            self.isLoadingMoreHistory = false
            self.historyLoadTask = nil
        }
    }

    func cancelPendingAutoRefresh() {
        automaticRefreshCoordinator.cancelCountdown()
        pendingAutoRefreshCountdown = nil
    }

    func cancelPendingAutoRefreshFromUser() {
        guard automaticRefreshCoordinator.isCountdownScheduled
                || pendingAutoRefreshCountdown != nil else {
            return
        }

        cancelPendingAutoRefresh()
        publishOperationFeedback(
            "已取消本次自动续期。",
            result: .cancelled
        )
    }

    func startPendingAutoRefreshNow() {
        guard automaticRefreshCoordinator.isCountdownScheduled,
              pendingAutoRefreshCountdown != nil,
              canRefreshNow else {
            return
        }

        cancelPendingAutoRefresh()
        beginRefresh(
            source: .automaticInitial,
            profileRefreshMode: .automatic
        )
    }

    func dismissOperationFeedback() {
        guard !deploymentTransaction.hasActiveTask,
              pendingDeployRecoveryTask == nil,
              pendingAutoRefreshCountdown == nil,
              !state.isDeployRunning,
              !isReloadingEnvironment else {
            return
        }

        deployMessage = nil
        deployProgressText = nil
        isOperationFeedbackDismissed = true
    }

    private func attemptAutomaticRefreshIfNeeded() {
        guard allowsCriticalDeviceActions else {
            cancelPendingAutoRefresh()
            cancelAutomaticRefreshWait(clearNotificationKeys: false)
            return
        }
        guard pendingDeployRecoveryTask == nil else {
            cancelPendingAutoRefresh()
            return
        }
        guard canRefreshNow else {
            cancelPendingAutoRefresh()
            return
        }

        guard shouldAutoRefreshNow else {
            cancelPendingAutoRefresh()
            cancelAutomaticRefreshWait(clearNotificationKeys: true)
            return
        }

        if let lastAutomaticAttemptAt = state.lastAutomaticAttemptAt {
            let elapsed = Date().timeIntervalSince(lastAutomaticAttemptAt)
            if elapsed >= 0, elapsed < autoRefreshCooldownInterval {
                return
            }
        }
        if let recoveryFailureAt =
                state.lastAutomaticRecoveryFailureAt {
            let elapsed = Date().timeIntervalSince(recoveryFailureAt)
            let requiredBackoff = max(
                refreshTimingPolicy
                    .automaticRecoveryFailureBackoff,
                autoRefreshCooldownInterval
            )
            if elapsed >= 0,
               elapsed < requiredBackoff {
                return
            }
        }

        guard !automaticRefreshCoordinator.isCountdownScheduled else {
            return
        }

        scheduleAutoRefreshCountdown()
    }

    private func formattedDeviceSummary(name: String, osVersion: String?) -> String {
        guard let osVersion = normalizedSummaryValue(osVersion) else {
            return name
        }

        let formattedOSVersion = osVersion.lowercased().hasPrefix("ios ")
            ? osVersion
            : "iOS \(osVersion)"
        return "\(name) · \(formattedOSVersion)"
    }

    private func normalizedSummaryValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedValue.isEmpty ? nil : normalizedValue
    }

    private var operationFeedbackResult: RefreshResult? {
        guard let operationFeedbackMessage,
              operationFeedbackAssociation?.message == operationFeedbackMessage else {
            return nil
        }

        return operationFeedbackAssociation?.result
    }

    private func publishOperationFeedback(
        _ message: String?,
        result: RefreshResult?
    ) {
        if let message = normalizedSummaryValue(message), let result {
            operationFeedbackAssociation = (message, result)
        } else {
            operationFeedbackAssociation = nil
        }
        isPublishingAssociatedOperationFeedback = true
        deployMessage = message
        isPublishingAssociatedOperationFeedback = false
        if let result {
            presentMenuBarResult(result)
        }
    }

    private func presentMenuBarResult(_ result: RefreshResult) {
        guard result != .running else {
            return
        }

        menuBarTransientResultTask?.cancel()
        menuBarTransientResult = result
        let displayDuration = menuBarResultDisplayDuration
        menuBarTransientResultTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: displayDuration)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            self.menuBarTransientResult = nil
            self.menuBarTransientResultTask = nil
        }
    }

    private func clearMenuBarTransientResult() {
        menuBarTransientResultTask?.cancel()
        menuBarTransientResultTask = nil
        menuBarTransientResult = nil
    }

    private func absoluteDateTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func compactMonthDayTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private func relativeDateTimeString(for date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func readableProfileSource(_ source: ExpirySource) -> String {
        switch source {
        case .installMetadata("embedded_mobileprovision"):
            return "embedded.mobileprovision"
        case .verifiedDeploymentProfile:
            return "本次安装包的 embedded.mobileprovision"
        case .deployTimeEstimate:
            return "按安装时间估算"
        case .installedAppDetectedDeployTimeEstimate:
            return "已检测到安装，按安装时间估算"
        case .storedEstimate:
            return "已存储的有效期"
        case .installMetadata(let rawValue):
            return rawValue
        case .unknown(let rawValue):
            return "未知来源（\(rawValue)）"
        }
    }

    private func syncLaunchAtLoginFromConfig() {
        do {
            try launchAtLoginService.sync(isEnabled: config.startAtLogin)
        } catch {
            deployMessage = "同步启动自启状态失败：\(error.localizedDescription)"
        }

        launchAtLoginEnabled = launchAtLoginService.currentStatus()
        setupViewModel.startAtLogin = launchAtLoginEnabled
    }

    private var shouldAutoRefreshNow: Bool {
        isAutomaticRefreshConditionMet
    }

    private var allowsCriticalDeviceActions: Bool {
        deviceDetectionRolloutController.decision(
            for: deviceDetectionRolloutState.mode
        ).allowsCriticalActions
    }

    private var isAutomaticRefreshConditionMet: Bool {
        guard hasConfirmedCurrentTargetAppInstallation,
              let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return false
        }

        switch config.autoRefreshPolicy {
        case .reminderOnly:
            return false
        case .autoRefreshWhenExpired:
            return estimatedExpiryAt <= remainingExpiryNow
        }
    }

    private var preferredBackgroundRefreshMode: EnvironmentRefreshMode {
        if state.targetAppPresence == .installed,
           !state.isTargetAppExpiryEvidenceVerified {
            return .appMetadataRetry
        }
        return isAutomaticRefreshConditionMet
            ? .automaticRecoveryCheck
            : .backgroundPoll
    }

    private func xcodeValidationCacheKey(
        for config: AppConfig,
        targetGeneration: Int? = nil
    ) -> XcodeValidationCacheKey? {
        guard let projectPath = normalizedSummaryValue(config.xcodeprojPath),
              let scheme = normalizedSummaryValue(config.scheme),
              let targetName = normalizedSummaryValue(config.targetName),
              let bundleID = normalizedSummaryValue(config.bundleID) else {
            return nil
        }
        return XcodeValidationCacheKey(
            targetGeneration:
                targetGeneration ?? targetConfigurationGeneration,
            normalizedProjectIdentity:
                URL(fileURLWithPath: projectPath)
                    .standardizedFileURL.path,
            scheme: scheme,
            targetName: targetName,
            bundleID: bundleID
        )
    }

    private func installedAppCacheKey(
        for config: AppConfig,
        deviceID: String?,
        targetGeneration: Int? = nil
    ) -> InstalledAppCacheKey? {
        Self.installedAppCacheKey(
            targetGeneration:
                targetGeneration ?? targetConfigurationGeneration,
            config: config,
            deviceID: deviceID
        )
    }

    private static func installedAppCacheKey(
        targetGeneration: Int,
        config: AppConfig,
        deviceID: String?
    ) -> InstalledAppCacheKey? {
        let rawDeviceID = deviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = config.bundleID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawDeviceID.isEmpty,
              !bundleID.isEmpty,
              let stableDeviceID = StableDeviceID(rawDeviceID),
              DeviceIdentityValidator.isSafe(bundleID) else {
            return nil
        }
        return InstalledAppCacheKey(
            targetGeneration: targetGeneration,
            deviceID: stableDeviceID,
            bundleID: bundleID
        )
    }

    private func cacheKeys(
        for config: AppConfig,
        deviceID: String?,
        targetGeneration: Int? = nil
    ) -> RefreshTargetCacheKeys {
        RefreshTargetCacheKeys(
            xcode: xcodeValidationCacheKey(
                for: config,
                targetGeneration: targetGeneration
            ),
            installedApp: installedAppCacheKey(
                for: config,
                deviceID: deviceID,
                targetGeneration: targetGeneration
            )
        )
    }

    private func manualRefreshPromptReason(
        at now: Date
    ) -> ManualRefreshPromptReason? {
        if state.targetAppPresence == .confirmedNotInstalled {
            return .appNotInstalled
        }
        guard hasCurrentTargetAppInstallationIdentity else {
            return .installationUnconfirmed
        }
        guard state.isTargetAppExpiryEvidenceVerified,
              let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return .expiryUnknown
        }
        return estimatedExpiryAt <= now
            ? nil
            : .notExpired(estimatedExpiryAt)
    }

    private func profileRefreshProgressText(
        for mode: ProvisioningProfileRefreshMode
    ) -> String {
        mode == .force
            ? "正在更新签名描述文件…"
            : "正在优先复用现有签名描述文件…"
    }

    private var currentManualRefreshPromptEvidence:
        ManualRefreshPromptEvidence {
        ManualRefreshPromptEvidence(
            installationIdentity: InstallationIdentitySnapshot(state: state),
            estimatedExpiryAt: expiryInfo?.estimatedExpiryAt
        )
    }

    private func invalidateManualRefreshProfileChoiceIfNeeded() {
        guard let prompt = manualRefreshPrompt else {
            return
        }
        guard prompt.targetGeneration == targetConfigurationGeneration,
              matchedDevice?.id == prompt.deviceID,
              canRefreshNow,
              manualRefreshPromptEvidence
                == currentManualRefreshPromptEvidence else {
            cancelManualRefreshProfileChoice()
            return
        }
    }

    private func isConfirmedCurrentTargetAppExpired(
        at now: Date
    ) -> Bool {
        guard hasConfirmedCurrentTargetAppInstallation,
              let estimatedExpiryAt = expiryInfo?.estimatedExpiryAt else {
            return false
        }
        return estimatedExpiryAt <= now
    }

    private var hasCurrentTargetAppInstallationIdentity: Bool {
        guard state.targetAppPresence == .installed,
              let configuredBundleID = normalizedSummaryValue(config.bundleID),
              let recordedBundleID = normalizedSummaryValue(state.targetAppBundleID),
              let recordedDeviceID = normalizedSummaryValue(state.targetDeviceID),
              let currentDeviceID = normalizedSummaryValue(
                  matchedDevice?.id ?? config.preferredDeviceID
              ) else {
            return false
        }
        return configuredBundleID == recordedBundleID
            && recordedDeviceID == currentDeviceID
    }

    private var hasConfirmedCurrentTargetAppInstallation: Bool {
        hasCurrentTargetAppInstallationIdentity
            && state.isTargetAppExpiryEvidenceVerified
    }

    private var hasCurrentMatchedDeploymentDevice: Bool {
        guard let matchedDevice else {
            return false
        }
        return deviceMatcher.match(
            preferredDeviceID: config.preferredDeviceID,
            preferredDeviceName: config.preferredDeviceName,
            devices: availableDevices
        ).device?.id == matchedDevice.id
    }

    private var isEnvironmentReadyForAutomaticRecovery: Bool {
        !state.processRecoveryBlocked
            && !statePersistenceFailureActive
            && environmentStatus.areAllChecksPassing
    }

    private var isWirelessPairingCoolingDown: Bool {
        guard let preferredDeviceID = normalizedSummaryValue(config.preferredDeviceID),
              normalizedSummaryValue(state.lastPairingDeviceID) == preferredDeviceID,
              let lastPairingAttemptAt = state.lastPairingAttemptAt else {
            return false
        }

        let elapsed = Date().timeIntervalSince(lastPairingAttemptAt)
        return elapsed >= 0 && elapsed < wirelessPairingCooldownInterval
    }

    private var wirelessPairingCooldownInterval: TimeInterval {
        refreshTimingPolicy.wirelessPairingCooldown
    }

    private var isConnectionRecoveryStatus: Bool {
        deviceStatusPresentation.isConnectionRecovery
    }

    private func recoveryStatusMessage(for status: DeviceStatus?) -> String {
        DeviceStatusPresentation.make(
            status: status,
            hasPersistedIdentity: state.currentDeviceName != nil
        ).recoveryMessage ?? "自动续期正在等待目标 iPhone 恢复连接。"
    }

    private var automaticRefreshReason: String {
        switch config.autoRefreshPolicy {
        case .reminderOnly:
            return "当前为到期提醒模式。"
        case .autoRefreshWhenExpired:
            return "已检测到 App 预计过期，正在自动续签到真机。"
        }
    }

    private var autoRefreshCooldownInterval: TimeInterval {
        TimeInterval(
            AppConfigConstraints.normalizeExpiredCheckInterval(
                config.expiredCheckIntervalMinutes
            ) * 60
        )
    }

    private func scheduleAutoRefreshCountdown() {
        guard allowsCriticalDeviceActions else {
            cancelPendingAutoRefresh()
            return
        }
        clearMenuBarTransientResult()
        recordAutomaticRefreshEvent(.expiryDetected)
        let countdownSeconds =
            refreshTimingPolicy.automaticRefreshCountdownSeconds
        deployMessage = automaticRefreshReason
        automaticRefreshCoordinator.scheduleCountdown(
            seconds: countdownSeconds,
            shouldContinue: { [weak self] in
                self?.allowsCriticalDeviceActions == true
            },
            onUpdate: { [weak self] remaining in
                self?.pendingAutoRefreshCountdown = remaining
            },
            onReady: { [weak self] in
                self?.beginRefresh(
                    source: .automaticInitial,
                    profileRefreshMode: .automatic
                )
            }
        )
    }

    private func runOpenCommandAsync(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
    }

    private func applyRefreshSnapshot(_ snapshot: DeviceRefreshSnapshot, refreshSequence: Int) {
        guard deviceRefreshSession.isCurrent(refreshSequence),
              snapshot.policyGeneration
                == deviceDetectionRolloutState.generation,
              snapshot.observationGeneration
                == passiveObservationGeneration else {
            return
        }

        let manualPairingRequested =
            manualPairingRefreshSequence == refreshSequence
        manualPairingRefreshSequence = nil

        let isDeployFailureConfirmation = pendingDeployFailureNotification?.refreshSequence == refreshSequence
        let isPassiveRefresh = passiveRefreshSequence == refreshSequence
        let hasDegradedTargetObservation =
            snapshot.targetObservation?.diagnostics.quality == .degraded
        let externallySuppressesRefreshActions =
            isDeployFailureConfirmation
            || isPassiveRefresh
        var shouldSuppressRefreshActions =
            externallySuppressesRefreshActions
            || !snapshot.allowsCriticalActions
            || snapshot.usedCachedActionEvidence
            || hasDegradedTargetObservation
        if let update = snapshot.xcodeCacheUpdate {
            refreshSessionCaches.storeXcodeValidation(
                update.entry,
                for: update.key
            )
        }
        if let invalidationKey =
            snapshot.installedAppCacheInvalidationKey {
            refreshSessionCaches.invalidate(
                .installedAppIdentityChanged(invalidationKey)
            )
        }
        if let update = snapshot.installedAppCacheUpdate,
           snapshot.targetObservation?.diagnostics.quality != .degraded {
            refreshSessionCaches.storeInstalledApp(
                update.entry,
                for: update.key
            )
        }
        if isPassiveRefresh {
            passiveRefreshSequence = nil
        }
        _ = deviceRefreshSession.complete(sequence: refreshSequence)
        isReloadingEnvironment = false
        isForegroundEnvironmentCheck = false
        activeEnvironmentRefreshPresentation = nil
        defer {
            invalidateManualRefreshProfileChoiceIfNeeded()
        }

        environmentStatus = snapshot.environmentStatus

        if let errorMessage = snapshot.errorMessage {
            refreshSessionCaches.invalidate(
                .scanIssue(
                    .failure,
                    appKey: installedAppCacheKey(
                        for: config,
                        deviceID: config.preferredDeviceID
                    )
                )
            )
            cancelManualRefreshProfileChoice()
            resolvePendingDeployFailureNotification(
                refreshSequence: refreshSequence,
                availableDevices: []
            )
            if snapshot.treatsScanFailureAsTransient {
                applyTransientScanFailure(errorMessage)
                return
            }

            availableDevices = []
            matchedDevice = nil
            cancelInstalledAppRetry(resetBackoff: false)
            setupViewModel.syncDetectedDevices(
                devices: [],
                matchedDevice: nil,
                feedback: .replace(errorMessage)
            )
            reminderDecision = ReminderDecision(shouldPrompt: false, reason: errorMessage, nextEligibleAt: nil)
            if !shouldSuppressRefreshActions {
                deployMessage = "设备扫描失败。"
            }
            persistState(status: .scanFailed, device: nil, scanFailure: errorMessage)
            return
        }

        let now = Date()
        let previousMatchedDevice = matchedDevice
        availableDevices = snapshot.availableDevices
        matchedDevice = snapshot.matchedDevice
        if let recordedDeviceID = normalizedSummaryValue(state.targetDeviceID),
           let currentDeviceID = normalizedSummaryValue(
               snapshot.matchedDevice?.id
           ),
           recordedDeviceID != currentDeviceID {
            if let staleKey = installedAppCacheKey(
                for: config,
                deviceID: recordedDeviceID
            ) {
                refreshSessionCaches.invalidate(
                    .installedAppIdentityChanged(staleKey)
                )
            }
            invalidatePersistedTargetAppEvidence()
        }
        if hasDegradedTargetObservation {
            if pendingDeployFailureNotification?.refreshSequence
                == refreshSequence {
                pendingDeployFailureNotification = nil
            }
        } else {
            resolvePendingDeployFailureNotification(
                refreshSequence: refreshSequence,
                availableDevices: snapshot.availableDevices
            )
        }

        let reduction = deviceRefreshSnapshotReducer.reduce(
            .init(
                snapshot: snapshot,
                config: config,
                state: state,
                previousMatchedDevice: previousMatchedDevice,
                connectionState: deviceConnectionState,
                connectionConfirmationStartedAt:
                    connectionConfirmationStartedAt,
                confirmedDeviceAbsenceCount:
                    confirmedDeviceAbsenceCount,
                consecutiveInstalledAppAbsences:
                    consecutiveInstalledAppAbsences,
                installedAppInfo: installedAppInfo,
                installedAppInspectionFailure:
                    installedAppInspectionFailure,
                externallySuppressesActions:
                    externallySuppressesRefreshActions,
                now: now,
                observedAt: ContinuousClock().now
            )
        )
        guard persistPreparedState(reduction.state) else {
            return
        }
        deviceConnectionState = reduction.connectionState
        connectionConfirmationStartedAt =
            reduction.connectionConfirmationStartedAt
        confirmedDeviceAbsenceCount =
            reduction.confirmedDeviceAbsenceCount
        consecutiveInstalledAppAbsences =
            reduction.consecutiveInstalledAppAbsences
        installedAppInfo = reduction.installedAppInfo
        installedAppInspectionFailure =
            reduction.installedAppInspectionFailure
        expiryInfo = reduction.expiryInfo
        shouldSuppressRefreshActions =
            reduction.shouldSuppressRefreshActions
        if reduction.resetsConnectionEvidence {
            cancelConnectionConfirmation(resetEvidence: true)
        }
        if let cacheIssue = reduction.cacheIssue {
            refreshSessionCaches.invalidate(
                .scanIssue(
                    cacheIssue,
                    appKey: installedAppCacheKey(
                        for: config,
                        deviceID: config.preferredDeviceID
                    )
                )
            )
        }
        if reduction.shouldResetInstalledAppRetry {
            cancelInstalledAppRetry(resetBackoff: true)
        }
        restartRemainingExpiryTimer()

        let connectionResolution = reduction.connectionResolution
        let connectionStatus = connectionResolution.deviceStatus
        let typedConnectionRecheckAfter =
            reduction.connectionRecheckAfter
        let typedConnectionPhase = reduction.connectionPhase
        let setupMessage = reduction.setupMessage
        let setupDeviceFeedback: DeviceFeedbackUpdate
        if setupViewModel.isScanningDevices {
            setupDeviceFeedback = .preserve
        } else if let setupMessage {
            setupDeviceFeedback = .replace(setupMessage)
        } else {
            setupDeviceFeedback = .clear
        }
        setupViewModel.syncDetectedDevices(
            devices: snapshot.availableDevices,
            matchedDevice: snapshot.matchedDevice,
            feedback: setupDeviceFeedback
        )

        if connectionResolution == .online, let matchedDevice = snapshot.matchedDevice {
            if let identityPersistenceCandidate =
                snapshot.identityPersistenceCandidate {
                persistResolvedDeviceIdentityIfNeeded(
                    identityPersistenceCandidate,
                    matchedDevice: matchedDevice,
                    availableDevices: snapshot.availableDevices
                )
            } else {
                autoPinUniqueDeviceIfNeeded(
                    matchedDevice,
                    availableDevices: snapshot.availableDevices,
                    scanResult: snapshot.scanResult
                )
            }
        }
        if !shouldSuppressRefreshActions,
           snapshot.matchedDevice == nil,
           let diagnostic = snapshot.deviceMatchResult.diagnosticMessage,
           snapshot.scanResult?.unavailableTarget == nil {
            deployMessage = diagnostic
        }

        let typedRecoveryTarget = validatedTypedRecoveryTarget(
            from: snapshot.targetObservation,
            connectionPhase: typedConnectionPhase
        )
        let compatibilityUnavailableTarget =
            snapshot.targetObservation == nil
                ? snapshot.scanResult?.unavailableTarget
                : nil
        let recoveryTarget =
            typedRecoveryTarget ?? compatibilityUnavailableTarget
        let allowsRecoveryAction =
            typedRecoveryTarget != nil
                ? (
                    !isDeployFailureConfirmation
                        && !isPassiveRefresh
                        && snapshot.allowsCriticalActions
                        && !snapshot.usedCachedActionEvidence
                )
                : !shouldSuppressRefreshActions
        let shouldAttemptPairing =
            manualPairingRequested || isAutomaticRefreshConditionMet
        let pairingEnvironmentIsReady =
            manualPairingRequested || isEnvironmentReadyForAutomaticRecovery
        if allowsRecoveryAction,
           snapshot.matchedDevice == nil,
           let recoveryTarget,
           typedRecoveryTarget != nil
                || connectionResolution == .offline,
           shouldAttemptPairing,
           pairingEnvironmentIsReady,
           snapshot.refreshMode != .backgroundPoll {
            handleUnavailableTargetForAutomaticRefresh(
                recoveryTarget,
                scanResult: snapshot.scanResult,
                bypassPairingCooldown: manualPairingRequested
                    || snapshot.refreshMode == .manualDeepCheck
            )
            return
        }

        updateStateFromMatch(
            recordPrompt: !shouldSuppressRefreshActions,
            attemptAutomaticRefresh: !shouldSuppressRefreshActions,
            connectionStatus: connectionStatus,
            scanResult: snapshot.scanResult,
            observationDiagnostics:
                snapshot.targetObservation?.diagnostics
        )

        switch connectionResolution {
        case .online:
            if shouldRetryInstalledAppInspection(after: snapshot.installedAppInspectionOutcome) {
                scheduleInstalledAppRetry()
            }
        case .confirming:
            cancelInstalledAppRetry(resetBackoff: false)
            if let typedConnectionRecheckAfter {
                scheduleTypedConnectionRecheck(
                    after: typedConnectionRecheckAfter
                )
            } else {
                scheduleConnectionConfirmation()
            }
        case .offline:
            cancelInstalledAppRetry(resetBackoff: false)
            cancelConnectionConfirmation(resetEvidence: true)
        case .scanFailed:
            cancelInstalledAppRetry(resetBackoff: false)
            if let typedConnectionRecheckAfter {
                scheduleTypedConnectionRecheck(
                    after: typedConnectionRecheckAfter
                )
            } else {
                cancelConnectionConfirmation(resetEvidence: true)
            }
        }
    }

    private func resolvePendingDeployFailureNotification(
        refreshSequence: Int,
        availableDevices: [DeviceInfo]
    ) {
        guard let pendingNotification = pendingDeployFailureNotification,
              pendingNotification.refreshSequence == refreshSequence else {
            return
        }

        pendingDeployFailureNotification = nil
        guard availableDevices.contains(where: {
            $0.id == pendingNotification.deviceID && $0.isAvailable
        }) else {
            return
        }

        deliverBackgroundNotification(
            .refreshFailed(summary: pendingNotification.summary)
        )
    }

    private func validatedTypedRecoveryTarget(
        from observation: TargetDeviceObservation?,
        connectionPhase: DeviceConnectionPhase?
    ) -> UnavailableDeviceInfo? {
        guard connectionPhase == .recoveryCandidate,
              let observation,
              deviceConnectionState.latestObservation == observation,
              let candidate = observation.recoveryCandidate,
              let configuredID = normalizedSummaryValue(
                  config.preferredDeviceID
              ),
              StableDeviceID(configuredID) == candidate.deviceID else {
            return nil
        }

        switch observation.evidence {
        case .inconclusive:
            return UnavailableDeviceInfo(
                id: candidate.deviceID.value,
                name: candidate.displayName,
                osVersion: candidate.osVersion ?? "未知",
                pairingState: nil,
                connectionState: nil,
                tunnelState: nil,
                developerModeStatus: nil,
                diagnosticMessage: observation.diagnostics.summary
            )
        case .unavailable(let device):
            guard device.id == candidate.deviceID.value else {
                return nil
            }
            return device
        case .matched, .confirmedAbsent, .conflict:
            return nil
        }
    }

    private func handleUnavailableTargetForAutomaticRefresh(
        _ unavailableTarget: UnavailableDeviceInfo,
        scanResult: DeviceScanResult?,
        bypassPairingCooldown: Bool
    ) {
        cancelPendingAutoRefresh()
        guard allowsCriticalDeviceActions else {
            cancelPairingTask()
            return
        }

        guard let osMajorVersion = unavailableTarget.osMajorVersion else {
            setConnectionRecoveryStatus(
                .wirelessPairingRequired,
                message: "无法确认目标 iPhone 的系统版本。请解锁设备、确认连接同一 Wi-Fi，然后手动重新检查。",
                device: unavailableTarget,
                scanResult: scanResult
            )
            return
        }

        guard osMajorVersion
                >= DeviceCompatibilityPolicy
                    .minimumWirelessPairingMajorVersion else {
            setConnectionRecoveryStatus(
                .wiredConnectionRequired,
                message:
                    "自动续期受阻："
                    + DeviceCompatibilityPolicy.wiredConnectionGuidance
                    + "请解锁 iPhone，并在 Finder 或 Xcode 完成一次信任或配对；"
                    + "重新检查成功后会恢复无线自动续期。",
                device: unavailableTarget,
                scanResult: scanResult
            )
            return
        }

        guard pairingTask == nil else {
            return
        }

        if !bypassPairingCooldown, isWirelessPairingCoolingDown {
            let currentStatus = state.currentDeviceStatus
            let status = isConnectionRecoveryStatus && currentStatus != .wirelessPairing
                ? (currentStatus ?? .wirelessPairingRequired)
                : .wirelessPairingRequired
            setConnectionRecoveryStatus(
                status,
                message: recoveryStatusMessage(for: status),
                device: unavailableTarget,
                scanResult: scanResult
            )
            return
        }

        let attemptDate = Date()
        guard setConnectionRecoveryStatus(
            .wirelessPairing,
            message: "正在通过同一局域网重新配对 \(unavailableTarget.name)…",
            device: unavailableTarget,
            scanResult: scanResult,
            pairingAttemptAt: attemptDate
        ) else {
            return
        }

        let pairDevice = self.pairDevice
        let pairingIdentifier = UUID()
        pairingTaskIdentifier = pairingIdentifier
        pairingTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.pairingTaskIdentifier == pairingIdentifier,
                  self.allowsCriticalDeviceActions else {
                return
            }
            defer {
                if self.pairingTaskIdentifier == pairingIdentifier {
                    self.pairingTask = nil
                    self.pairingTaskIdentifier = nil
                }
            }
            let result = await pairDevice(unavailableTarget)

            guard self.pairingTaskIdentifier == pairingIdentifier else {
                return
            }
            guard !Task.isCancelled,
                  self.allowsCriticalDeviceActions else {
                return
            }

            guard self.matchedDevice == nil,
                  self.state.currentDeviceStatus == .wirelessPairing else {
                return
            }

            self.handleWirelessPairingResult(result, device: unavailableTarget)
        }
    }

    private func handleWirelessPairingResult(
        _ result: DevicePairingResult,
        device: UnavailableDeviceInfo
    ) {
        switch result {
        case .success:
            deployMessage = "无线配对成功，正在重新检查目标 iPhone…"
            reminderDecision = ReminderDecision(
                shouldPrompt: false,
                reason: "无线配对成功，正在等待设备连接可用。",
                nextEligibleAt: nil
            )
            refreshDeviceStatus(
                presentation: .background,
                mode: .automaticRecoveryCheck
            )
        case .confirmationRequired(let diagnostic):
            setConnectionRecoveryStatus(
                .wirelessPairingConfirmationRequired,
                message: "请解锁 \(device.name)，在 iPhone 上确认信任，并确保开发者模式已开启。",
                device: device,
                diagnosticMessage: diagnostic
            )
        case .networkUnavailable(let diagnostic):
            setConnectionRecoveryStatus(
                .wirelessPairingRequired,
                message: "请解锁 \(device.name)，并确认 iPhone 与 Mac 连接到同一 Wi-Fi 后重新检查。",
                device: device,
                diagnosticMessage: diagnostic
            )
        case .toolchainUnsupported(let diagnostic):
            setConnectionRecoveryStatus(
                .xcodeUpdateRequired,
                message: "当前 Xcode/CoreDevice 不支持 \(device.osVersion) 设备，请升级 Xcode 后重新检查。",
                device: device,
                diagnosticMessage: diagnostic
            )
        case .failed(let diagnostic):
            setConnectionRecoveryStatus(
                .wirelessPairingRequired,
                message: "无线配对失败。请解锁 \(device.name)、确认连接同一 Wi-Fi，然后手动重新检查。",
                device: device,
                diagnosticMessage: diagnostic
            )
        }
    }

    @discardableResult
    private func setConnectionRecoveryStatus(
        _ status: DeviceStatus,
        message: String,
        device: UnavailableDeviceInfo,
        scanResult: DeviceScanResult? = nil,
        diagnosticMessage: String? = nil,
        pairingAttemptAt: Date? = nil
    ) -> Bool {
        reminderDecision = ReminderDecision(shouldPrompt: false, reason: message, nextEligibleAt: nil)
        deployMessage = message
        setupViewModel.syncDetectedDevices(
            devices: availableDevices,
            matchedDevice: nil,
            feedback: .replace(message)
        )
        return persistState(
            status: status,
            device: nil,
            unavailableDevice: device,
            detectedExpiryAt: expiryInfo?.estimatedExpiryAt,
            expirySource: expiryInfo?.source,
            scanResult: scanResult,
            diagnosticMessage: diagnosticMessage,
            pairingAttemptAt: pairingAttemptAt
        )
    }

    private func applyTransientScanFailure(_ errorMessage: String) {
        let now = refreshScheduler.wallNow()
        let lastSeenAtForResolution = matchedDevice != nil || state.currentDeviceStatus == .online
            ? now
            : state.lastDeviceSeenAt
        if lastSeenAtForResolution != nil, connectionConfirmationStartedAt == nil {
            connectionConfirmationStartedAt = now
        }
        let resolution = deviceConnectionStabilizer.resolve(
            evidence: .scanFailed,
            lastSeenAt: lastSeenAtForResolution,
            confirmationStartedAt: connectionConfirmationStartedAt,
            confirmedAbsenceCount: confirmedDeviceAbsenceCount,
            now: now
        )
        let connectionStatus = resolution.deviceStatus
        let isConfirming = resolution == .confirming
        let setupMessage = isConfirming ? "设备检测暂时失败，正在重新确认目标设备连接…" : errorMessage

        availableDevices = []
        matchedDevice = nil
        cancelInstalledAppRetry(resetBackoff: false)
        setupViewModel.syncDetectedDevices(
            devices: [],
            matchedDevice: nil,
            feedback: .replace(setupMessage)
        )
        reminderDecision = ReminderDecision(
            shouldPrompt: false,
            reason: isConfirming ? "设备检测暂时失败，正在重新确认目标设备连接。" : "暂时无法确认目标设备连接。",
            nextEligibleAt: nil
        )
        deployMessage = isConfirming ? "设备检测暂时失败，正在重新确认。" : "暂时无法确认目标设备连接。"
        persistState(status: connectionStatus, device: nil, scanFailure: errorMessage)

        if isConfirming {
            scheduleConnectionConfirmation()
        } else {
            cancelConnectionConfirmation(resetEvidence: true)
        }
    }

    private func scheduleConnectionConfirmation(now: Date? = nil) {
        guard connectionConfirmationTask == nil,
              let startedAt = connectionConfirmationStartedAt else {
            return
        }

        let elapsed = (now ?? refreshScheduler.wallNow())
            .timeIntervalSince(startedAt)
        let remaining = deviceConnectionStabilizer.confirmationInterval - elapsed
        guard remaining > 0 else {
            return
        }

        let firstRetryDelay: TimeInterval = 5
        let delay = elapsed < firstRetryDelay
            ? min(firstRetryDelay - elapsed, remaining)
            : remaining

        connectionConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.refreshScheduler.sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            self.connectionConfirmationTask = nil
            guard self.state.currentDeviceStatus == .confirming else {
                return
            }
            self.refreshDeviceStatus(
                presentation: .background,
                mode: .connectionConfirmation
            )
        }
    }

    private func scheduleTypedConnectionRecheck(after delay: Duration) {
        guard connectionConfirmationTask == nil else {
            return
        }
        connectionConfirmationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.refreshScheduler.sleep(
                    max(delay, .zero)
                )
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self.connectionConfirmationTask = nil
            guard !self.deploymentTransaction.hasActiveTask,
                  !self.state.isDeployRunning else {
                return
            }
            self.refreshDeviceStatus(
                presentation: .background,
                mode: .connectionConfirmation
            )
        }
    }

    private func cancelConnectionConfirmation(resetEvidence: Bool) {
        connectionConfirmationTask?.cancel()
        connectionConfirmationTask = nil
        if resetEvidence {
            connectionConfirmationStartedAt = nil
            confirmedDeviceAbsenceCount = 0
        }
    }

    private func shouldRetryInstalledAppInspection(after outcome: InstalledAppInspectionOutcome) -> Bool {
        guard matchedDevice != nil,
              config.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }

        switch outcome {
        case .notRequested:
            return expiryInfo?.estimatedExpiryAt == nil
        case .found(let appInfo):
            return appInfo.installMetadata?.expectedExpiryAt == nil
                || !stateSettlement.installationMetadataIsCurrent(
                    appInfo,
                    state: state
                )
        case .notInstalled:
            return consecutiveInstalledAppAbsences
                < refreshTimingPolicy.requiredAbsenceCount
        case .failed:
            return true
        }
    }

    private func scheduleInstalledAppRetry() {
        guard installedAppRetryTask == nil, matchedDevice != nil else {
            return
        }

        let index = min(installedAppRetryIndex, installedAppRetryDelays.count - 1)
        let delay = installedAppRetryDelays[index]
        let retrySleep = refreshScheduler.sleep
        installedAppRetryIndex = min(index + 1, installedAppRetryDelays.count - 1)

        installedAppRetryTask = Task { @MainActor [weak self] in
            do {
                try await retrySleep(.seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.installedAppRetryTask = nil
            guard self.matchedDevice != nil else { return }
            self.refreshDeviceStatus(
                presentation: .background,
                mode: .appMetadataRetry
            )
        }
    }

    private func cancelInstalledAppRetry(resetBackoff: Bool) {
        installedAppRetryTask?.cancel()
        installedAppRetryTask = nil
        if resetBackoff {
            installedAppRetryIndex = 0
        }
    }

    @discardableResult
    private func persistInstalledAppInspection(
        _ outcome: InstalledAppInspectionOutcome,
        confirmedAbsent: Bool,
        inspectedAt: Date,
        inspectedDeviceID: String?
    ) -> Bool {
        guard outcome.didRunInspection else {
            return true
        }

        do {
            try commitStateEvents([
                .installationInspection(
                    installationInspectionUpdate(
                        outcome: outcome,
                        confirmedAbsent: confirmedAbsent,
                        inspectedAt: inspectedAt,
                        inspectedDeviceID: inspectedDeviceID
                    )
                )
            ])
            return true
        } catch {
            enterStatePersistenceFailure(error)
            return false
        }
    }

    private func persistPreparedState(_ preparedState: AppState) -> Bool {
        do {
            state = try stateSettlement.commit(
                proposedState: preparedState,
                recoveringFromPersistenceFailure:
                    statePersistenceFailureActive
            )
            statePersistenceFailureActive = false
            return true
        } catch {
            enterStatePersistenceFailure(error)
            return false
        }
    }

    private func installationInspectionUpdate(
        outcome: InstalledAppInspectionOutcome,
        confirmedAbsent: Bool,
        inspectedAt: Date,
        inspectedDeviceID: String?
    ) -> RefreshStateSettlement.InstallationInspectionUpdate {
        RefreshStateSettlement.InstallationInspectionUpdate(
            outcome: outcome,
            confirmedAbsent: confirmedAbsent,
            inspectedAt: inspectedAt,
            inspectedDeviceID: inspectedDeviceID,
            configuredBundleID: config.bundleID,
            unidentifiedEvidenceGracePeriod:
                refreshTimingPolicy.installedAppCacheTTL.timeInterval
        )
    }

    private func updateStateAndPersist(
        _ update: (inout AppState) -> Void
    ) throws {
        state = try stateSettlement.commit(
            currentState: state,
            recoveringFromPersistenceFailure:
                statePersistenceFailureActive,
            update: update
        )
        statePersistenceFailureActive = false
    }

    @discardableResult
    private func commitStateEvents(
        _ events: [RefreshStateSettlement.Event]
    ) throws -> [InstalledAppStateReduction] {
        let commit = try stateSettlement.commit(
            currentState: state,
            recoveringFromPersistenceFailure:
                statePersistenceFailureActive,
            events: events
        )
        state = commit.state
        statePersistenceFailureActive = false
        return commit.installationReductions
    }

    private func enterStatePersistenceFailure(
        _ error: Error,
        prefix: String = "无法写入运行状态"
    ) {
        statePersistenceFailureActive = true
        let message = "\(prefix)，已阻止续签与自动配对：\(error.localizedDescription)"
        if !state.processRecoveryBlocked {
            state.lastErrorSummary = message
        }
        reminderDecision = ReminderDecision(
            shouldPrompt: false,
            reason: message,
            nextEligibleAt: nil
        )
        deployMessage = message
        cancelPendingAutoRefresh()
        cancelPendingDeployRecovery(clearProgress: true)
        cancelPairingTask()
        invalidateReminderDelivery()
    }

    private func autoPinUniqueDeviceIfNeeded(
        _ device: DeviceInfo,
        availableDevices: [DeviceInfo],
        scanResult: DeviceScanResult?
    ) {
        let preferredID = config.preferredDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferredName = config.preferredDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard scanResult?.isCompleteInventory == true,
              preferredID.isEmpty,
              preferredName.isEmpty,
              availableDevices.count == 1,
              availableDevices.first?.id == device.id else {
            return
        }

        var updatedConfig = config
        updatedConfig.preferredDeviceID = device.id
        updatedConfig.preferredDeviceName = device.name

        do {
            try stateStore.saveConfig(updatedConfig)
            config = updatedConfig
            setupViewModel.syncPersistedDeviceSelection(updatedConfig)
        } catch {
            setupViewModel.syncDetectedDevices(
                devices: availableDevices,
                matchedDevice: device,
                feedback: .replace(
                    "已检测到唯一设备，但自动固定失败：\(error.localizedDescription)"
                )
            )
        }
    }

    private func persistResolvedDeviceIdentityIfNeeded(
        _ candidate: DeviceIdentityPersistenceCandidate,
        matchedDevice: DeviceInfo,
        availableDevices: [DeviceInfo]
    ) {
        guard normalizedSummaryValue(config.preferredDeviceID) == nil,
              candidate.deviceID.value == matchedDevice.id,
              DeviceIdentityValidator.isSafe(candidate.displayName) else {
            return
        }

        let normalizeName: (String) -> String = {
            $0.replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        if let preferredName = normalizedSummaryValue(
            config.preferredDeviceName
        ), normalizeName(preferredName) != normalizeName(
            candidate.displayName
        ) {
            return
        }

        var updatedConfig = config
        updatedConfig.preferredDeviceID = candidate.deviceID.value
        updatedConfig.preferredDeviceName = candidate.displayName

        do {
            try stateStore.saveConfig(updatedConfig)
            config = updatedConfig
            setupViewModel.syncPersistedDeviceSelection(updatedConfig)
        } catch {
            setupViewModel.syncDetectedDevices(
                devices: availableDevices,
                matchedDevice: matchedDevice,
                feedback: .replace(
                    "已检测到唯一设备，但自动固定失败：\(error.localizedDescription)"
                )
            )
        }
    }

}
