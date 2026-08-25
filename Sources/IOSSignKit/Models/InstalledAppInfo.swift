import Foundation

struct InstalledAppInfo: Codable, Equatable, Sendable {
    var bundleIdentifier: String
    var name: String
    var version: String
    var bundleVersion: String
    var appURL: String
    var builtByDeveloper: Bool
    var installMetadata: AppInstallMetadataSnapshot?
    var installMetadataValidation: InstallMetadataValidation = .notFound
}

enum InstalledAppIdentity {
    static func normalizedAppURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("application-container:") {
            let suffix = String(trimmed.dropFirst("application-container:".count))
            guard let uuid = UUID(uuidString: suffix) else {
                return nil
            }
            return "application-container:\(uuid.uuidString.lowercased())"
        }
        let url: URL?
        if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            url = URL(string: trimmed)
        }
        guard let url, url.isFileURL else {
            return nil
        }

        let components = url.standardizedFileURL.pathComponents
        if let applicationIndex = components.lastIndex(where: {
            $0.caseInsensitiveCompare("Application") == .orderedSame
        }),
        components.indices.contains(applicationIndex + 1),
        let containerUUID = UUID(uuidString: components[applicationIndex + 1]) {
            return "application-container:\(containerUUID.uuidString.lowercased())"
        }

        let path = url.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : "/\(path)"
    }
}

enum InstallMetadataValidation: Codable, Equatable, Sendable {
    case notFound
    case valid
    case invalid(String)
    case unavailable(String)
}
