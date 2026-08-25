import Foundation

struct RefreshStateSettlement {
    enum Event {
        case deviceObservation(DeviceObservationUpdate)
        case installationInspection(InstallationInspectionUpdate)
        case deploymentStarted(
            token: String,
            source: RefreshTriggerSource,
            startedAt: Date
        )
        case deploymentProcessRecorded(
            processGroupID: Int32,
            token: String
        )
        case deploymentResult(
            DeployResult,
            context: DeploymentContext,
            isCurrentTarget: Bool,
            cancellationResult: RefreshResult
        )
        case targetEvidenceInvalidated
        case reminderDelivered(Date)
    }

    struct Commit {
        let state: AppState
        let installationReductions: [InstalledAppStateReduction]
    }

    struct DeviceObservationUpdate {
        let status: DeviceStatus
        let device: DeviceInfo?
        let unavailableDevice: UnavailableDeviceInfo?
        let detectedExpiryAt: Date?
        let expirySource: ExpirySource?
        let scanResult: DeviceScanResult?
        let observationDiagnostics: DeviceObservationDiagnostics?
        let scanFailure: String?
        let diagnosticMessage: String?
        let pairingAttemptAt: Date?
        let pairingDeviceID: String?
        let now: Date
    }

    struct InstallationInspectionUpdate {
        let outcome: InstalledAppInspectionOutcome
        let confirmedAbsent: Bool
        let inspectedAt: Date
        let inspectedDeviceID: String?
        let configuredBundleID: String?
        let unidentifiedEvidenceGracePeriod: TimeInterval
    }

    private let stateStore: RefreshStateStore

    init(stateStore: RefreshStateStore) {
        self.stateStore = stateStore
    }

    func commit(
        currentState: AppState,
        recoveringFromPersistenceFailure: Bool,
        events: [Event]
    ) throws -> Commit {
        var installationReductions: [InstalledAppStateReduction] = []
        let state = try commit(
            currentState: currentState,
            recoveringFromPersistenceFailure:
                recoveringFromPersistenceFailure
        ) { state in
            for event in events {
                if let reduction = apply(event, to: &state) {
                    installationReductions.append(reduction)
                }
            }
        }
        return Commit(
            state: state,
            installationReductions: installationReductions
        )
    }

    @discardableResult
    func apply(
        _ event: Event,
        to state: inout AppState
    ) -> InstalledAppStateReduction? {
        switch event {
        case .deviceObservation(let update):
            applyDeviceObservation(update, to: &state)
        case .installationInspection(let update):
            return applyInstallationInspection(update, to: &state)
        case .deploymentStarted(let token, let source, let startedAt):
            state.isDeployRunning = true
            state.deploymentRecoveryBlocked = false
            state.activeDeployProcessGroupID = nil
            state.activeDeploymentToken = token
            state.lastAttemptAt = startedAt
            if source.isAutomatic {
                state.lastAutomaticAttemptAt = startedAt
                appendAutomaticRefreshEvent(
                    .deploymentCommitted,
                    to: &state
                )
            }
            state.lastResult = .running
        case .deploymentProcessRecorded(let processGroupID, let token):
            state.activeDeployProcessGroupID = processGroupID
            state.activeDeploymentToken = token
        case .deploymentResult(
            let result,
            let context,
            let isCurrentTarget,
            let cancellationResult
        ):
            applyDeploymentResult(
                result,
                context: context,
                isCurrentTarget: isCurrentTarget,
                cancellationResult: cancellationResult,
                to: &state
            )
        case .targetEvidenceInvalidated:
            invalidateTargetEvidence(in: &state)
        case .reminderDelivered(let deliveredAt):
            state.lastPromptAt = deliveredAt
        }
        return nil
    }

    func commit(
        currentState: AppState,
        recoveringFromPersistenceFailure: Bool,
        update: (inout AppState) -> Void
    ) throws -> AppState {
        var nextState = currentState
        update(&nextState)
        return try commit(
            proposedState: nextState,
            recoveringFromPersistenceFailure:
                recoveringFromPersistenceFailure
        )
    }

    func commit(
        proposedState: AppState,
        recoveringFromPersistenceFailure: Bool
    ) throws -> AppState {
        var nextState = proposedState
        if recoveringFromPersistenceFailure,
           !nextState.processRecoveryBlocked,
           isPersistenceDiagnostic(nextState.lastErrorSummary) {
            nextState.lastErrorSummary = nil
        }
        try stateStore.saveState(nextState)
        return nextState
    }

    func applyDeviceObservation(
        _ update: DeviceObservationUpdate,
        to state: inout AppState
    ) {
        state.currentDeviceStatus = update.status
        if let device = update.device {
            state.currentDeviceName = device.name
            state.currentDeviceOS = device.osVersion
            state.lastDeviceSeenAt = update.now
        } else if let unavailableDevice = update.unavailableDevice {
            state.currentDeviceName = unavailableDevice.name
            state.currentDeviceOS = unavailableDevice.osVersion
        } else if update.status == .offline {
            state.currentDeviceName = nil
            state.currentDeviceOS = nil
        }

        if let detectedExpiryAt = update.detectedExpiryAt {
            state.lastDetectedExpiryAt = detectedExpiryAt
        }
        if let expirySource = update.expirySource {
            state.expirySource = expirySource
        }
        if let scanResult = update.scanResult {
            state.lastDeviceScanSource = scanResult.source.displayName
            state.lastDeviceScanFailure = scanResult.diagnostics.message
        } else if let diagnostics = update.observationDiagnostics {
            state.lastDeviceScanSource = diagnostics.source.displayName
            state.lastDeviceScanFailure = diagnostics.quality == .complete
                ? nil
                : diagnostics.summary
        } else if let scanFailure = update.scanFailure {
            state.lastDeviceScanSource = "失败"
            state.lastDeviceScanFailure = scanFailure
        } else if let diagnosticMessage = update.diagnosticMessage {
            state.lastDeviceScanFailure = diagnosticMessage
        }
        if let pairingAttemptAt = update.pairingAttemptAt {
            state.lastPairingAttemptAt = pairingAttemptAt
            state.lastPairingDeviceID = update.pairingDeviceID
        }
    }

    func applyDeploymentResult(
        _ result: DeployResult,
        context: DeploymentContext,
        isCurrentTarget: Bool,
        cancellationResult: RefreshResult,
        to state: inout AppState
    ) {
        if context.source.isAutomatic, isCurrentTarget {
            appendAutomaticRefreshEvent(.settled, to: &state)
        }
        guard result.processGroupTerminationWasConfirmed else {
            state.isDeployRunning = false
            state.deploymentRecoveryBlocked = true
            state.lastResult = .interrupted
            state.lastErrorSummary =
                "续签部署进程已结束，但无法确认完整进程树已退出；已阻止新的续签，重启 iOSSignKit 后将再次核验。"
            state.lastLogPath = result.logPath
            return
        }
        guard result.profileCacheRecoveryWasConfirmed else {
            state.isDeployRunning = false
            state.deploymentRecoveryBlocked = true
            state.activeDeployProcessGroupID = nil
            state.lastResult = .interrupted
            state.lastErrorSummary =
                "续签部署进程已结束，但无法确认签名描述文件缓存事务已提交或完整恢复；已阻止新的续签，重启 iOSSignKit 后将按事务令牌再次恢复。"
            state.lastLogPath = result.logPath
            return
        }
        state.isDeployRunning = false
        state.deploymentRecoveryBlocked = false
        state.activeDeployProcessGroupID = nil
        state.activeDeploymentToken = nil
        guard isCurrentTarget else {
            if state.lastResult == .running {
                state.lastResult = nil
            }
            return
        }

        state.lastLogPath = result.logPath
        switch result.outcome {
        case .success:
            state.lastResult = .success
            state.lastAutomaticRecoveryFailureAt = nil
            state.lastSuccessAt = result.finishedAt
            state.activeInstallationSuccessAt = result.finishedAt
            state.lastExpiryVerifiedAt =
                result.verifiedProfileExpirationDate == nil
                    ? nil
                    : result.finishedAt
            state.lastAppInspectionAt = nil
            state.lastAppInspectionFailure = nil
            if let verifiedProfileExpirationDate =
                result.verifiedProfileExpirationDate {
                state.lastDetectedExpiryAt = verifiedProfileExpirationDate
                state.expirySource = .verifiedDeploymentProfile
            } else {
                state.lastDetectedExpiryAt =
                    PersonalSigningValidity.expiryDate(
                        after: result.finishedAt
                    )
                state.expirySource = .deployTimeEstimate
            }
            state.targetAppPresence = .unknown
            state.targetAppBundleID = context.config.bundleID
            state.targetDeviceID = context.device.id
            state.targetAppVersion = nil
            state.targetAppBuildVersion = nil
            state.targetAppURL = nil
            state.isTargetAppExpiryEvidenceVerified = true
            state.lastErrorSummary = nil
        case .failure, .timedOut:
            state.lastResult = .failure
            state.lastErrorSummary = result.summary
            if context.source == .automaticRecovery {
                state.lastAutomaticRecoveryFailureAt = result.finishedAt
            }
        case .cancelled:
            state.lastResult = cancellationResult
            state.lastErrorSummary = cancellationResult == .interrupted
                ? "续签因 iOSSignKit 退出而中断。"
                : result.summary
        }
    }

    @discardableResult
    func applyInstallationInspection(
        _ update: InstallationInspectionUpdate,
        to state: inout AppState
    ) -> InstalledAppStateReduction {
        guard update.outcome.didRunInspection else {
            return InstalledAppStateReduction(
                expiryEvidenceVerified:
                    state.isTargetAppExpiryEvidenceVerified,
                failureMessage: state.lastAppInspectionFailure
            )
        }

        state.lastAppInspectionAt = update.inspectedAt
        switch update.outcome {
        case .notRequested:
            return InstalledAppStateReduction(
                expiryEvidenceVerified:
                    state.isTargetAppExpiryEvidenceVerified,
                failureMessage: state.lastAppInspectionFailure
            )
        case .found(let appInfo):
            return applyFoundApp(
                appInfo,
                update: update,
                to: &state
            )
        case .notInstalled:
            if update.confirmedAbsent {
                state.isTargetAppExpiryEvidenceVerified = false
                state.activeInstallationSuccessAt = nil
                state.lastAutomaticRecoveryFailureAt = nil
                state.targetAppVersion = nil
                state.targetAppBuildVersion = nil
                state.targetAppURL = nil
            }
            state.targetAppPresence = update.confirmedAbsent
                ? .confirmedNotInstalled
                : .confirmingNotInstalled
            state.targetAppBundleID = update.configuredBundleID
            state.targetDeviceID = update.inspectedDeviceID
            if update.confirmedAbsent {
                state.lastDetectedExpiryAt = nil
                state.expirySource = nil
                state.lastExpiryVerifiedAt = nil
            }
            let failureMessage = update.confirmedAbsent
                ? nil
                : "暂未检测到目标 App，正在重新确认安装状态。"
            state.lastAppInspectionFailure = failureMessage
            return InstalledAppStateReduction(
                expiryEvidenceVerified:
                    state.isTargetAppExpiryEvidenceVerified,
                failureMessage: failureMessage
            )
        case .failed(let failure):
            state.lastAppInspectionFailure = failure
            return InstalledAppStateReduction(
                expiryEvidenceVerified:
                    state.isTargetAppExpiryEvidenceVerified,
                failureMessage: failure
            )
        }
    }

    private func applyFoundApp(
        _ appInfo: InstalledAppInfo,
        update: InstallationInspectionUpdate,
        to state: inout AppState
    ) -> InstalledAppStateReduction {
        let previousAppURL = state.targetAppURL.flatMap(
            InstalledAppIdentity.normalizedAppURL
        )
        let currentAppURL = InstalledAppIdentity.normalizedAppURL(
            appInfo.appURL
        )
        if !appInfo.builtByDeveloper {
            state.activeInstallationSuccessAt = nil
            state.lastAutomaticRecoveryFailureAt = nil
            state.lastDetectedExpiryAt = nil
            state.expirySource = nil
            state.lastExpiryVerifiedAt = nil
            state.targetAppPresence = .installed
            state.targetAppBundleID = appInfo.bundleIdentifier
            state.targetDeviceID = update.inspectedDeviceID
            state.isTargetAppExpiryEvidenceVerified = false
            state.targetAppVersion = appInfo.version
            state.targetAppBuildVersion = appInfo.bundleVersion
            state.targetAppURL = currentAppURL
            let failureMessage =
                "检测到的 App 不是开发者签名安装，已停止到期提醒与自动续期。"
            state.lastAppInspectionFailure = failureMessage
            return InstalledAppStateReduction(
                expiryEvidenceVerified: false,
                failureMessage: failureMessage
            )
        }

        let identityChanged =
            (previousAppURL != nil && previousAppURL != currentAppURL)
            || (state.targetAppVersion != nil
                && state.targetAppVersion != appInfo.version)
            || (state.targetAppBuildVersion != nil
                && state.targetAppBuildVersion != appInfo.bundleVersion)
        let metadataIsCurrent = installationMetadataIsCurrent(
            appInfo,
            state: state
        )
        let hasValidatedMetadata =
            appInfo.installMetadataValidation == .valid
                && metadataIsCurrent
                && !identityChanged
        let hasCurrentMetadataExpiry = hasValidatedMetadata
            && appInfo.installMetadata?.expectedExpiryAt != nil
        let evidenceVerified = hasValidatedMetadata
            || (!identityChanged
                && canPreserveVerifiedDeploymentEvidence(
                    for: appInfo,
                    state: state,
                    inspectedAt: update.inspectedAt,
                    inspectedDeviceID: update.inspectedDeviceID,
                    gracePeriod:
                        update.unidentifiedEvidenceGracePeriod
                ))

        if identityChanged {
            state.activeInstallationSuccessAt = nil
            state.lastAutomaticRecoveryFailureAt = nil
            state.lastDetectedExpiryAt = nil
            state.expirySource = nil
            state.lastExpiryVerifiedAt = nil
        }
        state.targetAppPresence = .installed
        state.targetAppBundleID = appInfo.bundleIdentifier
        state.targetDeviceID = update.inspectedDeviceID
        state.isTargetAppExpiryEvidenceVerified = evidenceVerified
        state.targetAppVersion = appInfo.version
        state.targetAppBuildVersion = appInfo.bundleVersion
        state.targetAppURL = currentAppURL
        if !hasCurrentMetadataExpiry,
           state.expirySource?.requiresInstallationIdentityValidation
            == true {
            state.lastDetectedExpiryAt = nil
            state.expirySource = nil
            state.lastExpiryVerifiedAt = nil
        }
        let hasPreservedVerifiedProfileExpiry =
            evidenceVerified
                && state.expirySource == .verifiedDeploymentProfile
                && state.lastDetectedExpiryAt != nil

        let failureMessage: String?
        if identityChanged {
            failureMessage = "检测到新的 App 安装实例，旧有效期证据已失效。"
        } else if case .invalid(let reason) =
                    appInfo.installMetadataValidation {
            failureMessage = "安装元数据无效：\(reason)"
        } else if case .unavailable(let reason) =
                    appInfo.installMetadataValidation {
            failureMessage = "无法验证安装元数据：\(reason)"
        } else if appInfo.installMetadata?.expectedExpiryAt == nil {
            failureMessage = hasPreservedVerifiedProfileExpiry
                ? nil
                : "已检测到 App，但安装元数据中没有可用的有效期。"
        } else if !metadataIsCurrent {
            failureMessage = "安装元数据早于最近一次续签，正在等待设备更新。"
        } else {
            failureMessage = nil
            state.lastExpiryVerifiedAt = update.inspectedAt
        }
        state.lastAppInspectionFailure = failureMessage
        return InstalledAppStateReduction(
            expiryEvidenceVerified: evidenceVerified,
            failureMessage: failureMessage
        )
    }

    func installationMetadataIsCurrent(
        _ appInfo: InstalledAppInfo,
        state: AppState
    ) -> Bool {
        guard let metadata = appInfo.installMetadata else {
            return false
        }
        return state.activeInstallationSuccessAt.map {
            metadata.recordedAt >= $0.addingTimeInterval(-5)
        } ?? true
    }

    private func canPreserveVerifiedDeploymentEvidence(
        for appInfo: InstalledAppInfo,
        state: AppState,
        inspectedAt: Date,
        inspectedDeviceID: String?,
        gracePeriod: TimeInterval
    ) -> Bool {
        let metadataMayReflectPreviousInstall: Bool
        switch appInfo.installMetadataValidation {
        case .notFound:
            metadataMayReflectPreviousInstall = true
        case .valid:
            metadataMayReflectPreviousInstall =
                !installationMetadataIsCurrent(appInfo, state: state)
        case .invalid, .unavailable:
            metadataMayReflectPreviousInstall = false
        }
        guard metadataMayReflectPreviousInstall,
              appInfo.builtByDeveloper,
              state.isTargetAppExpiryEvidenceVerified,
              let lastSuccessAt = state.activeInstallationSuccessAt,
              inspectedAt >= lastSuccessAt.addingTimeInterval(-5),
              normalized(state.targetAppBundleID)
                == normalized(appInfo.bundleIdentifier),
              normalized(state.targetDeviceID)
                == normalized(inspectedDeviceID) else {
            return false
        }
        if let recordedVersion = state.targetAppVersion,
           let recordedBuildVersion = state.targetAppBuildVersion,
           state.targetAppURL == nil,
           InstalledAppIdentity.normalizedAppURL(appInfo.appURL) != nil {
            return recordedVersion == appInfo.version
                && recordedBuildVersion == appInfo.bundleVersion
        }
        if let recordedVersion = state.targetAppVersion,
           let recordedBuildVersion = state.targetAppBuildVersion,
           let recordedAppURL = state.targetAppURL,
           let normalizedRecordedAppURL =
                InstalledAppIdentity.normalizedAppURL(recordedAppURL),
           let normalizedCurrentAppURL =
                InstalledAppIdentity.normalizedAppURL(appInfo.appURL) {
            return recordedVersion == appInfo.version
                && recordedBuildVersion == appInfo.bundleVersion
                && normalizedRecordedAppURL == normalizedCurrentAppURL
        }
        guard state.targetAppVersion == nil,
              state.targetAppBuildVersion == nil,
              state.targetAppURL == nil,
              inspectedAt.timeIntervalSince(lastSuccessAt)
                <= gracePeriod else {
            return false
        }
        return true
    }

    private func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private func invalidateTargetEvidence(in state: inout AppState) {
        state.lastSuccessAt = nil
        state.activeInstallationSuccessAt = nil
        state.lastPromptAt = nil
        state.lastAutomaticAttemptAt = nil
        state.lastAutomaticRecoveryFailureAt = nil
        state.lastPairingAttemptAt = nil
        state.lastPairingDeviceID = nil
        state.lastDetectedExpiryAt = nil
        state.expirySource = nil
        state.lastExpiryVerifiedAt = nil
        state.lastAppInspectionAt = nil
        state.lastAppInspectionFailure = nil
        state.targetAppPresence = .unknown
        state.targetAppBundleID = nil
        state.targetDeviceID = nil
        state.targetAppVersion = nil
        state.targetAppBuildVersion = nil
        state.targetAppURL = nil
        state.isTargetAppExpiryEvidenceVerified = false
    }

    private func appendAutomaticRefreshEvent(
        _ kind: AutomaticRefreshEventKind,
        to state: inout AppState
    ) {
        guard state.automaticRefreshEvents.last?.kind != kind else {
            return
        }
        state.appendAutomaticRefreshEvent(kind)
    }

    private func isPersistenceDiagnostic(_ value: String?) -> Bool {
        value?.hasPrefix("无法写入运行状态") == true
            || value?.hasPrefix("提醒已发送，但无法保存冷却时间") == true
    }
}
