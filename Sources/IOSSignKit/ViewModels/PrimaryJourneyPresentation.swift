import Foundation

enum PrimaryJourneyPhase: Equatable {
    case needsSetup
    case waitingForDevice
    case monitoring
    case renewalRequired
    case checking
    case countdown
    case recovering
    case deploying
    case completed
    case attention
    case blocked
}

struct PrimaryJourneyHeader: Equatable {
    let title: String
    let detail: String
    let tone: StatusTone
    let systemImage: String
    let lastFullVerificationSummary: String
    let remainingExpiryText: String
    let remainingExpiryComponents: [RemainingExpiryMetricComponent]
    let consumedExpiryProgress: Double?
    let expiredDurationText: String?
}

struct PrimaryJourneyVerificationStep: Equatable, Identifiable {
    enum ID: Equatable, Hashable {
        case environment
        case device
        case signing
    }

    let id: ID
    let title: String
    let value: String
    let detail: String?
    let tone: StatusTone
    let systemImage: String
}

struct PrimaryJourneyTargetDevice: Equatable {
    let value: String
    let detail: String?
    let cardDetail: String?
    let tone: StatusTone
    let badgeSystemImage: String
}

struct PrimaryJourneyAction: Equatable, Identifiable {
    enum ID: Equatable, Hashable {
        case recheck
        case recoveryPreservingRecheck
        case pairDevice
        case requestRefresh
        case retryCurrentRefresh
        case startCountdownNow
        case cancelCountdown
        case cancelRefresh
        case cancelRecovery
        case dismissFeedback
        case openHistory
        case showDeployLog
    }

    enum Placement: Equatable {
        case header
        case task
    }

    enum Style: Equatable {
        case primary
        case secondary
        case destructive
        case quiet
    }

    enum Availability: Equatable {
        case enabled
        case disabled(reason: String)
    }

    let id: ID
    let title: String
    let systemImage: String
    let placement: Placement
    let style: Style
    let availability: Availability

    var isEnabled: Bool {
        availability == .enabled
    }

}

struct PrimaryJourneyTask: Equatable {
    enum Kind: Equatable {
        case processRecoveryBlocked
        case checking
        case countdown
        case recovering
        case deploying
        case currentFeedback
    }

    let kind: Kind
    let title: String
    let detail: String
    let tone: StatusTone
    let systemImage: String
    let progress: OperationActivityProgress?
    let actions: [PrimaryJourneyAction]
}

struct PrimaryJourneyPreviousResult: Equatable {
    enum Outcome: Equatable {
        case success
        case failure
        case cancelled
        case interrupted
        case unknown
    }

    let outcome: Outcome
    let title: String
    let detail: String?
    let tone: StatusTone
    let occurredAt: Date?
    let logPath: String?
}

struct PrimaryJourneyPresentation: Equatable {
    let phase: PrimaryJourneyPhase
    let header: PrimaryJourneyHeader
    let renewalIcon: RenewalIconPresentation
    let targetDevice: PrimaryJourneyTargetDevice
    let verificationSteps: [PrimaryJourneyVerificationStep]
    let currentTask: PrimaryJourneyTask?
    let previousResult: PrimaryJourneyPreviousResult?
    let headerActions: [PrimaryJourneyAction]
    let deviceSelectionIsEnabled: Bool

    var heroActions: [PrimaryJourneyAction] {
        if let currentTask,
           currentTask.kind != .currentFeedback,
           !currentTask.actions.isEmpty
        {
            return []
        }

        return headerActions.filter { $0.placement == .header }
    }
}

enum PrimaryJourneyActionOutcome: Equatable {
    case performed
    case manualSigningChoiceRequired
    case openHistory
    case showDeployLog(String)
    case rejected(reason: String)
}

struct PrimaryJourneyPresentationContext {
    let needsSetup: Bool
    let environmentSummary: String
    let environmentTone: StatusTone
    let deviceValue: String
    let deviceDetail: String?
    let lastDeviceSeenCardSummary: String
    let deviceTone: StatusTone
    let deviceIsPinned: Bool
    let installationTone: StatusTone
    let expirySummary: String
    let expiryCardSummary: String?
    let expiryDetail: String?
    let expiryTone: StatusTone
    let lastFullVerificationSummary: String
    let remainingExpiryText: String
    let remainingExpiryComponents: [RemainingExpiryMetricComponent]
    let consumedExpiryProgress: Double?
    let expiredDurationText: String?
    let expiryUrgency: RemainingExpiryUrgency
    let isExpired: Bool
    let activity: OperationActivityPresentation
    let isProcessRecoveryBlocked: Bool
    let isCountdownActive: Bool
    let isRecoveryActive: Bool
    let isDeploymentActive: Bool
    let isChecking: Bool
    let hasManualSigningChoice: Bool
    let canRefresh: Bool
    let canCancelRefresh: Bool
    let refreshDisabledReason: String?
    let canPairDevice: Bool
    let pairDeviceDisabledReason: String?
    let previousResult: PrimaryJourneyPreviousResult?
    let deployLogText: String
}

extension PrimaryJourneyPresentation {
    static func make(
        context: PrimaryJourneyPresentationContext
    ) -> PrimaryJourneyPresentation {
        let environmentTone = context.environmentTone
        let deviceIsOffline = deviceStepTitle(context: context) == "设备离线"
        let deviceTone: StatusTone = deviceIsOffline
            ? .neutral
            : context.deviceTone
        let signingTone = signingStepTone(context: context)
        let verificationSteps = [
            PrimaryJourneyVerificationStep(
                id: .environment,
                title: environmentStepTitle(context: context),
                value: context.environmentSummary,
                detail: nil,
                tone: environmentTone,
                systemImage: verificationSystemImage(
                    for: .environment,
                    tone: environmentTone,
                    context: context
                )
            ),
            PrimaryJourneyVerificationStep(
                id: .device,
                title: deviceStepTitle(context: context),
                value: deviceStepSummary(context: context),
                detail: nil,
                tone: deviceTone,
                systemImage: verificationSystemImage(
                    for: .device,
                    tone: deviceTone,
                    context: context
                )
            ),
            PrimaryJourneyVerificationStep(
                id: .signing,
                title: signingStepTitle(context: context),
                value: signingStepSummary(context: context),
                detail: nil,
                tone: signingTone,
                systemImage: verificationSystemImage(
                    for: .signing,
                    tone: signingTone,
                    context: context
                )
            )
        ]
        let targetDevice = makeTargetDevice(context: context)

        if context.isProcessRecoveryBlocked {
            let reason = "续签进程状态尚未恢复，当前不能执行此操作。"
            let task = makeTask(
                kind: .processRecoveryBlocked,
                activity: context.activity,
                actions: []
            )
            let header = makeHeader(
                activity: context.activity,
                lastFullVerificationSummary:
                    context.lastFullVerificationSummary,
                remainingExpiryText: context.remainingExpiryText,
                remainingExpiryComponents:
                    context.remainingExpiryComponents,
                consumedExpiryProgress: context.consumedExpiryProgress,
                expiredDurationText: context.expiredDurationText
            )
            return PrimaryJourneyPresentation(
                phase: .blocked,
                header: header,
                renewalIcon: RenewalIconPresentation.make(
                    phase: .blocked,
                    headerTone: header.tone,
                    deviceTone: context.deviceTone,
                    expiryUrgency: context.expiryUrgency,
                    isExpired: context.isExpired,
                    progress: task.progress
                ),
                targetDevice: targetDevice,
                verificationSteps: verificationSteps,
                currentTask: task,
                previousResult: context.previousResult,
                headerActions: [
                    recheckAction(
                        id: .recheck,
                        availability: .disabled(reason: reason)
                    ),
                    refreshAction(
                        availability: .disabled(reason: reason)
                    )
                ],
                deviceSelectionIsEnabled: false
            )
        }

        let task = currentTask(context: context)
        let phase = phase(context: context, task: task)
        let header = activityOwnsHeader(task: task, phase: phase)
            ? makeHeader(
                activity: context.activity,
                lastFullVerificationSummary:
                    context.lastFullVerificationSummary,
                remainingExpiryText: context.remainingExpiryText,
                remainingExpiryComponents:
                    context.remainingExpiryComponents,
                consumedExpiryProgress: context.consumedExpiryProgress,
                expiredDurationText: context.expiredDurationText
            )
            : makeStableHeader(context: context, phase: phase)
        let renewalIcon = RenewalIconPresentation.make(
            phase: phase,
            headerTone: header.tone,
            deviceTone: context.deviceTone,
            expiryUrgency: context.expiryUrgency,
            isExpired: context.isExpired,
            progress: task?.progress
        )

        return PrimaryJourneyPresentation(
            phase: phase,
            header: header,
            renewalIcon: renewalIcon,
            targetDevice: targetDevice,
            verificationSteps: verificationSteps,
            currentTask: task,
            previousResult: context.previousResult,
            headerActions: headerActions(
                context: context,
                task: task,
                phase: phase
            ),
            deviceSelectionIsEnabled: deviceSelectionIsEnabled(
                context: context,
                task: task
            )
        )
    }

    private static func activityOwnsHeader(
        task: PrimaryJourneyTask?,
        phase: PrimaryJourneyPhase
    ) -> Bool {
        switch task?.kind {
        case .processRecoveryBlocked, .checking, .countdown,
             .recovering, .deploying:
            return true
        case .currentFeedback:
            return phase == .completed || phase == .attention
        case nil:
            return false
        }
    }

    private static func environmentStepTitle(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        switch context.environmentTone {
        case .good:
            return "环境已就绪"
        case .critical:
            return "环境检查失败"
        case .warning:
            return "环境待确认"
        case .info:
            return "正在检查环境"
        case .neutral:
            return "运行环境"
        }
    }

    private static func makeTargetDevice(
        context: PrimaryJourneyPresentationContext
    ) -> PrimaryJourneyTargetDevice {
        let parts = context.deviceValue.components(separatedBy: " · ")
        let value = parts.first ?? context.deviceValue
        let detail = [
            context.deviceIsPinned ? "固定设备" : nil,
            context.deviceDetail
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let cardDetail: String?
        if deviceStepTitle(context: context) == "设备离线" {
            var lines = [
                context.lastDeviceSeenCardSummary == "暂无记录"
                    ? "最后在线：暂无记录"
                    : "最后在线：\(context.lastDeviceSeenCardSummary)"
            ]
            lines.append(offlineAppCardSummary(context: context))
            cardDetail = lines.joined(separator: "\n")
        } else {
            cardDetail = nil
        }

        return PrimaryJourneyTargetDevice(
            value: value,
            detail: detail.isEmpty ? nil : detail,
            cardDetail: cardDetail,
            tone: context.deviceTone,
            badgeSystemImage: targetDeviceBadgeSystemImage(context: context)
        )
    }

    private static func offlineAppCardSummary(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        if context.installationTone == .critical {
            return "App 未安装"
        }
        if let expiryCardSummary = context.expiryCardSummary {
            return "App 已安装 · 到期 \(expiryCardSummary)"
        }

        switch context.installationTone {
        case .good:
            return "App 已安装 · 到期待确认"
        case .info:
            return "App 正在检查"
        case .warning, .neutral:
            return "App 状态待确认"
        case .critical:
            return "App 未安装"
        }
    }

    private static func targetDeviceBadgeSystemImage(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        let deviceTitle = deviceStepTitle(context: context)
        if deviceTitle == "设备离线" {
            return "wifi.slash"
        }

        switch context.deviceTone {
        case .good:
            return "wifi"
        case .critical:
            return "exclamationmark"
        case .warning:
            return "questionmark"
        case .info:
            return "arrow.clockwise"
        case .neutral:
            return "ellipsis"
        }
    }

    private static func deviceStepTitle(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        let detail = context.deviceDetail ?? ""
        if detail.contains("离线") || context.deviceValue.contains("离线") {
            return "设备离线"
        }

        switch context.deviceTone {
        case .good:
            return "设备已连接"
        case .critical:
            return "设备不可用"
        case .warning:
            return "设备待确认"
        case .info:
            return "正在检查设备"
        case .neutral:
            return "目标设备"
        }
    }

    private static func deviceStepSummary(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        let title = deviceStepTitle(context: context)
        if title == "设备离线" {
            return "未检测到目标设备"
        }
        return context.deviceDetail ?? context.deviceValue
    }

    private static func signingStepTitle(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        if deviceStepTitle(context: context) == "设备离线" {
            return "签名状态"
        }

        switch signingStepTone(context: context) {
        case .good:
            return "签名有效"
        case .critical:
            return context.isExpired ? "签名已到期" : "签名需要处理"
        case .warning:
            return "签名待确认"
        case .info:
            return "正在检查签名"
        case .neutral:
            return "App 与签名"
        }
    }

    private static func signingStepSummary(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        if deviceStepTitle(context: context) == "设备离线" {
            return "等待设备后可确认"
        }
        if context.deviceTone == .warning
            || context.deviceTone == .critical {
            return "需重新确认设备状态"
        }
        return context.expirySummary
    }

    private static func signingStepTone(
        context: PrimaryJourneyPresentationContext
    ) -> StatusTone {
        if deviceStepTitle(context: context) == "设备离线" {
            return .neutral
        }
        return combinedTone(
            context.deviceTone,
            combinedTone(
                context.installationTone,
                context.expiryTone
            )
        )
    }

    private static func verificationSystemImage(
        for id: PrimaryJourneyVerificationStep.ID,
        tone: StatusTone,
        context: PrimaryJourneyPresentationContext
    ) -> String {
        switch id {
        case .environment:
            switch tone {
            case .good:
                return "checkmark"
            case .critical:
                return "xmark"
            case .warning:
                return "questionmark"
            case .info:
                return "arrow.clockwise"
            case .neutral:
                return "ellipsis"
            }
        case .device:
            if deviceStepTitle(context: context) == "设备离线" {
                return "minus"
            }
            switch tone {
            case .good:
                return "iphone"
            case .critical:
                return "xmark"
            case .warning:
                return "questionmark"
            case .info:
                return "arrow.clockwise"
            case .neutral:
                return "iphone"
            }
        case .signing:
            if deviceStepTitle(context: context) == "设备离线" {
                return "minus"
            }
            switch tone {
            case .good:
                return "checkmark"
            case .critical:
                return "exclamationmark"
            case .warning:
                return "questionmark"
            case .info:
                return "arrow.clockwise"
            case .neutral:
                return "questionmark"
            }
        }
    }

    private static func combinedTone(
        _ lhs: StatusTone,
        _ rhs: StatusTone
    ) -> StatusTone {
        return tonePriority(lhs) >= tonePriority(rhs)
            ? lhs
            : rhs
    }

    private static func tonePriority(_ tone: StatusTone) -> Int {
        switch tone {
        case .neutral:
            return 0
        case .good:
            return 1
        case .info:
            return 2
        case .warning:
            return 3
        case .critical:
            return 4
        }
    }

    private static func currentTask(
        context: PrimaryJourneyPresentationContext
    ) -> PrimaryJourneyTask? {
        if context.isCountdownActive {
            return makeTask(
                kind: .countdown,
                activity: context.activity,
                actions: taskActions(context: context)
            )
        }
        if context.isRecoveryActive {
            return makeTask(
                kind: .recovering,
                activity: context.activity,
                actions: taskActions(context: context)
            )
        }
        if context.isDeploymentActive {
            return makeTask(
                kind: .deploying,
                activity: context.activity,
                actions: taskActions(context: context)
            )
        }
        if context.isChecking {
            return makeTask(
                kind: .checking,
                activity: context.activity,
                actions: taskActions(context: context)
            )
        }
        if context.activity.source == .currentFeedback {
            return makeTask(
                kind: .currentFeedback,
                activity: context.activity,
                actions: taskActions(context: context)
            )
        }
        return nil
    }

    private static func phase(
        context: PrimaryJourneyPresentationContext,
        task: PrimaryJourneyTask?
    ) -> PrimaryJourneyPhase {
        switch task?.kind {
        case .processRecoveryBlocked:
            return .blocked
        case .checking:
            return .checking
        case .countdown:
            return .countdown
        case .recovering:
            return .recovering
        case .deploying:
            return .deploying
        case .currentFeedback:
            switch context.activity.kind {
            case .success:
                return .completed
            case .failure, .warning:
                return .attention
            case .idle, .checking, .countdown, .deploying,
                 .cancelled, .info:
                break
            }
        case nil:
            break
        }

        if context.needsSetup {
            return .needsSetup
        }
        if context.environmentTone != .good {
            return .attention
        }
        if context.deviceTone != .good {
            return .waitingForDevice
        }
        if context.isExpired {
            return .renewalRequired
        }
        return .monitoring
    }

    private static func makeStableHeader(
        context: PrimaryJourneyPresentationContext,
        phase: PrimaryJourneyPhase
    ) -> PrimaryJourneyHeader {
        let title: String
        let detail: String
        let tone: StatusTone
        let systemImage: String

        switch phase {
        case .needsSetup:
            title = "完成项目配置"
            detail = "选择项目并确认续签目标后即可开始检查签名。"
            tone = .warning
            systemImage = "gearshape.fill"
        case .waitingForDevice:
            title = "先重新确认设备状态"
            detail = waitingForDeviceDetail(context: context)
            tone = context.deviceTone == .critical ? .critical : .warning
            systemImage = "iphone.slash"
        case .renewalRequired:
            title = "签名需要续期"
            detail = "目标 App 已到期，可以立即续签。"
            tone = .critical
            systemImage = "exclamationmark.circle.fill"
        case .monitoring:
            title = "当前无需续期"
            detail = context.lastFullVerificationSummary
            tone = .good
            systemImage = "checkmark.seal.fill"
        case .completed:
            title = "续签完成"
            detail = "已记录本次续签结果。"
            tone = .good
            systemImage = "checkmark.circle.fill"
        case .attention:
            title = "运行环境需要处理"
            detail = context.environmentSummary
            tone = context.environmentTone
            systemImage = "exclamationmark.triangle.fill"
        case .checking, .countdown, .recovering, .deploying, .blocked:
            title = context.activity.title
            detail = context.activity.detail
            tone = context.activity.tone
            systemImage = context.activity.systemImage
        }

        return PrimaryJourneyHeader(
            title: title,
            detail: detail,
            tone: tone,
            systemImage: systemImage,
            lastFullVerificationSummary:
                context.lastFullVerificationSummary,
            remainingExpiryText: context.remainingExpiryText,
            remainingExpiryComponents:
                context.remainingExpiryComponents,
            consumedExpiryProgress: context.consumedExpiryProgress,
            expiredDurationText: context.expiredDurationText
        )
    }

    private static func waitingForDeviceDetail(
        context: PrimaryJourneyPresentationContext
    ) -> String {
        let firstLine: String
        if context.remainingExpiryText == "--" {
            firstLine = "签名状态将在设备连接后确认"
        } else if context.isExpired {
            firstLine = "签名已到期，设备连接后可立即续签"
        } else if let component = context.remainingExpiryComponents.first {
            let compactExpiry = [component.value, component.unit]
                .compactMap { $0 }
                .joined(separator: " ")
            firstLine = "签名剩余 \(compactExpiry)，设备连接后可立即续签"
        } else {
            firstLine = "签名剩余 \(context.remainingExpiryText)，设备连接后可立即续签"
        }

        return [
            firstLine,
            "请确认 iPhone 已解锁，并与 Mac 处于同一网络"
        ].joined(separator: "\n")
    }

    private static func headerActions(
        context: PrimaryJourneyPresentationContext,
        task: PrimaryJourneyTask?,
        phase: PrimaryJourneyPhase
    ) -> [PrimaryJourneyAction] {
        let taskOwnsPrimaryAction = task?.actions.contains {
            $0.style == .primary && $0.isEnabled
        } == true
        let recheckID: PrimaryJourneyAction.ID = context.isRecoveryActive
            ? .recoveryPreservingRecheck
            : .recheck
        let disabledReason = headerDisabledReason(
            context: context,
            taskOwnsPrimaryAction: taskOwnsPrimaryAction
        )
        let recheckAvailability: PrimaryJourneyAction.Availability =
            disabledReason.map(PrimaryJourneyAction.Availability.disabled)
            ?? .enabled
        let refreshAvailability: PrimaryJourneyAction.Availability
        if let disabledReason {
            refreshAvailability = .disabled(reason: disabledReason)
        } else if context.canRefresh {
            refreshAvailability = .enabled
        } else {
            refreshAvailability = .disabled(
                reason: context.refreshDisabledReason
                    ?? "当前条件不允许开始续签。"
            )
        }

        return [
            recheckAction(
                id: recheckID,
                style: phase == .renewalRequired
                    ? .secondary
                    : .primary,
                availability: recheckAvailability
            ),
            pairingActionOrRefresh(
                context: context,
                phase: phase,
                refreshAvailability: refreshAvailability
            )
        ]
    }

    private static func pairingActionOrRefresh(
        context: PrimaryJourneyPresentationContext,
        phase: PrimaryJourneyPhase,
        refreshAvailability: PrimaryJourneyAction.Availability
    ) -> PrimaryJourneyAction {
        guard phase == .waitingForDevice,
              context.deviceIsPinned else {
            return refreshAction(
                style: phase == .renewalRequired
                    ? .primary
                    : .secondary,
                availability: refreshAvailability
            )
        }

        return PrimaryJourneyAction(
            id: .pairDevice,
            title: "尝试配对",
            systemImage: "link",
            placement: .header,
            style: .secondary,
            availability: context.canPairDevice
                ? .enabled
                : .disabled(
                    reason: context.pairDeviceDisabledReason
                        ?? "当前无法尝试配对目标设备。"
                )
        )
    }

    private static func headerDisabledReason(
        context: PrimaryJourneyPresentationContext,
        taskOwnsPrimaryAction: Bool
    ) -> String? {
        if taskOwnsPrimaryAction {
            return "请先处理当前任务。"
        }
        if context.isCountdownActive {
            return "自动续期倒计时正在进行。"
        }
        if context.isDeploymentActive {
            return "续签正在进行中。"
        }
        if context.isChecking {
            return "正在检查设备与安装状态。"
        }
        return nil
    }

    private static func deviceSelectionIsEnabled(
        context: PrimaryJourneyPresentationContext,
        task: PrimaryJourneyTask?
    ) -> Bool {
        guard !context.hasManualSigningChoice else {
            return false
        }
        switch task?.kind {
        case .processRecoveryBlocked, .checking, .countdown,
             .recovering, .deploying:
            return false
        case .currentFeedback, nil:
            return true
        }
    }

    private static func taskActions(
        context: PrimaryJourneyPresentationContext
    ) -> [PrimaryJourneyAction] {
        switch context.activity.actions {
        case .none, .checking:
            return []
        case .countdown:
            return [
                taskAction(
                    id: .startCountdownNow,
                    title: "立即开始",
                    systemImage: "play.fill",
                    style: .primary,
                    availability: context.canRefresh
                        ? .enabled
                        : .disabled(
                            reason: context.refreshDisabledReason
                                ?? "当前条件不允许开始续签。"
                        )
                ),
                taskAction(
                    id: .cancelCountdown,
                    title: "取消",
                    systemImage: "xmark",
                    style: .quiet,
                    availability: .enabled
                )
            ]
        case .deploying:
            return [
                taskAction(
                    id: .showDeployLog,
                    title: "查看日志",
                    systemImage: "terminal",
                    style: .quiet,
                    availability: context.deployLogText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty && !context.isDeploymentActive
                        ? .disabled(reason: "当前还没有续签日志。")
                        : .enabled
                ),
                taskAction(
                    id: .cancelRefresh,
                    title: "停止续签",
                    systemImage: "stop.circle",
                    style: .destructive,
                    availability: context.canCancelRefresh
                        ? .enabled
                        : .disabled(reason: "当前续签无法安全取消。")
                )
            ]
        case .success:
            return [dismissAction()]
        case .recovery:
            return [
                taskAction(
                    id: .recoveryPreservingRecheck,
                    title: "重新检查",
                    systemImage: "arrow.clockwise",
                    style: .primary,
                    availability: .enabled
                ),
                taskAction(
                    id: .cancelRecovery,
                    title: "取消重试",
                    systemImage: "xmark",
                    style: .quiet,
                    availability: context.canCancelRefresh
                        ? .enabled
                        : .disabled(reason: "当前没有可取消的恢复任务。")
                )
            ]
        case .recheck:
            return [
                taskAction(
                    id: .recheck,
                    title: "重新检查",
                    systemImage: "arrow.clockwise",
                    style: .primary,
                    availability: .enabled
                ),
                dismissAction()
            ]
        case .retry:
            return [
                taskAction(
                    id: .retryCurrentRefresh,
                    title: "重试",
                    systemImage: "arrow.clockwise",
                    style: .primary,
                    availability: context.canRefresh
                        ? .enabled
                        : .disabled(
                            reason: context.refreshDisabledReason
                                ?? "当前条件不允许重试。"
                        )
                ),
                dismissAction()
            ]
        case .dismiss:
            return [dismissAction()]
        }
    }

    private static func taskAction(
        id: PrimaryJourneyAction.ID,
        title: String,
        systemImage: String,
        style: PrimaryJourneyAction.Style,
        availability: PrimaryJourneyAction.Availability
    ) -> PrimaryJourneyAction {
        PrimaryJourneyAction(
            id: id,
            title: title,
            systemImage: systemImage,
            placement: .task,
            style: style,
            availability: availability
        )
    }

    private static func dismissAction() -> PrimaryJourneyAction {
        taskAction(
            id: .dismissFeedback,
            title: "关闭",
            systemImage: "xmark",
            style: .quiet,
            availability: .enabled
        )
    }

    private static func makeHeader(
        activity: OperationActivityPresentation,
        lastFullVerificationSummary: String,
        remainingExpiryText: String,
        remainingExpiryComponents: [RemainingExpiryMetricComponent],
        consumedExpiryProgress: Double?,
        expiredDurationText: String?
    ) -> PrimaryJourneyHeader {
        PrimaryJourneyHeader(
            title: activity.title,
            detail: activity.detail,
            tone: activity.tone,
            systemImage: activity.systemImage,
            lastFullVerificationSummary: lastFullVerificationSummary,
            remainingExpiryText: remainingExpiryText,
            remainingExpiryComponents: remainingExpiryComponents,
            consumedExpiryProgress: consumedExpiryProgress,
            expiredDurationText: expiredDurationText
        )
    }

    private static func makeTask(
        kind: PrimaryJourneyTask.Kind,
        activity: OperationActivityPresentation,
        actions: [PrimaryJourneyAction]
    ) -> PrimaryJourneyTask {
        PrimaryJourneyTask(
            kind: kind,
            title: activity.title,
            detail: activity.detail,
            tone: activity.tone,
            systemImage: activity.systemImage,
            progress: activity.progress,
            actions: actions
        )
    }

    private static func recheckAction(
        id: PrimaryJourneyAction.ID,
        style: PrimaryJourneyAction.Style = .secondary,
        availability: PrimaryJourneyAction.Availability
    ) -> PrimaryJourneyAction {
        PrimaryJourneyAction(
            id: id,
            title: "重新检查",
            systemImage: "arrow.clockwise",
            placement: .header,
            style: style,
            availability: availability
        )
    }

    private static func refreshAction(
        style: PrimaryJourneyAction.Style = .primary,
        availability: PrimaryJourneyAction.Availability
    ) -> PrimaryJourneyAction {
        PrimaryJourneyAction(
            id: .requestRefresh,
            title: "立即续签",
            systemImage: "arrow.triangle.2.circlepath.circle",
            placement: .header,
            style: style,
            availability: availability
        )
    }
}
