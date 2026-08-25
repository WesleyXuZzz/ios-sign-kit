import Foundation

struct DevelopmentTeamIdentifier: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.count == 10,
              rawValue.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
              }) else {
            return nil
        }
        self.rawValue = rawValue
    }
}
