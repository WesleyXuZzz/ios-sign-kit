import AppKit
import SwiftUI
import Combine

@MainActor
enum MainPanelWindowGeometry {
    static let frameSize = NSSize(width: 912, height: 768)
    static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable
    ]

    static var initialContentRect: NSRect {
        NSWindow.contentRect(
            forFrameRect: NSRect(origin: .zero, size: frameSize),
            styleMask: styleMask
        )
    }
}

private struct StatusBarDisplaySnapshot: Equatable {
    var title: String
    var titleFontStyle: MenuBarTitleFontStyle
    var accessibilityLabel: String
    var ringFraction: Double
    var ringTone: StatusTone
}

@MainActor
enum StatusBarTitleFontProvider {
    static let statusPointSize: CGFloat = 12
    static let timePointSize: CGFloat = 11

    static func font(for style: MenuBarTitleFontStyle) -> NSFont {
        switch style {
        case .status:
            NSFont.monospacedDigitSystemFont(
                ofSize: statusPointSize,
                weight: .semibold
            )
        case .time:
            NSFont.monospacedSystemFont(
                ofSize: timePointSize,
                weight: .semibold
            )
        }
    }
}

enum StatusMenuCommand: Equatable {
    case openPanel
    case reload
    case refresh
    case openProject
    case quit
}

enum StatusMenuLayoutItem: Equatable {
    case header
    case separator
    case command(
        id: StatusMenuCommand,
        title: String,
        systemImageName: String,
        keyEquivalent: String
    )
}

enum StatusMenuLayout {
    static func items(
        refreshTitle: String
    ) -> [StatusMenuLayoutItem] {
        [
            .header,
            .separator,
            .command(
                id: .openPanel,
                title: "打开面板",
                systemImageName: "rectangle.on.rectangle.angled",
                keyEquivalent: ""
            ),
            .command(
                id: .reload,
                title: "重新检查",
                systemImageName: "arrow.clockwise",
                keyEquivalent: ""
            ),
            .command(
                id: .refresh,
                title: refreshTitle,
                systemImageName: "arrow.triangle.2.circlepath",
                keyEquivalent: ""
            ),
            .command(
                id: .openProject,
                title: "打开项目",
                systemImageName: "folder",
                keyEquivalent: ""
            ),
            .separator,
            .command(
                id: .quit,
                title: "退出 iOSSignKit",
                systemImageName: "power",
                keyEquivalent: "q"
            )
        ]
    }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate, NSMenuDelegate {
    private enum StatusItemLayout {
        static let iconDiameter: CGFloat = 16
    }

    private let viewModel: MenuBarViewModel
    private let statusItem: NSStatusItem
    private let contextMenu = NSMenu()
    private let statusMenuHeaderView = StatusMenuHeaderView()
    private let statusMenuHeaderItem = NSMenuItem()
    private let panelVisibility = MainPanelVisibilityState()
    private var reloadMenuItem: NSMenuItem?
    private var refreshMenuItem: NSMenuItem?
    private var panelWindow: NSWindow?
    private var visualQAInitialTab: MainPanelView.PanelTab = .status
    private var visualQASettingsScrollAnchor: UnitPoint = .top
    private var stateCancellable: AnyCancellable?
    private var isContextMenuOpen = false
    private var displayedSnapshot: StatusBarDisplaySnapshot?

    init(viewModel: MenuBarViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusItem()
        configureContextMenu()
        bindViewModel()
        updateStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAccessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        // Keep the status button's native content tree. Layer-backed text
        // subviews can invalidate status-item snapshots while being drawn.
        // The variable-length item lets AppKit include its own content insets.
    }

    private func bindViewModel() {
        stateCancellable = Self.observeStatusChanges(viewModel.objectWillChange) { [weak self] in
            self?.updateStatusItem()
        }
    }

    static func observeStatusChanges(
        _ publisher: ObservableObjectPublisher,
        update: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        var updatePending = false
        return publisher.sink { _ in
            guard !updatePending else { return }
            updatePending = true
            // objectWillChange precedes the writes. Read the final state once
            // on the next main-queue turn, even when several properties change.
            DispatchQueue.main.async {
                updatePending = false
                update()
            }
        }
    }

    private func updateStatusItem(forceRefresh: Bool = false) {
        if isContextMenuOpen {
            updateContextMenu()
        }
        guard let button = statusItem.button else { return }
        let presentation = viewModel.menuBarPresentation
        let headerPresentation = viewModel.statusMenuHeaderPresentation
        let snapshot = StatusBarDisplaySnapshot(
            title: presentation.title,
            titleFontStyle: presentation.titleFontStyle,
            accessibilityLabel: presentation.accessibilityLabel,
            ringFraction: headerPresentation.fraction,
            ringTone: headerPresentation.tone
        )
        guard forceRefresh || displayedSnapshot != snapshot else { return }
        let previous = displayedSnapshot

        if forceRefresh || previous?.ringFraction != snapshot.ringFraction
            || previous?.ringTone != snapshot.ringTone {
            button.image = RenewalRingArtwork.make(
                fraction: snapshot.ringFraction,
                tone: ringTone(for: snapshot.ringTone),
                diameter: StatusItemLayout.iconDiameter,
                lineWidth: 1.6,
                isTemplate: true
            )
        }
        if forceRefresh || previous?.title != snapshot.title
            || previous?.titleFontStyle != snapshot.titleFontStyle {
            button.attributedTitle = NSAttributedString(
                string: snapshot.title,
                attributes: [
                    .font: StatusBarTitleFontProvider.font(for: snapshot.titleFontStyle)
                ]
            )
        }
        if previous?.accessibilityLabel != snapshot.accessibilityLabel {
            button.setAccessibilityLabel(snapshot.accessibilityLabel)
        }
        if button.image?.accessibilityDescription != snapshot.accessibilityLabel {
            button.image?.accessibilityDescription = snapshot.accessibilityLabel
        }
        displayedSnapshot = snapshot
    }

    @objc
    private func handleAccessibilityDisplayOptionsDidChange(_ notification: Notification) {
        updateStatusItem(forceRefresh: true)
    }

    @objc
    private func handleStatusItemClick(_ sender: AnyObject?) {
        Self.performStatusItemClick(
            isRightClick: NSApp.currentEvent?.type == .rightMouseUp,
            showContextMenu: { showContextMenu() },
            showMainPanel: { showMainPanel() }
        )
    }

    static func performStatusItemClick(
        isRightClick: Bool,
        showContextMenu: () -> Void,
        showMainPanel: () -> Void
    ) {
        if isRightClick {
            showContextMenu()
        } else {
            showMainPanel()
        }
    }

    private func ensureMainPanelWindow() {
        guard panelWindow == nil else { return }

        let window = NSWindow(
            contentRect: MainPanelWindowGeometry.initialContentRect,
            styleMask: MainPanelWindowGeometry.styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "iOS 个人签名续期工具"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = window.contentRect(
            forFrameRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: MainPanelView.Layout.minimumWindowWidth,
                    height: 680
                )
            )
        ).size
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: MainPanelView(
                viewModel: viewModel,
                panelVisibility: panelVisibility,
                initialTab: visualQAInitialTab,
                settingsInitialScrollAnchor:
                    visualQASettingsScrollAnchor
            )
        )
        panelWindow = window
    }

    private func showContextMenu() {
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        isContextMenuOpen = true
        updateContextMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        isContextMenuOpen = false
    }

    private func configureContextMenu() {
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self

        for item in StatusMenuLayout.items(
            refreshTitle: viewModel.manualRefreshActionTitle
        ) {
            switch item {
            case .header:
                statusMenuHeaderItem.view = statusMenuHeaderView
                statusMenuHeaderItem.isEnabled = false
                contextMenu.addItem(statusMenuHeaderItem)

            case .separator:
                contextMenu.addItem(.separator())

            case let .command(
                id,
                title,
                systemImageName,
                keyEquivalent
            ):
                let menuItem = actionMenuItem(
                    title: title,
                    systemImageName: systemImageName,
                    action: action(for: id),
                    keyEquivalent: keyEquivalent
                )
                if id == .reload {
                    reloadMenuItem = menuItem
                } else if id == .refresh {
                    refreshMenuItem = menuItem
                }
                contextMenu.addItem(menuItem)
            }
        }
    }

    private func updateContextMenu() {
        let presentation = viewModel.statusMenuHeaderPresentation
        statusMenuHeaderView.update(
            presentation: presentation,
            image: nil
        )
        let phase = viewModel.primaryJourneyPresentation.phase
        let canReload = phase != .checking && phase != .deploying
        if reloadMenuItem?.isEnabled != canReload {
            reloadMenuItem?.isEnabled = canReload
        }
        let refreshTitle = viewModel.manualRefreshActionTitle
        if refreshMenuItem?.title != refreshTitle {
            refreshMenuItem?.title = refreshTitle
        }
        let canRefresh = viewModel.canRefreshNow
        if refreshMenuItem?.isEnabled != canRefresh {
            refreshMenuItem?.isEnabled = canRefresh
        }
    }

    private func ringTone(
        for tone: StatusTone
    ) -> RenewalRingView.Tone {
        switch tone {
        case .good:
            .success
        case .info:
            .normal
        case .warning:
            .warning
        case .critical:
            .critical
        case .neutral:
            .offline
        }
    }

    private func actionMenuItem(
        title: String,
        systemImageName: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = self
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular
        )
        let image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        item.image = image
        return item
    }

    private func action(for command: StatusMenuCommand) -> Selector {
        switch command {
        case .openPanel:
            #selector(handleOpenPanel)
        case .reload:
            #selector(handleReload)
        case .refresh:
            #selector(handleRefresh)
        case .openProject:
            #selector(handleOpenProject)
        case .quit:
            #selector(handleQuit)
        }
    }

    @objc
    private func handleOpenPanel() {
        showMainPanel()
    }

    func showMainPanel() {
        ensureMainPanelWindow()
        guard let panelWindow else { return }

        NSApp.setActivationPolicy(.regular)
        if panelWindow.isMiniaturized {
            panelWindow.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        panelWindow.makeKeyAndOrderFront(nil)
        panelWindow.orderFrontRegardless()
        panelVisibility.setVisible(true)
    }

    func preloadMainPanelWindow() {
        ensureMainPanelWindow()
        panelVisibility.setVisible(false)
    }

#if DEBUG
    func configureVisualQA(
        initialTab: MainPanelView.PanelTab,
        settingsScrollAnchor: UnitPoint
    ) {
        guard panelWindow == nil else { return }
        visualQAInitialTab = initialTab
        visualQASettingsScrollAnchor = settingsScrollAnchor
    }

    func setVisualQAFrameSize(_ size: NSSize) {
        ensureMainPanelWindow()
        guard let panelWindow else { return }
        panelWindow.setFrame(
            NSRect(origin: panelWindow.frame.origin, size: size),
            display: true
        )
        panelWindow.center()
    }
#endif

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == panelWindow else { return }
        panelVisibility.setVisible(false)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == panelWindow else { return }
        panelVisibility.setVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == panelWindow else { return }
        panelVisibility.setVisible(window.isVisible)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == panelWindow else { return }
        panelVisibility.setVisible(
            window.occlusionState.contains(.visible)
                && !window.isMiniaturized
        )
    }

    @objc
    private func handleReload() {
        viewModel.reloadEnvironment()
    }

    @objc
    private func handleRefresh() {
        Self.performManualRefresh(
            requestRefresh: { viewModel.refreshNow() },
            showMainPanel: { showMainPanel() }
        )
    }

    static func performManualRefresh(
        requestRefresh: () -> ManualRefreshRequestOutcome,
        showMainPanel: () -> Void
    ) {
        if requestRefresh() == .profileChoiceRequired {
            showMainPanel()
        }
    }

    @objc
    private func handleOpenProject() {
        viewModel.openProjectFolder()
    }

    @objc
    private func handleQuit() {
        viewModel.quitApp()
    }
}
