import Foundation

struct ExpiryInfo: Codable, Equatable, Sendable {
    var estimatedExpiryAt: Date?
    var source: ExpirySource
    var detectedAt: Date
    var isFallbackValue: Bool
}
