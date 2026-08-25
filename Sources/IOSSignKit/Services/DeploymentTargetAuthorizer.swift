import Foundation

struct DeploymentTarget: Equatable, Sendable {
    let device: DeviceInfo

    fileprivate init(verifiedDevice: DeviceInfo) {
        self.device = verifiedDevice
    }
}

enum DeploymentStartTarget: Equatable, Sendable {
    case verified(DeploymentTarget)
    case compatibility(CompatibilityDeploymentTarget)

    var device: DeviceInfo {
        switch self {
        case .verified(let target):
            return target.device
        case .compatibility(let target):
            return target.device
        }
    }

    func isAuthorized(
        for mode: DeviceDetectionRolloutMode
    ) -> Bool {
        switch (mode, self) {
        case (.production, .verified),
             (.fallback, .compatibility),
             (.shadow, .compatibility):
            return true
        case (.production, .compatibility),
             (.fallback, .verified),
             (.shadow, .verified),
             (.readOnly, _):
            return false
        }
    }
}

struct DeploymentTargetAuthorizer: Sendable {
    func authorize(
        outcomes: [(DeviceScanSource, SourceScanOutcome)],
        observation: TargetDeviceObservation
    ) throws -> DeploymentTarget {
        guard outcomes.allSatisfy({ $0.1.isComplete }) else {
            throw DeviceMonitorError.commandFailed(
                "续签前设备来源未全部返回完整结果，本次续签已停止。"
            )
        }

        guard case .matched(let device) = observation.evidence else {
            throw DeviceMonitorError.commandFailed(
                "续签前无法从同一轮完整设备证据确认目标 iPhone，本次续签已停止。"
            )
        }

        let assessed = outcomes
            .flatMap { $0.1.records }
            .compactMap(\.assessment)
        let availableDevices = DeviceEvidenceMerger.available(
            assessed.compactMap {
                guard case .positive(let device) = $0 else {
                    return nil
                }
                return device
            }
        )
        let unavailableDevices = DeviceEvidenceMerger.unavailable(
            assessed.compactMap {
                switch $0 {
                case .unavailable(let device, _),
                     .uncertain(let device, _):
                    return device
                case .positive:
                    return nil
                }
            }
        )
        let compatibilityValidatedTarget = try CompatibilityDeploymentTarget(
            device: device,
            availableDevices: availableDevices,
            unavailableDevices: unavailableDevices
        )
        return DeploymentTarget(
            verifiedDevice: compatibilityValidatedTarget.device
        )
    }

}
