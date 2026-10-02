import Foundation

struct AppInstallMetadataSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var recordedAt: Date
    var bundleIdentifier: String
    var shortVersion: String
    var buildVersion: String
    var expectedExpiryAt: Date?
    var profileSource: String
    // Optional additions to schema 1. The digest identifies profile bytes,
    // not an installation event; the URL comes from the installed App bundle.
    var profileDigest: String? = nil
    var installationAppURL: String? = nil

    var normalizedProfileDigest: String? {
        guard let profileDigest,
              profileDigest.utf8.count == 64,
              profileDigest.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else {
            return nil
        }
        return profileDigest.lowercased()
    }

    func isBound(to appURL: String) -> Bool {
        guard normalizedProfileDigest != nil,
              let installationAppURL,
              let reportedIdentity = InstalledAppIdentity.normalizedAppURL(installationAppURL),
              let observedIdentity = InstalledAppIdentity.normalizedAppURL(appURL) else {
            return false
        }
        return reportedIdentity == observedIdentity
    }
}
