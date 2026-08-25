import Foundation
import Testing
@testable import IOSSignKit

struct AppConfigMigrationTests {
    @Test
    func schemaOneTargetSelectionIsInvalidatedForExplicitReselection()
        throws {
        let data = Data(
            #"""
            {
              "projectRootPath": "/example/project",
              "deployScriptPath": "/example/project/scripts/deploy/ios-device.command",
              "xcodeprojPath": "/example/project/App.xcodeproj",
              "scheme": "App",
              "bundleID": "com.example.App",
              "applicationTargetResolutionSchemaVersion": 1,
              "checkIntervalMinutes": 5,
              "reminderCooldownHours": 24
            }
            """#.utf8
        )

        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: data
        )

        #expect(config.targetName == nil)
        #expect(!config.hasResolvedApplicationTarget)
    }

    @Test
    func targetNameRoundTripsAsPartOfResolvedApplicationIdentity()
        throws {
        let config = AppConfig(
            projectRootPath: "/example/project",
            deployScriptPath:
                "/example/project/scripts/deploy/ios-device.command",
            xcodeprojPath: "/example/project/App.xcodeproj",
            scheme: "App",
            targetName: "InternalApp",
            bundleID: "com.example.App",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            expiredCheckIntervalMinutes: 2,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )

        let decoded = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONEncoder().encode(config)
        )

        #expect(decoded == config)
        #expect(decoded.hasResolvedApplicationTarget)
        #expect(decoded.targetName == "InternalApp")
        #expect(
            decoded.applicationTargetResolutionSchemaVersion
                == AppConfig
                    .currentApplicationTargetResolutionSchemaVersion
        )
    }

    @Test
    func resolvedApplicationTargetDoesNotRequireLegacyDeployScript() {
        let config = AppConfig(
            projectRootPath: "/example/project",
            deployScriptPath: nil,
            xcodeprojPath: "/example/project/App.xcodeproj",
            scheme: "App",
            targetName: "App",
            bundleID: "com.example.App",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )

        #expect(config.hasResolvedApplicationTarget)
    }

    @Test
    @MainActor
    func bootstrapRemovesLegacyDeployScriptPathFromActiveConfiguration()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-legacy-script-config-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = RefreshStateStore(appSupportDirectory: directory)
        let legacyScriptPath =
            "/example/project/scripts/deploy/ios-device.command"
        let config = AppConfig(
            projectRootPath: "/example/project",
            deployScriptPath: legacyScriptPath,
            xcodeprojPath: "/example/project/App.xcodeproj",
            scheme: "App",
            targetName: "App",
            bundleID: "com.example.App",
            preferredDeviceID: nil,
            preferredDeviceName: nil,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .reminderOnly
        )
        try store.saveConfig(config)

        let result = AppBootstrapper(stateStore: store).bootstrap()

        #expect(result.config.deployScriptPath == nil)
        #expect(result.config.hasResolvedApplicationTarget)
        #expect(store.loadConfig().deployScriptPath == nil)
        let persistedData = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        #expect(
            String(decoding: persistedData, as: UTF8.self)
                .contains(legacyScriptPath) == false
        )
    }

    @Test
    func clampsUntrustedNumericValuesAndNormalizesBlankIdentifiers() throws {
        let data = Data(
            #"""
            {
              "projectRootPath": "   ",
              "bundleID": " com.example.App ",
              "preferredDeviceID": "\n",
              "checkIntervalMinutes": 9223372036854775807,
              "expiredCheckIntervalMinutes": -10,
              "reminderCooldownHours": -10
            }
            """#.utf8
        )

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.projectRootPath == nil)
        #expect(config.bundleID == "com.example.App")
        #expect(config.preferredDeviceID == nil)
        #expect(config.checkIntervalMinutes == 60)
        #expect(config.expiredCheckIntervalMinutes == 1)
        #expect(config.reminderCooldownHours == 1)
    }

    @Test
    func migratesLegacyThresholdPolicyWithoutResettingOtherFields() throws {
        let data = Data(
            #"""
            {
              "projectRootPath": "/example/project",
              "deployScriptPath": "/example/project/scripts/deploy/ios-device.command",
              "bundleID": "com.example.App",
              "preferredDeviceID": "iphone-1",
              "refreshThresholdDays": 5,
              "checkIntervalMinutes": 10,
              "reminderCooldownHours": 12,
              "launchAppAfterInstall": true,
              "openLogOnFailure": true,
              "startAtLogin": true,
              "autoRefreshPolicy": "autoRefreshWhenDue"
            }
            """#.utf8
        )

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(config.projectRootPath == "/example/project")
        #expect(config.bundleID == "com.example.App")
        #expect(config.preferredDeviceID == "iphone-1")
        #expect(config.checkIntervalMinutes == 10)
        #expect(config.expiredCheckIntervalMinutes == 1)
        #expect(config.reminderCooldownHours == 12)
        #expect(config.startAtLogin)
        #expect(config.autoRefreshPolicy == .autoRefreshWhenExpired)

        let encoded = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["refreshThresholdDays"] == nil)
        #expect(object["launchAppAfterInstall"] == nil)
        #expect(object["openLogOnFailure"] == nil)
        #expect(object["autoRefreshPolicy"] as? String == "autoRefreshWhenExpired")
    }

    @Test
    @MainActor
    func bootstrapPreservesMalformedConfigAndReportsRecoveryMessage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sign-kit-corrupt-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let malformed = Data(#"{"projectRootPath":42"#.utf8)
        try malformed.write(to: configURL, options: .atomic)
        let store = RefreshStateStore(appSupportDirectory: directory)

        let result = AppBootstrapper(stateStore: store).bootstrap()

        #expect(result.requiresSetup)
        #expect(result.configurationLoadFailure?.contains("原文件已保留") == true)
        #expect(try Data(contentsOf: configURL) == malformed)

        let setup = SetupWizardViewModel(
            deviceDetectionRolloutMode: .fallback,
            initialConfig: result.config,
            environmentValidator: EnvironmentValidator(),
            stateStore: store,
            configurationRequiresRecovery: true
        )
        #expect(!setup.saveSettings())
        #expect(!setup.validationMessage.isEmpty)
        #expect(try Data(contentsOf: configURL) == malformed)
    }
}
