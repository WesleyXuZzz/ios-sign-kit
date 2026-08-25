import Foundation
import Testing
@testable import IOSSignKit

struct DeviceAppInspectorTests {
    @Test
    func metadataSourcePathsIncludeDisplayNameBundleNameAndAppBundleName() {
        let paths = DeviceAppInspector.installMetadataSourcePaths(
            appName: "示例应用",
            bundleID: "com.example.SampleApp",
            appURL: "file:///private/var/containers/Bundle/Application/UUID/SampleApp.app/"
        )

        #expect(paths == [
            "Library/Application Support/示例应用/install-metadata.json",
            "Library/Application Support/SampleApp/install-metadata.json",
            "Library/Application Support/App/install-metadata.json"
        ])
    }

    @Test
    func metadataSourcePathsSanitizeAndDeduplicateNames() {
        let paths = DeviceAppInspector.installMetadataSourcePaths(
            appName: "Sample/App",
            bundleID: "com.example.Sample-App",
            appURL: "file:///tmp/Sample-App.app"
        )

        #expect(paths == [
            "Library/Application Support/Sample-App/install-metadata.json",
            "Library/Application Support/App/install-metadata.json"
        ])
    }

    @Test
    func retriesTransientCommandFailureAndBoundsEveryCommand() async throws {
        let runner = ScriptedAppInspectorRunner(responses: [
            .init(result: .failure(stderr: "CoreDevice unavailable")),
            .init(result: .success(), json: installedAppsJSON())
        ])
        let inspector = DeviceAppInspector(runCommand: runner.run)
        let device = DeviceInfo(
            id: "iphone-1",
            name: "Example iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "18.5",
            isAvailable: true,
            isPaired: true
        )

        let app = try await inspector.inspectInstalledApp(
            device: device,
            bundleID: "com.example.App",
            retryCount: 2,
            retryDelaySeconds: 0,
            commandTimeoutSeconds: 3
        )

        #expect(app?.bundleIdentifier == "com.example.App")
        let infoCalls = runner.invocations.filter { $0.arguments.starts(with: ["devicectl", "device", "info", "apps"]) }
        #expect(infoCalls.count == 2)
        #expect(infoCalls.allSatisfy { $0.arguments.contains("--timeout") })
        #expect(infoCalls.allSatisfy { $0.timeoutSeconds == 4 })
        #expect(runner.invocations.allSatisfy { $0.timeoutSeconds == 4 })
        #expect(runner.temporaryPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    @Test
    func rejectsMetadataThatDoesNotDescribeCurrentInstallation() {
        let now = Date()
        let valid = AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: now,
            bundleIdentifier: "com.example.App",
            shortVersion: "1.0",
            buildVersion: "1",
            expectedExpiryAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            profileSource: "embedded_mobileprovision"
        )

        #expect(InstallMetadataValidator.validationFailure(
            valid,
            requestedBundleID: "com.example.App",
            installedBundleID: "com.example.App",
            installedVersion: "1.0",
            installedBuildVersion: "1",
            now: now
        ) == nil)

        var wrongBundle = valid
        wrongBundle.bundleIdentifier = "com.example.Other"
        #expect(InstallMetadataValidator.validationFailure(
            wrongBundle,
            requestedBundleID: "com.example.App",
            installedBundleID: "com.example.App",
            installedVersion: "1.0",
            installedBuildVersion: "1",
            now: now
        ) != nil)

        var wrongVersion = valid
        wrongVersion.buildVersion = "2"
        #expect(InstallMetadataValidator.validationFailure(
            wrongVersion,
            requestedBundleID: "com.example.App",
            installedBundleID: "com.example.App",
            installedVersion: "1.0",
            installedBuildVersion: "1",
            now: now
        ) != nil)

        var unsupported = valid
        unsupported.schemaVersion = 99
        #expect(InstallMetadataValidator.validationFailure(
            unsupported,
            requestedBundleID: "com.example.App",
            installedBundleID: "com.example.App",
            installedVersion: "1.0",
            installedBuildVersion: "1",
            now: now
        ) != nil)
    }

    @Test
    func rejectsImplausibleMetadataDates() {
        let now = Date()
        let future = AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: now.addingTimeInterval(10 * 60),
            bundleIdentifier: "com.example.App",
            shortVersion: "1.0",
            buildVersion: "1",
            expectedExpiryAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            profileSource: "embedded_mobileprovision"
        )
        #expect(InstallMetadataValidator.validationFailure(
            future,
            requestedBundleID: "com.example.App",
            installedBundleID: "com.example.App",
            installedVersion: "1.0",
            installedBuildVersion: "1",
            now: now
        ) != nil)

        var excessiveLifetime = future
        excessiveLifetime.recordedAt = now
        excessiveLifetime.expectedExpiryAt = now.addingTimeInterval(9 * 24 * 60 * 60)
        #expect(InstallMetadataValidator.validationFailure(
            excessiveLifetime,
            requestedBundleID: "com.example.App",
            installedBundleID: "com.example.App",
            installedVersion: "1.0",
            installedBuildVersion: "1",
            now: now
        ) != nil)
    }
}

private final class ScriptedAppInspectorRunner: @unchecked Sendable {
    struct Invocation: Sendable {
        let arguments: [String]
        let timeoutSeconds: TimeInterval?
    }

    struct Response: Sendable {
        let result: CommandResult
        let json: String?

        init(result: CommandResult, json: String? = nil) {
            self.result = result
            self.json = json
        }
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var invocations: [Invocation] = []
    private(set) var temporaryPaths: [String] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(_ launchPath: String, _ arguments: [String], _ timeoutSeconds: TimeInterval?) throws -> CommandResult {
        let response: Response
        lock.lock()
        invocations.append(Invocation(arguments: arguments, timeoutSeconds: timeoutSeconds))
        response = responses.isEmpty
            ? Response(result: .failure(stderr: "metadata unavailable"))
            : responses.removeFirst()
        let outputPath = path(after: "--json-output", in: arguments)
        let destinationPath = path(after: "--destination", in: arguments)
        temporaryPaths.append(contentsOf: [outputPath, destinationPath].compactMap { $0 })
        lock.unlock()

        if let json = response.json, let outputPath {
            try json.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        return response.result
    }

    private func path(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
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

private func installedAppsJSON() -> String {
    """
    {
      "result": {
        "apps": [{
          "bundleIdentifier": "com.example.App",
          "bundleVersion": "1",
          "name": "Example App",
          "url": "file:///private/var/containers/Bundle/Application/UUID/Example.app/",
          "version": "1.0",
          "builtByDeveloper": true
        }]
      }
    }
    """
}
