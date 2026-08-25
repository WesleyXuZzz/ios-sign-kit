import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct LANControlHTTPApplicationTests {
    private struct SessionPayload: Decodable {
        let token: String
    }

    @Test
    func loginAuthorizesStatusAndActionWhileWrongPasswordFails() throws {
        let credential = try LANControlPasswordCredential.make(
            password: "secret-pass",
            salt: Data(repeating: 3, count: 16),
            rounds: 3
        )
        var requestedAction: LANControlAction?
        let application = makeApplication(
            credential: credential,
            actionHandler: { action in
                requestedAction = action
                return .accepted("accepted")
            }
        )

        #expect(application.handle(request(method: "GET", path: "/api/status")).statusCode == 401)
        #expect(
            application.handle(
                request(
                    method: "POST",
                    path: "/api/login",
                    json: ["password": "wrong-pass"]
                )
            ).statusCode == 401
        )

        let login = application.handle(
            request(
                method: "POST",
                path: "/api/login",
                json: ["password": "secret-pass"]
            )
        )
        let token = try JSONDecoder().decode(
            SessionPayload.self,
            from: login.body
        ).token
        let authorization = ["authorization": "Bearer \(token)"]

        let status = application.handle(
            request(method: "GET", path: "/api/status", headers: authorization)
        )
        #expect(status.statusCode == 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            LANControlSnapshot.self,
            from: status.body
        )
        #expect(snapshot.deviceStatus == "离线")
        #expect(snapshot.deviceStatusTone == .warning)
        let renew = application.handle(
            request(method: "POST", path: "/api/renew", headers: authorization)
        )
        #expect(renew.statusCode == 202)
        guard case .renew(profileRefreshMode: nil) = requestedAction else {
            Issue.record("续签动作未传递到受控动作接缝。")
            return
        }

        let forceRenew = application.handle(
            request(
                method: "POST",
                path: "/api/renew",
                headers: authorization,
                json: ["profileRefreshMode": "force"]
            )
        )
        #expect(forceRenew.statusCode == 202)
        guard case .renew(profileRefreshMode: .force) = requestedAction else {
            Issue.record("网页选择的覆盖签名策略未传递到受控动作接缝。")
            return
        }

        requestedAction = nil
        let invalidRenew = application.handle(
            request(
                method: "POST",
                path: "/api/renew",
                headers: authorization,
                json: ["profileRefreshMode": "unexpected"]
            )
        )
        #expect(invalidRenew.statusCode == 400)
        #expect(requestedAction == nil)

        let dismissResult = application.handle(
            request(
                method: "POST",
                path: "/api/dismiss-result",
                headers: authorization
            )
        )
        #expect(dismissResult.statusCode == 202)
        guard case .dismissResult = requestedAction else {
            Issue.record("完成动作未传递到受控动作接缝。")
            return
        }
    }

    @Test
    func renewCanRequestProfileChoiceFromAuthenticatedWebClient() throws {
        let credential = try LANControlPasswordCredential.make(
            password: "secret-pass",
            salt: Data(repeating: 7, count: 16),
            rounds: 2
        )
        let application = makeApplication(
            credential: credential,
            actionHandler: { action in
                guard case .renew(profileRefreshMode: nil) = action else {
                    return .rejected("unexpected")
                }
                return .profileChoiceRequired("请选择本次签名策略。")
            }
        )
        let login = application.handle(
            request(
                method: "POST",
                path: "/api/login",
                json: ["password": "secret-pass"]
            )
        )
        let token = try JSONDecoder().decode(
            SessionPayload.self,
            from: login.body
        ).token

        let response = application.handle(
            request(
                method: "POST",
                path: "/api/renew",
                headers: ["authorization": "Bearer \(token)"]
            )
        )
        let outcome = try JSONDecoder().decode(
            LANControlActionOutcome.self,
            from: response.body
        )

        #expect(response.statusCode == 409)
        #expect(!outcome.accepted)
        #expect(outcome.requiresProfileChoice)
        #expect(outcome.message == "请选择本次签名策略。")
    }

    @Test
    func pairingTokenIsSingleUseAndCreatesIndependentSession() throws {
        let credential = try LANControlPasswordCredential.make(
            password: "secret-pass",
            salt: Data(repeating: 4, count: 16),
            rounds: 2
        )
        let application = makeApplication(credential: credential)
        let pairingURL = try application.issuePairingURL()
        let token = try #require(
            URLComponents(url: pairingURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pair" })?.value
        )

        let first = application.handle(
            request(
                method: "POST",
                path: "/api/pair",
                json: ["token": token]
            )
        )
        #expect(first.statusCode == 200)
        #expect(
            application.handle(
                request(
                    method: "POST",
                    path: "/api/pair",
                    json: ["token": token]
                )
            ).statusCode == 401
        )
    }

    @Test
    func parserRequiresCompleteBodyAndResponseAddsConnectionClose() throws {
        let raw = Data(
            "POST /api/login HTTP/1.1\r\nHost: test\r\nContent-Length: 21\r\n\r\n{\"password\":\"secret\"}".utf8
        )
        let parsed = try #require(LANControlHTTPRequest.parse(raw))
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/api/login")
        #expect(parsed.header("host") == "test")

        let response = LANControlHTTPResponse(
            statusCode: 200,
            reason: "OK",
            headers: ["Content-Type": "text/plain"],
            body: Data("ok".utf8)
        )
        let serialized = String(decoding: response.serialized(), as: UTF8.self)
        #expect(serialized.contains("Connection: close"))
        #expect(serialized.contains("Content-Length: 2"))
    }

    @Test
    func parserRejectsAmbiguousMessageFraming() {
        let duplicateLength = Data(
            "POST /api/login HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\nx".utf8
        )
        let chunked = Data(
            "POST /api/login HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
        )

        #expect(LANControlHTTPRequest.parse(duplicateLength) == nil)
        #expect(LANControlHTTPRequest.parse(chunked) == nil)
    }

    private func makeApplication(
        credential: LANControlPasswordCredential,
        actionHandler: @escaping LANControlHTTPApplication.ActionHandler = {
            _ in .accepted("accepted")
        }
    ) -> LANControlHTTPApplication {
        LANControlHTTPApplication(
            configuration: LANControlConfiguration(
                isEnabled: true,
                accessHost: "test-mac.local",
                port: 51_888,
                passwordCredential: credential
            ),
            snapshotProvider: {
                LANControlSnapshot(
                    pageState: .ready,
                    appName: "Example",
                    deviceName: "iPhone",
                    deviceStatus: "离线",
                    deviceStatusTone: .warning,
                    signatureStatus: "已过期",
                    message: "ready",
                    canRenew: true,
                    canRecheck: true,
                    phaseIndex: nil,
                    phases: LANControlOperationPhase.allCases.map(\.title),
                    elapsedSeconds: 0,
                    expectedExpiryAt: nil,
                    checkedAt: Date(timeIntervalSince1970: 1)
                )
            },
            actionHandler: actionHandler,
            assetProvider: { _ in Data("asset".utf8) }
        )
    }

    private func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        json: [String: String]? = nil
    ) -> LANControlHTTPRequest {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            ?? Data()
        return LANControlHTTPRequest(
            method: method,
            target: path,
            headers: headers,
            body: body
        )
    }
}
