import Testing
@testable import IOSSignKit

struct NotificationServiceTests {
    @Test
    func mapsNotificationEventsToPresentations() {
        #expect(
            AppNotification.refreshReminder(reason: "已到期。", isExpired: true).presentation
                == AppNotificationPresentation(
                    title: "建议续签",
                    body: "已到期。",
                    iconResourceName: "NotificationExpired"
                )
        )
        #expect(
            AppNotification.refreshSucceeded(deviceName: "测试 iPhone").presentation
                == AppNotificationPresentation(
                    title: "续签成功",
                    body: "已将 App 安装到 测试 iPhone。",
                    iconResourceName: "NotificationSuccess"
                )
        )
        #expect(
            AppNotification.refreshFailed(summary: "续签失败。面板日志可用。").presentation
                == AppNotificationPresentation(
                    title: "续签失败",
                    body: "续签失败。面板日志可用。",
                    iconResourceName: "NotificationFailure"
                )
        )
        #expect(
            AppNotification.manualRefreshBlockedByLock(
                deviceName: nil
            ).presentation
                == AppNotificationPresentation(
                    title: "请解锁 iPhone",
                    body: "目标 iPhone 当前已锁定。请解锁后重新发起续签。",
                    iconResourceName: "NotificationReminder"
                )
        )
        #expect(
            AppNotification.automaticRefreshWaitingForUnlock(
                deviceName: "测试 iPhone"
            ).presentation
                == AppNotificationPresentation(
                    title: "请保持 iPhone 解锁",
                    body: "测试 iPhone 当前尚未就绪。iOSSignKit 将自动继续检查并续签。",
                    iconResourceName: "NotificationReminder"
                )
        )
    }

    @Test
    @MainActor
    func doesNotSendAppleScriptNotificationsFromTestProcess() async {
        var deliveredNotifications: [(title: String, body: String)] = []
        let service = NotificationService(
            notificationCenter: nil,
            appleScriptFallback: { title, body in
                deliveredNotifications.append((title, body))
                return .scheduled
            }
        )

        let result = await service.send(.refreshFailed(summary: "续签流程未完成。"))

        #expect(deliveredNotifications.isEmpty)
        #expect(result == .failed("系统通知服务不可用。"))
    }

    @Test
    @MainActor
    func canExplicitlyEnableAppleScriptFallback() async {
        var deliveredNotifications: [(title: String, body: String)] = []
        let service = NotificationService(
            notificationCenter: nil,
            appleScriptFallback: { title, body in
                deliveredNotifications.append((title, body))
                return .scheduled
            },
            allowsAppleScriptFallback: true
        )

        let result = await service.send(.refreshFailed(summary: "续签流程执行失败。"))

        #expect(result == .scheduled)
        #expect(deliveredNotifications.count == 1)
        #expect(deliveredNotifications.first?.title == "续签失败")
        #expect(deliveredNotifications.first?.body == "续签流程执行失败。")
    }
}
