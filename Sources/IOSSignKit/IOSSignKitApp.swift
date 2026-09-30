import SwiftUI

@main
struct IOSSignKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings live in the AppKit main panel. This scene only satisfies
        // the SwiftUI app lifecycle and must not open a blank window at login.
        Settings {
            EmptyView()
        }
        .suppressingPlaceholderLaunch()
    }
}

private extension Scene {
    func suppressingPlaceholderLaunch() -> some Scene {
        if #available(macOS 15.0, *) {
            return defaultLaunchBehavior(.suppressed)
                .restorationBehavior(.disabled)
        }
        return self
    }
}
