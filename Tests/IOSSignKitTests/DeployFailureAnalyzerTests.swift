import Foundation
import Testing
@testable import IOSSignKit

struct DeployFailureAnalyzerTests {
    @Test
    func recognizesCapturedDestinationPreparationFailureFromStandardOutput() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 70,
            standardOutput: capturedDestinationPreparationFailure,
            standardError: ""
        )

        #expect(analysis.reason == .devicePreparationRequired)
        #expect(
            analysis.summary
                == "Xcode 无法准备目标 iPhone；请解锁设备，等待 Xcode 完成设备准备后重试。"
        )
    }

    @Test
    func recognizesStructuredMarkerForCompatibleDeployScripts() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 70,
            standardOutput: """
            build failed
            IOS_SIGN_KIT_FAILURE_REASON=device_preparation_required
            """,
            standardError: ""
        )

        #expect(analysis.reason == .devicePreparationRequired)
    }

    @Test
    func exitStatusSeventyWithoutBothRequiredDiagnosticsRemainsGeneric() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 70,
            standardOutput: """
            xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
            """,
            standardError: ""
        )

        #expect(analysis.reason == .generic)
        #expect(
            analysis.summary
                == "xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available"
        )
    }

    @Test
    func actionableErrorBeatsPreambleWhenStandardErrorIsEmpty() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 65,
            standardOutput: """
            [03:06:02] 环境检查
              仓库目录: /example
            xcodebuild: error: Scheme Example is not currently configured for the build action.
            """,
            standardError: ""
        )

        #expect(analysis.reason == .generic)
        #expect(
            analysis.summary
                == "xcodebuild: error: Scheme Example is not currently configured for the build action."
        )
    }

    @Test
    func anotherDevicesPreparationErrorCannotTriggerTargetRecovery() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 70,
            standardOutput: """
            xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
            Available destinations:
                { platform:iOS, id:OTHER-ID, name:Other, error:Other may need to be unlocked to recover from previously reported preparation errors }
                { platform:iOS, id:TARGET-ID, name:Target }
            """,
            standardError: "",
            targetDeviceID: "TARGET-ID"
        )

        #expect(analysis.reason == .generic)
    }

    @Test
    func duplicateIdentifierCannotBindAnotherDevicesErrorToTarget() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 70,
            standardOutput: """
            xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
            Available destinations:
                { platform:iOS, id:OTHER-ID, name:Other, id:TARGET-ID, error:Other may need to be unlocked to recover from previously reported preparation errors }
            """,
            standardError: "",
            targetDeviceID: "TARGET-ID"
        )

        #expect(analysis.reason == .generic)
    }

    @Test
    func legacyOutputWithoutTargetIdentityMustBeUnambiguous() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 70,
            standardOutput: """
            xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
            Available destinations:
                { platform:iOS, id:OTHER-ID, name:Other, error:Other may need to be unlocked to recover from previously reported preparation errors }
                { platform:iOS, id:TARGET-ID, name:Target }
            """,
            standardError: ""
        )

        #expect(analysis.reason == .generic)
    }

    @Test
    func actionableStandardErrorTakesPriorityOverStandardOutput() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 65,
            standardOutput: "xcodebuild: error: destination unavailable",
            standardError: "Signing failed for the selected profile"
        )

        #expect(analysis.reason == .generic)
        #expect(analysis.summary == "Signing failed for the selected profile")
    }

    @Test
    func xcodebuildErrorBeatsGenericExitCodeWrapper() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 64,
            standardOutput:
                "xcodebuild: error: Found no destinations for the scheme 'Example'.",
            standardError:
                "错误: 无法校验 ios-sign-kit 指定的 Xcode 工程，xcodebuild 退出码: 64。"
        )

        #expect(analysis.reason == .generic)
        #expect(
            analysis.summary
                == "xcodebuild: error: Found no destinations for the scheme 'Example'."
        )
    }

    @Test
    func emptyOutputUsesBuiltInRenewalFailureSummary() {
        let analysis = DeployFailureAnalyzer().analyze(
            exitStatus: 1,
            standardOutput: "",
            standardError: ""
        )

        #expect(analysis.reason == .generic)
        #expect(analysis.summary == "续签流程执行失败。")
    }
}

private let capturedDestinationPreparationFailure = """
[03:06:02] 环境检查
  仓库目录: /example
  设备筛选: Example iPhone

[03:06:08] 开始编译 iOS 真机包
xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available

Available destinations for the "ExampleApp" scheme:
    { platform:iOS, arch:arm64, id:EXAMPLE-DEVICE-ID, name:Example iPhone, error:Example iPhone may need to be unlocked to recover from previously reported preparation errors }
"""
