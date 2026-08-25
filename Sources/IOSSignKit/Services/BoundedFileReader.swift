import Foundation

enum BoundedFileReaderError: Error, LocalizedError, Equatable {
    case invalidLimit
    case exceedsLimit(fileName: String, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "文件读取上限必须大于零。"
        case .exceedsLimit(let fileName, let maximumBytes):
            return "\(fileName) 超过允许的 \(maximumBytes) 字节，已停止读取。"
        }
    }
}

struct BoundedFileReader {
    static let structuredOutputMaximumBytes = 8 * 1_024 * 1_024
    static let metadataMaximumBytes = 1 * 1_024 * 1_024
    static let persistedStateMaximumBytes = 1 * 1_024 * 1_024

    func data(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0, maximumBytes < Int.max else {
            throw BoundedFileReaderError.invalidLimit
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var result = Data()
        let readLimit = maximumBytes + 1
        while result.count < readLimit {
            let requestedCount = min(64 * 1_024, readLimit - result.count)
            guard let chunk = try handle.read(upToCount: requestedCount),
                  !chunk.isEmpty else {
                break
            }
            result.append(chunk)
        }

        guard result.count <= maximumBytes else {
            throw BoundedFileReaderError.exceedsLimit(
                fileName: url.lastPathComponent,
                maximumBytes: maximumBytes
            )
        }
        return result
    }

    func utf8String(
        at url: URL,
        maximumBytes: Int
    ) throws -> String {
        String(
            decoding: try data(at: url, maximumBytes: maximumBytes),
            as: UTF8.self
        )
    }
}

enum DiagnosticText {
    static let maximumCharacters = 4_000

    static func bounded(
        _ value: String,
        maximumCharacters: Int = maximumCharacters
    ) -> String {
        let prefix = value.prefix(max(maximumCharacters, 0))
        guard prefix.endIndex != value.endIndex else {
            return value
        }
        return "\(prefix)…"
    }
}
