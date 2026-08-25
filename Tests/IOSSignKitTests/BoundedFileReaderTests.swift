import Foundation
import Testing
@testable import IOSSignKit

struct BoundedFileReaderTests {
    @Test
    func readsFileAtLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-bounded-reader-\(UUID().uuidString)")
        let payload = Data(repeating: 0x61, count: 128)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try BoundedFileReader().data(at: url, maximumBytes: 128)

        #expect(result == payload)
    }

    @Test
    func rejectsFileBeyondLimitWithoutReadingItUnbounded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-bounded-reader-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: 129).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: BoundedFileReaderError.self) {
            try BoundedFileReader().data(at: url, maximumBytes: 128)
        }
    }

    @Test
    func oversizedPersistedStateIsReportedAsCorrupt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-oversized-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            repeating: 0x20,
            count: BoundedFileReader.persistedStateMaximumBytes + 1
        ).write(to: directory.appendingPathComponent("state.json"))

        let result = RefreshStateStore(appSupportDirectory: directory).loadStateResult()

        guard case .corrupt = result else {
            Issue.record("超出上限的状态文件必须被视为损坏，而不是无界解码。")
            return
        }
    }

    @Test
    func oversizedStateCannotBeWrittenThenAcceptedOnRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-oversized-state-write-\(UUID().uuidString)", isDirectory: true)
        let store = RefreshStateStore(appSupportDirectory: directory)
        var state = AppState.default
        state.lastDeviceScanFailure = String(
            repeating: "x",
            count: BoundedFileReader.persistedStateMaximumBytes + 1
        )

        #expect(throws: RefreshStateStoreError.self) {
            try store.saveState(state)
        }
        guard case .missing = store.loadStateResult() else {
            Issue.record("编码阶段拒绝的超限状态不得留下事务标记或状态文件。")
            return
        }
    }

    @Test
    func diagnosticTextHasAStorageSafeUpperBound() {
        let diagnostic = DiagnosticText.bounded(
            String(repeating: "错误", count: 10_000)
        )

        #expect(diagnostic.count == DiagnosticText.maximumCharacters + 1)
        #expect(diagnostic.hasSuffix("…"))
    }
}
