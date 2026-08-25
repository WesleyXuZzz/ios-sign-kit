import CryptoKit
import Foundation

struct LANControlConfiguration: Codable, Equatable, Sendable {
    static let defaultPort = 51_888

    var isEnabled: Bool
    var accessHost: String
    var port: Int
    var passwordCredential: LANControlPasswordCredential?

    static var `default`: LANControlConfiguration {
        LANControlConfiguration(
            isEnabled: false,
            accessHost: defaultAccessHost,
            port: defaultPort,
            passwordCredential: nil
        )
    }

    init(
        isEnabled: Bool,
        accessHost: String,
        port: Int,
        passwordCredential: LANControlPasswordCredential?
    ) {
        self.isEnabled = isEnabled
        self.accessHost = accessHost.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.port = port
        self.passwordCredential = passwordCredential
    }

    var accessURL: URL? {
        guard Self.validationMessage(host: accessHost, port: port) == nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = accessHost
        components.port = port
        return components.url
    }

    static func validationMessage(host rawHost: String, port: Int) -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return "访问主机不能为空。"
        }
        guard host == rawHost, !host.contains(where: \Character.isWhitespace) else {
            return "访问主机不能包含空格。"
        }
        let lowercased = host.lowercased()
        guard !lowercased.hasPrefix("http://"),
              !lowercased.hasPrefix("https://"),
              !host.contains(":"),
              !host.contains("/") else {
            return "访问主机不应包含协议、端口或路径。"
        }
        guard isValidHost(host) else {
            return "访问主机格式无效。"
        }
        guard (1_024...65_535).contains(port) else {
            return "端口需为 1024–65535 之间的数字。"
        }
        return nil
    }

    private static var defaultAccessHost: String {
        let hostName = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostName.isEmpty else {
            return "localhost"
        }
        return hostName.contains(".") ? hostName : "\(hostName).local"
    }

    private static func isValidHost(_ host: String) -> Bool {
        let numericParts = host.split(separator: ".", omittingEmptySubsequences: false)
        if numericParts.count == 4,
           numericParts.allSatisfy({ part in
               !part.isEmpty && part.allSatisfy(\.isNumber)
           }) {
            return numericParts.allSatisfy { part in
                guard part.count == 1 || part.first != "0",
                      let value = Int(part) else {
                    return false
                }
                return (0...255).contains(value)
            }
        }

        guard host.count <= 253 else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                guard !label.isEmpty,
                      label.count <= 63,
                      label.first != "-",
                      label.last != "-" else {
                    return false
                }
                return label.allSatisfy { character in
                    character.isASCII
                        && (character.isLetter
                            || character.isNumber
                            || character == "-")
                }
            }
    }
}

struct LANControlPasswordCredential: Codable, Equatable, Sendable {
    static let productionRounds = 120_000
    static let maximumAcceptedRounds = 500_000

    let salt: Data
    let verifier: Data
    let rounds: Int

    static func make(
        password: String,
        salt: Data? = nil,
        rounds: Int = productionRounds
    ) throws -> LANControlPasswordCredential {
        guard password.count >= 6 else {
            throw LANControlPasswordError.tooShort
        }
        guard (1...maximumAcceptedRounds).contains(rounds) else {
            throw LANControlPasswordError.invalidCredential
        }
        let resolvedSalt = salt ?? randomData(count: 16)
        return LANControlPasswordCredential(
            salt: resolvedSalt,
            verifier: derive(
                password: password,
                salt: resolvedSalt,
                rounds: rounds
            ),
            rounds: rounds
        )
    }

    func verifies(_ password: String) -> Bool {
        guard (1...Self.maximumAcceptedRounds).contains(rounds),
              salt.count >= 16,
              verifier.count == 32 else {
            return false
        }
        let candidate = Self.derive(
            password: password,
            salt: salt,
            rounds: rounds
        )
        guard candidate.count == verifier.count else {
            return false
        }
        return zip(candidate, verifier).reduce(UInt8.zero) {
            $0 | ($1.0 ^ $1.1)
        } == 0
    }

    private static func derive(
        password: String,
        salt: Data,
        rounds: Int
    ) -> Data {
        var initial = Data(password.utf8)
        initial.append(salt)
        var digest = Data(SHA256.hash(data: initial))
        guard rounds > 1 else {
            return digest
        }
        for _ in 1..<rounds {
            var input = digest
            input.append(salt)
            digest = Data(SHA256.hash(data: input))
        }
        return digest
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

enum LANControlPasswordError: Error, LocalizedError, Equatable {
    case tooShort
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .tooShort:
            "控制密码至少需要 6 个字符。"
        case .invalidCredential:
            "控制密码校验信息无效。"
        }
    }
}
