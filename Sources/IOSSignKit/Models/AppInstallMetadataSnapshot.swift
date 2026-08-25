import Foundation

struct AppInstallMetadataSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var recordedAt: Date
    var bundleIdentifier: String
    var shortVersion: String
    var buildVersion: String
    var expectedExpiryAt: Date?
    var profileSource: String
}
