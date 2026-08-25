import Foundation

struct DeviceMonitor: Sendable {
    private let sourceScanner: DeviceSourceScanner
    private let commandBudgets: DeviceCommandBudgetCatalog

    init(
        commandRunner: CommandRunner = CommandRunner(),
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudgets = commandBudgets
        self.sourceScanner = DeviceSourceScanner { launchPath, arguments, timeoutSeconds in
            try await commandRunner.runAsync(launchPath, arguments: arguments, timeoutSeconds: timeoutSeconds)
        }
    }

    init(
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult,
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudgets = commandBudgets
        self.sourceScanner = DeviceSourceScanner { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
    }

    init(
        runCommandAsync: @escaping @Sendable (String, [String], TimeInterval?) async throws -> CommandResult,
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudgets = commandBudgets
        self.sourceScanner = DeviceSourceScanner(runCommand: runCommandAsync)
    }

    func observeTarget(
        _ target: TargetDeviceReference,
        purpose: TargetScanPurpose
    ) async throws -> TargetDeviceObservation {
        try await observeTargetWithCompatibilityComparison(
            target,
            purpose: purpose
        ).primary
    }

    func observeTargetWithCompatibilityComparison(
        _ target: TargetDeviceReference,
        purpose: TargetScanPurpose,
        compatibilityOptions: DeviceScanOptions? = nil
    ) async throws -> ComparedTargetDeviceObservation {
        let resolvedCompatibilityOptions = compatibilityOptions
            ?? defaultCompatibilityOptions(
                for: target,
                purpose: purpose
            )
        let timeoutSeconds = commandBudgets.budget(
            for: purpose.commandPurpose
        ).commandTimeoutSeconds
        let xcdevice = try await sourceScanner.scanXCDevice(timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        let xcdeviceOutcomes = [
            (DeviceScanSource.xcdevice, xcdevice)
        ]
        let compatibilityXCDeviceObservation = projectCompatibilityTarget(
            target,
            outcomes: xcdeviceOutcomes,
            options: resolvedCompatibilityOptions
        )
        let compatibilityXCDeviceMatched: Bool
        if case .matched = compatibilityXCDeviceObservation.evidence {
            compatibilityXCDeviceMatched = true
        } else {
            compatibilityXCDeviceMatched = false
        }
        let freezesCompatibilityAfterXCDevice =
            !resolvedCompatibilityOptions.requiresCompleteInventory
                && xcdevice.isComplete
                && compatibilityXCDeviceMatched

        if purpose == .background,
           case .stableID = target {
            let fastObservation = fuseTarget(target, outcomes: [(.xcdevice, xcdevice)])
            if case .matched = fastObservation.evidence,
               xcdevice.isComplete {
                return ComparedTargetDeviceObservation(
                    compatibility: compatibilityXCDeviceObservation,
                    canonical: fastObservation,
                    projections: makeProjectionPair(
                        compatibilityObservation: compatibilityXCDeviceObservation,
                        canonicalObservation: fastObservation,
                        sourceCommandCount: xcdeviceOutcomes.count
                    )
                )
            }
        }

        let devicectl = try await sourceScanner.scanDeviceCtl(timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        let outcomes: [(DeviceScanSource, SourceScanOutcome)] = [
            (.xcdevice, xcdevice),
            (.devicectl, devicectl)
        ]
        let observation = fuseTarget(target, outcomes: outcomes)
        let compatibilityObservation = freezesCompatibilityAfterXCDevice
            ? compatibilityXCDeviceObservation
            : projectCompatibilityTarget(
                target,
                outcomes: outcomes,
                options: resolvedCompatibilityOptions
            )
        return ComparedTargetDeviceObservation(
            compatibility: compatibilityObservation,
            canonical: observation,
            projections: makeProjectionPair(
                compatibilityObservation: compatibilityObservation,
                canonicalObservation: observation,
                sourceCommandCount: outcomes.count
            )
        )
    }

    func scanInventory(
        purpose: InventoryScanPurpose
    ) async throws -> DeviceInventory {
        try await scanInventoryWithCompatibilityComparison(
            purpose: purpose
        ).primary
    }

    func scanInventoryWithCompatibilityComparison(
        purpose: InventoryScanPurpose,
        compatibilityOptions: DeviceScanOptions? = nil
    ) async throws -> ComparedDeviceInventory {
        let timeoutSeconds = commandBudgets.budget(
            for: purpose.commandPurpose
        ).commandTimeoutSeconds
        let xcdevice = try await sourceScanner.scanXCDevice(timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        let devicectl = try await sourceScanner.scanDeviceCtl(timeoutSeconds: timeoutSeconds)
        try Task.checkCancellation()
        let outcomes: [(DeviceScanSource, SourceScanOutcome)] = [
            (.xcdevice, xcdevice),
            (.devicectl, devicectl)
        ]
        let canonicalInventory = makeInventory(outcomes: outcomes)
        let compatibilityInventory = makeInventory(
            outcomes: outcomes,
            usesCompatibilityAvailability: true
        )
        return ComparedDeviceInventory(
            compatibility: compatibilityInventory,
            canonical: canonicalInventory,
            projections: makeProjectionPair(
                outcomes: outcomes,
                canonicalInventory: canonicalInventory,
                sourceCommandCount: outcomes.count
            )
        )
    }

    func verifyDeploymentTarget(
        _ target: TargetDeviceReference
    ) async throws -> DeploymentTarget {
        guard case .stableID = target else {
            throw DeviceMonitorError.commandFailed(
                "续签目标必须使用稳定设备 ID，设备名称只能用于发现和迁移。"
            )
        }

        let timeoutSeconds = commandBudgets.budget(
            for: .deploymentVerification
        ).commandTimeoutSeconds
        let xcdevice = try await sourceScanner.scanXCDevice(
            timeoutSeconds: timeoutSeconds
        )
        try Task.checkCancellation()
        let devicectl = try await sourceScanner.scanDeviceCtl(
            timeoutSeconds: timeoutSeconds
        )
        try Task.checkCancellation()
        let outcomes: [(DeviceScanSource, SourceScanOutcome)] = [
            (.xcdevice, xcdevice),
            (.devicectl, devicectl)
        ]
        let observation = fuseTarget(target, outcomes: outcomes)
        return try DeploymentTargetAuthorizer().authorize(
            outcomes: outcomes,
            observation: observation
        )
    }

    func scanAvailableIPhones() async throws -> [DeviceInfo] {
        try await scanAvailableIPhones(options: .polling()).devices
    }

    func scanAvailableIPhones(options: DeviceScanOptions) async throws -> DeviceScanResult {
        try await scanAvailableIPhonesWithCanonicalComparison(
            options: options
        ).primary
    }

    func scanAvailableIPhonesWithCanonicalComparison(
        options: DeviceScanOptions
    ) async throws -> ComparedCompatibilityDeviceScan {
        let attempts = max(options.attemptCount, 1)
        var notes: [String] = []
        var latestDevices: [DeviceInfo] = []
        var latestSource: DeviceScanSource = .none
        var latestUnavailableTarget: UnavailableDeviceInfo?
        var latestUnavailableAmbiguity: String?
        var latestUnavailableSource: DeviceScanSource = .none
        var didRunSuccessfulSource = false
        var sourceOutcomes: [DeviceScanSourceOutcome] = []
        var latestComparisonOutcomes:
            [(DeviceScanSource, SourceScanOutcome)] = []
        var sourceCommandCount = 0

        for attempt in 1...attempts {
            var successfulSourcesThisAttempt = Set<DeviceScanSource>()
            var devicesThisAttempt: [DeviceInfo] = []
            var unavailableDevicesThisAttempt: [UnavailableDeviceInfo] = []
            var latestSourceThisAttempt: DeviceScanSource = .none
            var comparisonOutcomesThisAttempt:
                [(DeviceScanSource, SourceScanOutcome)] = []
            do {
                let outcome = try await sourceScanner.scanXCDevice(
                    timeoutSeconds: options.commandTimeoutSeconds
                )
                sourceCommandCount += 1
                comparisonOutcomesThisAttempt.append((.xcdevice, outcome))
                latestComparisonOutcomes = comparisonOutcomesThisAttempt
                let batch = try batch(
                    from: outcome,
                    usesCompatibilityAvailability: true
                )
                didRunSuccessfulSource = true
                let foundExpectedTarget = containsExpectedTarget(in: batch.devices, options: options)
                successfulSourcesThisAttempt.insert(.xcdevice)
                sourceOutcomes.append(
                    DeviceScanSourceOutcome(
                        source: .xcdevice,
                        result: foundExpectedTarget ? .matchedTarget : .completedWithoutTarget,
                        message: nil
                    )
                )
                if !batch.devices.isEmpty {
                    devicesThisAttempt = DeviceEvidenceMerger.available(
                        devicesThisAttempt + batch.devices
                    )
                    latestSourceThisAttempt = .xcdevice
                    latestDevices = DeviceEvidenceMerger.available(
                        latestDevices + batch.devices
                    )
                    latestSource = .xcdevice
                }
                unavailableDevicesThisAttempt = DeviceEvidenceMerger.unavailable(
                    unavailableDevicesThisAttempt + batch.unavailableDevices
                )
                if let unavailableTarget = matchUnavailableTarget(in: batch.unavailableDevices, options: options) {
                    latestUnavailableTarget = unavailableTarget
                    latestUnavailableSource = .xcdevice
                }
                if let ambiguity = unavailableTargetAmbiguity(
                    in: batch.unavailableDevices,
                    options: options
                ) {
                    latestUnavailableAmbiguity = ambiguity
                }

                if foundExpectedTarget, !options.requiresCompleteInventory {
                    return makeComparedCompatibilityDeviceScan(
                        primary: DeviceScanResult(
                            devices: latestDevices,
                            source: .xcdevice,
                            unavailableTarget: nil,
                            diagnostics: DeviceScanDiagnostics(
                                attempts: attempt,
                                message: diagnosticMessage(from: notes),
                                sourceOutcomes: sourceOutcomes
                            )
                        ),
                        outcomes: comparisonOutcomesThisAttempt,
                        options: options,
                        sourceCommandCount: sourceCommandCount
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = diagnosticDescription(for: error)
                notes.append("xcdevice：\(message)")
                sourceOutcomes.append(
                    DeviceScanSourceOutcome(source: .xcdevice, result: .failed, message: message)
                )
            }

            if options.usesDevicectlFallback {
                do {
                    let outcome = try await sourceScanner.scanDeviceCtl(
                        timeoutSeconds: options.commandTimeoutSeconds
                    )
                    sourceCommandCount += 1
                    comparisonOutcomesThisAttempt.append(
                        (.devicectl, outcome)
                    )
                    latestComparisonOutcomes =
                        comparisonOutcomesThisAttempt
                    let batch = try batch(
                        from: outcome,
                        usesCompatibilityAvailability: true
                    )
                    didRunSuccessfulSource = true
                    let foundExpectedTarget = containsExpectedTarget(in: batch.devices, options: options)
                    successfulSourcesThisAttempt.insert(.devicectl)
                    sourceOutcomes.append(
                        DeviceScanSourceOutcome(
                            source: .devicectl,
                            result: foundExpectedTarget ? .matchedTarget : .completedWithoutTarget,
                            message: nil
                        )
                    )
                    if !batch.devices.isEmpty {
                        devicesThisAttempt = DeviceEvidenceMerger.available(
                            devicesThisAttempt + batch.devices
                        )
                        latestSourceThisAttempt = .devicectl
                        latestDevices = DeviceEvidenceMerger.available(
                            latestDevices + batch.devices
                        )
                        latestSource = .devicectl
                    }
                    unavailableDevicesThisAttempt = DeviceEvidenceMerger.unavailable(
                        unavailableDevicesThisAttempt + batch.unavailableDevices
                    )
                    if let unavailableTarget = matchUnavailableTarget(in: batch.unavailableDevices, options: options) {
                        latestUnavailableTarget = unavailableTarget
                        latestUnavailableSource = .devicectl
                    }
                    if let ambiguity = unavailableTargetAmbiguity(
                        in: batch.unavailableDevices,
                        options: options
                    ) {
                        latestUnavailableAmbiguity = ambiguity
                    }

                    if foundExpectedTarget, !options.requiresCompleteInventory {
                        return makeComparedCompatibilityDeviceScan(
                            primary: DeviceScanResult(
                                devices: latestDevices,
                                source: .devicectl,
                                unavailableTarget: nil,
                                diagnostics: DeviceScanDiagnostics(
                                    attempts: attempt,
                                    message: diagnosticMessage(from: notes),
                                    sourceOutcomes: sourceOutcomes
                                )
                            ),
                            outcomes: comparisonOutcomesThisAttempt,
                            options: options,
                            sourceCommandCount: sourceCommandCount
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let message = diagnosticDescription(for: error)
                    notes.append("devicectl：\(message)")
                    sourceOutcomes.append(
                        DeviceScanSourceOutcome(source: .devicectl, result: .failed, message: message)
                    )
                }
            }

            if options.requiresCompleteInventory,
               successfulSourcesThisAttempt == Set([.xcdevice, .devicectl]) {
                let unavailableIDs = Set(unavailableDevicesThisAttempt.map(\.id))
                let conflictingIDs = Set(devicesThisAttempt.map(\.id))
                    .intersection(unavailableIDs)
                let verifiedDevices = devicesThisAttempt.filter {
                    !conflictingIDs.contains($0.id)
                }
                let foundVerifiedTarget = containsExpectedTarget(
                    in: verifiedDevices,
                    options: options
                )
                let unavailableTarget = matchUnavailableTarget(
                    in: unavailableDevicesThisAttempt,
                    options: options
                )
                let unavailableAmbiguity = unavailableTargetAmbiguity(
                    in: unavailableDevicesThisAttempt,
                    options: options
                )
                let resolvedSource = verifiedDevices.isEmpty
                    ? .none
                    : latestSourceThisAttempt
                let diagnosticNotes = notes
                    + (conflictingIDs.isEmpty
                        ? []
                        : ["设备来源对同一稳定 ID 的可用状态不一致，已拒绝将其视为可续签设备。"])
                    + (unavailableTarget?.diagnosticMessage.map { [$0] } ?? [])
                    + (unavailableAmbiguity.map { [$0] } ?? [])
                let hasPreferredTarget = options.preferredDeviceID?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    || options.preferredDeviceName?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                if foundVerifiedTarget
                    || unavailableAmbiguity != nil
                    || !hasPreferredTarget
                    || attempt == attempts {
                    return makeComparedCompatibilityDeviceScan(
                        primary: DeviceScanResult(
                            devices: verifiedDevices,
                            source: resolvedSource,
                            unavailableTarget: foundVerifiedTarget
                                ? nil
                                : (unavailableAmbiguity == nil
                                    ? unavailableTarget
                                    : nil),
                            unavailableDevices: unavailableDevicesThisAttempt,
                            conflictingDeviceIDs: conflictingIDs,
                            isCompleteInventory: true,
                            diagnostics: DeviceScanDiagnostics(
                                attempts: attempt,
                                message: diagnosticMessage(
                                    from: diagnosticNotes
                                ),
                                sourceOutcomes: sourceOutcomes
                            )
                        ),
                        outcomes: comparisonOutcomesThisAttempt,
                        options: options,
                        sourceCommandCount: sourceCommandCount
                    )
                }
            }

            if attempt < attempts, options.retryDelaySeconds > 0 {
                try await Task.sleep(for: .seconds(options.retryDelaySeconds))
            }
        }

        if options.requiresCompleteInventory {
            throw DeviceMonitorError.commandFailed(
                diagnosticMessage(
                    from: notes,
                    fallback: "无法从全部设备来源完成安全的 iPhone 清单核验。"
                ) ?? "无法从全部设备来源完成安全的 iPhone 清单核验。"
            )
        }

        if didRunSuccessfulSource {
            let resolvedSource = latestUnavailableTarget != nil
                ? latestUnavailableSource
                : (latestDevices.isEmpty ? .none : latestSource)
            let unavailableMessage = latestUnavailableTarget?.diagnosticMessage
            let diagnosticNotes = notes
                + (unavailableMessage.map { [$0] } ?? [])
                + (latestUnavailableAmbiguity.map { [$0] } ?? [])
            return makeComparedCompatibilityDeviceScan(
                primary: DeviceScanResult(
                    devices: latestDevices,
                    source: resolvedSource,
                    unavailableTarget: latestUnavailableTarget,
                    diagnostics: DeviceScanDiagnostics(
                        attempts: attempts,
                        message: diagnosticMessage(
                            from: diagnosticNotes,
                            fallback: unavailableMessage ?? (latestDevices.isEmpty ? "未发现可用 iPhone。" : "未匹配到目标 iPhone。")
                        ),
                        sourceOutcomes: sourceOutcomes
                    )
                ),
                outcomes: latestComparisonOutcomes,
                options: options,
                sourceCommandCount: sourceCommandCount
            )
        }

        throw DeviceMonitorError.commandFailed(
            diagnosticMessage(from: notes, fallback: "无法从 Xcode 设备服务读取设备列表。") ?? "无法从 Xcode 设备服务读取设备列表。"
        )
    }

    private func makeComparedCompatibilityDeviceScan(
        primary: DeviceScanResult,
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        options: DeviceScanOptions,
        sourceCommandCount: Int
    ) -> ComparedCompatibilityDeviceScan {
        let canonicalProjection: DeviceDetectionProjection
        if let targetReference = targetReference(for: options) {
            canonicalProjection = projection(
                for: fuseTarget(
                    targetReference,
                    outcomes: outcomes
                )
            )
        } else {
            let inventory = makeInventory(outcomes: outcomes)
            var projection = inventoryProjection(
                outcomes: outcomes,
                usesCompatibilityAvailability: false
            )
            if inventory.identityResolution == .ambiguous {
                projection = DeviceDetectionProjection(
                    classification: .conflict,
                    quality: projection.quality
                )
            }
            canonicalProjection = projection
        }

        return ComparedCompatibilityDeviceScan(
            primary: primary,
            projections: DeviceDetectionProjectionPair(
                compatibility: compatibilityProjection(
                    for: primary,
                    options: options
                ),
                canonical: canonicalProjection,
                sourceCommandCount: sourceCommandCount
            )
        )
    }

    private func targetReference(
        for options: DeviceScanOptions
    ) -> TargetDeviceReference? {
        if let rawID = options.preferredDeviceID,
           let stableID = StableDeviceID(rawID) {
            return .stableID(
                stableID,
                displayName: options.preferredDeviceName
            )
        }
        if let rawName = options.preferredDeviceName {
            let name = rawName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !name.isEmpty {
                return .compatibilityName(name)
            }
        }
        return nil
    }

    private func defaultCompatibilityOptions(
        for target: TargetDeviceReference,
        purpose: TargetScanPurpose
    ) -> DeviceScanOptions {
        let preferredDeviceID: String?
        let preferredDeviceName: String?
        switch target {
        case .stableID(let stableID, let displayName):
            preferredDeviceID = stableID.value
            preferredDeviceName = displayName
        case .compatibilityName(let name):
            preferredDeviceID = nil
            preferredDeviceName = name
        }

        switch purpose {
        case .background:
            return .polling(
                preferredDeviceID: preferredDeviceID,
                preferredDeviceName: preferredDeviceName
            )
        case .recovery:
            return .automaticRecovery(
                preferredDeviceID: preferredDeviceID,
                preferredDeviceName: preferredDeviceName
            )
        case .interactive:
            return .reliable(
                preferredDeviceID: preferredDeviceID,
                preferredDeviceName: preferredDeviceName
            )
        }
    }

    private func compatibilityProjection(
        for result: DeviceScanResult,
        options: DeviceScanOptions
    ) -> DeviceDetectionProjection {
        let hasPreferredTarget =
            targetReference(for: options) != nil
        let classification: DeviceDetectionClassification
        if result.hasAvailabilityConflict(
            preferredDeviceID: options.preferredDeviceID,
            preferredDeviceName: options.preferredDeviceName
        ) {
            classification = .conflict
        } else if hasPreferredTarget,
                  containsExpectedTarget(
                    in: result.devices,
                    options: options
                  ) {
            classification = .matched
        } else if !hasPreferredTarget, result.devices.count == 1 {
            classification = .matched
        } else if !hasPreferredTarget, result.devices.count > 1 {
            classification = .inconclusive
        } else if result.unavailableTarget != nil
                    || (!hasPreferredTarget
                        && result.unavailableDevices.count == 1) {
            classification = .unavailable
        } else if result.isCompleteInventory {
            classification = .confirmedAbsent
        } else {
            classification = .inconclusive
        }
        let quality: ObservationQuality =
            result.diagnostics.sourceOutcomes.contains {
                $0.result == .failed
            } ? .degraded : .complete
        return DeviceDetectionProjection(
            classification: classification,
            quality: quality
        )
    }

    private func makeProjectionPair(
        compatibilityObservation: TargetDeviceObservation,
        canonicalObservation: TargetDeviceObservation,
        sourceCommandCount: Int
    ) -> DeviceDetectionProjectionPair {
        DeviceDetectionProjectionPair(
            compatibility: projection(for: compatibilityObservation),
            canonical: projection(for: canonicalObservation),
            sourceCommandCount: sourceCommandCount
        )
    }

    private func makeProjectionPair(
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        canonicalInventory: DeviceInventory,
        sourceCommandCount: Int
    ) -> DeviceDetectionProjectionPair {
        var canonicalProjection = inventoryProjection(
            outcomes: outcomes,
            usesCompatibilityAvailability: false
        )
        if canonicalInventory.identityResolution == .ambiguous {
            canonicalProjection = DeviceDetectionProjection(
                classification: .conflict,
                quality: canonicalProjection.quality
            )
        }
        return DeviceDetectionProjectionPair(
            compatibility: inventoryProjection(
                outcomes: outcomes,
                usesCompatibilityAvailability: true
            ),
            canonical: canonicalProjection,
            sourceCommandCount: sourceCommandCount
        )
    }

    private func projection(
        for observation: TargetDeviceObservation
    ) -> DeviceDetectionProjection {
        let classification: DeviceDetectionClassification
        switch observation.evidence {
        case .matched:
            classification = .matched
        case .confirmedAbsent:
            classification = .confirmedAbsent
        case .unavailable:
            classification = .unavailable
        case .inconclusive:
            classification = .inconclusive
        case .conflict:
            classification = .conflict
        }
        return DeviceDetectionProjection(
            classification: classification,
            quality: observation.diagnostics.quality
        )
    }

    private func inventoryProjection(
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        usesCompatibilityAvailability: Bool
    ) -> DeviceDetectionProjection {
        let assessments = projectionRecords(
            outcomes: outcomes,
            usesCompatibilityAvailability: usesCompatibilityAvailability
        ).compactMap {
                usesCompatibilityAvailability
                    ? $0.compatibilityAssessment
                    : $0.assessment
            }
        let positiveIDs = Set(
            assessments.compactMap { assessment -> String? in
                guard case .positive(let device) = assessment else {
                    return nil
                }
                return device.id
            }
        )
        let unavailableIDs = Set(
            assessments.compactMap { assessment -> String? in
                guard case .unavailable(let device, _) = assessment else {
                    return nil
                }
                return device.id
            }
        )
        let uncertainIDs = Set(
            assessments.compactMap { assessment -> String? in
                guard case .uncertain(let device, _) = assessment else {
                    return nil
                }
                return device.id
            }
        )
        let quality: ObservationQuality = outcomes.allSatisfy {
            $0.1.isComplete
        } ? .complete : .degraded
        let classification: DeviceDetectionClassification
        if !positiveIDs.intersection(unavailableIDs).isEmpty {
            classification = .conflict
        } else if positiveIDs.count == 1 {
            classification = .matched
        } else if positiveIDs.count > 1 {
            classification = .inconclusive
        } else if unavailableIDs.count == 1, uncertainIDs.isEmpty {
            classification = .unavailable
        } else if outcomes.count >= 2,
                  outcomes.allSatisfy({ $0.1.isComplete }),
                  assessments.isEmpty {
            classification = .confirmedAbsent
        } else {
            classification = .inconclusive
        }
        return DeviceDetectionProjection(
            classification: classification,
            quality: quality
        )
    }

    private func fuseTarget(
        _ target: TargetDeviceReference,
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        usesCompatibilityAvailability: Bool = false
    ) -> TargetDeviceObservation {
        let records = projectionRecords(
            outcomes: outcomes,
            usesCompatibilityAvailability: usesCompatibilityAvailability
        )
        let targetID: StableDeviceID?
        var identityPersistenceCandidateID: StableDeviceID? = nil
        switch target {
        case .stableID(let stableID, _):
            targetID = stableID
            identityPersistenceCandidateID = nil
        case .compatibilityName(let name):
            let normalizedName = normalize(name)
            let matchingRecords = records.filter {
                $0.name.map(normalize) == normalizedName
            }
            let matchingIDs = Set(matchingRecords.compactMap(\.stableID))
            guard matchingIDs.count <= 1 else {
                return TargetDeviceObservation(
                    evidence: .conflict,
                    recoveryCandidate: nil,
                    diagnostics: DeviceObservationDiagnostics(
                        quality: .degraded,
                        source: .none,
                        summary: "检测到多台同名 iPhone，设备名称无法安全解析为稳定设备 ID。"
                    )
                )
            }
            targetID = matchingIDs.first
            if let targetID,
               outcomes.count >= 2,
               outcomes.allSatisfy({ $0.1.isComplete }) {
                let targetNames = records
                    .filter { $0.stableID == targetID }
                    .compactMap(\.name)
                    .map(normalize)
                if !targetNames.isEmpty,
                   targetNames.allSatisfy({ $0 == normalizedName }) {
                    identityPersistenceCandidateID = targetID
                }
            }
            if targetID == nil {
                let evidence: TargetDeviceEvidence = outcomes.count >= 2
                    && outcomes.allSatisfy { $0.1.isComplete }
                    && matchingRecords.isEmpty
                    ? .confirmedAbsent
                    : .inconclusive
                return TargetDeviceObservation(
                    evidence: evidence,
                    recoveryCandidate: nil,
                    diagnostics: makeDiagnostics(
                        source: .none,
                        outcomes: outcomes,
                        extraMessages: matchingRecords.isEmpty
                            ? []
                            : ["名称匹配到的设备缺少稳定设备 ID。"]
                    )
                )
            }
        }

        guard let targetID else {
            return TargetDeviceObservation(
                evidence: .inconclusive,
                recoveryCandidate: nil,
                diagnostics: makeDiagnostics(source: .none, outcomes: outcomes)
            )
        }

        let targetRecords = records.filter { $0.stableID == targetID }
        let assessments = targetRecords.compactMap {
            usesCompatibilityAvailability
                ? $0.compatibilityAssessment
                : $0.assessment
        }
        let positives = assessments.compactMap { assessment -> DeviceInfo? in
            guard case .positive(let device) = assessment else {
                return nil
            }
            return device
        }
        let unavailable = assessments.compactMap {
            assessment -> (UnavailableDeviceInfo, TargetRecoveryCandidate?)? in
            guard case .unavailable(let device, let candidate) = assessment else {
                return nil
            }
            return (device, candidate)
        }
        let uncertain = assessments.compactMap {
            assessment -> (UnavailableDeviceInfo, TargetRecoveryCandidate?)? in
            guard case .uncertain(let device, let candidate) = assessment else {
                return nil
            }
            return (device, candidate)
        }
        let source = targetRecords
            .first(where: { record in
                guard case .positive = record.assessment else {
                    return false
                }
                return true
            })?
            .source ?? targetRecords.first?.source ?? .none
        let extraMessages = uncertain.compactMap(\.0.diagnosticMessage)

        if !positives.isEmpty, !unavailable.isEmpty {
            return TargetDeviceObservation(
                evidence: .conflict,
                recoveryCandidate: unavailable.compactMap(\.1).first,
                diagnostics: makeDiagnostics(
                    source: source,
                    outcomes: outcomes,
                    extraMessages: ["设备来源对同一稳定 ID 给出了正向和明确不可用证据。"]
                )
            )
        }
        if let positive = positives.first {
            let identityPersistenceCandidate =
                identityPersistenceCandidateID.map {
                    DeviceIdentityPersistenceCandidate(
                        deviceID: $0,
                        displayName: positive.name
                    )
                }
            return TargetDeviceObservation(
                evidence: .matched(positive),
                recoveryCandidate: uncertain.compactMap(\.1).first,
                identityPersistenceCandidate:
                    identityPersistenceCandidate,
                diagnostics: makeDiagnostics(
                    source: source,
                    outcomes: outcomes,
                    extraMessages: extraMessages,
                    forceDegraded: !uncertain.isEmpty
                )
            )
        }
        if let unavailable = unavailable.first {
            return TargetDeviceObservation(
                evidence: .unavailable(unavailable.0),
                recoveryCandidate: unavailable.1 ?? uncertain.compactMap(\.1).first,
                diagnostics: makeDiagnostics(
                    source: source,
                    outcomes: outcomes,
                    extraMessages: [unavailable.0.diagnosticMessage].compactMap { $0 }
                )
            )
        }
        if !uncertain.isEmpty {
            return TargetDeviceObservation(
                evidence: .inconclusive,
                recoveryCandidate: uncertain.compactMap(\.1).first,
                diagnostics: makeDiagnostics(
                    source: targetRecords.first?.source ?? .none,
                    outcomes: outcomes,
                    extraMessages: extraMessages,
                    forceDegraded: true
                )
            )
        }
        if outcomes.count >= 2, outcomes.allSatisfy({ $0.1.isComplete }) {
            return TargetDeviceObservation(
                evidence: .confirmedAbsent,
                recoveryCandidate: nil,
                diagnostics: makeDiagnostics(source: .none, outcomes: outcomes)
            )
        }
        return TargetDeviceObservation(
            evidence: .inconclusive,
            recoveryCandidate: nil,
            diagnostics: makeDiagnostics(source: .none, outcomes: outcomes)
        )
    }

    private func makeInventory(
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        usesCompatibilityAvailability: Bool = false
    ) -> DeviceInventory {
        let records = projectionRecords(
            outcomes: outcomes,
            usesCompatibilityAvailability: usesCompatibilityAvailability
        )
        let assessments = records.compactMap {
            usesCompatibilityAvailability
                ? $0.compatibilityAssessment
                : $0.assessment
        }
        let positiveDevices = assessments.compactMap { assessment -> DeviceInfo? in
            guard case .positive(let device) = assessment else {
                return nil
            }
            return device
        }
        let unavailable = assessments.compactMap {
            assessment -> (UnavailableDeviceInfo, TargetRecoveryCandidate?)? in
            switch assessment {
            case .unavailable(let device, let candidate),
                 .uncertain(let device, let candidate):
                return (device, candidate)
            case .positive:
                return nil
            }
        }
        let unavailableIDs = Set(
            assessments.compactMap { assessment -> String? in
                guard case .unavailable(let device, _) = assessment else {
                    return nil
                }
                return device.id
            }
        )
        let conflictingIDs = Set(positiveDevices.map(\.id)).intersection(unavailableIDs)
        let devices = DeviceEvidenceMerger.available(positiveDevices)
            .filter { !conflictingIDs.contains($0.id) }
        let canonicalIDs = Set(records.compactMap(\.stableID))
        let nameToIDs = Dictionary(grouping: records.compactMap { record -> (String, StableDeviceID)? in
            guard let name = record.name, let stableID = record.stableID else {
                return nil
            }
            return (normalize(name), stableID)
        }, by: \.0)
        let hasNameAmbiguity = nameToIDs.values.contains {
            Set($0.map(\.1)).count > 1
        }
        let idToNames = Dictionary(grouping: records.compactMap { record -> (StableDeviceID, String)? in
            guard let name = record.name, let stableID = record.stableID else {
                return nil
            }
            return (stableID, normalize(name))
        }, by: \.0)
        let hasIDNameAmbiguity = idToNames.values.contains {
            Set($0.map(\.1)).count > 1
        }
        let hasIncompleteIdentity = records.contains {
            $0.stableID == nil || $0.name == nil
        }
        let resolution: InventoryIdentityResolution
        if hasNameAmbiguity || hasIDNameAmbiguity {
            resolution = .ambiguous
        } else if outcomes.count < 2
            || !outcomes.allSatisfy({ $0.1.isComplete })
            || hasIncompleteIdentity
            || !conflictingIDs.isEmpty {
            resolution = .incomplete
        } else {
            resolution = .complete
        }
        var recoveryCandidatesByID: [StableDeviceID: TargetRecoveryCandidate] = [:]
        for candidate in unavailable.compactMap(\.1) {
            recoveryCandidatesByID[candidate.deviceID] = candidate
        }
        let recoveryCandidates = Array(recoveryCandidatesByID.values)
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName)
                    == .orderedAscending
            }
        let unavailableDevices = DeviceEvidenceMerger.unavailable(
            unavailable.map(\.0)
        )
        .filter { !conflictingIDs.contains($0.id) }
        let uncertainMessages = assessments.compactMap { assessment -> String? in
            guard case .uncertain(let device, _) = assessment else {
                return nil
            }
            return device.diagnosticMessage
        }
        let source: DeviceScanSource = records.contains { $0.source == .xcdevice }
            ? .xcdevice
            : (records.contains { $0.source == .devicectl } ? .devicectl : .none)
        let identityPersistenceCandidate:
            DeviceIdentityPersistenceCandidate?
        if resolution == .complete,
           canonicalIDs.count == 1,
           let canonicalID = canonicalIDs.first,
           devices.count == 1,
           let device = devices.first,
           device.id == canonicalID.value {
            identityPersistenceCandidate =
                DeviceIdentityPersistenceCandidate(
                    deviceID: canonicalID,
                    displayName: device.name
                )
        } else {
            identityPersistenceCandidate = nil
        }
        return DeviceInventory(
            devices: devices,
            unavailableDevices: unavailableDevices,
            recoveryCandidates: recoveryCandidates,
            identityResolution: resolution,
            identityPersistenceCandidate:
                identityPersistenceCandidate,
            diagnostics: makeDiagnostics(
                source: source,
                outcomes: outcomes,
                extraMessages: uncertainMessages
                    + (conflictingIDs.isEmpty
                        ? []
                        : ["设备来源对同一稳定 ID 给出了正向和明确不可用证据。"]),
                forceDegraded: !uncertainMessages.isEmpty
            )
        )
    }

    private func projectCompatibilityTarget(
        _ target: TargetDeviceReference,
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        options: DeviceScanOptions
    ) -> TargetDeviceObservation {
        if !options.requiresCompleteInventory {
            for (index, entry) in outcomes.enumerated() {
                guard case .completed(let records) = entry.1,
                      let device = compatibilityMatchedDevice(
                        target,
                        in: records
                      ) else {
                    continue
                }
                return TargetDeviceObservation(
                    evidence: .matched(device),
                    recoveryCandidate: nil,
                    diagnostics: makeDiagnostics(
                        source: entry.0,
                        outcomes: Array(outcomes.prefix(index + 1))
                    )
                )
            }

            var unavailableByID:
                [String: (
                    device: UnavailableDeviceInfo,
                    candidate: TargetRecoveryCandidate?,
                    source: DeviceScanSource
                )] = [:]
            for (source, outcome) in outcomes {
                guard case .completed(let records) = outcome else {
                    continue
                }
                for record in records {
                    guard case .unavailable(
                        let device,
                        let candidate
                    ) = record.compatibilityAssessment else {
                        continue
                    }
                    unavailableByID[device.id] = (
                        device,
                        candidate,
                        source
                    )
                }
            }
            let unavailableMatches: [(
                device: UnavailableDeviceInfo,
                candidate: TargetRecoveryCandidate?,
                source: DeviceScanSource
            )]
            switch target {
            case .stableID(let stableID, _):
                unavailableMatches = unavailableByID[
                    stableID.value
                ].map { [$0] } ?? []
            case .compatibilityName(let name):
                let normalizedName = normalize(name)
                unavailableMatches = unavailableByID.values.filter {
                    normalize($0.device.name) == normalizedName
                }
            }
            if unavailableMatches.count == 1,
               let unavailable = unavailableMatches.first {
                return TargetDeviceObservation(
                    evidence: .unavailable(unavailable.device),
                    recoveryCandidate: unavailable.candidate,
                    diagnostics: makeDiagnostics(
                        source: unavailable.source,
                        outcomes: outcomes
                    )
                )
            }
            return TargetDeviceObservation(
                evidence: .inconclusive,
                recoveryCandidate: nil,
                diagnostics: makeDiagnostics(
                    source: .none,
                    outcomes: outcomes
                )
            )
        }
        return fuseTarget(
            target,
            outcomes: outcomes,
            usesCompatibilityAvailability: true
        )
    }

    private func compatibilityMatchedDevice(
        _ target: TargetDeviceReference,
        in records: [ParsedDeviceRecord]
    ) -> DeviceInfo? {
        let devices = records.compactMap { record -> DeviceInfo? in
            guard case .positive(let device) = record.compatibilityAssessment else {
                return nil
            }
            return device
        }
        switch target {
        case .stableID(let stableID, _):
            return devices.first { $0.id == stableID.value }
        case .compatibilityName(let name):
            let normalizedName = normalize(name)
            return devices.first {
                normalize($0.name) == normalizedName
            }
        }
    }

    private func projectionRecords(
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        usesCompatibilityAvailability: Bool
    ) -> [ParsedDeviceRecord] {
        guard usesCompatibilityAvailability else {
            return outcomes.flatMap { $0.1.records }
        }
        return outcomes.flatMap { entry -> [ParsedDeviceRecord] in
            let outcome = entry.1
            guard case .completed(let records) = outcome else {
                return []
            }
            return records
        }
    }

    private func makeDiagnostics(
        source: DeviceScanSource,
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        extraMessages: [String] = [],
        forceDegraded: Bool = false
    ) -> DeviceObservationDiagnostics {
        let messages = outcomes.compactMap { $0.1.diagnosticMessage } + extraMessages
        return DeviceObservationDiagnostics(
            quality: forceDegraded || outcomes.contains(where: { !$0.1.isComplete })
                ? .degraded
                : .complete,
            source: source,
            summary: diagnosticMessage(from: messages)
        )
    }

    private func batch(
        from outcome: SourceScanOutcome,
        usesCompatibilityAvailability: Bool = false
    ) throws -> DeviceScanBatch {
        guard case .completed(let records) = outcome else {
            throw DeviceMonitorError.commandFailed(
                outcome.diagnosticMessage ?? "设备来源没有返回完整、可解析的结果。"
            )
        }
        let assessments = records.compactMap {
            usesCompatibilityAvailability
                ? $0.compatibilityAssessment
                : $0.assessment
        }
        return DeviceScanBatch(
            devices: assessments.compactMap {
                guard case .positive(let device) = $0 else {
                    return nil
                }
                return device
            }.sortedByName(),
            unavailableDevices: assessments.compactMap {
                guard case .unavailable(let device, _) = $0 else {
                    return nil
                }
                return device
            }.sortedByName()
        )
    }

    private func containsExpectedTarget(in devices: [DeviceInfo], options: DeviceScanOptions) -> Bool {
        if let preferredDeviceID = normalizedPreferredValue(options.preferredDeviceID) {
            return devices.contains { $0.id == preferredDeviceID }
        }

        if let preferredDeviceName = normalizedPreferredValue(options.preferredDeviceName) {
            return devices.contains { normalize($0.name) == normalize(preferredDeviceName) }
        }

        return !devices.isEmpty
    }

    private func matchUnavailableTarget(
        in devices: [UnavailableDeviceInfo],
        options: DeviceScanOptions
    ) -> UnavailableDeviceInfo? {
        if let preferredDeviceID = normalizedPreferredValue(options.preferredDeviceID) {
            return devices.first { $0.id == preferredDeviceID }
        }

        if let preferredDeviceName = normalizedPreferredValue(options.preferredDeviceName) {
            let matches = devices.filter {
                normalize($0.name) == normalize(preferredDeviceName)
            }
            return matches.count == 1 ? matches.first : nil
        }

        return devices.count == 1 ? devices.first : nil
    }

    private func unavailableTargetAmbiguity(
        in devices: [UnavailableDeviceInfo],
        options: DeviceScanOptions
    ) -> String? {
        guard normalizedPreferredValue(options.preferredDeviceID) == nil,
              let preferredDeviceName = normalizedPreferredValue(
                  options.preferredDeviceName
              ) else {
            return nil
        }
        let count = devices.filter {
            normalize($0.name) == normalize(preferredDeviceName)
        }.count
        guard count > 1 else {
            return nil
        }
        return "检测到 \(count) 台同名且不可用的 iPhone，无法安全确定配对目标。请改用稳定设备 ID。"
    }

    private func normalizedPreferredValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func diagnosticDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return compactDiagnostic(description)
        }

        return compactDiagnostic(error.localizedDescription)
    }

    private func diagnosticMessage(from notes: [String], fallback: String? = nil) -> String? {
        let nonEmptyNotes = notes
            .map { compactDiagnostic($0) }
            .filter { !$0.isEmpty }

        if !nonEmptyNotes.isEmpty {
            return nonEmptyNotes.joined(separator: "；")
        }

        return fallback
    }

    private func compactDiagnostic(_ value: String) -> String {
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return DiagnosticText.bounded(
            lines.prefix(3).joined(separator: " ")
        )
    }
}
