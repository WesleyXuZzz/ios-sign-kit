import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct MenuBarViewModelRefreshPolicySafetyIntegrationTests {
    @Test
    func switchingToReadOnlyCancelsQueuedCountdownWithoutRecordingAttempt()
        async throws
    {
        let fixture = try RefreshPolicySafetyFixture(
            inspectionBehavior: .installedExpired,
            seedsInstalledAppCache: false
        )
        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .connectionConfirmation
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()
        #expect(fixture.viewModel.pendingAutoRefreshCountdown != nil)

        fixture.viewModel.transitionDeviceDetectionRollout(to: .readOnly)

        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)

        await fixture.shutdown()

        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)
        #expect(fixture.stateStore.loadState().lastAutomaticAttemptAt == nil)
        #expect(fixture.actionRecorder.deployCount == 0)
    }

    @Test
    func cachedXcodeValidationCannotAuthorizeNewAutomaticCountdown()
        async throws
    {
        let fixture = try RefreshPolicySafetyFixture(
            inspectionBehavior: .installedExpired,
            seedsInstalledAppCache: false,
            initialExpiryOffset: 3_600,
            inspectedExpiryOffset: -60
        )
        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.xcodeRecorder.commandCount == 0)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        #expect(fixture.viewModel.state.lastAutomaticAttemptAt == nil)

        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.inspectionRecorder.callCount == 2)
        #expect(fixture.xcodeRecorder.commandCount >= 2)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown != nil)
        #expect(fixture.actionRecorder.deployCount == 0)
        await fixture.shutdown()
    }

    @Test(arguments: [
        RefreshPolicySafetyInspectionBehavior.notInstalled,
        RefreshPolicySafetyInspectionBehavior.failed,
    ])
    func freshNegativeInspectionEvictsOldInstalledEvidenceBeforeNextHeartbeat(
        _ behavior: RefreshPolicySafetyInspectionBehavior
    ) async throws {
        let fixture = try RefreshPolicySafetyFixture(
            inspectionBehavior: behavior,
            seedsInstalledAppCache: true
        )
        // Recovery work must bypass the old installed candidate and publish
        // the fresh negative result.
        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .connectionConfirmation
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        // With valid Xcode evidence and no critical action pending, this is a
        // heartbeat candidate. It must inspect again instead of resurrecting
        // the pre-existing installed entry.
        fixture.viewModel.refreshDeviceStatus(
            presentation: .background,
            mode: .backgroundPoll
        )
        await fixture.viewModel.waitForEnvironmentRefreshToSettle()

        #expect(fixture.inspectionRecorder.callCount == 2)
        #expect(fixture.viewModel.pendingAutoRefreshCountdown == nil)
        await fixture.shutdown()
    }
}

struct RefreshPolicySafetyCacheBoundaryTests {
    @Test
    func freshInvalidXcodeValidationEvictsOlderSuccessfulValidation() {
        let clock = ContinuousClock()
        let observedAt = clock.now
        let key = XcodeValidationCacheKey(
            targetGeneration: 0,
            normalizedProjectIdentity: "/tmp/RefreshPolicySafety.xcodeproj",
            scheme: "RefreshPolicySafety",
            targetName: "RefreshPolicySafety",
            bundleID: "com.example.refresh-policy-safety"
        )
        var caches = RefreshSessionCaches()
        caches.storeXcodeValidation(
            XcodeValidationCacheEntry(
                validation: XcodeProjectValidation(
                    isValid: true,
                    diagnosticMessage: nil
                ),
                observedAt: observedAt,
                observedWallClockAt: Date()
            ),
            for: key
        )
        #expect(
            caches.xcodeCandidate(for: key, at: observedAt) != nil
        )

        caches.storeXcodeValidation(
            XcodeValidationCacheEntry(
                validation: XcodeProjectValidation(
                    isValid: false,
                    diagnosticMessage: "目标已失效"
                ),
                observedAt: observedAt.advanced(by: .seconds(1)),
                observedWallClockAt: Date()
            ),
            for: key
        )

        #expect(
            caches.xcodeCandidate(
                for: key,
                at: observedAt.advanced(by: .seconds(1))
            ) == nil
        )
    }
}

enum RefreshPolicySafetyInspectionBehavior:
    CaseIterable,
    Sendable
{
    case installedExpired
    case notInstalled
    case failed
}

@MainActor
private final class RefreshPolicySafetyFixture {
    let stateStore: RefreshStateStore
    let inspectionRecorder: RefreshPolicySafetyInspectionRecorder
    let xcodeRecorder = RefreshPolicySafetyXcodeRecorder()
    let actionRecorder = RefreshPolicySafetyActionRecorder()
    let scheduler = ManualRefreshScheduler()
    let viewModel: MenuBarViewModel

    init(
        inspectionBehavior: RefreshPolicySafetyInspectionBehavior,
        seedsInstalledAppCache: Bool,
        initialExpiryOffset: TimeInterval = -60,
        inspectedExpiryOffset: TimeInterval = -60
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-refresh-policy-safety-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent(
            "Project",
            isDirectory: true
        )
        let scriptURL = projectURL.appendingPathComponent(
            "scripts/deploy/ios-device.command"
        )
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/zsh\nexit 1\n".write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        let xcodeProjectURL = projectURL.appendingPathComponent(
            "RefreshPolicySafety.xcodeproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: xcodeProjectURL,
            withIntermediateDirectories: true
        )

        let device = DeviceInfo(
            id: "refresh-policy-safety-iphone",
            name: "Refresh Policy Safety iPhone",
            platform: "com.apple.platform.iphoneos",
            osVersion: "27.0",
            isAvailable: true,
            isPaired: true
        )
        let bundleID = "com.example.refresh-policy-safety"
        let config = AppConfig(
            projectRootPath: projectURL.path,
            deployScriptPath: scriptURL.path,
            xcodeprojPath: xcodeProjectURL.path,
            scheme: "RefreshPolicySafety",
            targetName: "RefreshPolicySafety",
            bundleID: bundleID,
            preferredDeviceID: device.id,
            preferredDeviceName: device.name,
            checkIntervalMinutes: 5,
            reminderCooldownHours: 24,
            startAtLogin: false,
            autoRefreshPolicy: .autoRefreshWhenExpired
        )

        let now = Date()
        let expectedExpiryAt = now.addingTimeInterval(
            initialExpiryOffset
        )
        var state = AppState.default
        state.currentDeviceStatus = "online"
        state.currentDeviceName = device.name
        state.currentDeviceOS = device.osVersion
        state.lastDeviceSeenAt = now
        state.targetAppPresence = .installed
        state.targetAppBundleID = bundleID
        state.targetDeviceID = device.id
        state.lastDetectedExpiryAt = expectedExpiryAt
        state.expirySource = "test"
        state.isTargetAppExpiryEvidenceVerified = true

        stateStore = RefreshStateStore(
            appSupportDirectory: rootURL.appendingPathComponent(
                "State",
                isDirectory: true
            )
        )
        try stateStore.saveConfig(config)
        try stateStore.saveState(state)

        let oldInstalledApp = RefreshPolicySafetyFixture.makeInstalledApp(
            bundleID: bundleID,
            expectedExpiryAt: now.addingTimeInterval(
                inspectedExpiryOffset
            )
        )
        inspectionRecorder = RefreshPolicySafetyInspectionRecorder(
            behavior: inspectionBehavior,
            installedApp: oldInstalledApp
        )

        let observedAt = ContinuousClock().now
        var caches = RefreshSessionCaches()
        caches.storeXcodeValidation(
            XcodeValidationCacheEntry(
                validation: XcodeProjectValidation(
                    isValid: true,
                    diagnosticMessage: nil
                ),
                observedAt: observedAt,
                observedWallClockAt: now
            ),
            for: XcodeValidationCacheKey(
                targetGeneration: 0,
                normalizedProjectIdentity:
                    xcodeProjectURL.standardizedFileURL.path,
                scheme: config.scheme ?? "",
                targetName: config.targetName ?? "",
                bundleID: bundleID
            )
        )
        if seedsInstalledAppCache {
            caches.storeInstalledApp(
                InstalledAppCacheEntry(
                    result: .installed(oldInstalledApp),
                    observedAt: observedAt,
                    observedWallClockAt: now
                ),
                for: InstalledAppCacheKey(
                    targetGeneration: 0,
                    deviceID: StableDeviceID(device.id)!,
                    bundleID: bundleID
                )
            )
        }

        let inspectionRecorder = self.inspectionRecorder
        let xcodeRecorder = self.xcodeRecorder
        let actionRecorder = self.actionRecorder
        viewModel = MenuBarViewModel(
            deviceDetectionRolloutMode: .production,
            bootstrapper: AppBootstrapper(stateStore: stateStore),
            stateStore: stateStore,
            xcodeProjectResolver:
                refreshPolicySafetyProjectResolver(
                    recorder: xcodeRecorder
                ),
            deviceMonitor: DeviceMonitor(
                runCommand: RefreshPolicySafetyDeviceRunner(
                    device: device
                ).run
            ),
            refreshSessionCaches: caches,
            refreshScheduler: scheduler.interface,
            inspectInstalledApp: {
                @Sendable _, _, _, _ in
                try inspectionRecorder.inspect()
            },
            startDeploy: { _, _, _, _, _ in
                actionRecorder.recordDeploy()
                throw DeployServiceError.missingDeployScript
            },
            pairDevice: { _ in
                actionRecorder.recordPair()
                return .failed("测试中禁止配对")
            },
            notificationService: ScheduledNotificationStub()
        )
        viewModel.stopPolling()
    }

    func shutdown() async {
        await viewModel.shutdown()
        scheduler.cancelAll()
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    private static func makeInstalledApp(
        bundleID: String,
        expectedExpiryAt: Date
    ) -> InstalledAppInfo {
        InstalledAppInfo(
            bundleIdentifier: bundleID,
            name: "Refresh Policy Safety",
            version: "1.0",
            bundleVersion: "1",
            appURL:
                "file:///private/var/containers/Bundle/Application/test/RefreshPolicySafety.app",
            builtByDeveloper: true,
            installMetadata: AppInstallMetadataSnapshot(
                schemaVersion: 1,
                recordedAt: Date(),
                bundleIdentifier: bundleID,
                shortVersion: "1.0",
                buildVersion: "1",
                expectedExpiryAt: expectedExpiryAt,
                profileSource: "test"
            ),
            installMetadataValidation: .valid
        )
    }
}

private final class RefreshPolicySafetyInspectionRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let behavior: RefreshPolicySafetyInspectionBehavior
    private let installedApp: InstalledAppInfo
    private var calls = 0

    init(
        behavior: RefreshPolicySafetyInspectionBehavior,
        installedApp: InstalledAppInfo
    ) {
        self.behavior = behavior
        self.installedApp = installedApp
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func inspect() throws -> InstalledAppInfo? {
        lock.withLock {
            calls += 1
        }
        switch behavior {
        case .installedExpired:
            return installedApp
        case .notInstalled:
            return nil
        case .failed:
            throw RefreshPolicySafetyInspectionError.unavailable
        }
    }
}

private enum RefreshPolicySafetyInspectionError: Error {
    case unavailable
}

private final class RefreshPolicySafetyActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var deploys = 0
    private var pairs = 0

    var deployCount: Int {
        lock.withLock { deploys }
    }

    func recordDeploy() {
        lock.withLock {
            deploys += 1
        }
    }

    func recordPair() {
        lock.withLock {
            pairs += 1
        }
    }
}

private final class RefreshPolicySafetyXcodeRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var commands = 0

    var commandCount: Int {
        lock.withLock { commands }
    }

    func recordCommand() {
        lock.withLock {
            commands += 1
        }
    }
}

private final class RefreshPolicySafetyDeviceRunner: @unchecked Sendable {
    private let device: DeviceInfo

    init(device: DeviceInfo) {
        self.device = device
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        if arguments.first == "xcdevice" {
            return CommandResult(
                standardOutput: """
                [{
                  "simulator": false,
                  "available": true,
                  "platform": "\(device.platform)",
                  "identifier": "\(device.id)",
                  "name": "\(device.name)",
                  "modelCode": "iPhone18,1",
                  "modelName": "iPhone",
                  "operatingSystemVersion": "\(device.osVersion)"
                }]
                """,
                standardError: "",
                terminationStatus: 0
            )
        }

        guard arguments.first == "devicectl",
              let outputPath = jsonOutputPath(from: arguments) else {
            return CommandResult(
                standardOutput: "",
                standardError: "Unexpected test command",
                terminationStatus: 1
            )
        }
        try """
        {"result":{"devices":[{
          "identifier":"coredevice-refresh-policy-safety",
          "deviceProperties":{
            "name":"\(device.name)",
            "osVersionNumber":"\(device.osVersion)",
            "deviceClass":"iPhone",
            "developerModeStatus":"enabled"
          },
          "hardwareProperties":{
            "udid":"\(device.id)",
            "platform":"iOS",
            "deviceType":"iPhone"
          },
          "connectionProperties":{
            "connectionState":"connected",
            "pairingState":"paired",
            "tunnelState":"connected",
            "transportType":"localNetwork"
          }
        }]}}
        """.write(
            toFile: outputPath,
            atomically: true,
            encoding: .utf8
        )
        return CommandResult(
            standardOutput: "",
            standardError: "",
            terminationStatus: 0
        )
    }

    private func jsonOutputPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--json-output"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private func refreshPolicySafetyProjectResolver(
    recorder: RefreshPolicySafetyXcodeRecorder
) -> XcodeProjectResolver {
    XcodeProjectResolver { _, arguments, _ in
        recorder.recordCommand()
        if arguments.contains("-list") {
            return CommandResult(
                standardOutput:
                    #"{"project":{"schemes":["RefreshPolicySafety"],"targets":["RefreshPolicySafety"]}}"#,
                standardError: "",
                terminationStatus: 0
            )
        }
        return CommandResult(
            standardOutput: """
            [{
              "target": "RefreshPolicySafety",
              "buildSettings": {
                "PRODUCT_TYPE": "com.apple.product-type.application",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.example.refresh-policy-safety",
                "PLATFORM_NAME": "iphoneos"
              }
            }]
            """,
            standardError: "",
            terminationStatus: 0
        )
    }
}
