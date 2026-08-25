import Foundation

struct XcodeProjectCandidate: Identifiable, Equatable, Sendable {
    let container: XcodeContainer
    let scheme: String
    let targetName: String
    let bundleID: String

    var projectPath: String {
        container.path
    }

    init(
        container: XcodeContainer,
        scheme: String,
        targetName: String,
        bundleID: String
    ) {
        self.container = container
        self.scheme = scheme
        self.targetName = targetName
        self.bundleID = bundleID
    }

    init(
        projectPath: String,
        scheme: String,
        targetName: String,
        bundleID: String
    ) {
        self.init(
            container: XcodeContainer(path: projectPath)
                ?? .project(path: projectPath),
            scheme: scheme,
            targetName: targetName,
            bundleID: bundleID
        )
    }

    var id: String {
        [container.kind.rawValue, projectPath, scheme, targetName, bundleID]
            .map { "\($0.lengthOfBytes(using: .utf8)):\($0)" }
            .joined()
    }

    var selectionDisplayName: String {
        "\(scheme) · \(targetName) · \(bundleID) · \(projectPath)"
    }

    var pickerDisplayName: String {
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        return "\(scheme) · \(targetName) — \(bundleID) · \(projectName)"
    }
}

struct XcodeProjectResolution: Equatable, Sendable {
    let candidates: [XcodeProjectCandidate]
    let diagnosticMessage: String?
    let isComplete: Bool
}

struct XcodeProjectValidation: Equatable, Sendable {
    let isValid: Bool
    let diagnosticMessage: String?
}

struct XcodeProjectResolver: Sendable {
    private let locateContainers: @Sendable (String) async throws -> [XcodeContainer]
    private let runCommand: @Sendable (String, [String], TimeInterval?) async throws -> CommandResult

    init(
        commandRunner: CommandRunner = CommandRunner()
    ) {
        let locator = XcodeProjectLocator(commandExecutor: commandRunner)
        self.locateContainers = { projectRootPath in
            try await locator.locateContainers(projectRootPath: projectRootPath)
        }
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try await commandRunner.runAsync(
                launchPath,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    init(
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult
    ) {
        let locator = XcodeProjectLocator()
        self.locateContainers = { projectRootPath in
            try await locator.locateContainers(projectRootPath: projectRootPath)
        }
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
    }

    init(
        locateProjectPaths: @escaping @Sendable (String) async throws -> [String],
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult
    ) {
        self.locateContainers = { projectRootPath in
            try await locateProjectPaths(projectRootPath).compactMap {
                XcodeContainer(path: $0)
            }
        }
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
    }

    init(
        locateContainers: @escaping @Sendable (String) async throws -> [XcodeContainer],
        runCommand: @escaping @Sendable (String, [String], TimeInterval?) throws -> CommandResult
    ) {
        self.locateContainers = locateContainers
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try runCommand(launchPath, arguments, timeoutSeconds)
        }
    }

    func resolve(projectRootPath: String) async -> XcodeProjectResolution {
        let containers: [XcodeContainer]
        do {
            try Task.checkCancellation()
            containers = Array(Set(
                try await locateContainers(projectRootPath)
            ))
            .sorted {
                ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return XcodeProjectResolution(
                candidates: [],
                diagnosticMessage: "项目识别已取消。",
                isComplete: false
            )
        } catch {
            return XcodeProjectResolution(
                candidates: [],
                diagnosticMessage: DiagnosticText.bounded(
                    error.localizedDescription
                ),
                isComplete: false
            )
        }
        guard !containers.isEmpty else {
            return XcodeProjectResolution(
                candidates: [],
                diagnosticMessage: "项目目录中没有找到 .xcodeproj 或 .xcworkspace。",
                isComplete: true
            )
        }
        guard containers.count <= 20 else {
            return XcodeProjectResolution(
                candidates: [],
                diagnosticMessage: "检测到超过 20 个 Xcode 容器，范围过大，已停止自动识别。",
                isComplete: false
            )
        }

        var candidates: [XcodeProjectCandidate] = []
        var diagnostics: [String] = []
        var listedSchemeCount = 0
        var listedTargetCount = 0
        for container in containers {
            do {
                let listing = try await projectListing(in: container)
                listedSchemeCount += listing.schemes.count
                if listedSchemeCount > 100 {
                    diagnostics.append("Scheme 总数超过 100 个，已停止自动识别。")
                    break
                }
                listedTargetCount += listing.targets.count
                if listedTargetCount > 100 {
                    diagnostics.append("Target 总数超过 100 个，已停止自动识别。")
                    break
                }
                for scheme in listing.schemes {
                    do {
                        let resolvedTargets = try await applicationTargets(
                            container: container,
                            scheme: scheme
                        )
                        candidates.append(contentsOf: resolvedTargets.map {
                            XcodeProjectCandidate(
                                container: $0.container,
                                scheme: scheme,
                                targetName: $0.targetName,
                                bundleID: $0.bundleID
                            )
                        })
                    } catch is CancellationError {
                        return XcodeProjectResolution(
                            candidates: [],
                            diagnosticMessage: "项目识别已取消。",
                            isComplete: false
                        )
                    } catch {
                        diagnostics.append("\(scheme)：\(error.localizedDescription)")
                    }
                }
            } catch is CancellationError {
                return XcodeProjectResolution(
                    candidates: [],
                    diagnosticMessage: "项目识别已取消。",
                    isComplete: false
                )
            } catch {
                diagnostics.append("\(URL(fileURLWithPath: container.path).lastPathComponent)：\(error.localizedDescription)")
            }
        }

        let uniqueCandidates = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .sorted {
            (
                $0.projectPath,
                $0.container.kind.rawValue,
                $0.scheme,
                $0.targetName,
                $0.bundleID
            ) < (
                $1.projectPath,
                $1.container.kind.rawValue,
                $1.scheme,
                $1.targetName,
                $1.bundleID
            )
        }

        let diagnosticMessage: String?
        if uniqueCandidates.isEmpty {
            diagnosticMessage = diagnostics.first
                ?? "没有从 Xcode 构建设置中找到可续签的 iOS App 目标；Framework 或 Library 目标不能单独安装到真机。"
        } else if uniqueCandidates.count > 1 {
            diagnosticMessage = "检测到多个 Scheme 与 App Target 组合，请明确选择。"
        } else {
            diagnosticMessage = diagnostics.first
        }
        return XcodeProjectResolution(
            candidates: Array(uniqueCandidates),
            diagnosticMessage: diagnosticMessage,
            isComplete: diagnostics.isEmpty
        )
    }

    func validateSelectedTarget(config: AppConfig) async -> XcodeProjectValidation {
        guard config.hasResolvedApplicationTarget,
              let projectPath = config.xcodeprojPath,
              let scheme = config.scheme,
              let targetName = config.targetName,
              let bundleID = config.bundleID,
              let container = XcodeContainer(path: projectPath) else {
            return XcodeProjectValidation(
                isValid: false,
                diagnosticMessage: "App 目标配置不完整。"
            )
        }
        do {
            let listing = try await projectListing(in: container)
            guard listing.schemes.contains(scheme) else {
                return XcodeProjectValidation(
                    isValid: false,
                    diagnosticMessage: "已保存的 Scheme 不再存在，请重新识别项目。"
                )
            }
            guard listing.targets.isEmpty
                    || listing.targets.contains(targetName) else {
                return XcodeProjectValidation(
                    isValid: false,
                    diagnosticMessage: "已保存的 App Target 不再存在，请重新识别项目。"
                )
            }
            let resolvedTargets = try await applicationTargets(
                container: container,
                scheme: scheme
            )
            let isValid = resolvedTargets.contains {
                $0.bundleID == bundleID
                    && $0.targetName == targetName
                    && $0.container.kind == container.kind
                    && URL(fileURLWithPath: $0.container.path)
                        .standardizedFileURL.path
                    == URL(fileURLWithPath: projectPath)
                        .standardizedFileURL.path
            }
            return XcodeProjectValidation(
                isValid: isValid,
                diagnosticMessage: isValid
                    ? nil
                    : "已保存的 App Target 或 Bundle ID 不再匹配可续签的 iPhone App 目标。"
            )
        } catch is CancellationError {
            return XcodeProjectValidation(
                isValid: false,
                diagnosticMessage: "项目目标验证已取消。"
            )
        } catch {
            return XcodeProjectValidation(
                isValid: false,
                diagnosticMessage: DiagnosticText.bounded(
                    error.localizedDescription
                )
            )
        }
    }

    private func projectListing(
        in container: XcodeContainer
    ) async throws -> XcodeListProject {
        try Task.checkCancellation()
        let result = try await runCommand(
            "/usr/bin/xcodebuild",
            ["-list", "-json"] + container.xcodebuildArguments,
            15
        )
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            throw XcodeProjectResolverError.commandFailed(commandMessage(from: result))
        }
        guard result.processGroupTerminationWasConfirmed else {
            throw XcodeProjectResolverError.commandFailed(
                "xcodebuild 进程树未能确认结束。"
            )
        }
        guard !result.standardOutputWasTruncated,
              !result.standardErrorWasTruncated else {
            throw XcodeProjectResolverError.outputTooLarge
        }
        let data = Data(result.standardOutput.utf8)
        let response = try JSONDecoder().decode(XcodeListResponse.self, from: data)
        let listedContainer: XcodeListProject?
        switch container.kind {
        case .project:
            listedContainer = response.project
        case .workspace:
            listedContainer = response.workspace
        }
        guard let listedContainer else {
            throw XcodeProjectResolverError.missingContainerListing(
                container.kind
            )
        }
        return XcodeListProject(
            schemes: normalizedNames(listedContainer.schemes),
            targets: normalizedNames(listedContainer.targets)
        )
    }

    private func applicationTargets(
        container: XcodeContainer,
        scheme: String
    ) async throws -> [XcodeApplicationTarget] {
        try Task.checkCancellation()
        let result = try await runCommand(
            "/usr/bin/xcodebuild",
            [
                "-showBuildSettings",
                "-json"
            ]
                + container.xcodebuildArguments
                + [
                "-scheme",
                scheme,
                "-sdk",
                "iphoneos"
            ],
            20
        )
        try Task.checkCancellation()
        guard result.processGroupTerminationWasConfirmed else {
            throw XcodeProjectResolverError.commandFailed(
                "xcodebuild 进程树未能确认结束。"
            )
        }
        guard !result.standardOutputWasTruncated,
              !result.standardErrorWasTruncated else {
            throw XcodeProjectResolverError.outputTooLarge
        }
        if result.terminationStatus != 0 {
            if try await isConfirmedNonIOSOnlyScheme(
                container: container,
                scheme: scheme
            ) {
                return []
            }
            throw XcodeProjectResolverError.commandFailed(commandMessage(from: result))
        }

        let records = try JSONDecoder().decode(
            [XcodeBuildSettingsRecord].self,
            from: Data(result.standardOutput.utf8)
        )
        return records.compactMap { record in
            let settings = record.buildSettings
            let isApplication = settings["PRODUCT_TYPE"] == "com.apple.product-type.application"
            let platformName = settings["PLATFORM_NAME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard isApplication,
                  platformName == "iphoneos",
                  let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleID.isEmpty,
                  !bundleID.contains("$(") else {
                return nil
            }
            return XcodeApplicationTarget(
                container: container,
                targetName: record.target,
                bundleID: bundleID
            )
        }
    }

    private func isConfirmedNonIOSOnlyScheme(
        container: XcodeContainer,
        scheme: String
    ) async throws -> Bool {
        let fallbackResult: CommandResult
        do {
            fallbackResult = try await runCommand(
                "/usr/bin/xcodebuild",
                [
                    "-showBuildSettings",
                    "-json"
                ]
                    + container.xcodebuildArguments
                    + [
                    "-scheme",
                    scheme
                ],
                20
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
        try Task.checkCancellation()
        guard fallbackResult.completedSuccessfullyAndFullyTerminated,
              !fallbackResult.standardOutputWasTruncated,
              !fallbackResult.standardErrorWasTruncated,
              let records = try? JSONDecoder().decode(
                [XcodeBuildSettingsRecord].self,
                from: Data(fallbackResult.standardOutput.utf8)
              ),
              !records.isEmpty else {
            return false
        }
        return !records.contains { record in
            let settings = record.buildSettings
            guard settings["PRODUCT_TYPE"]
                    == "com.apple.product-type.application" else {
                return false
            }
            let platformName = settings["PLATFORM_NAME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let sdkName = settings["SDK_NAME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let sdkRoot = settings["SDKROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let supportedPlatforms = Set(
                (settings["SUPPORTED_PLATFORMS"] ?? "")
                    .split(whereSeparator: { $0.isWhitespace })
                    .map { $0.lowercased() }
            )
            return platformName == "iphoneos"
                || sdkName?.hasPrefix("iphoneos") == true
                || sdkRoot?.hasPrefix("iphoneos") == true
                || supportedPlatforms.contains("iphoneos")
        }
    }

    private func normalizedNames(_ names: [String]) -> [String] {
        Array(Set(names.compactMap { name in
            let normalized = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return normalized.isEmpty ? nil : normalized
        }))
        .sorted()
    }

    private func commandMessage(from result: CommandResult) -> String {
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            return DiagnosticText.bounded(message)
        }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "xcodebuild 执行失败。" : DiagnosticText.bounded(output)
    }
}

enum XcodeProjectResolverError: Error, LocalizedError {
    case commandFailed(String)
    case outputTooLarge
    case missingContainerListing(XcodeContainer.Kind)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            return message
        case .outputTooLarge:
            return "xcodebuild 返回的结构化结果过大，已停止解析以避免使用不完整配置。"
        case .missingContainerListing(let kind):
            let name = kind == .project ? "project" : "workspace"
            return "xcodebuild 未返回预期的 \(name) 结构化项目清单。"
        }
    }
}

private struct XcodeListResponse: Decodable {
    let project: XcodeListProject?
    let workspace: XcodeListProject?
}

private struct XcodeListProject: Decodable {
    let schemes: [String]
    let targets: [String]

    private enum CodingKeys: String, CodingKey {
        case schemes
        case targets
    }

    init(schemes: [String], targets: [String]) {
        self.schemes = schemes
        self.targets = targets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemes = try container.decodeIfPresent(
            [String].self,
            forKey: .schemes
        ) ?? []
        targets = try container.decodeIfPresent(
            [String].self,
            forKey: .targets
        ) ?? []
    }
}

private struct XcodeBuildSettingsRecord: Decodable {
    let target: String
    let buildSettings: [String: String]
}

private struct XcodeApplicationTarget {
    let container: XcodeContainer
    let targetName: String
    let bundleID: String
}
