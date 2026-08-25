import Foundation

struct LANControlHTTPRequest: Equatable, Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data

    var path: String {
        URLComponents(string: target)?.path ?? target
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    static func parse(_ data: Data) -> LANControlHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let delimiterRange = data.range(of: delimiter),
              let head = String(
                  data: data[..<delimiterRange.lowerBound],
                  encoding: .utf8
              ) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[2].hasPrefix("HTTP/1.") else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return nil
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headers[name] == nil else {
                return nil
            }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else {
            return nil
        }
        let bodyStart = delimiterRange.upperBound
        let body = Data(data[bodyStart...])
        let expectedLength = Int(headers["content-length"] ?? "0") ?? -1
        guard expectedLength >= 0, body.count == expectedLength else {
            return nil
        }
        return LANControlHTTPRequest(
            method: String(parts[0]).uppercased(),
            target: String(parts[1]),
            headers: headers,
            body: body
        )
    }
}

struct LANControlHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let reason: String
    let headers: [String: String]
    let body: Data

    func serialized() -> Data {
        var mergedHeaders = headers
        mergedHeaders["Content-Length"] = String(body.count)
        mergedHeaders["Connection"] = "close"
        var lines = ["HTTP/1.1 \(statusCode) \(reason)"]
        for key in mergedHeaders.keys.sorted() {
            lines.append("\(key): \(mergedHeaders[key] ?? "")")
        }
        lines.append("")
        lines.append("")
        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }
}

@MainActor
final class LANControlHTTPApplication {
    typealias SnapshotProvider = @MainActor @Sendable () -> LANControlSnapshot
    typealias ActionHandler = @MainActor @Sendable (
        LANControlAction
    ) -> LANControlActionOutcome
    typealias AssetProvider = @Sendable (String) -> Data?

    private struct LoginPayload: Decodable {
        let password: String
    }

    private struct PairPayload: Decodable {
        let token: String
    }

    private struct RenewPayload: Decodable {
        let profileRefreshMode: ProvisioningProfileRefreshMode?
    }

    private struct SessionPayload: Encodable {
        let token: String
        let expiresAt: Date
    }

    private var configuration: LANControlConfiguration
    private let snapshotProvider: SnapshotProvider
    private let actionHandler: ActionHandler
    private let assetProvider: AssetProvider
    private let now: @Sendable () -> Date
    private var sessions: [String: Date] = [:]
    private var pairingTokens: [String: Date] = [:]
    private var failedLoginAttempts: [Date] = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: LANControlConfiguration,
        snapshotProvider: @escaping SnapshotProvider,
        actionHandler: @escaping ActionHandler,
        assetProvider: @escaping AssetProvider,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
        self.assetProvider = assetProvider
        self.now = now
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func update(configuration: LANControlConfiguration) {
        let credentialChanged = self.configuration.passwordCredential
            != configuration.passwordCredential
        self.configuration = configuration
        if !configuration.isEnabled || credentialChanged {
            sessions.removeAll()
            pairingTokens.removeAll()
        }
    }

    func issuePairingURL() throws -> URL {
        guard configuration.isEnabled,
              configuration.passwordCredential != nil,
              var components = configuration.accessURL.flatMap({
                  URLComponents(url: $0, resolvingAgainstBaseURL: false)
              }) else {
            throw LANControlServerError.notRunning
        }
        pruneExpiredCredentials()
        let token = Self.randomToken()
        pairingTokens[token] = now().addingTimeInterval(120)
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "pair", value: token)]
        guard let url = components.url else {
            throw LANControlServerError.invalidAccessURL
        }
        return url
    }

    func handle(_ request: LANControlHTTPRequest) -> LANControlHTTPResponse {
        pruneExpiredCredentials()
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return asset("index.html", contentType: "text/html; charset=utf-8")
        case ("GET", "/styles.css"):
            return asset("styles.css", contentType: "text/css; charset=utf-8")
        case ("GET", "/app.js"):
            return asset(
                "app.js",
                contentType: "text/javascript; charset=utf-8"
            )
        case ("POST", "/api/login"):
            return login(request)
        case ("POST", "/api/pair"):
            return pair(request)
        case ("POST", "/api/logout"):
            if let token = bearerToken(in: request) {
                sessions[token] = nil
            }
            return json(LANControlActionOutcome.accepted("已退出。"))
        case ("GET", "/api/status"):
            guard isAuthorized(request) else {
                return unauthorized()
            }
            return json(snapshotProvider())
        case ("POST", "/api/renew"):
            guard isAuthorized(request) else {
                return unauthorized()
            }
            return renew(request)
        case ("POST", "/api/recheck"):
            guard isAuthorized(request) else {
                return unauthorized()
            }
            return actionResponse(actionHandler(.recheck))
        case ("POST", "/api/dismiss-result"):
            guard isAuthorized(request) else {
                return unauthorized()
            }
            return actionResponse(actionHandler(.dismissResult))
        default:
            return text("未找到该页面。", status: 404, reason: "Not Found")
        }
    }

    private func login(_ request: LANControlHTTPRequest) -> LANControlHTTPResponse {
        let cutoff = now().addingTimeInterval(-60)
        failedLoginAttempts.removeAll { $0 < cutoff }
        guard failedLoginAttempts.count < 8 else {
            return text(
                "尝试次数过多，请稍后再试。",
                status: 429,
                reason: "Too Many Requests"
            )
        }
        guard let payload = try? decoder.decode(LoginPayload.self, from: request.body),
              let credential = configuration.passwordCredential,
              credential.verifies(payload.password) else {
            failedLoginAttempts.append(now())
            return text("密码不正确。", status: 401, reason: "Unauthorized")
        }
        failedLoginAttempts.removeAll()
        return issueSession()
    }

    private func pair(_ request: LANControlHTTPRequest) -> LANControlHTTPResponse {
        guard let payload = try? decoder.decode(PairPayload.self, from: request.body),
              let expiresAt = pairingTokens.removeValue(forKey: payload.token),
              expiresAt > now() else {
            return text(
                "二维码已失效，请在 Mac 上重新生成。",
                status: 401,
                reason: "Unauthorized"
            )
        }
        return issueSession()
    }

    private func renew(
        _ request: LANControlHTTPRequest
    ) -> LANControlHTTPResponse {
        let profileRefreshMode: ProvisioningProfileRefreshMode?
        if request.body.isEmpty {
            profileRefreshMode = nil
        } else {
            guard let payload = try? decoder.decode(
                RenewPayload.self,
                from: request.body
            ) else {
                return json(
                    LANControlActionOutcome.rejected("签名策略无效，请重新选择。"),
                    status: 400,
                    reason: "Bad Request"
                )
            }
            profileRefreshMode = payload.profileRefreshMode
        }
        return actionResponse(
            actionHandler(.renew(profileRefreshMode: profileRefreshMode))
        )
    }

    private func issueSession() -> LANControlHTTPResponse {
        let token = Self.randomToken()
        let expiresAt = now().addingTimeInterval(8 * 60 * 60)
        sessions[token] = expiresAt
        return json(SessionPayload(token: token, expiresAt: expiresAt))
    }

    private func isAuthorized(_ request: LANControlHTTPRequest) -> Bool {
        guard let token = bearerToken(in: request),
              let expiry = sessions[token],
              expiry > now() else {
            return false
        }
        return true
    }

    private func bearerToken(in request: LANControlHTTPRequest) -> String? {
        guard let value = request.header("authorization"),
              value.hasPrefix("Bearer ") else {
            return nil
        }
        let token = String(value.dropFirst("Bearer ".count))
        return token.isEmpty ? nil : token
    }

    private func pruneExpiredCredentials() {
        let current = now()
        sessions = sessions.filter { $0.value > current }
        pairingTokens = pairingTokens.filter { $0.value > current }
    }

    private func actionResponse(
        _ outcome: LANControlActionOutcome
    ) -> LANControlHTTPResponse {
        json(
            outcome,
            status: outcome.accepted ? 202 : 409,
            reason: outcome.accepted ? "Accepted" : "Conflict"
        )
    }

    private func asset(
        _ name: String,
        contentType: String
    ) -> LANControlHTTPResponse {
        guard let data = assetProvider(name) else {
            return text("页面资源不可用。", status: 500, reason: "Internal Server Error")
        }
        return LANControlHTTPResponse(
            statusCode: 200,
            reason: "OK",
            headers: securityHeaders.merging([
                "Content-Type": contentType,
                "Cache-Control": "no-store"
            ]) { _, new in new },
            body: data
        )
    }

    private func unauthorized() -> LANControlHTTPResponse {
        text("会话已失效，请重新登录。", status: 401, reason: "Unauthorized")
    }

    private func json<T: Encodable>(
        _ value: T,
        status: Int = 200,
        reason: String = "OK"
    ) -> LANControlHTTPResponse {
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return LANControlHTTPResponse(
            statusCode: status,
            reason: reason,
            headers: securityHeaders.merging([
                "Content-Type": "application/json; charset=utf-8",
                "Cache-Control": "no-store"
            ]) { _, new in new },
            body: body
        )
    }

    private func text(
        _ value: String,
        status: Int,
        reason: String
    ) -> LANControlHTTPResponse {
        LANControlHTTPResponse(
            statusCode: status,
            reason: reason,
            headers: securityHeaders.merging([
                "Content-Type": "text/plain; charset=utf-8",
                "Cache-Control": "no-store"
            ]) { _, new in new },
            body: Data(value.utf8)
        )
    }

    private var securityHeaders: [String: String] {
        [
            "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY"
        ]
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data(
            (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        )
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum LANControlServerError: Error, LocalizedError, Equatable {
    case notRunning
    case invalidAccessURL
    case assetMissing(String)
    case requestTooLarge
    case malformedRequest

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "局域网控制服务尚未运行。"
        case .invalidAccessURL:
            "局域网控制访问链接无效。"
        case .assetMissing(let name):
            "局域网控制页面资源缺失：\(name)"
        case .requestTooLarge:
            "请求内容超过允许大小。"
        case .malformedRequest:
            "请求格式无效。"
        }
    }
}
