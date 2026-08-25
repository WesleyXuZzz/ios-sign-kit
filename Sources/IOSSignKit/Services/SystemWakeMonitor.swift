import AppKit
import Foundation

@MainActor
final class SystemWakeMonitor: NSObject {
    typealias WakeHandler = @MainActor @Sendable () -> Void

    private let notificationCenter: NotificationCenter
    private let wakeNotification: Notification.Name
    private let onWake: WakeHandler
    private var observerRegistration: SystemWakeObserverRegistration?

    init(
        notificationCenter: NotificationCenter =
            NSWorkspace.shared.notificationCenter,
        wakeNotification: Notification.Name =
            NSWorkspace.didWakeNotification,
        onWake: @escaping WakeHandler
    ) {
        self.notificationCenter = notificationCenter
        self.wakeNotification = wakeNotification
        self.onWake = onWake
        super.init()
    }

    func start() {
        guard observerRegistration == nil else {
            return
        }
        let onWake = self.onWake
        let observerToken = notificationCenter.addObserver(
            forName: wakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onWake()
            }
        }
        observerRegistration = SystemWakeObserverRegistration(
            notificationCenter: notificationCenter,
            observerToken: observerToken
        )
    }

    func stop() {
        guard let observerRegistration else {
            return
        }
        observerRegistration.cancel()
        self.observerRegistration = nil
    }
}

private final class SystemWakeObserverRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var observerToken: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter,
        observerToken: NSObjectProtocol
    ) {
        self.notificationCenter = notificationCenter
        self.observerToken = observerToken
    }

    func cancel() {
        let token = lock.withLock {
            defer { observerToken = nil }
            return observerToken
        }
        if let token {
            notificationCenter.removeObserver(token)
        }
    }

    deinit {
        cancel()
    }
}
