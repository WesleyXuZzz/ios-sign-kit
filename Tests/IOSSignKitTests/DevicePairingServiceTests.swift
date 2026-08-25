import Foundation
import Testing
@testable import IOSSignKit

struct DevicePairingServiceTests {
    @Test
    func successfulPairUsesConfiguredDeviceIdentifier() async {
        let runner = PairingCommandRunner(result: .success())
        let service = DevicePairingService(runCommand: runner.run)

        let result = await service.pairWirelessly(device: unavailableDevice)

        #expect(result == .success)
        #expect(runner.invocation?.launchPath == "/usr/bin/xcrun")
        #expect(runner.invocation?.arguments.prefix(3) == ["devicectl", "manage", "pair"])
        #expect(runner.invocation?.arguments.contains("iphone-1") == true)
        #expect(runner.invocation?.timeoutSeconds == 61)
    }

    @Test
    func classifiesTrustAndUnlockRequirement() async {
        let runner = PairingCommandRunner(
            result: .failure(stderr: "Unlock the device and confirm Trust This Computer to continue.")
        )
        let service = DevicePairingService(runCommand: runner.run)

        let result = await service.pairWirelessly(device: unavailableDevice)

        guard case .confirmationRequired(let message) = result else {
            Issue.record("Expected confirmationRequired, got \(result)")
            return
        }
        #expect(message.contains("Unlock the device"))
    }

    @Test
    func classifiesLocalNetworkFailure() async {
        let runner = PairingCommandRunner(
            result: .failure(stderr: "The device is unavailable on the local network.")
        )
        let service = DevicePairingService(runCommand: runner.run)

        let result = await service.pairWirelessly(device: unavailableDevice)

        guard case .networkUnavailable = result else {
            Issue.record("Expected networkUnavailable, got \(result)")
            return
        }
    }

    @Test
    func classifiesUnsupportedToolchain() async {
        let runner = PairingCommandRunner(
            result: .failure(stderr: "This device version is not supported. Upgrade Xcode.")
        )
        let service = DevicePairingService(runCommand: runner.run)

        let result = await service.pairWirelessly(device: unavailableDevice)

        guard case .toolchainUnsupported = result else {
            Issue.record("Expected toolchainUnsupported, got \(result)")
            return
        }
    }

    @Test
    func unlockEvidenceWinsWhenFailureAlsoSaysNotSupported() async {
        let runner = PairingCommandRunner(
            result: .failure(
                stderr:
                    "This operation is not supported while the device is locked. Unlock the device and retry."
            )
        )
        let service = DevicePairingService(runCommand: runner.run)

        let result = await service.pairWirelessly(
            device: unavailableDevice
        )

        guard case .confirmationRequired = result else {
            Issue.record(
                "Expected confirmationRequired, got \(result)"
            )
            return
        }
    }

    @Test
    func keepsUnknownFailureDiagnostic() async {
        let runner = PairingCommandRunner(result: .failure(stderr: "Pairing failed with code 42."))
        let service = DevicePairingService(runCommand: runner.run)

        let result = await service.pairWirelessly(device: unavailableDevice)

        guard case .failed(let message) = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
        #expect(message.contains("code 42"))
    }
}

private final class PairingCommandRunner: @unchecked Sendable {
    struct Invocation: Sendable {
        let launchPath: String
        let arguments: [String]
        let timeoutSeconds: TimeInterval?
    }

    private let lock = NSLock()
    private let result: CommandResult
    private(set) var invocation: Invocation?

    init(result: CommandResult) {
        self.result = result
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        lock.lock()
        invocation = Invocation(
            launchPath: launchPath,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        )
        lock.unlock()
        return result
    }
}

private let unavailableDevice = UnavailableDeviceInfo(
    id: "iphone-1",
    name: "Example iPhone",
    osVersion: "27.0",
    pairingState: "unpaired",
    connectionState: nil,
    tunnelState: "unavailable",
    developerModeStatus: "enabled",
    diagnosticMessage: nil
)

private extension CommandResult {
    static func success(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 0)
    }

    static func failure(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 1)
    }
}
