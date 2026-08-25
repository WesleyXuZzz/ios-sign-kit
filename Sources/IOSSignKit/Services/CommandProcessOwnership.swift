import Foundation
import Darwin

enum CommandOwnedProcessRecoveryOutcome: Equatable, Sendable {
    case notFound
    case terminated
    case unresolved
}

enum CommandOwnedProcessDiscoveryOutcome: Equatable, Sendable {
    case notFound
    case found
    case unavailable
}

enum CommandEnvironmentMatch: Equatable, Sendable {
    case exact(environmentKey: String, value: String)
    case prefix(environmentKey: String, value: String)

    fileprivate func matches(_ environmentEntry: ArraySlice<UInt8>) -> Bool {
        let expected: [UInt8]
        switch self {
        case .exact(let environmentKey, let value):
            expected = Array("\(environmentKey)=\(value)".utf8)
            return environmentEntry.elementsEqual(expected)
        case .prefix(let environmentKey, let value):
            expected = Array("\(environmentKey)=\(value)".utf8)
            return environmentEntry.starts(with: expected)
        }
    }
}

enum CommandProcessListInspection: Equatable, Sendable {
    case available([pid_t])
    case unavailable
}

enum CommandProcessOwnerInspection: Equatable, Sendable {
    case currentUser
    case otherUser
    case exited
    case unavailable
}

enum CommandProcessTokenInspection: Equatable, Sendable {
    case matched
    case absent
    case exited
    case unavailable
}

private enum CommandProcessSignalOutcome: Sendable {
    case signaled
    case exited
    case unavailable
}

private enum CommandMarkerCreatorPolicy: Equatable, Sendable {
    case any
    case abandonedOnly
}

private struct CommandOwnershipFileIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(fileStatus: stat) {
        device = UInt64(UInt32(bitPattern: fileStatus.st_dev))
        inode = UInt64(fileStatus.st_ino)
        generation = fileStatus.st_gen
        birthSeconds = Int64(fileStatus.st_birthtimespec.tv_sec)
        birthNanoseconds =
            Int64(fileStatus.st_birthtimespec.tv_nsec)
    }

    init(vnodeStatus: vinfo_stat) {
        device = UInt64(vnodeStatus.vst_dev)
        inode = vnodeStatus.vst_ino
        generation = vnodeStatus.vst_gen
        birthSeconds = vnodeStatus.vst_birthtime
        birthNanoseconds = vnodeStatus.vst_birthtimensec
    }
}

private struct CommandOwnershipCreatorIdentity:
    Codable,
    Equatable,
    Sendable {
    let processIdentifier: UInt32
    let userID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init(processInfo: proc_bsdinfo) {
        processIdentifier = processInfo.pbi_pid
        userID = processInfo.pbi_uid
        startSeconds = processInfo.pbi_start_tvsec
        startMicroseconds = processInfo.pbi_start_tvusec
    }

    static func capture(
        processIdentifier: pid_t
    ) throws -> Self {
        let expectedByteCount =
            Int32(MemoryLayout<proc_bsdinfo>.size)
        for attempt in 0..<3 {
            var processInfo = proc_bsdinfo()
            errno = 0
            let byteCount = withUnsafeMutablePointer(
                to: &processInfo
            ) {
                proc_pidinfo(
                    processIdentifier,
                    PROC_PIDTBSDINFO,
                    0,
                    $0,
                    expectedByteCount
                )
            }
            if byteCount == expectedByteCount {
                let identity = Self(processInfo: processInfo)
                guard identity.processIdentifier ==
                        UInt32(bitPattern: processIdentifier),
                      identity.processIdentifier > 1,
                      identity.userID == UInt32(geteuid()) else {
                    throw CommandOwnershipMarkerError.invalidMarker
                }
                return identity
            }
            if attempt + 1 < 3,
               errno == EINTR || errno == ENOMEM {
                usleep(1_000)
                continue
            }
            throw CommandOwnershipMarkerError.invalidMarker
        }
        throw CommandOwnershipMarkerError.invalidMarker
    }

    func inspectCurrentState()
        -> CommandOwnershipCreatorState {
        let expectedByteCount =
            Int32(MemoryLayout<proc_bsdinfo>.size)
        for attempt in 0..<3 {
            var processInfo = proc_bsdinfo()
            errno = 0
            let byteCount = withUnsafeMutablePointer(
                to: &processInfo
            ) {
                proc_pidinfo(
                    Int32(bitPattern: processIdentifier),
                    PROC_PIDTBSDINFO,
                    0,
                    $0,
                    expectedByteCount
                )
            }
            if byteCount == expectedByteCount {
                guard Self(processInfo: processInfo) == self else {
                    return .abandoned
                }
                if processInfo.pbi_status == SZOMB
                    || processInfo.pbi_flags
                        & UInt32(PROC_FLAG_INEXIT) != 0 {
                    return .abandoned
                }
                return .active
            }
            if errno == ESRCH
                || errno == ENOENT
                || errno == EINVAL {
                return .abandoned
            }
            if attempt + 1 < 3,
               errno == EINTR || errno == ENOMEM {
                usleep(1_000)
                continue
            }
            return .unavailable
        }
        return .unavailable
    }
}

private enum CommandOwnershipCreatorState {
    case active
    case abandoned
    case unavailable
}

private struct CommandOwnershipFileMarker:
    Codable,
    Equatable,
    Sendable {
    static let schemaVersion = CommandOwnershipMarkerFormat.currentSchemaVersion

    let schemaVersion: Int
    let token: String
    let ownerUserID: UInt32
    let mode: UInt16
    let identity: CommandOwnershipFileIdentity
    let creator: CommandOwnershipCreatorIdentity
}

private struct CommandOwnershipMarkerStore: Sendable {
    private static let maximumMarkerBytes = 64 * 1_024
    private static let maximumMarkerCount = 4_096
    let directoryURL: URL

    static let production = CommandOwnershipMarkerStore(
        directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(
                CommandOwnershipMarkerFormat.directoryName(userID: geteuid()),
                isDirectory: true
            )
    )

    func create(
        token: String,
        creatorProcessIdentifier: pid_t
    ) throws -> PreparedCommandOwnershipFile {
        guard Self.isSupportedToken(token) else {
            throw CommandOwnershipMarkerError.invalidToken
        }
        let creator = try CommandOwnershipCreatorIdentity.capture(
            processIdentifier: creatorProcessIdentifier
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        guard let directoryStatus = try pathStatus(at: directoryURL),
              Self.isSecureMarkerDirectory(directoryStatus) else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
        let url = markerURL(for: token)
        let descriptor = url.path.withCString {
            open(
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw CommandOwnershipMarkerError.cannotCreate(errno)
        }

        var inheritedDescriptor: Int32 = -1
        do {
            try CommandProcessOwnershipTracker
                .secureOwnershipMarkerPermissions(descriptor)
            var fileStatus = stat()
            guard fstat(descriptor, &fileStatus) == 0 else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            let marker = CommandOwnershipFileMarker(
                schemaVersion:
                    CommandOwnershipFileMarker.schemaVersion,
                token: token,
                ownerUserID: UInt32(geteuid()),
                mode: UInt16(S_IRUSR | S_IWUSR),
                identity:
                    CommandOwnershipFileIdentity(
                        fileStatus: fileStatus
                    ),
                creator: creator
            )
            let data = try JSONEncoder().encode(marker)
            guard data.count <= Self.maximumMarkerBytes else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            try Self.writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            inheritedDescriptor = url.path.withCString {
                open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard inheritedDescriptor >= 0 else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            var inheritedStatus = stat()
            guard fstat(inheritedDescriptor, &inheritedStatus) == 0,
                  CommandOwnershipFileIdentity(
                      fileStatus: inheritedStatus
                  ) == marker.identity else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            guard flock(
                inheritedDescriptor,
                LOCK_EX | LOCK_NB
            ) == 0 else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            close(descriptor)
            return PreparedCommandOwnershipFile(
                descriptor: inheritedDescriptor
            )
        } catch {
            close(descriptor)
            if inheritedDescriptor >= 0 {
                close(inheritedDescriptor)
            }
            _ = url.path.withCString { unlink($0) }
            throw error
        }
    }

    func load(matching match: CommandEnvironmentMatch) throws
        -> [CommandOwnershipFileMarker] {
        switch match {
        case .exact(_, let token):
            let url = markerURL(for: token)
            guard try pathStatus(at: url) != nil else {
                return []
            }
            return [try decodeMarker(at: url, expectedToken: token)]
        case .prefix(_, let prefix):
            guard let directoryStatus =
                    try pathStatus(at: directoryURL) else {
                return []
            }
            guard Self.isSecureMarkerDirectory(directoryStatus) else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard urls.count <= Self.maximumMarkerCount else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            return try urls
                .filter {
                    $0.pathExtension == "json"
                        && $0.deletingPathExtension()
                            .lastPathComponent.hasPrefix(prefix)
                }
                .map {
                    try decodeMarker(
                        at: $0,
                        expectedToken:
                            $0.deletingPathExtension().lastPathComponent
                    )
                }
        }
    }

    func remove(_ markers: [CommandOwnershipFileMarker]) throws {
        for marker in markers {
            let url = markerURL(for: marker.token)
            guard try pathStatus(at: url) != nil else {
                continue
            }
            let current = try fileStatus(at: url)
            guard Self.isSecureRegularMarker(current),
                  CommandOwnershipFileIdentity(fileStatus: current) ==
                    marker.identity else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
            guard url.path.withCString({ unlink($0) }) == 0 else {
                throw CommandOwnershipMarkerError.invalidMarker
            }
        }
    }

    func inspectOwnershipLock(
        for marker: CommandOwnershipFileMarker
    ) -> CommandOwnershipLockState {
        let url = markerURL(for: marker.token)
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            return .unavailable
        }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              Self.isSecureRegularMarker(fileStatus),
              CommandOwnershipFileIdentity(
                  fileStatus: fileStatus
              ) == marker.identity else {
            return .unavailable
        }
        errno = 0
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            guard flock(descriptor, LOCK_UN) == 0 else {
                return .unavailable
            }
            return .released
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            return .held
        }
        return .unavailable
    }

    func markerURL(for token: String) -> URL {
        directoryURL.appendingPathComponent("\(token).json")
    }

    private func decodeMarker(
        at url: URL,
        expectedToken: String
    ) throws -> CommandOwnershipFileMarker {
        guard Self.isSupportedToken(expectedToken) else {
            throw CommandOwnershipMarkerError.invalidToken
        }
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
        defer { close(descriptor) }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              Self.isSecureRegularMarker(fileStatus),
              fileStatus.st_size > 0,
              fileStatus.st_size <= Self.maximumMarkerBytes else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
        let data = try Self.readAll(
            from: descriptor,
            byteCount: Int(fileStatus.st_size)
        )
        let marker = try JSONDecoder().decode(
            CommandOwnershipFileMarker.self,
            from: data
        )
        let identity =
            CommandOwnershipFileIdentity(fileStatus: fileStatus)
        let pathStatus = try self.fileStatus(at: url)
        guard marker.schemaVersion ==
                CommandOwnershipFileMarker.schemaVersion,
              marker.token == expectedToken,
              marker.ownerUserID == UInt32(geteuid()),
              marker.mode == UInt16(S_IRUSR | S_IWUSR),
              marker.creator.userID == marker.ownerUserID,
              marker.creator.processIdentifier > 1,
              marker.identity == identity,
              Self.isSecureRegularMarker(pathStatus),
              CommandOwnershipFileIdentity(fileStatus: pathStatus) ==
                identity else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
        return marker
    }

    private func fileStatus(at url: URL) throws -> stat {
        guard let value = try pathStatus(at: url) else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
        return value
    }

    private func pathStatus(at url: URL) throws -> stat? {
        var value = stat()
        errno = 0
        if url.path.withCString({ lstat($0, &value) }) == 0 {
            return value
        }
        if errno == ENOENT {
            return nil
        }
        throw CommandOwnershipMarkerError.invalidMarker
    }

    private static func isSecureRegularMarker(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
            && value.st_uid == geteuid()
            && (value.st_mode & 0o777) == (S_IRUSR | S_IWUSR)
            && value.st_nlink == 1
    }

    private static func isSecureMarkerDirectory(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
            && value.st_uid == geteuid()
            && (value.st_mode & 0o777) ==
                (S_IRWXU)
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { storage in
            var offset = 0
            while offset < storage.count {
                let written = Darwin.write(
                    descriptor,
                    storage.baseAddress?.advanced(by: offset),
                    storage.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw CommandOwnershipMarkerError.invalidMarker
                }
            }
        }
    }

    private static func readAll(
        from descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { storage in
            var offset = 0
            while offset < storage.count {
                let count = pread(
                    descriptor,
                    storage.baseAddress?.advanced(by: offset),
                    storage.count - offset,
                    off_t(offset)
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw CommandOwnershipMarkerError.invalidMarker
                }
            }
        }
        return data
    }

    private static func isSupportedToken(_ token: String) -> Bool {
        if DeploymentToken(rawValue: token) != nil {
            return true
        }
        let prefix =
            CommandProcessOwnershipTracker.commandTokenPrefix
        guard token.hasPrefix(prefix) else {
            return false
        }
        return UUID(uuidString: String(token.dropFirst(prefix.count))) != nil
    }
}

private enum CommandOwnershipLockState {
    case held
    case released
    case unavailable
}

private enum CommandOwnershipMarkerError: Error {
    case invalidToken
    case invalidMarker
    case cannotCreate(Int32)
}

struct PreparedCommandOwnershipFile: Sendable {
    let descriptor: Int32
}

struct CommandProcessOwnershipTracker: Sendable {
    static let environmentKey = "IOS_SIGN_KIT_COMMAND_TOKEN"
    static let ownershipDescriptorEnvironmentKey =
        "IOS_SIGN_KIT_OWNERSHIP_FD"
    static let commandTokenPrefix = "ios-sign-kit-command-"
    static let inheritedMarkerDescriptor: Int32 = 198

    private static let maximumProcessArgumentsBytes = 4 * 1_024 * 1_024
    private static let maximumProcessCount = 32_768
    private static let maximumProcessDescriptorCount = 65_536
    private static let processArgumentsReadAttempts = 3
    private let match: CommandEnvironmentMatch
    private let processListProvider:
        @Sendable () -> CommandProcessListInspection
    private let processOwnerInspector:
        @Sendable (pid_t) -> CommandProcessOwnerInspection
    private let processTokenInspector:
        @Sendable (
            pid_t,
            CommandEnvironmentMatch
        ) -> CommandProcessTokenInspection
    private let processSignaler:
        @Sendable (pid_t, Int32) -> CommandProcessSignalOutcome
    private let markerStore: CommandOwnershipMarkerStore
    private let usesPersistentMarkers: Bool
    private let markerCreatorPolicy:
        CommandMarkerCreatorPolicy

    init(token: String) {
        self.init(
            match: .exact(
                environmentKey: Self.environmentKey,
                value: token
            )
        )
    }

    init(
        environmentKey: String,
        exactValue: String
    ) {
        self.init(
            match: .exact(
                environmentKey: environmentKey,
                value: exactValue
            )
        )
    }

    init(
        environmentKey: String,
        valuePrefix: String,
        onlyAbandonedCreators: Bool = false
    ) {
        self.init(
            match: .prefix(
                environmentKey: environmentKey,
                value: valuePrefix
            ),
            markerCreatorPolicy:
                onlyAbandonedCreators
                ? .abandonedOnly
                : .any
        )
    }

    private init(
        match: CommandEnvironmentMatch,
        markerCreatorPolicy:
            CommandMarkerCreatorPolicy = .any
    ) {
        self.init(
            match: match,
            processListProvider: Self.inspectProcessList,
            processOwnerInspector: Self.inspectProcessOwner,
            processTokenInspector: Self.inspectProcessToken,
            processSignaler: Self.signalProcess,
            markerStore: .production,
            usesPersistentMarkers: true,
            markerCreatorPolicy: markerCreatorPolicy
        )
    }

    init(
        match: CommandEnvironmentMatch,
        processListProvider:
            @escaping @Sendable () -> CommandProcessListInspection,
        processOwnerInspector:
            @escaping @Sendable (pid_t) -> CommandProcessOwnerInspection,
        processTokenInspector:
            @escaping @Sendable (
                pid_t,
                CommandEnvironmentMatch
            ) -> CommandProcessTokenInspection
    ) {
        self.init(
            match: match,
            processListProvider: processListProvider,
            processOwnerInspector: processOwnerInspector,
            processTokenInspector: processTokenInspector,
            processSignaler: Self.signalProcess,
            markerStore: .production,
            usesPersistentMarkers: false,
            markerCreatorPolicy: .any
        )
    }

    private init(
        match: CommandEnvironmentMatch,
        processListProvider:
            @escaping @Sendable () -> CommandProcessListInspection,
        processOwnerInspector:
            @escaping @Sendable (pid_t) -> CommandProcessOwnerInspection,
        processTokenInspector:
            @escaping @Sendable (
                pid_t,
                CommandEnvironmentMatch
            ) -> CommandProcessTokenInspection,
        processSignaler:
            @escaping @Sendable (
                pid_t,
                Int32
            ) -> CommandProcessSignalOutcome,
        markerStore: CommandOwnershipMarkerStore,
        usesPersistentMarkers: Bool,
        markerCreatorPolicy: CommandMarkerCreatorPolicy
    ) {
        self.match = match
        self.processListProvider = processListProvider
        self.processOwnerInspector = processOwnerInspector
        self.processTokenInspector = processTokenInspector
        self.processSignaler = processSignaler
        self.markerStore = markerStore
        self.usesPersistentMarkers = usesPersistentMarkers
        self.markerCreatorPolicy = markerCreatorPolicy
    }

    static func makeToken() -> String {
        "\(commandTokenPrefix)\(UUID().uuidString.lowercased())"
    }

    static func markerFileURL(for token: String) -> URL {
        CommandOwnershipMarkerStore.production.markerURL(for: token)
    }

    static func childDescriptorsToClose(
        _ descriptors: [Int32]
    ) -> [Int32] {
        descriptors.filter { $0 != inheritedMarkerDescriptor }
    }

    static func secureOwnershipMarkerPermissions(
        _ descriptor: Int32
    ) throws {
        guard fchmod(
            descriptor,
            mode_t(S_IRUSR | S_IWUSR)
        ) == 0 else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_uid == geteuid(),
              (fileStatus.st_mode & 0o777) ==
                (S_IRUSR | S_IWUSR),
              fileStatus.st_nlink == 1 else {
            throw CommandOwnershipMarkerError.invalidMarker
        }
    }

    static func prepareOwnershipFile(
        token: String,
        creatorProcessIdentifier: pid_t = getpid()
    ) throws -> PreparedCommandOwnershipFile {
        var prepared =
            try CommandOwnershipMarkerStore.production.create(
                token: token,
                creatorProcessIdentifier:
                    creatorProcessIdentifier
            )
        do {
            let relocated = fcntl(
                prepared.descriptor,
                F_DUPFD_CLOEXEC,
                inheritedMarkerDescriptor + 1
            )
            guard relocated >= 0 else {
                throw CommandRunnerError.pipeCreationFailed(errno)
            }
            close(prepared.descriptor)
            prepared = PreparedCommandOwnershipFile(
                descriptor: relocated
            )
            return prepared
        } catch {
            close(prepared.descriptor)
            _ = CommandProcessOwnershipTracker(
                token: token
            ).removeMarkerIfPresent()
            throw error
        }
    }

    @discardableResult
    func removeMarkerIfPresent() -> Bool {
        guard usesPersistentMarkers else {
            return true
        }
        switch markersRequiringProcessScan() {
        case .none:
            return true
        case .ready, .unavailable:
            return false
        }
    }

    func discoverAllOwnedProcesses() -> CommandOwnedProcessDiscoveryOutcome {
        switch matchingProcessIdentifiers(until: .now() + 2) {
        case .found(let identifiers):
            if identifiers.isEmpty {
                return removeMarkerIfPresent()
                    ? .notFound
                    : .unavailable
            }
            return .found
        case .unavailable:
            return .unavailable
        }
    }

    func terminateAllOwnedProcesses() -> Bool {
        switch recoverAllOwnedProcesses() {
        case .notFound, .terminated:
            return true
        case .unresolved:
            return false
        }
    }

    func recoverAllOwnedProcesses() -> CommandOwnedProcessRecoveryOutcome {
        let totalDeadline = DispatchTime.now() + 2.5
        guard case .found(let initialProcesses) =
                matchingProcessIdentifiers(until: totalDeadline) else {
            return .unresolved
        }
        guard !initialProcesses.isEmpty else {
            return removeMarkerIfPresent()
                ? .notFound
                : .unresolved
        }
        guard signalOwnedProcesses(
            initialProcesses,
            signal: SIGTERM,
            deadline: totalDeadline
        ) else {
            return .unresolved
        }
        if waitForOwnedProcessesToExit(
            until: earlier(
                DispatchTime.now() + 0.25,
                totalDeadline
            )
        ) {
            return removeMarkerIfPresent()
                ? .terminated
                : .unresolved
        }

        guard case .found(let survivors) =
                matchingProcessIdentifiers(until: totalDeadline),
              signalOwnedProcesses(
                  survivors,
                  signal: SIGKILL,
                  deadline: totalDeadline
              ) else {
            return .unresolved
        }
        if waitForOwnedProcessesToExit(until: totalDeadline) {
            return removeMarkerIfPresent()
                ? .terminated
                : .unresolved
        }
        return .unresolved
    }

    private enum ProcessScan {
        case found(Set<pid_t>)
        case unavailable
    }

    private enum MarkerScanPreparation {
        case none
        case ready([CommandOwnershipFileMarker])
        case unavailable
    }

    private func markersRequiringProcessScan()
        -> MarkerScanPreparation {
        let loadedMarkers: [CommandOwnershipFileMarker]
        do {
            loadedMarkers = try markerStore.load(
                matching: match
            )
        } catch {
            return .unavailable
        }
        var lockedMarkers: [CommandOwnershipFileMarker] = []
        for marker in loadedMarkers {
            if markerCreatorPolicy == .abandonedOnly {
                switch marker.creator.inspectCurrentState() {
                case .active:
                    continue
                case .abandoned:
                    break
                case .unavailable:
                    return .unavailable
                }
            }
            switch markerStore.inspectOwnershipLock(for: marker) {
            case .held:
                lockedMarkers.append(marker)
            case .released:
                do {
                    try markerStore.remove([marker])
                } catch {
                    return .unavailable
                }
            case .unavailable:
                return .unavailable
            }
        }
        return lockedMarkers.isEmpty
            ? .none
            : .ready(lockedMarkers)
    }

    private func matchingProcessIdentifiers(
        until deadline: DispatchTime
    ) -> ProcessScan {
        guard DispatchTime.now() < deadline else {
            return .unavailable
        }
        let markers: [CommandOwnershipFileMarker]
        if usesPersistentMarkers {
            switch markersRequiringProcessScan() {
            case .none:
                return .found([])
            case .ready(let lockedMarkers):
                markers = lockedMarkers
            case .unavailable:
                return .unavailable
            }
        } else {
            markers = []
        }
        let processListInspection = usesPersistentMarkers
            ? processesReferencingMarkers(markers)
            : processListProvider()
        guard case .available(let identifiers) = processListInspection,
              identifiers.count <= Self.maximumProcessCount else {
            return .unavailable
        }

        var matching: Set<pid_t> = []
        for identifier in identifiers
            where identifier > 1 && identifier != getpid() {
            guard DispatchTime.now() < deadline else {
                return .unavailable
            }
            if usesPersistentMarkers {
                let ownershipInspection =
                    Self.inspectProcessMarkerFile(
                        identifier,
                        markers: markers
                    )
                switch ownershipInspection {
                case .matched:
                    switch processOwnerInspector(identifier) {
                    case .currentUser:
                        matching.insert(identifier)
                    case .otherUser, .exited:
                        continue
                    case .unavailable:
                        return .unavailable
                    }
                case .absent, .exited:
                    continue
                case .unavailable:
                    // An inaccessible process cannot own a 0600 marker from
                    // another UID. Only a stable current-UID process remains
                    // a safety-relevant uncertainty.
                    switch processOwnerInspector(identifier) {
                    case .otherUser, .exited:
                        continue
                    case .currentUser, .unavailable:
                        return .unavailable
                    }
                }
                continue
            }

            switch processOwnerInspector(identifier) {
            case .otherUser, .exited:
                continue
            case .unavailable:
                return .unavailable
            case .currentUser:
                break
            }
            let ownershipInspection =
                processTokenInspector(identifier, match)
            switch ownershipInspection {
            case .matched:
                matching.insert(identifier)
            case .absent, .exited:
                continue
            case .unavailable:
                return .unavailable
            }
        }
        return .found(matching)
    }

    private func processesReferencingMarkers(
        _ markers: [CommandOwnershipFileMarker]
    ) -> CommandProcessListInspection {
        var identifiers: Set<pid_t> = []
        let identifierByteCount = MemoryLayout<pid_t>.size
        guard identifierByteCount > 0 else {
            return .unavailable
        }

        for marker in markers {
            let path = markerStore.markerURL(for: marker.token).path
            var didReadCompleteSnapshot = false
            for attempt in 0..<Self.processArgumentsReadAttempts {
                errno = 0
                let requiredByteCount = path.withCString {
                    proc_listpidspath(
                        UInt32(PROC_UID_ONLY),
                        UInt32(geteuid()),
                        $0,
                        UInt32(
                            PROC_LISTPIDSPATH_EXCLUDE_EVTONLY
                        ),
                        nil,
                        0
                    )
                }
                guard requiredByteCount >= 0 else {
                    if attempt + 1
                        < Self.processArgumentsReadAttempts {
                        usleep(1_000)
                        continue
                    }
                    return .unavailable
                }
                let requiredBytes = Int(requiredByteCount)
                if requiredBytes == 0 {
                    didReadCompleteSnapshot = true
                    break
                }
                guard requiredBytes % identifierByteCount == 0 else {
                    return .unavailable
                }
                let requiredCount =
                    requiredBytes / identifierByteCount
                guard requiredCount <= Self.maximumProcessCount else {
                    return .unavailable
                }
                let capacity = min(
                    Self.maximumProcessCount,
                    requiredCount + 128
                )
                guard capacity > requiredCount else {
                    return .unavailable
                }

                var markerIdentifiers = [pid_t](
                    repeating: 0,
                    count: capacity
                )
                errno = 0
                let readByteCount =
                    markerIdentifiers.withUnsafeMutableBytes {
                        storage in
                        path.withCString {
                            proc_listpidspath(
                                UInt32(PROC_UID_ONLY),
                                UInt32(geteuid()),
                                $0,
                                UInt32(
                                    PROC_LISTPIDSPATH_EXCLUDE_EVTONLY
                                ),
                                storage.baseAddress,
                                Int32(storage.count)
                            )
                        }
                    }
                guard readByteCount >= 0 else {
                    if attempt + 1
                        < Self.processArgumentsReadAttempts {
                        usleep(1_000)
                        continue
                    }
                    return .unavailable
                }
                let readBytes = Int(readByteCount)
                if readBytes == 0 {
                    didReadCompleteSnapshot = true
                    break
                }
                guard readBytes % identifierByteCount == 0,
                      readBytes < capacity
                        * identifierByteCount else {
                    if attempt + 1
                        < Self.processArgumentsReadAttempts {
                        usleep(1_000)
                        continue
                    }
                    return .unavailable
                }
                identifiers.formUnion(
                    markerIdentifiers.prefix(
                        readBytes / identifierByteCount
                    )
                )
                didReadCompleteSnapshot = true
                break
            }
            guard didReadCompleteSnapshot else {
                return .unavailable
            }
        }
        return .available(Array(identifiers))
    }

    private static func inspectProcessList() -> CommandProcessListInspection {
        let processCount = proc_listallpids(nil, 0)
        guard processCount >= 0,
              processCount <= maximumProcessCount else {
            return .unavailable
        }
        var identifiers = [pid_t](
            repeating: 0,
            count: max(Int(processCount) + 128, 128)
        )
        let listedCount = identifiers.withUnsafeMutableBytes { storage in
            proc_listallpids(
                storage.baseAddress,
                Int32(storage.count)
            )
        }
        guard listedCount >= 0,
              Int(listedCount) < identifiers.count else {
            return .unavailable
        }
        return .available(Array(identifiers.prefix(Int(listedCount))))
    }

    static func inspectProcessOwner(
        _ processIdentifier: pid_t
    ) -> CommandProcessOwnerInspection {
        let expectedByteCount =
            Int32(MemoryLayout<proc_bsdinfo>.size)
        for attempt in 0..<processArgumentsReadAttempts {
            var processInfo = proc_bsdinfo()
            errno = 0
            let byteCount = withUnsafeMutablePointer(to: &processInfo) {
                proc_pidinfo(
                    processIdentifier,
                    PROC_PIDTBSDINFO,
                    0,
                    $0,
                    expectedByteCount
                )
            }
            if byteCount == expectedByteCount {
                if processInfo.pbi_status == SZOMB
                    || processInfo.pbi_flags
                        & UInt32(PROC_FLAG_INEXIT) != 0 {
                    return .exited
                }
                return processInfo.pbi_uid == geteuid()
                    ? .currentUser
                    : .otherUser
            }
            if processDidExit(errno) {
                return .exited
            }
            if errno == EPERM {
                return inspectSignalAccess(processIdentifier)
            }
            if attempt + 1 < processArgumentsReadAttempts {
                usleep(1_000)
            }
        }

        return inspectSignalAccess(processIdentifier)
    }

    private static func inspectSignalAccess(
        _ processIdentifier: pid_t
    ) -> CommandProcessOwnerInspection {
        errno = 0
        if kill(processIdentifier, 0) == 0 {
            return .unavailable
        }
        if errno == EPERM {
            return .otherUser
        }
        return processDidExit(errno) ? .exited : .unavailable
    }

    private static func inspectProcessMarkerFile(
        _ processIdentifier: pid_t,
        markers: [CommandOwnershipFileMarker]
    ) -> CommandProcessTokenInspection {
        let expectedByteCount =
            Int32(MemoryLayout<vnode_fdinfo>.size)
        for attempt in 0..<processArgumentsReadAttempts {
            switch inspectInheritedMarkerDescriptor(
                processIdentifier
            ) {
            case .absent:
                return .absent
            case .exited:
                return .exited
            case .unavailable:
                return .unavailable
            case .vnode:
                break
            }
            var vnodeInfo = vnode_fdinfo()
            errno = 0
            let byteCount = withUnsafeMutablePointer(
                to: &vnodeInfo
            ) {
                proc_pidfdinfo(
                    processIdentifier,
                    inheritedMarkerDescriptor,
                    PROC_PIDFDVNODEINFO,
                    $0,
                    expectedByteCount
                )
            }
            if byteCount == expectedByteCount {
                let status = vnodeInfo.pvi.vi_stat
                guard (status.vst_mode & UInt16(S_IFMT)) ==
                        UInt16(S_IFREG),
                      status.vst_uid == geteuid(),
                      (status.vst_mode & 0o777) ==
                        UInt16(S_IRUSR | S_IWUSR) else {
                    return .absent
                }
                let identity =
                    CommandOwnershipFileIdentity(
                        vnodeStatus: status
                    )
                return markers.contains(where: {
                    $0.identity == identity
                })
                    ? .matched
                    : .absent
            }
            if errno == EBADF {
                if attempt + 1 < processArgumentsReadAttempts {
                    usleep(1_000)
                    continue
                }
                return .absent
            }
            if processDidExit(errno) {
                return .exited
            }
            if attempt + 1 < processArgumentsReadAttempts {
                usleep(1_000)
            }
        }
        return .unavailable
    }

    private enum InheritedMarkerDescriptorInspection {
        case vnode
        case absent
        case exited
        case unavailable
    }

    private static func inspectInheritedMarkerDescriptor(
        _ processIdentifier: pid_t
    ) -> InheritedMarkerDescriptorInspection {
        let descriptorByteCount =
            MemoryLayout<proc_fdinfo>.size
        guard descriptorByteCount > 0 else {
            return .unavailable
        }

        for attempt in 0..<processArgumentsReadAttempts {
            errno = 0
            let requiredByteCount = proc_pidinfo(
                processIdentifier,
                PROC_PIDLISTFDS,
                0,
                nil,
                0
            )
            if requiredByteCount == 0 {
                if processDidExit(errno) {
                    return .exited
                }
                if errno == 0 {
                    return .absent
                }
                if attempt + 1 < processArgumentsReadAttempts {
                    usleep(1_000)
                    continue
                }
                return .unavailable
            }
            guard requiredByteCount > 0,
                  Int(requiredByteCount) % descriptorByteCount == 0 else {
                return .unavailable
            }

            let requiredDescriptorCount =
                Int(requiredByteCount) / descriptorByteCount
            guard requiredDescriptorCount
                    <= maximumProcessDescriptorCount else {
                return .unavailable
            }
            let descriptorCapacity = min(
                maximumProcessDescriptorCount,
                requiredDescriptorCount + 64
            )
            guard descriptorCapacity > requiredDescriptorCount else {
                return .unavailable
            }

            var descriptors = [proc_fdinfo](
                repeating: proc_fdinfo(),
                count: descriptorCapacity
            )
            errno = 0
            let readByteCount =
                descriptors.withUnsafeMutableBytes { storage in
                    proc_pidinfo(
                        processIdentifier,
                        PROC_PIDLISTFDS,
                        0,
                        storage.baseAddress,
                        Int32(storage.count)
                    )
                }
            if readByteCount == 0 {
                if processDidExit(errno) {
                    return .exited
                }
                if errno == 0 {
                    return .absent
                }
                if attempt + 1 < processArgumentsReadAttempts {
                    usleep(1_000)
                    continue
                }
                return .unavailable
            }
            guard readByteCount > 0,
                  Int(readByteCount) % descriptorByteCount == 0,
                  Int(readByteCount) < descriptorCapacity
                    * descriptorByteCount else {
                if attempt + 1 < processArgumentsReadAttempts {
                    usleep(1_000)
                    continue
                }
                return .unavailable
            }

            let descriptorCount =
                Int(readByteCount) / descriptorByteCount
            guard let markerDescriptor = descriptors
                .prefix(descriptorCount)
                .first(where: {
                    $0.proc_fd == inheritedMarkerDescriptor
                }) else {
                return .absent
            }
            return markerDescriptor.proc_fdtype
                    == UInt32(PROX_FDTYPE_VNODE)
                ? .vnode
                : .absent
        }
        return .unavailable
    }

    static func inspectProcessToken(
        _ processIdentifier: pid_t,
        match: CommandEnvironmentMatch
    ) -> CommandProcessTokenInspection {
        var query = [
            Int32(CTL_KERN),
            Int32(KERN_PROCARGS2),
            processIdentifier
        ]
        for _ in 0..<processArgumentsReadAttempts {
            var byteCount = 0
            errno = 0
            let sizingStatus =
                query.withUnsafeMutableBufferPointer { queryBuffer in
                    sysctl(
                        queryBuffer.baseAddress,
                        UInt32(queryBuffer.count),
                        nil,
                        &byteCount,
                        nil,
                        0
                    )
                }
            guard sizingStatus == 0 else {
                if errno == ENOMEM {
                    continue
                }
                return processDidExit(errno)
                    ? .exited
                    : .unavailable
            }
            guard byteCount > 0,
                  byteCount <= maximumProcessArgumentsBytes else {
                return .unavailable
            }

            var bytes = [UInt8](repeating: 0, count: byteCount)
            errno = 0
            let readStatus =
                query.withUnsafeMutableBufferPointer { queryBuffer in
                    bytes.withUnsafeMutableBytes { storage in
                        sysctl(
                            queryBuffer.baseAddress,
                            UInt32(queryBuffer.count),
                            storage.baseAddress,
                            &byteCount,
                            nil,
                            0
                        )
                    }
                }
            guard readStatus == 0 else {
                if errno == ENOMEM {
                    continue
                }
                return processDidExit(errno)
                    ? .exited
                    : .unavailable
            }
            guard byteCount > 0, byteCount <= bytes.count else {
                return .unavailable
            }
            return inspectProcessArgumentsPayload(
                bytes.prefix(byteCount),
                match: match
            )
        }
        return .unavailable
    }

    static func inspectProcessArgumentsPayload(
        _ processArguments: ArraySlice<UInt8>,
        match: CommandEnvironmentMatch
    ) -> CommandProcessTokenInspection {
        let bytes = Array(processArguments)
        let integerByteCount = MemoryLayout<Int32>.size
        guard bytes.count >= integerByteCount else {
            return .unavailable
        }
        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyBytes(
                    from: source.prefix(integerByteCount)
                )
            }
        }
        guard argumentCount >= 0,
              argumentCount <= 32_768 else {
            return .unavailable
        }
        guard bytes.last == 0 else {
            return .unavailable
        }
        var cursor = integerByteCount
        var stringCount = 0
        while cursor < bytes.count {
            while cursor < bytes.count, bytes[cursor] == 0 {
                cursor += 1
            }
            guard cursor < bytes.count else {
                break
            }
            let entryStart = cursor
            guard skipCString(in: bytes, cursor: &cursor) else {
                return .unavailable
            }
            let entryEnd = max(entryStart, cursor - 1)
            stringCount += 1
            if match.matches(bytes[entryStart..<entryEnd]) {
                return .matched
            }
        }
        return stringCount >= Int(argumentCount) + 1
            ? .absent
            : .unavailable
    }

    private static func skipCString(
        in bytes: [UInt8],
        cursor: inout Int
    ) -> Bool {
        guard cursor < bytes.count,
              let terminator = bytes[cursor...].firstIndex(of: 0) else {
            return false
        }
        cursor = terminator + 1
        return true
    }

    private static func signalProcess(
        _ processIdentifier: pid_t,
        signal: Int32
    ) -> CommandProcessSignalOutcome {
        errno = 0
        if kill(processIdentifier, signal) == 0 {
            return .signaled
        }
        return processDidExit(errno)
            ? .exited
            : .unavailable
    }

    private static func processDidExit(_ errorCode: Int32) -> Bool {
        errorCode == ESRCH
            || errorCode == ENOENT
            || errorCode == EINVAL
    }

    private func signalOwnedProcesses(
        _ processIdentifiers: Set<pid_t>,
        signal: Int32,
        deadline: DispatchTime
    ) -> Bool {
        let markers: [CommandOwnershipFileMarker]
        if usesPersistentMarkers {
            switch markersRequiringProcessScan() {
            case .none:
                return true
            case .ready(let lockedMarkers):
                markers = lockedMarkers
            case .unavailable:
                return false
            }
        } else {
            markers = []
        }
        for processIdentifier in processIdentifiers {
            guard DispatchTime.now() < deadline else {
                return false
            }
            // Recheck the inherited vnode marker immediately before signalling
            // so PID reuse cannot redirect a signal.
            let ownershipInspection = usesPersistentMarkers
                ? Self.inspectProcessMarkerFile(
                    processIdentifier,
                    markers: markers
                )
                : processTokenInspector(processIdentifier, match)
            switch ownershipInspection {
            case .matched:
                break
            case .absent, .exited:
                continue
            case .unavailable:
                return false
            }
            switch processSignaler(processIdentifier, signal) {
            case .signaled, .exited:
                continue
            case .unavailable:
                return false
            }
        }
        return true
    }

    private func waitForOwnedProcessesToExit(
        until deadline: DispatchTime
    ) -> Bool {
        repeat {
            switch matchingProcessIdentifiers(until: deadline) {
            case .found(let identifiers) where identifiers.isEmpty:
                return true
            case .found:
                usleep(10_000)
            case .unavailable:
                return false
            }
        } while DispatchTime.now() < deadline
        guard case .found(let identifiers) =
                matchingProcessIdentifiers(until: .now() + 0.01) else {
            return false
        }
        return identifiers.isEmpty
    }

    private func earlier(
        _ lhs: DispatchTime,
        _ rhs: DispatchTime
    ) -> DispatchTime {
        lhs < rhs ? lhs : rhs
    }
}
