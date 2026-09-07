import Foundation

@MainActor
final class AppBootstrapper {
    private let stateStore: RefreshStateStore
    private let environmentValidator: EnvironmentValidator
    private let deploymentProcessRecovery: DeploymentProcessRecovery
    private let deploymentWorkspaceCleanup:
        (String) throws -> Void
    private let provisioningProfileCacheRecovery:
        (String) throws -> Void
    private let hostInstallReceiptLoader:
        (String) throws -> HostInstallReceipt?
    private let commandProcessRecoveryOutcome:
        DeploymentProcessRecoveryOutcome?
    private let deploymentPrefixRecoveryOutcome:
        DeploymentProcessRecoveryOutcome?

    init(
        stateStore: RefreshStateStore = RefreshStateStore(),
        environmentValidator: EnvironmentValidator = EnvironmentValidator(),
        deploymentProcessRecovery: DeploymentProcessRecovery =
            DeploymentProcessRecovery(),
        deploymentWorkspaceCleanup:
            @escaping (String) throws -> Void = { deploymentToken in
                try StandardIOSDeploymentWorkspaceCleaner().cleanup(
                    deploymentToken: deploymentToken
                )
            },
        provisioningProfileCacheRecovery:
            @escaping (String) throws -> Void = { deploymentToken in
                _ = try ProvisioningProfileCacheManager()
                    .recoverInterruptedTransaction(
                        deploymentToken: deploymentToken
                    )
            },
        hostInstallReceiptLoader:
            @escaping (String) throws -> HostInstallReceipt? = {
                deploymentToken in
                try HostInstallReceiptStore().load(
                    deploymentToken: deploymentToken
                )
            },
        commandProcessRecoveryOutcome:
            DeploymentProcessRecoveryOutcome? = nil,
        deploymentPrefixRecoveryOutcome:
            DeploymentProcessRecoveryOutcome? = nil
    ) {
        self.stateStore = stateStore
        self.environmentValidator = environmentValidator
        self.deploymentProcessRecovery = deploymentProcessRecovery
        self.deploymentWorkspaceCleanup = deploymentWorkspaceCleanup
        self.provisioningProfileCacheRecovery =
            provisioningProfileCacheRecovery
        self.hostInstallReceiptLoader = hostInstallReceiptLoader
        self.commandProcessRecoveryOutcome =
            commandProcessRecoveryOutcome
        self.deploymentPrefixRecoveryOutcome =
            deploymentPrefixRecoveryOutcome
    }

    func bootstrap() -> BootstrapResult {
        let config: AppConfig
        let configurationLoadFailure: String?
        switch stateStore.loadConfigResult() {
        case .missing:
            config = normalize(config: .default)
            configurationLoadFailure = nil
        case .loaded(let loadedConfig), .loadedAfterInterruptedWrite(let loadedConfig):
            config = normalize(config: loadedConfig)
            configurationLoadFailure = nil
        case .corrupt:
            config = .default
            configurationLoadFailure = "配置文件已损坏，原文件已保留；请重新确认并保存项目配置。"
        }
        var state: AppState
        switch stateStore.loadStateResult() {
        case .missing:
            state = normalize(state: .default, config: config, stateFileWasCorrupt: false)
        case .loaded(let loadedState):
            state = normalize(
                state: loadedState,
                config: config,
                stateFileWasCorrupt: false,
                stateWriteWasInterrupted: false
            )
        case .loadedAfterInterruptedWrite(let loadedState):
            state = normalize(
                state: loadedState,
                config: config,
                stateFileWasCorrupt: false,
                stateWriteWasInterrupted: true
            )
        case .corrupt:
            state = normalize(
                state: .default,
                config: config,
                stateFileWasCorrupt: true,
                stateWriteWasInterrupted: false
            )
        }
        let statePersistenceUnavailable: Bool
        let statePersistenceFailureMessage: String?
        do {
            try stateStore.verifyStatePersistenceAvailable()
            statePersistenceUnavailable = false
            statePersistenceFailureMessage = nil
        } catch {
            statePersistenceUnavailable = true
            let message = "无法写入运行状态，已阻止续签与自动配对：\(error.localizedDescription)"
            statePersistenceFailureMessage = message
            if !state.processRecoveryBlocked {
                state.lastErrorSummary = message
            }
        }
        let environmentStatus = environmentValidator.validate(config: config)

        return BootstrapResult(
            config: config,
            state: state,
            environmentStatus: environmentStatus,
            requiresSetup: !config.hasResolvedApplicationTarget,
            configurationLoadFailure: configurationLoadFailure,
            statePersistenceUnavailable: statePersistenceUnavailable,
            statePersistenceFailureMessage: statePersistenceFailureMessage
        )
    }

    private func normalize(config: AppConfig) -> AppConfig {
        var migrated = config
        migrated.bundleID = environmentValidator.resolveBundleID(from: config)
        // The field remains decodable for backward compatibility, but the
        // built-in deployment flow must not retain a machine-specific script
        // path in the active or persisted configuration.
        migrated.deployScriptPath = nil
        // Decoding also clamps numeric ranges and trims optional strings.
        // Rewriting makes recovery from hand-edited or older JSON durable.
        try? stateStore.saveConfig(migrated)
        return migrated
    }

    private func normalize(
        state loadedState: AppState,
        config: AppConfig,
        stateFileWasCorrupt: Bool,
        stateWriteWasInterrupted: Bool = false
    ) -> AppState {
        var recovered = loadedState
        var didChange = stateFileWasCorrupt || stateWriteWasInterrupted

        let hasDeploymentRecoveryEvidence = recovered.isDeployRunning
            || recovered.deploymentRecoveryBlocked
            || recovered.activeDeployProcessGroupID != nil
            || recovered.activeDeploymentToken != nil
            || stateFileWasCorrupt
        if hasDeploymentRecoveryEvidence {
            let outcome: DeploymentProcessRecoveryOutcome
            if let token = recovered.activeDeploymentToken {
                outcome = deploymentProcessRecovery.recover(
                    processGroupID: recovered.activeDeployProcessGroupID,
                    token: token
                )
            } else {
                outcome = deploymentPrefixRecoveryOutcome
                    ?? deploymentProcessRecovery.recoverAnyDeployment()
            }

            recovered.isDeployRunning = false
            recovered.lastResult = .interrupted
            switch outcome {
            case .terminated:
                let deploymentToken = recovered.activeDeploymentToken
                let recoverySummary = stateFileWasCorrupt
                    ? "运行状态文件已损坏；发现并终止了遗留续签进程，可安全重试。"
                    : "上次续签在应用退出前未完成；遗留续签进程已终止，可安全重试。"
                settleRecoveredDeployment(
                    state: &recovered,
                    config: config,
                    deploymentToken: deploymentToken,
                    successSummary: recoverySummary
                )
            case .notFound:
                let deploymentToken = recovered.activeDeploymentToken
                let recoverySummary = stateFileWasCorrupt
                    ? "运行状态文件已损坏，已重建状态；未发现遗留续签进程。"
                    : "上次续签在应用退出前未完成；未发现仍在运行的续签进程，可安全重试。"
                settleRecoveredDeployment(
                    state: &recovered,
                    config: config,
                    deploymentToken: deploymentToken,
                    successSummary: recoverySummary
                )
            case .unresolved(let diagnostic):
                recovered.deploymentRecoveryBlocked = true
                recovered.lastErrorSummary = "上次续签未完成；无法确认或终止遗留续签，已阻止新续签：\(diagnostic)"
            }
            didChange = true
        } else if let deploymentPrefixRecoveryOutcome {
            switch deploymentPrefixRecoveryOutcome {
            case .notFound:
                break
            case .terminated:
                recovered.isDeployRunning = false
                recovered.lastResult = .interrupted
                recovered.deploymentRecoveryBlocked = false
                recovered.lastErrorSummary =
                    "启动时发现并终止了缺少持久化状态的遗留续签，可安全重试。"
                didChange = true
            case .unresolved(let diagnostic):
                recovered.isDeployRunning = false
                recovered.lastResult = .interrupted
                recovered.deploymentRecoveryBlocked = true
                recovered.lastErrorSummary =
                    "启动时无法确认是否存在遗留续签进程，已阻止新续签：\(diagnostic)"
                didChange = true
            }
        }

        switch commandProcessRecoveryOutcome {
        case nil:
            break
        case .some(.notFound):
            if recovered.commandRecoveryBlocked {
                recovered.commandRecoveryBlocked = false
                if recovered.lastErrorSummary?
                    .hasPrefix("无法确认或终止上次退出留下的后台命令") == true {
                    recovered.lastErrorSummary =
                        "未发现上次退出留下的后台命令，可安全继续。"
                }
                didChange = true
            }
        case .some(.terminated):
            let wasCommandRecoveryBlocked =
                recovered.commandRecoveryBlocked
            recovered.commandRecoveryBlocked = false
            if !recovered.deploymentRecoveryBlocked,
               !stateFileWasCorrupt,
               recovered.lastErrorSummary == nil
                || wasCommandRecoveryBlocked
                || recovered.lastErrorSummary?
                    .hasPrefix("无法确认或终止上次退出留下的后台命令") == true {
                recovered.lastErrorSummary =
                    "上次退出留下的后台命令已安全终止。"
            }
            didChange = true
        case .some(.unresolved(let diagnostic)):
            recovered.commandRecoveryBlocked = true
            let commandDiagnostic =
                "无法确认或终止上次退出留下的后台命令，已阻止新续签：\(diagnostic)"
            if recovered.deploymentRecoveryBlocked,
               let deploymentDiagnostic = recovered.lastErrorSummary {
                recovered.lastErrorSummary =
                    "\(deploymentDiagnostic)；同时，\(commandDiagnostic)"
            } else {
                recovered.lastErrorSummary = commandDiagnostic
            }
            didChange = true
        }

        let configuredBundleID = normalizedBundleID(config.bundleID)
        let recordedBundleID = normalizedBundleID(recovered.targetAppBundleID)
        let configuredDeviceID = normalizedIdentifier(config.preferredDeviceID)
        let recordedDeviceID = normalizedIdentifier(recovered.targetDeviceID)
        let targetIdentityChanged = (recordedBundleID != nil && recordedBundleID != configuredBundleID)
            || (configuredDeviceID != nil && recordedDeviceID != nil && recordedDeviceID != configuredDeviceID)
        let hasTargetBoundEvidence = recovered.lastSuccessAt != nil
            || recovered.activeInstallationSuccessAt != nil
            || recovered.lastPromptAt != nil
            || recovered.lastDetectedExpiryAt != nil
            || recovered.expirySource != nil
            || recovered.lastExpiryVerifiedAt != nil
            || recovered.lastAutomaticAttemptAt != nil
            || recovered.lastAutomaticRecoveryFailureAt != nil
            || recovered.lastPairingAttemptAt != nil
            || recovered.lastPairingDeviceID != nil
            || recovered.targetAppPresence != .unknown
            || recovered.targetAppVersion != nil
            || recovered.targetAppBuildVersion != nil
            || recovered.targetAppURL != nil
            || recovered.isTargetAppExpiryEvidenceVerified
        let targetIdentityIsIncomplete = recordedBundleID == nil || recordedDeviceID == nil
        if targetIdentityChanged
            || (hasTargetBoundEvidence && targetIdentityIsIncomplete)
            || (stateWriteWasInterrupted && hasTargetBoundEvidence) {
            recovered.lastSuccessAt = nil
            recovered.activeInstallationSuccessAt = nil
            recovered.lastPromptAt = nil
            recovered.lastAutomaticAttemptAt = nil
            recovered.lastAutomaticRecoveryFailureAt = nil
            recovered.lastPairingAttemptAt = nil
            recovered.lastPairingDeviceID = nil
            recovered.lastDetectedExpiryAt = nil
            recovered.expirySource = nil
            recovered.lastExpiryVerifiedAt = nil
            recovered.lastAppInspectionAt = nil
            recovered.lastAppInspectionFailure = nil
            recovered.targetAppPresence = .unknown
            recovered.targetAppBundleID = nil
            recovered.targetDeviceID = nil
            recovered.targetAppVersion = nil
            recovered.targetAppBuildVersion = nil
            recovered.targetAppURL = nil
            recovered.isTargetAppExpiryEvidenceVerified = false
            recovered.lastPromptAt = nil
            didChange = true
        }

        if didChange {
            try? stateStore.saveState(recovered)
        }
        return recovered
    }

    private func settleRecoveredDeployment(
        state: inout AppState,
        config: AppConfig,
        deploymentToken: String?,
        successSummary: String
    ) {
        state.activeDeployProcessGroupID = nil
        guard let deploymentToken else {
            state.deploymentRecoveryBlocked = false
            state.activeDeploymentToken = nil
            state.lastErrorSummary = successSummary
            return
        }

        let workspaceCleanupWarning: String?
        do {
            try deploymentWorkspaceCleanup(deploymentToken)
            workspaceCleanupWarning = nil
        } catch {
            workspaceCleanupWarning = DiagnosticText.bounded(
                "本次续签的构建缓存目录未能清理："
                    + error.localizedDescription
            )
        }

        do {
            // The process recovery above must finish first. Restoring cached
            // profiles while an inherited xcodebuild process may still be
            // running would race that process's provisioning decisions.
            try provisioningProfileCacheRecovery(deploymentToken)
        } catch {
            state.deploymentRecoveryBlocked = true
            state.activeDeploymentToken = deploymentToken
            state.lastErrorSummary = DiagnosticText.bounded(
                "已确认没有仍在运行的遗留续签进程，但签名描述文件缓存恢复失败，已阻止新续签："
                    + error.localizedDescription
                    + warningSuffix(workspaceCleanupWarning)
            )
            return
        }

        do {
            let receipt = try hostInstallReceiptLoader(deploymentToken)
            if let receipt, receipt.status == .installed {
                guard receiptMatchesCurrentTarget(
                    receipt,
                    config: config,
                    state: state
                ) else {
                    throw HostInstallReceiptBootstrapError.targetMismatch
                }
                applyInstalledReceipt(
                    receipt,
                    workspaceCleanupWarning: workspaceCleanupWarning,
                    to: &state
                )
                return
            }
            state.deploymentRecoveryBlocked = false
            state.activeDeploymentToken = nil
            state.lastErrorSummary = recoverySummary(
                successSummary,
                workspaceCleanupWarning: workspaceCleanupWarning
            )
        } catch {
            state.deploymentRecoveryBlocked = true
            state.activeDeploymentToken = deploymentToken
            state.lastErrorSummary = DiagnosticText.bounded(
                "已确认没有仍在运行的遗留续签进程，且签名描述文件缓存已安全结算，但宿主安装回执无法确认，已阻止新续签："
                    + error.localizedDescription
                    + warningSuffix(workspaceCleanupWarning)
            )
        }
    }

    private func receiptMatchesCurrentTarget(
        _ receipt: HostInstallReceipt,
        config: AppConfig,
        state: AppState
    ) -> Bool {
        guard receipt.deploymentToken
                == state.activeDeploymentToken,
              receipt.installedAt != nil,
              normalizedBundleID(config.bundleID)
                == receipt.bundleIdentifier else {
            return false
        }
        if let persistedBundleID = normalizedBundleID(
            state.targetAppBundleID
        ), persistedBundleID != receipt.bundleIdentifier {
            return false
        }
        let configuredDeviceID = normalizedIdentifier(
            config.preferredDeviceID
        )
        let persistedDeviceID = normalizedIdentifier(state.targetDeviceID)
        guard configuredDeviceID != nil || persistedDeviceID != nil else {
            return false
        }
        if let configuredDeviceID,
           configuredDeviceID != receipt.deviceIdentifier {
            return false
        }
        if let persistedDeviceID,
           persistedDeviceID != receipt.deviceIdentifier {
            return false
        }
        return true
    }

    private func applyInstalledReceipt(
        _ receipt: HostInstallReceipt,
        workspaceCleanupWarning: String?,
        to state: inout AppState
    ) {
        guard let installedAt = receipt.installedAt else {
            return
        }
        state.deploymentRecoveryBlocked = false
        state.activeDeploymentToken = nil
        state.lastResult = .success
        state.lastSuccessAt = installedAt
        state.activeInstallationSuccessAt = installedAt
        state.lastDetectedExpiryAt = receipt.profileExpirationDate
        state.expirySource = .verifiedDeploymentProfile
        state.lastExpiryVerifiedAt = installedAt
        state.lastAutomaticRecoveryFailureAt = nil
        state.lastAppInspectionAt = nil
        state.lastAppInspectionFailure = nil
        state.targetAppPresence = .unknown
        state.targetAppBundleID = receipt.bundleIdentifier
        state.targetDeviceID = receipt.deviceIdentifier
        state.targetAppVersion = receipt.shortVersion
        state.targetAppBuildVersion = receipt.buildVersion
        state.targetAppURL = nil
        state.isTargetAppExpiryEvidenceVerified = true
        state.lastErrorSummary = workspaceCleanupWarning
    }

    private func recoverySummary(
        _ successSummary: String,
        workspaceCleanupWarning: String?
    ) -> String {
        guard let workspaceCleanupWarning else {
            return successSummary
        }
        return DiagnosticText.bounded(
            "\(successSummary)；\(workspaceCleanupWarning)"
        )
    }

    private func warningSuffix(_ warning: String?) -> String {
        warning.map { "；同时，\($0)" } ?? ""
    }

    private func normalizedBundleID(_ value: String?) -> String? {
        normalizedIdentifier(value)
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }
}

private enum HostInstallReceiptBootstrapError: LocalizedError {
    case targetMismatch

    var errorDescription: String? {
        switch self {
        case .targetMismatch:
            return "installed 回执中的 Bundle ID 或设备 ID 与当前项目目标不一致。"
        }
    }
}

struct BootstrapResult {
    let config: AppConfig
    let state: AppState
    let environmentStatus: EnvironmentStatus
    let requiresSetup: Bool
    let configurationLoadFailure: String?
    let statePersistenceUnavailable: Bool
    let statePersistenceFailureMessage: String?
}
