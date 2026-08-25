import Foundation

enum XcodeContainer: Hashable, Sendable, Codable, Identifiable {
    enum Kind: String, Sendable, Codable {
        case project
        case workspace
    }

    case project(path: String)
    case workspace(path: String)

    var kind: Kind {
        switch self {
        case .project:
            return .project
        case .workspace:
            return .workspace
        }
    }

    var path: String {
        switch self {
        case .project(let path), .workspace(let path):
            return path
        }
    }

    var id: String {
        "\(kind.rawValue):\(path.lengthOfBytes(using: .utf8)):\(path)"
    }

    var xcodebuildArguments: [String] {
        switch self {
        case .project(let path):
            return ["-project", path]
        case .workspace(let path):
            return ["-workspace", path]
        }
    }

    init?(path: String) {
        let pathExtension = URL(fileURLWithPath: path)
            .pathExtension
            .lowercased()
        switch pathExtension {
        case "xcodeproj":
            self = .project(path: path)
        case "xcworkspace":
            self = .workspace(path: path)
        default:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let path = try container.decode(String.self, forKey: .path)
        switch kind {
        case .project:
            self = .project(path: path)
        case .workspace:
            self = .workspace(path: path)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(path, forKey: .path)
    }
}
