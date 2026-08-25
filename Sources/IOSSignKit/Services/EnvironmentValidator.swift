import Foundation

struct EnvironmentValidator {
    private let fileManager: FileManager
    private let processEnvironment: [String: String]

    init(fileManager: FileManager = .default, processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.processEnvironment = processEnvironment
    }

    func validate(config: AppConfig) -> EnvironmentStatus {
        let isXcodebuildAvailable = commandExists("xcodebuild")
        let isXcrunAvailable = commandExists("xcrun")
        let isProjectPathValid = validateProjectPath(config.projectRootPath)
        let isApplicationTargetResolved = validateApplicationTarget(config)

        let summary: String
        if config.projectRootPath == nil {
            summary = "请选择项目目录以完成配置。"
        } else if !isProjectPathValid {
            summary = "项目目录看起来不正确。"
        } else if !isApplicationTargetResolved {
            summary = "App 目标配置不完整或已失效，请重新识别并选择 Scheme。"
        } else if !isXcodebuildAvailable || !isXcrunAvailable {
            summary = "Xcode 命令行工具还没有准备好。"
        } else {
            summary = "环境检查通过，可以开始使用。"
        }

        return EnvironmentStatus(
            isXcodebuildAvailable: isXcodebuildAvailable,
            isXcrunAvailable: isXcrunAvailable,
            isProjectPathValid: isProjectPathValid,
            isApplicationTargetResolved: isApplicationTargetResolved,
            summary: summary
        )
    }

    func inferProjectDetails(from projectRootPath: String) -> AppConfigInference {
        return AppConfigInference(
            projectRootPath: projectRootPath,
            deployScriptPath: nil,
            xcodeprojPath: nil,
            scheme: nil,
            bundleID: nil
        )
    }

    func resolveBundleID(from config: AppConfig) -> String? {
        if let bundleID = config.bundleID,
           !bundleID.isEmpty,
           !bundleID.contains("$(") {
            return bundleID
        }

        return nil
    }

    private func validateProjectPath(_ projectRootPath: String?) -> Bool {
        guard let projectRootPath, !projectRootPath.isEmpty else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectRootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        return true
    }

    private func validateApplicationTarget(_ config: AppConfig) -> Bool {
        guard config.hasResolvedApplicationTarget,
              let projectRootPath = config.projectRootPath,
              let xcodeprojPath = config.xcodeprojPath,
              let scheme = config.scheme,
              let targetName = config.targetName,
              let bundleID = config.bundleID,
              !scheme.contains("\0"),
              !targetName.contains("\0"),
              !bundleID.contains("$("),
              !bundleID.contains("\0") else {
            return false
        }

        let resolvedRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedProject = URL(fileURLWithPath: xcodeprojPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard XcodeContainer(path: resolvedProject.path) != nil,
              resolvedProject.path.hasPrefix(resolvedRoot.path + "/") else {
            return false
        }

        var isDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: resolvedProject.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func commandExists(_ name: String) -> Bool {
        let candidateDirectories = (processEnvironment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for directory in candidateDirectories where !directory.isEmpty {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: path) {
                return true
            }
        }

        return false
    }
}

struct AppConfigInference: Equatable, Sendable {
    var projectRootPath: String
    var deployScriptPath: String?
    var xcodeprojPath: String?
    var scheme: String?
    var bundleID: String?
}
