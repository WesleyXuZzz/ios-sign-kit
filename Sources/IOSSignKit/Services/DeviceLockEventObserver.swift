import Foundation

/// Hints streamed from a device that its lock state may have changed.
enum DeviceLockEvent: Equatable, Sendable {
    /// A CoreDevice observation session is connected and listening.
    case observing
    /// SpringBoard posted `com.apple.springboard.lockstate`. The notification
    /// carries no state, so callers must confirm with a `lockState` query.
    case lockStateMayHaveChanged
    /// The session ended unexpectedly. Events may be missed until the next
    /// `.observing`.
    case interrupted
}

/// Keeps one `devicectl device notification observe` session per waiting
/// device so an unlock is noticed within about a second, instead of polling
/// `lockState` every 30 seconds. The observing process is idle between
/// events, which costs far less than repeatedly spawning `devicectl`.
struct DeviceLockEventObserver: Sendable {
    typealias RunCommand = @Sendable (
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval,
        _ onOutput: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> CommandResult

    static let notificationName = "com.apple.springboard.lockstate"
    /// Long sessions keep respawns rare; each renewal ends with the wait.
    static let sessionSeconds = 30 * 60
    /// `devicectl` requires its global timeout to exceed the session.
    static let toolTimeoutPaddingSeconds = 5
    /// Grace period on top of the session before the runner kills the process.
    static let outerTimeoutPaddingSeconds = 15
    /// Backoff between sessions that failed before connecting.
    static let retryDelays: [Duration] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(300)
    ]

    private let runCommand: RunCommand
    private let sleep: AsyncSleepHandler

    init(
        commandRunner: CommandRunner = CommandRunner(),
        sleep: @escaping AsyncSleepHandler = RefreshScheduler.continuous.sleep
    ) {
        self.runCommand = { arguments, timeoutSeconds, onOutput in
            // Waiting for an event is deferrable background work.
            try await CommandSpawnQualityOfService.$current.withValue(.utility) {
                try await commandRunner.runAsync(
                    "/usr/bin/xcrun",
                    arguments: arguments,
                    onOutput: onOutput,
                    timeoutSeconds: timeoutSeconds
                )
            }
        }
        self.sleep = sleep
    }

    init(
        runCommand: @escaping RunCommand,
        sleep: @escaping AsyncSleepHandler
    ) {
        self.runCommand = runCommand
        self.sleep = sleep
    }

    static func arguments(deviceID: String) -> [String] {
        [
            "devicectl", "device", "notification", "observe",
            "--device", deviceID,
            "--name", notificationName,
            "--session-timeout", "\(sessionSeconds)",
            "--timeout", "\(sessionSeconds + toolTimeoutPaddingSeconds)"
        ]
    }

    /// Streams events until the consumer stops iterating. A session that
    /// connected and then ended restarts immediately; one that never
    /// connected backs off. If the runner cannot confirm the previous process
    /// tree exited, the stream finishes rather than stacking processes.
    func events(deviceID: String) -> AsyncStream<DeviceLockEvent> {
        let runCommand = runCommand
        let sleep = sleep
        let arguments = Self.arguments(deviceID: deviceID)
        let timeoutSeconds = TimeInterval(
            Self.sessionSeconds + Self.outerTimeoutPaddingSeconds
        )

        return AsyncStream { continuation in
            let task = Task {
                var consecutiveFailures = 0
                while !Task.isCancelled {
                    let parser = DeviceLockEventLineParser { event in
                        continuation.yield(event)
                    }
                    let result = try? await runCommand(
                        arguments,
                        timeoutSeconds,
                        parser.consume
                    )
                    guard !Task.isCancelled else {
                        break
                    }
                    if result?.processGroupTerminationWasConfirmed == false {
                        continuation.yield(.interrupted)
                        break
                    }
                    let didConnect = parser.didConnect
                    if didConnect,
                       result?.terminationStatus == 0 {
                        consecutiveFailures = 0
                        continue
                    }
                    continuation.yield(.interrupted)
                    if didConnect {
                        consecutiveFailures = 0
                        continue
                    }
                    let delay = Self.retryDelays[
                        min(consecutiveFailures, Self.retryDelays.count - 1)
                    ]
                    consecutiveFailures += 1
                    do {
                        try await sleep(delay)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// Splits streamed stdout into lines. `devicectl` stdout is human-readable
/// and not a stable format, so the parser only relies on the notification
/// name appearing on its own line. A false positive costs one extra
/// `lockState` query.
final class DeviceLockEventLineParser: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (DeviceLockEvent) -> Void
    private var pendingLine = ""
    private var connected = false

    init(emit: @escaping @Sendable (DeviceLockEvent) -> Void) {
        self.emit = emit
    }

    var didConnect: Bool {
        lock.withLock { connected }
    }

    func consume(_ text: String, isError: Bool) {
        guard !isError else {
            return
        }
        let events: [DeviceLockEvent] = lock.withLock {
            pendingLine += text
            var lines = pendingLine.components(separatedBy: "\n")
            pendingLine = lines.removeLast()
            // Bound memory if the tool never prints a newline.
            if pendingLine.utf8.count > 4_096 {
                lines.append(pendingLine)
                pendingLine = ""
            }
            var events: [DeviceLockEvent] = []
            for line in lines
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !connected {
                    connected = true
                    events.append(.observing)
                }
                if line.contains(DeviceLockEventObserver.notificationName) {
                    events.append(.lockStateMayHaveChanged)
                }
            }
            return events
        }
        events.forEach(emit)
    }
}
