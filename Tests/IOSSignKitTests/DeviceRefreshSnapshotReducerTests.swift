import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct DeviceRefreshSnapshotReducerTests {
    @Test
    func matchedInstalledAppProducesOneActionablePlan() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let device = makeDevice()
        let appInfo = makeAppInfo(
            recordedAt: now.addingTimeInterval(-10),
            expiryAt: now.addingTimeInterval(3_600)
        )

        let plan = makeReducer().reduce(
            input(
                snapshot: snapshot(
                    device: device,
                    quality: .complete,
                    outcome: .found(appInfo)
                ),
                now: now
            )
        )

        #expect(plan.connectionResolution == .online)
        #expect(plan.resetsConnectionEvidence)
        #expect(plan.installedAppInfo == appInfo)
        #expect(plan.state.isTargetAppExpiryEvidenceVerified)
        #expect(plan.expiryInfo?.estimatedExpiryAt != nil)
        #expect(!plan.shouldSuppressRefreshActions)
        #expect(plan.cacheIssue == nil)
        #expect(plan.shouldResetInstalledAppRetry)
    }

    @Test
    func degradedObservationSuppressesActionsAndInvalidatesCache() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000)
        let device = makeDevice()
        let appInfo = makeAppInfo(
            recordedAt: now.addingTimeInterval(-10),
            expiryAt: now.addingTimeInterval(3_600)
        )

        let plan = makeReducer().reduce(
            input(
                snapshot: snapshot(
                    device: device,
                    quality: .degraded,
                    outcome: .found(appInfo),
                    diagnostic: "设备证据不完整"
                ),
                now: now
            )
        )

        #expect(plan.connectionResolution == .online)
        #expect(plan.shouldSuppressRefreshActions)
        #expect(plan.cacheIssue == .partial)
        #expect(plan.setupMessage == "设备证据不完整")
    }

    @Test
    func skippedInspectionDoesNotInventAnInstallationBlocker() {
        let now = Date(timeIntervalSinceReferenceDate: 2_500)
        let device = makeDevice()

        let plan = makeReducer().reduce(
            input(
                snapshot: snapshot(
                    device: device,
                    quality: .complete,
                    outcome: .notRequested
                ),
                now: now
            )
        )

        #expect(plan.connectionResolution == .online)
        #expect(!plan.state.isTargetAppExpiryEvidenceVerified)
        #expect(!plan.shouldSuppressRefreshActions)
    }

    @Test
    func secondConfirmedAbsenceClearsInstallationEvidence() {
        let now = Date(timeIntervalSinceReferenceDate: 3_000)
        let device = makeDevice()
        let previousApp = makeAppInfo(
            recordedAt: now.addingTimeInterval(-100),
            expiryAt: now.addingTimeInterval(3_600)
        )
        var state = AppState.default
        state.targetAppPresence = .installed
        state.targetAppBundleID = previousApp.bundleIdentifier
        state.targetDeviceID = device.id
        state.targetAppVersion = previousApp.version
        state.targetAppBuildVersion = previousApp.bundleVersion
        state.targetAppURL = previousApp.appURL
        state.isTargetAppExpiryEvidenceVerified = true
        state.lastDetectedExpiryAt = now.addingTimeInterval(3_600)
        state.expirySource = .installMetadata(
            "embedded_mobileprovision"
        )

        let plan = makeReducer().reduce(
            input(
                snapshot: snapshot(
                    device: device,
                    quality: .complete,
                    outcome: .notInstalled
                ),
                state: state,
                consecutiveAbsences: 1,
                installedAppInfo: previousApp,
                now: now
            )
        )

        #expect(plan.consecutiveInstalledAppAbsences == 2)
        #expect(plan.installedAppInfo == nil)
        #expect(plan.state.targetAppPresence == .confirmedNotInstalled)
        #expect(!plan.state.isTargetAppExpiryEvidenceVerified)
        #expect(plan.expiryInfo == nil)
        #expect(plan.shouldSuppressRefreshActions)
        #expect(plan.shouldResetInstalledAppRetry)
    }

    private func makeReducer() -> DeviceRefreshSnapshotReducer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-snapshot-reducer-\(UUID().uuidString)",
                isDirectory: true
            )
        return DeviceRefreshSnapshotReducer(
            connectionReducer: DeviceConnectionReducer(),
            connectionStabilizer: DeviceConnectionStabilizer(),
            stateSettlement: RefreshStateSettlement(
                stateStore: RefreshStateStore(
                    appSupportDirectory: directory
                )
            ),
            expiryInspector: ExpiryInspector(),
            requiredAbsenceCount: 2,
            unidentifiedEvidenceGracePeriod: 600
        )
    }

    private func input(
        snapshot: DeviceRefreshSnapshot,
        state: AppState = .default,
        consecutiveAbsences: Int = 0,
        installedAppInfo: InstalledAppInfo? = nil,
        now: Date
    ) -> DeviceRefreshSnapshotReducer.Input {
        var config = AppConfig.default
        config.bundleID = "com.example.reducer"
        config.preferredDeviceID = makeDevice().id
        config.preferredDeviceName = makeDevice().name
        return DeviceRefreshSnapshotReducer.Input(
            snapshot: snapshot,
            config: config,
            state: state,
            previousMatchedDevice: nil,
            connectionState: .initial,
            connectionConfirmationStartedAt: nil,
            confirmedDeviceAbsenceCount: 0,
            consecutiveInstalledAppAbsences: consecutiveAbsences,
            installedAppInfo: installedAppInfo,
            installedAppInspectionFailure: nil,
            externallySuppressesActions: false,
            now: now,
            observedAt: ContinuousClock().now
        )
    }

    private func snapshot(
        device: DeviceInfo,
        quality: ObservationQuality,
        outcome: InstalledAppInspectionOutcome,
        diagnostic: String? = nil
    ) -> DeviceRefreshSnapshot {
        DeviceRefreshSnapshot(
            environmentStatus: .unknown,
            availableDevices: [device],
            matchedDevice: device,
            deviceMatchResult: .matched(device),
            installedAppInspectionOutcome: outcome,
            treatsScanFailureAsTransient: false,
            refreshMode: .manualDeepCheck,
            scanResult: nil,
            targetObservation: TargetDeviceObservation(
                evidence: .matched(device),
                recoveryCandidate: nil,
                diagnostics: DeviceObservationDiagnostics(
                    quality: quality,
                    source: .xcdevice,
                    summary: diagnostic
                )
            ),
            identityPersistenceCandidate: nil,
            policyGeneration: 0,
            observationGeneration: 0,
            allowsCriticalActions: true,
            usedCachedActionEvidence: false,
            xcodeCacheUpdate: nil,
            installedAppCacheUpdate: nil,
            installedAppCacheInvalidationKey: nil,
            errorMessage: nil
        )
    }

    private func makeDevice() -> DeviceInfo {
        DeviceInfo(
            id: "00008110-001234567890001E",
            name: "Reducer iPhone",
            platform: "iOS",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
    }

    private func makeAppInfo(
        recordedAt: Date,
        expiryAt: Date
    ) -> InstalledAppInfo {
        InstalledAppInfo(
            bundleIdentifier: "com.example.reducer",
            name: "Reducer App",
            version: "1.0",
            bundleVersion: "1",
            appURL:
                "application-container:55555555-5555-5555-5555-555555555555",
            builtByDeveloper: true,
            installMetadata: AppInstallMetadataSnapshot(
                schemaVersion: 1,
                recordedAt: recordedAt,
                bundleIdentifier: "com.example.reducer",
                shortVersion: "1.0",
                buildVersion: "1",
                expectedExpiryAt: expiryAt,
                profileSource: "embedded_mobileprovision"
            ),
            installMetadataValidation: .valid
        )
    }
}
