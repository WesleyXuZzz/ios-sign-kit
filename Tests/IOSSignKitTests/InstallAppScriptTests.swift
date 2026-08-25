import Foundation
import Testing

struct InstallAppScriptTests {
    @Test
    func installsPackagedAppWhenNoPreviousInstallationExists() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceApp = fixture.dist.appendingPathComponent("InstallFixture.app")
        try createApp(at: sourceApp, marker: "new")

        let result = try runInstaller(fixture: fixture)
        let installedApp = fixture.applications
            .appendingPathComponent("InstallFixture.app")

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("Installed app:"))
        #expect(!FileManager.default.fileExists(atPath: sourceApp.path))
        #expect(try marker(in: installedApp) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    @Test
    func replacesMatchingInstallationAndMovesPreviousAppToTrash() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceApp = fixture.dist.appendingPathComponent("InstallFixture.app")
        let installedApp = fixture.applications
            .appendingPathComponent("InstallFixture.app")
        try createApp(at: sourceApp, marker: "new")
        try createApp(at: installedApp, marker: "old")

        let result = try runInstaller(fixture: fixture)
        let trashEntries = try FileManager.default.contentsOfDirectory(
            at: fixture.trash,
            includingPropertiesForKeys: nil
        )

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(try marker(in: installedApp) == "new")
        #expect(!FileManager.default.fileExists(atPath: sourceApp.path))
        #expect(trashEntries.count == 1)
        #expect(trashEntries.first?.lastPathComponent.hasPrefix("InstallFixture-previous-") == true)
        if let previousApp = trashEntries.first {
            #expect(try marker(in: previousApp) == "old")
        }
    }

    @Test
    func dryRunValidatesWithoutMovingEitherApp() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceApp = fixture.dist.appendingPathComponent("InstallFixture.app")
        let installedApp = fixture.applications
            .appendingPathComponent("InstallFixture.app")
        try createApp(at: sourceApp, marker: "new")
        try createApp(at: installedApp, marker: "old")

        let result = try runInstaller(fixture: fixture, arguments: ["--dry-run"])

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("Dry run completed"))
        #expect(try marker(in: sourceApp) == "new")
        #expect(try marker(in: installedApp) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    @Test
    func refusesToReplaceAnAppWithAnotherBundleIdentifier() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sourceApp = fixture.dist.appendingPathComponent("InstallFixture.app")
        let installedApp = fixture.applications
            .appendingPathComponent("InstallFixture.app")
        try createApp(at: sourceApp, marker: "new")
        try createApp(
            at: installedApp,
            marker: "unrelated",
            bundleIdentifier: "com.example.unrelated"
        )

        let result = try runInstaller(fixture: fixture)

        #expect(result.status != 0)
        #expect(result.standardError.contains("Refusing to replace an application with Bundle ID"))
        #expect(try marker(in: sourceApp) == "new")
        #expect(try marker(in: installedApp) == "unrelated")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    private func makeFixture() throws -> InstallerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-install-script-\(UUID().uuidString)",
                isDirectory: true
            )
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let config = root.appendingPathComponent("config", isDirectory: true)
        let dist = root.appendingPathComponent("dist", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)

        for directory in [scripts, config, dist, applications, trash] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        try FileManager.default.copyItem(
            at: testRepositoryRoot.appendingPathComponent("scripts/install-app.sh"),
            to: scripts.appendingPathComponent("install-app.sh")
        )
        try FileManager.default.copyItem(
            at: testRepositoryRoot.appendingPathComponent("scripts/validate-release-metadata.sh"),
            to: scripts.appendingPathComponent("validate-release-metadata.sh")
        )
        try FileManager.default.copyItem(
            at: testRepositoryRoot.appendingPathComponent("scripts/validate-build-config.sh"),
            to: scripts.appendingPathComponent("validate-build-config.sh")
        )

        let metadata: [String: Any] = [
            "appDisplayName": "InstallFixture",
            "executableName": "InstallFixture",
            "bundleIdentifier": "com.example.install-fixture",
            "marketingVersion": "1.0.0",
            "buildVersion": "1",
            "minimumMacOSVersion": "14.0",
        ]
        let metadataData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadataData.write(to: config.appendingPathComponent("release-metadata.json"))

        return InstallerFixture(
            root: root,
            dist: dist,
            applications: applications,
            trash: trash
        )
    }

    private func createApp(
        at appURL: URL,
        marker: String,
        bundleIdentifier: String = "com.example.install-fixture"
    ) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        for directory in [executables, resources] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "InstallFixture",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "InstallFixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: resources.appendingPathComponent("marker.txt"))

        let executable = executables.appendingPathComponent("InstallFixture")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: executable
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let signingResult = try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", appURL.path]
        )
        guard signingResult.status == 0 else {
            throw InstallerTestError.commandFailed(signingResult.standardError)
        }
    }

    private func marker(in appURL: URL) throws -> String {
        try String(
            contentsOf: appURL.appendingPathComponent("Contents/Resources/marker.txt"),
            encoding: .utf8
        )
    }

    private func runInstaller(
        fixture: InstallerFixture,
        arguments: [String] = []
    ) throws -> ProcessResult {
        var environment = ProcessInfo.processInfo.environment
        environment["IOS_SIGN_KIT_APPLICATIONS_DIRECTORY"] = fixture.applications.path
        environment["IOS_SIGN_KIT_TRASH_DIRECTORY"] = fixture.trash.path

        return try runProcess(
            executable: "/bin/zsh",
            arguments: [
                fixture.root.appendingPathComponent("scripts/install-app.sh").path
            ] + arguments,
            environment: environment
        )
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private struct InstallerFixture {
    let root: URL
    let dist: URL
    let applications: URL
    let trash: URL
}

private struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private enum InstallerTestError: Error {
    case commandFailed(String)
}
