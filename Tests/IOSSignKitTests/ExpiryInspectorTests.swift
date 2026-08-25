import Foundation
import Testing
@testable import IOSSignKit

struct ExpiryInspectorTests {
    @Test
    func prefersStoredExpiryWhenAvailable() {
        let inspector = ExpiryInspector()
        let storedDate = Calendar.current.date(byAdding: .day, value: 4, to: Date())!
        let state = AppState(
            lastSuccessAt: Calendar.current.date(byAdding: .day, value: -1, to: Date()),
            lastPromptAt: nil,
            lastAttemptAt: nil,
            lastResult: nil,
            lastErrorSummary: nil,
            lastDetectedExpiryAt: storedDate,
            expirySource: "installed_app_profile",
            currentDeviceStatus: nil,
            currentDeviceName: nil,
            currentDeviceOS: nil,
            isDeployRunning: false,
            lastLogPath: nil
        )

        let info = inspector.inspect(state: state)
        #expect(info?.estimatedExpiryAt == storedDate)
        #expect(info?.isFallbackValue == false)
        #expect(info?.source == "installed_app_profile")
        #expect(info?.source == .unknown("installed_app_profile"))
    }

    @Test
    func confirmedAbsenceInvalidatesEveryPersistedExpiryFallback() {
        var state = AppState.default
        state.lastSuccessAt = Date().addingTimeInterval(-24 * 60 * 60)
        state.lastDetectedExpiryAt = Date().addingTimeInterval(24 * 60 * 60)
        state.expirySource = .installMetadata("embedded_mobileprovision")
        state.targetAppPresence = .confirmedNotInstalled

        #expect(ExpiryInspector().inspect(state: state) == nil)

        state.targetAppPresence = .installed
        #expect(ExpiryInspector().inspect(state: state)?.estimatedExpiryAt == state.lastDetectedExpiryAt)
    }

    @Test
    func fallsBackToSevenDayEstimateFromLastSuccess() {
        let inspector = ExpiryInspector()
        let lastSuccessAt = Date()
        let state = AppState(
            lastSuccessAt: lastSuccessAt,
            activeInstallationSuccessAt: lastSuccessAt,
            lastPromptAt: nil,
            lastAttemptAt: nil,
            lastResult: nil,
            lastErrorSummary: nil,
            lastDetectedExpiryAt: nil,
            expirySource: nil,
            currentDeviceStatus: nil,
            currentDeviceName: nil,
            currentDeviceOS: nil,
            isDeployRunning: false,
            lastLogPath: nil
        )

        let info = inspector.inspect(state: state)
        let expectedDate = PersonalSigningValidity.expiryDate(after: lastSuccessAt)
        #expect(info?.estimatedExpiryAt == expectedDate)
        #expect(info?.isFallbackValue == true)
        #expect(info?.source == "deploy_time_estimate")
    }

    @Test
    func prefersInstallMetadataExpiryWhenAvailable() {
        let inspector = ExpiryInspector()
        let metadataExpiry = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
        let installedApp = InstalledAppInfo(
            bundleIdentifier: "com.example.app",
            name: "Example",
            version: "1.0",
            bundleVersion: "1",
            appURL: "file:///tmp/Example.app",
            builtByDeveloper: true,
            installMetadata: AppInstallMetadataSnapshot(
                schemaVersion: 1,
                recordedAt: Date(),
                bundleIdentifier: "com.example.app",
                shortVersion: "1.0",
                buildVersion: "1",
                expectedExpiryAt: metadataExpiry,
                profileSource: "embedded_mobileprovision"
            ),
            installMetadataValidation: .valid
        )

        let info = inspector.inspect(state: .default, installedAppInfo: installedApp)
        #expect(info?.estimatedExpiryAt == metadataExpiry)
        #expect(info?.isFallbackValue == false)
        #expect(info?.source == "embedded_mobileprovision")
    }

    @Test
    func ignoresInstallMetadataRecordedBeforeMinimumDate() {
        let inspector = ExpiryInspector()
        let deployFinishedAt = Date()
        let deployedEstimate = Calendar.current.date(byAdding: .day, value: 7, to: deployFinishedAt)!
        let staleMetadataExpiry = Calendar.current.date(byAdding: .day, value: 1, to: deployFinishedAt)!
        let state = AppState(
            lastSuccessAt: deployFinishedAt,
            lastPromptAt: nil,
            lastAttemptAt: nil,
            lastResult: "success",
            lastErrorSummary: nil,
            lastDetectedExpiryAt: deployedEstimate,
            expirySource: "deploy_time_estimate",
            currentDeviceStatus: "online",
            currentDeviceName: "iPhone",
            currentDeviceOS: "18.0",
            isDeployRunning: false,
            lastLogPath: nil
        )
        let installedApp = InstalledAppInfo(
            bundleIdentifier: "com.example.app",
            name: "Example",
            version: "1.0",
            bundleVersion: "1",
            appURL: "file:///tmp/Example.app",
            builtByDeveloper: true,
            installMetadata: AppInstallMetadataSnapshot(
                schemaVersion: 1,
                recordedAt: deployFinishedAt.addingTimeInterval(-60),
                bundleIdentifier: "com.example.app",
                shortVersion: "1.0",
                buildVersion: "1",
                expectedExpiryAt: staleMetadataExpiry,
                profileSource: "embedded_mobileprovision"
            ),
            installMetadataValidation: .valid
        )

        let info = inspector.inspect(
            state: state,
            installedAppInfo: installedApp,
            minimumInstallMetadataRecordedAt: deployFinishedAt.addingTimeInterval(-5)
        )
        #expect(info?.estimatedExpiryAt == deployedEstimate)
        #expect(info?.isFallbackValue == false)
        #expect(info?.source == "deploy_time_estimate")
    }

    @Test
    func unvalidatedMetadataCannotOverridePersistedExpiry() {
        let persistedExpiry = Date().addingTimeInterval(2 * 24 * 60 * 60)
        let untrustedExpiry = Date().addingTimeInterval(-60)
        var state = AppState.default
        state.lastDetectedExpiryAt = persistedExpiry
        state.expirySource = .storedEstimate
        let metadata = AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: Date(),
            bundleIdentifier: "com.example.app",
            shortVersion: "1.0",
            buildVersion: "1",
            expectedExpiryAt: untrustedExpiry,
            profileSource: "untrusted"
        )

        for validation in [
            InstallMetadataValidation.notFound,
            .invalid("identity mismatch")
        ] {
            let app = InstalledAppInfo(
                bundleIdentifier: "com.example.app",
                name: "Example",
                version: "1.0",
                bundleVersion: "1",
                appURL: "file:///tmp/Example.app",
                builtByDeveloper: true,
                installMetadata: metadata,
                installMetadataValidation: validation
            )

            let info = ExpiryInspector().inspect(
                state: state,
                installedAppInfo: app
            )
            #expect(info?.estimatedExpiryAt == persistedExpiry)
            #expect(info?.source == .storedEstimate)
        }
    }
}
