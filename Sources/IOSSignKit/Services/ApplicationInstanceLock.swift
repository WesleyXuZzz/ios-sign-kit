import Foundation
import Darwin

enum ApplicationInstanceLockError: Error, LocalizedError, Equatable {
    case alreadyRunning
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "iOSSignKit 已在运行。"
        case .unavailable(let reason):
            return "无法建立应用实例锁：\(reason)"
        }
    }
}

final class ApplicationInstanceLock {
    private let fileManager: FileManager
    private let lockFileURL: URL
    private var descriptor: Int32 = -1

    init(
        fileManager: FileManager = .default,
        appSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let directory: URL
        if let appSupportDirectory {
            directory = appSupportDirectory
        } else {
            let baseURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            directory = baseURL.appendingPathComponent("iOSSignKit", isDirectory: true)
        }
        self.lockFileURL = directory.appendingPathComponent(".instance.lock")
    }

    deinit {
        release()
    }

    func acquire() throws {
        guard descriptor < 0 else {
            return
        }
        do {
            try fileManager.createDirectory(
                at: lockFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw ApplicationInstanceLockError.unavailable(error.localizedDescription)
        }

        let openedDescriptor = lockFileURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard openedDescriptor >= 0 else {
            throw ApplicationInstanceLockError.unavailable(
                String(cString: strerror(errno))
            )
        }
        var status = stat()
        guard fstat(openedDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            let code = errno
            Darwin.close(openedDescriptor)
            throw ApplicationInstanceLockError.unavailable(
                code == 0 ? "锁路径不是普通文件。" : String(cString: strerror(code))
            )
        }
        _ = fchmod(openedDescriptor, S_IRUSR | S_IWUSR)
        guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(openedDescriptor)
            if code == EWOULDBLOCK {
                throw ApplicationInstanceLockError.alreadyRunning
            }
            throw ApplicationInstanceLockError.unavailable(
                String(cString: strerror(code))
            )
        }
        descriptor = openedDescriptor
    }

    func release() {
        guard descriptor >= 0 else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }
}
