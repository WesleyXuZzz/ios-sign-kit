import Foundation

struct RolloutDiagnostic: Equatable, Sendable {
    let message: String
}

struct RolloutResolution: Equatable, Sendable {
    let mode: DeviceDetectionRolloutMode
    let diagnostic: RolloutDiagnostic?
}

struct DeviceDetectionRolloutConfiguration: Equatable, Sendable {
    static let environmentKey = "IOS_SIGN_KIT_DEVICE_DETECTION_POLICY"

    let resolution: RolloutResolution

    var mode: DeviceDetectionRolloutMode {
        resolution.mode
    }

    init(
        processEnvironment: [String: String] =
            ProcessInfo.processInfo.environment
    ) {
        resolution = Self.resolve(environment: processEnvironment)
    }

    static func resolve(environment: [String: String]) -> RolloutResolution {
        let configuredValue = environment[environmentKey]
        switch configuredValue {
        case nil:
            return RolloutResolution(mode: .production, diagnostic: nil)
        case "fallback":
            return RolloutResolution(mode: .fallback, diagnostic: nil)
        case "shadow":
            return RolloutResolution(mode: .shadow, diagnostic: nil)
        case "readOnly":
            return RolloutResolution(mode: .readOnly, diagnostic: nil)
        case "production":
            return RolloutResolution(mode: .production, diagnostic: nil)
        default:
            let renderedValue = configuredValue ?? ""
            return RolloutResolution(
                mode: .readOnly,
                diagnostic: RolloutDiagnostic(
                    message:
                        "设备检测配置值“\(renderedValue)”无效，已进入只读保护。"
                        + "请将 \(environmentKey) 设置为 fallback、shadow、"
                        + "readOnly 或 production 后重新启动 iOSSignKit。"
                )
            )
        }
    }
}
