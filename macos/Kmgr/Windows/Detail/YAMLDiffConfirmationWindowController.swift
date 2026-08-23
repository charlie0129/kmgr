import AppKit
import KmgrCore

/// A transient, resizable confirmation window for prepared YAML edits.
///
/// The text storage is the sole retained copy of rendered decoded Secret
/// values. It is cleared as soon as the sheet presentation ends.
@MainActor
final class YAMLDiffConfirmationWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    enum Choice: Sendable {
        case apply
        case keepEditing
    }

    private let changedPaths: [YAMLDiffPresentation.ChangedPath]
    private let pathsTable = NSTableView()
    private let diffDocument: DiffTextDocument
    private let tableLayoutStore: TableLayoutStore
    private var tableLayoutBinding: TableLayoutBinding?
    private let reviewSession = DiffReviewSheetSession<Choice>(
        cancellationChoice: .keepEditing
    )

    init(
        targetDetails: String,
        prepared: PreparedYAMLEdit,
        tableLayoutStore: TableLayoutStore? = nil
    ) {
        let presentation = YAMLDiffPresentation(prepared: prepared)
        changedPaths = presentation.changedPaths
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        diffDocument = DiffTextDocument(
            lines: presentation.lines,
            identifierPrefix: "yaml-diff",
            accessibilityLabel: "Prepared YAML unified diff"
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review YAML Changes"
        panel.minSize = NSSize(width: 680, height: 480)
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
        clearTransientPresentation()
        return choice
    }

    func cancelReview() {
        if reviewSession.isActive {
            reviewSession.cancel()
        } else {
            window?.close()
        }
        clearTransientPresentation()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard reviewSession.isActive else {
            clearTransientPresentation()
            return true
        }
        reviewSession.cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        reviewSession.cancel()
        clearTransientPresentation()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        changedPaths.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard changedPaths.indices.contains(row), let tableColumn else { return nil }
        let cellIdentifier = NSUserInterfaceItemIdentifier(
            "yaml-diff-path-cell-\(tableColumn.identifier.rawValue)"
        )
        let cell: NSTableCellView
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self)
            as? NSTableCellView,
            let reusedField = reused.textField
        {
            cell = reused
            field = reusedField
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier
            field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = tableColumn.identifier.rawValue == "path"
                ? .byTruncatingMiddle : .byTruncatingTail
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let item = changedPaths[row]
        switch tableColumn.identifier.rawValue {
        case "path":
            field.stringValue = item.path
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            field.textColor = .labelColor
        case "before":
            field.stringValue = item.beforeSummary
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = color(for: item.severity)
        default:
            field.stringValue = item.afterSummary
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = color(for: item.severity)
        }
        field.toolTip = field.stringValue
        return cell
    }

    private func configure(
        panel: NSPanel,
        targetDetails: String,
        presentation: YAMLDiffPresentation
    ) {
        let heading = NSTextField(labelWithString:
            "Apply \(changedPaths.count) YAML change\(changedPaths.count == 1 ? "" : "s")?"
        )
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.identifier = .init("yaml-diff-heading")

        let target = NSTextField(wrappingLabelWithString: targetDetails)
        target.identifier = .init("yaml-diff-target")
        target.lineBreakMode = .byTruncatingMiddle
        target.maximumNumberOfLines = 2
        target.textColor = .secondaryLabelColor
        target.toolTip = targetDetails

        let changedPathsLabel = NSTextField(labelWithString: "Changed Paths")
        changedPathsLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        configurePathsTable()
        let pathsScroll = NSScrollView()
        pathsScroll.identifier = .init("yaml-diff-paths-scroll")
        pathsScroll.documentView = pathsTable
        pathsScroll.hasVerticalScroller = true
        pathsScroll.autohidesScrollers = true
        pathsScroll.borderType = .bezelBorder
        pathsScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let diffLabel = NSTextField(labelWithString: "Unified Diff")
        diffLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let truncation = NSTextField(wrappingLabelWithString:
            "The unified diff reached the 16 KiB display limit. The prepared edit is complete; only this preview is truncated."
        )
        truncation.identifier = .init("yaml-diff-truncation")
        truncation.textColor = .systemOrange
        truncation.maximumNumberOfLines = 2
        truncation.isHidden = !presentation.unifiedDiffTruncated

        let copyAll = NSButton(title: "Copy All", target: self, action: #selector(copyAll))
        copyAll.identifier = .init("yaml-diff-copy-all")
        copyAll.toolTip = "Copy the complete visible presentation, including decoded Secret values."
        let search = NSButton(title: "Search", target: self, action: #selector(search))
        search.identifier = .init("yaml-diff-search")
        search.toolTip = "Open the native find bar for the diff."
        let keepEditing = NSButton(
            title: "Keep Editing", target: self, action: #selector(keepEditing)
        )
        keepEditing.identifier = .init("yaml-diff-keep-editing")
        keepEditing.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.identifier = .init("yaml-diff-apply")
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [copyAll, search, NSView(), keepEditing, apply])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [
            heading, target, changedPathsLabel, pathsScroll, diffLabel,
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
            changedPathsLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            pathsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            diffLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            diffDocument.scrollView.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -36
            ),
            diffDocument.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            truncation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        panel.contentView = root
        panel.initialFirstResponder = diffDocument.initialFirstResponder
    }

    private func configurePathsTable() {
        for (identifier, title, width) in [
            ("path", "Path", CGFloat(260)),
            ("before", "Before", CGFloat(310)),
            ("after", "After", CGFloat(310)),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = 120
            pathsTable.addTableColumn(column)
        }
        pathsTable.identifier = .init("yaml-diff-paths")
        pathsTable.dataSource = self
        pathsTable.delegate = self
        pathsTable.rowHeight = 22
        pathsTable.usesAlternatingRowBackgroundColors = true
        pathsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableLayoutBinding = TableLayoutBinding(
            tableView: pathsTable,
            surface: .yamlDiffPaths,
            store: tableLayoutStore
        )
    }

    private func color(for severity: CellSeverity) -> NSColor {
        switch severity {
        case .warning: .systemOrange
        case .critical: .systemRed
        case .informational: .systemBlue
        case .muted: .secondaryLabelColor
        case .terminating: .systemPurple
        case .normal: .labelColor
        }
    }

    @objc private func copyAll() {
        var changedPathSummary = "Changed Paths\nPath\tBefore\tAfter"
        for path in changedPaths {
            changedPathSummary += "\n\(path.path)\t\(path.beforeSummary)\t\(path.afterSummary)"
        }
        let copyText = changedPathSummary + "\n\nUnified Diff\n" + diffDocument.text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText, forType: .string)
    }

    @objc private func search() {
        diffDocument.showFindPanel(in: window)
    }

    @objc private func apply() {
        finishReview(with: .apply, response: .OK)
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

    private func clearTransientPresentation() {
        diffDocument.clear()
    }
}
