import Foundation

@MainActor
struct DeviceRefreshSnapshotReducer {
    struct Input {
        let snapshot: DeviceRefreshSnapshot
        let config: AppConfig
        let state: AppState
        let previousMatchedDevice: DeviceInfo?
        let connectionState: DeviceConnectionState
        let connectionConfirmationStartedAt: Date?
        let confirmedDeviceAbsenceCount: Int
        let consecutiveInstalledAppAbsences: Int
        let installedAppInfo: InstalledAppInfo?
        let installedAppInspectionFailure: String?
        let externallySuppressesActions: Bool
        let now: Date
        let observedAt: ContinuousClock.Instant
    }

    struct Plan {
        let state: AppState
        let connectionState: DeviceConnectionState
        let connectionResolution: DeviceConnectionResolution
        let connectionPhase: DeviceConnectionPhase?
        let connectionRecheckAfter: Duration?
        let connectionConfirmationStartedAt: Date?
        let confirmedDeviceAbsenceCount: Int
        let resetsConnectionEvidence: Bool
        let consecutiveInstalledAppAbsences: Int
        let installedAppInfo: InstalledAppInfo?
        let installedAppInspectionFailure: String?
        let expiryInfo: ExpiryInfo?
        let shouldResetInstalledAppRetry: Bool
        let shouldSuppressRefreshActions: Bool
        let cacheIssue: DeviceScanCacheIssue?
        let setupMessage: String?
    }

    private let connectionReducer: DeviceConnectionReducer
    private let connectionStabilizer: DeviceConnectionStabilizer
    private let stateSettlement: RefreshStateSettlement
    private let expiryInspector: ExpiryInspector
    private let requiredAbsenceCount: Int
    private let unidentifiedEvidenceGracePeriod: TimeInterval

    init(
        connectionReducer: DeviceConnectionReducer,
        connectionStabilizer: DeviceConnectionStabilizer,
        stateSettlement: RefreshStateSettlement,
        expiryInspector: ExpiryInspector,
        requiredAbsenceCount: Int,
        unidentifiedEvidenceGracePeriod: TimeInterval
    ) {
        self.connectionReducer = connectionReducer
        self.connectionStabilizer = connectionStabilizer
        self.stateSettlement = stateSettlement
        self.expiryInspector = expiryInspector
        self.requiredAbsenceCount = max(requiredAbsenceCount, 1)
        self.unidentifiedEvidenceGracePeriod = max(
            unidentifiedEvidenceGracePeriod,
            0
        )
    }

    func reduce(_ input: Input) -> Plan {
        let snapshot = input.snapshot
        let hasDegradedTargetObservation =
            snapshot.targetObservation?.diagnostics.quality == .degraded
        let hasAvailabilityConflict =
            snapshot.targetObservation?.evidence == .conflict
            || snapshot.scanResult?.hasAvailabilityConflict(
                preferredDeviceID: input.config.preferredDeviceID,
                preferredDeviceName: input.config.preferredDeviceName
            ) == true
        let connection = reduceConnection(
            input,
            hasAvailabilityConflict: hasAvailabilityConflict
        )
        let installation = reduceInstallation(input)
        let hasUnverifiedFoundInstallation: Bool
        if case .found = snapshot.installedAppInspectionOutcome {
            hasUnverifiedFoundInstallation =
                !installation.reduction.expiryEvidenceVerified
        } else {
            hasUnverifiedFoundInstallation = false
        }
        let shouldSuppressForInstallation =
            snapshot.matchedDevice != nil
            && (
                hasUnverifiedFoundInstallation
                || snapshot.installedAppInspectionOutcome
                    .shouldSuppressActions(
                        hasUsableExpiry:
                            installation.expiryInfo?.estimatedExpiryAt
                                != nil
                    )
            )

        let cacheIssue: DeviceScanCacheIssue?
        if hasAvailabilityConflict {
            cacheIssue = .conflict
        } else if hasDegradedTargetObservation {
            cacheIssue = .partial
        } else {
            cacheIssue = nil
        }
        let setupMessage: String?
        if hasAvailabilityConflict {
            setupMessage =
                "不同设备检测来源对目标 iPhone 的可用状态结论不一致，"
                + "已暂停续签；请解锁设备并重新检查。"
        } else if connection.resolution == .confirming {
            setupMessage = snapshot.targetObservation?.diagnostics.summary
                ?? "正在重新确认目标设备连接…"
        } else {
            setupMessage = snapshot.targetObservation?.diagnostics.summary
                ?? snapshot.deviceMatchResult.diagnosticMessage
        }

        return Plan(
            state: installation.state,
            connectionState: connection.state,
            connectionResolution: connection.resolution,
            connectionPhase: connection.phase,
            connectionRecheckAfter: connection.recheckAfter,
            connectionConfirmationStartedAt:
                connection.confirmationStartedAt,
            confirmedDeviceAbsenceCount:
                connection.confirmedAbsenceCount,
            resetsConnectionEvidence: connection.resetsEvidence,
            consecutiveInstalledAppAbsences:
                installation.consecutiveAbsences,
            installedAppInfo: installation.appInfo,
            installedAppInspectionFailure:
                installation.inspectionFailure,
            expiryInfo: installation.expiryInfo,
            shouldResetInstalledAppRetry:
                installation.shouldResetRetry,
            shouldSuppressRefreshActions:
                input.externallySuppressesActions
                    || !snapshot.allowsCriticalActions
                    || snapshot.usedCachedActionEvidence
                    || hasDegradedTargetObservation
                    || shouldSuppressForInstallation,
            cacheIssue: cacheIssue,
            setupMessage: setupMessage
        )
    }

    private func reduceConnection(
        _ input: Input,
        hasAvailabilityConflict: Bool
    ) -> ConnectionReduction {
        let snapshot = input.snapshot
        if let observation = snapshot.targetObservation {
            let transition = connectionReducer.reduce(
                state: input.connectionState,
                event: .observation(observation, at: input.observedAt)
            )
            let resolution: DeviceConnectionResolution
            let resetsEvidence: Bool
            switch transition.state.phase {
            case .online:
                resolution = .online
                resetsEvidence = true
            case .confirming, .recoveryCandidate:
                resolution = .confirming
                resetsEvidence = false
            case .offline:
                resolution = .offline
                resetsEvidence = false
            case .unknown:
                resolution = .scanFailed
                resetsEvidence = false
            case .inconclusive:
                resolution = input.state.lastDeviceSeenAt == nil
                    ? .scanFailed
                    : .confirming
                resetsEvidence = false
            }
            return ConnectionReduction(
                state: transition.state,
                resolution: resolution,
                phase: transition.state.phase,
                recheckAfter: transition.nextCheckAfter,
                confirmationStartedAt: resetsEvidence
                    ? nil
                    : input.connectionConfirmationStartedAt,
                confirmedAbsenceCount: resetsEvidence
                    ? 0
                    : input.confirmedDeviceAbsenceCount,
                resetsEvidence: resetsEvidence
            )
        }

        if hasAvailabilityConflict {
            return ConnectionReduction(
                state: input.connectionState,
                resolution: .scanFailed,
                phase: nil,
                recheckAfter: nil,
                confirmationStartedAt: nil,
                confirmedAbsenceCount: 0,
                resetsEvidence: true
            )
        }

        var confirmationStartedAt =
            input.connectionConfirmationStartedAt
        var confirmedAbsenceCount = input.confirmedDeviceAbsenceCount
        let lastSeenAt = input.previousMatchedDevice != nil
            || input.state.currentDeviceStatus == .online
            ? input.now
            : (input.state.currentDeviceStatus == .offline
                ? nil
                : input.state.lastDeviceSeenAt)
        let evidence: DeviceConnectionEvidence
        let resetsEvidence: Bool
        if snapshot.matchedDevice == nil {
            evidence = .targetAbsent
            resetsEvidence = false
            confirmedAbsenceCount += 1
            if lastSeenAt != nil, confirmationStartedAt == nil {
                confirmationStartedAt = input.now
            }
        } else {
            evidence = .online
            resetsEvidence = true
            confirmationStartedAt = nil
            confirmedAbsenceCount = 0
        }
        return ConnectionReduction(
            state: input.connectionState,
            resolution: connectionStabilizer.resolve(
                evidence: evidence,
                lastSeenAt: lastSeenAt,
                confirmationStartedAt: confirmationStartedAt,
                confirmedAbsenceCount: confirmedAbsenceCount,
                now: input.now
            ),
            phase: nil,
            recheckAfter: nil,
            confirmationStartedAt: confirmationStartedAt,
            confirmedAbsenceCount: confirmedAbsenceCount,
            resetsEvidence: resetsEvidence
        )
    }

    private func reduceInstallation(
        _ input: Input
    ) -> InstallationReduction {
        let snapshot = input.snapshot
        var state = input.state
        var consecutiveAbsences = input.consecutiveInstalledAppAbsences
        var appInfo = input.installedAppInfo
        var inspectionFailure = input.installedAppInspectionFailure
        let confirmedAbsent = consecutiveAbsences
            + (snapshot.installedAppInspectionOutcome.isNotInstalled ? 1 : 0)
            >= requiredAbsenceCount
        let reduction = stateSettlement.applyInstallationInspection(
            .init(
                outcome: snapshot.installedAppInspectionOutcome,
                confirmedAbsent: confirmedAbsent,
                inspectedAt: input.now,
                inspectedDeviceID: snapshot.matchedDevice?.id,
                configuredBundleID: input.config.bundleID,
                unidentifiedEvidenceGracePeriod:
                    unidentifiedEvidenceGracePeriod
            ),
            to: &state
        )
        var shouldResetRetry = false
        switch snapshot.installedAppInspectionOutcome {
        case .notRequested:
            break
        case .found(let foundAppInfo):
            consecutiveAbsences = 0
            appInfo = foundAppInfo
            inspectionFailure = reduction.failureMessage
            shouldResetRetry = reduction.failureMessage == nil
        case .notInstalled:
            consecutiveAbsences += 1
            inspectionFailure = reduction.failureMessage
            if consecutiveAbsences >= requiredAbsenceCount {
                appInfo = nil
                shouldResetRetry = true
            }
        case .failed(let failure):
            inspectionFailure = failure
        }
        let expiryInfo = reduction.expiryEvidenceVerified
            ? expiryInspector.inspect(
                state: state,
                installedAppInfo: appInfo,
                minimumInstallMetadataRecordedAt:
                    state.activeInstallationSuccessAt?
                        .addingTimeInterval(-5)
            )
            : nil
        return InstallationReduction(
            state: state,
            consecutiveAbsences: consecutiveAbsences,
            appInfo: appInfo,
            inspectionFailure: inspectionFailure,
            reduction: reduction,
            expiryInfo: expiryInfo,
            shouldResetRetry: shouldResetRetry
        )
    }

    private struct ConnectionReduction {
        let state: DeviceConnectionState
        let resolution: DeviceConnectionResolution
        let phase: DeviceConnectionPhase?
        let recheckAfter: Duration?
        let confirmationStartedAt: Date?
        let confirmedAbsenceCount: Int
        let resetsEvidence: Bool
    }

    private struct InstallationReduction {
        let state: AppState
        let consecutiveAbsences: Int
        let appInfo: InstalledAppInfo?
        let inspectionFailure: String?
        let reduction: InstalledAppStateReduction
        let expiryInfo: ExpiryInfo?
        let shouldResetRetry: Bool
    }
}
