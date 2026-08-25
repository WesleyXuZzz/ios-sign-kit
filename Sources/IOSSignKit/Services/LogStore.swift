import Foundation

enum DeployLogFilename {
    private static let prefix = "deploy-"
    private static let suffix = ".log"
    static let operationalTimeZoneSecondsFromGMT = 8 * 60 * 60
    static let timestampFormat = "yyyy-MM-dd-HH-mm-ss.SSS-'T+08-00'"
    private static let operationalTimeZone = TimeZone(
        secondsFromGMT: operationalTimeZoneSecondsFromGMT
    )!

    static func make(for date: Date) -> String {
        let timestamp = formatter().string(from: date)
        return "\(prefix)\(timestamp)\(suffix)"
    }

    static func date(from filename: String) -> Date? {
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return nil
        }

        let rawTimestamp = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        guard let date = formatter().date(from: rawTimestamp), make(for: date) == filename else {
            return nil
        }

        return date
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = operationalTimeZone
        formatter.dateFormat = timestampFormat
        formatter.isLenient = false
        return formatter
    }
}

struct LogStore: Sendable {
    private let logsDirectoryURL: URL?
    private let maximumLogCount: Int
    private let maximumTotalBytes: UInt64

    init(
        logsDirectoryURL: URL? = nil,
        maximumLogCount: Int = 200,
        maximumTotalBytes: UInt64 = 256 * 1_024 * 1_024
    ) {
        self.logsDirectoryURL = logsDirectoryURL
        self.maximumLogCount = max(maximumLogCount, 1)
        self.maximumTotalBytes = max(maximumTotalBytes, 1)
    }

    func makeLogFileURL() throws -> URL {
        let directory = try logsDirectory()
        return directory.appendingPathComponent(DeployLogFilename.make(for: Date()))
    }

    func writeLog(_ content: String, to url: URL) throws {
        let fileManager = FileManager()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        try? enforceRetentionPolicy()
    }

    func listLogFiles() throws -> [URL] {
        let fileManager = FileManager()
        let directory = try logsDirectory()
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter { $0.pathExtension == "log" }
    }

    private func enforceRetentionPolicy() throws {
        let deployLogs = try listLogFiles()
            .filter { DeployLogFilename.date(from: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var retainedCount = 0
        var retainedBytes: UInt64 = 0

        for url in deployLogs {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let fileBytes = UInt64(max(values?.fileSize ?? 0, 0))
            let shouldAlwaysKeepNewest = retainedCount == 0
            let fitsPolicy = retainedCount < maximumLogCount
                && retainedBytes <= maximumTotalBytes
                && fileBytes <= maximumTotalBytes - retainedBytes
            if shouldAlwaysKeepNewest || fitsPolicy {
                retainedCount += 1
                retainedBytes += fileBytes
            } else {
                try FileManager().removeItem(at: url)
            }
        }
    }

    private func logsDirectory() throws -> URL {
        let fileManager = FileManager()
        if let logsDirectoryURL {
            try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
            return logsDirectoryURL
        }

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = baseURL.appendingPathComponent("iOSSignKit/logs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
