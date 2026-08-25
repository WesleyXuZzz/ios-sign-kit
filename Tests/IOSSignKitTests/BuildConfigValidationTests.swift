import Foundation
import Testing

struct BuildConfigValidationTests {
    @Test
    func releaseMetadataMatchesPackageAndOfficialIdentity() throws {
        let metadata = try releaseMetadata()
        #expect(metadata.appDisplayName == "iOSSignKit")
        #expect(metadata.executableName == "IOSSignKit")
        #expect(metadata.bundleIdentifier == "com.xuzw.iossignkit")
        #expect(
            metadata.marketingVersion.split(separator: ".").count == 3
        )
        #expect(Int(metadata.buildVersion).map { $0 > 0 } == true)
        #expect(metadata.minimumMacOSVersion == "14.0")

        let package = try String(
            contentsOf: testRepositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(package.contains(".macOS(.v14)"))
    }

    @Test
    func validatesReleaseMetadataAndRejectsMissingFile() throws {
        let valid = try runMetadataValidator(
            testRepositoryRoot.appendingPathComponent("config/release-metadata.json")
        )
        #expect(valid.status == 0)

        let missing = try runMetadataValidator(
            testRepositoryRoot.appendingPathComponent("config/missing-release-metadata.json")
        )
        #expect(missing.status != 0)
        #expect(missing.standardError.contains("Invalid release metadata"))
    }

    @Test
    func releaseMetadataRequiresSemanticMarketingVersionAndIntegerBuild() throws {
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-invalid-release-metadata-\(UUID().uuidString).json"
            )
        defer { try? FileManager.default.removeItem(at: metadataURL) }

        let invalidVersions = [
            (marketingVersion: "1.0", buildVersion: "1"),
            (marketingVersion: "1.0.0-beta", buildVersion: "1"),
            (marketingVersion: "1.0.0", buildVersion: "0"),
            (marketingVersion: "1.0.0", buildVersion: "1.2"),
        ]

        for version in invalidVersions {
            let metadata: [String: String] = [
                "appDisplayName": "iOSSignKit",
                "executableName": "IOSSignKit",
                "bundleIdentifier": "com.xuzw.iossignkit",
                "marketingVersion": version.marketingVersion,
                "buildVersion": version.buildVersion,
                "minimumMacOSVersion": "14.0",
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata)
            try data.write(to: metadataURL)

            let result = try runMetadataValidator(metadataURL)

            #expect(result.status != 0)
            #expect(result.standardError.contains("Invalid release metadata"))
        }
    }

    @Test
    func releaseBuildRejectsBundleIdentityOverridesBeforeBuilding() throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            testRepositoryRoot.appendingPathComponent("scripts/build-app.sh").path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["BUNDLE_IDENTIFIER"] = "com.example.override"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let standardError = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus != 0)
        #expect(standardError.contains("environment overrides are not allowed"))
        #expect(!standardError.contains("Building release binary"))
    }

    @Test
    func buildScriptSupportsExplicitCodeSigningIdentity() throws {
        let script = try String(
            contentsOf: testRepositoryRoot
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(
            script.contains(
                "IOS_SIGN_KIT_CODE_SIGN_IDENTITY=\"${IOS_SIGN_KIT_CODE_SIGN_IDENTITY:--}\""
            )
        )
        #expect(
            script.contains(
                "codesign --force --sign \"$IOS_SIGN_KIT_CODE_SIGN_IDENTITY\""
            )
        )
    }

    @Test
    func releaseBuildDefaultsToParallelFileCompilationAndSizeOptimization() throws {
        let script = try String(
            contentsOf: testRepositoryRoot
                .appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(
            script.contains(
                """
                  SWIFT_BUILD_EXTRA_OPTIONS=(
                    "-Xswiftc"
                    "-Osize"
                    "-Xswiftc"
                    "-no-whole-module-optimization"
                """
            )
        )
    }

    @Test
    func acceptsValidCustomBundleValues() throws {
        let result = try runValidator(
            bundleIdentifier: "com.example.ios-sign-kit",
            bundleVersion: "12.3.4"
        )

        #expect(result.status == 0)
        #expect(result.standardError.isEmpty)
    }

    @Test
    func rejectsValuesThatCouldCorruptInfoPlist() throws {
        let invalidCases = [
            ("bad&value", "1"),
            ("com.example..app", "1"),
            ("com.example.app", "1&2"),
            ("com.example.app", "1.2.3.4"),
            ("", "1")
        ]

        for (bundleIdentifier, bundleVersion) in invalidCases {
            let result = try runValidator(
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion
            )
            #expect(result.status != 0)
            #expect(result.standardError.contains("Invalid"))
        }
    }

    private func runValidator(
        bundleIdentifier: String,
        bundleVersion: String
    ) throws -> (status: Int32, standardError: String) {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            testRepositoryRoot.appendingPathComponent("scripts/validate-build-config.sh").path,
            bundleIdentifier,
            bundleVersion
        ]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: errorData, as: UTF8.self)
        )
    }

    private func releaseMetadata() throws -> ReleaseMetadataFixture {
        let data = try Data(
            contentsOf: testRepositoryRoot
                .appendingPathComponent("config/release-metadata.json")
        )
        return try JSONDecoder().decode(ReleaseMetadataFixture.self, from: data)
    }

    private func runMetadataValidator(
        _ metadataURL: URL
    ) throws -> (status: Int32, standardError: String) {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            testRepositoryRoot
                .appendingPathComponent("scripts/validate-release-metadata.sh")
                .path,
            metadataURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

private struct ReleaseMetadataFixture: Decodable {
    let appDisplayName: String
    let executableName: String
    let bundleIdentifier: String
    let marketingVersion: String
    let buildVersion: String
    let minimumMacOSVersion: String
}
