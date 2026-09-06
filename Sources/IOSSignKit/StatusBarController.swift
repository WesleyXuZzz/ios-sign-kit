import AppKit
import SwiftUI
import Combine
import QuartzCore

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

struct StatusBarTransitionSnapshot: Equatable {
    var title: String
    var iconTransitionIdentity: MenuBarIconTransitionIdentity
    var titleGroup: MenuBarTitleTransitionGroup
    var titleWidthTier: MenuBarTitleWidthTier = .standard
    var titleFontStyle: MenuBarTitleFontStyle = .status
    var accessibilityLabel: String = ""
    var ringFraction: Double = 0.25
    var ringTone: StatusTone = .neutral
}

enum StatusBarTitleTransition: Equatable {
    case immediate
    case crossfade(duration: TimeInterval)
    case semanticPush(duration: TimeInterval, verticalOffset: CGFloat)
}

enum StatusBarIconTransition: Equatable {
    case immediate
    case crossfade(duration: TimeInterval)
}

struct StatusBarTransitionDecision: Equatable {
    var title: StatusBarTitleTransition
    var icon: StatusBarIconTransition
}

enum StatusBarWidthTransition: Equatable {
    case unchanged
    case applyImmediately(MenuBarTitleWidthTier)
    case shrinkAfterTransition(
        tier: MenuBarTitleWidthTier,
        delay: TimeInterval,
        generation: Int
    )
}

enum StatusBarTransitionPolicy {
    static let semanticTitleDuration: TimeInterval = 0.18
    static let expiryTitleDuration: TimeInterval = 0.12
    static let iconDuration: TimeInterval = 0.14
    static let semanticTitleOffset: CGFloat = 3

    static func decision(
        previous: StatusBarTransitionSnapshot?,
        next: StatusBarTransitionSnapshot,
        reduceMotion: Bool
    ) -> StatusBarTransitionDecision {
        guard let previous, !reduceMotion else {
            return StatusBarTransitionDecision(title: .immediate, icon: .immediate)
        }

        let titleTransition: StatusBarTitleTransition
        if previous.title == next.title {
            titleTransition = .immediate
        } else if previous.titleGroup == .expiry, next.titleGroup == .expiry {
            titleTransition = .crossfade(duration: expiryTitleDuration)
        } else {
            titleTransition = .semanticPush(
                duration: semanticTitleDuration,
                verticalOffset: semanticTitleOffset
            )
        }

        let iconTransition: StatusBarIconTransition =
            previous.iconTransitionIdentity == next.iconTransitionIdentity
                && previous.ringFraction == next.ringFraction
                && previous.ringTone == next.ringTone
                ? .immediate
                : .crossfade(duration: iconDuration)

        return StatusBarTransitionDecision(title: titleTransition, icon: iconTransition)
    }

    static func shouldApply(
        previous: StatusBarTransitionSnapshot?,
        next: StatusBarTransitionSnapshot,
        forceImmediate: Bool
    ) -> Bool {
        forceImmediate || previous != next
    }

    static func duration(of transition: StatusBarTitleTransition) -> TimeInterval {
        switch transition {
        case .immediate:
            0
        case let .crossfade(duration), let .semanticPush(duration, _):
            duration
        }
    }
}

struct StatusBarTransitionState {
    private(set) var snapshot: StatusBarTransitionSnapshot?
    private(set) var generation = 0

    mutating func transition(
        to next: StatusBarTransitionSnapshot,
        reduceMotion: Bool
    ) -> StatusBarTransitionDecision {
        let decision = StatusBarTransitionPolicy.decision(
            previous: snapshot,
            next: next,
            reduceMotion: reduceMotion
        )
        snapshot = next
        generation += 1
        return decision
    }
}

struct StatusBarWidthTransitionState {
    private(set) var appliedTier: MenuBarTitleWidthTier?
    private(set) var targetTier: MenuBarTitleWidthTier?
    private(set) var generation = 0

    init(appliedTier: MenuBarTitleWidthTier? = nil) {
        self.appliedTier = appliedTier
        self.targetTier = appliedTier
    }

    mutating func transition(
        to nextTier: MenuBarTitleWidthTier,
        titleTransition: StatusBarTitleTransition,
        reduceMotion: Bool
    ) -> StatusBarWidthTransition {
        generation += 1
        targetTier = nextTier

        guard let appliedTier else {
            self.appliedTier = nextTier
            return .applyImmediately(nextTier)
        }

        guard appliedTier != nextTier else {
            return .unchanged
        }

        let isExpansion =
            StatusBarWidthMetrics.statusItemLength(for: nextTier)
                > StatusBarWidthMetrics.statusItemLength(for: appliedTier)
        if reduceMotion || isExpansion {
            self.appliedTier = nextTier
            return .applyImmediately(nextTier)
        }

        let delay = StatusBarTransitionPolicy.duration(of: titleTransition)
        guard delay > 0 else {
            self.appliedTier = nextTier
            return .applyImmediately(nextTier)
        }

        return .shrinkAfterTransition(
            tier: nextTier,
            delay: delay,
            generation: generation
        )
    }

    mutating func completeDelayedShrink(
        to tier: MenuBarTitleWidthTier,
        generation: Int
    ) -> Bool {
        guard self.generation == generation, targetTier == tier else {
            return false
        }
        appliedTier = tier
        return true
    }
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

enum StatusBarWidthMetrics {
    static let iconWidth: CGFloat = 16
    static let iconTitleSpacing: CGFloat = 8
    static let horizontalInset: CGFloat = 1
    static let compactTitleWidth: CGFloat = 24
    static let standardTitleWidth: CGFloat = 41

    static func titleWidth(for tier: MenuBarTitleWidthTier) -> CGFloat {
        switch tier {
        case .compact:
            compactTitleWidth
        case .standard:
            standardTitleWidth
        }
    }

    static func statusItemLength(for tier: MenuBarTitleWidthTier) -> CGFloat {
        horizontalInset
            + iconWidth
            + iconTitleSpacing
            + titleWidth(for: tier)
            + horizontalInset
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
private final class StatusTitleTransitionView: NSView {
    private let outgoingField = NSTextField(labelWithString: "")
    private let incomingField = NSTextField(labelWithString: "")
    private var targetTitle = ""
    private var targetFont: NSFont

    init(font: NSFont) {
        targetFont = font
        super.init(frame: .zero)
        wantsLayer = true
        configure(field: outgoingField, font: font)
        configure(field: incomingField, font: font)
        addSubview(outgoingField)
        addSubview(incomingField)

        NSLayoutConstraint.activate([
            outgoingField.leadingAnchor.constraint(equalTo: leadingAnchor),
            outgoingField.trailingAnchor.constraint(equalTo: trailingAnchor),
            outgoingField.centerYAnchor.constraint(equalTo: centerYAnchor),
            incomingField.leadingAnchor.constraint(equalTo: leadingAnchor),
            incomingField.trailingAnchor.constraint(equalTo: trailingAnchor),
            incomingField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        showImmediately("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(
        title: String,
        font: NSFont,
        transition: StatusBarTitleTransition
    ) {
        cancelAnimations()

        guard !targetTitle.isEmpty, transition != .immediate else {
            targetTitle = title
            targetFont = font
            showImmediately(title, font: font)
            return
        }

        outgoingField.stringValue = targetTitle
        outgoingField.font = targetFont
        incomingField.stringValue = title
        incomingField.font = font
        prepareForAnimation()
        targetTitle = title
        targetFont = font

        switch transition {
        case .immediate:
            showImmediately(title, font: font)
        case let .crossfade(duration):
            animateCrossfade(duration: duration)
        case let .semanticPush(duration, verticalOffset):
            animateSemanticPush(duration: duration, verticalOffset: verticalOffset)
        }
    }

    func finishImmediately() {
        cancelAnimations()
        showImmediately(targetTitle, font: targetFont)
    }

    private func configure(field: NSTextField, font: NSFont) {
        field.font = font
        field.textColor = .labelColor
        field.alignment = .left
        field.lineBreakMode = .byClipping
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.wantsLayer = true
    }

    private func prepareForAnimation() {
        outgoingField.layer?.opacity = 1
        outgoingField.layer?.transform = CATransform3DIdentity
        incomingField.layer?.opacity = 0
        incomingField.layer?.transform = CATransform3DIdentity
    }

    private func showImmediately(_ title: String, font: NSFont? = nil) {
        let font = font ?? targetFont
        outgoingField.stringValue = title
        outgoingField.font = font
        incomingField.stringValue = title
        incomingField.font = font
        outgoingField.layer?.opacity = 1
        outgoingField.layer?.transform = CATransform3DIdentity
        incomingField.layer?.opacity = 0
        incomingField.layer?.transform = CATransform3DIdentity
    }

    private func cancelAnimations() {
        outgoingField.layer?.removeAllAnimations()
        incomingField.layer?.removeAllAnimations()
    }

    private func animateCrossfade(duration: TimeInterval) {
        addOpacityAnimation(
            to: outgoingField.layer,
            from: 1,
            to: 0,
            duration: duration
        )
        addOpacityAnimation(
            to: incomingField.layer,
            from: 0,
            to: 1,
            duration: duration
        )
    }

    private func animateSemanticPush(duration: TimeInterval, verticalOffset: CGFloat) {
        addAnimationGroup(
            to: outgoingField.layer,
            opacityFrom: 1,
            opacityTo: 0,
            translationFrom: 0,
            translationTo: verticalOffset,
            duration: duration
        )
        addAnimationGroup(
            to: incomingField.layer,
            opacityFrom: 0,
            opacityTo: 1,
            translationFrom: -verticalOffset,
            translationTo: 0,
            duration: duration
        )
    }

    private func addOpacityAnimation(
        to layer: CALayer?,
        from: Float,
        to: Float,
        duration: TimeInterval
    ) {
        guard let layer else { return }
        layer.opacity = to
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "status-opacity")
    }

    private func addAnimationGroup(
        to layer: CALayer?,
        opacityFrom: Float,
        opacityTo: Float,
        translationFrom: CGFloat,
        translationTo: CGFloat,
        duration: TimeInterval
    ) {
        guard let layer else { return }
        layer.opacity = opacityTo
        layer.transform = CATransform3DMakeTranslation(0, translationTo, 0)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = opacityFrom
        opacity.toValue = opacityTo

        let translation = CABasicAnimation(keyPath: "transform.translation.y")
        translation.fromValue = translationFrom
        translation.toValue = translationTo

        let group = CAAnimationGroup()
        group.animations = [opacity, translation]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(group, forKey: "status-title-transition")
    }
}

@MainActor
private final class StatusIconTransitionView: NSView {
    private let outgoingImageView = NSImageView()
    private let incomingImageView = NSImageView()
    private var targetImage: NSImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configure(imageView: outgoingImageView)
        configure(imageView: incomingImageView)
        addSubview(outgoingImageView)
        addSubview(incomingImageView)

        NSLayoutConstraint.activate([
            outgoingImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            outgoingImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outgoingImageView.topAnchor.constraint(equalTo: topAnchor),
            outgoingImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            incomingImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            incomingImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            incomingImageView.topAnchor.constraint(equalTo: topAnchor),
            incomingImageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(image: NSImage?, transition: StatusBarIconTransition) {
        cancelAnimations()

        guard targetImage != nil, transition != .immediate else {
            targetImage = image
            showImmediately(image)
            return
        }

        outgoingImageView.image = targetImage
        incomingImageView.image = image
        outgoingImageView.layer?.opacity = 1
        incomingImageView.layer?.opacity = 0
        targetImage = image

        switch transition {
        case .immediate:
            showImmediately(image)
        case let .crossfade(duration):
            addOpacityAnimation(
                to: outgoingImageView.layer,
                from: 1,
                to: 0,
                duration: duration
            )
            addOpacityAnimation(
                to: incomingImageView.layer,
                from: 0,
                to: 1,
                duration: duration
            )
        }
    }

    func finishImmediately() {
        cancelAnimations()
        showImmediately(targetImage)
    }

    private func configure(imageView: NSImageView) {
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
    }

    private func showImmediately(_ image: NSImage?) {
        outgoingImageView.image = image
        incomingImageView.image = image
        outgoingImageView.layer?.opacity = 1
        incomingImageView.layer?.opacity = 0
    }

    private func cancelAnimations() {
        outgoingImageView.layer?.removeAllAnimations()
        incomingImageView.layer?.removeAllAnimations()
    }

    private func addOpacityAnimation(
        to layer: CALayer?,
        from: Float,
        to: Float,
        duration: TimeInterval
    ) {
        guard let layer else { return }
        layer.opacity = to
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "status-icon-opacity")
    }
}

@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    private enum StatusItemLayout {
        static let height: CGFloat = 16
    }

    private let viewModel: MenuBarViewModel
    private let statusItem: NSStatusItem
    private let statusStackView = NSStackView()
    private let statusIconView = StatusIconTransitionView()
    private let statusTitleView = StatusTitleTransitionView(
        font: StatusBarTitleFontProvider.font(for: .status)
    )
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
    private var transitionState = StatusBarTransitionState()
    private var widthTransitionState = StatusBarWidthTransitionState(
        appliedTier: .standard
    )
    private var titleWidthConstraint: NSLayoutConstraint?
    private var pendingTitleWidthShrinkTask: Task<Void, Never>?

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
        pendingTitleWidthShrinkTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = nil
        button.title = ""
        button.attributedTitle = NSAttributedString()

        statusStackView.orientation = .horizontal
        statusStackView.alignment = .centerY
        statusStackView.spacing = StatusBarWidthMetrics.iconTitleSpacing
        statusStackView.translatesAutoresizingMaskIntoConstraints = false

        statusIconView.translatesAutoresizingMaskIntoConstraints = false

        statusTitleView.translatesAutoresizingMaskIntoConstraints = false

        statusStackView.addArrangedSubview(statusIconView)
        statusStackView.addArrangedSubview(statusTitleView)
        button.addSubview(statusStackView)

        let titleWidthConstraint = statusTitleView.widthAnchor.constraint(
            equalToConstant: StatusBarWidthMetrics.titleWidth(for: .standard)
        )
        self.titleWidthConstraint = titleWidthConstraint
        statusItem.length = StatusBarWidthMetrics.statusItemLength(for: .standard)

        NSLayoutConstraint.activate([
            statusIconView.widthAnchor.constraint(equalToConstant: StatusBarWidthMetrics.iconWidth),
            statusIconView.heightAnchor.constraint(equalToConstant: StatusItemLayout.height),
            titleWidthConstraint,
            statusTitleView.heightAnchor.constraint(equalToConstant: StatusItemLayout.height),
            statusStackView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            statusStackView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            statusStackView.leadingAnchor.constraint(
                greaterThanOrEqualTo: button.leadingAnchor,
                constant: StatusBarWidthMetrics.horizontalInset
            ),
            statusStackView.trailingAnchor.constraint(
                lessThanOrEqualTo: button.trailingAnchor,
                constant: -StatusBarWidthMetrics.horizontalInset
            )
        ])
    }

    private func bindViewModel() {
        stateCancellable = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
    }

    private func updateStatusItem(forceImmediate: Bool = false) {
        let presentation = viewModel.menuBarPresentation
        let headerPresentation = viewModel.statusMenuHeaderPresentation
        updateContextMenu()
        statusItem.button?.setAccessibilityLabel(presentation.accessibilityLabel)
        let snapshot = StatusBarTransitionSnapshot(
            title: presentation.title,
            iconTransitionIdentity: presentation.iconTransitionIdentity,
            titleGroup: presentation.titleTransitionGroup,
            titleWidthTier: presentation.titleWidthTier,
            titleFontStyle: presentation.titleFontStyle,
            accessibilityLabel: presentation.accessibilityLabel,
            ringFraction: headerPresentation.fraction,
            ringTone: headerPresentation.tone
        )
        guard StatusBarTransitionPolicy.shouldApply(
            previous: transitionState.snapshot,
            next: snapshot,
            forceImmediate: forceImmediate
        ) else {
            return
        }
        let reduceMotion = forceImmediate
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = transitionState.transition(
            to: snapshot,
            reduceMotion: reduceMotion
        )
        pendingTitleWidthShrinkTask?.cancel()
        pendingTitleWidthShrinkTask = nil
        let widthTransition = widthTransitionState.transition(
            to: presentation.titleWidthTier,
            titleTransition: transition.title,
            reduceMotion: reduceMotion
        )
        applyWidthTransition(widthTransition)

        let image = RenewalRingArtwork.make(
            fraction: headerPresentation.fraction,
            tone: ringTone(for: headerPresentation.tone),
            diameter: StatusBarWidthMetrics.iconWidth,
            lineWidth: 1.6,
            isTemplate: true
        )
        image.accessibilityDescription = presentation.accessibilityLabel
        statusIconView.display(image: image, transition: transition.icon)
        statusTitleView.display(
            title: presentation.title,
            font: StatusBarTitleFontProvider.font(for: presentation.titleFontStyle),
            transition: transition.title
        )
    }

    private func applyWidthTransition(_ transition: StatusBarWidthTransition) {
        switch transition {
        case .unchanged:
            break
        case let .applyImmediately(tier):
            applyWidthTier(tier)
        case let .shrinkAfterTransition(tier, delay, generation):
            pendingTitleWidthShrinkTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self,
                      self.widthTransitionState.completeDelayedShrink(
                        to: tier,
                        generation: generation
                      ) else {
                    return
                }
                self.applyWidthTier(tier)
                self.pendingTitleWidthShrinkTask = nil
            }
        }
    }

    private func applyWidthTier(_ tier: MenuBarTitleWidthTier) {
        statusTitleView.isHidden = false
        statusStackView.spacing = StatusBarWidthMetrics.iconTitleSpacing
        titleWidthConstraint?.constant = StatusBarWidthMetrics.titleWidth(for: tier)
        statusItem.length = StatusBarWidthMetrics.statusItemLength(for: tier)
        statusItem.button?.layoutSubtreeIfNeeded()
    }

    @objc
    private func handleAccessibilityDisplayOptionsDidChange(_ notification: Notification) {
        statusTitleView.finishImmediately()
        statusIconView.finishImmediately()
        updateStatusItem(forceImmediate: true)
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
        updateContextMenu()
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func configureContextMenu() {
        contextMenu.autoenablesItems = false

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
        reloadMenuItem?.isEnabled = phase != .checking
            && phase != .deploying
        refreshMenuItem?.title = viewModel.manualRefreshActionTitle
        refreshMenuItem?.isEnabled = viewModel.canRefreshNow
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
