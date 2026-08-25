import Foundation

enum DeviceStatus: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    case unknown
    case online
    case offline
    case confirming
    case scanFailed
    case wirelessPairing
    case wirelessPairingConfirmationRequired
    case wirelessPairingRequired
    case xcodeUpdateRequired
    case wiredConnectionRequired
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "unknown": self = .unknown
        case "online": self = .online
        case "offline": self = .offline
        case "confirming": self = .confirming
        case "scan_failed": self = .scanFailed
        case "wireless_pairing": self = .wirelessPairing
        case "wireless_pairing_confirmation_required": self = .wirelessPairingConfirmationRequired
        case "wireless_pairing_required": self = .wirelessPairingRequired
        case "xcode_update_required": self = .xcodeUpdateRequired
        case "wired_connection_required": self = .wiredConnectionRequired
        default: self = .unrecognized(rawValue)
        }
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    var rawValue: String {
        switch self {
        case .unknown: "unknown"
        case .online: "online"
        case .offline: "offline"
        case .confirming: "confirming"
        case .scanFailed: "scan_failed"
        case .wirelessPairing: "wireless_pairing"
        case .wirelessPairingConfirmationRequired: "wireless_pairing_confirmation_required"
        case .wirelessPairingRequired: "wireless_pairing_required"
        case .xcodeUpdateRequired: "xcode_update_required"
        case .wiredConnectionRequired: "wired_connection_required"
        case .unrecognized(let rawValue): rawValue
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum RefreshResult: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    case running
    case success
    case failure
    case cancelled
    case interrupted
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "running": self = .running
        case "success": self = .success
        case "failure": self = .failure
        case "cancelled": self = .cancelled
        case "interrupted": self = .interrupted
        default: self = .unrecognized(rawValue)
        }
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    var rawValue: String {
        switch self {
        case .running: "running"
        case .success: "success"
        case .failure: "failure"
        case .cancelled: "cancelled"
        case .interrupted: "interrupted"
        case .unrecognized(let rawValue): rawValue
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ExpirySource: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    case storedEstimate
    case deployTimeEstimate
    case installedAppDetectedDeployTimeEstimate
    case verifiedDeploymentProfile
    case installMetadata(String)
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "stored_estimate": self = .storedEstimate
        case "deploy_time_estimate": self = .deployTimeEstimate
        case "installed_app_detected_deploy_time_estimate": self = .installedAppDetectedDeployTimeEstimate
        case "verified_deployment_profile": self = .verifiedDeploymentProfile
        case "embedded_mobileprovision": self = .installMetadata(rawValue)
        default:
            if rawValue.hasPrefix("install_metadata:") {
                self = .installMetadata(String(rawValue.dropFirst("install_metadata:".count)))
            } else {
                self = .unknown(rawValue)
            }
        }
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    var rawValue: String {
        switch self {
        case .storedEstimate: "stored_estimate"
        case .deployTimeEstimate: "deploy_time_estimate"
        case .installedAppDetectedDeployTimeEstimate: "installed_app_detected_deploy_time_estimate"
        case .verifiedDeploymentProfile: "verified_deployment_profile"
        case .installMetadata("embedded_mobileprovision"): "embedded_mobileprovision"
        case .installMetadata(let rawValue): "install_metadata:\(rawValue)"
        case .unknown(let rawValue): rawValue
        }
    }

    var requiresInstallationIdentityValidation: Bool {
        switch self {
        case .installMetadata, .unknown:
            return true
        case .storedEstimate,
             .deployTimeEstimate,
             .installedAppDetectedDeployTimeEstimate,
             .verifiedDeploymentProfile:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TargetAppPresence: String, Equatable, Hashable, Sendable, Codable {
    case unknown
    case installed
    case confirmingNotInstalled
    case confirmedNotInstalled
}
