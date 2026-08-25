import Foundation

enum StoredValueLoadResult<Value> {
    case missing
    case loaded(Value)
    case loadedAfterInterruptedWrite(Value)
    case corrupt
}

enum RefreshStateStoreError: Error, LocalizedError {
    case encodedValueExceedsLimit(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .encodedValueExceedsLimit(let maximumBytes):
            return "编码后的状态超过 \(maximumBytes) 字节上限。"
        }
    }
}

struct RefreshStateStore {
    private let fileManager: FileManager
    private let appSupportDirectoryOverride: URL?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let fileReader: BoundedFileReader

    init(fileManager: FileManager = .default, appSupportDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.appSupportDirectoryOverride = appSupportDirectory
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.fileReader = BoundedFileReader()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadConfig() -> AppConfig {
        switch loadConfigResult() {
        case .loaded(let config), .loadedAfterInterruptedWrite(let config):
            return config
        case .missing, .corrupt:
            return .default
        }
    }

    func loadConfigIfPresent() -> AppConfig? {
        load(AppConfig.self, from: configURL)
    }

    func loadConfigResult() -> StoredValueLoadResult<AppConfig> {
        loadResult(AppConfig.self, from: configURL)
    }

    func saveConfig(_ config: AppConfig) throws {
        try save(config, to: configURL)
    }

    func loadState() -> AppState {
        switch loadStateResult() {
        case .loaded(let state), .loadedAfterInterruptedWrite(let state):
            return state
        case .missing, .corrupt:
            return .default
        }
    }

    func loadStateResult() -> StoredValueLoadResult<AppState> {
        let result = loadResult(AppState.self, from: stateURL)
        if fileManager.fileExists(atPath: stateWriteMarkerURL.path) {
            // Data.write(.atomic) leaves either the previous complete state or the
            // newly written complete state. A marker can survive a crash after
            // the rename, so preserve any state that still decodes successfully.
            // The bootstrapper will independently normalize an active deployment.
            if case .loaded(let state) = result {
                return .loadedAfterInterruptedWrite(state)
            }
            return result
        }
        return result
    }

    func saveState(_ state: AppState) throws {
        let data = try encodedDataWithinLimit(state)
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: stateWriteMarkerURL, options: .atomic)
        do {
            try data.write(to: stateURL, options: .atomic)
            try fileManager.removeItem(at: stateWriteMarkerURL)
        } catch {
            // A failed atomic replacement leaves the previous state usable. Do
            // not let a stale marker hide that valid recovery evidence.
            try? fileManager.removeItem(at: stateWriteMarkerURL)
            throw error
        }
    }

    func verifyStatePersistenceAvailable() throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let probeURL = appSupportDirectory
            .appendingPathComponent(".state-write-probe-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: probeURL)
        }
        try Data("probe".utf8).write(to: probeURL, options: .atomic)
        try fileManager.removeItem(at: probeURL)
    }

    private var configURL: URL {
        appSupportDirectory.appendingPathComponent("config.json")
    }

    private var stateURL: URL {
        appSupportDirectory.appendingPathComponent("state.json")
    }

    private var stateWriteMarkerURL: URL {
        appSupportDirectory.appendingPathComponent(".state-write-in-progress")
    }

    private var appSupportDirectory: URL {
        if let appSupportDirectoryOverride {
            return appSupportDirectoryOverride
        }

        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL.appendingPathComponent("iOSSignKit", isDirectory: true)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        switch loadResult(type, from: url) {
        case .loaded(let value), .loadedAfterInterruptedWrite(let value):
            return value
        case .missing, .corrupt:
            return nil
        }
    }

    private func loadResult<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) -> StoredValueLoadResult<T> {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let data = try? fileReader.data(
            at: url,
            maximumBytes: BoundedFileReader.persistedStateMaximumBytes
        ),
              let value = try? decoder.decode(type, from: data) else {
            return .corrupt
        }
        return .loaded(value)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        let data = try encodedDataWithinLimit(value)
        try data.write(to: url, options: .atomic)
    }

    private func encodedDataWithinLimit<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder.encode(value)
        guard data.count <= BoundedFileReader.persistedStateMaximumBytes else {
            throw RefreshStateStoreError.encodedValueExceedsLimit(
                maximumBytes: BoundedFileReader.persistedStateMaximumBytes
            )
        }
        return data
    }
}
