import Foundation
import Testing
@testable import IOSSignKit

let testRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

struct ManualRefreshSchedulerSnapshot: Equatable, Sendable {
    let wallNow: Date
    let requestedDelays: [Duration]
    let pendingSleepCount: Int
}

final class ManualRefreshScheduler: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: Duration
        let order: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ScheduleObserver {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var wallNow: Date
        var elapsed: Duration = .zero
        var requestedDelays: [Duration] = []
        var waiters: [Waiter] = []
        var activeIDs: Set<UUID> = []
        var cancelledIDs: Set<UUID> = []
        var scheduleObservers: [ScheduleObserver] = []
        var nextOrder = 0
    }

    private let lock = NSLock()
    private var state: State

    init(
        now: Date = Date()
    ) {
        state = State(wallNow: now)
    }

    var interface: RefreshScheduler {
        RefreshScheduler(
            wallNow: { [weak self] in
                self?.snapshot.wallNow ?? Date()
            },
            sleep: { [weak self] duration in
                guard let self else {
                    throw CancellationError()
                }
                try await self.sleep(for: duration)
            }
        )
    }

    var snapshot: ManualRefreshSchedulerSnapshot {
        lock.withLock {
            ManualRefreshSchedulerSnapshot(
                wallNow: state.wallNow,
                requestedDelays: state.requestedDelays,
                pendingSleepCount: state.waiters.count
            )
        }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        defer { unregister(id: id) }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    id: id,
                    duration: max(duration, .zero),
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancel(id: id)
        }
    }

    func waitUntilScheduled(count: Int) async {
        guard count > 0 else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if state.requestedDelays.count >= count {
                    return true
                }
                state.scheduleObservers.append(
                    ScheduleObserver(
                        count: count,
                        continuation: continuation
                    )
                )
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) {
        let resumptions = lock.withLock {
            let delta = max(duration, .zero)
            state.elapsed += delta
            state.wallNow = state.wallNow.addingTimeInterval(
                delta.timeInterval
            )
            return removeDueWaitersLocked()
        }
        resumptions.forEach { $0.resume(returning: ()) }
    }

    func resumeNextSleep() {
        let resumptions = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard let deadline = state.waiters.map(\.deadline).min() else {
                return []
            }
            let delta = max(deadline - state.elapsed, .zero)
            state.elapsed += delta
            state.wallNow = state.wallNow.addingTimeInterval(
                delta.timeInterval
            )
            return removeDueWaitersLocked()
        }
        resumptions.forEach { $0.resume(returning: ()) }
    }

    func cancelAll() {
        let (continuations, observers) = lock.withLock {
            let continuations = state.waiters.map(\.continuation)
            let observers = state.scheduleObservers.map(\.continuation)
            state.waiters.removeAll()
            state.cancelledIDs.removeAll()
            state.scheduleObservers.removeAll()
            return (continuations, observers)
        }
        continuations.forEach {
            $0.resume(throwing: CancellationError())
        }
        observers.forEach { $0.resume() }
    }

    private func register(
        id: UUID,
        duration: Duration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        var shouldCancel = false
        var shouldResumeImmediately = false
        var observers: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            state.requestedDelays.append(duration)
            if state.cancelledIDs.remove(id) != nil {
                shouldCancel = true
            } else {
                state.activeIDs.insert(id)
                if duration == .zero {
                    shouldResumeImmediately = true
                } else {
                    state.waiters.append(
                        Waiter(
                            id: id,
                            deadline: state.elapsed + duration,
                            order: state.nextOrder,
                            continuation: continuation
                        )
                    )
                    state.nextOrder += 1
                }
            }
            let scheduledCount = state.requestedDelays.count
            let ready = state.scheduleObservers.filter {
                scheduledCount >= $0.count
            }
            state.scheduleObservers.removeAll {
                scheduledCount >= $0.count
            }
            observers = ready.map(\.continuation)
        }
        observers.forEach { $0.resume() }
        if shouldCancel {
            continuation.resume(throwing: CancellationError())
        } else if shouldResumeImmediately {
            continuation.resume(returning: ())
        }
    }

    private func cancel(id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard let index = state.waiters.firstIndex(where: {
                $0.id == id
            }) else {
                if !state.activeIDs.contains(id) {
                    state.cancelledIDs.insert(id)
                }
                return nil
            }
            return state.waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func unregister(id: UUID) {
        lock.withLock {
            state.activeIDs.remove(id)
            state.cancelledIDs.remove(id)
        }
    }

    private func removeDueWaitersLocked()
        -> [CheckedContinuation<Void, any Error>]
    {
        let due = state.waiters
            .filter { $0.deadline <= state.elapsed }
            .sorted {
                if $0.deadline == $1.deadline {
                    return $0.order < $1.order
                }
                return $0.deadline < $1.deadline
            }
        let dueIDs = Set(due.map(\.id))
        state.waiters.removeAll { dueIDs.contains($0.id) }
        return due.map(\.continuation)
    }
}

final class TestEventRecorder<Event: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Event, any Error>
    }

    private struct State {
        var events: [Event] = []
        var history: [Event] = []
        var waiters: [Waiter] = []
        var activeWaiterIDs: Set<UUID> = []
        var cancelledWaiterIDs: Set<UUID> = []
    }

    private let lock = NSLock()
    private var state = State()

    func record(_ event: Event) {
        let waiter = lock.withLock { () -> Waiter? in
            state.history.append(event)
            guard !state.waiters.isEmpty else {
                state.events.append(event)
                return nil
            }
            return state.waiters.removeFirst()
        }
        waiter?.continuation.resume(returning: event)
    }

    func next() async throws -> Event {
        let id = UUID()
        defer { unregisterWaiter(id: id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock { () -> Result<Event, any Error>? in
                    if state.cancelledWaiterIDs.remove(id) != nil {
                        return .failure(CancellationError())
                    }
                    state.activeWaiterIDs.insert(id)
                    if !state.events.isEmpty {
                        return .success(state.events.removeFirst())
                    }
                    state.waiters.append(
                        Waiter(id: id, continuation: continuation)
                    )
                    return nil
                }
                switch immediate {
                case .success(let event):
                    continuation.resume(returning: event)
                case .failure:
                    continuation.resume(throwing: CancellationError())
                case nil:
                    break
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    func snapshot() -> [Event] {
        lock.withLock { state.history }
    }

    func pendingWaiterCount() -> Int {
        lock.withLock { state.waiters.count }
    }

    func cancelAllWaiters() {
        let currentWaiters = lock.withLock {
            let currentWaiters = state.waiters
            state.waiters.removeAll()
            return currentWaiters
        }
        currentWaiters.forEach {
            $0.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancelWaiter(id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Event, any Error>? in
            guard let index = state.waiters.firstIndex(where: {
                $0.id == id
            }) else {
                if !state.activeWaiterIDs.contains(id) {
                    state.cancelledWaiterIDs.insert(id)
                }
                return nil
            }
            return state.waiters.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func unregisterWaiter(id: UUID) {
        lock.withLock {
            state.activeWaiterIDs.remove(id)
            state.cancelledWaiterIDs.remove(id)
        }
    }
}

@MainActor
final class ScheduledNotificationStub: NotificationSending {
    func send(
        _ notification: AppNotification
    ) async -> NotificationDeliveryResult {
        .scheduled
    }
}

@MainActor
private func waitUntil(
    timeout: Duration,
    pollInterval: Duration,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try await Task.sleep(for: pollInterval)
    }
    #expect(condition())
}

@MainActor
func waitForExpiryBootstrap(
    timeout: Duration = .seconds(5),
    condition: @escaping @MainActor () -> Bool
) async throws {
    try await waitUntil(
        timeout: timeout,
        pollInterval: .milliseconds(25),
        condition: condition
    )
}

@MainActor
func waitForRefreshPolicySafety(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
) async throws {
    try await waitUntil(
        timeout: timeout,
        pollInterval: .milliseconds(20),
        condition: condition
    )
}

@MainActor
func waitForMenuBarStatus(
    timeout: Duration = .seconds(10),
    condition: @escaping @MainActor () -> Bool
) async throws {
    try await waitUntil(
        timeout: timeout,
        pollInterval: .milliseconds(10),
        condition: condition
    )
}

@MainActor
func waitForSetupWizard(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
) async throws {
    try await waitUntil(
        timeout: timeout,
        pollInterval: .milliseconds(20),
        condition: condition
    )
}

@MainActor
func waitForSystemWakeMonitor(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    try await waitUntil(
        timeout: timeout,
        pollInterval: .milliseconds(10),
        condition: condition
    )
}
