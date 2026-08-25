import Foundation
import Testing
@testable import IOSSignKit

struct HostInstallReceiptStoreTests {
    @Test
    func preparedReceiptBecomesInstalledAndRoundTrips() throws {
        let fixture = HostInstallReceiptStoreFixture()
        let token = DeploymentToken.make().rawValue
        let preparedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let expirationDate = preparedAt.addingTimeInterval(7 * 24 * 60 * 60)

        let prepared = try fixture.store.recordPrepared(
            deploymentToken: token,
            bundleIdentifier: "com.example.App",
            deviceIdentifier: "DEVICE-1",
            teamIdentifier: "ABCDE12345",
            shortVersion: "1.2.3",
            buildVersion: "42",
            profileUUID: "3D4C69C7-798A-43FB-A7BB-A7E2DD80F5AB",
            profileDigest: String(repeating: "a", count: 64),
            profileExpirationDate: expirationDate,
            preparedAt: preparedAt
        )

        #expect(prepared.status == .prepared)
        #expect(prepared.installedAt == nil)
        #expect(try fixture.store.load(deploymentToken: token) == prepared)

        let installedAt = preparedAt.addingTimeInterval(30)
        let installed = try fixture.store.markInstalled(
            deploymentToken: token,
            installedAt: installedAt
        )

        #expect(installed.status == .installed)
        #expect(installed.installedAt == installedAt)
        #expect(try fixture.store.load(deploymentToken: token) == installed)
    }

    @Test
    func receiptDirectoryAndFileUsePrivatePermissions() throws {
        let fixture = HostInstallReceiptStoreFixture()
        let token = try fixture.recordPrepared()
        let receiptURL = fixture.receiptURL(token: token)

        let rootAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.rootURL.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: receiptURL.path
        )

        #expect(rootAttributes[.posixPermissions] as? Int == 0o700)
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
    }

    @Test
    func corruptExactReceiptFailsClosed() throws {
        let fixture = HostInstallReceiptStoreFixture()
        let token = try fixture.recordPrepared()
        let receiptURL = fixture.receiptURL(token: token)
        try Data("{\"payload\":\"tampered\"}".utf8).write(
            to: receiptURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: receiptURL.path
        )

        #expect(throws: HostInstallReceiptStoreError.self) {
            _ = try fixture.store.load(deploymentToken: token)
        }
    }

    @Test
    func invalidTokenNeverSelectsAFile() throws {
        let fixture = HostInstallReceiptStoreFixture()
        try FileManager.default.createDirectory(
            at: fixture.rootURL,
            withIntermediateDirectories: true
        )

        #expect(throws: HostInstallReceiptStoreError.invalidDeploymentToken) {
            _ = try fixture.store.load(deploymentToken: "../receipt")
        }
    }

    @Test
    func renamedReceiptCannotBeLoadedOrMarkedForAnotherExactToken()
        throws
    {
        let fixture = HostInstallReceiptStoreFixture()
        let originalToken = try fixture.recordPrepared()
        let differentToken = DeploymentToken.make().rawValue
        try FileManager.default.moveItem(
            at: fixture.receiptURL(token: originalToken),
            to: fixture.receiptURL(token: differentToken)
        )

        #expect(throws: HostInstallReceiptStoreError.self) {
            _ = try fixture.store.load(deploymentToken: differentToken)
        }
        #expect(throws: HostInstallReceiptStoreError.self) {
            _ = try fixture.store.markInstalled(
                deploymentToken: differentToken,
                installedAt: Date(timeIntervalSince1970: 1_787_000_030)
            )
        }
    }

    @Test
    func retentionKeepsCurrentTokenAndBoundsControlledReceipts() throws {
        let fixture = HostInstallReceiptStoreFixture(
            limits: HostInstallReceiptStoreLimits(
                maximumReceiptBytes: 64 * 1_024,
                maximumReceiptCount: 2,
                maximumTotalBytes: 128 * 1_024,
                maximumDirectoryEntryCount: 20
            )
        )
        _ = try fixture.recordPrepared(
            token: DeploymentToken.make().rawValue,
            preparedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
        _ = try fixture.recordPrepared(
            token: DeploymentToken.make().rawValue,
            preparedAt: Date(timeIntervalSince1970: 1_787_000_001)
        )
        let currentToken = try fixture.recordPrepared(
            token: DeploymentToken.make().rawValue,
            preparedAt: Date(timeIntervalSince1970: 1_787_000_002)
        )

        let controlledFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.rootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(controlledFiles.count == 2)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.receiptURL(token: currentToken).path
            )
        )
        #expect(
            try fixture.store.load(deploymentToken: currentToken)?.status
                == .prepared
        )
    }

    @Test
    func retentionIgnoresUncontrolledJSONSymlink() throws {
        let fixture = HostInstallReceiptStoreFixture(
            limits: HostInstallReceiptStoreLimits(
                maximumReceiptBytes: 64 * 1_024,
                maximumReceiptCount: 1,
                maximumTotalBytes: 128 * 1_024,
                maximumDirectoryEntryCount: 20
            )
        )
        let firstToken = try fixture.recordPrepared()
        let symlinkURL = fixture.rootURL.appendingPathComponent(
            "\(DeploymentToken.make().rawValue).json"
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: fixture.receiptURL(token: firstToken)
        )
        let currentToken = try fixture.recordPrepared()

        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: symlinkURL.path
            ) == fixture.receiptURL(token: firstToken).path
        )
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.receiptURL(token: currentToken).path
            )
        )
    }

    @Test
    func retentionCountsUnknownRegularJSONBytesAndFailsClosed() throws {
        let fixture = HostInstallReceiptStoreFixture(
            limits: HostInstallReceiptStoreLimits(
                maximumReceiptBytes: 64 * 1_024,
                maximumReceiptCount: 10,
                maximumTotalBytes: 64 * 1_024,
                maximumDirectoryEntryCount: 20
            )
        )
        let currentToken = try fixture.recordPrepared()
        let unknownURL = fixture.rootURL.appendingPathComponent(
            "unknown.json"
        )
        try Data(repeating: 0x41, count: 70 * 1_024).write(
            to: unknownURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: unknownURL.path
        )

        #expect(throws: HostInstallReceiptStoreError.self) {
            _ = try fixture.store.markInstalled(
                deploymentToken: currentToken,
                installedAt: Date(timeIntervalSince1970: 1_787_000_030)
            )
        }
        #expect(FileManager.default.fileExists(atPath: unknownURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.receiptURL(token: currentToken).path
            )
        )
    }
}

private struct HostInstallReceiptStoreFixture {
    let rootURL: URL
    let store: HostInstallReceiptStore

    init(
        limits: HostInstallReceiptStoreLimits = .production
    ) {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ios-sign-kit-host-receipt-\(UUID().uuidString)",
                isDirectory: true
            )
        store = HostInstallReceiptStore(rootURL: rootURL, limits: limits)
    }

    func receiptURL(token: String) -> URL {
        rootURL.appendingPathComponent("\(token).json")
    }

    @discardableResult
    func recordPrepared(
        token: String = DeploymentToken.make().rawValue,
        preparedAt: Date = Date(timeIntervalSince1970: 1_787_000_000)
    ) throws -> String {
        _ = try store.recordPrepared(
            deploymentToken: token,
            bundleIdentifier: "com.example.App",
            deviceIdentifier: "DEVICE-1",
            teamIdentifier: "ABCDE12345",
            shortVersion: "1.2.3",
            buildVersion: "42",
            profileUUID: "3D4C69C7-798A-43FB-A7BB-A7E2DD80F5AB",
            profileDigest: String(repeating: "a", count: 64),
            profileExpirationDate:
                preparedAt.addingTimeInterval(7 * 24 * 60 * 60),
            preparedAt: preparedAt
        )
        return token
    }
}
