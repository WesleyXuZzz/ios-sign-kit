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
        guard let app = try await fetchAppRecord(
            device: device, bundleID: bundleID,
            commandTimeoutSeconds: commandTimeoutSeconds,
            outerTimeoutSeconds: outerTimeoutSeconds
        ) else { return nil }
        let receiptResult = try await fetchDeviceReceipt(
            device: device, bundleID: bundleID, app: app,
            commandTimeoutSeconds: commandTimeoutSeconds,
            outerTimeoutSeconds: outerTimeoutSeconds
        )
        if let receiptResult {
            // The two observations must straddle the receipt read. A container
            // change during transfer invalidates this whole observation.
            if receiptResult.receipt != nil {
                guard let confirmed = try await fetchAppRecord(
                    device: device, bundleID: bundleID,
                    commandTimeoutSeconds: commandTimeoutSeconds,
                    outerTimeoutSeconds: outerTimeoutSeconds
                ), confirmed == app else {
                    throw DeviceAppInspectorError.invalidResponse("读取设备回执期间安装发生变化，请重新检查。")
                }
            }
            return InstalledAppInfo(
                bundleIdentifier: app.bundleIdentifier, name: app.name,
                version: app.version, bundleVersion: app.bundleVersion,
                appURL: InstalledAppIdentity.normalizedAppURL(app.url)!,
                builtByDeveloper: app.builtByDeveloper,
                installMetadata: receiptResult.receipt?.metadata,
                installMetadataValidation: receiptResult.validation,
                deviceInstallReceipt: receiptResult.receipt
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
            appURL: InstalledAppIdentity.normalizedAppURL(app.url)!,
            builtByDeveloper: app.builtByDeveloper,
            installMetadata: metadataResult.metadata,
            installMetadataValidation: metadataResult.validation
        )
    }

    private func fetchAppRecord(
        device: DeviceInfo,
        bundleID: String,
        commandTimeoutSeconds: TimeInterval,
        outerTimeoutSeconds: TimeInterval
    ) async throws -> DeviceAppRecord? {
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
        return try DeviceAppsResponse.app(from: data, bundleID: bundleID)
    }

    private func fetchDeviceReceipt(
        device: DeviceInfo,
        bundleID: String,
        app: DeviceAppRecord,
        commandTimeoutSeconds: TimeInterval,
        outerTimeoutSeconds: TimeInterval
    ) async throws -> (receipt: DeviceInstallReceipt?, validation: InstallMetadataValidation)? {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("device-receipt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result: CommandResult
        do {
            result = try await runCommand("/usr/bin/xcrun", [
                "devicectl", "device", "copy", "from",
                "--device", device.id,
                "--domain-type", "appDataContainer",
                "--domain-identifier", bundleID,
                "--source", DeviceInstallReceipt.containerPath,
                "--destination", destination.path,
                "--timeout", "\(Int(ceil(commandTimeoutSeconds)))"
            ], outerTimeoutSeconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (nil, .unavailable(DiagnosticText.bounded(error.localizedDescription)))
        }
        guard result.completedSuccessfullyAndFullyTerminated else {
            let diagnostic = DiagnosticText.bounded(result.standardError.isEmpty ? result.standardOutput : result.standardError)
            // Only an explicit absence allows falling back to optional legacy
            // App metadata. An unreadable/corrupt receipt cannot be bypassed.
            if result.processGroupTerminationWasConfirmed,
               Self.isExplicitMissingMetadataFile(diagnostic) { return nil }
            return (nil, .unavailable(diagnostic.isEmpty ? "无法读取设备安装回执。" : diagnostic))
        }
        do {
            let data = try BoundedFileReader().data(at: destination, maximumBytes: DeviceInstallReceipt.maximumBytes)
            let receipt = try DeviceInstallReceipt.decode(data)
            return (receipt, receipt.validation(deviceID: device.id, app: app))
        } catch {
            return (nil, .invalid("设备安装回执无效：\(DiagnosticText.bounded(error.localizedDescription))"))
        }
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
        var previousInstallationMetadata: AppInstallMetadataSnapshot?
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
                switch InstallMetadataValidator.validate(
                    metadata,
                    requestedBundleID: bundleID,
                    installedBundleID: app.bundleIdentifier,
                    installedVersion: app.version,
                    installedBuildVersion: app.bundleVersion,
                    installedAppURL: app.url
                ) {
                case .valid:
                    return InstallMetadataFetchResult(metadata: metadata, validation: .valid)
                case .previousInstallation:
                    previousInstallationMetadata = metadata
                case .invalid(let reason):
                    invalidReason = reason
                }
            } catch {
                invalidReason = "无法解码安装元数据：\(error.localizedDescription)"
                continue
            }
        }

        if let invalidReason {
            return InstallMetadataFetchResult(metadata: nil, validation: .invalid(invalidReason))
        }
        if let previousInstallationMetadata {
            return InstallMetadataFetchResult(
                metadata: previousInstallationMetadata,
                validation: .previousInstallation
            )
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
    enum Result: Equatable {
        case valid
        case previousInstallation
        case invalid(String)
    }

    static let supportedSchemaVersion = 1
    static let maximumClockSkew: TimeInterval = 5 * 60
    static let maximumPersonalProfileLifetime: TimeInterval = 8 * 24 * 60 * 60
    static let maximumProfileSourceBytes = 256

    static func validate(
        _ metadata: AppInstallMetadataSnapshot,
        requestedBundleID: String,
        installedBundleID: String,
        installedVersion: String,
        installedBuildVersion: String,
        now: Date = Date(),
        installedAppURL: String? = nil
    ) -> Result {
        guard metadata.schemaVersion == supportedSchemaVersion else {
            return .invalid("不支持 schemaVersion \(metadata.schemaVersion)。")
        }
        guard metadata.bundleIdentifier == requestedBundleID,
              metadata.bundleIdentifier == installedBundleID else {
            return .invalid("Bundle ID 与当前安装不一致。")
        }
        guard [metadata.shortVersion, metadata.buildVersion]
            .allSatisfy(DeviceIdentityValidator.isSafe) else {
            return .invalid("版本或 Build 包含无效字段。")
        }
        if metadata.profileDigest != nil,
           metadata.normalizedProfileDigest == nil {
            return .invalid("Profile 摘要必须是 64 位十六进制 SHA-256。")
        }
        var belongsToPreviousInstallation = false
        if let reportedURL = metadata.installationAppURL {
            guard reportedURL.utf8.count <= 1_024,
                  let reportedIdentity = InstalledAppIdentity.normalizedAppURL(reportedURL),
                  let installedAppURL,
                  let observedIdentity = InstalledAppIdentity.normalizedAppURL(installedAppURL) else {
                return .invalid("安装元数据或设备当前的 App 安装路径无效。")
            }
            belongsToPreviousInstallation = reportedIdentity != observedIdentity
        }
        guard metadata.recordedAt <= now.addingTimeInterval(maximumClockSkew) else {
            return .invalid("recordedAt 晚于当前时间。")
        }
        let profileSource = metadata.profileSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profileSource != DeviceInstallReceipt.source else {
            return .invalid("设备回执来源只能由独立的安装回执提供。")
        }
        guard !profileSource.isEmpty else {
            return .invalid("profileSource 为空。")
        }
        guard profileSource.lengthOfBytes(using: .utf8) <= maximumProfileSourceBytes,
              profileSource.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return .invalid("profileSource 包含非法字符或长度超过 \(maximumProfileSourceBytes) 字节。")
        }
        if let expectedExpiryAt = metadata.expectedExpiryAt {
            guard expectedExpiryAt >= metadata.recordedAt.addingTimeInterval(-maximumClockSkew) else {
                return .invalid("expectedExpiryAt 早于 recordedAt。")
            }
            guard expectedExpiryAt <= metadata.recordedAt.addingTimeInterval(maximumPersonalProfileLifetime) else {
                return .invalid("expectedExpiryAt 超出个人签名有效期范围。")
            }
        }
        // Classify only well-formed evidence for this Bundle as stale. Its
        // version may legitimately differ after a successful local upgrade.
        if belongsToPreviousInstallation {
            return .previousInstallation
        }
        guard metadata.shortVersion == installedVersion,
              metadata.buildVersion == installedBuildVersion else {
            return .invalid("版本或 Build 与当前安装不一致。")
        }
        return .valid
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
