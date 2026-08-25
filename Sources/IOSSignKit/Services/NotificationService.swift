import Foundation
import UserNotifications

enum AppNotification: Equatable, Sendable {
    case refreshReminder(reason: String, isExpired: Bool)
    case refreshSucceeded(deviceName: String?)
    case refreshFailed(summary: String)
    case manualRefreshBlockedByLock(deviceName: String?)
    case automaticRefreshWaitingForUnlock(deviceName: String?)

    var presentation: AppNotificationPresentation {
        switch self {
        case .refreshReminder(let reason, let isExpired):
            return AppNotificationPresentation(
                title: "建议续签",
                body: reason,
                iconResourceName: isExpired ? "NotificationExpired" : "NotificationReminder"
            )
        case .refreshSucceeded(let deviceName):
            let target = deviceName ?? "目标 iPhone"
            return AppNotificationPresentation(
                title: "续签成功",
                body: "已将 App 安装到 \(target)。",
                iconResourceName: "NotificationSuccess"
            )
        case .refreshFailed(let summary):
            return AppNotificationPresentation(
                title: "续签失败",
                body: summary,
                iconResourceName: "NotificationFailure"
            )
        case .manualRefreshBlockedByLock(let deviceName):
            let target = deviceName ?? "目标 iPhone"
            return AppNotificationPresentation(
                title: "请解锁 iPhone",
                body: "\(target) 当前已锁定。请解锁后重新发起续签。",
                iconResourceName: "NotificationReminder"
            )
        case .automaticRefreshWaitingForUnlock(let deviceName):
            let target = deviceName ?? "目标 iPhone"
            return AppNotificationPresentation(
                title: "请保持 iPhone 解锁",
                body: "\(target) 当前尚未就绪。iOSSignKit 将自动继续检查并续签。",
                iconResourceName: "NotificationReminder"
            )
        }
    }
}

struct AppNotificationPresentation: Equatable, Sendable {
    let title: String
    let body: String
    let iconResourceName: String
}

enum NotificationDeliveryResult: Equatable, Sendable {
    case scheduled
    case denied
    case failed(String)
}

@MainActor
protocol NotificationSending: AnyObject {
    func send(_ notification: AppNotification) async -> NotificationDeliveryResult
}

@MainActor
final class NotificationService: NotificationSending {
    private let notificationCenter: UNUserNotificationCenter?
    private let appleScriptFallback: (String, String) async -> NotificationDeliveryResult
    private let allowsAppleScriptFallback: Bool

    init(
        notificationCenter: UNUserNotificationCenter? = nil,
        appleScriptFallback: @escaping (String, String) async -> NotificationDeliveryResult =
            NotificationService.sendWithAppleScript,
        allowsAppleScriptFallback: Bool? = nil
    ) {
        self.appleScriptFallback = appleScriptFallback
        self.allowsAppleScriptFallback = allowsAppleScriptFallback ?? Self.canUseAppleScriptFallback

        if let notificationCenter {
            self.notificationCenter = notificationCenter
        } else if Self.canUseUserNotifications {
            self.notificationCenter = .current()
        } else {
            self.notificationCenter = nil
        }
    }

    func send(_ notification: AppNotification) async -> NotificationDeliveryResult {
        let presentation = notification.presentation
        return await send(
            title: presentation.title,
            body: presentation.body,
            iconResourceName: presentation.iconResourceName
        )
    }

    private func send(
        title: String,
        body: String,
        iconResourceName: String
    ) async -> NotificationDeliveryResult {
        guard let notificationCenter else {
            if allowsAppleScriptFallback {
                return await appleScriptFallback(title, body)
            }
            return .failed("系统通知服务不可用。")
        }

        do {
            let settings = await notificationCenter.notificationSettings()
            try Task.checkCancellation()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = try await notificationCenter.requestAuthorization(options: [.alert])
                try Task.checkCancellation()
                guard granted else {
                    return .denied
                }
            case .denied:
                return .denied
            case .authorized, .provisional, .ephemeral:
                break
            @unknown default:
                return .failed("无法识别系统通知授权状态。")
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        if let attachment = notificationAttachment(named: iconResourceName) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "ios-sign-kit-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try Task.checkCancellation()
            try await notificationCenter.add(request)
            if Task.isCancelled {
                notificationCenter.removePendingNotificationRequests(
                    withIdentifiers: [request.identifier]
                )
                notificationCenter.removeDeliveredNotifications(
                    withIdentifiers: [request.identifier]
                )
                return .failed("系统通知请求已取消。")
            }
            return .scheduled
        } catch is CancellationError {
            return .failed("系统通知请求已取消。")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func notificationAttachment(named resourceName: String) -> UNNotificationAttachment? {
        guard let resourceURL = notificationIconURL(named: resourceName) else {
            return nil
        }

        return try? UNNotificationAttachment(
            identifier: resourceName,
            url: resourceURL,
            options: nil
        )
    }

    private func notificationIconURL(named resourceName: String) -> URL? {
        let appResourceURL = Bundle.main.resourceURL
        let candidates = [
            appResourceURL?.appendingPathComponent("\(resourceName).png"),
            appResourceURL?
                .appendingPathComponent("Icons")
                .appendingPathComponent("\(resourceName).png"),
            appResourceURL?
                .appendingPathComponent("ios-sign-kit_IOSSignKit.bundle")
                .appendingPathComponent("\(resourceName).png"),
            appResourceURL?
                .appendingPathComponent("ios-sign-kit_IOSSignKit.bundle")
                .appendingPathComponent("Icons")
                .appendingPathComponent("\(resourceName).png"),
            Bundle.module.url(forResource: resourceName, withExtension: "png"),
            Bundle.module.url(forResource: resourceName, withExtension: "png", subdirectory: "Icons")
        ]

        return candidates
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private nonisolated static var canUseAppleScriptFallback: Bool {
        let processInfo = ProcessInfo.processInfo
        let isTestProcess = Bundle.main.bundleURL.pathExtension == "xctest"
            || processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processInfo.arguments.contains(where: { argument in
                argument.contains(".xctest") || argument == "--testing-library"
            })
        return !isTestProcess
    }

    private nonisolated static func sendWithAppleScript(
        title: String,
        body: String
    ) async -> NotificationDeliveryResult {
        do {
            let result = try await CommandRunner().runAsync(
                "/usr/bin/osascript",
                arguments: [
                    "-e",
                    "display notification \(appleScriptStringLiteral(body)) with title \(appleScriptStringLiteral(title))"
                ],
                timeoutSeconds: 10
            )
            try Task.checkCancellation()
            guard result.completedSuccessfullyAndFullyTerminated else {
                let message = result.standardError
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message.isEmpty ? "系统通知命令执行失败。" : message)
            }
            return .scheduled
        } catch is CancellationError {
            return .failed("系统通知请求已取消。")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
