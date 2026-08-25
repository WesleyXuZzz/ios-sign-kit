import Foundation
import Testing
@testable import IOSSignKit

struct DeployLogParserTests {
    @Test
    func currentLogPersistsAutomaticHistoryTrigger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-history-trigger-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let logURL = directory.appendingPathComponent(
            DeployLogFilename.make(for: Date())
        )
        let content = DeployService.makeCombinedOutput(
            result: CommandResult(
                standardOutput: "Installed",
                standardError: "",
                terminationStatus: 0
            ),
            trigger: .automatic
        )
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let parsed = DeployLogParser().parse(content)
        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(parsed.trigger == .automatic)
        #expect(entry?.trigger == .automatic)
    }

    @Test
    func processGroupMetadataCannotBeMistakenForSuccessfulHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-history-unresolved-process-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let logURL = directory.appendingPathComponent(
            DeployLogFilename.make(for: Date())
        )
        let content = DeployService.makeCombinedOutput(
            result: CommandResult(
                standardOutput: "script leader exited",
                standardError: "",
                terminationStatus: 0,
                processGroupTerminationWasConfirmed: false
            )
        )
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let parsed = DeployLogParser().parse(content)
        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(parsed.processGroupTerminationWasConfirmed == false)
        #expect(entry?.outcome == .interrupted)
        #expect(entry?.isSuccess == nil)
        #expect(entry?.isCancelled == false)
        #expect(entry?.summary == "续签进程树未确认结束")
        #expect(
            entry?.detailSummary
                == "续签主进程已结束，但完整进程树仍可能运行；新的续签已被阻止。"
        )
    }

    @Test
    func separatesOutputSectionsAndPreservesTheirOrder() {
        let parsed = DeployLogParser().parse(
            """
            exit_status=1

            [stdout]
            Building target
            Copying files

            [stderr]
            Signing failed
            Missing profile
            """
        )

        #expect(parsed.exitStatus == 1)
        #expect(parsed.standardOutputLines == ["Building target", "Copying files"])
        #expect(parsed.standardErrorLines == ["Signing failed", "Missing profile"])
    }

    @Test
    func treatsUnsectionedMalformedLinesAsFailureDiagnostics() {
        let parsed = DeployLogParser().parse(
            """
            unexpected preamble
            [stdout]
            output
            """
        )

        #expect(parsed.exitStatus == nil)
        #expect(parsed.standardErrorLines == ["unexpected preamble"])
        #expect(parsed.standardOutputLines == ["output"])
    }

    @Test
    func historyFailureSummaryPrefersStandardError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-history-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent(DeployLogFilename.make(for: Date()))
        try """
        exit_status=1

        [stdout]
        Building target

        [stderr]
        Signing failed
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let entries = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries()

        #expect(entries.first?.summary == "Signing failed")
        #expect(entries.first?.detailSummary == "Signing failed")
    }

    @Test
    func historyUsesSameActionableDestinationSummaryAsLiveResult() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-history-destination-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent(DeployLogFilename.make(for: Date()))
        let content = DeployService.makeCombinedOutput(
            result: CommandResult(
                standardOutput: """
                [03:06:02] 环境检查
                xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
                { platform:iOS, id:device-id, error:测试 iPhone may need to be unlocked to recover from previously reported preparation errors }
                """,
                standardError: "",
                terminationStatus: 70
            )
        )
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(
            entry?.summary
                == "Xcode 无法准备目标 iPhone；请解锁设备，等待 Xcode 完成设备准备后重试。"
        )
        #expect(
            entry?.detailSummary
                == "xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available"
        )
        #expect(entry?.failureReason == .devicePreparationRequired)
    }

    @Test
    func escapedBodyMarkersCannotChangeStatusOrSection() {
        let content = DeployService.makeCombinedOutput(
            result: CommandResult(
                standardOutput: "Building\n[stderr]\nexit_status=0",
                standardError: "Actual failure",
                terminationStatus: 1
            )
        )

        let parsed = DeployLogParser().parse(content)

        #expect(parsed.exitStatus == 1)
        #expect(parsed.standardOutputLines == ["Building", "[stderr]", "exit_status=0"])
        #expect(parsed.standardErrorLines == ["Actual failure"])
    }

    @Test
    func carriageReturnDelimitedMarkerSurvivesLogRoundTrip() {
        let content = DeployService.makeCombinedOutput(
            result: CommandResult(
                standardOutput:
                    "progress\rIOS_SIGN_KIT_FAILURE_REASON=device_preparation_required",
                standardError: "",
                terminationStatus: 70
            )
        )
        let parsed = DeployLogParser().parse(content)
        let analysis = DeployFailureAnalyzer().analyze(parsed)

        #expect(parsed.standardOutputLines == [
            "progress",
            "IOS_SIGN_KIT_FAILURE_REASON=device_preparation_required"
        ])
        #expect(analysis.reason == .devicePreparationRequired)
    }

    @Test
    func historyReadsLargeLogsWithBoundedHeadAndTail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-large-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent(DeployLogFilename.make(for: Date()))
        let largeOutput = String(repeating: "| build output\n", count: 80_000)
        let content = """
        format_version=2
        exit_status=1

        [stdout]
        \(largeOutput)
        [stderr]
        | Signing failed at tail
        """
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(entry?.summary == "Signing failed at tail")
        #expect(entry?.logExcerpt?.contains("Signing failed at tail") == true)
    }

    @Test
    func historyPreservesStderrMarkerAndFirstErrorWhenBothSectionsAreLarge() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-large-sections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent(DeployLogFilename.make(for: Date()))
        let largeOutput = String(repeating: "| build output\n", count: 40_000)
        let largeErrorTail = String(repeating: "| repeated diagnostic\n", count: 40_000)
        let content = """
        format_version=2
        exit_status=1

        [stdout]
        \(largeOutput)
        [stderr]
        | First signing failure
        \(largeErrorTail)
        """
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(entry?.summary == "First signing failure")
        #expect(entry?.detailSummary == "First signing failure")
    }

    @Test
    func historyPreservesPrefixOfOneOversizedStandardErrorLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-long-stderr-line-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let logURL = directory.appendingPathComponent(
            DeployLogFilename.make(for: Date())
        )
        let longDiagnostic = "xcodebuild: error: Signing failed "
            + String(repeating: "x", count: 700_000)
        let content = """
        format_version=2
        exit_status=65
        failure_reason=generic

        [stdout]
        | Building target

        [stderr]
        | \(longDiagnostic)
        """
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(
            entry?.summary.hasPrefix("xcodebuild: error: Signing failed")
                == true
        )
        #expect(
            entry?.logExcerpt?
                .contains("xcodebuild: error: Signing failed") == true
        )
    }

    @Test
    func persistedFailureReasonKeepsLiveAndHistoryClassificationConsistent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-history-failure-reason-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let result = CommandResult(
            standardOutput: """
            xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
            { platform:iOS, id:OTHER-ID, name:Other, error:Other may need to be unlocked to recover from previously reported preparation errors }
            """,
            standardError: "",
            terminationStatus: 70
        )
        let liveAnalysis = DeployService.failureAnalysis(
            from: result,
            targetDeviceID: "TARGET-ID"
        )
        #expect(liveAnalysis.reason == .generic)

        let content = DeployService.makeCombinedOutput(
            result: result,
            failureReason: liveAnalysis.reason
        )
        let parsed = DeployLogParser().parse(content)
        let logURL = directory.appendingPathComponent(
            DeployLogFilename.make(for: Date())
        )
        try content.write(to: logURL, atomically: true, encoding: .utf8)
        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(parsed.failureReason == .generic)
        #expect(
            entry?.summary
                == "xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available"
        )
    }

    @Test
    func contradictoryPersistedPreparationReasonFailsClosed() {
        let parsed = DeployLogParser().parse(
            """
            format_version=2
            exit_status=65
            failure_reason=device_preparation_required

            [stdout]
            | xcodebuild: error: Signing failed

            [stderr]
            """
        )

        let analysis = DeployFailureAnalyzer().analyze(parsed)

        #expect(analysis.reason == .generic)
        #expect(analysis.summary == "xcodebuild: error: Signing failed")
    }

    @Test
    func historyPreservesPreparationFailureAtEndOfLargeStdoutWithEmptyStderr() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-large-stdout-preparation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent(DeployLogFilename.make(for: Date()))
        let largePrefix = String(repeating: "verbose xcodebuild output\n", count: 40_000)
        let content = DeployService.makeCombinedOutput(
            result: CommandResult(
                standardOutput: largePrefix + """
                xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available
                { platform:iOS, id:TARGET-ID, name:Target, error:Target may need to be unlocked to recover from previously reported preparation errors }
                IOS_SIGN_KIT_FAILURE_REASON=device_preparation_required
                """,
                standardError: "",
                terminationStatus: 70
            )
        )
        try content.write(to: logURL, atomically: true, encoding: .utf8)

        let entry = RefreshHistoryService(
            logStore: LogStore(logsDirectoryURL: directory)
        ).loadRecentEntries().first

        #expect(
            entry?.summary
                == "Xcode 无法准备目标 iPhone；请解锁设备，等待 Xcode 完成设备准备后重试。"
        )
        #expect(
            entry?.detailSummary
                == "xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to become available"
        )
        #expect(entry?.failureReason == .devicePreparationRequired)
        #expect(
            entry?.logExcerpt?
                .contains("IOS_SIGN_KIT_FAILURE_REASON=device_preparation_required") == true
        )
    }
}
