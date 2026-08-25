import Foundation

struct ExpiryInspector {
    func inspect(
        state: AppState,
        installedAppInfo: InstalledAppInfo? = nil,
        now: Date = Date(),
        minimumInstallMetadataRecordedAt: Date? = nil
    ) -> ExpiryInfo? {
        if state.targetAppPresence == .confirmedNotInstalled {
            return nil
        }

        if installedAppInfo == nil,
           state.activeInstallationSuccessAt == nil,
           state.lastDetectedExpiryAt == nil {
            return nil
        }

        if installedAppInfo?.installMetadataValidation == .valid,
           let installMetadata = installedAppInfo?.installMetadata,
           minimumInstallMetadataRecordedAt.map({ installMetadata.recordedAt >= $0 }) ?? true,
           let metadataExpiry = installMetadata.expectedExpiryAt {
            return ExpiryInfo(
                estimatedExpiryAt: metadataExpiry,
                source: .installMetadata(installMetadata.profileSource),
                detectedAt: now,
                isFallbackValue: false
            )
        }

        if let lastDetectedExpiryAt = state.lastDetectedExpiryAt {
            return ExpiryInfo(
                estimatedExpiryAt: lastDetectedExpiryAt,
                source: state.expirySource ?? .storedEstimate,
                detectedAt: state.lastExpiryVerifiedAt ?? now,
                isFallbackValue: false
            )
        }

        guard let lastSuccessAt = state.activeInstallationSuccessAt else {
            return nil
        }

        let estimatedExpiryAt = PersonalSigningValidity.expiryDate(
            after: lastSuccessAt
        )
        return ExpiryInfo(
            estimatedExpiryAt: estimatedExpiryAt,
            source: installedAppInfo == nil ? .deployTimeEstimate : .installedAppDetectedDeployTimeEstimate,
            detectedAt: now,
            isFallbackValue: true
        )
    }
}
