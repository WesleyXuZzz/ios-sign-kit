import Testing
@testable import IOSSignKit

struct HistoryEntryPresentationTests {
    @Test
    func failureUsesFriendlyReasonAndKeepsRawErrorAsSubtitle() {
        let entry = makeEntry(
            outcome: .failure,
            failureReason: .devicePreparationRequired,
            summary: "Xcode 无法准备目标 iPhone。",
            detailSummary: "xcodebuild: error: Timed out waiting for all destinations\n后续诊断"
        )

        let presentation = HistoryEntryPresentation.make(entry: entry)

        #expect(presentation.title == "续签失败 · 设备准备超时")
        #expect(
            presentation.subtitle
                == "xcodebuild: error: Timed out waiting for all destinations"
        )
    }

    @Test
    func successDistinguishesAutomaticRenewalFromManualTrigger() {
        let automatic = HistoryEntryPresentation.make(
            entry: makeEntry(
                outcome: .success,
                trigger: .automatic,
                summary: "续签成功",
                detailSummary: nil
            )
        )
        let manual = HistoryEntryPresentation.make(
            entry: makeEntry(
                outcome: .success,
                trigger: .manual,
                summary: "续签成功",
                detailSummary: nil
            )
        )

        #expect(automatic.title == "续签成功 · 自动续期")
        #expect(manual.title == "续签成功 · 手动触发")
    }

    @Test
    func cancelledResultUsesUnifiedUserFacingTerm() {
        let presentation = HistoryEntryPresentation.make(
            entry: makeEntry(
                outcome: .cancelled,
                summary: "已取消",
                detailSummary: nil
            )
        )

        #expect(presentation.title == "已取消 · 用户停止")
    }

    private func makeEntry(
        outcome: RefreshHistoryOutcome,
        trigger: RefreshHistoryTrigger? = nil,
        failureReason: DeployFailureReason? = nil,
        summary: String,
        detailSummary: String?
    ) -> RefreshHistoryEntry {
        RefreshHistoryEntry(
            id: "history-entry",
            startedAt: nil,
            outcome: outcome,
            trigger: trigger,
            failureReason: failureReason,
            summary: summary,
            detailSummary: detailSummary,
            logExcerpt: nil,
            logPath: "/tmp/history-entry.log",
            rawFilename: "history-entry.log"
        )
    }
}
