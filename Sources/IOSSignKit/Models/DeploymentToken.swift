import Foundation

struct DeploymentToken: Equatable, Sendable {
    static let prefix = "ios-sign-kit-deploy-"

    let rawValue: String

    init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(Self.prefix) else {
            return nil
        }
        let suffix = String(normalized.dropFirst(Self.prefix.count))
        guard suffix.count == 36,
              let uuid = UUID(uuidString: suffix),
              uuid.uuidString.caseInsensitiveCompare(suffix) == .orderedSame else {
            return nil
        }
        self.rawValue = normalized
    }

    static func make() -> DeploymentToken {
        DeploymentToken(rawValue: "\(prefix)\(UUID().uuidString)")!
    }
}
