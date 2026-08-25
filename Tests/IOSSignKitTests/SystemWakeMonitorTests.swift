import Foundation
import Testing
@testable import IOSSignKit

@MainActor
struct SystemWakeMonitorTests {
    @Test
    func forwardsWakeNotificationsOnlyWhileStarted() async throws {
        let notificationCenter = NotificationCenter()
        let wakeNotification = Notification.Name(
            "SystemWakeMonitorTests.wake"
        )
        var wakeCount = 0
        let monitor = SystemWakeMonitor(
            notificationCenter: notificationCenter,
            wakeNotification: wakeNotification
        ) {
            wakeCount += 1
        }

        notificationCenter.post(name: wakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(wakeCount == 0)

        monitor.start()
        notificationCenter.post(name: wakeNotification, object: nil)
        try await waitForSystemWakeMonitor {
            wakeCount == 1
        }
        #expect(wakeCount == 1)

        monitor.stop()
        notificationCenter.post(name: wakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(wakeCount == 1)
    }

    @Test
    func backgroundPostedWakeIsForwardedOnMainActorOnlyWhileStarted()
        async throws
    {
        let notificationCenter = NotificationCenter()
        let wakeNotification = Notification.Name(
            "SystemWakeMonitorTests.backgroundWake"
        )
        let poster = SystemWakeNotificationPoster(
            notificationCenter: notificationCenter,
            notification: wakeNotification
        )
        var wakeCount = 0
        var handlerWasOnMainThread = false
        let monitor = SystemWakeMonitor(
            notificationCenter: notificationCenter,
            wakeNotification: wakeNotification
        ) {
            wakeCount += 1
            handlerWasOnMainThread = Thread.isMainThread
        }

        monitor.start()
        await Task.detached {
            poster.post()
        }.value
        try await waitForSystemWakeMonitor {
            wakeCount == 1
        }

        #expect(handlerWasOnMainThread)

        monitor.stop()
        await Task.detached {
            poster.post()
        }.value
        try await Task.sleep(for: .milliseconds(50))

        #expect(wakeCount == 1)
    }
}

private final class SystemWakeNotificationPoster: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let notification: Notification.Name

    init(
        notificationCenter: NotificationCenter,
        notification: Notification.Name
    ) {
        self.notificationCenter = notificationCenter
        self.notification = notification
    }

    func post() {
        notificationCenter.post(name: notification, object: nil)
    }
}
