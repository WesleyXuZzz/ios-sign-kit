import Foundation
@preconcurrency import Network

@MainActor
final class LANControlServerController: ObservableObject {
    typealias SnapshotProvider = LANControlHTTPApplication.SnapshotProvider
    typealias ActionHandler = LANControlHTTPApplication.ActionHandler
    typealias AssetProvider = LANControlHTTPApplication.AssetProvider

    @Published private(set) var status: LANControlServiceStatus = .disabled

    private let queue = DispatchQueue(
        label: "com.xuzw.iossignkit.lan-control",
        qos: .utility
    )
    private let assetProvider: AssetProvider
    private var snapshotProvider: SnapshotProvider?
    private var actionHandler: ActionHandler?
    private var application: LANControlHTTPApplication?
    private var listener: NWListener?
    private var activePort: Int?
    private var configuration = LANControlConfiguration.default

    convenience init() {
        self.init(assetProvider: LANControlServerController.bundledAsset(named:))
    }

    init(assetProvider: @escaping AssetProvider) {
        self.assetProvider = assetProvider
    }

    func configure(
        snapshotProvider: @escaping SnapshotProvider,
        actionHandler: @escaping ActionHandler
    ) {
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
    }

    func apply(_ configuration: LANControlConfiguration) {
        self.configuration = configuration

        guard let snapshotProvider, let actionHandler else {
            stop(status: .failed("局域网控制模块尚未完成初始化。"))
            return
        }

        if let application {
            application.update(configuration: configuration)
        } else {
            application = LANControlHTTPApplication(
                configuration: configuration,
                snapshotProvider: snapshotProvider,
                actionHandler: actionHandler,
                assetProvider: assetProvider
            )
        }

        guard configuration.isEnabled else {
            stop(status: .disabled)
            return
        }
        guard configuration.passwordCredential != nil else {
            stop(status: .failed("请先设置控制密码。"))
            return
        }
        guard let accessURL = configuration.accessURL else {
            stop(status: .failed("局域网控制访问链接无效。"))
            return
        }

        if listener != nil, activePort == configuration.port {
            status = .running(accessURL)
            return
        }

        listener?.cancel()
        listener = nil
        activePort = nil

        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            status = .failed("端口需为 1024–65535 之间的数字。")
            return
        }

        do {
            let listener = try NWListener(using: .tcp, on: port)
            self.listener = listener
            self.activePort = configuration.port
            status = .starting(accessURL)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener,
                          self.listener === listener else {
                        return
                    }
                    self.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor in
                    guard let self, let listener,
                          self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.start(queue: queue)
        } catch {
            stop(status: .failed(Self.listenerFailureMessage(error)))
        }
    }

    func issuePairingURL() throws -> URL {
        guard status.isRunning, let application else {
            throw LANControlServerError.notRunning
        }
        return try application.issuePairingURL()
    }

    func stop() {
        stop(status: .disabled)
    }

    private func stop(status newStatus: LANControlServiceStatus) {
        let oldListener = listener
        listener = nil
        activePort = nil
        oldListener?.cancel()
        status = newStatus
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .setup, .waiting:
            if let url = configuration.accessURL {
                status = .starting(url)
            }
        case .ready:
            if let url = configuration.accessURL {
                status = .running(url)
            } else {
                stop(status: .failed("局域网控制访问链接无效。"))
            }
        case .failed(let error):
            stop(status: .failed(Self.listenerFailureMessage(error)))
        case .cancelled:
            break
        @unknown default:
            stop(status: .failed("局域网控制服务进入未知状态。"))
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLocalNetworkEndpoint(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(
        on connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = accumulated
                if let data {
                    buffer.append(data)
                }
                if buffer.count > 65_536 {
                    self.send(
                        self.errorResponse(
                            "请求内容超过允许大小。",
                            status: 413,
                            reason: "Content Too Large"
                        ),
                        on: connection
                    )
                    return
                }
                if let requestLength = Self.completeRequestLength(in: buffer),
                   buffer.count >= requestLength {
                    guard buffer.count == requestLength,
                          let request = LANControlHTTPRequest.parse(buffer) else {
                        self.send(
                            self.errorResponse(
                                "请求格式无效。",
                                status: 400,
                                reason: "Bad Request"
                            ),
                            on: connection
                        )
                        return
                    }
                    let response = self.application?.handle(request)
                        ?? self.errorResponse(
                            "局域网控制模块尚未完成初始化。",
                            status: 503,
                            reason: "Service Unavailable"
                        )
                    self.send(response, on: connection)
                    return
                }
                if isComplete || error != nil {
                    self.send(
                        self.errorResponse(
                            "请求格式无效。",
                            status: 400,
                            reason: "Bad Request"
                        ),
                        on: connection
                    )
                    return
                }
                self.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func send(
        _ response: LANControlHTTPResponse,
        on connection: NWConnection
    ) {
        connection.send(
            content: response.serialized(),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private func errorResponse(
        _ message: String,
        status: Int,
        reason: String
    ) -> LANControlHTTPResponse {
        LANControlHTTPResponse(
            statusCode: status,
            reason: reason,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Content-Type-Options": "nosniff"
            ],
            body: Data(message.utf8)
        )
    }

    private static func completeRequestLength(in data: Data) -> Int? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: delimiter),
              let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return nil
        }
        var contentLength = 0
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if name == "content-length" {
                let value = line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = Int(value), parsed >= 0 else {
                    return nil
                }
                contentLength = parsed
            }
        }
        return range.upperBound + contentLength
    }

    private static func listenerFailureMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("address already in use")
            || description.localizedCaseInsensitiveContains("in use") {
            return "端口已被占用，请更换端口。"
        }
        return "局域网控制服务启动失败：\(description)"
    }

    nonisolated static func isLocalNetworkEndpoint(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else {
            return false
        }
        let rawHost = String(describing: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let hostWithoutZone = rawHost.split(separator: "%", maxSplits: 1)
            .first.map(String.init) ?? rawHost
        let lowercased = hostWithoutZone.lowercased()

        if lowercased == "localhost"
            || lowercased.hasSuffix(".local")
            || lowercased == "::1"
            || lowercased.hasPrefix("fe80:")
            || lowercased.hasPrefix("fc")
            || lowercased.hasPrefix("fd") {
            return true
        }

        let parts = lowercased.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]),
              let second = Int(parts[1]),
              parts.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) else {
            return false
        }
        return first == 10
            || first == 127
            || (first == 169 && second == 254)
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    nonisolated private static func bundledAsset(named name: String) -> Data? {
        let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "LANControlWeb"
        ) ?? Bundle.module.url(forResource: name, withExtension: nil)
        return url.flatMap { try? Data(contentsOf: $0) }
    }
}
