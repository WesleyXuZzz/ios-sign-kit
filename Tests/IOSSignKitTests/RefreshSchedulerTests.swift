import Foundation
import Testing
@testable import IOSSignKit

struct RefreshSchedulerTests {
    @Test
    func advanceResumesOnlyReachedDeadlinesAndMovesWallTime()
        async throws
    {
        let initialDate = Date(
            timeIntervalSinceReferenceDate: 800_000_000
        )
        let scheduler = ManualRefreshScheduler(now: initialDate)
        let events = TestEventRecorder<String>()
        let shortTask = Task {
            try await scheduler.interface.sleep(.seconds(5))
            events.record("short")
        }
        await scheduler.waitUntilScheduled(count: 1)
        let longTask = Task {
            try await scheduler.interface.sleep(.seconds(20))
            events.record("long")
        }
        await scheduler.waitUntilScheduled(count: 2)

        scheduler.advance(by: .seconds(5))
        #expect(try await events.next() == "short")
        #expect(events.snapshot() == ["short"])
        #expect(scheduler.snapshot.pendingSleepCount == 1)
        #expect(
            scheduler.snapshot.wallNow
                == initialDate.addingTimeInterval(5)
        )

        scheduler.advance(by: .seconds(15))
        #expect(try await events.next() == "long")
        try await shortTask.value
        try await longTask.value
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    @Test
    func cancellationRemovesPendingSleep() async {
        let scheduler = ManualRefreshScheduler()
        let task = Task {
            try await scheduler.interface.sleep(.seconds(30))
        }
        await scheduler.waitUntilScheduled(count: 1)
        #expect(scheduler.snapshot.pendingSleepCount == 1)

        task.cancel()
        do {
            try await task.value
            Issue.record("取消后的 sleep 不应正常返回。")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("取消后的 sleep 返回了意外错误：\(error)")
        }

        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }

    @Test
    func cancelAllSettlesEveryPendingSleep() async {
        let scheduler = ManualRefreshScheduler()
        let first = Task {
            try await scheduler.interface.sleep(.seconds(5))
        }
        let second = Task {
            try await scheduler.interface.sleep(.seconds(10))
        }
        await scheduler.waitUntilScheduled(count: 2)

        scheduler.cancelAll()
        for task in [first, second] {
            do {
                try await task.value
                Issue.record("cancelAll 后不应有 sleep 正常返回。")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("cancelAll 返回了意外错误：\(error)")
            }
        }
        #expect(scheduler.snapshot.pendingSleepCount == 0)
    }
}
