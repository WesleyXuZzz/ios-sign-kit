#if DEBUG
import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct VisualQAScenarioTests {
    @Test(arguments: VisualQAPhase.allCases)
    func mockScenariosRemainIsolatedAndExposeExpectedPresentation(_ phase: VisualQAPhase) async throws {
        let model = try VisualQAScenario.makeViewModel(phase: phase)
        #expect(model.config.projectRootPath?.hasPrefix(FileManager.default.temporaryDirectory.path) == true)
        #expect(model.config.bundleID == "dev.example.visualqa")
        #expect(!model.config.startAtLogin)
        #expect(model.state.activeDeploymentToken == nil)
        #expect(model.state.activeDeployProcessGroupID == nil)
        if phase != .offline {
            #expect(model.historyEntries.count == 4)
            #expect(model.matchedDevice?.id == model.config.preferredDeviceID)
            #expect(model.historyEntries.allSatisfy { $0.logPath.hasPrefix(FileManager.default.temporaryDirectory.path) })
        }
        let expected: OperationActivityKind? = switch phase {
        case .deploying: .deploying
        case .success: .success
        case .failure: .failure
        case .cancelled: .cancelled
        case .countdown: .countdown
        default: nil
        }
        if let expected { #expect(model.operationActivityPresentation.kind == expected) }
        let before = model.deployLogText
        VisualQAScenario.appendMockOutput(to: model, sequence: 77)
        #expect((model.deployLogText != before) == (phase == .deploying))
        await model.shutdown()
    }
}
#endif
