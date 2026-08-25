import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct DeviceRefreshWorkflowTests {
    @Test
    func refreshReturnsMatchedDeviceAndInstallationInspection() async throws {
        let deviceID = "00008110-001234567890001E"
        let monitor = DeviceMonitor(runCommandAsync: { _, _, _ in
            CommandResult(
                standardOutput: Self.xcdeviceJSON(
                    id: deviceID,
                    name: "Workflow iPhone"
                ),
                standardError: "",
                terminationStatus: 0
            )
        })
        let workflow = DeviceRefreshWorkflow(
            deviceMonitor: monitor,
            deviceMatcher: DeviceMatcher(),
            xcodeProjectResolver: XcodeProjectResolver(),
            inspectInstalledApp: { device, bundleID, _, _ in
                InstalledAppInfo(
                    bundleIdentifier: bundleID,
                    name: "Workflow App",
                    version: "1.0",
                    bundleVersion: "1",
                    appURL:
                        "application-container:44444444-4444-4444-4444-444444444444",
                    builtByDeveloper: true,
                    installMetadata: nil,
                    installMetadataValidation: .notFound
                )
            }
        )

        let transition = try await workflow.refresh(
            request(deviceID: deviceID)
        )

        #expect(transition.snapshot.matchedDevice?.id == deviceID)
        #expect(transition.snapshot.availableDevices.count == 1)
        #expect(transition.snapshot.allowsCriticalActions)
        #expect(transition.snapshot.errorMessage == nil)
        guard case .found(let appInfo) =
                transition.snapshot.installedAppInspectionOutcome else {
            Issue.record("应返回已安装 App 的检查结果")
            return
        }
        #expect(appInfo.bundleIdentifier == "com.example.workflow")
        #expect(transition.snapshot.installedAppCacheUpdate != nil)
    }

    @Test
    func sourceFailureRemainsTypedTargetObservation() async throws {
        let monitor = DeviceMonitor(runCommandAsync: { _, _, _ in
            throw WorkflowTestError.scanUnavailable
        })
        let workflow = DeviceRefreshWorkflow(
            deviceMonitor: monitor,
            deviceMatcher: DeviceMatcher(),
            xcodeProjectResolver: XcodeProjectResolver(),
            inspectInstalledApp: { _, _, _, _ in
                Issue.record("设备扫描失败时不应检查已安装 App")
                return nil
            }
        )

        let transition = try await workflow.refresh(
            request(deviceID: "00008110-001234567890001E")
        )

        #expect(transition.snapshot.matchedDevice == nil)
        #expect(transition.snapshot.availableDevices.isEmpty)
        #expect(transition.snapshot.errorMessage == nil)
        let observationDiagnostic =
            transition.snapshot.targetObservation?.diagnostics.summary
        #expect(
            observationDiagnostic?.contains("模拟扫描失败") == true
        )
        guard case .notRequested =
                transition.snapshot.installedAppInspectionOutcome else {
            Issue.record("扫描失败不应产生 App 检查结果")
            return
        }
        #expect(transition.comparisonSample == nil)
    }

    private func request(deviceID: String) -> DeviceRefreshRequest {
        var config = AppConfig.default
        config.bundleID = "com.example.workflow"
        config.preferredDeviceID = deviceID
        config.preferredDeviceName = "Workflow iPhone"
        return DeviceRefreshRequest(
            config: config,
            mode: .backgroundPoll,
            rolloutState: DeviceDetectionRolloutState(
                mode: .production,
                generation: 7
            ),
            targetGeneration: 3,
            observationGeneration: 11,
            sessionCaches: RefreshSessionCaches(),
            criticalActionCandidates: [],
            hasKnownExpiry: false,
            hasConfirmedInstallation: false,
            lastResult: nil,
            isDeployRunning: false,
            isPassiveRefresh: false,
            targetOverride: nil
        )
    }

    nonisolated private static func xcdeviceJSON(
        id: String,
        name: String
    ) -> String {
        """
        [
          {
            "ignored": false,
            "simulator": false,
            "platform": "com.apple.platform.iphoneos",
            "available": true,
            "identifier": "\(id)",
            "name": "\(name)",
            "modelCode": "iPhone17,1",
            "modelName": "iPhone",
            "operatingSystemVersion": "27.0"
          }
        ]
        """
    }
}

private enum WorkflowTestError: LocalizedError {
    case scanUnavailable

    var errorDescription: String? {
        "模拟扫描失败"
    }
}
