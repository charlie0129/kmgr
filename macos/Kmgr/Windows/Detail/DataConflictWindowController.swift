import AppKit
import KmgrCore

@MainActor
final class DataConflictWindowController: NSWindowController, NSWindowDelegate {
    enum Choice {
        case reload
        case copyLocal
        case retry
        case keepEditing
    }

    private let local: DataConflictValueDisplay
    private let current: DataConflictValueDisplay
    private let retryUnavailableReason: String?
    private let canCopyLocal: Bool
    private let completion: (Choice) -> Void
    private let retryButton = NSButton(title: "Retry with Current Version", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var completed = false

    init(
        session: OpenedClusterSession?,
        identity: ResourceIdentity,
        key: String,
        resourceVersion: String,
        local: DataConflictValueDisplay,
        current: DataConflictValueDisplay,
        canCopyLocal: Bool,
        retryUnavailableReason: String?,
        completion: @escaping (Choice) -> Void
    ) {
        self.local = local
        self.current = current
        self.canCopyLocal = canCopyLocal
        self.retryUnavailableReason = retryUnavailableReason
        self.completion = completion
        let clusterPresentation = session.map(ClusterIdentityPresentation.init(session:))
            ?? ClusterIdentityPresentation(clusterName: "", contextName: "")
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(clusterPresentation.titlePrefix) — Resolve Key Conflict"
        panel.minSize = NSSize(width: 620, height: 500)
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configure(
            panel: panel,
            identity: identity,
            clusterPresentation: clusterPresentation,
            key: key,
            resourceVersion: resourceVersion
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let parent = sender.sheetParent else { return true }
        finish(.keepEditing)
        parent.endSheet(sender)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        finish(.keepEditing)
    }

    private func configure(
        panel: NSPanel,
        identity: ResourceIdentity,
        clusterPresentation: ClusterIdentityPresentation,
        key: String,
        resourceVersion: String
    ) {
        let target = NSTextField(wrappingLabelWithString:
            clusterPresentation.targetDetails(identity)
        )
        target.lineBreakMode = .byTruncatingMiddle
        let heading = NSTextField(wrappingLabelWithString:
            "The server changed key \(key) after it was loaded. Your local draft is still in the editor."
        )
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let version = NSTextField(labelWithString: "Fresh server resourceVersion: \(resourceVersion)")
        version.textColor = .secondaryLabelColor
        version.lineBreakMode = .byTruncatingMiddle

        let values = NSStackView(views: [
            valueColumn(title: "Local draft", value: local),
            valueColumn(title: "Current server value", value: current),
        ])
        values.orientation = .horizontal
        values.alignment = .top
        values.distribution = .fillEqually
        values.spacing = 12

        statusLabel.textColor = .systemOrange
        statusLabel.stringValue = retryUnavailableReason ?? ""
        statusLabel.isHidden = retryUnavailableReason == nil
        statusLabel.maximumNumberOfLines = 2

        let reload = NSButton(title: "Reload", target: self, action: #selector(reload))
        reload.toolTip = "Discard the local draft and load current server data."
        let copy = NSButton(title: "Copy Local", target: self, action: #selector(copyLocal))
        copy.toolTip = canCopyLocal
            ? "Copy the local decoded value to the pasteboard and keep editing."
            : "Reveal the selected Secret value before copying it."
        copy.isEnabled = canCopyLocal
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isEnabled = retryUnavailableReason == nil
        retryButton.toolTip = retryUnavailableReason
            ?? "Submit the same local mutation using this fresh resourceVersion and current key hash."
        let keepEditing = NSButton(
            title: "Keep Editing", target: self, action: #selector(keepEditing)
        )
        keepEditing.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [reload, copy, NSView(), keepEditing, retryButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [target, heading, version, values, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            target.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            version.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            values.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            values.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        panel.contentView = root
    }

    private func valueColumn(
        title: String,
        value: DataConflictValueDisplay
    ) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let summary = NSTextField(wrappingLabelWithString: value.summaryText)
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 3

        let textView = NSTextView()
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = value.valueText != nil
        textView.string = value.valueText ?? value.placeholderText
        textView.textColor = value.valueText == nil ? .secondaryLabelColor : .labelColor
        textView.textContainerInset = NSSize(width: 7, height: 7)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [heading, summary, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        summary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func reload() { close(with: .reload) }

    @objc private func copyLocal() {
        guard canCopyLocal else { return }
        close(with: .copyLocal)
    }

    @objc private func retry() {
        guard retryUnavailableReason == nil else { return }
        close(with: .retry)
    }

    @objc private func keepEditing() { close(with: .keepEditing) }

    private func close(with choice: Choice) {
        finish(choice)
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    private func finish(_ choice: Choice) {
        guard !completed else { return }
        completed = true
        completion(choice)
    }
}
