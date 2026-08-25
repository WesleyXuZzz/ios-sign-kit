import Foundation
import Testing
@testable import IOSSignKit

struct DomainBoundaryRegressionTests {
    @Test
    func deploymentTokenRequiresCanonicalUUIDSuffix() {
        let valid = DeploymentToken.make()

        #expect(DeploymentToken(rawValue: valid.rawValue) == valid)
        #expect(DeploymentToken(rawValue: "\(DeploymentToken.prefix)worker") == nil)
        #expect(DeploymentToken(rawValue: "\(DeploymentToken.prefix)\(UUID().uuidString)-extra") == nil)
    }

    @Test
    func appURLNormalizationBindsEquivalentRepresentationsToOneContainer() {
        let uuid = UUID()
        let upper = uuid.uuidString
        let lower = upper.lowercased()

        let first = InstalledAppIdentity.normalizedAppURL(
            "file:///private/var/containers/Bundle/Application/\(upper)/Example.app/"
        )
        let second = InstalledAppIdentity.normalizedAppURL(
            "file:///private/var/containers/Bundle/Application/\(lower)/Example.app"
        )

        #expect(first == second)
        #expect(
            first != InstalledAppIdentity.normalizedAppURL(
                "file:///private/var/containers/Bundle/Application/\(UUID().uuidString)/Example.app"
            )
        )
    }

    @Test
    func legacyDeploymentTargetRejectsUnavailableSameNameAndUnsafeIdentity()
        throws
    {
        let selected = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        let unavailableTwin = UnavailableDeviceInfo(
            id: "iphone-2",
            name: "Example iPhone",
            osVersion: "27.0",
            pairingState: "paired",
            connectionState: "connecting",
            tunnelState: nil,
            developerModeStatus: nil,
            diagnosticMessage: nil
        )

        #expect(throws: DeploymentTargetError.self) {
            _ = try CompatibilityDeploymentTarget(
                device: selected,
                availableDevices: [selected],
                unavailableDevices: [unavailableTwin]
            )
        }

        var unsafe = selected
        unsafe.name = "Example\u{0}iPhone"
        #expect(throws: DeploymentTargetError.self) {
            _ = try CompatibilityDeploymentTarget(
                device: unsafe,
                availableDevices: [unsafe]
            )
        }
    }

    @Test
    func historicalSuccessCannotReviveAnUnboundInstallationFallback() {
        var state = AppState.default
        state.lastSuccessAt = Date()
        state.targetAppPresence = .installed

        #expect(ExpiryInspector().inspect(state: state) == nil)

        state.activeInstallationSuccessAt = state.lastSuccessAt
        #expect(ExpiryInspector().inspect(state: state) != nil)
    }

    @Test
    func unknownPersistedDeviceStatusIsPresentedAsUnknown() {
        let presentation = DeviceStatusPresentation.make(
            status: .unrecognized("future-status"),
            hasPersistedIdentity: true
        )

        #expect(presentation.disconnectedSummary == "未知状态")
        #expect(presentation.disconnectedTone == .neutral)
    }

    @Test
    func onlyOneApplicationInstanceCanHoldTheWorkspaceLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-instance-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        let first = ApplicationInstanceLock(appSupportDirectory: directory)
        let second = ApplicationInstanceLock(appSupportDirectory: directory)

        try first.acquire()
        #expect(throws: ApplicationInstanceLockError.alreadyRunning) {
            try second.acquire()
        }
        first.release()
        try second.acquire()
        second.release()
    }
}
