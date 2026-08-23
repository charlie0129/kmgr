import AppKit
import KmgrCore

/// Bounded, lazy master-detail review for one staged key/value transaction.
/// Only the selected value diff is rendered; sensitive inputs and rendered
/// text are cleared when the review ends.
@MainActor
final class KeyValueDiffConfirmationWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    enum Choice: Sendable {
        case save
        case keepEditing
    }

    private let editorTitle: String
    private let targetDetails: String
    private var inputs: [KeyValueDiffInput]
    private let changesTable = NSTableView()
    private let keyLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let diffLabel = NSTextField(labelWithString: "Value Diff")
    private let sensitiveNotice = NSTextField(wrappingLabelWithString:
        "Decoded Secret value — this is the usable content, not Kubernetes base64 text."
    )
    private let truncationNotice = NSTextField(wrappingLabelWithString:
        "This comparison is bounded for display. Saving still uses the complete edited value."
    )
    private let diffDocument = DiffTextDocument(
        lines: [DiffTextLine(text: "Preparing selected value comparison…", role: .notice)],
        identifierPrefix: "key-value-diff",
        accessibilityLabel: "Selected key value comparison"
    )
    private let reviewSession = DiffReviewSheetSession<Choice>(
        cancellationChoice: .keepEditing
    )
    private var tableLayoutBinding: TableLayoutBinding?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0
    private var selectedPresentation: KeyValueDiffPresentation?

    init(
        editorTitle: String,
        targetDetails: String,
        inputs: [KeyValueDiffInput],
        tableLayoutStore: TableLayoutStore? = nil
    ) {
        precondition(!inputs.isEmpty, "A key/value review requires at least one change")
        self.editorTitle = editorTitle
        self.targetDetails = targetDetails
        self.inputs = inputs

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_020, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review \(editorTitle) Changes"
        panel.minSize = NSSize(width: 760, height: 480)
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configure(
            panel: panel,
            tableLayoutStore: tableLayoutStore ?? TableLayoutStore()
        )
        changesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        renderSelectedChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        renderTask?.cancel()
    }

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
        renderGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        selectedPresentation = nil
        diffDocument.clear()
        for index in inputs.indices { inputs[index].wipe() }
        inputs.removeAll(keepingCapacity: false)
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

    func numberOfRows(in tableView: NSTableView) -> Int { inputs.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard inputs.indices.contains(row), let tableColumn else { return nil }
        let input = inputs[row]
        let value: String
        switch tableColumn.identifier.rawValue {
        case "change": value = input.changeKind.rawValue
        case "key": value = input.displayKey
        case "before": value = summary(kind: input.beforeKind, value: input.beforeValue)
        case "after": value = summary(kind: input.afterKind, value: input.afterValue)
        default: value = ""
        }
        return textCell(value, table: tableView, column: tableColumn)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === changesTable else { return }
        renderSelectedChange()
    }

    private func configure(
        panel: NSPanel,
        tableLayoutStore: TableLayoutStore
    ) {
        let heading = NSTextField(labelWithString:
            "Save \(inputs.count.formatted()) \(inputs.count == 1 ? "change" : "changes")?"
        )
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.identifier = .init("key-value-diff-heading")

        let target = NSTextField(wrappingLabelWithString: targetDetails)
        target.identifier = .init("key-value-diff-target")
        target.lineBreakMode = .byTruncatingMiddle
        target.maximumNumberOfLines = 2
        target.textColor = .secondaryLabelColor
        target.toolTip = targetDetails

        for (id, title, width, minimumWidth) in [
            ("change", "Change", CGFloat(92), CGFloat(76)),
            ("key", "Key", CGFloat(250), CGFloat(130)),
            ("before", "Before", CGFloat(130), CGFloat(95)),
            ("after", "After", CGFloat(130), CGFloat(95)),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = minimumWidth
            column.resizingMask = .userResizingMask
            changesTable.addTableColumn(column)
        }
        changesTable.identifier = .init("key-value-diff-changes")
        changesTable.setAccessibilityLabel("Staged key value changes")
        changesTable.dataSource = self
        changesTable.delegate = self
        changesTable.usesAlternatingRowBackgroundColors = true
        changesTable.allowsEmptySelection = false
        changesTable.allowsMultipleSelection = false
        changesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableLayoutBinding = TableLayoutBinding(
            tableView: changesTable,
            surface: .keyValueDiffChanges,
            store: tableLayoutStore
        )
        let changesScroll = NSScrollView()
        changesScroll.identifier = .init("key-value-diff-changes-scroll")
        changesScroll.documentView = changesTable
        changesScroll.hasVerticalScroller = true
        changesScroll.hasHorizontalScroller = true
        changesScroll.autohidesScrollers = true
        changesScroll.borderType = .bezelBorder

        keyLabel.identifier = .init("key-value-diff-key")
        keyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        keyLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.identifier = .init("key-value-diff-metadata")
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        diffLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sensitiveNotice.identifier = .init("key-value-diff-sensitive-notice")
        sensitiveNotice.textColor = .systemOrange
        sensitiveNotice.maximumNumberOfLines = 2
        sensitiveNotice.isHidden = true
        truncationNotice.identifier = .init("key-value-diff-truncation")
        truncationNotice.textColor = .systemOrange
        truncationNotice.maximumNumberOfLines = 2
        truncationNotice.isHidden = true

        let right = NSStackView(views: [
            keyLabel, metadataLabel, sensitiveNotice, diffLabel,
            diffDocument.scrollView, truncationNotice,
        ])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 7
        for view in [
            keyLabel, metadataLabel, sensitiveNotice, diffLabel,
            diffDocument.scrollView, truncationNotice,
        ] {
            view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        diffDocument.scrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 240
        ).isActive = true

        let split = KeyValueEditorSplitView()
        split.identifier = .init("key-value-diff-split")
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "kmgr.key-value-diff-master-detail"
        split.preferredLeadingFraction = 0.38
        split.paneMinimumsProvider = {
            KeyValueEditorSplitView.PaneMinimums(leading: 300, trailing: 360)
        }
        split.addArrangedSubview(changesScroll)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        let copy = NSButton(title: "Copy Selected Diff", target: self, action: #selector(copySelected))
        copy.identifier = .init("key-value-diff-copy")
        let search = NSButton(title: "Search", target: self, action: #selector(search))
        search.identifier = .init("key-value-diff-search")
        let keepEditing = NSButton(
            title: "Keep Editing", target: self, action: #selector(keepEditing)
        )
        keepEditing.identifier = .init("key-value-diff-keep-editing")
        keepEditing.keyEquivalent = "\u{1b}"
        let save = NSButton(
            title: "Save \(inputs.count.formatted()) \(inputs.count == 1 ? "Change" : "Changes")",
            target: self,
            action: #selector(save)
        )
        save.identifier = .init("key-value-diff-save")
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [copy, search, NSView(), keepEditing, save])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, target, split, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
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
            split.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        panel.contentView = root
        panel.initialFirstResponder = changesTable
    }

    private func renderSelectedChange() {
        guard inputs.indices.contains(changesTable.selectedRow) else { return }
        let input = inputs[changesTable.selectedRow]
        keyLabel.stringValue = "\(input.changeKind.rawValue): \(input.displayKey)"
        metadataLabel.stringValue = "Preparing value comparison…"
        sensitiveNotice.isHidden = !input.sensitive
        truncationNotice.isHidden = true
        selectedPresentation = nil
        diffDocument.replace(lines: [DiffTextLine(
            text: "Preparing selected value comparison…",
            role: .notice
        )])

        renderGeneration &+= 1
        let generation = renderGeneration
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let presentation = await Task.detached(priority: .userInitiated) {
                var protectedInput = input
                defer { protectedInput.wipe() }
                return KeyValueDiffPresentation(input: protectedInput)
            }.value
            guard let self, !Task.isCancelled, renderGeneration == generation else { return }
            selectedPresentation = presentation
            metadataLabel.stringValue = presentation.metadataText
            diffLabel.stringValue = presentation.diffLabel
            truncationNotice.isHidden = !presentation.previewTruncated
            diffDocument.replace(lines: presentation.lines)
            renderTask = nil
        }
    }

    private func summary(kind: DataValueKind?, value: Data?) -> String {
        guard let kind, let value else { return "Absent" }
        let type = kind == .text ? "Text" : "Binary"
        let count = value.count == 1 ? "1 byte" : "\(value.count.formatted()) bytes"
        return "\(type) · \(count)"
    }

    private func textCell(
        _ value: String,
        table: NSTableView,
        column: NSTableColumn
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(
            "key-value-diff.\(column.identifier.rawValue)"
        )
        let cell = table.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = value
        cell.textField?.toolTip = value
        return cell
    }

    @objc private func copySelected() {
        guard let presentation = selectedPresentation else { return }
        let copyText = [
            "\(presentation.changeKind.rawValue): \(presentation.displayKey)",
            presentation.metadataText,
            "",
            presentation.diffLabel,
            presentation.text,
        ].joined(separator: "\n")
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
