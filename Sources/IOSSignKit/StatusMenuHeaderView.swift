import AppKit

@MainActor
final class StatusMenuHeaderView: NSView {
    private enum Layout {
        static let size = NSSize(width: 300, height: 54)
        static let horizontalInset: CGFloat = 14
        static let iconSize: CGFloat = 40
        static let iconTextSpacing: CGFloat = 10
        static let textSpacing: CGFloat = 1
    }

    private let iconView = NSImageView()
    private let headlineLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()

    override var intrinsicContentSize: NSSize {
        Layout.size
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Layout.size))
        configureView()
        configureIcon()
        configureLabels()
        configureLayout()
        configureAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        presentation: StatusMenuHeaderPresentation,
        image: NSImage?
    ) {
        headlineLabel.stringValue = presentation.headline
        detailLabel.stringValue = presentation.detail
        let ringImage = RenewalRingArtwork.make(
            fraction: presentation.fraction,
            tone: ringTone(for: presentation.tone),
            diameter: Layout.iconSize,
            lineWidth: 4,
            isTemplate: false,
            centerText: presentation.centerText
        )
        iconView.image = ringImage
        iconView.contentTintColor = nil
        setAccessibilityLabel(presentation.accessibilityLabel)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func configureView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = false
    }

    private func configureIcon() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageAlignment = .alignCenter
        iconView.imageFrameStyle = .none
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.setAccessibilityElement(false)
    }

    private func configureLabels() {
        configureLabel(
            headlineLabel,
            font: .systemFont(ofSize: 13, weight: .semibold),
            textColor: .labelColor
        )
        configureLabel(
            detailLabel,
            font: .systemFont(ofSize: 11, weight: .regular),
            textColor: .secondaryLabelColor
        )
    }

    private func configureLabel(
        _ label: NSTextField,
        font: NSFont,
        textColor: NSColor
    ) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = font
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)
    }

    private func configureLayout() {
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.distribution = .fill
        textStack.spacing = Layout.textSpacing
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(headlineLabel)
        textStack.addArrangedSubview(detailLabel)

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Layout.size.width),
            heightAnchor.constraint(equalToConstant: Layout.size.height),
            iconView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Layout.horizontalInset
            ),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
            textStack.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: Layout.iconTextSpacing
            ),
            textStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Layout.horizontalInset
            ),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            headlineLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: textStack.trailingAnchor
            ),
            detailLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: textStack.trailingAnchor
            )
        ])
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
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
}
