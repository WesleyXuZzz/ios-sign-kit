import Foundation
import Testing
@testable import IOSSignKit

struct XcodeDestinationReadinessInspectorTests {
    @Test
    func exactReadyDestinationIsAcceptedAndCommandContractIsStable() async {
        let invocation = DestinationInvocationRecorder(
            result: destinationSuccess(stdout: """
            Available destinations for the "Example" scheme:
                { platform:iOS, arch:arm64, id:OTHER, name:Other iPhone }
                { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone }
            """)
        )
        let inspector = XcodeDestinationReadinessInspector(runCommand: invocation.run)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .ready)
        #expect(invocation.launchPath == "/usr/bin/xcodebuild")
        #expect(invocation.arguments == [
            "-project", "/tmp/Example.xcodeproj",
            "-scheme", "Example",
            "-destination", "id=TARGET-ID",
            "-destination-timeout", "5",
            "-showdestinations"
        ])
        #expect(invocation.timeoutSeconds == 8)
    }

    @Test
    func workspaceUsesWorkspaceContainerArgument() async {
        let invocation = DestinationInvocationRecorder(
            result: destinationSuccess(stdout: """
            Available destinations:
                { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone }
            """)
        )
        let inspector = XcodeDestinationReadinessInspector(
            runCommand: invocation.run
        )
        var config = destinationConfig()
        config.xcodeprojPath = "/tmp/Example.xcworkspace"

        let readiness = await inspector.inspect(
            config: config,
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .ready)
        #expect(invocation.arguments?.prefix(2) == [
            "-workspace", "/tmp/Example.xcworkspace"
        ])
        #expect(invocation.arguments?.contains("-project") == false)
    }

    @Test
    func deviceIDMustMatchACompleteFieldRatherThanAPrefix() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, arch:arm64, id:TARGET-ID-EXTRA, name:Wrong iPhone }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unavailable("Xcode 的可用目标中没有找到该 iPhone。"))
    }

    @Test
    func duplicateIdentifierInjectedThroughANameIsUnknown() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, arch:arm64, id:OTHER-ID, name:Other, id:TARGET-ID }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        guard case .unknown = readiness else {
            Issue.record("重复 id 字段不得被当成目标设备：\(readiness)")
            return
        }
    }

    @Test
    func matchingUnlockPreparationErrorRequiresUnlock() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone, error:Target iPhone may need to be unlocked to recover from previously reported preparation errors }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .requiresUnlock(
            "Target iPhone may need to be unlocked to recover from previously reported preparation errors"
        ))
    }

    @Test
    func matchingOtherDestinationErrorIsUnavailable() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone, error:Developer Mode is disabled }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unavailable("Developer Mode is disabled"))
    }

    @Test
    func anotherDevicesErrorDoesNotPolluteTheTarget() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, arch:arm64, id:OTHER, name:Other, error:Other may need to be unlocked to recover from previously reported preparation errors }
            { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .ready)
    }

    @Test
    func duplicateReadyAndErrorRecordsRemainBlocked() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone }
            { platform:iOS, arch:arm64, id:TARGET-ID, name:Target iPhone, error:Device is locked }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .requiresUnlock("Device is locked"))
    }

    @Test
    func errorFieldMayAppearBeforeOtherDestinationFields() async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            { platform:iOS, id:TARGET-ID, error:Device is locked, name:Target iPhone, arch:arm64 }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .requiresUnlock("Device is locked"))
    }

    @Test(arguments: [
        "{ platform:iOS, id:TARGET-ID, error:, name:Target iPhone }",
        "{ platform:iOS, id:TARGET-ID, error:Device is locked, error:Developer Mode is disabled, name:Target iPhone }"
    ])
    func malformedErrorFieldsDoNotBecomeReady(record: String) async {
        let inspector = makeInspector(stdout: """
        Available destinations for the "Example" scheme:
            \(record)
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        guard case .unknown = readiness else {
            Issue.record("畸形 error 字段必须 fail closed，实际为：\(readiness)")
            return
        }
    }

    @Test(arguments: [
        CommandResult(
            standardOutput: """
            Available destinations:
                { platform:iOS, id:TARGET-ID, name:Target }
            """,
            standardError: "xcodebuild failed",
            terminationStatus: 65
        ),
        CommandResult(
            standardOutput: "",
            standardError: "Command timed out after 8.0 seconds.",
            terminationStatus: 124
        ),
        CommandResult(
            standardOutput: "",
            standardError: "Command cancelled.",
            terminationStatus: 130
        )
    ])
    func unsuccessfulCommandIsUnknownEvenWhenOutputContainsAReadyRecord(
        result: CommandResult
    ) async {
        let inspector = makeInspector(result: result)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        guard case .unknown = readiness else {
            Issue.record("命令失败、超时或取消不得产生确定 readiness：\(readiness)")
            return
        }
    }

    @Test
    func thrownCancellationIsUnknownAndDoesNotInventReadiness() async {
        let inspector = XcodeDestinationReadinessInspector { _, _, _ in
            throw CancellationError()
        }

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unknown("目标设备准备检查已取消。"))
    }

    @Test
    func truncatedOutputIsUnknown() async {
        let inspector = makeInspector(result: CommandResult(
            standardOutput: """
            Available destinations:
                { platform:iOS, id:TARGET-ID, name:Target }
            """,
            standardError: "",
            terminationStatus: 0,
            standardOutputWasTruncated: true
        ))

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unknown("Xcode destination 输出不完整，无法安全判断设备状态。"))
    }

    @Test
    func successfulExitWithUnconfirmedOwnedProcessesIsUnknown() async {
        let inspector = makeInspector(result: CommandResult(
            standardOutput: """
            Available destinations:
                { platform:iOS, id:TARGET-ID, name:Target }
            """,
            standardError: "",
            terminationStatus: 0,
            processGroupTerminationWasConfirmed: false
        ))

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(
            readiness
                == .unknown(
                    """
                    Xcode destination 检查失败：Available destinations:
                        { platform:iOS, id:TARGET-ID, name:Target }
                    """
                )
        )
    }

    @Test(arguments: ["", "unrelated diagnostic", "{ malformed"])
    func emptyOrMalformedSuccessfulOutputIsUnknown(stdout: String) async {
        let readiness = await makeInspector(stdout: stdout).inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unknown("Xcode 未返回可识别的 destination 列表。"))
    }

    @Test
    func oversizedSemanticOutputIsUnknown() async {
        let inspector = makeInspector(stdout: """
        Available destinations:
        \(String(repeating: "x", count: 1_048_577))
            { platform:iOS, id:TARGET-ID, name:Target }
        """)

        let readiness = await inspector.inspect(
            config: destinationConfig(),
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unknown("Xcode destination 输出过大，无法安全判断设备状态。"))
    }

    @Test
    func incompleteConfigurationIsUnknownWithoutLaunchingCommand() async {
        let invocation = DestinationInvocationRecorder(result: destinationSuccess(stdout: ""))
        let inspector = XcodeDestinationReadinessInspector(runCommand: invocation.run)

        let readiness = await inspector.inspect(
            config: .default,
            deviceID: "TARGET-ID"
        )

        #expect(readiness == .unknown("App 目标配置不完整，无法检查 destination。"))
        #expect(invocation.launchPath == nil)
    }
}

private final class DestinationInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: CommandResult
    private(set) var launchPath: String?
    private(set) var arguments: [String]?
    private(set) var timeoutSeconds: TimeInterval?

    init(result: CommandResult) {
        self.result = result
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        lock.withLock {
            self.launchPath = launchPath
            self.arguments = arguments
            self.timeoutSeconds = timeoutSeconds
        }
        return result
    }
}

private func destinationConfig() -> AppConfig {
    AppConfig(
        projectRootPath: "/tmp",
        deployScriptPath: "/tmp/deploy.command",
        xcodeprojPath: "/tmp/Example.xcodeproj",
        scheme: "Example",
        targetName: "Example",
        bundleID: "com.example.app",
        preferredDeviceID: "TARGET-ID",
        preferredDeviceName: "Target iPhone",
        checkIntervalMinutes: 5,
        reminderCooldownHours: 24,
        startAtLogin: false,
        autoRefreshPolicy: .autoRefreshWhenExpired
    )
}

private func makeInspector(
    stdout: String,
    stderr: String = "",
    status: Int32 = 0
) -> XcodeDestinationReadinessInspector {
    makeInspector(result: CommandResult(
        standardOutput: stdout,
        standardError: stderr,
        terminationStatus: status
    ))
}

private func makeInspector(
    result: CommandResult
) -> XcodeDestinationReadinessInspector {
    XcodeDestinationReadinessInspector { _, _, _ in result }
}

private func destinationSuccess(
    stdout: String = "",
    stderr: String = ""
) -> CommandResult {
    CommandResult(
        standardOutput: stdout,
        standardError: stderr,
        terminationStatus: 0
    )
}
