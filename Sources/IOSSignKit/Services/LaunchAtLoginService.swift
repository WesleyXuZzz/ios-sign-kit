import Foundation
import ServiceManagement

enum LaunchAtLoginError: LocalizedError, Equatable {
    case missingApplicationIdentity
    case requiresApproval
    case registrationFailed(String)
    case unverifiedLaunchAgent(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingApplicationIdentity:
            return "无法确认当前 iOSSignKit 的应用身份，未修改登录启动项。"
        case .requiresApproval:
            return "iOSSignKit 登录启动项需要在“系统设置 > 通用 > 登录项与扩展”中重新允许。"
        case .registrationFailed(let reason):
            return "注册 iOSSignKit 登录启动项失败：\(reason)"
        case .unverifiedLaunchAgent(let path):
            return "发现无法确认归属的登录启动项，已保留原文件。请手动检查：\(path)"
        case .migrationFailed(let reason):
            return "迁移旧登录启动项失败，已保留旧配置：\(reason)"
        }
    }
}

enum MainAppLoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

struct MainAppLoginItemController: Sendable {
    let status: @Sendable () -> MainAppLoginItemStatus
    let register: @Sendable () throws -> Void
    let unregister: @Sendable () throws -> Void

    static let system = MainAppLoginItemController(
        status: {
            switch SMAppService.mainApp.status {
            case .notRegistered:
                return .notRegistered
            case .enabled:
                return .enabled
            case .requiresApproval:
                return .requiresApproval
            case .notFound:
                return .notFound
            @unknown default:
                return .notFound
            }
        },
        register: {
            try SMAppService.mainApp.register()
        },
        unregister: {
            try SMAppService.mainApp.unregister()
        }
    )
}

struct LaunchAtLoginService: Sendable {
    static let legacyBundleIdentifier = "dev.example.iossignkit"

    private let syncOverride: (@Sendable (Bool) throws -> Void)?
    private let currentStatusOverride: (@Sendable () -> Bool)?
    private let mainAppLoginItem: MainAppLoginItemController
    private let launchAgentsDirectory: URL
    private let currentBundleIdentifier: String?
    private let bundleURL: URL
    private let executableURL: URL?
    private let removeItem: @Sendable (URL) throws -> Void

    init() {
        self.syncOverride = nil
        self.currentStatusOverride = nil
        self.mainAppLoginItem = .system
        self.launchAgentsDirectory = FileManager().homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.currentBundleIdentifier = Bundle.main.bundleIdentifier
        self.bundleURL = Bundle.main.bundleURL
        self.executableURL = Bundle.main.executableURL
        self.removeItem = { try FileManager().removeItem(at: $0) }
    }

    init(
        sync: @escaping @Sendable (Bool) throws -> Void,
        currentStatus: @escaping @Sendable () -> Bool
    ) {
        self.syncOverride = sync
        self.currentStatusOverride = currentStatus
        self.mainAppLoginItem = .system
        self.launchAgentsDirectory = URL(fileURLWithPath: "/")
        self.currentBundleIdentifier = nil
        self.bundleURL = URL(fileURLWithPath: "/")
        self.executableURL = nil
        self.removeItem = { _ in }
    }

    init(
        mainAppLoginItem: MainAppLoginItemController,
        launchAgentsDirectory: URL,
        currentBundleIdentifier: String,
        bundleURL: URL,
        executableURL: URL?,
        removeItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager().removeItem(at: $0)
        }
    ) {
        self.syncOverride = nil
        self.currentStatusOverride = nil
        self.mainAppLoginItem = mainAppLoginItem
        self.launchAgentsDirectory = launchAgentsDirectory
        self.currentBundleIdentifier = currentBundleIdentifier
        self.bundleURL = bundleURL
        self.executableURL = executableURL
        self.removeItem = removeItem
    }

    func sync(isEnabled: Bool) throws {
        if let syncOverride {
            try syncOverride(isEnabled)
            return
        }
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            if !isEnabled {
                return
            }
            throw LaunchAtLoginError.missingApplicationIdentity
        }
        if isEnabled {
            try enable(currentBundleIdentifier: currentBundleIdentifier)
        } else {
            try disable(currentBundleIdentifier: currentBundleIdentifier)
        }
    }

    func currentStatus() -> Bool {
        if let currentStatusOverride {
            return currentStatusOverride()
        }
        if mainAppLoginItem.status() == .enabled {
            return true
        }
        guard let currentBundleIdentifier,
              let arguments = fallbackProgramArguments() else {
            return false
        }
        return ownership(
            at: launchAgentURL(label: currentBundleIdentifier),
            expectedLabel: currentBundleIdentifier
        ) == .owned
            && launchAgentArguments(
                at: launchAgentURL(label: currentBundleIdentifier)
            ) == arguments
    }

    private func enable(currentBundleIdentifier: String) throws {
        try validateLaunchAgentOwnership(
            currentBundleIdentifier: currentBundleIdentifier
        )

        var registeredDuringThisCall = false
        switch mainAppLoginItem.status() {
        case .enabled:
            break
        case .requiresApproval:
            throw LaunchAtLoginError.requiresApproval
        case .notFound:
            try installFallbackLaunchAgent(
                currentBundleIdentifier: currentBundleIdentifier
            )
            return
        case .notRegistered:
            do {
                try mainAppLoginItem.register()
                registeredDuringThisCall = true
            } catch {
                if isServiceError(error, code: kSMErrorInvalidSignature) {
                    try installFallbackLaunchAgent(
                        currentBundleIdentifier: currentBundleIdentifier
                    )
                    return
                }
                if isServiceError(error, code: kSMErrorAlreadyRegistered),
                   mainAppLoginItem.status() == .enabled {
                    break
                }
                if isServiceError(error, code: kSMErrorLaunchDeniedByUser) {
                    throw LaunchAtLoginError.requiresApproval
                }
                throw LaunchAtLoginError.registrationFailed(
                    error.localizedDescription
                )
            }
        }

        do {
            try removeOwnedLaunchAgentsTransactionally(
                currentBundleIdentifier: currentBundleIdentifier
            )
        } catch {
            guard registeredDuringThisCall else {
                throw error
            }
            do {
                try mainAppLoginItem.unregister()
            } catch let rollbackError {
                throw LaunchAtLoginError.migrationFailed(
                    "\(error.localizedDescription)；新登录项回滚也失败：\(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func disable(currentBundleIdentifier: String) throws {
        switch mainAppLoginItem.status() {
        case .enabled, .requiresApproval:
            do {
                try mainAppLoginItem.unregister()
            } catch {
                if !isServiceError(error, code: kSMErrorJobNotFound) {
                    throw LaunchAtLoginError.registrationFailed(
                        error.localizedDescription
                    )
                }
            }
        case .notRegistered, .notFound:
            break
        }
        try removeOwnedLaunchAgentsTransactionally(
            currentBundleIdentifier: currentBundleIdentifier
        )
    }

    private func installFallbackLaunchAgent(
        currentBundleIdentifier: String
    ) throws {
        guard let arguments = fallbackProgramArguments() else {
            throw LaunchAtLoginError.missingApplicationIdentity
        }
        let currentURL = launchAgentURL(label: currentBundleIdentifier)
        let legacyURL = launchAgentURL(label: Self.legacyBundleIdentifier)
        let currentOwnership = ownership(
            at: currentURL,
            expectedLabel: currentBundleIdentifier
        )
        let legacyOwnership = ownership(
            at: legacyURL,
            expectedLabel: Self.legacyBundleIdentifier
        )

        if currentOwnership == .unverified {
            throw LaunchAtLoginError.unverifiedLaunchAgent(currentURL.path)
        }
        if legacyOwnership == .unverified {
            throw LaunchAtLoginError.unverifiedLaunchAgent(legacyURL.path)
        }

        let previousCurrentData = currentOwnership == .owned
            ? try Data(contentsOf: currentURL)
            : nil
        try FileManager().createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        let data = try launchAgentData(
            label: currentBundleIdentifier,
            arguments: arguments
        )
        try data.write(to: currentURL, options: .atomic)

        guard legacyOwnership == .owned else {
            return
        }
        do {
            try removeItem(legacyURL)
        } catch {
            do {
                if let previousCurrentData {
                    try previousCurrentData.write(
                        to: currentURL,
                        options: .atomic
                    )
                } else {
                    try removeItem(currentURL)
                }
            } catch {
                throw LaunchAtLoginError.migrationFailed(
                    "\(error.localizedDescription)；兼容登录项回滚也失败"
                )
            }
            throw LaunchAtLoginError.migrationFailed(
                error.localizedDescription
            )
        }
    }

    private func validateLaunchAgentOwnership(
        currentBundleIdentifier: String
    ) throws {
        for (url, label) in launchAgentCandidates(
            currentBundleIdentifier: currentBundleIdentifier
        ) where ownership(at: url, expectedLabel: label) == .unverified {
            throw LaunchAtLoginError.unverifiedLaunchAgent(url.path)
        }
    }

    private func removeOwnedLaunchAgentsTransactionally(
        currentBundleIdentifier: String
    ) throws {
        let ownedItems = try launchAgentCandidates(
            currentBundleIdentifier: currentBundleIdentifier
        ).compactMap { url, label -> (URL, Data)? in
            guard ownership(at: url, expectedLabel: label) == .owned else {
                return nil
            }
            return (url, try Data(contentsOf: url))
        }
        var removedItems: [(URL, Data)] = []

        do {
            for item in ownedItems {
                try removeItem(item.0)
                removedItems.append(item)
            }
        } catch {
            var rollbackFailures: [String] = []
            for (url, data) in removedItems {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    rollbackFailures.append(error.localizedDescription)
                }
            }
            let suffix = rollbackFailures.isEmpty
                ? ""
                : "；旧配置回滚也失败：\(rollbackFailures.joined(separator: "；"))"
            throw LaunchAtLoginError.migrationFailed(
                error.localizedDescription + suffix
            )
        }
    }

    private func launchAgentCandidates(
        currentBundleIdentifier: String
    ) -> [(URL, String)] {
        [
            (
                launchAgentURL(label: currentBundleIdentifier),
                currentBundleIdentifier
            ),
            (
                launchAgentURL(label: Self.legacyBundleIdentifier),
                Self.legacyBundleIdentifier
            ),
        ]
    }

    private func launchAgentURL(label: String) -> URL {
        launchAgentsDirectory.appendingPathComponent(label + ".plist")
    }

    private func launchAgentData(
        label: String,
        arguments: [String]
    ) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private func fallbackProgramArguments() -> [String]? {
        guard bundleURL.pathExtension == "app",
              let executableURL,
              executableURL.path.hasPrefix(bundleURL.path + "/"),
              isExecutableRegularNonSymbolicLink(executableURL) else {
            return nil
        }
        return [executableURL.path]
    }

    private func ownership(
        at url: URL,
        expectedLabel: String
    ) -> LaunchAgentOwnership {
        guard FileManager().fileExists(atPath: url.path) else {
            return .absent
        }
        guard isRegularNonSymbolicLink(url),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              plist["Label"] as? String == expectedLabel,
              let arguments = plist["ProgramArguments"] as? [String],
              isVerifiedIOSSignKitEntry(arguments) else {
            return .unverified
        }
        return .owned
    }

    private func launchAgentArguments(at url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["ProgramArguments"] as? [String]
    }

    private func isVerifiedIOSSignKitEntry(_ arguments: [String]) -> Bool {
        if arguments.count == 1 {
            let candidate = URL(fileURLWithPath: arguments[0])
            guard candidate.path.hasPrefix("/"),
                  candidate.lastPathComponent == "IOSSignKit",
                  isExecutableRegularNonSymbolicLink(candidate) else {
                return false
            }
            let candidateBundleURL = candidate
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return isVerifiedIOSSignKitBundle(candidateBundleURL)
        }
        guard arguments.count == 2, arguments[0] == "/usr/bin/open" else {
            return false
        }
        return isVerifiedIOSSignKitBundle(
            URL(fileURLWithPath: arguments[1])
        )
    }

    private func isVerifiedIOSSignKitBundle(_ candidateBundleURL: URL) -> Bool {
        guard candidateBundleURL.path.hasPrefix("/"),
              candidateBundleURL.pathExtension == "app",
              isDirectoryNonSymbolicLink(candidateBundleURL) else {
            return false
        }
        let infoURL = candidateBundleURL
            .appendingPathComponent("Contents/Info.plist")
        guard isRegularNonSymbolicLink(infoURL),
              let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              [
                Self.legacyBundleIdentifier,
                currentBundleIdentifier,
              ].compactMap({ $0 }).contains(identifier),
              info["CFBundleExecutable"] as? String == "IOSSignKit" else {
            return false
        }
        let candidateExecutableURL = candidateBundleURL
            .appendingPathComponent("Contents/MacOS/IOSSignKit")
        return isExecutableRegularNonSymbolicLink(candidateExecutableURL)
    }

    private func isServiceError(_ error: Error, code: Int) -> Bool {
        let nsError = error as NSError
        guard nsError.code == code else {
            return false
        }
        if nsError.domain == "kSMErrorDomainFramework" {
            return true
        }
        if #available(macOS 15.0, *) {
            return nsError.domain == SMAppServiceErrorDomain
        }
        return false
    }

    private func isRegularNonSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isExecutableRegularNonSymbolicLink(_ url: URL) -> Bool {
        isRegularNonSymbolicLink(url)
            && FileManager().isExecutableFile(atPath: url.path)
    }

    private func isDirectoryNonSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}

private enum LaunchAgentOwnership {
    case absent
    case owned
    case unverified
}
