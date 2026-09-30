import Foundation
import Testing
@testable import IOSSignKit

struct DeviceLockEventObserverTests {
    @Test
    func parserJoinsSplitChunksAndIgnoresStandardError() {
        let events = LockedEventLog()
        let parser = DeviceLockEventLineParser { events.append($0) }

        parser.consume("Darwin notification observation started. 60 sec", isError: false)
        #expect(events.values.isEmpty)
        #expect(!parser.didConnect)
        parser.consume("onds remaining:\n• 17:41:28 : Observed 'com.apple.spring", isError: false)
        #expect(events.values == [.observing])
        parser.consume("board.lockstate'\n", isError: false)
        parser.consume("warning: com.apple.springboard.lockstate\n", isError: true)
        parser.consume("\n\n", isError: false)

        #expect(parser.didConnect)
        #expect(events.values == [.observing, .lockStateMayHaveChanged])
    }

    @Test
    func observeArgumentsTargetTheExactDeviceAndOutliveTheSession() throws {
        let arguments = DeviceLockEventObserver.arguments(deviceID: "00008120-ABC")
        #expect(arguments.prefix(4) == ["devicectl", "device", "notification", "observe"])
        #expect(arguments.contains("00008120-ABC"))
        #expect(arguments.contains(DeviceLockEventObserver.notificationName))
        let sessionIndex = try #require(arguments.firstIndex(of: "--session-timeout"))
        let timeoutIndex = try #require(arguments.firstIndex(of: "--timeout"))
        let session = try #require(Int(arguments[sessionIndex + 1]))
        let timeout = try #require(Int(arguments[timeoutIndex + 1]))
        #expect(session == DeviceLockEventObserver.sessionSeconds)
        #expect(timeout > session)
        #expect(
            TimeInterval(session + DeviceLockEventObserver.outerTimeoutPaddingSeconds)
                > TimeInterval(timeout)
        )
    }

    @Test
    func streamRestartsConnectedSessionsAndBacksOffFailedStarts() async throws {
        let scheduler = ManualRefreshScheduler()
        let calls = LockedCounter()
        let observer = DeviceLockEventObserver(
            runCommand: { _, _, onOutput in
                switch calls.increment() {
                case 1:
                    onOutput("Darwin notification observation started.\n", false)
                    onOutput("Observed 'com.apple.springboard.lockstate'\n", false)
                    return CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
                case 2:
                    return CommandResult(standardOutput: "", standardError: "", terminationStatus: 1)
                default:
                    return CommandResult(
                        standardOutput: "",
                        standardError: "",
                        terminationStatus: 1,
                        processGroupTerminationWasConfirmed: false
                    )
                }
            },
            sleep: scheduler.interface.sleep
        )

        var iterator = observer.events(deviceID: "iphone-1").makeAsyncIterator()
        #expect(await iterator.next() == .observing)
        #expect(await iterator.next() == .lockStateMayHaveChanged)
        // The clean session restarted at once; the next one failed before
        // connecting, so the observer reports it and backs off.
        #expect(await iterator.next() == .interrupted)
        await scheduler.waitUntilScheduled(count: 1)
        #expect(scheduler.snapshot.requestedDelays == [DeviceLockEventObserver.retryDelays[0]])
        #expect(calls.value == 2)

        scheduler.advance(by: DeviceLockEventObserver.retryDelays[0])
        // An unconfirmed process tree stops the stream instead of respawning.
        #expect(await iterator.next() == .interrupted)
        #expect(await iterator.next() == nil)
        #expect(calls.value == 3)
    }

    @Test
    func cancellingTheConsumerCancelsTheRunningSession() async throws {
        let started = TestEventRecorder<Void>()
        let cancelled = TestEventRecorder<Void>()
        let observer = DeviceLockEventObserver(
            runCommand: { _, _, _ in
                started.record(())
                do {
                    try await Task.sleep(for: .seconds(3_600))
                } catch {
                    cancelled.record(())
                    throw error
                }
                return CommandResult(standardOutput: "", standardError: "", terminationStatus: 0)
            },
            sleep: { _ in throw CancellationError() }
        )

        let consumer = Task {
            for await _ in observer.events(deviceID: "iphone-1") {}
        }
        _ = try await started.next()
        consumer.cancel()
        _ = try await cancelled.next()
        await consumer.value
    }
}

private final class LockedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DeviceLockEvent] = []

    var values: [DeviceLockEvent] { lock.withLock { storage } }

    func append(_ event: DeviceLockEvent) {
        lock.withLock { storage.append(event) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
