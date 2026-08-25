import Foundation

struct DeviceAppInspector {
    private let runCommand: @Sendable (String, [String], TimeInterval?) async throws -> CommandResult
    private let decoder: JSONDecoder
    private let commandBudget: DeviceCommandBudget

    init(
        commandRunner: CommandRunner = CommandRunner(),
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudget = commandBudgets.budget(
            for: .installedAppInspection
        )
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try await commandRunner.runAsync(
                launchPath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
        }
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    init(
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult,
        commandBudgets: DeviceCommandBudgetCatalog = .production
    ) {
        self.commandBudget = commandBudgets.budget(
            for: .installedAppInspection
        )
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func inspectInstalledApp(device: DeviceInfo, bundleID: String) async throws -> InstalledAppInfo? {
        try await inspectInstalledApp(device: device, bundleID: bundleID, retryCount: 1, retryDelaySeconds: 0)
    }

    func inspectInstalledApp(
        device: DeviceInfo,
        bundleID: String,
        retryCount: Int,
        retryDelaySeconds: TimeInterval,
        commandTimeoutSeconds: TimeInterval? = nil
    ) async throws -> InstalledAppInfo? {
        let commandTimeoutSeconds =
            commandTimeoutSeconds ?? commandBudget.commandTimeoutSeconds
        let outerTimeoutSeconds = commandTimeoutSeconds
            == commandBudget.commandTimeoutSeconds
            ? commandBudget.outerTimeoutSeconds
            : commandTimeoutSeconds + 1
        let attempts = max(retryCount, 1)
        var lastError: Error?
        var didCompleteSuccessfulInspection = false

        for attempt in 0..<attempts {
            do {
                let app = try await inspectInstalledAppOnce(
                    device: device,
                    bundleID: bundleID,
                    commandTimeoutSeconds: commandTimeoutSeconds,
                    outerTimeoutSeconds: outerTimeoutSeconds
                )
                didCompleteSuccessfulInspection = true
                if let app {
                    return app
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            if attempt < attempts - 1, retryDelaySeconds > 0 {
                try await Task.sleep(for: .seconds(retryDelaySeconds))
            }
        }

        if !didCompleteSuccessfulInspection, let lastError {
            throw lastError
        }

        return nil
    }

    private func inspectInstalledAppOnce(
        device: DeviceInfo,
        bundleID: String,
        commandTimeoutSeconds: TimeInterval,
        outerTimeoutSeconds: TimeInterval
    ) async throws -> InstalledAppInfo? {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devicectl-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let arguments = [
            "devicectl", "device", "info", "apps",
            "--device", device.id,
            "--bundle-id", bundleID,
            "--timeout", "\(Int(ceil(commandTimeoutSeconds)))",
            "--json-output", outputURL.path
        ]
        let result = try await runCommand(
            "/usr/bin/xcrun",
            arguments,
            outerTimeoutSeconds
        )

        guard result.completedSuccessfullyAndFullyTerminated else {
            let diagnostic = result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            throw DeviceAppInspectorError.commandFailed(DiagnosticText.bounded(diagnostic))
        }

        let data = try BoundedFileReader().data(
            at: outputURL,
            maximumBytes: BoundedFileReader.structuredOutputMaximumBytes
        )
        let decoded = try decoder.decode(DeviceAppsResponse.self, from: data)
        let matchingApps = decoded.result.apps.filter {
            $0.bundleIdentifier == bundleID
        }
        guard matchingApps.count <= 1 else {
            throw DeviceAppInspectorError.invalidResponse(
                "设备返回了多个相同 Bundle ID 的安装记录，无法确认当前实例。"
            )
        }
        guard let app = matchingApps.first else {
            return nil
        }
        guard [app.bundleIdentifier, app.name, app.version, app.bundleVersion]
            .allSatisfy(DeviceIdentityValidator.isSafe),
              let normalizedAppURL = InstalledAppIdentity.normalizedAppURL(app.url),
              normalizedAppURL.utf8.count <= 1_024 else {
            throw DeviceAppInspectorError.invalidResponse(
                "设备返回的 App 身份字段无效或过长。"
            )
        }

        let metadataResult = try await fetchInstallMetadata(
            device: device,
            bundleID: bundleID,
            app: app,
            commandTimeoutSeconds: commandTimeoutSeconds,
            outerTimeoutSeconds: outerTimeoutSeconds
        )

        return InstalledAppInfo(
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            version: app.version,
            bundleVersion: app.bundleVersion,
            appURL: normalizedAppURL,
            builtByDeveloper: app.builtByDeveloper,
            installMetadata: metadataResult.metadata,
            installMetadataValidation: metadataResult.validation
        )
    }

    private func fetchInstallMetadata(
        device: DeviceInfo,
        bundleID: String,
        app: DeviceAppRecord,
        commandTimeoutSeconds: TimeInterval,
        outerTimeoutSeconds: TimeInterval
    ) async throws -> InstallMetadataFetchResult {
        var invalidReason: String?
        var unavailableReason: String?
        var sawExplicitlyMissingFile = false

        for sourcePath in Self.installMetadataSourcePaths(appName: app.name, bundleID: bundleID, appURL: app.url) {
            let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("install-metadata-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: destinationURL) }

            let arguments = [
                "devicectl", "device", "copy", "from",
                "--device", device.id,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleID,
                "--source", sourcePath,
                "--destination", destinationURL.path,
                "--timeout", "\(Int(ceil(commandTimeoutSeconds)))"
            ]
            let result: CommandResult
            do {
                result = try await runCommand(
                    "/usr/bin/xcrun",
                    arguments,
                    outerTimeoutSeconds
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unavailableReason = DiagnosticText.bounded(error.localizedDescription)
                continue
            }

            guard result.completedSuccessfullyAndFullyTerminated else {
                let diagnostic = DiagnosticText.bounded(
                    result.standardError.isEmpty
                        ? result.standardOutput
                        : result.standardError
                )
                if Self.isExplicitMissingMetadataFile(diagnostic) {
                    sawExplicitlyMissingFile = true
                } else {
                    unavailableReason = diagnostic.isEmpty
                        ? "devicectl 无法读取安装元数据。"
                        : diagnostic
                }
                continue
            }

            guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                unavailableReason = "devicectl 报告复制成功，但没有生成安装元数据文件。"
                continue
            }

            do {
                let data = try BoundedFileReader().data(
                    at: destinationURL,
                    maximumBytes: BoundedFileReader.metadataMaximumBytes
                )
                let metadata = try decoder.decode(AppInstallMetadataSnapshot.self, from: data)
                if let validationFailure = InstallMetadataValidator.validationFailure(
                    metadata,
                    requestedBundleID: bundleID,
                    installedBundleID: app.bundleIdentifier,
                    installedVersion: app.version,
                    installedBuildVersion: app.bundleVersion
                ) {
                    invalidReason = validationFailure
                    continue
                }
                return InstallMetadataFetchResult(metadata: metadata, validation: .valid)
            } catch {
                invalidReason = "无法解码安装元数据：\(error.localizedDescription)"
                continue
            }
        }

        if let invalidReason {
            return InstallMetadataFetchResult(metadata: nil, validation: .invalid(invalidReason))
        }
        if let unavailableReason {
            return InstallMetadataFetchResult(
                metadata: nil,
                validation: .unavailable(unavailableReason)
            )
        }
        if !sawExplicitlyMissingFile {
            return InstallMetadataFetchResult(
                metadata: nil,
                validation: .unavailable("无法确认安装元数据是否存在。")
            )
        }
        return InstallMetadataFetchResult(metadata: nil, validation: .notFound)
    }

    private static func isExplicitMissingMetadataFile(_ diagnostic: String) -> Bool {
        let normalized = diagnostic.lowercased()
        return normalized.contains("no such file")
            || normalized.contains("source file does not exist")
            || normalized.contains("nsfile no such file")
            || normalized.contains("cocoa error 260")
    }

    static func installMetadataSourcePaths(appName: String, bundleID: String, appURL: String) -> [String] {
        uniqueDirectoryNames([
            appName,
            bundleID.split(separator: ".").last.map(String.init) ?? "",
            appBundleDirectoryName(from: appURL),
            "App"
        ]).map { directoryName in
            "Library/Application Support/\(directoryName)/install-metadata.json"
        }
    }

    private static func uniqueDirectoryNames(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let safeValue = value
                .split(separator: "/")
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeValue.isEmpty, seen.insert(safeValue).inserted else {
                return nil
            }
            return safeValue
        }
    }

    private static func appBundleDirectoryName(from appURL: String) -> String {
        guard let url = URL(string: appURL) else {
            return ""
        }

        let lastPathComponent = url.lastPathComponent
        if lastPathComponent.hasSuffix(".app") {
            return String(lastPathComponent.dropLast(4))
        }

        return lastPathComponent
    }
}

struct InstallMetadataValidator {
    static let supportedSchemaVersion = 1
    static let maximumClockSkew: TimeInterval = 5 * 60
    static let maximumPersonalProfileLifetime: TimeInterval = 8 * 24 * 60 * 60
    static let maximumProfileSourceBytes = 256

    static func validationFailure(
        _ metadata: AppInstallMetadataSnapshot,
        requestedBundleID: String,
        installedBundleID: String,
        installedVersion: String,
        installedBuildVersion: String,
        now: Date = Date()
    ) -> String? {
        guard metadata.schemaVersion == supportedSchemaVersion else {
            return "不支持 schemaVersion \(metadata.schemaVersion)。"
        }
        guard metadata.bundleIdentifier == requestedBundleID,
              metadata.bundleIdentifier == installedBundleID else {
            return "Bundle ID 与当前安装不一致。"
        }
        guard metadata.shortVersion == installedVersion,
              metadata.buildVersion == installedBuildVersion else {
            return "版本或 Build 与当前安装不一致。"
        }
        guard metadata.recordedAt <= now.addingTimeInterval(maximumClockSkew) else {
            return "recordedAt 晚于当前时间。"
        }
        let profileSource = metadata.profileSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profileSource.isEmpty else {
            return "profileSource 为空。"
        }
        guard profileSource.lengthOfBytes(using: .utf8) <= maximumProfileSourceBytes,
              profileSource.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return "profileSource 包含非法字符或长度超过 \(maximumProfileSourceBytes) 字节。"
        }
        if let expectedExpiryAt = metadata.expectedExpiryAt {
            guard expectedExpiryAt >= metadata.recordedAt.addingTimeInterval(-maximumClockSkew) else {
                return "expectedExpiryAt 早于 recordedAt。"
            }
            guard expectedExpiryAt <= metadata.recordedAt.addingTimeInterval(maximumPersonalProfileLifetime) else {
                return "expectedExpiryAt 超出个人签名有效期范围。"
            }
        }
        return nil
    }
}

private struct InstallMetadataFetchResult {
    let metadata: AppInstallMetadataSnapshot?
    let validation: InstallMetadataValidation
}

enum DeviceAppInspectorError: Error, LocalizedError {
    case invalidResponse(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message):
            return message
        case .commandFailed(let message):
            return message.isEmpty ? "devicectl 未能读取已安装 App。" : message
        }
    }
}

private struct DeviceAppsResponse: Decodable {
    let result: DeviceAppsResult
}

private struct DeviceAppsResult: Decodable {
    let apps: [DeviceAppRecord]
}

private struct DeviceAppRecord: Decodable {
    let bundleIdentifier: String
    let bundleVersion: String
    let name: String
    let url: String
    let version: String
    let builtByDeveloper: Bool
}
