import CryptoKit
import Darwin
import Foundation

enum HostInstallReceiptStatus: String, Codable, Equatable, Sendable {
    case prepared
    case installed
}

struct HostInstallReceipt: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let deploymentToken: String
    let bundleIdentifier: String
    let deviceIdentifier: String
    let teamIdentifier: String
    let shortVersion: String
    let buildVersion: String
    let profileUUID: String
    let profileDigest: String
    let profileExpirationDate: Date
    let preparedAt: Date
    var status: HostInstallReceiptStatus
    var installedAt: Date?
}

struct HostInstallReceiptStoreLimits: Equatable, Sendable {
    static let production = HostInstallReceiptStoreLimits(
        maximumReceiptBytes: 64 * 1_024,
        maximumReceiptCount: 200,
        maximumTotalBytes: 8 * 1_024 * 1_024,
        maximumDirectoryEntryCount: 4_096
    )

    let maximumReceiptBytes: Int
    let maximumReceiptCount: Int
    let maximumTotalBytes: Int
    let maximumDirectoryEntryCount: Int

    fileprivate var isValid: Bool {
        maximumReceiptBytes > 0
            && maximumReceiptCount > 0
            && maximumTotalBytes >= maximumReceiptBytes
            && maximumDirectoryEntryCount >= maximumReceiptCount
    }
}

enum HostInstallReceiptStoreError:
    Error,
    Equatable,
    LocalizedError,
    Sendable {
    case invalidDeploymentToken
    case invalidReceipt(String)
    case invalidLimits
    case unsafePath(String)
    case receiptCollision
    case receiptNotFound
    case receiptCorrupt(String)
    case writeFailed(String)
    case retentionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidDeploymentToken:
            return "宿主安装回执的续签事务令牌无效。"
        case .invalidReceipt(let reason):
            return "宿主安装回执内容无效：\(reason)"
        case .invalidLimits:
            return "宿主安装回执的文件或保留上限无效。"
        case .unsafePath(let path):
            return "宿主安装回执路径不安全：\(path)"
        case .receiptCollision:
            return "同一续签事务令牌已存在不同的宿主安装回执。"
        case .receiptNotFound:
            return "找不到待确认的宿主安装回执。"
        case .receiptCorrupt(let reason):
            return "宿主安装回执已损坏：\(reason)"
        case .writeFailed(let reason):
            return "无法持久化宿主安装回执：\(reason)"
        case .retentionFailed(let reason):
            return "无法执行宿主安装回执保留策略：\(reason)"
        }
    }
}

struct HostInstallReceiptStore: Sendable {
    static var productionRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("iOSSignKit", isDirectory: true)
            .appendingPathComponent("Install Receipts", isDirectory: true)
    }

    private struct PayloadEnvelope: Codable {
        let payload: Data
        let sha256Digest: String
    }

    private struct RetainedFile {
        let url: URL
        let byteCount: Int
        let modifiedAt: Date
        let isRemovable: Bool
    }

    private let rootURL: URL
    private let limits: HostInstallReceiptStoreLimits

    init(
        rootURL: URL = Self.productionRootURL,
        limits: HostInstallReceiptStoreLimits = .production
    ) {
        self.rootURL = rootURL
        self.limits = limits
    }

    @discardableResult
    func recordPrepared(
        deploymentToken: String,
        bundleIdentifier: String,
        deviceIdentifier: String,
        teamIdentifier: String,
        shortVersion: String,
        buildVersion: String,
        profileUUID: String,
        profileDigest: String,
        profileExpirationDate: Date,
        preparedAt: Date = Date()
    ) throws -> HostInstallReceipt {
        let receipt = HostInstallReceipt(
            schemaVersion: HostInstallReceipt.schemaVersion,
            deploymentToken: deploymentToken,
            bundleIdentifier: bundleIdentifier,
            deviceIdentifier: deviceIdentifier,
            teamIdentifier: teamIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            profileUUID: profileUUID,
            profileDigest: profileDigest,
            profileExpirationDate: Self.canonicalDate(
                profileExpirationDate
            ),
            preparedAt: Self.canonicalDate(preparedAt),
            status: .prepared,
            installedAt: nil
        )
        try validate(receipt)
        let rootURL = try preparedRootURL()
        let receiptURL = try exactReceiptURL(
            deploymentToken: deploymentToken,
            rootURL: rootURL
        )
        if HostInstallReceiptPath.entryExists(receiptURL) {
            let existing = try readReceipt(at: receiptURL)
            guard existing == receipt else {
                throw HostInstallReceiptStoreError.receiptCollision
            }
            try enforceRetention(
                in: rootURL,
                excludingDeploymentToken: deploymentToken
            )
            return existing
        }
        try write(receipt, to: receiptURL, permitsReplacement: false)
        try enforceRetention(
            in: rootURL,
            excludingDeploymentToken: deploymentToken
        )
        return receipt
    }

    @discardableResult
    func markInstalled(
        deploymentToken: String,
        installedAt: Date = Date()
    ) throws -> HostInstallReceipt {
        let rootURL = try preparedRootURL()
        let receiptURL = try exactReceiptURL(
            deploymentToken: deploymentToken,
            rootURL: rootURL
        )
        guard HostInstallReceiptPath.entryExists(receiptURL) else {
            throw HostInstallReceiptStoreError.receiptNotFound
        }
        var receipt = try readReceipt(at: receiptURL)
        guard receipt.deploymentToken == deploymentToken else {
            throw HostInstallReceiptStoreError.receiptCorrupt(
                "文件名与 payload 中的事务令牌不一致。"
            )
        }
        if receipt.status == .installed {
            try enforceRetention(
                in: rootURL,
                excludingDeploymentToken: deploymentToken
            )
            return receipt
        }
        receipt.status = .installed
        receipt.installedAt = Self.canonicalDate(installedAt)
        try validate(receipt)
        try write(receipt, to: receiptURL, permitsReplacement: true)
        try enforceRetention(
            in: rootURL,
            excludingDeploymentToken: deploymentToken
        )
        return receipt
    }

    func load(
        deploymentToken: String
    ) throws -> HostInstallReceipt? {
        guard limits.isValid else {
            throw HostInstallReceiptStoreError.invalidLimits
        }
        guard DeploymentToken(rawValue: deploymentToken) != nil else {
            throw HostInstallReceiptStoreError.invalidDeploymentToken
        }
        let rootURL = try validatedRootURL(createIfMissing: false)
        guard let rootURL else {
            return nil
        }
        let receiptURL = try exactReceiptURL(
            deploymentToken: deploymentToken,
            rootURL: rootURL
        )
        guard HostInstallReceiptPath.entryExists(receiptURL) else {
            return nil
        }
        let receipt = try readReceipt(at: receiptURL)
        guard receipt.deploymentToken == deploymentToken else {
            throw HostInstallReceiptStoreError.receiptCorrupt(
                "文件名与 payload 中的事务令牌不一致。"
            )
        }
        return receipt
    }

    private func preparedRootURL() throws -> URL {
        guard limits.isValid else {
            throw HostInstallReceiptStoreError.invalidLimits
        }
        return try requireValidatedRootURL()
    }

    private func requireValidatedRootURL() throws -> URL {
        guard let rootURL = try validatedRootURL(createIfMissing: true) else {
            throw HostInstallReceiptStoreError.unsafePath(self.rootURL.path)
        }
        return rootURL
    }

    private func validatedRootURL(
        createIfMissing: Bool
    ) throws -> URL? {
        let standardizedURL = rootURL.standardizedFileURL
        guard rootURL.isFileURL,
              standardizedURL.path.hasPrefix("/"),
              standardizedURL.path != "/",
              !rootURL.pathComponents.contains(".."),
              !HostInstallReceiptPath.isSymbolicLink(standardizedURL) else {
            throw HostInstallReceiptStoreError.unsafePath(rootURL.path)
        }
        let canonicalURL = standardizedURL.resolvingSymlinksInPath()
            .standardizedFileURL
        if !HostInstallReceiptPath.entryExists(canonicalURL) {
            guard createIfMissing else {
                return nil
            }
            do {
                try FileManager.default.createDirectory(
                    at: canonicalURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw HostInstallReceiptStoreError.writeFailed(
                    DiagnosticText.bounded(error.localizedDescription)
                )
            }
        }
        guard HostInstallReceiptPath.isDirectory(canonicalURL) else {
            throw HostInstallReceiptStoreError.unsafePath(
                canonicalURL.path
            )
        }
        do {
            try HostInstallReceiptPath.setPermissions(
                0o700,
                at: canonicalURL
            )
        } catch {
            throw HostInstallReceiptStoreError.writeFailed(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        guard HostInstallReceiptPath.hasPermissions(
            0o700,
            at: canonicalURL
        ) else {
            throw HostInstallReceiptStoreError.unsafePath(
                canonicalURL.path
            )
        }
        return canonicalURL
    }

    private func exactReceiptURL(
        deploymentToken: String,
        rootURL: URL
    ) throws -> URL {
        guard DeploymentToken(rawValue: deploymentToken) != nil else {
            throw HostInstallReceiptStoreError.invalidDeploymentToken
        }
        let receiptURL = rootURL.appendingPathComponent(
            "\(deploymentToken).json",
            isDirectory: false
        ).standardizedFileURL
        guard receiptURL.deletingLastPathComponent().path == rootURL.path else {
            throw HostInstallReceiptStoreError.unsafePath(receiptURL.path)
        }
        return receiptURL
    }

    private func write(
        _ receipt: HostInstallReceipt,
        to url: URL,
        permitsReplacement: Bool
    ) throws {
        if HostInstallReceiptPath.entryExists(url) {
            guard permitsReplacement,
                  HostInstallReceiptPath.isRegularFile(
                    url,
                    maximumBytes: limits.maximumReceiptBytes
                  ) else {
                throw HostInstallReceiptStoreError.receiptCollision
            }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let payload = try encoder.encode(receipt)
            let envelope = PayloadEnvelope(
                payload: payload,
                sha256Digest: HostInstallReceiptPath.sha256Hex(payload)
            )
            let data = try encoder.encode(envelope)
            guard data.count <= limits.maximumReceiptBytes else {
                throw HostInstallReceiptStoreError.invalidReceipt(
                    "编码后超过文件大小上限。"
                )
            }
            try data.write(to: url, options: .atomic)
            try HostInstallReceiptPath.setPermissions(0o600, at: url)
            let persistedReceipt = try readReceipt(at: url)
            guard HostInstallReceiptPath.hasPermissions(0o600, at: url),
                  persistedReceipt == receipt else {
                throw HostInstallReceiptStoreError.receiptCorrupt(
                    "原子写入后无法通过校验。"
                )
            }
        } catch let error as HostInstallReceiptStoreError {
            throw error
        } catch {
            throw HostInstallReceiptStoreError.writeFailed(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
    }

    private func readReceipt(at url: URL) throws -> HostInstallReceipt {
        guard HostInstallReceiptPath.isRegularFile(
            url,
            maximumBytes: limits.maximumReceiptBytes
        ), HostInstallReceiptPath.hasPermissions(0o600, at: url) else {
            throw HostInstallReceiptStoreError.receiptCorrupt(
                "文件不是权限为 0600 的受控普通文件。"
            )
        }
        do {
            let data = try BoundedFileReader().data(
                at: url,
                maximumBytes: limits.maximumReceiptBytes
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(
                PayloadEnvelope.self,
                from: data
            )
            guard HostInstallReceiptPath.sha256Hex(envelope.payload)
                    == envelope.sha256Digest else {
                throw HostInstallReceiptStoreError.receiptCorrupt(
                    "payload 摘要不匹配。"
                )
            }
            let receipt = try decoder.decode(
                HostInstallReceipt.self,
                from: envelope.payload
            )
            try validate(receipt)
            return receipt
        } catch let error as HostInstallReceiptStoreError {
            throw error
        } catch {
            throw HostInstallReceiptStoreError.receiptCorrupt(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
    }

    private func validate(_ receipt: HostInstallReceipt) throws {
        guard receipt.schemaVersion == HostInstallReceipt.schemaVersion,
              DeploymentToken(rawValue: receipt.deploymentToken) != nil else {
            throw HostInstallReceiptStoreError.invalidReceipt(
                "schema 或事务令牌无效。"
            )
        }
        guard Self.isValidBundleIdentifier(receipt.bundleIdentifier),
              DeviceIdentityValidator.isSafe(receipt.deviceIdentifier),
              DevelopmentTeamIdentifier(
                  rawValue: receipt.teamIdentifier
              ) != nil,
              DeviceIdentityValidator.isSafe(receipt.shortVersion),
              DeviceIdentityValidator.isSafe(receipt.buildVersion),
              UUID(uuidString: receipt.profileUUID) != nil,
              HostInstallReceiptPath.isSHA256Digest(receipt.profileDigest),
              receipt.preparedAt.timeIntervalSinceReferenceDate.isFinite,
              receipt.profileExpirationDate.timeIntervalSinceReferenceDate
                .isFinite else {
            throw HostInstallReceiptStoreError.invalidReceipt(
                "项目、设备、版本或签名身份字段无效。"
            )
        }
        switch receipt.status {
        case .prepared:
            guard receipt.installedAt == nil else {
                throw HostInstallReceiptStoreError.invalidReceipt(
                    "prepared 回执不得包含安装时间。"
                )
            }
        case .installed:
            guard let installedAt = receipt.installedAt,
                  installedAt.timeIntervalSinceReferenceDate.isFinite,
                  installedAt >= receipt.preparedAt.addingTimeInterval(-300),
                  receipt.profileExpirationDate > installedAt else {
                throw HostInstallReceiptStoreError.invalidReceipt(
                    "installed 回执的时间关系无效。"
                )
            }
        }
    }

    private func enforceRetention(
        in rootURL: URL,
        excludingDeploymentToken: String
    ) throws {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey
                ],
                options: []
            )
        } catch {
            throw HostInstallReceiptStoreError.retentionFailed(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        guard entries.count <= limits.maximumDirectoryEntryCount else {
            throw HostInstallReceiptStoreError.retentionFailed(
                "目录条目数量超过安全扫描上限。"
            )
        }
        let excludedURL = try exactReceiptURL(
            deploymentToken: excludingDeploymentToken,
            rootURL: rootURL
        )
        var retainedFiles: [RetainedFile] = []
        for entry in entries {
            guard entry.pathExtension == "json",
                  let status = HostInstallReceiptPath.fileStatus(entry),
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_size >= 0 else {
                continue
            }
            let token = Self.deploymentTokenFromFileName(entry)
            let isRemovable = token.flatMap(DeploymentToken.init(rawValue:))
                != nil
                && status.st_size <= limits.maximumReceiptBytes
                && HostInstallReceiptPath.hasPermissions(0o600, at: entry)
            retainedFiles.append(
                RetainedFile(
                    url: entry.standardizedFileURL,
                    byteCount: Int(status.st_size),
                    modifiedAt: Date(
                        timeIntervalSince1970:
                            TimeInterval(status.st_mtimespec.tv_sec)
                                + TimeInterval(status.st_mtimespec.tv_nsec)
                                    / 1_000_000_000
                    ),
                    isRemovable: isRemovable
                )
            )
        }
        var retainedCount = retainedFiles.count
        var retainedBytes = 0
        for file in retainedFiles {
            let addition = retainedBytes.addingReportingOverflow(
                file.byteCount
            )
            guard !addition.overflow else {
                throw HostInstallReceiptStoreError.retentionFailed(
                    "受控 JSON 文件总大小溢出。"
                )
            }
            retainedBytes = addition.partialValue
        }
        let removableFiles = retainedFiles
            .filter {
                $0.isRemovable && $0.url.path != excludedURL.path
            }
            .sorted {
                if $0.modifiedAt == $1.modifiedAt {
                    return $0.url.path < $1.url.path
                }
                return $0.modifiedAt < $1.modifiedAt
            }
        for file in removableFiles {
            guard retainedCount > limits.maximumReceiptCount
                    || retainedBytes > limits.maximumTotalBytes else {
                break
            }
            do {
                try FileManager.default.removeItem(at: file.url)
                retainedCount -= 1
                retainedBytes -= file.byteCount
            } catch {
                throw HostInstallReceiptStoreError.retentionFailed(
                    DiagnosticText.bounded(error.localizedDescription)
                )
            }
        }
        guard retainedCount <= limits.maximumReceiptCount,
              retainedBytes <= limits.maximumTotalBytes else {
            throw HostInstallReceiptStoreError.retentionFailed(
                "排除当前事务后仍无法满足保留上限。"
            )
        }
    }

    private static func deploymentTokenFromFileName(_ url: URL) -> String? {
        guard url.pathExtension == "json" else {
            return nil
        }
        let token = url.deletingPathExtension().lastPathComponent
        return token.isEmpty ? nil : token
    }

    private static func canonicalDate(_ date: Date) -> Date {
        let milliseconds = floor(date.timeIntervalSince1970 * 1_000)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= 255,
              !value.isEmpty,
              !value.contains("*"),
              !value.contains("/"),
              !value.hasPrefix("."),
              !value.hasSuffix(".") else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty
                    && component.unicodeScalars.allSatisfy {
                        ($0.value >= 48 && $0.value <= 57)
                            || ($0.value >= 65 && $0.value <= 90)
                            || ($0.value >= 97 && $0.value <= 122)
                            || $0 == "-"
                    }
            }
    }
}

private enum HostInstallReceiptPath {
    static func fileStatus(_ url: URL) -> stat? {
        var status = stat()
        return url.path.withCString { path in
            lstat(path, &status) == 0 ? status : nil
        }
    }

    static func entryExists(_ url: URL) -> Bool {
        fileStatus(url) != nil
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        guard let status = fileStatus(url) else {
            return false
        }
        return status.st_mode & S_IFMT == S_IFLNK
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard let status = fileStatus(url) else {
            return false
        }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    static func isRegularFile(
        _ url: URL,
        maximumBytes: Int
    ) -> Bool {
        guard let status = fileStatus(url) else {
            return false
        }
        return status.st_mode & S_IFMT == S_IFREG
            && status.st_size >= 0
            && status.st_size <= maximumBytes
    }

    static func setPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    static func hasPermissions(_ permissions: Int, at url: URL) -> Bool {
        guard let status = fileStatus(url) else {
            return false
        }
        return Int(status.st_mode & 0o777) == permissions
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 97 && $0.value <= 102)
            }
    }
}
