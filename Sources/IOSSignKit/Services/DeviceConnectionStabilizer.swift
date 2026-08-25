import Foundation

enum DeviceConnectionEvidence: Equatable, Sendable {
    case online
    case targetAbsent
    case scanFailed
}

enum DeviceConnectionResolution: String, Equatable, Sendable {
    case online
    case confirming
    case offline
    case scanFailed = "scan_failed"

    var deviceStatus: DeviceStatus {
        DeviceStatus(rawValue: rawValue)
    }
}

struct DeviceConnectionStabilizer: Sendable {
    var confirmationInterval: TimeInterval = 30
    var requiredAbsenceCount: Int = 2

    func resolve(
        evidence: DeviceConnectionEvidence,
        lastSeenAt: Date?,
        confirmationStartedAt: Date?,
        confirmedAbsenceCount: Int,
        now: Date = Date()
    ) -> DeviceConnectionResolution {
        if evidence == .online {
            return .online
        }

        guard lastSeenAt != nil else {
            return evidence == .targetAbsent ? .offline : .scanFailed
        }

        guard let confirmationStartedAt else {
            return .confirming
        }

        let isWithinConfirmationWindow = now.timeIntervalSince(confirmationStartedAt) < confirmationInterval
        if isWithinConfirmationWindow {
            return .confirming
        }

        if evidence == .targetAbsent, confirmedAbsenceCount >= requiredAbsenceCount {
            return .offline
        }

        return .scanFailed
    }
}
