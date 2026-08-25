import CryptoKit
import Darwin
import Foundation

enum ProvisioningProfileCacheLocation: String, CaseIterable, Codable, Sendable {
    case xcodeUserData = "xcode-user-data"
    case mobileDevice = "mobile-device"
}

struct ProvisioningProfileCacheDirectories: Equatable, Sendable {
    let xcodeUserDataURL: URL
    let mobileDeviceURL: URL

    static var production: ProvisioningProfileCacheDirectories {
        let libraryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
        return ProvisioningProfileCacheDirectories(
            xcodeUserDataURL: libraryURL
                .appendingPathComponent("Developer", isDirectory: true)
                .appendingPathComponent("Xcode", isDirectory: true)
                .appendingPathComponent("UserData", isDirectory: true)
                .appendingPathComponent("Provisioning Profiles", isDirectory: true),
            mobileDeviceURL: libraryURL
                .appendingPathComponent("MobileDevice", isDirectory: true)
                .appendingPathComponent("Provisioning Profiles", isDirectory: true)
        )
    }

    fileprivate var entries: [ProvisioningProfileCacheDirectory] {
        [
            ProvisioningProfileCacheDirectory(
                location: .xcodeUserData,
                url: xcodeUserDataURL
            ),
            ProvisioningProfileCacheDirectory(
                location: .mobileDevice,
                url: mobileDeviceURL
            )
        ]
    }
}

struct ProvisioningProfileCacheLimits: Equatable, Sendable {
    static let production = ProvisioningProfileCacheLimits(
        maximumDirectoryEntryCount: 4_096,
        maximumProfileBytes: 4 * 1_024 * 1_024,
        maximumDecodedProfileBytes: 1 * 1_024 * 1_024
    )

    let maximumDirectoryEntryCount: Int
    let maximumProfileBytes: Int
    let maximumDecodedProfileBytes: Int

    fileprivate var isValid: Bool {
        maximumDirectoryEntryCount > 0
            && maximumDirectoryEntryCount <= 100_000
            && maximumProfileBytes > 0
            && maximumDecodedProfileBytes > 0
            && maximumProfileBytes < Int.max
            && maximumDecodedProfileBytes < Int.max
    }
}

struct ProvisioningProfileCacheBackup: Equatable, Sendable {
    let location: ProvisioningProfileCacheLocation
    let originalURL: URL
    let destinationURL: URL
    let sha256Digest: String
    let expirationDate: Date
}

enum ProvisioningProfileCacheTransactionState: Equatable, Sendable {
    case active
    case committed
    case rolledBack
}

enum ProvisioningProfileCacheRecoveryResult: Equatable, Sendable {
    case noManifest
    case alreadyCommitted(backupCount: Int)
    case alreadyRolledBack
    case restored(profileCount: Int)
}

enum ProvisioningProfileCacheError: Error, Equatable, LocalizedError, Sendable {
    case invalidBundleIdentifier
    case invalidTeamIdentifier
    case invalidDeploymentToken
    case invalidLimits
    case duplicateProfileDirectories
    case unsafePath(String)
    case directoryEnumerationFailed(String)
    case directoryEntryLimitExceeded(String)
    case backupCollision(String)
    case profileDecodeFailed(fileName: String, reason: String)
    case decodedProfileTooLarge(fileName: String, maximumBytes: Int)
    case profileChanged(String)
    case commandProcessTreeUnresolved(String)
    case manifestInvalid(String)
    case manifestWriteFailed(String)
    case recoveryFailed(String)
    case preparationFailed(reason: String, rollbackFailures: [String])
    case rollbackIncomplete([String])

    var errorDescription: String? {
        switch self {
        case .invalidBundleIdentifier:
            return "目标 Bundle ID 无效，已停止处理签名描述文件缓存。"
        case .invalidTeamIdentifier:
            return "目标开发团队标识无效，已停止处理签名描述文件缓存。"
        case .invalidDeploymentToken:
            return "续签事务令牌无效，已停止处理签名描述文件缓存。"
        case .invalidLimits:
            return "签名描述文件缓存扫描上限无效。"
        case .duplicateProfileDirectories:
            return "两个签名描述文件缓存目录指向同一路径。"
        case .unsafePath(let path):
            return "签名描述文件缓存路径不安全：\(path)"
        case .directoryEnumerationFailed(let path):
            return "无法枚举签名描述文件缓存目录：\(path)"
        case .directoryEntryLimitExceeded(let path):
            return "签名描述文件缓存目录条目数量超过安全上限：\(path)"
        case .backupCollision(let path):
            return "签名描述文件备份路径已存在，未覆盖原内容：\(path)"
        case .profileDecodeFailed(let fileName, let reason):
            return "无法解码签名描述文件 \(fileName)：\(reason)"
        case .decodedProfileTooLarge(let fileName, let maximumBytes):
            return "签名描述文件 \(fileName) 的解码结果超过 \(maximumBytes) 字节上限。"
        case .profileChanged(let name):
            return "签名描述文件在扫描期间发生变化：\(name)"
        case .commandProcessTreeUnresolved(let diagnostic):
            return "签名描述文件解码进程树未确认结束：\(diagnostic)"
        case .manifestInvalid(let reason):
            return "签名描述文件缓存事务记录无效：\(reason)"
        case .manifestWriteFailed(let reason):
            return "无法持久化签名描述文件缓存事务：\(reason)"
        case .recoveryFailed(let reason):
            return "无法恢复未完成的签名描述文件缓存事务：\(reason)"
        case .preparationFailed(let reason, let rollbackFailures):
            let suffix = rollbackFailures.isEmpty
                ? ""
                : "；回滚未完全完成：\(rollbackFailures.joined(separator: "；"))"
            return "无法隔离签名描述文件缓存：\(reason)\(suffix)"
        case .rollbackIncomplete(let failures):
            return "签名描述文件缓存回滚未完全完成：\(failures.joined(separator: "；"))"
        }
    }
}

private enum ProvisioningProfileCacheManifestState: String, Codable, Sendable {
    case preparing
    case active
    case rollingBack
    case committed
    case rolledBack
}

private enum ProvisioningProfileCacheManifestItemState: String, Codable, Sendable {
    case planned
    case moved
    case restoring
    case restored
}

private struct ProvisioningProfileCacheManifestItem: Codable, Equatable, Sendable {
    let location: ProvisioningProfileCacheLocation
    let originalPath: String
    let destinationPath: String
    let sha256Digest: String
    let expirationDate: Date
    var state: ProvisioningProfileCacheManifestItemState

    init(
        backup: ProvisioningProfileCacheBackup,
        state: ProvisioningProfileCacheManifestItemState
    ) {
        location = backup.location
        originalPath = backup.originalURL.path
        destinationPath = backup.destinationURL.path
        sha256Digest = backup.sha256Digest
        expirationDate = backup.expirationDate
        self.state = state
    }
}

private struct ProvisioningProfileCacheManifestPayload:
    Codable,
    Equatable,
    Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let deploymentToken: String
    let bundleIdentifier: String
    let teamIdentifier: String
    var state: ProvisioningProfileCacheManifestState
    var items: [ProvisioningProfileCacheManifestItem]
}

private struct ProvisioningProfileCacheManifestEnvelope: Codable, Sendable {
    let payload: Data
    let sha256Digest: String
}

private final class ProvisioningProfileCacheManifestStore: @unchecked Sendable {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    static let fileName = "transaction-manifest.json"
    static let maximumManifestBytes = 1 * 1_024 * 1_024

    let url: URL

    var snapshot: ProvisioningProfileCacheManifestPayload {
        lock.withLock { payload }
    }

    private let lock = NSLock()
    private let writer: Writer
    private var payload: ProvisioningProfileCacheManifestPayload

    init(
        creatingAt url: URL,
        deploymentToken: String,
        bundleIdentifier: String,
        teamIdentifier: String,
        writer: @escaping Writer
    ) throws {
        self.url = url
        self.writer = writer
        payload = ProvisioningProfileCacheManifestPayload(
            schemaVersion: ProvisioningProfileCacheManifestPayload.schemaVersion,
            deploymentToken: deploymentToken,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            state: .preparing,
            items: []
        )
        guard !SecureProvisioningProfilePath.entryExists(url) else {
            throw ProvisioningProfileCacheError.backupCollision(url.path)
        }
        try Self.writeAndVerify(payload, to: url, writer: writer)
    }

    init(loadingAt url: URL, writer: @escaping Writer) throws {
        self.url = url
        self.writer = writer
        payload = try Self.readAndVerify(from: url)
    }

    func plan(_ backup: ProvisioningProfileCacheBackup) throws {
        try update { payload in
            guard !payload.items.contains(where: {
                $0.originalPath == backup.originalURL.path
                    || $0.destinationPath == backup.destinationURL.path
            }) else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "存在重复的 Profile 映射。"
                )
            }
            payload.items.append(
                ProvisioningProfileCacheManifestItem(
                    backup: backup,
                    state: .planned
                )
            )
        }
    }

    func markMoved(_ backup: ProvisioningProfileCacheBackup) throws {
        try updateItem(backup, state: .moved)
    }

    func markRestoring(_ backup: ProvisioningProfileCacheBackup) throws {
        try update { payload in
            payload.state = .rollingBack
            try Self.setItemState(
                backup,
                state: .restoring,
                in: &payload
            )
        }
    }

    func markRestored(_ backup: ProvisioningProfileCacheBackup) throws {
        try updateItem(backup, state: .restored)
    }

    func markActive() throws {
        try update { payload in
            payload.state = .active
        }
    }

    func markCommitted() throws {
        try update { payload in
            payload.state = .committed
        }
    }

    func markRolledBack() throws {
        try update { payload in
            payload.state = .rolledBack
            for index in payload.items.indices {
                payload.items[index].state = .restored
            }
        }
    }

    private func updateItem(
        _ backup: ProvisioningProfileCacheBackup,
        state: ProvisioningProfileCacheManifestItemState
    ) throws {
        try update { payload in
            try Self.setItemState(backup, state: state, in: &payload)
        }
    }

    private func update(
        _ transform: (inout ProvisioningProfileCacheManifestPayload) throws -> Void
    ) throws {
        try lock.withLock {
            var nextPayload = payload
            try transform(&nextPayload)
            try Self.writeAndVerify(
                nextPayload,
                to: url,
                writer: writer
            )
            payload = nextPayload
        }
    }

    private static func setItemState(
        _ backup: ProvisioningProfileCacheBackup,
        state: ProvisioningProfileCacheManifestItemState,
        in payload: inout ProvisioningProfileCacheManifestPayload
    ) throws {
        guard let index = payload.items.firstIndex(where: {
            $0.originalPath == backup.originalURL.path
                && $0.destinationPath == backup.destinationURL.path
                && $0.sha256Digest == backup.sha256Digest
        }) else {
            throw ProvisioningProfileCacheError.manifestInvalid(
                "找不到待更新的 Profile 映射。"
            )
        }
        payload.items[index].state = state
    }

    private static func writeAndVerify(
        _ payload: ProvisioningProfileCacheManifestPayload,
        to url: URL,
        writer: Writer
    ) throws {
        do {
            if SecureProvisioningProfilePath.entryExists(url),
               !SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    url,
                    maximumBytes: maximumManifestBytes
               ) {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "manifest 路径不是受控普通文件。"
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let payloadData = try encoder.encode(payload)
            let envelope = ProvisioningProfileCacheManifestEnvelope(
                payload: payloadData,
                sha256Digest: SecureProvisioningProfilePath.sha256Hex(
                    payloadData
                )
            )
            let envelopeData = try encoder.encode(envelope)
            guard envelopeData.count <= maximumManifestBytes else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "manifest 超过允许的字节上限。"
                )
            }
            try writer(envelopeData, url)
            try SecureProvisioningProfilePath.setPOSIXPermissions(
                0o600,
                at: url
            )
            guard SecureProvisioningProfilePath.hasPOSIXPermissions(
                0o600,
                at: url
            ), try readAndVerify(from: url) == payload else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "原子写入后的 manifest 无法验证。"
                )
            }
        } catch let error as ProvisioningProfileCacheError {
            throw error
        } catch {
            throw ProvisioningProfileCacheError.manifestWriteFailed(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
    }

    private static func readAndVerify(
        from url: URL
    ) throws -> ProvisioningProfileCacheManifestPayload {
        guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
            url,
            maximumBytes: maximumManifestBytes
        ) else {
            throw ProvisioningProfileCacheError.manifestInvalid(
                "manifest 不存在、不是普通文件或超过大小上限。"
            )
        }
        do {
            let data = try BoundedFileReader().data(
                at: url,
                maximumBytes: maximumManifestBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(
                ProvisioningProfileCacheManifestEnvelope.self,
                from: data
            )
            guard SecureProvisioningProfilePath.sha256Hex(envelope.payload)
                    == envelope.sha256Digest else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "manifest 摘要不匹配。"
                )
            }
            let payload = try decoder.decode(
                ProvisioningProfileCacheManifestPayload.self,
                from: envelope.payload
            )
            guard payload.schemaVersion
                    == ProvisioningProfileCacheManifestPayload.schemaVersion else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "manifest schema 不受支持。"
                )
            }
            return payload
        } catch let error as ProvisioningProfileCacheError {
            throw error
        } catch {
            throw ProvisioningProfileCacheError.manifestInvalid(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
    }
}

final class ProvisioningProfileCacheTransaction: @unchecked Sendable {
    typealias MoveItem = @Sendable (URL, URL) throws -> Void

    let backupDirectoryURL: URL
    let backups: [ProvisioningProfileCacheBackup]

    var previousProfileDigests: Set<String> {
        Set(backups.map(\.sha256Digest))
    }

    var state: ProvisioningProfileCacheTransactionState {
        lock.withLock { storage.state }
    }

    private struct Storage {
        var state = ProvisioningProfileCacheTransactionState.active
        var pendingBackupIndices: Set<Int>
    }

    private let lock = NSLock()
    private let moveItem: MoveItem
    private let maximumProfileBytes: Int
    private let manifestStore: ProvisioningProfileCacheManifestStore?
    private var storage: Storage

    fileprivate init(
        backupDirectoryURL: URL,
        backups: [ProvisioningProfileCacheBackup],
        maximumProfileBytes: Int,
        manifestStore: ProvisioningProfileCacheManifestStore?,
        moveItem: @escaping MoveItem
    ) {
        self.backupDirectoryURL = backupDirectoryURL
        self.backups = backups
        self.maximumProfileBytes = maximumProfileBytes
        self.manifestStore = manifestStore
        self.moveItem = moveItem
        storage = Storage(
            pendingBackupIndices: Set(backups.indices)
        )
    }

    func commit() throws {
        try lock.withLock {
            guard storage.state == .active else {
                return
            }
            try manifestStore?.markCommitted()
            storage.state = .committed
            cleanupCommittedBackups()
        }
    }

    func rollback() throws {
        try lock.withLock {
            guard storage.state == .active else {
                return
            }

            let failures = Self.restore(
                backups: backups,
                pendingBackupIndices: &storage.pendingBackupIndices,
                maximumProfileBytes: maximumProfileBytes,
                moveItem: moveItem,
                willRestore: { [manifestStore] backup in
                    try manifestStore?.markRestoring(backup)
                },
                didRestore: { [manifestStore] backup in
                    try manifestStore?.markRestored(backup)
                }
            )
            guard failures.isEmpty else {
                throw ProvisioningProfileCacheError.rollbackIncomplete(failures)
            }
            do {
                try manifestStore?.markRolledBack()
            } catch {
                throw ProvisioningProfileCacheError.rollbackIncomplete([
                    DiagnosticText.bounded(error.localizedDescription)
                ])
            }
            storage.state = .rolledBack
        }
    }

    fileprivate static func restore(
        backups: [ProvisioningProfileCacheBackup],
        pendingBackupIndices: inout Set<Int>,
        maximumProfileBytes: Int,
        moveItem: MoveItem,
        willRestore: ((ProvisioningProfileCacheBackup) throws -> Void)? = nil,
        didRestore: ((ProvisioningProfileCacheBackup) throws -> Void)? = nil
    ) -> [String] {
        var failures: [String] = []
        for index in pendingBackupIndices.sorted(by: >) {
            let backup = backups[index]
            let destinationExists = SecureProvisioningProfilePath.entryExists(
                backup.destinationURL
            )
            let originalExists = SecureProvisioningProfilePath.entryExists(
                backup.originalURL
            )

            if !destinationExists {
                if originalExists,
                   SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                       backup.originalURL,
                       maximumBytes: maximumProfileBytes
                   ),
                   SecureProvisioningProfilePath.sha256Hex(
                       at: backup.originalURL,
                       maximumBytes: maximumProfileBytes
                   ) == backup.sha256Digest {
                    do {
                        try didRestore?(backup)
                        pendingBackupIndices.remove(index)
                    } catch {
                        failures.append(
                            "无法记录已恢复状态："
                                + DiagnosticText.bounded(error.localizedDescription)
                        )
                    }
                } else {
                    failures.append(
                        "备份和原文件均无法确认：\(backup.originalURL.lastPathComponent)"
                    )
                }
                continue
            }

            guard !originalExists else {
                failures.append(
                    "原路径已存在，未覆盖：\(backup.originalURL.path)"
                )
                continue
            }
            guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                backup.destinationURL,
                maximumBytes: maximumProfileBytes
            ),
                  SecureProvisioningProfilePath.sha256Hex(
                    at: backup.destinationURL,
                    maximumBytes: maximumProfileBytes
                  ) == backup.sha256Digest else {
                failures.append(
                    "备份内容无法验证：\(backup.destinationURL.path)"
                )
                continue
            }

            do {
                try willRestore?(backup)
                try moveItem(backup.destinationURL, backup.originalURL)
                guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    backup.originalURL,
                    maximumBytes: maximumProfileBytes
                ),
                      SecureProvisioningProfilePath.sha256Hex(
                        at: backup.originalURL,
                        maximumBytes: maximumProfileBytes
                      ) == backup.sha256Digest else {
                    failures.append(
                        "恢复后内容无法验证：\(backup.originalURL.path)"
                    )
                    continue
                }
                try didRestore?(backup)
                pendingBackupIndices.remove(index)
            } catch {
                failures.append(
                    "无法恢复 \(backup.originalURL.lastPathComponent)："
                        + DiagnosticText.bounded(error.localizedDescription)
                )
            }
        }
        return failures
    }

    private func cleanupCommittedBackups() {
        guard let manifestStore,
              manifestStore.snapshot.state == .committed,
              DeploymentToken(
                rawValue: backupDirectoryURL.lastPathComponent
              ) != nil,
              SecureProvisioningProfilePath.isDirectoryWithoutSymbolicLinks(
                backupDirectoryURL
              ), SecureProvisioningProfilePath.hasPOSIXPermissions(
                0o700,
                at: backupDirectoryURL
              ) else {
            return
        }

        for backup in backups {
            let locationDirectoryURL = backupDirectoryURL
                .appendingPathComponent(
                    backup.location.rawValue,
                    isDirectory: true
                )
                .standardizedFileURL
            guard backup.destinationURL.deletingLastPathComponent()
                    .standardizedFileURL.path == locationDirectoryURL.path,
                  SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    backup.destinationURL,
                    maximumBytes: maximumProfileBytes
                  ), SecureProvisioningProfilePath.sha256Hex(
                    at: backup.destinationURL,
                    maximumBytes: maximumProfileBytes
                  ) == backup.sha256Digest else {
                continue
            }
            try? FileManager.default.removeItem(at: backup.destinationURL)
        }

        guard backups.allSatisfy({
            !SecureProvisioningProfilePath.entryExists($0.destinationURL)
        }) else {
            return
        }
        for location in Set(backups.map(\.location)) {
            let locationDirectoryURL = backupDirectoryURL.appendingPathComponent(
                location.rawValue,
                isDirectory: true
            )
            guard SecureProvisioningProfilePath.isDirectoryWithoutSymbolicLinks(
                locationDirectoryURL
            ), (try? FileManager.default.contentsOfDirectory(
                at: locationDirectoryURL,
                includingPropertiesForKeys: nil,
                options: []
            ).isEmpty) == true else {
                continue
            }
            try? FileManager.default.removeItem(at: locationDirectoryURL)
        }

        guard let remainingEntries = try? FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ), remainingEntries.count == 1,
              remainingEntries[0].standardizedFileURL.path
                == manifestStore.url.standardizedFileURL.path else {
            return
        }
        guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
            manifestStore.url,
            maximumBytes:
                ProvisioningProfileCacheManifestStore.maximumManifestBytes
        ) else {
            return
        }
        try? FileManager.default.removeItem(at: manifestStore.url)
        guard (try? FileManager.default.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty) == true else {
            return
        }
        try? FileManager.default.removeItem(at: backupDirectoryURL)
    }
}

struct ProvisioningProfileCacheManager: Sendable {
    typealias Decoder = @Sendable (URL, String) async throws -> Data
    typealias MoveItem = ProvisioningProfileCacheTransaction.MoveItem
    typealias ManifestWriter = @Sendable (Data, URL) throws -> Void

    private let directories: ProvisioningProfileCacheDirectories
    private let backupRootURL: URL
    private let limits: ProvisioningProfileCacheLimits
    private let decodeProvisioningProfile: Decoder
    private let moveItem: MoveItem
    private let manifestWriter: ManifestWriter

    static var productionBackupRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("iOSSignKit", isDirectory: true)
            .appendingPathComponent(
                "Provisioning Profile Backups",
                isDirectory: true
            )
    }

    init(
        commandExecutor: any CommandExecuting = CommandRunner(),
        directories: ProvisioningProfileCacheDirectories = .production,
        backupRootURL: URL = Self.productionBackupRootURL,
        limits: ProvisioningProfileCacheLimits = .production
    ) {
        self.directories = directories
        self.backupRootURL = backupRootURL
        self.limits = limits
        manifestWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
        decodeProvisioningProfile = { profileURL, deploymentToken in
            let result = try await commandExecutor.runAsync(
                "/usr/bin/security",
                arguments: ["cms", "-D", "-i", profileURL.path],
                currentDirectoryPath: nil,
                environmentOverrides: [
                    DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                        deploymentToken
                ],
                onOutput: nil,
                timeoutSeconds: 10
            )
            guard result.processGroupTerminationWasConfirmed else {
                let diagnostic = result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
                throw ProvisioningProfileCacheError.commandProcessTreeUnresolved(
                    DiagnosticText.bounded(
                        diagnostic.isEmpty
                            ? "security cms 的完整进程树仍可能运行。"
                            : diagnostic
                    )
                )
            }
            guard result.completedSuccessfullyAndFullyTerminated,
                  !result.standardOutputWasTruncated,
                  !result.standardErrorWasTruncated else {
                let diagnostic = result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
                throw ProvisioningProfileCacheError.preparationFailed(
                    reason: DiagnosticText.bounded(
                        diagnostic.isEmpty
                            ? "security cms 返回退出状态 \(result.terminationStatus)。"
                            : diagnostic
                    ),
                    rollbackFailures: []
                )
            }
            return Data(result.standardOutput.utf8)
        }
        moveItem = { sourceURL, destinationURL in
            try FileManager.default.moveItem(
                at: sourceURL,
                to: destinationURL
            )
        }
    }

    init(
        directories: ProvisioningProfileCacheDirectories,
        backupRootURL: URL,
        limits: ProvisioningProfileCacheLimits = .production,
        decodeProvisioningProfile: @escaping Decoder,
        moveItem: @escaping MoveItem = { sourceURL, destinationURL in
            try FileManager.default.moveItem(
                at: sourceURL,
                to: destinationURL
            )
        },
        manifestWriter: @escaping ManifestWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.directories = directories
        self.backupRootURL = backupRootURL
        self.limits = limits
        self.decodeProvisioningProfile = decodeProvisioningProfile
        self.moveItem = moveItem
        self.manifestWriter = manifestWriter
    }

    func prepareTransaction(
        bundleIdentifier: String,
        expectedTeamIdentifier: String,
        refreshMode: ProvisioningProfileRefreshMode,
        deploymentToken: String,
        now: Date = Date()
    ) async throws -> ProvisioningProfileCacheTransaction {
        try Task.checkCancellation()
        guard Self.isValidBundleIdentifier(bundleIdentifier) else {
            throw ProvisioningProfileCacheError.invalidBundleIdentifier
        }
        guard DevelopmentTeamIdentifier(
            rawValue: expectedTeamIdentifier
        ) != nil else {
            throw ProvisioningProfileCacheError.invalidTeamIdentifier
        }
        guard DeploymentToken(rawValue: deploymentToken) != nil else {
            throw ProvisioningProfileCacheError.invalidDeploymentToken
        }
        guard limits.isValid else {
            throw ProvisioningProfileCacheError.invalidLimits
        }

        let validatedDirectories = try validateDirectories()
        let validatedBackupRootURL = try validateBackupRoot(
            against: validatedDirectories
        )
        let backupDirectoryURL = validatedBackupRootURL.appendingPathComponent(
            deploymentToken,
            isDirectory: true
        )
        guard backupDirectoryURL.deletingLastPathComponent().standardizedFileURL.path
                == validatedBackupRootURL.path else {
            throw ProvisioningProfileCacheError.unsafePath(
                backupDirectoryURL.path
            )
        }

        let candidates = try await matchingCandidates(
            in: validatedDirectories,
            bundleIdentifier: bundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            refreshMode: refreshMode,
            deploymentToken: deploymentToken,
            now: now
        )
        try Task.checkCancellation()
        guard !candidates.isEmpty else {
            return ProvisioningProfileCacheTransaction(
                backupDirectoryURL: backupDirectoryURL,
                backups: [],
                maximumProfileBytes: limits.maximumProfileBytes,
                manifestStore: nil,
                moveItem: moveItem
            )
        }

        guard !SecureProvisioningProfilePath.entryExists(backupDirectoryURL) else {
            throw ProvisioningProfileCacheError.backupCollision(
                backupDirectoryURL.path
            )
        }

        do {
            try SecureProvisioningProfilePath.createDirectoryIfNeeded(
                validatedBackupRootURL
            )
            guard !SecureProvisioningProfilePath.entryExists(backupDirectoryURL) else {
                throw ProvisioningProfileCacheError.backupCollision(
                    backupDirectoryURL.path
                )
            }
            try FileManager.default.createDirectory(
                at: backupDirectoryURL,
                withIntermediateDirectories: false
            )
            try SecureProvisioningProfilePath.setPOSIXPermissions(
                0o700,
                at: backupDirectoryURL
            )
            guard SecureProvisioningProfilePath.isDirectoryWithoutSymbolicLinks(
                backupDirectoryURL
            ), SecureProvisioningProfilePath.hasPOSIXPermissions(
                0o700,
                at: backupDirectoryURL
            ) else {
                throw ProvisioningProfileCacheError.unsafePath(
                    backupDirectoryURL.path
                )
            }
        } catch let error as ProvisioningProfileCacheError {
            throw error
        } catch {
            throw ProvisioningProfileCacheError.preparationFailed(
                reason: DiagnosticText.bounded(error.localizedDescription),
                rollbackFailures: []
            )
        }

        let manifestStore = try ProvisioningProfileCacheManifestStore(
            creatingAt: backupDirectoryURL.appendingPathComponent(
                ProvisioningProfileCacheManifestStore.fileName
            ),
            deploymentToken: deploymentToken,
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: expectedTeamIdentifier,
            writer: manifestWriter
        )

        var locationDirectories: [ProvisioningProfileCacheLocation: URL] = [:]
        var backups: [ProvisioningProfileCacheBackup] = []
        do {
            for candidate in candidates {
                try Task.checkCancellation()
                let locationDirectoryURL: URL
                if let existing = locationDirectories[candidate.location] {
                    locationDirectoryURL = existing
                } else {
                    let newURL = backupDirectoryURL.appendingPathComponent(
                        candidate.location.rawValue,
                        isDirectory: true
                    )
                    guard !SecureProvisioningProfilePath.entryExists(newURL) else {
                        throw ProvisioningProfileCacheError.backupCollision(
                            newURL.path
                        )
                    }
                    try FileManager.default.createDirectory(
                        at: newURL,
                        withIntermediateDirectories: false
                    )
                    try SecureProvisioningProfilePath.setPOSIXPermissions(
                        0o700,
                        at: newURL
                    )
                    guard SecureProvisioningProfilePath.isDirectoryWithoutSymbolicLinks(
                        newURL
                    ), SecureProvisioningProfilePath.hasPOSIXPermissions(
                        0o700,
                        at: newURL
                    ) else {
                        throw ProvisioningProfileCacheError.unsafePath(newURL.path)
                    }
                    locationDirectories[candidate.location] = newURL
                    locationDirectoryURL = newURL
                }

                let destinationURL = locationDirectoryURL.appendingPathComponent(
                    candidate.url.lastPathComponent,
                    isDirectory: false
                )
                guard destinationURL.deletingLastPathComponent()
                        .standardizedFileURL.path
                        == locationDirectoryURL.standardizedFileURL.path else {
                    throw ProvisioningProfileCacheError.unsafePath(
                        destinationURL.path
                    )
                }
                guard !SecureProvisioningProfilePath.entryExists(
                    destinationURL
                ) else {
                    throw ProvisioningProfileCacheError.backupCollision(
                        destinationURL.path
                    )
                }
                guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    candidate.url,
                    maximumBytes: limits.maximumProfileBytes
                ),
                      SecureProvisioningProfilePath.sha256Hex(
                        at: candidate.url,
                        maximumBytes: limits.maximumProfileBytes
                      ) == candidate.sha256Digest else {
                    throw ProvisioningProfileCacheError.profileChanged(
                        candidate.url.lastPathComponent
                    )
                }

                let backup = ProvisioningProfileCacheBackup(
                    location: candidate.location,
                    originalURL: candidate.url.standardizedFileURL,
                    destinationURL: destinationURL.standardizedFileURL,
                    sha256Digest: candidate.sha256Digest,
                    expirationDate: candidate.expirationDate
                )
                try manifestStore.plan(backup)
                backups.append(backup)
                try Task.checkCancellation()
                try moveItem(candidate.url, destinationURL)
                try SecureProvisioningProfilePath.setPOSIXPermissions(
                    0o600,
                    at: destinationURL
                )
                guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    destinationURL,
                    maximumBytes: limits.maximumProfileBytes
                ), SecureProvisioningProfilePath.hasPOSIXPermissions(
                    0o600,
                    at: destinationURL
                ),
                      SecureProvisioningProfilePath.sha256Hex(
                        at: destinationURL,
                        maximumBytes: limits.maximumProfileBytes
                      ) == candidate.sha256Digest else {
                    throw ProvisioningProfileCacheError.profileChanged(
                        candidate.url.lastPathComponent
                    )
                }
                try manifestStore.markMoved(backup)
            }
            try manifestStore.markActive()
        } catch {
            var pendingIndices = Set(backups.indices)
            let rollbackFailures = ProvisioningProfileCacheTransaction.restore(
                backups: backups,
                pendingBackupIndices: &pendingIndices,
                maximumProfileBytes: limits.maximumProfileBytes,
                moveItem: moveItem,
                willRestore: { backup in
                    try manifestStore.markRestoring(backup)
                },
                didRestore: { backup in
                    try manifestStore.markRestored(backup)
                }
            )
            var finalRollbackFailures = rollbackFailures
            if finalRollbackFailures.isEmpty {
                do {
                    try manifestStore.markRolledBack()
                } catch {
                    finalRollbackFailures.append(
                        DiagnosticText.bounded(error.localizedDescription)
                    )
                }
            }
            if error is CancellationError,
               finalRollbackFailures.isEmpty {
                throw CancellationError()
            }
            throw ProvisioningProfileCacheError.preparationFailed(
                reason: DiagnosticText.bounded(error.localizedDescription),
                rollbackFailures: finalRollbackFailures
            )
        }

        return ProvisioningProfileCacheTransaction(
            backupDirectoryURL: backupDirectoryURL,
            backups: backups,
            maximumProfileBytes: limits.maximumProfileBytes,
            manifestStore: manifestStore,
            moveItem: moveItem
        )
    }

    func recoverInterruptedTransaction(
        deploymentToken: String
    ) throws -> ProvisioningProfileCacheRecoveryResult {
        guard DeploymentToken(rawValue: deploymentToken) != nil else {
            throw ProvisioningProfileCacheError.invalidDeploymentToken
        }
        guard limits.isValid else {
            throw ProvisioningProfileCacheError.invalidLimits
        }
        let validatedDirectories = try validateDirectories()
        let validatedBackupRootURL = try validateBackupRoot(
            against: validatedDirectories
        )
        let backupDirectoryURL = validatedBackupRootURL.appendingPathComponent(
            deploymentToken,
            isDirectory: true
        ).standardizedFileURL
        guard backupDirectoryURL.deletingLastPathComponent().path
                == validatedBackupRootURL.path else {
            throw ProvisioningProfileCacheError.unsafePath(
                backupDirectoryURL.path
            )
        }
        guard SecureProvisioningProfilePath.entryExists(backupDirectoryURL) else {
            return .noManifest
        }
        guard SecureProvisioningProfilePath.isDirectoryWithoutSymbolicLinks(
            backupDirectoryURL
        ), SecureProvisioningProfilePath.hasPOSIXPermissions(
            0o700,
            at: backupDirectoryURL
        ) else {
            throw ProvisioningProfileCacheError.recoveryFailed(
                "事务目录不是权限为 0700 的受控目录。"
            )
        }

        let manifestURL = backupDirectoryURL.appendingPathComponent(
            ProvisioningProfileCacheManifestStore.fileName
        )
        guard SecureProvisioningProfilePath.entryExists(manifestURL) else {
            let entries = try FileManager.default.contentsOfDirectory(
                at: backupDirectoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard entries.isEmpty else {
                throw ProvisioningProfileCacheError.recoveryFailed(
                    "事务目录包含数据但缺少 manifest，已停止自动恢复。"
                )
            }
            return .noManifest
        }
        guard SecureProvisioningProfilePath.hasPOSIXPermissions(
            0o600,
            at: manifestURL
        ) else {
            throw ProvisioningProfileCacheError.recoveryFailed(
                "manifest 权限不是 0600。"
            )
        }

        let manifestStore = try ProvisioningProfileCacheManifestStore(
            loadingAt: manifestURL,
            writer: manifestWriter
        )
        let payload = manifestStore.snapshot
        let backups = try validatedBackups(
            from: payload,
            deploymentToken: deploymentToken,
            backupDirectoryURL: backupDirectoryURL,
            profileDirectories: validatedDirectories
        )

        switch payload.state {
        case .committed:
            for backup in backups where SecureProvisioningProfilePath.entryExists(
                backup.destinationURL
            ) {
                guard SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    backup.destinationURL,
                    maximumBytes: limits.maximumProfileBytes
                ), SecureProvisioningProfilePath.sha256Hex(
                    at: backup.destinationURL,
                    maximumBytes: limits.maximumProfileBytes
                ) == backup.sha256Digest else {
                    throw ProvisioningProfileCacheError.recoveryFailed(
                        "已提交备份的内容或摘要无效。"
                    )
                }
            }
            let cleanupTransaction = ProvisioningProfileCacheTransaction(
                backupDirectoryURL: backupDirectoryURL,
                backups: backups,
                maximumProfileBytes: limits.maximumProfileBytes,
                manifestStore: manifestStore,
                moveItem: moveItem
            )
            try cleanupTransaction.commit()
            return .alreadyCommitted(backupCount: backups.count)
        case .rolledBack:
            for backup in backups {
                guard !SecureProvisioningProfilePath.entryExists(
                    backup.destinationURL
                ), SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                    backup.originalURL,
                    maximumBytes: limits.maximumProfileBytes
                ), SecureProvisioningProfilePath.sha256Hex(
                    at: backup.originalURL,
                    maximumBytes: limits.maximumProfileBytes
                ) == backup.sha256Digest else {
                    throw ProvisioningProfileCacheError.recoveryFailed(
                        "已回滚事务的文件状态与 manifest 不一致。"
                    )
                }
            }
            return .alreadyRolledBack
        case .preparing, .active, .rollingBack:
            let movedProfileCount = backups.filter {
                SecureProvisioningProfilePath.entryExists($0.destinationURL)
            }.count
            var pendingIndices = Set(backups.indices)
            let failures = ProvisioningProfileCacheTransaction.restore(
                backups: backups,
                pendingBackupIndices: &pendingIndices,
                maximumProfileBytes: limits.maximumProfileBytes,
                moveItem: moveItem,
                willRestore: { backup in
                    try manifestStore.markRestoring(backup)
                },
                didRestore: { backup in
                    try manifestStore.markRestored(backup)
                }
            )
            guard failures.isEmpty else {
                throw ProvisioningProfileCacheError.recoveryFailed(
                    failures.joined(separator: "；")
                )
            }
            do {
                try manifestStore.markRolledBack()
            } catch {
                throw ProvisioningProfileCacheError.recoveryFailed(
                    DiagnosticText.bounded(error.localizedDescription)
                )
            }
            return .restored(profileCount: movedProfileCount)
        }
    }

    private func validatedBackups(
        from payload: ProvisioningProfileCacheManifestPayload,
        deploymentToken: String,
        backupDirectoryURL: URL,
        profileDirectories: [ProvisioningProfileCacheDirectory]
    ) throws -> [ProvisioningProfileCacheBackup] {
        guard payload.deploymentToken == deploymentToken,
              DeploymentToken(rawValue: payload.deploymentToken) != nil,
              Self.isValidBundleIdentifier(payload.bundleIdentifier),
              DevelopmentTeamIdentifier(
                  rawValue: payload.teamIdentifier
              ) != nil,
              payload.items.count <= limits.maximumDirectoryEntryCount * 2 else {
            throw ProvisioningProfileCacheError.manifestInvalid(
                "事务身份或条目数量无效。"
            )
        }
        let directoriesByLocation = Dictionary(
            uniqueKeysWithValues: profileDirectories.map {
                ($0.location, $0.url)
            }
        )
        var originalPaths: Set<String> = []
        var destinationPaths: Set<String> = []
        var backups: [ProvisioningProfileCacheBackup] = []
        for item in payload.items {
            guard let profileDirectoryURL = directoriesByLocation[item.location],
                  SecureProvisioningProfilePath.isSHA256Digest(
                    item.sha256Digest
                  ) else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "Profile 来源或摘要无效。"
                )
            }
            let originalURL = URL(fileURLWithPath: item.originalPath)
                .standardizedFileURL
            let destinationURL = URL(fileURLWithPath: item.destinationPath)
                .standardizedFileURL
            let locationDirectoryURL = backupDirectoryURL.appendingPathComponent(
                item.location.rawValue,
                isDirectory: true
            ).standardizedFileURL
            let expectedDestinationURL = locationDirectoryURL
                .appendingPathComponent(originalURL.lastPathComponent)
                .standardizedFileURL
            guard item.originalPath == originalURL.path,
                  item.destinationPath == destinationURL.path,
                  originalURL.pathExtension.caseInsensitiveCompare(
                    "mobileprovision"
                  ) == .orderedSame,
                  originalURL.deletingLastPathComponent().path
                    == profileDirectoryURL.path,
                  destinationURL.path == expectedDestinationURL.path,
                  originalPaths.insert(originalURL.path).inserted,
                  destinationPaths.insert(destinationURL.path).inserted else {
                throw ProvisioningProfileCacheError.manifestInvalid(
                    "Profile 映射路径不在受控目录内或发生重复。"
                )
            }
            if SecureProvisioningProfilePath.entryExists(locationDirectoryURL) {
                guard SecureProvisioningProfilePath
                    .isDirectoryWithoutSymbolicLinks(locationDirectoryURL),
                      SecureProvisioningProfilePath.hasPOSIXPermissions(
                        0o700,
                        at: locationDirectoryURL
                      ) else {
                    throw ProvisioningProfileCacheError.manifestInvalid(
                        "Profile 备份子目录不安全。"
                    )
                }
            }
            backups.append(
                ProvisioningProfileCacheBackup(
                    location: item.location,
                    originalURL: originalURL,
                    destinationURL: destinationURL,
                    sha256Digest: item.sha256Digest,
                    expirationDate: item.expirationDate
                )
            )
        }
        return backups
    }

    private func validateDirectories() throws -> [ProvisioningProfileCacheDirectory] {
        let standardizedEntries = try directories.entries.map { entry in
            let url = try SecureProvisioningProfilePath.validatedAbsoluteURL(
                entry.url
            )
            return ProvisioningProfileCacheDirectory(
                location: entry.location,
                url: url
            )
        }
        let resolvedPaths = standardizedEntries.map {
            $0.url.resolvingSymlinksInPath().path
        }
        guard Set(resolvedPaths).count == standardizedEntries.count else {
            throw ProvisioningProfileCacheError.duplicateProfileDirectories
        }
        return standardizedEntries
    }

    private func validateBackupRoot(
        against profileDirectories: [ProvisioningProfileCacheDirectory]
    ) throws -> URL {
        let backupRootURL = try SecureProvisioningProfilePath.validatedAbsoluteURL(
            backupRootURL
        )
        let backupPath = backupRootURL.resolvingSymlinksInPath().path
        for directory in profileDirectories {
            let profilePath = directory.url.resolvingSymlinksInPath().path
            guard !SecureProvisioningProfilePath.contains(
                profilePath,
                candidate: backupPath
            ), !SecureProvisioningProfilePath.contains(
                backupPath,
                candidate: profilePath
            ) else {
                throw ProvisioningProfileCacheError.unsafePath(backupRootURL.path)
            }
        }
        return backupRootURL
    }

    private func matchingCandidates(
        in directories: [ProvisioningProfileCacheDirectory],
        bundleIdentifier: String,
        expectedTeamIdentifier: String,
        refreshMode: ProvisioningProfileRefreshMode,
        deploymentToken: String,
        now: Date
    ) async throws -> [ProvisioningProfileCacheCandidate] {
        var candidates: [ProvisioningProfileCacheCandidate] = []
        for directory in directories {
            try Task.checkCancellation()
            guard SecureProvisioningProfilePath.entryExists(directory.url) else {
                continue
            }
            guard SecureProvisioningProfilePath.isDirectoryWithoutSymbolicLinks(
                directory.url
            ) else {
                throw ProvisioningProfileCacheError.unsafePath(directory.url.path)
            }

            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory.url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw ProvisioningProfileCacheError.directoryEnumerationFailed(
                    directory.url.path
                )
            }
            guard entries.count <= limits.maximumDirectoryEntryCount else {
                throw ProvisioningProfileCacheError.directoryEntryLimitExceeded(
                    directory.url.path
                )
            }

            for entryURL in entries.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard entryURL.pathExtension.caseInsensitiveCompare(
                    "mobileprovision"
                ) == .orderedSame,
                      entryURL.deletingLastPathComponent().standardizedFileURL.path
                        == directory.url.path,
                      SecureProvisioningProfilePath.isRegularNonSymbolicLink(
                        entryURL,
                        maximumBytes: limits.maximumProfileBytes
                      ),
                      let digest = SecureProvisioningProfilePath.sha256Hex(
                        at: entryURL,
                        maximumBytes: limits.maximumProfileBytes
                      ) else {
                    continue
                }

                let decodedData: Data
                do {
                    decodedData = try await decodeProvisioningProfile(
                        entryURL,
                        deploymentToken
                    )
                } catch let error as CancellationError {
                    throw error
                } catch let error as ProvisioningProfileCacheError {
                    throw error
                } catch {
                    throw ProvisioningProfileCacheError.profileDecodeFailed(
                        fileName: entryURL.lastPathComponent,
                        reason: DiagnosticText.bounded(error.localizedDescription)
                    )
                }
                try Task.checkCancellation()
                guard decodedData.count <= limits.maximumDecodedProfileBytes else {
                    throw ProvisioningProfileCacheError.decodedProfileTooLarge(
                        fileName: entryURL.lastPathComponent,
                        maximumBytes: limits.maximumDecodedProfileBytes
                    )
                }
                guard let profile = Self.parseProfile(decodedData),
                      Self.matches(
                        profile.applicationIdentifier,
                        bundleIdentifier: bundleIdentifier,
                        expectedTeamIdentifier: expectedTeamIdentifier
                      ) else {
                    continue
                }
                if refreshMode == .automatic,
                   profile.expirationDate > now {
                    continue
                }
                candidates.append(
                    ProvisioningProfileCacheCandidate(
                        location: directory.location,
                        url: entryURL,
                        sha256Digest: digest,
                        expirationDate: profile.expirationDate
                    )
                )
            }
        }
        return candidates
    }

    private static func parseProfile(
        _ data: Data
    ) -> ProvisioningProfileCacheIdentity? {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let applicationIdentifier = entitlements[
                "application-identifier"
              ] as? String,
              applicationIdentifier == applicationIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines),
              DeviceIdentityValidator.isSafe(applicationIdentifier),
              let expirationDate = plist["ExpirationDate"] as? Date else {
            return nil
        }
        return ProvisioningProfileCacheIdentity(
            applicationIdentifier: applicationIdentifier,
            expirationDate: expirationDate
        )
    }

    private static func matches(
        _ applicationIdentifier: String,
        bundleIdentifier: String,
        expectedTeamIdentifier: String
    ) -> Bool {
        guard let separator = applicationIdentifier.firstIndex(of: ".") else {
            return false
        }
        let teamIdentifier = applicationIdentifier[..<separator]
        let profileBundleIdentifier = applicationIdentifier[
            applicationIdentifier.index(after: separator)...
        ]
        return teamIdentifier == expectedTeamIdentifier[...]
            && profileBundleIdentifier == bundleIdentifier
            && applicationIdentifier
                == "\(expectedTeamIdentifier).\(bundleIdentifier)"
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 255,
              !value.isEmpty,
              !value.contains("*"),
              !value.contains("/"),
              !value.contains(":"),
              !value.hasPrefix("."),
              !value.hasSuffix(".") else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty
                    && component.unicodeScalars.allSatisfy {
                        isASCIIAlphaNumeric($0) || $0 == "-"
                    }
            }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }
}

private struct ProvisioningProfileCacheDirectory: Sendable {
    let location: ProvisioningProfileCacheLocation
    let url: URL
}

private struct ProvisioningProfileCacheCandidate: Sendable {
    let location: ProvisioningProfileCacheLocation
    let url: URL
    let sha256Digest: String
    let expirationDate: Date
}

private struct ProvisioningProfileCacheIdentity: Sendable {
    let applicationIdentifier: String
    let expirationDate: Date
}

private enum SecureProvisioningProfilePath {
    static func validatedAbsoluteURL(_ url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        guard url.isFileURL,
              standardizedURL.path.hasPrefix("/"),
              standardizedURL.path != "/",
              !url.pathComponents.contains(".."),
              !isSymbolicLink(standardizedURL) else {
            throw ProvisioningProfileCacheError.unsafePath(url.path)
        }
        let resolvedURL = try canonicalizedURL(standardizedURL)
        return resolvedURL
    }

    static func createDirectoryIfNeeded(_ url: URL) throws {
        guard !entryExists(url) else {
            guard isDirectoryWithoutSymbolicLinks(url) else {
                throw ProvisioningProfileCacheError.unsafePath(url.path)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        guard isDirectoryWithoutSymbolicLinks(url) else {
            throw ProvisioningProfileCacheError.unsafePath(url.path)
        }
    }

    static func contains(_ rootPath: String, candidate: String) -> Bool {
        candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }

    static func entryExists(_ url: URL) -> Bool {
        withFileStatus(url) { _ in true } ?? false
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        withFileStatus(url) { status in
            (status.st_mode & S_IFMT) == S_IFLNK
        } ?? false
    }

    static func setPOSIXPermissions(
        _ permissions: Int,
        at url: URL
    ) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    static func hasPOSIXPermissions(
        _ permissions: Int,
        at url: URL
    ) -> Bool {
        withFileStatus(url) { status in
            Int(status.st_mode & 0o777) == permissions
        } ?? false
    }

    static func isDirectoryWithoutSymbolicLinks(_ url: URL) -> Bool {
        return withFileStatus(url) { status in
            (status.st_mode & S_IFMT) == S_IFDIR
        } ?? false
    }

    static func isRegularNonSymbolicLink(
        _ url: URL,
        maximumBytes: Int
    ) -> Bool {
        withFileStatus(url) { status in
            (status.st_mode & S_IFMT) == S_IFREG
                && status.st_size >= 0
                && status.st_size <= maximumBytes
        } ?? false
    }

    static func sha256Hex(
        at url: URL,
        maximumBytes: Int
    ) -> String? {
        guard isRegularNonSymbolicLink(
            url,
            maximumBytes: maximumBytes
        ),
              let data = try? BoundedFileReader().data(
                at: url,
                maximumBytes: maximumBytes
              ) else {
            return nil
        }
        return sha256Hex(data)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }

    private static func canonicalizedURL(_ url: URL) throws -> URL {
        var existingAncestorURL = url
        var missingComponents: [String] = []
        while !entryExists(existingAncestorURL) {
            let parentURL = existingAncestorURL.deletingLastPathComponent()
            guard parentURL.path != existingAncestorURL.path else {
                throw ProvisioningProfileCacheError.unsafePath(url.path)
            }
            missingComponents.insert(
                existingAncestorURL.lastPathComponent,
                at: 0
            )
            existingAncestorURL = parentURL
        }

        let resolvedPath: String? = existingAncestorURL
            .withUnsafeFileSystemRepresentation { path in
                guard let path,
                      let resolved = Darwin.realpath(path, nil) else {
                    return nil
                }
                defer { Darwin.free(resolved) }
                return String(cString: resolved)
            }
        guard let resolvedPath else {
            throw ProvisioningProfileCacheError.unsafePath(url.path)
        }
        var resultURL = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        for component in missingComponents {
            resultURL.appendPathComponent(component)
        }
        return resultURL.standardizedFileURL
    }

    private static func withFileStatus<T>(
        _ url: URL,
        _ body: (stat) -> T
    ) -> T? {
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return Int32(-1)
            }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else {
            return nil
        }
        return body(status)
    }
}
