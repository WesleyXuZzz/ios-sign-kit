import Foundation

struct InstallationIdentitySnapshot: Equatable, Hashable, Sendable {
    let presence: TargetAppPresence
    let bundleID: String?
    let deviceID: String?
    let version: String?
    let buildVersion: String?
    let appURL: String?
    let activeInstallationSuccessAt: Date?
    let expiryEvidenceIsVerified: Bool

    init(
        presence: TargetAppPresence,
        bundleID: String?,
        deviceID: String?,
        version: String?,
        buildVersion: String?,
        appURL: String?,
        activeInstallationSuccessAt: Date?,
        expiryEvidenceIsVerified: Bool
    ) {
        self.presence = presence
        self.bundleID = bundleID
        self.deviceID = deviceID
        self.version = version
        self.buildVersion = buildVersion
        self.appURL = appURL
        self.activeInstallationSuccessAt = activeInstallationSuccessAt
        self.expiryEvidenceIsVerified = expiryEvidenceIsVerified
    }

    init(state: AppState) {
        self.init(
            presence: state.targetAppPresence,
            bundleID: state.targetAppBundleID,
            deviceID: state.targetDeviceID,
            version: state.targetAppVersion,
            buildVersion: state.targetAppBuildVersion,
            appURL: state.targetAppURL,
            activeInstallationSuccessAt: state.activeInstallationSuccessAt,
            expiryEvidenceIsVerified:
                state.isTargetAppExpiryEvidenceVerified
        )
    }
}
