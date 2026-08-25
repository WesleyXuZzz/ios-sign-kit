import Foundation

enum DeploymentPreflightTargetStrategy: Sendable {
    case canonical(TargetDeviceReference)
    case compatibility
}

enum DeploymentPreflightProgress: Equatable, Sendable {
    case confirmingDevice
    case confirmingLockState
    case manualLockStateUnknown(
        deviceName: String,
        failure: DeviceLockStateInspectionFailure
    )
    case preparing
    case confirmingDestination
    case manualDestinationUnknown(String)
    case verifyingInstallation
    case finalDeviceVerification
    case finalUnlockConfirmation
}

enum DeploymentPreflightOutcome: Sendable {
    case ready(DeploymentStartTarget)
    case deviceLocked(DeviceInfo)
    case lockStateUnknown(
        DeviceInfo,
        DeviceLockStateInspectionFailure
    )
    case destinationBlocked(
        DeviceInfo,
        XcodeDestinationReadiness
    )
    case automaticInstallationChanged
}

enum DeploymentPreflightError: Error, LocalizedError {
    case applicationTargetInvalid(String)

    var errorDescription: String? {
        switch self {
        case .applicationTargetInvalid(let diagnostic):
            return "续签前 App 目标验证失败：\(diagnostic)"
        }
    }
}

@MainActor
struct DeploymentPreflightWorkflow {
    struct Request: Sendable {
        let context: DeploymentContext
        let expectedDeviceID: StableDeviceID
        let targetStrategy: DeploymentPreflightTargetStrategy
    }

    struct Callbacks {
        let isCurrent: @MainActor () -> Bool
        let verifyAutomaticInstallation:
            @MainActor (DeploymentContext, DeviceInfo) async -> Bool
        let isAutomaticRefreshEligible: @MainActor () -> Bool
        let reportProgress:
            @MainActor (DeploymentPreflightProgress) -> Void
    }

    private let deviceMonitor: DeviceMonitor
    private let deviceMatcher: DeviceMatcher
    private let deviceLockStateInspector: DeviceLockStateInspector
    private let xcodeProjectResolver: XcodeProjectResolver
    private let xcodeDestinationReadinessInspector:
        XcodeDestinationReadinessInspector
    private let validateEnvironment: @MainActor (AppConfig) -> EnvironmentStatus

    init(
        deviceMonitor: DeviceMonitor,
        deviceMatcher: DeviceMatcher,
        deviceLockStateInspector: DeviceLockStateInspector,
        xcodeProjectResolver: XcodeProjectResolver,
        xcodeDestinationReadinessInspector:
            XcodeDestinationReadinessInspector,
        validateEnvironment:
            @escaping @MainActor (AppConfig) -> EnvironmentStatus = {
                EnvironmentValidator().validate(config: $0)
            }
    ) {
        self.deviceMonitor = deviceMonitor
        self.deviceMatcher = deviceMatcher
        self.deviceLockStateInspector = deviceLockStateInspector
        self.xcodeProjectResolver = xcodeProjectResolver
        self.xcodeDestinationReadinessInspector =
            xcodeDestinationReadinessInspector
        self.validateEnvironment = validateEnvironment
    }

    func run(
        _ request: Request,
        callbacks: Callbacks
    ) async throws -> DeploymentPreflightOutcome {
        try ensureCurrent(callbacks)
        callbacks.reportProgress(.confirmingDevice)
        let target = try await freshTarget(
            for: request,
            callbacks: callbacks
        )

        callbacks.reportProgress(.confirmingLockState)
        let initialLock = await deviceLockStateInspector
            .inspectObservation(device: target.device)
        try ensureCurrent(callbacks)
        switch initialLock.state {
        case .locked:
            return .deviceLocked(target.device)
        case .unknown:
            let failure = initialLock.failure ?? .malformedOutput
            guard !request.context.source.isAutomatic else {
                return .lockStateUnknown(target.device, failure)
            }
            callbacks.reportProgress(
                .manualLockStateUnknown(
                    deviceName: target.device.name,
                    failure: failure
                )
            )
        case .unlocked:
            callbacks.reportProgress(.preparing)
        }

        let staticEnvironment = validateEnvironment(request.context.config)
        guard staticEnvironment.areAllChecksPassing else {
            throw DeploymentPreflightError.applicationTargetInvalid(
                staticEnvironment.summary
            )
        }
        let targetValidation = await xcodeProjectResolver
            .validateSelectedTarget(config: request.context.config)
        try ensureCurrent(callbacks)
        guard targetValidation.isValid else {
            throw DeploymentPreflightError.applicationTargetInvalid(
                targetValidation.diagnosticMessage
                    ?? "App 目标验证失败。"
            )
        }

        callbacks.reportProgress(.confirmingDestination)
        let destinationReadiness =
            await xcodeDestinationReadinessInspector.inspect(
                config: request.context.config,
                deviceID: target.device.id
            )
        try ensureCurrent(callbacks)
        switch destinationReadiness {
        case .ready:
            callbacks.reportProgress(.preparing)
        case .unknown(let diagnostic)
            where request.context.source == .manual:
            callbacks.reportProgress(
                .manualDestinationUnknown(diagnostic)
            )
        case .requiresUnlock, .unavailable, .unknown:
            return .destinationBlocked(
                target.device,
                destinationReadiness
            )
        }

        if request.context.source.isAutomatic {
            callbacks.reportProgress(.verifyingInstallation)
            let installationIsCurrent =
                await callbacks.verifyAutomaticInstallation(
                    request.context,
                    target.device
                )
            try ensureCurrent(callbacks)
            guard installationIsCurrent,
                  callbacks.isAutomaticRefreshEligible() else {
                return .automaticInstallationChanged
            }
        }

        let deploymentTarget: DeploymentStartTarget
        switch target.strategyResult {
        case .canonical(let reference):
            callbacks.reportProgress(.finalDeviceVerification)
            deploymentTarget = .verified(
                try await deviceMonitor.verifyDeploymentTarget(reference)
            )
            try ensureCurrent(callbacks)
        case .compatibility(let compatibilityTarget):
            deploymentTarget = .compatibility(compatibilityTarget)
        }
        guard deploymentTarget.device.id
                == request.expectedDeviceID.value,
              deploymentTarget.isAuthorized(
                  for: request.context.deviceDetectionRollout.mode
              ) else {
            throw DeploymentTargetError.deviceNotVerified(
                request.context.device.name
            )
        }

        if request.context.source.isAutomatic {
            callbacks.reportProgress(.finalUnlockConfirmation)
            let finalLock = await deviceLockStateInspector
                .inspectObservation(device: deploymentTarget.device)
            try ensureCurrent(callbacks)
            switch finalLock.state {
            case .unlocked:
                break
            case .locked:
                return .deviceLocked(deploymentTarget.device)
            case .unknown:
                return .lockStateUnknown(
                    deploymentTarget.device,
                    finalLock.failure ?? .malformedOutput
                )
            }
        }
        return .ready(deploymentTarget)
    }

    private func freshTarget(
        for request: Request,
        callbacks: Callbacks
    ) async throws -> FreshTarget {
        switch request.targetStrategy {
        case .canonical(let reference):
            let observation = try await deviceMonitor.observeTarget(
                reference,
                purpose: .interactive
            )
            try ensureCurrent(callbacks)
            guard case .matched(let device) = observation.evidence,
                  device.id == request.expectedDeviceID.value else {
                throw DeploymentTargetError.deviceNotVerified(
                    request.context.device.name
                )
            }
            return FreshTarget(
                device: device,
                strategyResult: .canonical(reference)
            )
        case .compatibility:
            let scan = try await deviceMonitor.scanAvailableIPhones(
                options: .reliable(
                    preferredDeviceID:
                        request.context.config.preferredDeviceID,
                    preferredDeviceName:
                        request.context.config.preferredDeviceName
                )
            )
            try ensureCurrent(callbacks)
            guard !scan.hasAvailabilityConflict(
                preferredDeviceID:
                    request.context.config.preferredDeviceID,
                preferredDeviceName:
                    request.context.config.preferredDeviceName
            ) else {
                throw DeploymentTargetError.deviceNotVerified(
                    request.context.device.name
                )
            }
            let match = deviceMatcher.match(
                preferredDeviceID:
                    request.context.config.preferredDeviceID,
                preferredDeviceName:
                    request.context.config.preferredDeviceName,
                devices: scan.devices
            )
            guard let device = match.device,
                  device.id == request.expectedDeviceID.value else {
                throw DeploymentTargetError.deviceNotVerified(
                    request.context.device.name
                )
            }
            return FreshTarget(
                device: device,
                strategyResult: .compatibility(
                    try CompatibilityDeploymentTarget(
                        device: device,
                        availableDevices: scan.devices,
                        unavailableDevices: scan.unavailableDevices
                    )
                )
            )
        }
    }

    private func ensureCurrent(_ callbacks: Callbacks) throws {
        try Task.checkCancellation()
        guard callbacks.isCurrent() else {
            throw CancellationError()
        }
    }

    private struct FreshTarget {
        let device: DeviceInfo
        let strategyResult: StrategyResult
    }

    private enum StrategyResult {
        case canonical(TargetDeviceReference)
        case compatibility(CompatibilityDeploymentTarget)
    }
}
