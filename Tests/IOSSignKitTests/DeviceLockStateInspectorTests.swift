import Foundation
import Testing
@testable import IOSSignKit

struct DeviceLockStateInspectorTests {
    @Test
    func returnsLockedFromBooleanField() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(result: .success(), outputFileContents: lockStateJSON(#"{"result":{"locked":true}}"#))
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .locked)
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].launchPath == "/usr/bin/xcrun")
        #expect(runner.invocations[0].arguments.prefix(4) == ["devicectl", "device", "info", "lockState"])
        #expect(runner.invocations[0].arguments.contains("--device"))
        #expect(runner.invocations[0].arguments.contains("iphone-1"))
        #expect(runner.invocations[0].arguments.contains("--timeout"))
        #expect(runner.invocations[0].arguments.contains("5"))
        #expect(runner.invocations[0].arguments.contains("--json-output"))
        #expect(runner.invocations[0].timeoutSeconds == 6)
    }

    @Test
    func returnsUnlockedFromStringField() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(result: .success(), outputFileContents: lockStateJSON(#"{"result":{"lockState":"unlocked"}}"#))
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .unlocked)
    }

    @Test
    func returnsUnlockedFromCoreDevicePasscodeRequiredField() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(
                result: .success(),
                outputFileContents: coreDeviceLockStateJSON(
                    passcodeRequired: false
                )
            )
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .unlocked)
    }

    @Test
    func returnsLockedFromCoreDevicePasscodeRequiredField() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(
                result: .success(),
                outputFileContents: coreDeviceLockStateJSON(
                    passcodeRequired: true
                )
            )
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .locked)
    }

    @Test
    func unlockedSinceBootAloneDoesNotClaimCurrentUnlock() {
        let state = DeviceLockStateInspector.lockState(from: [
            "result": ["unlockedSinceBoot": true]
        ])

        #expect(state == nil)
    }

    @Test
    func transientCommandFailureIsRetriedOnce() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(result: .failure(stderr: "CoreDevice connection invalidated")),
            .init(
                result: .success(),
                outputFileContents: coreDeviceLockStateJSON(
                    passcodeRequired: false
                )
            )
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .unlocked)
        #expect(runner.invocations.count == 2)
    }

    @Test
    func unsupportedSchemaPreservesToolMetadata() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(
                result: .success(),
                outputFileContents: """
                {
                  "info": {
                    "jsonVersion": 3,
                    "outcome": "success",
                    "version": "518.33"
                  },
                  "result": {"unlockedSinceBoot": true}
                }
                """
            )
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let observation = await inspector.inspectObservation(
            device: exampleDevice
        )

        #expect(
            observation
                == .indeterminate(
                    .unsupportedSchema(
                        jsonVersion: 3,
                        toolVersion: "518.33"
                    )
                )
        )
        #expect(runner.invocations.count == 1)
    }

    @Test
    func malformedPasscodeRequiredDoesNotFallBackToWeakerEvidence() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(
                result: .success(),
                outputFileContents: #"{"result":{"passcodeRequired":"false","locked":false}}"#
            )
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let observation = await inspector.inspectObservation(
            device: exampleDevice
        )

        #expect(observation == .indeterminate(.malformedOutput))
        #expect(runner.invocations.count == 1)
    }

    @Test
    func conflictingPasscodeAndCompatibilityEvidenceIsUnknown() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(
                result: .success(),
                outputFileContents: #"{"result":{"passcodeRequired":false,"locked":true}}"#
            )
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let observation = await inspector.inspectObservation(
            device: exampleDevice
        )

        #expect(observation == .indeterminate(.conflictingEvidence))
        #expect(runner.invocations.count == 1)
    }

    @Test
    func commandFailureReturnsUnknown() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(result: .failure(stderr: "CoreDevice timed out"))
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .unknown)
        #expect(runner.invocations.count == 2)
    }

    @Test
    func missingLockStateReturnsUnknown() async {
        let runner = ScriptedLockStateCommandRunner(responses: [
            .init(result: .success(), outputFileContents: lockStateJSON(#"{"result":{"device":"iphone-1"}}"#))
        ])
        let inspector = DeviceLockStateInspector(runCommand: runner.run)

        let state = await inspector.inspect(device: exampleDevice)

        #expect(state == .unknown)
    }

    @Test
    func conflictingLockFieldsReturnUnknownRegardlessOfDictionaryOrder() {
        let state = DeviceLockStateInspector.lockState(from: [
            "result": [
                "locked": true,
                "lockState": "unlocked"
            ]
        ])

        #expect(state == nil)
    }

    @Test
    func unrelatedNestedStateFieldIsIgnored() {
        let state = DeviceLockStateInspector.lockState(from: [
            "result": [
                "locked": true,
                "history": ["state": "unlocked"]
            ]
        ])

        #expect(state == .locked)
    }

    private var exampleDevice: DeviceInfo {
        DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "26.5",
            isAvailable: true,
            isPaired: true
        )
    }
}

private final class ScriptedLockStateCommandRunner: @unchecked Sendable {
    struct Invocation: Sendable {
        let launchPath: String
        let arguments: [String]
        let timeoutSeconds: TimeInterval?
    }

    private let lock = NSLock()
    private var responses: [LockStateResponse]
    private(set) var invocations: [Invocation] = []

    init(responses: [LockStateResponse]) {
        self.responses = responses
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        let response: LockStateResponse
        lock.lock()
        invocations.append(Invocation(launchPath: launchPath, arguments: arguments, timeoutSeconds: timeoutSeconds))
        response = responses.isEmpty ? .init(result: .failure(stderr: "missing scripted response")) : responses.removeFirst()
        lock.unlock()

        if let outputFileContents = response.outputFileContents,
           let outputPath = jsonOutputPath(from: arguments) {
            try outputFileContents.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }

        return response.result
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }
}

private struct LockStateResponse: Sendable {
    let result: CommandResult
    let outputFileContents: String?

    init(result: CommandResult, outputFileContents: String? = nil) {
        self.result = result
        self.outputFileContents = outputFileContents
    }
}

private extension CommandResult {
    static func success(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 0)
    }

    static func failure(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(standardOutput: stdout, standardError: stderr, terminationStatus: 1)
    }
}

private func lockStateJSON(_ resultBody: String) -> String {
    resultBody
}

private func coreDeviceLockStateJSON(
    passcodeRequired: Bool,
    unlockedSinceBoot: Bool = true
) -> String {
    """
    {
      "info": {
        "jsonVersion": 3,
        "outcome": "success",
        "version": "518.33"
      },
      "result": {
        "deviceIdentifier": "CORE-DEVICE-ID",
        "passcodeRequired": \(passcodeRequired),
        "unlockedSinceBoot": \(unlockedSinceBoot)
      }
    }
    """
}
