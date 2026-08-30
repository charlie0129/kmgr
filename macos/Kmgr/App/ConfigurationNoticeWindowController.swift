import AppKit

/// A lightweight, non-modal surface for launch-time configuration notices.
/// The chooser has its own inline banner; this panel covers the automatic
/// workspace-restoration path where no chooser is shown.
@MainActor
final class ConfigurationNoticeWindowController: NSWindowController, NSWindowDelegate {
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton(title: "OK", target: nil, action: nil)
    private var didNotifyClose = false

    var onClose: (() -> Void)?

    init(notice: ClusterManagerInitialNotice) {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = notice.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        titleLabel.stringValue = notice.title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.setAccessibilityLabel("Configuration notice title")

        messageLabel.stringValue = notice.message
        messageLabel.maximumNumberOfLines = 6
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setAccessibilityLabel("Configuration notice")

        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: "Configuration notice"
        )
        imageView.contentTintColor = .systemOrange
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 24,
            weight: .medium
        )
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentHuggingPriority(.required, for: .vertical)

        closeButton.target = self
        closeButton.action = #selector(closeNotice)
        closeButton.keyEquivalent = "\r"
        closeButton.setAccessibilityLabel("Dismiss configuration notice")

        let labels = NSStackView(views: [titleLabel, messageLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5

        let body = NSStackView(views: [imageView, labels])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 12

        let footer = NSStackView(views: [NSView(), closeButton])
        footer.orientation = .horizontal

        let root = NSStackView(views: [body, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 30),
            messageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 390),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func show(relativeTo parent: NSWindow?) {
        if let parent, parent.isVisible {
            let parentFrame = parent.frame
            let size = window?.frame.size ?? .zero
            let x = parentFrame.midX - size.width / 2
            let y = parentFrame.maxY - size.height - 36
            window?.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        notifyClose()
    }

    @objc private func closeNotice() {
        window?.close()
    }

    private func notifyClose() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose?()
    }
}
