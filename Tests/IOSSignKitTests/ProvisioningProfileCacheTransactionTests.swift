import CryptoKit
import Foundation
import Testing
@testable import IOSSignKit

struct ProvisioningProfileCacheTransactionTests {
    private let bundleIdentifier = "com.example.Sample"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func forceMovesOnlyExactMatchesFromBothCacheLocations() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let firstData = try fixture.writeProfile(
            location: .xcodeUserData,
            name: "exact-active",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let secondData = try fixture.writeProfile(
            location: .mobileDevice,
            name: "exact-expired",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(-3_600)
        )
        let differentTeamURL = try fixture.writeProfileURL(
            location: .mobileDevice,
            name: "different-team",
            applicationIdentifier: "OTHER12345.com.example.Sample",
            expirationDate: now.addingTimeInterval(-3_600)
        )
        let differentBundleURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "different-bundle",
            applicationIdentifier: "TEAM123456.com.example.SampleHelper",
            expirationDate: now.addingTimeInterval(-3_600)
        )
        let wildcardURL = try fixture.writeProfileURL(
            location: .mobileDevice,
            name: "wildcard",
            applicationIdentifier: "TEAM123456.*",
            expirationDate: now.addingTimeInterval(-3_600)
        )
        let token = DeploymentToken.make().rawValue

        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: token,
            now: now
        )

        #expect(transaction.backups.count == 2)
        #expect(transaction.backups.map(\.location) == [
            .xcodeUserData,
            .mobileDevice
        ])
        #expect(transaction.previousProfileDigests == Set([
            sha256Hex(firstData),
            sha256Hex(secondData)
        ]))
        #expect(transaction.backups.allSatisfy {
            !$0.originalURL.path.hasPrefix(transaction.backupDirectoryURL.path)
                && $0.destinationURL.path.hasPrefix(
                    transaction.backupDirectoryURL.path + "/"
                )
                && FileManager.default.fileExists(atPath: $0.destinationURL.path)
                && !FileManager.default.fileExists(atPath: $0.originalURL.path)
        })
        #expect(posixPermissions(at: transaction.backupDirectoryURL) == 0o700)
        #expect(transaction.backups.allSatisfy {
            posixPermissions(at: $0.destinationURL.deletingLastPathComponent())
                == 0o700
                && posixPermissions(at: $0.destinationURL) == 0o600
        })
        #expect(FileManager.default.fileExists(atPath: differentBundleURL.path))
        #expect(FileManager.default.fileExists(atPath: differentTeamURL.path))
        #expect(FileManager.default.fileExists(atPath: wildcardURL.path))
    }

    @Test
    func automaticMovesOnlyExpiredExactMatches() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let expiredURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "expired",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now
        )
        let activeURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "active",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(1)
        )

        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .automatic,
            deploymentToken: DeploymentToken.make().rawValue,
            now: now
        )

        #expect(transaction.backups.map {
            $0.originalURL.lastPathComponent
        } == [expiredURL.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        #expect(FileManager.default.fileExists(atPath: activeURL.path))
    }

    @Test
    func ignoresSymbolicLinksAndOversizedProfilesWithoutDecodingThem() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let targetURL = fixture.rootURL.appendingPathComponent("outside-profile")
        try Data("outside".utf8).write(to: targetURL)
        let symbolicLinkURL = fixture.xcodeDirectoryURL
            .appendingPathComponent("linked.mobileprovision")
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: targetURL
        )
        let oversizedURL = fixture.mobileDeviceDirectoryURL
            .appendingPathComponent("oversized.mobileprovision")
        try Data(repeating: 0x61, count: 65).write(to: oversizedURL)
        let decoder = ProfileDecoderRecorder()
        let manager = ProvisioningProfileCacheManager(
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL,
            limits: ProvisioningProfileCacheLimits(
                maximumDirectoryEntryCount: 16,
                maximumProfileBytes: 64,
                maximumDecodedProfileBytes: 1_024
            ),
            decodeProvisioningProfile: decoder.decode
        )

        let transaction = try await manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: DeploymentToken.make().rawValue,
            now: now
        )

        #expect(transaction.backups.isEmpty)
        #expect(decoder.paths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: symbolicLinkURL.path))
        #expect(FileManager.default.fileExists(atPath: oversizedURL.path))
    }

    @Test
    func rejectsEnumerationBeyondConfiguredLimit() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        try Data().write(
            to: fixture.xcodeDirectoryURL.appendingPathComponent("first.txt")
        )
        try Data().write(
            to: fixture.xcodeDirectoryURL.appendingPathComponent("second.txt")
        )
        let manager = ProvisioningProfileCacheManager(
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL,
            limits: ProvisioningProfileCacheLimits(
                maximumDirectoryEntryCount: 1,
                maximumProfileBytes: 1_024,
                maximumDecodedProfileBytes: 1_024
            ),
            decodeProvisioningProfile: fixture.decode
        )

        do {
            _ = try await manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("应拒绝超过枚举上限的缓存目录")
        } catch let error as ProvisioningProfileCacheError {
            guard case .directoryEntryLimitExceeded = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
        }
    }

    @Test
    func refusesExistingTransactionDirectoryWithoutOverwritingIt() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "matching",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let token = DeploymentToken.make().rawValue
        let collisionURL = fixture.backupRootURL.appendingPathComponent(
            token,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: collisionURL,
            withIntermediateDirectories: true
        )
        let markerURL = collisionURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: markerURL)

        do {
            _ = try await fixture.manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: token,
                now: now
            )
            Issue.record("应拒绝已存在的事务目录")
        } catch let error as ProvisioningProfileCacheError {
            guard case .backupCollision(let path) = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
            #expect(path == collisionURL.standardizedFileURL.path)
        }
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test
    func rollsBackEarlierMovesWhenAFollowingMoveFails() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let firstURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "first",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let secondURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "second",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let mover = FailingForwardMove(
            backupRootURL: fixture.backupRootURL,
            failingForwardMoveNumber: 2
        )
        let manager = ProvisioningProfileCacheManager(
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL,
            decodeProvisioningProfile: fixture.decode,
            moveItem: mover.move
        )

        do {
            _ = try await manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("第二次移动失败后不应返回事务")
        } catch let error as ProvisioningProfileCacheError {
            guard case .preparationFailed(_, let rollbackFailures) = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
            #expect(rollbackFailures.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(mover.forwardMoveCount == 2)
        #expect(mover.rollbackMoveCount == 1)
    }

    @Test
    func rollbackRestoresOnceAndRemainsIdempotent() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.writeProfileURL(
            location: .mobileDevice,
            name: "rollback",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: DeploymentToken.make().rawValue,
            now: now
        )
        let backupURL = try #require(transaction.backups.first?.destinationURL)

        try transaction.rollback()
        try transaction.rollback()
        try transaction.commit()

        #expect(transaction.state == .rolledBack)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test
    func commitPersistsCompletionThenRemovesControlledBackup() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let originalURL = try fixture.writeProfileURL(
            location: .mobileDevice,
            name: "commit",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: DeploymentToken.make().rawValue,
            now: now
        )
        let backupURL = try #require(transaction.backups.first?.destinationURL)

        try transaction.commit()
        try transaction.commit()
        try transaction.rollback()

        #expect(transaction.state == .committed)
        #expect(!FileManager.default.fileExists(atPath: originalURL.path))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: transaction.backupDirectoryURL.path
        ))
    }

    @Test
    func rejectsInvalidTokenBundleAndUnsafeOrDuplicateDirectories() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }

        await expectCacheError(.invalidDeploymentToken) {
            try await fixture.manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: "../unsafe",
                now: now
            )
        }
        await expectCacheError(.invalidBundleIdentifier) {
            try await fixture.manager.prepareTransaction(
                bundleIdentifier: "com.example.*",
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
        }
        await expectCacheError(.invalidTeamIdentifier) {
            try await fixture.manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                expectedTeamIdentifier: "team-unsafe",
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
        }

        let duplicateManager = ProvisioningProfileCacheManager(
            directories: ProvisioningProfileCacheDirectories(
                xcodeUserDataURL: fixture.xcodeDirectoryURL,
                mobileDeviceURL: fixture.xcodeDirectoryURL
            ),
            backupRootURL: fixture.backupRootURL,
            decodeProvisioningProfile: fixture.decode
        )
        await expectCacheError(.duplicateProfileDirectories) {
            try await duplicateManager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
        }

        let actualDirectoryURL = fixture.rootURL.appendingPathComponent(
            "actual-profile-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: actualDirectoryURL,
            withIntermediateDirectories: false
        )
        let linkedDirectoryURL = fixture.rootURL.appendingPathComponent(
            "linked-profile-directory",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectoryURL,
            withDestinationURL: actualDirectoryURL
        )
        let unsafeManager = ProvisioningProfileCacheManager(
            directories: ProvisioningProfileCacheDirectories(
                xcodeUserDataURL: linkedDirectoryURL,
                mobileDeviceURL: fixture.mobileDeviceDirectoryURL
            ),
            backupRootURL: fixture.backupRootURL,
            decodeProvisioningProfile: fixture.decode
        )
        do {
            _ = try await unsafeManager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("应拒绝包含符号链接的缓存目录")
        } catch let error as ProvisioningProfileCacheError {
            guard case .unsafePath = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
        }
    }

    @Test
    func productionDecoderInheritsDeploymentToken() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        _ = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "production-decoder",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let decodedProfile = try fixture.profileData(
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let executor = ProfileSecurityCommandExecutor(
            decodedProfile: String(decoding: decodedProfile, as: UTF8.self)
        )
        let manager = ProvisioningProfileCacheManager(
            commandExecutor: executor,
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL
        )
        let token = DeploymentToken.make().rawValue

        let transaction = try await manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: token,
            now: now
        )

        #expect(transaction.backups.count == 1)
        let invocation = try #require(executor.invocation)
        #expect(invocation.launchPath == "/usr/bin/security")
        #expect(invocation.arguments.prefix(3) == ["cms", "-D", "-i"])
        #expect(
            invocation.environment[
                DeploymentProcessRecovery.deploymentTokenEnvironmentKey
            ] == token
        )
    }

    @Test
    func decoderFailureFailsClosedWithoutMovingProfiles() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "decode-failure",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let manager = ProvisioningProfileCacheManager(
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL,
            decodeProvisioningProfile: { _, _ in
                throw CocoaError(.fileReadCorruptFile)
            }
        )

        do {
            _ = try await manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("解码失败时 force 不得静默继续")
        } catch let error as ProvisioningProfileCacheError {
            guard case .profileDecodeFailed(let fileName, _) = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
            #expect(fileName == sourceURL.lastPathComponent)
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test
    func decoderCancellationPropagatesWithoutMovingProfiles() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .mobileDevice,
            name: "decode-cancelled",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let manager = ProvisioningProfileCacheManager(
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL,
            decodeProvisioningProfile: { _, _ in
                throw CancellationError()
            }
        )

        do {
            _ = try await manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("取消不应被吞掉")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("取消被改写为其他错误：\(error)")
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test
    func oversizedDecodedProfileFailsClosedWithoutMovingProfiles() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "decoded-output-too-large",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let manager = ProvisioningProfileCacheManager(
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL,
            limits: ProvisioningProfileCacheLimits(
                maximumDirectoryEntryCount: 16,
                maximumProfileBytes: 4 * 1_024,
                maximumDecodedProfileBytes: 8
            ),
            decodeProvisioningProfile: { _, _ in
                Data(repeating: 0x61, count: 9)
            }
        )

        do {
            _ = try await manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("超限解码结果不得被静默跳过")
        } catch let error as ProvisioningProfileCacheError {
            #expect(error == .decodedProfileTooLarge(
                fileName: sourceURL.lastPathComponent,
                maximumBytes: 8
            ))
        }
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test
    func recoversMovedProfileFromPersistedActiveManifest() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "crash-recovery",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let token = DeploymentToken.make().rawValue
        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: token,
            now: now
        )
        let backupURL = try #require(transaction.backups.first?.destinationURL)
        let manifestURL = transaction.backupDirectoryURL.appendingPathComponent(
            "transaction-manifest.json"
        )
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(posixPermissions(at: manifestURL) == 0o600)

        let result = try fixture.manager.recoverInterruptedTransaction(
            deploymentToken: token
        )

        #expect(result == .restored(profileCount: 1))
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
        #expect(
            try fixture.manager.recoverInterruptedTransaction(
                deploymentToken: token
            ) == .alreadyRolledBack
        )
    }

    @Test
    func recoveryNeverOverwritesAnExistingOriginalPath() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .mobileDevice,
            name: "recovery-collision",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let token = DeploymentToken.make().rawValue
        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: token,
            now: now
        )
        let backupURL = try #require(transaction.backups.first?.destinationURL)
        let replacementData = Data("replacement-must-survive".utf8)
        try replacementData.write(to: sourceURL)

        do {
            _ = try fixture.manager.recoverInterruptedTransaction(
                deploymentToken: token
            )
            Issue.record("恢复不得覆盖已经重新出现的原路径")
        } catch let error as ProvisioningProfileCacheError {
            guard case .recoveryFailed = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
        }
        #expect(try Data(contentsOf: sourceURL) == replacementData)
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test
    func corruptedManifestFailsClosedAndLeavesBackupUntouched() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "corrupt-manifest",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let token = DeploymentToken.make().rawValue
        let transaction = try await fixture.manager.prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            refreshMode: .force,
            deploymentToken: token,
            now: now
        )
        let backupURL = try #require(transaction.backups.first?.destinationURL)
        let manifestURL = transaction.backupDirectoryURL.appendingPathComponent(
            "transaction-manifest.json"
        )
        try Data("tampered".utf8).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )

        do {
            _ = try fixture.manager.recoverInterruptedTransaction(
                deploymentToken: token
            )
            Issue.record("损坏的 manifest 必须失败关闭")
        } catch let error as ProvisioningProfileCacheError {
            guard case .manifestInvalid = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test
    func recoveryReportsNoManifestForEmptyTransaction() throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }

        #expect(
            try fixture.manager.recoverInterruptedTransaction(
                deploymentToken: DeploymentToken.make().rawValue
            ) == .noManifest
        )
    }

    @Test
    func securityProcessTreeUncertaintyIsPreserved() async throws {
        let fixture = try ProvisioningProfileCacheFixture()
        defer { fixture.remove() }
        _ = try fixture.writeProfileURL(
            location: .xcodeUserData,
            name: "unresolved-security-process",
            applicationIdentifier: "TEAM123456.com.example.Sample",
            expirationDate: now.addingTimeInterval(3_600)
        )
        let executor = ProfileSecurityCommandExecutor(
            decodedProfile: "ignored",
            processGroupTerminationWasConfirmed: false
        )
        let manager = ProvisioningProfileCacheManager(
            commandExecutor: executor,
            directories: fixture.directories,
            backupRootURL: fixture.backupRootURL
        )

        do {
            _ = try await manager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                expectedTeamIdentifier: "TEAM123456",
                refreshMode: .force,
                deploymentToken: DeploymentToken.make().rawValue,
                now: now
            )
            Issue.record("未确认结束的 security 进程树不得被降级为普通失败")
        } catch let error as ProvisioningProfileCacheError {
            guard case .commandProcessTreeUnresolved = error else {
                Issue.record("返回了错误类型：\(error)")
                return
            }
        }
    }

    private func expectCacheError(
        _ expected: ProvisioningProfileCacheError,
        operation: () async throws -> ProvisioningProfileCacheTransaction
    ) async {
        do {
            _ = try await operation()
            Issue.record("预期错误 \(expected)，实际成功")
        } catch let error as ProvisioningProfileCacheError {
            #expect(error == expected)
        } catch {
            Issue.record("返回了非预期错误：\(error)")
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func posixPermissions(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

private final class ProvisioningProfileCacheFixture: @unchecked Sendable {
    let rootURL: URL
    let xcodeDirectoryURL: URL
    let mobileDeviceDirectoryURL: URL
    let backupRootURL: URL

    var directories: ProvisioningProfileCacheDirectories {
        ProvisioningProfileCacheDirectories(
            xcodeUserDataURL: xcodeDirectoryURL,
            mobileDeviceURL: mobileDeviceDirectoryURL
        )
    }

    var manager: ProvisioningProfileCacheManager {
        ProvisioningProfileCacheManager(
            directories: directories,
            backupRootURL: backupRootURL,
            decodeProvisioningProfile: decode
        )
    }

    init() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        let temporaryDirectoryPath = temporaryDirectoryURL.path
        let canonicalTemporaryDirectoryURL = temporaryDirectoryPath == "/var"
            || temporaryDirectoryPath.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporaryDirectoryPath)
            : temporaryDirectoryURL
        rootURL = canonicalTemporaryDirectoryURL.appendingPathComponent(
            "ios-sign-kit-profile-cache-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        xcodeDirectoryURL = rootURL.appendingPathComponent(
            "xcode-profiles",
            isDirectory: true
        )
        mobileDeviceDirectoryURL = rootURL.appendingPathComponent(
            "mobile-device-profiles",
            isDirectory: true
        )
        backupRootURL = rootURL.appendingPathComponent(
            "backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: xcodeDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: mobileDeviceDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: backupRootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeProfile(
        location: ProvisioningProfileCacheLocation,
        name: String,
        applicationIdentifier: String,
        expirationDate: Date
    ) throws -> Data {
        let data = try profileData(
            applicationIdentifier: applicationIdentifier,
            expirationDate: expirationDate
        )
        try data.write(
            to: directoryURL(for: location).appendingPathComponent(
                "\(name).mobileprovision"
            )
        )
        return data
    }

    func writeProfileURL(
        location: ProvisioningProfileCacheLocation,
        name: String,
        applicationIdentifier: String,
        expirationDate: Date
    ) throws -> URL {
        let url = directoryURL(for: location).appendingPathComponent(
            "\(name).mobileprovision"
        )
        try profileData(
            applicationIdentifier: applicationIdentifier,
            expirationDate: expirationDate
        ).write(to: url)
        return url
    }

    func profileData(
        applicationIdentifier: String,
        expirationDate: Date
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "ExpirationDate": expirationDate,
                "Entitlements": [
                    "application-identifier": applicationIdentifier
                ]
            ],
            format: .xml,
            options: 0
        )
    }

    func decode(_ url: URL, _ deploymentToken: String) async throws -> Data {
        _ = deploymentToken
        return try Data(contentsOf: url)
    }

    private func directoryURL(
        for location: ProvisioningProfileCacheLocation
    ) -> URL {
        switch location {
        case .xcodeUserData:
            return xcodeDirectoryURL
        case .mobileDevice:
            return mobileDeviceDirectoryURL
        }
    }
}

private extension ProvisioningProfileCacheManager {
    func prepareTransaction(
        bundleIdentifier: String,
        refreshMode: ProvisioningProfileRefreshMode,
        deploymentToken: String,
        now: Date
    ) async throws -> ProvisioningProfileCacheTransaction {
        try await prepareTransaction(
            bundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: "TEAM123456",
            refreshMode: refreshMode,
            deploymentToken: deploymentToken,
            now: now
        )
    }
}

private final class ProfileDecoderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        lock.withLock { storedPaths }
    }

    func decode(_ url: URL, _ deploymentToken: String) async throws -> Data {
        _ = deploymentToken
        lock.withLock {
            storedPaths.append(url.path)
        }
        return try Data(contentsOf: url)
    }
}

private final class FailingForwardMove: @unchecked Sendable {
    private let lock = NSLock()
    private let backupRootPath: String
    private let failingForwardMoveNumber: Int
    private var storedForwardMoveCount = 0
    private var storedRollbackMoveCount = 0

    var forwardMoveCount: Int {
        lock.withLock { storedForwardMoveCount }
    }

    var rollbackMoveCount: Int {
        lock.withLock { storedRollbackMoveCount }
    }

    init(
        backupRootURL: URL,
        failingForwardMoveNumber: Int
    ) {
        backupRootPath = backupRootURL.standardizedFileURL.path + "/"
        self.failingForwardMoveNumber = failingForwardMoveNumber
    }

    func move(_ sourceURL: URL, _ destinationURL: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            if destinationURL.standardizedFileURL.path.hasPrefix(backupRootPath) {
                storedForwardMoveCount += 1
                return storedForwardMoveCount == failingForwardMoveNumber
            }
            storedRollbackMoveCount += 1
            return false
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }
}

private final class ProfileSecurityCommandExecutor: CommandExecuting, @unchecked Sendable {
    struct Invocation: Sendable {
        let launchPath: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private let decodedProfile: String
    private let processGroupTerminationWasConfirmed: Bool
    private var storedInvocation: Invocation?

    var invocation: Invocation? {
        lock.withLock { storedInvocation }
    }

    init(
        decodedProfile: String,
        processGroupTerminationWasConfirmed: Bool = true
    ) {
        self.decodedProfile = decodedProfile
        self.processGroupTerminationWasConfirmed =
            processGroupTerminationWasConfirmed
    }

    func run(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String],
        onOutput: (@Sendable (String, Bool) -> Void)?,
        timeoutSeconds: TimeInterval?
    ) throws -> CommandResult {
        fatalError("同步命令不应被调用")
    }

    func runAsync(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String],
        onOutput: (@Sendable (String, Bool) -> Void)?,
        timeoutSeconds: TimeInterval?
    ) async throws -> CommandResult {
        _ = currentDirectoryPath
        _ = onOutput
        _ = timeoutSeconds
        lock.withLock {
            storedInvocation = Invocation(
                launchPath: launchPath,
                arguments: arguments,
                environment: environmentOverrides
            )
        }
        return CommandResult(
            standardOutput: decodedProfile,
            standardError: "",
            terminationStatus: 0,
            processGroupTerminationWasConfirmed:
                processGroupTerminationWasConfirmed
        )
    }

    func start(
        _ launchPath: String,
        arguments: [String],
        currentDirectoryPath: String?,
        environmentOverrides: [String: String],
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) throws -> RunningCommand {
        fatalError("启动式命令不应被调用")
    }
}
