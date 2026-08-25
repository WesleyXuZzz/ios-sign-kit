import Foundation

struct DeviceRefreshTargetOverride: Sendable {
    let deviceID: String
    let deviceName: String
}

struct DeviceRefreshRequest: Sendable {
    let config: AppConfig
    let mode: EnvironmentRefreshMode
    let rolloutState: DeviceDetectionRolloutState
    let targetGeneration: Int
    let observationGeneration: UInt64
    let sessionCaches: RefreshSessionCaches
    let criticalActionCandidates: Set<CriticalRefreshAction>
    let hasKnownExpiry: Bool
    let hasConfirmedInstallation: Bool
    let lastResult: RefreshResult?
    let isDeployRunning: Bool
    let isPassiveRefresh: Bool
    let targetOverride: DeviceRefreshTargetOverride?
}

struct DeviceRefreshTransition: Sendable {
    let snapshot: DeviceRefreshSnapshot
    let comparisonSample: DeviceDetectionComparisonSample?
}

@MainActor
struct DeviceRefreshWorkflow {
    private let environmentValidator: EnvironmentValidator
    private let deviceMonitor: DeviceMonitor
    private let deviceMatcher: DeviceMatcher
    private let xcodeProjectResolver: XcodeProjectResolver
    private let inspectInstalledApp: InspectInstalledAppHandler
    private let rolloutController: DeviceDetectionRolloutController
    private let refreshPolicy: RefreshPolicy

    init(
        environmentValidator: EnvironmentValidator = EnvironmentValidator(),
        deviceMonitor: DeviceMonitor,
        deviceMatcher: DeviceMatcher,
        xcodeProjectResolver: XcodeProjectResolver,
        inspectInstalledApp: @escaping InspectInstalledAppHandler,
        rolloutController: DeviceDetectionRolloutController =
            DeviceDetectionRolloutController(),
        refreshPolicy: RefreshPolicy = RefreshPolicy()
    ) {
        self.environmentValidator = environmentValidator
        self.deviceMonitor = deviceMonitor
        self.deviceMatcher = deviceMatcher
        self.xcodeProjectResolver = xcodeProjectResolver
        self.inspectInstalledApp = inspectInstalledApp
        self.rolloutController = rolloutController
        self.refreshPolicy = refreshPolicy
    }

    func refresh(
        _ request: DeviceRefreshRequest
    ) async throws -> DeviceRefreshTransition {
        let plan = makePlan(for: request)
        var environmentStatus = environmentValidator.validate(
            config: request.config
        )
        var xcodeCacheUpdate: XcodeValidationCacheUpdate?

        if request.config.hasResolvedApplicationTarget {
            let validation: XcodeProjectValidation
            if let cachedValidation = plan.xcodeCandidate {
                validation = cachedValidation.validation
            } else {
                validation = await xcodeProjectResolver
                    .validateSelectedTarget(config: request.config)
                if let key = plan.xcodeCacheKey {
                    xcodeCacheUpdate = XcodeValidationCacheUpdate(
                        key: key,
                        entry: XcodeValidationCacheEntry(
                            validation: validation,
                            observedAt: ContinuousClock().now,
                            observedWallClockAt: Date()
                        )
                    )
                }
            }
            try Task.checkCancellation()
            environmentStatus.isApplicationTargetResolved =
                environmentStatus.isApplicationTargetResolved
                    && validation.isValid
            if !validation.isValid {
                environmentStatus.summary = validation.diagnosticMessage
                    ?? "Xcode 工程已变化，原 App 目标不再匹配；请重新识别并选择 Scheme。"
            }
        }

        do {
            return try await scanAndInspect(
                request: request,
                plan: plan,
                environmentStatus: environmentStatus,
                xcodeCacheUpdate: xcodeCacheUpdate
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return DeviceRefreshTransition(
                snapshot: DeviceRefreshSnapshot(
                    environmentStatus: environmentStatus,
                    availableDevices: [],
                    matchedDevice: nil,
                    deviceMatchResult: .noAvailableDevices,
                    installedAppInspectionOutcome: .notRequested,
                    treatsScanFailureAsTransient:
                        request.mode.treatsScanFailureAsTransient,
                    refreshMode: request.mode,
                    scanResult: nil,
                    targetObservation: nil,
                    identityPersistenceCandidate: nil,
                    policyGeneration: request.rolloutState.generation,
                    observationGeneration: request.observationGeneration,
                    allowsCriticalActions: plan.policyDecision
                        .allowsCriticalActions,
                    usedCachedActionEvidence: false,
                    xcodeCacheUpdate: xcodeCacheUpdate,
                    installedAppCacheUpdate: nil,
                    installedAppCacheInvalidationKey:
                        plan.configuredInstalledAppCacheKey,
                    errorMessage:
                        "设备扫描失败：\(error.localizedDescription)"
                ),
                comparisonSample: nil
            )
        }
    }

    private func scanAndInspect(
        request: DeviceRefreshRequest,
        plan: Plan,
        environmentStatus: EnvironmentStatus,
        xcodeCacheUpdate: XcodeValidationCacheUpdate?
    ) async throws -> DeviceRefreshTransition {
        let scan = try await scan(request: request, plan: plan)
        try Task.checkCancellation()

        let inspection = await inspectAppIfNeeded(
            request: request,
            plan: plan,
            matchedDevice: scan.matchResult.device
        )
        try Task.checkCancellation()

        let snapshot = DeviceRefreshSnapshot(
            environmentStatus: environmentStatus,
            availableDevices: scan.availableDevices,
            matchedDevice: scan.matchResult.device,
            deviceMatchResult: scan.matchResult,
            installedAppInspectionOutcome: inspection.outcome,
            treatsScanFailureAsTransient: false,
            refreshMode: request.mode,
            scanResult: scan.scanResult,
            targetObservation: scan.targetObservation,
            identityPersistenceCandidate:
                scan.identityPersistenceCandidate,
            policyGeneration: request.rolloutState.generation,
            observationGeneration: request.observationGeneration,
            allowsCriticalActions: plan.policyDecision
                .allowsCriticalActions,
            usedCachedActionEvidence:
                plan.xcodeCandidate != nil || inspection.usedCache,
            xcodeCacheUpdate: xcodeCacheUpdate,
            installedAppCacheUpdate: inspection.cacheUpdate,
            installedAppCacheInvalidationKey:
                inspection.cacheInvalidationKey,
            errorMessage: nil
        )
        return DeviceRefreshTransition(
            snapshot: snapshot,
            comparisonSample: comparisonSample(
                request: request,
                plan: plan,
                projections: scan.comparisonProjections
            )
        )
    }

    private func scan(
        request: DeviceRefreshRequest,
        plan: Plan
    ) async throws -> ScanOutcome {
        let targetReference = try Self.targetDeviceReference(
            for: request.config
        )

        if request.rolloutState.mode == .shadow {
            let compared = try await deviceMonitor
                .scanAvailableIPhonesWithCanonicalComparison(
                    options: plan.scanOptions
                )
            let scanResult = compared.primary
            return ScanOutcome(
                scanResult: scanResult,
                availableDevices: scanResult.devices,
                matchResult: deviceMatcher.match(
                    preferredDeviceID: request.config.preferredDeviceID,
                    preferredDeviceName:
                        request.config.preferredDeviceName,
                    devices: scanResult.devices
                ),
                targetObservation: nil,
                identityPersistenceCandidate: nil,
                comparisonProjections: compared.projections
            )
        }

        if plan.comparisonEngine != nil, let targetReference {
            let compared = try await deviceMonitor
                .observeTargetWithCompatibilityComparison(
                    targetReference,
                    purpose: request.mode.targetScanPurpose,
                    compatibilityOptions: plan.scanOptions
                )
            let observation = compared.observation(
                for: plan.policyDecision.primaryEngine
            )
            return Self.outcome(
                from: observation,
                targetReference: targetReference,
                comparisonProjections: compared.projections
            )
        }

        if plan.comparisonEngine != nil {
            let compared = try await deviceMonitor
                .scanInventoryWithCompatibilityComparison(
                    purpose: request.mode == .manualDeepCheck
                        ? .interactive
                        : .backgroundDiscovery,
                    compatibilityOptions: plan.scanOptions
                )
            let inventory = compared.inventory(
                for: plan.policyDecision.primaryEngine
            )
            return inventoryOutcome(
                inventory,
                comparisonProjections: compared.projections
            )
        }

        if plan.policyDecision.primaryEngine == .canonical {
            if let targetReference {
                let observation = try await deviceMonitor.observeTarget(
                    targetReference,
                    purpose: request.mode.targetScanPurpose
                )
                return Self.outcome(
                    from: observation,
                    targetReference: targetReference,
                    comparisonProjections: nil
                )
            }
            let inventory = try await deviceMonitor.scanInventory(
                purpose: request.mode == .manualDeepCheck
                    ? .interactive
                    : .backgroundDiscovery
            )
            return inventoryOutcome(
                inventory,
                comparisonProjections: nil
            )
        }

        let scanResult = try await deviceMonitor.scanAvailableIPhones(
            options: plan.scanOptions
        )
        return ScanOutcome(
            scanResult: scanResult,
            availableDevices: scanResult.devices,
            matchResult: deviceMatcher.match(
                preferredDeviceID: request.config.preferredDeviceID,
                preferredDeviceName: request.config.preferredDeviceName,
                devices: scanResult.devices
            ),
            targetObservation: nil,
            identityPersistenceCandidate: nil,
            comparisonProjections: nil
        )
    }

    private func inventoryOutcome(
        _ inventory: DeviceInventory,
        comparisonProjections: DeviceDetectionProjectionPair?
    ) -> ScanOutcome {
        let matchResult = deviceMatcher.match(
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            devices: inventory.devices
        )
        let observation = matchResult.device.map {
            TargetDeviceObservation(
                evidence: .matched($0),
                recoveryCandidate: nil,
                diagnostics: inventory.diagnostics
            )
        }
        return ScanOutcome(
            scanResult: nil,
            availableDevices: inventory.devices,
            matchResult: matchResult,
            targetObservation: observation,
            identityPersistenceCandidate:
                inventory.identityPersistenceCandidate,
            comparisonProjections: comparisonProjections
        )
    }

    private func inspectAppIfNeeded(
        request: DeviceRefreshRequest,
        plan: Plan,
        matchedDevice: DeviceInfo?
    ) async -> InspectionOutcome {
        guard plan.shouldInspectInstalledApp,
              let matchedDevice,
              let bundleID = request.config.bundleID,
              !bundleID.isEmpty else {
            return InspectionOutcome(
                outcome: .notRequested,
                cacheUpdate: nil,
                cacheInvalidationKey: nil,
                usedCache: false
            )
        }

        let currentCacheKey = Self.installedAppCacheKey(
            targetGeneration: request.targetGeneration,
            config: request.config,
            deviceID: matchedDevice.id
        )
        let cachedEntry = plan.refreshWork == .heartbeatOnly
                && currentCacheKey
                    == plan.configuredInstalledAppCacheKey
            ? plan.installedAppCandidate
            : nil
        if let cachedEntry {
            let outcome: InstalledAppInspectionOutcome
            switch cachedEntry.result {
            case .installed(let appInfo):
                outcome = .found(appInfo)
            case .notInstalled:
                outcome = .notInstalled
            }
            return InspectionOutcome(
                outcome: outcome,
                cacheUpdate: nil,
                cacheInvalidationKey: nil,
                usedCache: true
            )
        }

        do {
            let appInfo = try await inspectInstalledApp(
                matchedDevice,
                bundleID,
                plan.shouldRetryInstalledAppInspection ? 4 : 1,
                plan.shouldRetryInstalledAppInspection ? 1 : 0
            )
            let outcome = appInfo.map(
                InstalledAppInspectionOutcome.found
            ) ?? .notInstalled
            let cacheUpdate = appInfo.flatMap { appInfo in
                currentCacheKey.map {
                    InstalledAppCacheUpdate(
                        key: $0,
                        entry: InstalledAppCacheEntry(
                            result: .installed(appInfo),
                            observedAt: ContinuousClock().now,
                            observedWallClockAt: Date()
                        )
                    )
                }
            }
            return InspectionOutcome(
                outcome: outcome,
                cacheUpdate: cacheUpdate,
                cacheInvalidationKey: appInfo == nil
                    ? currentCacheKey
                    : nil,
                usedCache: false
            )
        } catch {
            return InspectionOutcome(
                outcome: .failed(
                    "读取已安装 App 失败：\(error.localizedDescription)"
                ),
                cacheUpdate: nil,
                cacheInvalidationKey: currentCacheKey,
                usedCache: false
            )
        }
    }

    private func makePlan(for request: DeviceRefreshRequest) -> Plan {
        let decision = rolloutController.decision(
            for: request.rolloutState.mode
        )
        let observedAt = ContinuousClock().now
        let xcodeKey = Self.xcodeValidationCacheKey(
            targetGeneration: request.targetGeneration,
            config: request.config
        )
        let appKey = Self.installedAppCacheKey(
            targetGeneration: request.targetGeneration,
            config: request.config,
            deviceID: request.config.preferredDeviceID
        )
        let canUseCandidates = decision.primaryEngine == .canonical
            && request.mode.refreshRequestKind == .background
        let xcodeCandidate = canUseCandidates
                && request.criticalActionCandidates.isEmpty
            ? xcodeKey.flatMap {
                request.sessionCaches.xcodeCandidate(
                    for: $0,
                    at: observedAt
                )
            }
            : nil
        let appCandidate = canUseCandidates
            ? appKey.flatMap {
                request.sessionCaches.installedAppCandidate(
                    for: $0,
                    at: observedAt
                )
            }
            : nil
        let canonicalWork = refreshPolicy.work(
            for: RefreshPolicyContext(
                requestKind: request.mode.refreshRequestKind,
                hasFreshXcodeValidation: xcodeCandidate != nil,
                hasFreshInstalledAppEvidence: appCandidate != nil,
                criticalActionCandidates:
                    request.criticalActionCandidates
            )
        )
        let compatibilityWork = RefreshWork.fullInteractiveCheck
        let refreshWork = decision.primaryEngine == .canonical
            ? canonicalWork
            : compatibilityWork
        let comparisonEngine: DeviceDetectionEngine?
        switch decision.comparison {
        case .some(.pure(let engine)):
            comparisonEngine = engine
        case .none:
            comparisonEngine = nil
        }
        let scanOptions = request.targetOverride.map {
            DeviceScanOptions.reliable(
                preferredDeviceID: $0.deviceID,
                preferredDeviceName: $0.deviceName
            )
        } ?? request.mode.scanOptions(for: request.config)
        let shouldInspect = request.targetOverride == nil
            && !request.isPassiveRefresh
            && (
                decision.primaryEngine == .canonical
                    || request.mode.shouldInspectInstalledApp(
                        hasKnownExpiry: request.hasKnownExpiry,
                        hasConfirmedInstallation:
                            request.hasConfirmedInstallation
                    )
            )
        return Plan(
            policyDecision: decision,
            xcodeCacheKey: xcodeKey,
            configuredInstalledAppCacheKey: appKey,
            xcodeCandidate: xcodeCandidate,
            installedAppCandidate: appCandidate,
            refreshWork: refreshWork,
            comparisonEngine: comparisonEngine,
            comparisonRefreshWork: comparisonEngine.map {
                $0 == .canonical ? canonicalWork : compatibilityWork
            },
            scanOptions: scanOptions,
            shouldInspectInstalledApp: shouldInspect,
            shouldRetryInstalledAppInspection:
                request.lastResult == .success
                    || request.isDeployRunning
                    || request.mode == .appMetadataRetry
        )
    }

    private func comparisonSample(
        request: DeviceRefreshRequest,
        plan: Plan,
        projections: DeviceDetectionProjectionPair?
    ) -> DeviceDetectionComparisonSample? {
        guard let projections,
              let comparisonEngine = plan.comparisonEngine,
              let comparisonWork = plan.comparisonRefreshWork else {
            return nil
        }
        return DeviceDetectionComparisonSample(
            rolloutMode: request.rolloutState.mode,
            primaryEngine: plan.policyDecision.primaryEngine,
            comparisonEngine: comparisonEngine,
            primaryDevice: projections.projection(
                for: plan.policyDecision.primaryEngine
            ),
            comparisonDevice: projections.projection(
                for: comparisonEngine
            ),
            primaryWork: plan.refreshWork,
            comparisonWork: comparisonWork,
            sourceCommandCount: projections.sourceCommandCount
        )
    }

    private static func outcome(
        from observation: TargetDeviceObservation,
        targetReference: TargetDeviceReference,
        comparisonProjections: DeviceDetectionProjectionPair?
    ) -> ScanOutcome {
        let availableDevices: [DeviceInfo]
        let matchResult: DeviceMatchResult
        switch observation.evidence {
        case .matched(let device):
            availableDevices = [device]
            matchResult = .matched(device)
        case .confirmedAbsent, .unavailable, .inconclusive, .conflict:
            availableDevices = []
            matchResult = unmatchedResult(for: targetReference)
        }
        return ScanOutcome(
            scanResult: nil,
            availableDevices: availableDevices,
            matchResult: matchResult,
            targetObservation: observation,
            identityPersistenceCandidate:
                observation.identityPersistenceCandidate,
            comparisonProjections: comparisonProjections
        )
    }

    private static func targetDeviceReference(
        for config: AppConfig
    ) throws -> TargetDeviceReference? {
        if let rawDeviceID = config.preferredDeviceID {
            guard let stableID = StableDeviceID(rawDeviceID) else {
                throw DeviceMonitorError.commandFailed(
                    "固定的目标设备 ID 无效，请在项目配置中重新选择 iPhone。"
                )
            }
            return .stableID(
                stableID,
                displayName: config.preferredDeviceName
            )
        }
        if let rawName = config.preferredDeviceName {
            let name = rawName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard DeviceIdentityValidator.isSafe(name) else {
                throw DeviceMonitorError.commandFailed(
                    "旧目标设备名称无效，请在项目配置中重新选择 iPhone。"
                )
            }
            return .compatibilityName(name)
        }
        return nil
    }

    private static func unmatchedResult(
        for target: TargetDeviceReference
    ) -> DeviceMatchResult {
        switch target {
        case .stableID(let stableID, _):
            return .preferredIdentifierUnavailable(stableID.value)
        case .compatibilityName(let name):
            return .preferredNameUnavailable(name)
        }
    }

    private static func xcodeValidationCacheKey(
        targetGeneration: Int,
        config: AppConfig
    ) -> XcodeValidationCacheKey? {
        guard let projectPath = normalized(config.xcodeprojPath),
              let scheme = normalized(config.scheme),
              let targetName = normalized(config.targetName),
              let bundleID = normalized(config.bundleID) else {
            return nil
        }
        return XcodeValidationCacheKey(
            targetGeneration: targetGeneration,
            normalizedProjectIdentity: URL(
                fileURLWithPath: projectPath
            ).standardizedFileURL.path,
            scheme: scheme,
            targetName: targetName,
            bundleID: bundleID
        )
    }

    private static func installedAppCacheKey(
        targetGeneration: Int,
        config: AppConfig,
        deviceID: String?
    ) -> InstalledAppCacheKey? {
        guard let rawDeviceID = normalized(deviceID),
              let bundleID = normalized(config.bundleID),
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

    private static func normalized(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private struct Plan {
        let policyDecision: DeviceDetectionDecision
        let xcodeCacheKey: XcodeValidationCacheKey?
        let configuredInstalledAppCacheKey: InstalledAppCacheKey?
        let xcodeCandidate: XcodeValidationCacheEntry?
        let installedAppCandidate: InstalledAppCacheEntry?
        let refreshWork: RefreshWork
        let comparisonEngine: DeviceDetectionEngine?
        let comparisonRefreshWork: RefreshWork?
        let scanOptions: DeviceScanOptions
        let shouldInspectInstalledApp: Bool
        let shouldRetryInstalledAppInspection: Bool
    }

    private struct ScanOutcome {
        let scanResult: DeviceScanResult?
        let availableDevices: [DeviceInfo]
        let matchResult: DeviceMatchResult
        let targetObservation: TargetDeviceObservation?
        let identityPersistenceCandidate:
            DeviceIdentityPersistenceCandidate?
        let comparisonProjections: DeviceDetectionProjectionPair?
    }

    private struct InspectionOutcome {
        let outcome: InstalledAppInspectionOutcome
        let cacheUpdate: InstalledAppCacheUpdate?
        let cacheInvalidationKey: InstalledAppCacheKey?
        let usedCache: Bool
    }
}
