import Foundation

enum DeployLogFormat {
    static let currentVersion = 2
    static let versionKey = "format_version"
    static var currentVersionHeader: String {
        "\(versionKey)=\(currentVersion)"
    }
}

enum CommandOwnershipMarkerFormat {
    static let currentSchemaVersion = 3
    static let directoryNamespace = "iOSSignKit-process-markers-v\(currentSchemaVersion)"

    static func directoryName(userID: uid_t) -> String {
        "\(directoryNamespace)-\(userID)"
    }
}
