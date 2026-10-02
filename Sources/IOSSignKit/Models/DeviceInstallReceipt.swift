import CryptoKit
import Foundation

/// Host-verified installation evidence transported in the App's data container.
/// The checksum detects incomplete transfers; it is not a signature or a lock
/// between Macs. No target-App code participates in producing this receipt.
struct DeviceInstallReceipt: Codable, Equatable, Sendable {
    static let source = "iossignkit_device_receipt"
    static let containerPath = "Library/com.xuzw.iossignkit.install-receipt.json"
    static let maximumBytes = 64 * 1_024

    let schemaVersion: Int
    let installationAppURL: String
    let installation: HostInstallReceipt

    private struct Envelope: Codable {
        let payload: Data
        let sha256: String
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(self)
        let data = try encoder.encode(Envelope(payload: payload, sha256: Self.digest(payload)))
        guard data.count <= Self.maximumBytes else {
            throw DeviceInstallReceiptError.invalid("回执超过大小上限。")
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else {
            throw DeviceInstallReceiptError.invalid("回执超过大小上限。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard digest(envelope.payload) == envelope.sha256 else {
            throw DeviceInstallReceiptError.invalid("回执传输摘要不匹配。")
        }
        let receipt = try decoder.decode(Self.self, from: envelope.payload)
        try receipt.validate()
        return receipt
    }

    func validate() throws {
        try HostInstallReceiptStore.validateReceipt(installation)
        guard schemaVersion == 1,
              installation.status == .installed,
              installationAppURL.utf8.count <= 1_024,
              let identity = InstalledAppIdentity.normalizedAppURL(installationAppURL),
              identity.hasPrefix("application-container:") else {
            throw DeviceInstallReceiptError.invalid("回执缺少已完成安装或安装容器身份。")
        }
    }

    func validation(
        deviceID: String,
        app: DeviceAppRecord,
        now: Date = Date()
    ) -> InstallMetadataValidation {
        guard installation.deviceIdentifier == deviceID,
              installation.bundleIdentifier == app.bundleIdentifier,
              let installedAt = installation.installedAt,
              installedAt <= now.addingTimeInterval(300),
              installation.preparedAt <= now.addingTimeInterval(300) else {
            return .invalid("设备回执的目标或时间与当前查询不一致。")
        }
        guard InstalledAppIdentity.normalizedAppURL(installationAppURL)
                == InstalledAppIdentity.normalizedAppURL(app.url) else {
            return .previousInstallation
        }
        guard app.builtByDeveloper,
              installation.shortVersion == app.version,
              installation.buildVersion == app.bundleVersion else {
            return .invalid("设备回执与当前 App 版本或安装来源不一致。")
        }
        return .valid
    }

    var metadata: AppInstallMetadataSnapshot? {
        guard installation.status == .installed,
              let installedAt = installation.installedAt else { return nil }
        return AppInstallMetadataSnapshot(
            schemaVersion: 1,
            recordedAt: installedAt,
            bundleIdentifier: installation.bundleIdentifier,
            shortVersion: installation.shortVersion,
            buildVersion: installation.buildVersion,
            expectedExpiryAt: installation.profileExpirationDate,
            profileSource: Self.source,
            profileDigest: installation.profileDigest,
            installationAppURL: installationAppURL
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum DeviceInstallReceiptError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

struct DeviceAppsResponse: Decodable {
    struct Result: Decodable {
        let apps: [DeviceAppRecord]
    }

    let result: Result

    static func app(from data: Data, bundleID: String) throws -> DeviceAppRecord? {
        let response = try JSONDecoder().decode(Self.self, from: data)
        let matches = response.result.apps.filter { $0.bundleIdentifier == bundleID }
        guard matches.count <= 1 else {
            throw DeviceAppInspectorError.invalidResponse("设备返回多个相同 Bundle ID 的安装记录。")
        }
        guard let app = matches.first else { return nil }
        guard [app.bundleIdentifier, app.name, app.version, app.bundleVersion]
                .allSatisfy(DeviceIdentityValidator.isSafe),
              app.url.utf8.count <= 1_024,
              InstalledAppIdentity.normalizedAppURL(app.url) != nil else {
            throw DeviceAppInspectorError.invalidResponse("设备返回的 App 身份字段无效或过长。")
        }
        return app
    }
}

struct DeviceAppRecord: Decodable, Equatable, Sendable {
    let bundleIdentifier: String
    let bundleVersion: String
    let name: String
    let url: String
    let version: String
    let builtByDeveloper: Bool
}
