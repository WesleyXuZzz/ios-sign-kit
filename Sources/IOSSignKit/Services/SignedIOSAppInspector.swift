import CryptoKit
import Foundation

enum SignedIOSAppCandidate: Equatable, Sendable {
    case application(URL)
    case productsDirectory(URL)
}

struct SignedIOSAppInspectionRequest: Equatable, Sendable {
    let derivedDataRootURL: URL
    let candidate: SignedIOSAppCandidate
    let expectedBundleIdentifier: String
    let expectedTeamIdentifier: String?
    let targetDeviceID: String
    let deploymentToken: String?
    let profileRefreshMode: ProvisioningProfileRefreshMode
    let previousProfileDigests: Set<String>
    let now: Date

    init(
        derivedDataRootURL: URL,
        candidate: SignedIOSAppCandidate,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String? = nil,
        targetDeviceID: String,
        deploymentToken: String? = nil,
        profileRefreshMode: ProvisioningProfileRefreshMode,
        previousProfileDigests: Set<String>,
        now: Date
    ) {
        self.derivedDataRootURL = derivedDataRootURL
        self.candidate = candidate
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.targetDeviceID = targetDeviceID
        self.deploymentToken = deploymentToken
        self.profileRefreshMode = profileRefreshMode
        self.previousProfileDigests = previousProfileDigests
        self.now = now
    }

    init(
        derivedDataRootURL: URL,
        candidate: SignedIOSAppCandidate,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String? = nil,
        targetDeviceID: String,
        deploymentToken: String? = nil,
        profileRefreshMode: ProvisioningProfileRefreshMode,
        previousProfileDigest: String?,
        now: Date
    ) {
        self.init(
            derivedDataRootURL: derivedDataRootURL,
            candidate: candidate,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedTeamIdentifier: expectedTeamIdentifier,
            targetDeviceID: targetDeviceID,
            deploymentToken: deploymentToken,
            profileRefreshMode: profileRefreshMode,
            previousProfileDigests: previousProfileDigest.map { [$0] } ?? [],
            now: now
        )
    }
}

struct VerifiedSignedIOSApp: Equatable, Sendable {
    let applicationURL: URL
    let bundleIdentifier: String
    let shortVersion: String
    let buildVersion: String
    let profileUUID: String
    let profileExpirationDate: Date
    let profileTeamIdentifier: String
    let profileDigest: String
}

enum SignedIOSAppInspectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest(String)
    case derivedDataRootUnavailable
    case artifactOutsideDerivedData
    case symbolicLinkNotAllowed(String)
    case applicationUnavailable
    case multipleMatchingApplications
    case applicationSearchLimitExceeded
    case invalidInfoPlist(String)
    case bundleIdentifierMismatch(expected: String, actual: String)
    case invalidExecutable
    case invalidProvisioningProfile(String)
    case profileExpired(Date)
    case profileApplicationIdentifierMismatch
    case profileTeamIdentifierMismatch(expected: String, actual: String)
    case profileDoesNotIncludeDevice
    case profileWasNotRefreshed
    case codeSignatureInvalid(String)
    case commandProcessTreeUnresolved(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let field):
            return "续签产物核验参数无效：\(field)。"
        case .derivedDataRootUnavailable:
            return "受控 DerivedData 目录不存在或不是目录。"
        case .artifactOutsideDerivedData:
            return "候选 App 不在本次受控 DerivedData 目录内。"
        case .symbolicLinkNotAllowed(let name):
            return "续签产物中的 \(name) 不得通过符号链接提供。"
        case .applicationUnavailable:
            return "没有找到唯一可核验的 iPhone App 构建产物。"
        case .multipleMatchingApplications:
            return "产品目录包含多个相同 Bundle ID 的 App，无法安全选择安装产物。"
        case .applicationSearchLimitExceeded:
            return "产品目录的层级或文件数量超过核验上限。"
        case .invalidInfoPlist(let reason):
            return "App 的 Info.plist 无效：\(reason)"
        case .bundleIdentifierMismatch(let expected, let actual):
            return "App 的 Bundle ID 为 \(actual)，与预期 \(expected) 不一致。"
        case .invalidExecutable:
            return "App 的主可执行文件缺失、不可执行或类型无效。"
        case .invalidProvisioningProfile(let reason):
            return "embedded.mobileprovision 无效：\(reason)"
        case .profileExpired(let date):
            return "embedded.mobileprovision 已于 \(date) 过期。"
        case .profileApplicationIdentifierMismatch:
            return "签名描述文件的 application-identifier 与目标 Bundle ID 不一致。"
        case .profileTeamIdentifierMismatch(let expected, let actual):
            return "签名描述文件的 Team 为 \(actual)，与 Xcode 构建 Team \(expected) 不一致。"
        case .profileDoesNotIncludeDevice:
            return "签名描述文件不包含当前目标设备。"
        case .profileWasNotRefreshed:
            return "强制刷新后签名描述文件未发生变化。"
        case .codeSignatureInvalid(let reason):
            return "App 代码签名核验失败：\(reason)"
        case .commandProcessTreeUnresolved(let reason):
            return "签名核验命令的进程树未确认结束：\(reason)"
        }
    }
}

struct SignedIOSAppInspector: Sendable {
    static let maximumInfoPlistBytes = 1 * 1_024 * 1_024
    static let maximumProvisioningProfileBytes = 4 * 1_024 * 1_024
    static let maximumDecodedProfileBytes = 1 * 1_024 * 1_024
    static let maximumProductSearchDepth = 4
    static let maximumProductSearchEntryCount = 512
    static let maximumProvisionedDeviceCount = 4_096
    static let maximumCommandOutputBytesPerStream = 1 * 1_024 * 1_024

    private let validateCodeSignature:
        @Sendable (URL, String?) async throws -> Void
    private let decodeProvisioningProfile:
        @Sendable (URL, String?) async throws -> Data

    init(commandExecutor: any CommandExecuting = CommandRunner()) {
        self.init { launchPath, arguments, environmentOverrides, timeoutSeconds in
            try await commandExecutor.runAsync(
                launchPath,
                arguments: arguments,
                currentDirectoryPath: nil,
                environmentOverrides: environmentOverrides,
                onOutput: nil,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    init(
        runCommand: @escaping @Sendable (
            String,
            [String],
            [String: String],
            TimeInterval?
        ) async throws -> CommandResult
    ) {
        self.validateCodeSignature = { applicationURL, deploymentToken in
            let result = try await runCommand(
                "/usr/bin/codesign",
                [
                    "--verify", "--deep", "--strict", "--verbose=2",
                    applicationURL.path
                ],
                Self.deploymentEnvironment(deploymentToken),
                15
            )
            guard result.processGroupTerminationWasConfirmed else {
                throw SignedIOSAppInspectionError.commandProcessTreeUnresolved(
                    "codesign 的进程组仍可能存在。"
                )
            }
            guard result.completedSuccessfullyAndFullyTerminated,
                  !result.standardOutputWasTruncated,
                  !result.standardErrorWasTruncated,
                  Self.commandOutputIsWithinLimit(result) else {
                let diagnostic = result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
                throw SignedIOSAppInspectionError.codeSignatureInvalid(
                    DiagnosticText.bounded(diagnostic.isEmpty
                        ? "codesign 返回退出状态 \(result.terminationStatus)。"
                        : diagnostic)
                )
            }
        }
        self.decodeProvisioningProfile = { profileURL, deploymentToken in
            let result = try await runCommand(
                "/usr/bin/security",
                ["cms", "-D", "-i", profileURL.path],
                Self.deploymentEnvironment(deploymentToken),
                10
            )
            guard result.processGroupTerminationWasConfirmed else {
                throw SignedIOSAppInspectionError.commandProcessTreeUnresolved(
                    "security cms 的进程组仍可能存在。"
                )
            }
            guard result.completedSuccessfullyAndFullyTerminated,
                  !result.standardOutputWasTruncated,
                  !result.standardErrorWasTruncated,
                  Self.commandOutputIsWithinLimit(result) else {
                let diagnostic = result.standardError.isEmpty
                    ? result.standardOutput
                    : result.standardError
                throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                    DiagnosticText.bounded(diagnostic.isEmpty
                        ? "security cms 返回退出状态 \(result.terminationStatus)。"
                        : diagnostic)
                )
            }
            guard result.standardOutput.utf8.count <= Self.maximumDecodedProfileBytes else {
                throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                    "解码结果超过允许的字节上限。"
                )
            }
            return Data(result.standardOutput.utf8)
        }
    }

    init(
        validateCodeSignature: @escaping @Sendable (URL) async throws -> Void,
        decodeProvisioningProfile: @escaping @Sendable (URL) async throws -> Data
    ) {
        self.validateCodeSignature = { applicationURL, _ in
            try await validateCodeSignature(applicationURL)
        }
        self.decodeProvisioningProfile = { profileURL, _ in
            try await decodeProvisioningProfile(profileURL)
        }
    }

    func inspect(
        _ request: SignedIOSAppInspectionRequest
    ) async throws -> VerifiedSignedIOSApp {
        guard DeviceIdentityValidator.isSafe(request.expectedBundleIdentifier) else {
            throw SignedIOSAppInspectionError.invalidRequest("Bundle ID")
        }
        if let expectedTeamIdentifier = request.expectedTeamIdentifier,
           DevelopmentTeamIdentifier(
               rawValue: expectedTeamIdentifier
           ) == nil {
            throw SignedIOSAppInspectionError.invalidRequest("开发团队")
        }
        guard DeviceIdentityValidator.isSafe(request.targetDeviceID) else {
            throw SignedIOSAppInspectionError.invalidRequest("设备 ID")
        }
        if let deploymentToken = request.deploymentToken,
           DeploymentToken(rawValue: deploymentToken) == nil {
            throw SignedIOSAppInspectionError.invalidRequest("部署令牌")
        }
        guard request.previousProfileDigests.allSatisfy(Self.isSHA256Digest) else {
            throw SignedIOSAppInspectionError.invalidRequest("旧 Profile 指纹")
        }

        let rootURL = request.derivedDataRootURL.standardizedFileURL
        guard Self.isDirectoryNonSymbolicLink(rootURL) else {
            throw SignedIOSAppInspectionError.derivedDataRootUnavailable
        }
        let applicationURL = try Self.resolveApplicationURL(
            from: request.candidate,
            rootURL: rootURL,
            expectedBundleIdentifier: request.expectedBundleIdentifier
        )

        let info = try Self.readApplicationInfo(
            at: applicationURL,
            expectedBundleIdentifier: request.expectedBundleIdentifier
        )
        let executableURL = applicationURL.appendingPathComponent(info.executableName)
        guard Self.isRegularNonSymbolicLink(executableURL),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SignedIOSAppInspectionError.invalidExecutable
        }

        let profileURL = applicationURL.appendingPathComponent("embedded.mobileprovision")
        guard Self.isRegularNonSymbolicLink(profileURL) else {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile("文件不存在或类型无效。")
        }
        let profileData: Data
        do {
            profileData = try BoundedFileReader().data(
                at: profileURL,
                maximumBytes: Self.maximumProvisioningProfileBytes
            )
        } catch {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        let decodedProfileData: Data
        do {
            decodedProfileData = try await decodeProvisioningProfile(
                profileURL,
                request.deploymentToken
            )
        } catch let error as SignedIOSAppInspectionError {
            throw error
        } catch {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        guard decodedProfileData.count <= Self.maximumDecodedProfileBytes else {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                "解码结果超过允许的字节上限。"
            )
        }
        let profileDataAfterDecoding: Data
        do {
            profileDataAfterDecoding = try BoundedFileReader().data(
                at: profileURL,
                maximumBytes: Self.maximumProvisioningProfileBytes
            )
        } catch {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        guard profileDataAfterDecoding == profileData else {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                "文件在核验期间发生变化。"
            )
        }
        let profile = try Self.parseProfile(
            decodedProfileData,
            expectedBundleIdentifier: request.expectedBundleIdentifier,
            expectedTeamIdentifier: request.expectedTeamIdentifier,
            targetDeviceID: request.targetDeviceID,
            now: request.now
        )
        let profileDigest = Self.sha256Hex(profileData)
        if request.profileRefreshMode == .force,
           request.previousProfileDigests.contains(where: {
               $0.caseInsensitiveCompare(profileDigest) == .orderedSame
           }) {
            throw SignedIOSAppInspectionError.profileWasNotRefreshed
        }

        do {
            try await validateCodeSignature(
                applicationURL,
                request.deploymentToken
            )
        } catch let error as SignedIOSAppInspectionError {
            throw error
        } catch {
            throw SignedIOSAppInspectionError.codeSignatureInvalid(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        let profileDataAfterSignatureValidation: Data
        do {
            profileDataAfterSignatureValidation = try BoundedFileReader().data(
                at: profileURL,
                maximumBytes: Self.maximumProvisioningProfileBytes
            )
        } catch {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        guard profileDataAfterSignatureValidation == profileData else {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                "文件在代码签名核验期间发生变化。"
            )
        }

        return VerifiedSignedIOSApp(
            applicationURL: applicationURL,
            bundleIdentifier: info.bundleIdentifier,
            shortVersion: info.shortVersion,
            buildVersion: info.buildVersion,
            profileUUID: profile.uuid,
            profileExpirationDate: profile.expirationDate,
            profileTeamIdentifier: profile.teamIdentifier,
            profileDigest: profileDigest
        )
    }

    private static func resolveApplicationURL(
        from candidate: SignedIOSAppCandidate,
        rootURL: URL,
        expectedBundleIdentifier: String
    ) throws -> URL {
        switch candidate {
        case .application(let applicationURL):
            let standardizedURL = applicationURL.standardizedFileURL
            try requireContained(standardizedURL, in: rootURL)
            guard standardizedURL.pathExtension == "app",
                  isDirectoryNonSymbolicLink(standardizedURL) else {
                throw SignedIOSAppInspectionError.applicationUnavailable
            }
            return standardizedURL.resolvingSymlinksInPath()
        case .productsDirectory(let productsDirectoryURL):
            let standardizedURL = productsDirectoryURL.standardizedFileURL
            try requireContained(standardizedURL, in: rootURL)
            guard isDirectoryNonSymbolicLink(standardizedURL) else {
                throw SignedIOSAppInspectionError.applicationUnavailable
            }
            return try resolveApplicationFromProductsDirectory(
                standardizedURL,
                rootURL: rootURL,
                expectedBundleIdentifier: expectedBundleIdentifier
            )
        }
    }

    private static func resolveApplicationFromProductsDirectory(
        _ productsDirectoryURL: URL,
        rootURL: URL,
        expectedBundleIdentifier: String
    ) throws -> URL {
        var pendingDirectories: [(url: URL, depth: Int)] = [
            (productsDirectoryURL, 0)
        ]
        var visitedEntryCount = 0
        var matchingApplications: [URL] = []

        while let directory = pendingDirectories.popLast() {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles]
            )
            visitedEntryCount += entries.count
            guard visitedEntryCount <= maximumProductSearchEntryCount else {
                throw SignedIOSAppInspectionError.applicationSearchLimitExceeded
            }

            for entry in entries.sorted(by: { $0.path < $1.path }) {
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                if values.isSymbolicLink == true {
                    if entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                        throw SignedIOSAppInspectionError.symbolicLinkNotAllowed(
                            entry.lastPathComponent
                        )
                    }
                    continue
                }
                guard values.isDirectory == true else {
                    continue
                }
                if entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    try requireContained(entry, in: rootURL)
                    do {
                        _ = try readApplicationInfo(
                            at: entry,
                            expectedBundleIdentifier: expectedBundleIdentifier
                        )
                        matchingApplications.append(entry.resolvingSymlinksInPath())
                        guard matchingApplications.count == 1 else {
                            throw SignedIOSAppInspectionError.multipleMatchingApplications
                        }
                    } catch SignedIOSAppInspectionError.bundleIdentifierMismatch {
                        continue
                    }
                    continue
                }
                guard directory.depth < maximumProductSearchDepth else {
                    continue
                }
                pendingDirectories.append((entry, directory.depth + 1))
            }
        }

        guard let applicationURL = matchingApplications.first else {
            throw SignedIOSAppInspectionError.applicationUnavailable
        }
        return applicationURL
    }

    private static func requireContained(_ candidateURL: URL, in rootURL: URL) throws {
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidateURL.resolvingSymlinksInPath()
        guard resolvedCandidate.path == resolvedRoot.path
                || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/") else {
            throw SignedIOSAppInspectionError.artifactOutsideDerivedData
        }
        var currentURL = resolvedRoot
        let rootComponents = resolvedRoot.pathComponents
        for component in resolvedCandidate.pathComponents.dropFirst(rootComponents.count) {
            currentURL.appendPathComponent(component)
            let resourceValues = try? currentURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            if resourceValues?.isSymbolicLink == true {
                throw SignedIOSAppInspectionError.symbolicLinkNotAllowed(component)
            }
        }
    }

    private static func readApplicationInfo(
        at applicationURL: URL,
        expectedBundleIdentifier: String
    ) throws -> ApplicationInfo {
        let infoURL = applicationURL.appendingPathComponent("Info.plist")
        guard isRegularNonSymbolicLink(infoURL) else {
            throw SignedIOSAppInspectionError.invalidInfoPlist("文件不存在或类型无效。")
        }
        let data: Data
        do {
            data = try BoundedFileReader().data(
                at: infoURL,
                maximumBytes: maximumInfoPlistBytes
            )
        } catch {
            throw SignedIOSAppInspectionError.invalidInfoPlist(
                DiagnosticText.bounded(error.localizedDescription)
            )
        }
        guard let dictionary = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let bundleIdentifier = safeString(dictionary["CFBundleIdentifier"]),
              let shortVersion = safeString(dictionary["CFBundleShortVersionString"]),
              let buildVersion = safeString(dictionary["CFBundleVersion"]),
              let executableName = safePathComponent(dictionary["CFBundleExecutable"]) else {
            throw SignedIOSAppInspectionError.invalidInfoPlist("缺少必要的 App 身份字段。")
        }
        guard bundleIdentifier == expectedBundleIdentifier else {
            throw SignedIOSAppInspectionError.bundleIdentifierMismatch(
                expected: expectedBundleIdentifier,
                actual: bundleIdentifier
            )
        }
        return ApplicationInfo(
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableName: executableName
        )
    }

    private static func parseProfile(
        _ data: Data,
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String?,
        targetDeviceID: String,
        now: Date
    ) throws -> ProvisioningProfileInfo {
        guard let dictionary = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              let uuid = safeString(dictionary["UUID"]),
              UUID(uuidString: uuid) != nil,
              let expirationDate = dictionary["ExpirationDate"] as? Date,
              let teamIdentifiers = dictionary["TeamIdentifier"] as? [String],
              teamIdentifiers.count == 1,
              let teamIdentifier = teamIdentifiers.first,
              DeviceIdentityValidator.isSafe(teamIdentifier),
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let applicationIdentifier = safeString(
                entitlements["application-identifier"]
              ),
              let entitlementTeamIdentifier = safeString(
                entitlements["com.apple.developer.team-identifier"]
              ),
              entitlementTeamIdentifier == teamIdentifier else {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                "缺少必要的身份、团队或有效期字段。"
            )
        }
        if let expectedTeamIdentifier,
           teamIdentifier != expectedTeamIdentifier {
            throw SignedIOSAppInspectionError.profileTeamIdentifierMismatch(
                expected: expectedTeamIdentifier,
                actual: teamIdentifier
            )
        }
        guard expirationDate > now else {
            throw SignedIOSAppInspectionError.profileExpired(expirationDate)
        }
        guard applicationIdentifier
                == "\(teamIdentifier).\(expectedBundleIdentifier)" else {
            throw SignedIOSAppInspectionError.profileApplicationIdentifierMismatch
        }
        guard let provisionedDevices = dictionary["ProvisionedDevices"]
                as? [String],
              !provisionedDevices.isEmpty,
              provisionedDevices.count <= maximumProvisionedDeviceCount,
              provisionedDevices.allSatisfy(DeviceIdentityValidator.isSafe) else {
            throw SignedIOSAppInspectionError.invalidProvisioningProfile(
                "ProvisionedDevices 必须是非空且受限的设备 ID 列表。"
            )
        }
        guard provisionedDevices.contains(targetDeviceID) else {
            throw SignedIOSAppInspectionError.profileDoesNotIncludeDevice
        }
        return ProvisioningProfileInfo(
            uuid: uuid.uppercased(),
            expirationDate: expirationDate,
            teamIdentifier: teamIdentifier
        )
    }

    private static func safeString(_ value: Any?) -> String? {
        guard let value = value as? String,
              DeviceIdentityValidator.isSafe(value),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return value
    }

    private static func safePathComponent(_ value: Any?) -> String? {
        guard let value = safeString(value),
              value != ".", value != "..",
              !value.contains("/"), !value.contains(":") else {
            return nil
        }
        return value
    }

    private static func isRegularNonSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isDirectoryNonSymbolicLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
    }

    private static func commandOutputIsWithinLimit(
        _ result: CommandResult
    ) -> Bool {
        result.standardOutput.utf8.count <= maximumCommandOutputBytesPerStream
            && result.standardError.utf8.count <= maximumCommandOutputBytesPerStream
    }

    private static func deploymentEnvironment(
        _ deploymentToken: String?
    ) -> [String: String] {
        guard let deploymentToken else {
            return [:]
        }
        return [
            DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                deploymentToken
        ]
    }
}

private struct ApplicationInfo {
    let bundleIdentifier: String
    let shortVersion: String
    let buildVersion: String
    let executableName: String
}

private struct ProvisioningProfileInfo {
    let uuid: String
    let expirationDate: Date
    let teamIdentifier: String
}
