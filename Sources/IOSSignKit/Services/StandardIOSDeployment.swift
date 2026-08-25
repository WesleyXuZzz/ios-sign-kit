import Darwin
import Foundation

struct StandardIOSDeploymentRequest: Sendable {
    let projectRootURL: URL
    let container: XcodeContainer
    let scheme: String
    let targetName: String
    let bundleIdentifier: String
    let deviceID: String
    let deviceName: String
    let deploymentToken: String
    let profileRefreshMode: ProvisioningProfileRefreshMode
}

struct DeploymentExecutionResult: Sendable {
    let commandResult: CommandResult
    let verifiedProfileExpirationDate: Date?
    let profileCacheRecoveryWasConfirmed: Bool

    init(
        commandResult: CommandResult,
        verifiedProfileExpirationDate: Date?,
        profileCacheRecoveryWasConfirmed: Bool = true
    ) {
        self.commandResult = commandResult
        self.verifiedProfileExpirationDate = verifiedProfileExpirationDate
        self.profileCacheRecoveryWasConfirmed =
            profileCacheRecoveryWasConfirmed
    }
}

protocol DeploymentExecution: AnyObject, Sendable {
    var processGroupIdentifier: Int32 { get }

    func cancel()
    func cancelAndWaitForTermination(timeoutSeconds: TimeInterval) -> Bool
    func waitUntilExit() -> DeploymentExecutionResult
}

protocol DeploymentStageCommand: AnyObject, Sendable {
    var processGroupIdentifier: Int32 { get }

    func cancel()
    func waitUntilExit(timeoutSeconds: TimeInterval?) -> CommandResult
}

extension RunningCommand: DeploymentStageCommand {}

private struct DeploymentTranscript: Sendable {
    static let maximumBytesPerStream = 8 * 1_024 * 1_024

    private var standardOutput = BoundedDeploymentTranscriptStream(
        maximumBytes: maximumBytesPerStream
    )
    private var standardError = BoundedDeploymentTranscriptStream(
        maximumBytes: maximumBytesPerStream
    )
    var standardOutputWasTruncated = false
    var standardErrorWasTruncated = false
    var processGroupTerminationWasConfirmed = true

    mutating func append(
        stage: String,
        result: CommandResult
    ) {
        appendOutput("\n=== \(stage) ===\n")
        appendOutput(result.standardOutput)
        appendError("\n=== \(stage) ===\n")
        appendError(result.standardError)
        standardOutputWasTruncated = standardOutputWasTruncated
            || result.standardOutputWasTruncated
            || standardOutput.wasTruncated
        standardErrorWasTruncated = standardErrorWasTruncated
            || result.standardErrorWasTruncated
            || standardError.wasTruncated
        processGroupTerminationWasConfirmed =
            processGroupTerminationWasConfirmed
                && result.processGroupTerminationWasConfirmed
    }

    mutating func appendDiagnostic(_ diagnostic: String) {
        appendError("\n=== iOSSignKit ===\n")
        appendError(diagnostic)
        appendError("\n")
    }

    mutating func appendOutput(_ output: String) {
        standardOutput.append(output)
        standardOutputWasTruncated = standardOutputWasTruncated
            || standardOutput.wasTruncated
    }

    mutating func markProcessGroupTerminationUnconfirmed() {
        processGroupTerminationWasConfirmed = false
    }

    private mutating func appendError(_ output: String) {
        standardError.append(output)
        standardErrorWasTruncated = standardErrorWasTruncated
            || standardError.wasTruncated
    }

    func result(terminationStatus: Int32) -> CommandResult {
        CommandResult(
            standardOutput: standardOutput.stringValue,
            standardError: standardError.stringValue,
            terminationStatus: terminationStatus,
            standardOutputWasTruncated: standardOutputWasTruncated,
            standardErrorWasTruncated: standardErrorWasTruncated,
            processGroupTerminationWasConfirmed:
                processGroupTerminationWasConfirmed
        )
    }
}

private struct BoundedDeploymentTranscriptStream: Sendable {
    private static let truncationMarker = Data(
        "\n… iOSSignKit transcript truncated …\n".utf8
    )
    private static let utf8BoundarySafetyBytes = 16

    private let maximumBytes: Int
    private let headLimit: Int
    private let tailLimit: Int
    private var head = Data()
    private var tail = Data()
    private(set) var wasTruncated = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(
            maximumBytes,
            Self.truncationMarker.count + Self.utf8BoundarySafetyBytes + 2
        )
        let payloadLimit = self.maximumBytes
            - Self.truncationMarker.count
            - Self.utf8BoundarySafetyBytes
        headLimit = payloadLimit / 2
        tailLimit = payloadLimit - headLimit
    }

    mutating func append(_ value: String) {
        let data = Data(value.utf8)
        guard !data.isEmpty else { return }

        if wasTruncated {
            appendToTail(data)
            return
        }
        if head.count + data.count <= maximumBytes {
            head.append(data)
            return
        }

        let previous = head
        head = Data(previous.prefix(headLimit))
        tail = Data(previous.dropFirst(min(previous.count, headLimit)))
        if tail.count > tailLimit {
            tail = Data(tail.suffix(tailLimit))
        }
        appendToTail(data)
        wasTruncated = true
    }

    var stringValue: String {
        guard wasTruncated else {
            return String(decoding: head, as: UTF8.self)
        }
        var value = Data()
        value.reserveCapacity(maximumBytes)
        value.append(head)
        value.append(Self.truncationMarker)
        value.append(tail)
        return String(decoding: value, as: UTF8.self)
    }

    private mutating func appendToTail(_ data: Data) {
        if data.count >= tailLimit {
            tail = Data(data.suffix(tailLimit))
            return
        }
        let overflow = max(tail.count + data.count - tailLimit, 0)
        if overflow > 0 {
            tail.removeFirst(overflow)
        }
        tail.append(data)
    }
}

private struct XcodeBuildSettingsEntry: Decodable {
    let target: String
    let buildSettings: [String: String]
}

private struct ResolvedIOSBuildProduct: Hashable, Sendable {
    let applicationURL: URL
    let developmentTeam: String
}

private enum StandardIOSDeploymentStageTimeout {
    static let buildSettings: TimeInterval = 60
    static let build: TimeInterval = 30 * 60
    static let install: TimeInterval = 5 * 60
    static let launch: TimeInterval = 60
}

struct StandardIOSDeploymentExecutor: Sendable {
    typealias StartCommand = @Sendable (
        String,
        [String],
        String?,
        [String: String],
        (@Sendable (String, Bool) -> Void)?
    ) throws -> any DeploymentStageCommand

    typealias RecordPreparedReceipt = @Sendable (
        StandardIOSDeploymentRequest,
        VerifiedSignedIOSApp,
        String,
        Date
    ) throws -> Void

    typealias MarkInstalledReceipt = @Sendable (
        String,
        Date
    ) throws -> Void

    private let startCommand: StartCommand
    private let inspectApplication: @Sendable (
        SignedIOSAppInspectionRequest
    ) async throws -> VerifiedSignedIOSApp
    private let prepareProfileCache: (@Sendable (
        String,
        String,
        ProvisioningProfileRefreshMode,
        String,
        Date
    ) async throws -> ProvisioningProfileCacheTransaction)?
    private let recordPreparedReceipt: RecordPreparedReceipt
    private let markInstalledReceipt: MarkInstalledReceipt
    private let makeWorkspaceURL: @Sendable (String) throws -> URL
    private let removeWorkspace: @Sendable (URL) throws -> Void

    init(commandRunner: CommandRunner = CommandRunner()) {
        startCommand = {
            launchPath,
            arguments,
            currentDirectoryPath,
            environment,
            onOutput in
            try commandRunner.start(
                launchPath,
                arguments: arguments,
                currentDirectoryPath: currentDirectoryPath,
                environmentOverrides: environment,
                onOutput: onOutput
            )
        }
        let inspector = SignedIOSAppInspector(
            commandExecutor: commandRunner
        )
        inspectApplication = { request in
            try await inspector.inspect(request)
        }
        let profileCacheManager = ProvisioningProfileCacheManager(
            commandExecutor: commandRunner
        )
        prepareProfileCache = {
            bundleIdentifier,
            expectedTeamIdentifier,
            refreshMode,
            deploymentToken,
            now in
            try await profileCacheManager.prepareTransaction(
                bundleIdentifier: bundleIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier,
                refreshMode: refreshMode,
                deploymentToken: deploymentToken,
                now: now
            )
        }
        let receiptStore = HostInstallReceiptStore()
        recordPreparedReceipt = { request, application, team, preparedAt in
            _ = try receiptStore.recordPrepared(
                deploymentToken: request.deploymentToken,
                bundleIdentifier: request.bundleIdentifier,
                deviceIdentifier: request.deviceID,
                teamIdentifier: team,
                shortVersion: application.shortVersion,
                buildVersion: application.buildVersion,
                profileUUID: application.profileUUID,
                profileDigest: application.profileDigest,
                profileExpirationDate: application.profileExpirationDate,
                preparedAt: preparedAt
            )
        }
        markInstalledReceipt = { deploymentToken, installedAt in
            _ = try receiptStore.markInstalled(
                deploymentToken: deploymentToken,
                installedAt: installedAt
            )
        }
        makeWorkspaceURL = Self.makeDefaultWorkspaceURL
        removeWorkspace = { workspaceURL in
            try Self.removeDefaultWorkspace(workspaceURL)
        }
    }

    init(
        startCommand: @escaping StartCommand,
        inspectApplication: @escaping @Sendable (
            SignedIOSAppInspectionRequest
        ) async throws -> VerifiedSignedIOSApp,
        prepareProfileCache: (@Sendable (
            String,
            String,
            ProvisioningProfileRefreshMode,
            String,
            Date
        ) async throws -> ProvisioningProfileCacheTransaction)? = nil,
        recordPreparedReceipt: @escaping RecordPreparedReceipt = {
            _, _, _, _ in
        },
        markInstalledReceipt: @escaping MarkInstalledReceipt = { _, _ in },
        makeWorkspaceURL: @escaping @Sendable (String) throws -> URL,
        removeWorkspace: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.startCommand = startCommand
        self.inspectApplication = inspectApplication
        self.prepareProfileCache = prepareProfileCache
        self.recordPreparedReceipt = recordPreparedReceipt
        self.markInstalledReceipt = markInstalledReceipt
        self.makeWorkspaceURL = makeWorkspaceURL
        self.removeWorkspace = removeWorkspace
    }

    func start(
        request: StandardIOSDeploymentRequest,
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) throws -> any DeploymentExecution {
        let validatedRequest = try Self.validate(request)
        let workspaceURL = try makeWorkspaceURL(
            validatedRequest.deploymentToken
        )
        let derivedDataURL = workspaceURL.appendingPathComponent(
            "DerivedData",
            isDirectory: true
        )
        try Self.preparePrivateDirectory(
            workspaceURL,
            createIfMissing: false
        )
        try Self.preparePrivateDirectory(
            derivedDataURL,
            createIfMissing: true
        )
        guard Self.isNonSymbolicLinkDirectory(workspaceURL),
              Self.isNonSymbolicLinkDirectory(derivedDataURL) else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }

        let environment = [
            DeploymentProcessRecovery.deploymentTokenEnvironmentKey:
                validatedRequest.deploymentToken
        ]
        let baseArguments = validatedRequest.container.xcodebuildArguments + [
            "-scheme", validatedRequest.scheme,
            "-destination", "id=\(validatedRequest.deviceID)",
            "-derivedDataPath", derivedDataURL.path
        ]
        onOutput?("\n[准备] 正在读取 Xcode 构建设置…\n", false)
        let firstCommand = try startCommand(
            "/usr/bin/xcodebuild",
            baseArguments + ["-showBuildSettings", "-json"],
            validatedRequest.projectRootURL.path,
            environment,
            onOutput
        )

        return StandardIOSDeploymentExecution(
            request: validatedRequest,
            workspaceURL: workspaceURL,
            derivedDataURL: derivedDataURL,
            baseXcodebuildArguments: baseArguments,
            environment: environment,
            firstCommand: firstCommand,
            startCommand: startCommand,
            inspectApplication: inspectApplication,
            prepareProfileCache: prepareProfileCache,
            recordPreparedReceipt: recordPreparedReceipt,
            markInstalledReceipt: markInstalledReceipt,
            removeWorkspace: removeWorkspace,
            onOutput: onOutput
        )
    }

    private static func validate(
        _ request: StandardIOSDeploymentRequest
    ) throws -> StandardIOSDeploymentRequest {
        guard DeploymentToken(rawValue: request.deploymentToken) != nil else {
            throw StandardIOSDeploymentError.invalidDeploymentToken
        }
        guard DeviceIdentityValidator.isSafe(request.scheme),
              DeviceIdentityValidator.isSafe(request.targetName),
              DeviceIdentityValidator.isSafe(request.bundleIdentifier),
              DeviceIdentityValidator.isSafe(request.deviceID),
              DeviceIdentityValidator.isSafe(request.deviceName) else {
            throw StandardIOSDeploymentError.invalidRequest
        }

        let projectRootURL = request.projectRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isNonSymbolicLinkDirectory(projectRootURL) else {
            throw StandardIOSDeploymentError.invalidProjectRoot
        }
        let containerURL = URL(fileURLWithPath: request.container.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isNonSymbolicLinkDirectory(containerURL),
              containerURL.path.hasPrefix(projectRootURL.path + "/"),
              let container = XcodeContainer(path: containerURL.path),
              container.kind == request.container.kind else {
            throw StandardIOSDeploymentError.invalidContainer
        }

        return StandardIOSDeploymentRequest(
            projectRootURL: projectRootURL,
            container: container,
            scheme: request.scheme,
            targetName: request.targetName,
            bundleIdentifier: request.bundleIdentifier,
            deviceID: request.deviceID,
            deviceName: request.deviceName,
            deploymentToken: request.deploymentToken,
            profileRefreshMode: request.profileRefreshMode
        )
    }

    private static func makeDefaultWorkspaceURL(
        deploymentToken: String
    ) throws -> URL {
        let cachesURL = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        guard isNonSymbolicLinkDirectory(cachesURL) else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        let applicationCachesURL = cachesURL.appendingPathComponent(
            "iOSSignKit",
            isDirectory: true
        )
        try preparePrivateDirectory(
            applicationCachesURL,
            createIfMissing: true
        )
        let rootURL = applicationCachesURL.appendingPathComponent(
            "Deployments",
            isDirectory: true
        )
        try preparePrivateDirectory(
            rootURL,
            createIfMissing: true
        )
        try retryStaleWorkspaceCleanup(
            in: rootURL,
            excludingDeploymentToken: deploymentToken
        )
        let workspaceURL = rootURL.appendingPathComponent(
            deploymentToken,
            isDirectory: true
        )
        guard workspaceURL.deletingLastPathComponent().standardizedFileURL.path
                == rootURL.standardizedFileURL.path else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        guard !FileManager.default.fileExists(
            atPath: workspaceURL.path
        ) else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        try preparePrivateDirectory(
            workspaceURL,
            createIfMissing: true
        )
        return workspaceURL
    }

    private static func removeDefaultWorkspace(_ workspaceURL: URL) throws {
        guard DeploymentToken(
            rawValue: workspaceURL.lastPathComponent
        ) != nil,
              isNonSymbolicLinkDirectory(workspaceURL) else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        try FileManager.default.removeItem(at: workspaceURL)
    }

    private static func isNonSymbolicLinkDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        createIfMissing: Bool
    ) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            guard createIfMissing else {
                throw StandardIOSDeploymentError.invalidWorkspace
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
        }
        guard isNonSymbolicLinkDirectory(url) else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700 else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
    }

    private static func retryStaleWorkspaceCleanup(
        in rootURL: URL,
        excludingDeploymentToken: String
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard entries.count <= 256 else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        for entry in entries {
            let standardizedEntry = entry.standardizedFileURL
            guard standardizedEntry.deletingLastPathComponent().path
                    == rootURL.standardizedFileURL.path,
                  standardizedEntry.lastPathComponent
                    != excludingDeploymentToken,
                  DeploymentToken(
                    rawValue: standardizedEntry.lastPathComponent
                  ) != nil,
                  isNonSymbolicLinkDirectory(standardizedEntry) else {
                continue
            }
            try? FileManager.default.removeItem(at: standardizedEntry)
        }
    }
}

enum StandardIOSDeploymentError: Error, Equatable, LocalizedError {
    case invalidRequest
    case invalidDeploymentToken
    case invalidProjectRoot
    case invalidContainer
    case invalidWorkspace
    case invalidBuildSettings(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "续签请求包含无效的项目、App 或设备身份。"
        case .invalidDeploymentToken:
            return "续签事务令牌无效。"
        case .invalidProjectRoot:
            return "项目根目录不存在、不是目录或不安全。"
        case .invalidContainer:
            return "Xcode 工程或工作区不存在、不安全，或不在项目目录内。"
        case .invalidWorkspace:
            return "无法创建安全的续签工作目录。"
        case .invalidBuildSettings(let reason):
            return "无法从 Xcode 构建设置确定唯一 App 产物：\(reason)"
        }
    }
}

struct StandardIOSDeploymentWorkspaceCleaner: Sendable {
    typealias CachesDirectoryProvider = @Sendable () throws -> URL
    typealias RemoveItem = @Sendable (URL) throws -> Void

    private let cachesDirectoryProvider: CachesDirectoryProvider
    private let removeItem: RemoveItem

    init() {
        cachesDirectoryProvider = {
            try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        }
        removeItem = { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    init(
        testingCachesDirectoryProvider: @escaping CachesDirectoryProvider,
        removeItem: @escaping RemoveItem = { url in
            try FileManager.default.removeItem(at: url)
        }
    ) {
        cachesDirectoryProvider = testingCachesDirectoryProvider
        self.removeItem = removeItem
    }

    func cleanup(deploymentToken: String) throws {
        guard DeploymentToken(rawValue: deploymentToken) != nil else {
            throw StandardIOSDeploymentError.invalidDeploymentToken
        }
        let cachesURL = try cachesDirectoryProvider().standardizedFileURL
        try requireSafeDirectory(cachesURL)

        let applicationCachesURL = cachesURL.appendingPathComponent(
            "iOSSignKit",
            isDirectory: true
        ).standardizedFileURL
        guard try validateOptionalDirectory(applicationCachesURL) else {
            return
        }
        let deploymentsRootURL = applicationCachesURL.appendingPathComponent(
            "Deployments",
            isDirectory: true
        ).standardizedFileURL
        guard try validateOptionalDirectory(deploymentsRootURL) else {
            return
        }
        let workspaceURL = deploymentsRootURL.appendingPathComponent(
            deploymentToken,
            isDirectory: true
        ).standardizedFileURL
        guard workspaceURL.deletingLastPathComponent().path
                == deploymentsRootURL.path else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        guard try validateOptionalDirectory(workspaceURL) else {
            return
        }
        try removeItem(workspaceURL)
    }

    private func validateOptionalDirectory(_ url: URL) throws -> Bool {
        guard let status = try fileStatus(url) else {
            return false
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        return true
    }

    private func requireSafeDirectory(_ url: URL) throws {
        guard try validateOptionalDirectory(url) else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
    }

    private func fileStatus(_ url: URL) throws -> stat? {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.path != "/",
              !url.pathComponents.contains("..") else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        var status = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return Int32(-1)
            }
            return Darwin.lstat(path, &status)
        }
        if result == 0 {
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw StandardIOSDeploymentError.invalidWorkspace
            }
            return status
        }
        guard errno == ENOENT else {
            throw StandardIOSDeploymentError.invalidWorkspace
        }
        return nil
    }
}

private final class StandardIOSDeploymentExecution:
    DeploymentExecution,
    @unchecked Sendable {
    typealias StartCommand = @Sendable (
        String,
        [String],
        String?,
        [String: String],
        (@Sendable (String, Bool) -> Void)?
    ) throws -> any DeploymentStageCommand

    private let request: StandardIOSDeploymentRequest
    private let workspaceURL: URL
    private let derivedDataURL: URL
    private let baseXcodebuildArguments: [String]
    private let environment: [String: String]
    private let startCommand: StartCommand
    private let inspectApplication: @Sendable (
        SignedIOSAppInspectionRequest
    ) async throws -> VerifiedSignedIOSApp
    private let prepareProfileCache: (@Sendable (
        String,
        String,
        ProvisioningProfileRefreshMode,
        String,
        Date
    ) async throws -> ProvisioningProfileCacheTransaction)?
    private let recordPreparedReceipt:
        StandardIOSDeploymentExecutor.RecordPreparedReceipt
    private let markInstalledReceipt:
        StandardIOSDeploymentExecutor.MarkInstalledReceipt
    private let removeWorkspace: @Sendable (URL) throws -> Void
    private let onOutput: (@Sendable (String, Bool) -> Void)?
    private let initialProcessGroupIdentifier: Int32
    private let stateCondition = NSCondition()
    private let resultReady = DispatchGroup()
    private var currentCommand: (any DeploymentStageCommand)?
    private var cachedResult: DeploymentExecutionResult?
    private var cancellationRequested = false
    private var workerTask: Task<Void, Never>?

    init(
        request: StandardIOSDeploymentRequest,
        workspaceURL: URL,
        derivedDataURL: URL,
        baseXcodebuildArguments: [String],
        environment: [String: String],
        firstCommand: any DeploymentStageCommand,
        startCommand: @escaping StartCommand,
        inspectApplication: @escaping @Sendable (
            SignedIOSAppInspectionRequest
        ) async throws -> VerifiedSignedIOSApp,
        prepareProfileCache: (@Sendable (
            String,
            String,
            ProvisioningProfileRefreshMode,
            String,
            Date
        ) async throws -> ProvisioningProfileCacheTransaction)?,
        recordPreparedReceipt: @escaping
            StandardIOSDeploymentExecutor.RecordPreparedReceipt,
        markInstalledReceipt: @escaping
            StandardIOSDeploymentExecutor.MarkInstalledReceipt,
        removeWorkspace: @escaping @Sendable (URL) throws -> Void,
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) {
        self.request = request
        self.workspaceURL = workspaceURL
        self.derivedDataURL = derivedDataURL
        self.baseXcodebuildArguments = baseXcodebuildArguments
        self.environment = environment
        self.currentCommand = firstCommand
        self.initialProcessGroupIdentifier =
            firstCommand.processGroupIdentifier
        self.startCommand = startCommand
        self.inspectApplication = inspectApplication
        self.prepareProfileCache = prepareProfileCache
        self.recordPreparedReceipt = recordPreparedReceipt
        self.markInstalledReceipt = markInstalledReceipt
        self.removeWorkspace = removeWorkspace
        self.onOutput = onOutput
        resultReady.enter()
        let workerTask = Task.detached { [self] in
            var result = await execute(firstCommand: firstCommand)
            if result.commandResult.processGroupTerminationWasConfirmed {
                do {
                    try removeWorkspace(workspaceURL)
                } catch {
                    let warning =
                        "本次续签的构建缓存目录未能清理；"
                        + "后续部署会再次尝试："
                        + error.localizedDescription
                    onOutput?("\n\(warning)\n", true)
                    result = resultByAppendingWorkspaceCleanupWarning(
                        warning,
                        to: result
                    )
                }
            }
            stateCondition.withLock {
                cachedResult = result
                currentCommand = nil
                stateCondition.broadcast()
            }
            resultReady.leave()
        }
        stateCondition.withLock {
            self.workerTask = workerTask
        }
    }

    var processGroupIdentifier: Int32 {
        stateCondition.withLock {
            currentCommand?.processGroupIdentifier
                ?? initialProcessGroupIdentifier
        }
    }

    func cancel() {
        stateCondition.lock()
        cancellationRequested = true
        let command = currentCommand
        let workerTask = workerTask
        stateCondition.unlock()
        workerTask?.cancel()
        command?.cancel()
    }

    func cancelAndWaitForTermination(
        timeoutSeconds: TimeInterval
    ) -> Bool {
        cancel()
        return resultReady.wait(
            timeout: .now() + max(timeoutSeconds, 0)
        ) == .success
            && cachedResultSnapshot()?.commandResult
                .processGroupTerminationWasConfirmed == true
    }

    func waitUntilExit() -> DeploymentExecutionResult {
        resultReady.wait()
        return cachedResultSnapshot()!
    }

    private func cachedResultSnapshot() -> DeploymentExecutionResult? {
        stateCondition.withLock { cachedResult }
    }

    private var isCancellationRequested: Bool {
        stateCondition.withLock { cancellationRequested }
    }

    private func execute(
        firstCommand: any DeploymentStageCommand
    ) async -> DeploymentExecutionResult {
        var transcript = DeploymentTranscript()
        let settingsResult = firstCommand.waitUntilExit(
            timeoutSeconds:
                StandardIOSDeploymentStageTimeout.buildSettings
        )
        transcript.append(stage: "Xcode build settings", result: settingsResult)
        guard settingsResult.completedSuccessfullyAndFullyTerminated else {
            return executionResult(
                transcript: transcript,
                status: settingsResult.terminationStatus
            )
        }
        guard !settingsResult.standardOutputWasTruncated,
              !settingsResult.standardErrorWasTruncated else {
            transcript.appendDiagnostic("Xcode 构建设置输出不完整，已停止安装。")
            return executionResult(transcript: transcript, status: 1)
        }

        let product: ResolvedIOSBuildProduct
        do {
            product = try resolveProduct(
                from: settingsResult.standardOutput
            )
        } catch {
            transcript.appendDiagnostic(error.localizedDescription)
            return executionResult(transcript: transcript, status: 1)
        }
        guard !isCancellationRequested else {
            return executionResult(transcript: transcript, status: 130)
        }

        let profileTransaction: ProvisioningProfileCacheTransaction?
        do {
            onOutput?(
                "\n[签名] 正在准备 provisioning profile 缓存…\n",
                false
            )
            profileTransaction = try await prepareProfileCache?(
                request.bundleIdentifier,
                product.developmentTeam,
                request.profileRefreshMode,
                request.deploymentToken,
                Date()
            )
        } catch let error as ProvisioningProfileCacheError {
            if case .commandProcessTreeUnresolved = error {
                transcript.markProcessGroupTerminationUnconfirmed()
            }
            transcript.appendDiagnostic(
                "无法准备 provisioning profile：\(error.localizedDescription)"
            )
            let cacheRecoveryWasConfirmed: Bool
            switch error {
            case .preparationFailed(_, let rollbackFailures):
                cacheRecoveryWasConfirmed = rollbackFailures.isEmpty
            case .rollbackIncomplete:
                cacheRecoveryWasConfirmed = false
            default:
                cacheRecoveryWasConfirmed = true
            }
            return DeploymentExecutionResult(
                commandResult: transcript.result(terminationStatus: 1),
                verifiedProfileExpirationDate: nil,
                profileCacheRecoveryWasConfirmed:
                    cacheRecoveryWasConfirmed
            )
        } catch {
            transcript.appendDiagnostic(
                "无法准备 provisioning profile：\(error.localizedDescription)"
            )
            return executionResult(transcript: transcript, status: 1)
        }
        guard !isCancellationRequested else {
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 130
            )
        }

        let buildResult: CommandResult
        do {
            onOutput?("\n[构建] 正在生成 iPhone App…\n", false)
            buildResult = try runStage(
                launchPath: "/usr/bin/xcodebuild",
                arguments: baseXcodebuildArguments + [
                    "-allowProvisioningUpdates",
                    "-allowProvisioningDeviceRegistration",
                    "build"
                ],
                timeoutSeconds: StandardIOSDeploymentStageTimeout.build
            )
        } catch {
            transcript.appendDiagnostic(
                "无法启动 xcodebuild：\(error.localizedDescription)"
            )
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 1
            )
        }
        transcript.append(stage: "Xcode build", result: buildResult)
        guard buildResult.completedSuccessfullyAndFullyTerminated else {
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: buildResult.terminationStatus
            )
        }
        guard !isCancellationRequested else {
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 130
            )
        }

        let verifiedApplication: VerifiedSignedIOSApp
        do {
            onOutput?("\n[核验] 正在检查 App 身份、签名与有效期…\n", false)
            verifiedApplication = try await inspectApplication(
                SignedIOSAppInspectionRequest(
                    derivedDataRootURL: derivedDataURL,
                    candidate: .application(product.applicationURL),
                    expectedBundleIdentifier: request.bundleIdentifier,
                    expectedTeamIdentifier: product.developmentTeam,
                    targetDeviceID: request.deviceID,
                    deploymentToken: request.deploymentToken,
                    profileRefreshMode: request.profileRefreshMode,
                    previousProfileDigests:
                        profileTransaction?.previousProfileDigests ?? [],
                    now: Date()
                )
            )
            transcript.appendOutput(
                "\n=== verified artifact ===\n"
                + "bundle_id=\(verifiedApplication.bundleIdentifier)\n"
                + "profile_uuid=\(verifiedApplication.profileUUID)\n"
                + "profile_expiry=\(verifiedApplication.profileExpirationDate.ISO8601Format())\n"
            )
        } catch let error as SignedIOSAppInspectionError {
            if case .commandProcessTreeUnresolved = error {
                transcript.markProcessGroupTerminationUnconfirmed()
            }
            transcript.appendDiagnostic(error.localizedDescription)
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 1
            )
        } catch {
            transcript.appendDiagnostic(error.localizedDescription)
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 1
            )
        }
        do {
            try recordPreparedReceipt(
                request,
                verifiedApplication,
                product.developmentTeam,
                Date()
            )
        } catch {
            transcript.appendDiagnostic(
                "无法持久化安装前宿主回执，已停止安装："
                    + error.localizedDescription
            )
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 1
            )
        }
        guard !isCancellationRequested else {
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 130
            )
        }

        let installResult: CommandResult
        do {
            onOutput?("\n[安装] 正在安装到 \(request.deviceName)…\n", false)
            installResult = try runStage(
                launchPath: "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "install", "app",
                    "--device", request.deviceID,
                    verifiedApplication.applicationURL.path
                ],
                timeoutSeconds: StandardIOSDeploymentStageTimeout.install
            )
        } catch {
            transcript.appendDiagnostic(
                "无法启动 devicectl 安装：\(error.localizedDescription)"
            )
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: 1
            )
        }
        transcript.append(stage: "devicectl install", result: installResult)
        guard installResult.completedSuccessfullyAndFullyTerminated else {
            return resultAfterRollingBackProfileCache(
                profileTransaction,
                transcript: transcript,
                status: installResult.terminationStatus
            )
        }
        do {
            try markInstalledReceipt(request.deploymentToken, Date())
        } catch {
            transcript.appendDiagnostic(
                "App 已安装，但宿主安装回执未能标记为已安装；"
                    + "本次仍按已核验的安装成功结算："
                    + error.localizedDescription
            )
        }
        var profileCacheRecoveryWasConfirmed = true
        do {
            try profileTransaction?.commit()
        } catch {
            transcript.appendDiagnostic(
                "App 已安装，但无法提交 provisioning profile 缓存事务；正在恢复原缓存："
                    + error.localizedDescription
            )
            do {
                try profileTransaction?.rollback()
                transcript.appendDiagnostic(
                    "原 provisioning profile 缓存已恢复；本次 App 安装仍然成功。"
                )
            } catch {
                profileCacheRecoveryWasConfirmed = false
                transcript.appendDiagnostic(
                    "App 已安装，但 provisioning profile 缓存未完成恢复："
                        + error.localizedDescription
                )
            }
        }
        guard !isCancellationRequested else {
            return DeploymentExecutionResult(
                commandResult: transcript.result(terminationStatus: 0),
                verifiedProfileExpirationDate:
                    verifiedApplication.profileExpirationDate,
                profileCacheRecoveryWasConfirmed:
                    profileCacheRecoveryWasConfirmed
            )
        }

        do {
            onOutput?("\n[启动] 正在尝试启动 App…\n", false)
            let launchResult = try runStage(
                launchPath: "/usr/bin/xcrun",
                arguments: [
                    "devicectl", "device", "process", "launch",
                    "--device", request.deviceID,
                    request.bundleIdentifier
                ],
                timeoutSeconds: StandardIOSDeploymentStageTimeout.launch
            )
            transcript.append(stage: "devicectl launch", result: launchResult)
            if !launchResult.completedSuccessfullyAndFullyTerminated {
                transcript.appendDiagnostic(
                    "App 已安装，但自动启动失败；可在解锁设备后手动打开。"
                )
            }
        } catch {
            transcript.appendDiagnostic(
                "App 已安装，但无法启动 devicectl launch：\(error.localizedDescription)"
            )
        }

        return DeploymentExecutionResult(
            commandResult: transcript.result(terminationStatus: 0),
            verifiedProfileExpirationDate:
                verifiedApplication.profileExpirationDate,
            profileCacheRecoveryWasConfirmed:
                profileCacheRecoveryWasConfirmed
        )
    }

    private func runStage(
        launchPath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) throws -> CommandResult {
        let command = try startCommand(
            launchPath,
            arguments,
            request.projectRootURL.path,
            environment,
            onOutput
        )
        stateCondition.lock()
        currentCommand = command
        let shouldCancel = cancellationRequested
        stateCondition.unlock()
        if shouldCancel {
            command.cancel()
        }
        return command.waitUntilExit(
            timeoutSeconds: timeoutSeconds
        )
    }

    private func resolveProduct(
        from output: String
    ) throws -> ResolvedIOSBuildProduct {
        guard output.utf8.count <= 4 * 1_024 * 1_024,
              let data = output.data(using: .utf8) else {
            throw StandardIOSDeploymentError.invalidBuildSettings(
                "输出超过允许上限。"
            )
        }
        let entries: [XcodeBuildSettingsEntry]
        do {
            entries = try JSONDecoder().decode(
                [XcodeBuildSettingsEntry].self,
                from: data
            )
        } catch {
            throw StandardIOSDeploymentError.invalidBuildSettings(
                "JSON 无法解析。"
            )
        }
        let selectedApplicationEntries = entries.filter { entry in
            entry.target == request.targetName
                && entry.buildSettings["PRODUCT_TYPE"]
                    == "com.apple.product-type.application"
                && entry.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"]
                    == request.bundleIdentifier
                && entry.buildSettings["SDK_NAME"]?.hasPrefix("iphoneos")
                    == true
        }
        if selectedApplicationEntries.contains(where: {
            $0.buildSettings["CODE_SIGN_STYLE"] != "Automatic"
        }) {
            throw StandardIOSDeploymentError.invalidBuildSettings(
                "所选 App Target 未启用 Automatically manage signing；请在 Xcode 的 Signing & Capabilities 中启用后重试。"
            )
        }
        if selectedApplicationEntries.contains(where: {
            guard let team = $0.buildSettings["DEVELOPMENT_TEAM"] else {
                return true
            }
            return DevelopmentTeamIdentifier(rawValue: team) == nil
        }) {
            throw StandardIOSDeploymentError.invalidBuildSettings(
                "所选 App Target 缺少安全且明确的 DEVELOPMENT_TEAM。"
            )
        }
        let products = entries.compactMap {
            entry -> ResolvedIOSBuildProduct? in
            guard entry.target == request.targetName,
                  entry.buildSettings["PRODUCT_TYPE"]
                    == "com.apple.product-type.application",
                  entry.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"]
                    == request.bundleIdentifier,
                  entry.buildSettings["SDK_NAME"]?.hasPrefix("iphoneos")
                    == true,
                  entry.buildSettings["CODE_SIGN_STYLE"] == "Automatic",
                  let targetBuildDirectory =
                    entry.buildSettings["TARGET_BUILD_DIR"],
                  let fullProductName =
                    entry.buildSettings["FULL_PRODUCT_NAME"],
                  let developmentTeam =
                    entry.buildSettings["DEVELOPMENT_TEAM"],
                  DevelopmentTeamIdentifier(
                      rawValue: developmentTeam
                  ) != nil,
                  URL(fileURLWithPath: fullProductName).lastPathComponent
                    == fullProductName,
                  fullProductName.hasSuffix(".app") else {
                return nil
            }
            let applicationURL = URL(
                fileURLWithPath: targetBuildDirectory,
                isDirectory: true
            )
            .appendingPathComponent(fullProductName, isDirectory: true)
            .standardizedFileURL
            guard applicationURL.path.hasPrefix(
                derivedDataURL.standardizedFileURL.path + "/"
            ) else {
                return nil
            }
            return ResolvedIOSBuildProduct(
                applicationURL: applicationURL,
                developmentTeam: developmentTeam
            )
        }
        let uniqueProducts = Array(Set(products)).sorted {
            if $0.applicationURL.path == $1.applicationURL.path {
                return $0.developmentTeam < $1.developmentTeam
            }
            return $0.applicationURL.path < $1.applicationURL.path
        }
        guard uniqueProducts.count == 1,
              let product = uniqueProducts.first else {
            throw StandardIOSDeploymentError.invalidBuildSettings(
                uniqueProducts.isEmpty
                    ? "没有与所选 Target、Bundle ID、Team 和 iphoneos App 匹配的产物。"
                    : "返回了多个匹配 App。"
            )
        }
        return product
    }

    private func executionResult(
        transcript: DeploymentTranscript,
        status: Int32
    ) -> DeploymentExecutionResult {
        DeploymentExecutionResult(
            commandResult: transcript.result(
                terminationStatus: isCancellationRequested ? 130 : status
            ),
            verifiedProfileExpirationDate: nil
        )
    }

    private func resultByAppendingWorkspaceCleanupWarning(
        _ warning: String,
        to result: DeploymentExecutionResult
    ) -> DeploymentExecutionResult {
        let commandResult = result.commandResult
        var standardError = BoundedDeploymentTranscriptStream(
            maximumBytes: DeploymentTranscript.maximumBytesPerStream
        )
        standardError.append(commandResult.standardError)
        standardError.append("\n=== iOSSignKit ===\n\(warning)\n")
        return DeploymentExecutionResult(
            commandResult: CommandResult(
                standardOutput: commandResult.standardOutput,
                standardError: standardError.stringValue,
                terminationStatus: commandResult.terminationStatus,
                standardOutputWasTruncated:
                    commandResult.standardOutputWasTruncated,
                standardErrorWasTruncated:
                    commandResult.standardErrorWasTruncated
                        || standardError.wasTruncated,
                processGroupTerminationWasConfirmed:
                    commandResult.processGroupTerminationWasConfirmed
            ),
            verifiedProfileExpirationDate:
                result.verifiedProfileExpirationDate,
            profileCacheRecoveryWasConfirmed:
                result.profileCacheRecoveryWasConfirmed
        )
    }

    private func resultAfterRollingBackProfileCache(
        _ transaction: ProvisioningProfileCacheTransaction?,
        transcript originalTranscript: DeploymentTranscript,
        status: Int32
    ) -> DeploymentExecutionResult {
        var transcript = originalTranscript
        guard transcript.processGroupTerminationWasConfirmed else {
            transcript.appendDiagnostic(
                "部署进程树尚未确认结束，已保留 provisioning profile 缓存事务；"
                    + "下次启动将在确认进程结束后恢复。"
            )
            return DeploymentExecutionResult(
                commandResult: transcript.result(
                    terminationStatus:
                        isCancellationRequested ? 130 : status
                ),
                verifiedProfileExpirationDate: nil,
                profileCacheRecoveryWasConfirmed: false
            )
        }
        do {
            try transaction?.rollback()
        } catch {
            transcript.appendDiagnostic(
                "部署失败后无法完整恢复 provisioning profile 缓存："
                    + error.localizedDescription
            )
            return DeploymentExecutionResult(
                commandResult: transcript.result(terminationStatus: 1),
                verifiedProfileExpirationDate: nil,
                profileCacheRecoveryWasConfirmed: false
            )
        }
        return executionResult(
            transcript: transcript,
            status: status
        )
    }
}
