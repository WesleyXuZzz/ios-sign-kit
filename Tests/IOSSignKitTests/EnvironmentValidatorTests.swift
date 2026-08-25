import Foundation
import Testing
@testable import IOSSignKit

struct EnvironmentValidatorTests {
    @Test
    func infersGenericIOSProjectDetails() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-tests-\(UUID().uuidString)", isDirectory: true)
        let deployScriptURL = rootURL.appendingPathComponent("scripts/deploy/ios-device.command")
        let appDirectoryURL = rootURL.appendingPathComponent("app/ios/ExampleApp/ExampleApp", isDirectory: true)
        let xcodeprojURL = rootURL.appendingPathComponent("app/ios/ExampleApp/ExampleApp.xcodeproj", isDirectory: true)
        let infoPlistURL = appDirectoryURL.appendingPathComponent("Info.plist")
        let projectFileURL = xcodeprojURL.appendingPathComponent("project.pbxproj")

        try FileManager.default.createDirectory(at: deployScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xcodeprojURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: deployScriptURL.path, contents: Data("#!/bin/zsh\n".utf8))
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        </dict>
        </plist>
        """.write(to: infoPlistURL, atomically: true, encoding: .utf8)
        try """
        PRODUCT_BUNDLE_IDENTIFIER = com.example.app;
        """.write(to: projectFileURL, atomically: true, encoding: .utf8)

        let validator = EnvironmentValidator()
        let inference = validator.inferProjectDetails(from: rootURL.path)

        #expect(inference.deployScriptPath == nil)
        #expect(inference.xcodeprojPath == nil)
        #expect(inference.scheme == nil)
        #expect(inference.bundleID == nil)
    }

    @Test
    func acceptsResolvedStandardProjectWithoutDeployScript() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-validator-standard-project-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent(
            "ExampleApp.xcodeproj",
            isDirectory: true
        )
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: toolsURL,
            withIntermediateDirectories: true
        )
        for command in ["xcodebuild", "xcrun"] {
            let commandURL = toolsURL.appendingPathComponent(command)
            try "#!/bin/zsh\nexit 0\n".write(
                to: commandURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: commandURL.path
            )
        }

        var config = AppConfig.default
        config.projectRootPath = rootURL.path
        config.xcodeprojPath = projectURL.path
        config.scheme = "ExampleApp"
        config.targetName = "ExampleApp"
        config.bundleID = "com.example.ExampleApp"

        let status = EnvironmentValidator(
            processEnvironment: ["PATH": toolsURL.path]
        ).validate(config: config)

        #expect(status.isProjectPathValid)
        #expect(status.isApplicationTargetResolved)
        #expect(status.areAllChecksPassing)
        #expect(status.summary == "环境检查通过，可以开始使用。")
    }

    @Test
    func acceptsResolvedStandardWorkspaceWithoutDeployScript() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-validator-standard-workspace-\(UUID().uuidString)",
                isDirectory: true
            )
        let workspaceURL = rootURL.appendingPathComponent(
            "ExampleApp.xcworkspace",
            isDirectory: true
        )
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: toolsURL,
            withIntermediateDirectories: true
        )
        for command in ["xcodebuild", "xcrun"] {
            let commandURL = toolsURL.appendingPathComponent(command)
            try "#!/bin/zsh\nexit 0\n".write(
                to: commandURL,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: commandURL.path
            )
        }

        var config = AppConfig.default
        config.projectRootPath = rootURL.path
        config.xcodeprojPath = workspaceURL.path
        config.scheme = "ExampleApp"
        config.targetName = "ExampleApp"
        config.bundleID = "com.example.ExampleApp"

        let status = EnvironmentValidator(
            processEnvironment: ["PATH": toolsURL.path]
        ).validate(config: config)

        #expect(status.isApplicationTargetResolved)
        #expect(status.areAllChecksPassing)
    }

    @Test
    func doesNotInferMissingDeployScript() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-validator-missing-script-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let inference = EnvironmentValidator()
            .inferProjectDetails(from: rootURL.path)

        #expect(inference.deployScriptPath == nil)
    }
}
