import Foundation

/// The single scheduling boundary used by refresh workflows.
///
/// Production code uses ``continuous``. Tests can provide a manual adapter so
/// business time and suspended work advance together without waiting on the
/// wall clock.
struct RefreshScheduler: Sendable {
    let wallNow: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    init(
        wallNow: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.wallNow = wallNow
        self.sleep = sleep
    }

    static let continuous = RefreshScheduler(
        wallNow: Date.init,
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

typealias AsyncSleepHandler = @Sendable (Duration) async throws -> Void
