import Foundation
import Testing

struct WorkspaceSizeAuditTests {
    @Test
    func reportsKeyWorkspaceCategoriesWithoutExposingTheRootPath() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-workspace-audit-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try createDirectory(".build/debug", in: fixtureRoot)
        try createDirectory(".build/release", in: fixtureRoot)
        try createDirectory("dist/iOSSignKit-Debug.app", in: fixtureRoot)
        try createDirectory("dist/.iOSSignKit.staging.fixture", in: fixtureRoot)
        try createDirectory("runtime/design-qa", in: fixtureRoot)
        try Data(repeating: 0x41, count: 8_192).write(
            to: fixtureRoot.appendingPathComponent(".build/debug/cache.bin")
        )
        try Data(repeating: 0x42, count: 4_096).write(
            to: fixtureRoot.appendingPathComponent("runtime/design-qa/screenshot.png")
        )
        try initializeGitRepository(at: fixtureRoot)

        let result = try runAudit(root: fixtureRoot)

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("[项目总量]"))
        #expect(result.standardOutput.contains("[.build 关键层级]"))
        #expect(result.standardOutput.contains(".build/debug"))
        #expect(result.standardOutput.contains("[Git 对象]"))
        #expect(result.standardOutput.contains("git count-objects -vH"))
        #expect(result.standardOutput.contains("count:"))
        #expect(result.standardOutput.contains("size-pack:"))
        #expect(result.standardOutput.contains("[dist 关键遗留项]"))
        #expect(result.standardOutput.contains("未完成 staging 目录: 1 项"))
        #expect(result.standardOutput.contains("Debug App 产物: 1 项"))
        #expect(result.standardOutput.contains("[runtime 关键遗留项]"))
        #expect(result.standardOutput.contains("runtime/design-qa"))
        #expect(result.standardOutput.contains("只报告，不删除"))
        #expect(!result.standardOutput.contains(fixtureRoot.path))
    }

    private func createDirectory(
        _ relativePath: String,
        in root: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relativePath),
            withIntermediateDirectories: true
        )
    }

    private func initializeGitRepository(at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", root.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func runAudit(
        root: URL
    ) throws -> (status: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            testRepositoryRoot
                .appendingPathComponent("scripts/audit-workspace-size.sh")
                .path,
            "--root",
            root.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}
