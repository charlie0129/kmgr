import AppKit

/// Transient review for one ConfigMap or Secret value mutation.
/// Rendered decoded Secret text is cleared as soon as the review ends.
@MainActor
final class DataValueDiffConfirmationWindowController: NSWindowController,
    NSWindowDelegate
{
    enum Choice: Sendable {
        case save
        case keepEditing
    }

    private let key: String
    private let metadataText: String
    private let diffLabel: String
    private let secret: Bool
    private let diffDocument: DiffTextDocument
    private let reviewSession = DiffReviewSheetSession<Choice>(
        cancellationChoice: .keepEditing
    )

    init(
        targetDetails: String,
        presentation: DataValueDiffPresentation
    ) {
        key = presentation.key
        metadataText = presentation.metadataText
        diffLabel = presentation.diffLabel
        secret = presentation.secret
        diffDocument = DiffTextDocument(
            lines: presentation.lines,
            identifierPrefix: "data-value-diff",
            accessibilityLabel: "Decoded Data value comparison"
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review Value Change"
        panel.minSize = NSSize(width: 640, height: 420)
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configure(
            panel: panel,
            targetDetails: targetDetails,
            presentation: presentation
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func runSheet(for parent: NSWindow) async -> Choice {
        guard let window else { return .keepEditing }
        let choice = await reviewSession.run(window: window, asSheetFor: parent)
        discardTransientPresentation()
        return choice
    }

    func cancelReview() {
        if reviewSession.isActive {
            reviewSession.cancel()
        } else {
            window?.close()
        }
        discardTransientPresentation()
    }

    func discardTransientPresentation() {
        diffDocument.clear()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard reviewSession.isActive else {
            discardTransientPresentation()
            return true
        }
        reviewSession.cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        reviewSession.cancel()
        discardTransientPresentation()
    }

    private func configure(
        panel: NSPanel,
        targetDetails: String,
        presentation: DataValueDiffPresentation
    ) {
        let heading = NSTextField(labelWithString: "Save changes to this value?")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.identifier = .init("data-value-diff-heading")

        let target = NSTextField(wrappingLabelWithString: targetDetails)
        target.identifier = .init("data-value-diff-target")
        target.lineBreakMode = .byTruncatingMiddle
        target.maximumNumberOfLines = 2
        target.textColor = .secondaryLabelColor
        target.toolTip = targetDetails

        let keyLabel = NSTextField(labelWithString: "Key: \(key)")
        keyLabel.identifier = .init("data-value-diff-key")
        keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.lineBreakMode = .byTruncatingMiddle
        keyLabel.toolTip = key
        keyLabel.setAccessibilityLabel("Data key")
        keyLabel.setAccessibilityValue(key)

        let metadata = NSTextField(labelWithString: metadataText)
        metadata.identifier = .init("data-value-diff-metadata")
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.toolTip = metadataText

        let secretNotice = NSTextField(wrappingLabelWithString:
            "Decoded Secret value — this is the usable content, not Kubernetes base64 text."
        )
        secretNotice.identifier = .init("data-value-diff-secret-notice")
        secretNotice.textColor = .systemOrange
        secretNotice.maximumNumberOfLines = 2
        secretNotice.isHidden = !secret

        let documentLabel = NSTextField(labelWithString: diffLabel)
        documentLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let truncation = NSTextField(wrappingLabelWithString:
            "The value comparison is bounded for display. Saving still uses the complete edited value."
        )
        truncation.identifier = .init("data-value-diff-truncation")
        truncation.textColor = .systemOrange
        truncation.maximumNumberOfLines = 2
        truncation.isHidden = !presentation.previewTruncated

        let copyAll = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copyAll.identifier = .init("data-value-diff-copy-all")
        copyAll.toolTip = secret
            ? "Copy the complete visible comparison, including the decoded Secret value."
            : "Copy the complete visible value comparison."
        let search = NSButton(title: "Search", target: self, action: #selector(search))
        search.identifier = .init("data-value-diff-search")
        search.toolTip = "Open the native find bar for the value comparison."
        let keepEditing = NSButton(
            title: "Keep Editing", target: self, action: #selector(keepEditing)
        )
        keepEditing.identifier = .init("data-value-diff-keep-editing")
        keepEditing.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save Key", target: self, action: #selector(save))
        save.identifier = .init("data-value-diff-save")
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [copyAll, search, NSView(), keepEditing, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [
            heading, target, keyLabel, metadata, secretNotice, documentLabel,
            diffDocument.scrollView, truncation, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            target.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            keyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            metadata.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            secretNotice.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            documentLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            diffDocument.scrollView.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -36
            ),
            diffDocument.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            truncation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        panel.contentView = root
        panel.initialFirstResponder = diffDocument.initialFirstResponder
    }

    @objc private func copyAll() {
        var copyText = "Key: \(key)\n\(metadataText)"
        if secret {
            copyText += "\nDecoded Secret value — not Kubernetes base64 text."
        }
        copyText += "\n\n\(diffLabel)\n\(diffDocument.text)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText, forType: .string)
    }

    @objc private func search() {
        diffDocument.showFindPanel(in: window)
    }

    @objc private func save() {
        finishReview(with: .save, response: .OK)
    }

    @objc private func keepEditing() {
        finishReview(with: .keepEditing, response: .cancel)
    }

    private func finishReview(
        with choice: Choice,
        response: NSApplication.ModalResponse
    ) {
        if reviewSession.isActive {
            reviewSession.finish(with: choice, response: response)
        } else {
            window?.close()
        }
    }
}
