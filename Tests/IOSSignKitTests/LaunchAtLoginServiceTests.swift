import Foundation
import ServiceManagement
import Testing
@testable import IOSSignKit

struct LaunchAtLoginServiceTests {
    @Test
    func migratesOwnedLegacyLaunchAgentToMainAppService() throws {
        let fixture = try Fixture()
        try fixture.writeLegacyLaunchAgent()

        try fixture.service.sync(isEnabled: true)

        #expect(!FileManager().fileExists(atPath: fixture.legacyPlistURL.path))
        #expect(!FileManager().fileExists(atPath: fixture.currentPlistURL.path))
        #expect(fixture.controller.registerCount == 1)
        #expect(fixture.service.currentStatus())
    }

    @Test
    func enabledMainAppServiceIsIdempotentAndRemovesOwnedLegacyEntry() throws {
        let fixture = try Fixture(initialStatus: .enabled)
        try fixture.writeLegacyLaunchAgent()

        try fixture.service.sync(isEnabled: true)

        #expect(fixture.controller.registerCount == 0)
        #expect(!FileManager().fileExists(atPath: fixture.legacyPlistURL.path))
        #expect(fixture.service.currentStatus())
    }

    @Test
    func invalidSignatureFallsBackToDirectExecutableLaunchAgent() throws {
        let fixture = try Fixture(
            registerError: serviceError(kSMErrorInvalidSignature)
        )

        try fixture.service.sync(isEnabled: true)

        let arguments = try #require(fixture.currentProgramArguments())
        #expect(arguments == [fixture.executableURL.path])
        #expect(!arguments.contains("/usr/bin/open"))
        #expect(fixture.service.currentStatus())
    }

    @Test
    func requiresApprovalReturnsActionableError() throws {
        let fixture = try Fixture(initialStatus: .requiresApproval)

        #expect(throws: LaunchAtLoginError.requiresApproval) {
            try fixture.service.sync(isEnabled: true)
        }
        #expect(!fixture.service.currentStatus())
    }

    @Test
    func missingMainAppServiceUsesDirectExecutableFallback() throws {
        let fixture = try Fixture(initialStatus: .notFound)

        try fixture.service.sync(isEnabled: true)

        let arguments = try #require(fixture.currentProgramArguments())
        #expect(arguments == [fixture.executableURL.path])
        #expect(!arguments.contains("/usr/bin/open"))
        #expect(fixture.service.currentStatus())
    }

    @Test
    func ordinaryRegistrationFailureDoesNotSilentlyFallBack() throws {
        let fixture = try Fixture(
            registerError: CocoaError(.fileWriteUnknown)
        )

        #expect(throws: LaunchAtLoginError.self) {
            try fixture.service.sync(isEnabled: true)
        }
        #expect(!FileManager().fileExists(atPath: fixture.currentPlistURL.path))
    }

    @Test
    func preservesLegacyLaunchAgentWhenOwnershipCannotBeProven() throws {
        let fixture = try Fixture()
        try fixture.writeLegacyLaunchAgent(label: "com.example.tampered")

        #expect(throws: LaunchAtLoginError.self) {
            try fixture.service.sync(isEnabled: true)
        }
        #expect(FileManager().fileExists(atPath: fixture.legacyPlistURL.path))
        #expect(fixture.controller.registerCount == 0)
    }

    @Test
    func preservesSymbolicLinkAndDoesNotRegisterReplacement() throws {
        let fixture = try Fixture()
        try FileManager().createDirectory(
            at: fixture.launchAgentsURL,
            withIntermediateDirectories: true
        )
        let target = fixture.root.appendingPathComponent("foreign.plist")
        try Data("foreign".utf8).write(to: target)
        try FileManager().createSymbolicLink(
            at: fixture.legacyPlistURL,
            withDestinationURL: target
        )

        #expect(throws: LaunchAtLoginError.self) {
            try fixture.service.sync(isEnabled: true)
        }
        #expect(
            try fixture.legacyPlistURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ).isSymbolicLink == true
        )
        #expect(fixture.controller.registerCount == 0)
    }

    @Test
    func rejectsTamperedProgramArguments() throws {
        let fixture = try Fixture()
        try fixture.writeLegacyLaunchAgent(
            arguments: ["/usr/bin/open", "/Applications/Other.app"]
        )

        #expect(throws: LaunchAtLoginError.self) {
            try fixture.service.sync(isEnabled: true)
        }
        #expect(FileManager().fileExists(atPath: fixture.legacyPlistURL.path))
    }

    @Test
    func rollsBackRegistrationWhenRemovingLegacyPlistFails() throws {
        let fixture = try Fixture(failLegacyRemoval: true)
        try fixture.writeLegacyLaunchAgent()

        #expect(throws: LaunchAtLoginError.self) {
            try fixture.service.sync(isEnabled: true)
        }
        #expect(FileManager().fileExists(atPath: fixture.legacyPlistURL.path))
        #expect(fixture.controller.registerCount == 1)
        #expect(fixture.controller.unregisterCount == 1)
        #expect(fixture.controller.currentStatus == .notRegistered)
    }

    @Test
    func disablingUnregistersMainAppAndRemovesOnlyOwnedFallback() throws {
        let fixture = try Fixture(
            registerError: serviceError(kSMErrorInvalidSignature)
        )
        try fixture.service.sync(isEnabled: true)
        try fixture.writeLegacyLaunchAgent(label: "foreign.label")
        fixture.controller.setStatus(.enabled)

        try fixture.service.sync(isEnabled: false)

        #expect(fixture.controller.unregisterCount == 1)
        #expect(!FileManager().fileExists(atPath: fixture.currentPlistURL.path))
        #expect(FileManager().fileExists(atPath: fixture.legacyPlistURL.path))
        #expect(!fixture.service.currentStatus())
    }
}

private func serviceError(_ code: Int) -> NSError {
    NSError(
        domain: "kSMErrorDomainFramework",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: "Service Management test error"]
    )
}

private struct Fixture {
    let root: URL
    let launchAgentsURL: URL
    let appURL: URL
    let executableURL: URL
    let controller: MainAppLoginItemRecorder
    let service: LaunchAtLoginService

    var legacyPlistURL: URL {
        launchAgentsURL.appendingPathComponent(
            LaunchAtLoginService.legacyBundleIdentifier + ".plist"
        )
    }

    var currentPlistURL: URL {
        launchAgentsURL.appendingPathComponent("com.xuzw.iossignkit.plist")
    }

    init(
        initialStatus: MainAppLoginItemStatus = .notRegistered,
        registerError: Error? = nil,
        unregisterError: Error? = nil,
        failLegacyRemoval: Bool = false
    ) throws {
        root = FileManager().temporaryDirectory.appendingPathComponent(
            "LaunchAtLoginServiceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        launchAgentsURL = root.appendingPathComponent(
            "LaunchAgents",
            isDirectory: true
        )
        appURL = root.appendingPathComponent("iOSSignKit.app", isDirectory: true)
        executableURL = appURL.appendingPathComponent(
            "Contents/MacOS/IOSSignKit"
        )
        try FileManager().createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try FileManager().setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.xuzw.iossignkit",
            "CFBundleExecutable": "IOSSignKit",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(
            to: appURL.appendingPathComponent("Contents/Info.plist")
        )

        controller = MainAppLoginItemRecorder(
            initialStatus: initialStatus,
            registerError: registerError,
            unregisterError: unregisterError
        )
        let legacyURL = launchAgentsURL.appendingPathComponent(
            LaunchAtLoginService.legacyBundleIdentifier + ".plist"
        )
        service = LaunchAtLoginService(
            mainAppLoginItem: controller.controller,
            launchAgentsDirectory: launchAgentsURL,
            currentBundleIdentifier: "com.xuzw.iossignkit",
            bundleURL: appURL,
            executableURL: executableURL,
            removeItem: { url in
                if failLegacyRemoval && url == legacyURL {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager().removeItem(at: url)
            }
        )
    }

    func writeLegacyLaunchAgent(
        label: String = LaunchAtLoginService.legacyBundleIdentifier,
        arguments: [String]? = nil
    ) throws {
        try FileManager().createDirectory(
            at: launchAgentsURL,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments ?? ["/usr/bin/open", appURL.path],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: legacyPlistURL)
    }

    func currentProgramArguments() -> [String]? {
        guard let data = try? Data(contentsOf: currentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["ProgramArguments"] as? [String]
    }
}

private final class MainAppLoginItemRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statusValue: MainAppLoginItemStatus
    private let registerError: Error?
    private let unregisterError: Error?
    private var registerCalls = 0
    private var unregisterCalls = 0

    init(
        initialStatus: MainAppLoginItemStatus,
        registerError: Error?,
        unregisterError: Error?
    ) {
        self.statusValue = initialStatus
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    var controller: MainAppLoginItemController {
        MainAppLoginItemController(
            status: { self.currentStatus },
            register: { try self.register() },
            unregister: { try self.unregister() }
        )
    }

    var currentStatus: MainAppLoginItemStatus {
        lock.withLock { statusValue }
    }

    var registerCount: Int {
        lock.withLock { registerCalls }
    }

    var unregisterCount: Int {
        lock.withLock { unregisterCalls }
    }

    func setStatus(_ status: MainAppLoginItemStatus) {
        lock.withLock {
            statusValue = status
        }
    }

    private func register() throws {
        try lock.withLock {
            registerCalls += 1
            if let registerError {
                throw registerError
            }
            statusValue = .enabled
        }
    }

    private func unregister() throws {
        try lock.withLock {
            unregisterCalls += 1
            if let unregisterError {
                throw unregisterError
            }
            statusValue = .notRegistered
        }
    }
}
