import Foundation

struct XcodeProjectLocator: Sendable {
    typealias RunCommand = @Sendable (
        String,
        [String],
        TimeInterval?
    ) async throws -> CommandResult

    private static let timeoutSeconds: TimeInterval = 45
    private static let skippedDirectoryNames = [
        ".build", ".git", ".swiftpm", "DerivedData", "dist",
        "xcuserdata", "Pods", "Carthage", "vendor", "node_modules",
        ".expo", ".next", "build"
    ]

    private let runCommand: RunCommand

    init(commandExecutor: any CommandExecuting = CommandRunner()) {
        self.runCommand = { launchPath, arguments, timeoutSeconds in
            try await commandExecutor.runAsync(
                launchPath,
                arguments: arguments,
                currentDirectoryPath: nil,
                environmentOverrides: [:],
                onOutput: nil,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    init(runCommand: @escaping RunCommand) {
        self.runCommand = runCommand
    }

    func locate(projectRootPath: String) async throws -> [String] {
        try await locateContainers(projectRootPath: projectRootPath)
            .map(\.path)
    }

    func locateContainers(
        projectRootPath: String
    ) async throws -> [XcodeContainer] {
        try Task.checkCancellation()
        let result = try await runCommand(
            "/usr/bin/find",
            Self.findArguments(projectRootPath: projectRootPath),
            Self.timeoutSeconds
        )
        try Task.checkCancellation()

        guard result.processGroupTerminationWasConfirmed else {
            throw XcodeProjectLocatorError.processTerminationUnconfirmed
        }
        guard result.terminationStatus == 0 else {
            throw XcodeProjectLocatorError.commandFailed(
                commandMessage(from: result)
            )
        }
        guard !result.standardOutputWasTruncated,
              !result.standardErrorWasTruncated else {
            throw XcodeProjectLocatorError.outputTooLarge
        }
        guard result.standardOutput.isEmpty
                || result.standardOutput.utf8.last == 0 else {
            throw XcodeProjectLocatorError.incompleteOutput
        }

        return Array(Set(
            result.standardOutput
                .split(separator: "\0", omittingEmptySubsequences: true)
                .compactMap { XcodeContainer(path: String($0)) }
                .filter {
                    Self.isAllowed(
                        $0,
                        projectRootPath: projectRootPath
                    )
                }
        ))
        .sorted {
            ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue)
        }
    }

    private static func findArguments(projectRootPath: String) -> [String] {
        var skippedPredicates = ["-name", ".*"]
        for name in skippedDirectoryNames {
            skippedPredicates.append(contentsOf: ["-o", "-name", name])
        }

        return [
            "-H",
            projectRootPath,
            "(",
            "-type", "d",
            "!", "-path", projectRootPath,
            "("
        ]
            + skippedPredicates
            + [
                ")", "-prune", ")",
                "-o",
                "(",
                "-type", "d",
                "(",
                "-name", "*.xcodeproj",
                "-o",
                "-name", "*.xcworkspace",
                ")",
                "-prune",
                "-print0",
                ")"
            ]
    }

    private static func isAllowed(
        _ container: XcodeContainer,
        projectRootPath: String
    ) -> Bool {
        let candidateURL = URL(fileURLWithPath: container.path)
            .standardizedFileURL
        if container.kind == .workspace,
           candidateURL.lastPathComponent == "project.xcworkspace" {
            return false
        }

        let rootPath = URL(fileURLWithPath: projectRootPath)
            .standardizedFileURL
            .path
        let candidatePath = candidateURL.path
        let relativePath: String
        if candidatePath == rootPath {
            relativePath = candidateURL.lastPathComponent
        } else {
            let rootPrefix = rootPath.hasSuffix("/")
                ? rootPath
                : rootPath + "/"
            guard candidatePath.hasPrefix(rootPrefix) else {
                return false
            }
            relativePath = String(candidatePath.dropFirst(rootPrefix.count))
        }

        let components = relativePath.split(separator: "/").map(String.init)
        return !components.contains { component in
            component.hasPrefix(".")
                || skippedDirectoryNames.contains(component)
        }
    }

    private func commandMessage(from result: CommandResult) -> String {
        let error = result.standardError.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !error.isEmpty {
            return DiagnosticText.bounded(error)
        }
        let output = result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return output.isEmpty
            ? "find 执行失败（状态 \(result.terminationStatus)）。"
            : DiagnosticText.bounded(output)
    }
}

enum XcodeProjectLocatorError: Error, LocalizedError {
    case commandFailed(String)
    case outputTooLarge
    case incompleteOutput
    case processTerminationUnconfirmed

    var errorDescription: String? {
        let detail: String
        switch self {
        case .commandFailed(let message):
            detail = message
        case .outputTooLarge:
            detail = "find 输出过大或不完整。"
        case .incompleteOutput:
            detail = "find 未返回完整的 NUL 结尾结果。"
        case .processTerminationUnconfirmed:
            detail = "find 进程树未能确认结束。"
        }
        return "项目目录遍历失败，未自动猜测 App 目标：\(detail)"
    }
}
