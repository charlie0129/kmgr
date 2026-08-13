import AppKit
import KmgrCore

@MainActor
final class ColumnsManagerWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    private let resourceTitle: String
    private let match: ColumnResourceMatch
    private let defaultColumns: [ColumnDefinition]
    private let fileStore: ColumnConfigurationFileStore
    private var configurationDocument: ColumnsConfigurationDocument
    private var draft: ResourceColumnDraft
    private var lastAppliedColumns: [ColumnDefinition]
    private var persistenceAvailable: Bool
    private var dirty = false
    private var editorController: CELColumnEditorWindowController?
    private var catalogController: NativeColumnPickerWindowController?

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    /// Called after every safe draft change so a resource table can preview
    /// the new order and enabled state before it is persisted.
    var onDraftChanged: (([ColumnDefinition]) -> Void)?
    var onSaved: (([ColumnDefinition]) -> Void)?
    var onClose: (() -> Void)?

    init(
        resourceTitle: String,
        match: ColumnResourceMatch,
        defaultColumns: [ColumnDefinition],
        configurationPath: String = AppPreferences.defaultColumnsConfigurationPath
    ) {
        self.resourceTitle = resourceTitle
        self.match = match
        self.defaultColumns = defaultColumns
        fileStore = ColumnConfigurationFileStore(path: configurationPath)

        var loadedDocument = ColumnsConfigurationDocument()
        var loadMessage: String?
        do {
            loadedDocument = try fileStore.load()
        } catch {
            loadMessage = error.localizedDescription
        }
        configurationDocument = loadedDocument
        let existing = loadedDocument.views.first(where: { $0.match == match })?.columns
            ?? defaultColumns
        draft = ResourceColumnDraft(match: match, columns: existing)
        lastAppliedColumns = existing
        persistenceAvailable = loadMessage == nil

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 570),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Columns — \(resourceTitle)"
        window.minSize = NSSize(width: 680, height: 380)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
        tableView.reloadData()
        updateActionAvailability()
        if let loadMessage {
            showStatus(loadMessage, error: true)
        } else {
            showStatus(scopeDescription, error: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(sender)
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { draft.columns.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard draft.columns.indices.contains(row), let tableColumn else { return nil }
        let definition = draft.columns[row]
        if tableColumn.identifier == .columnEnabled {
            let identifier = NSUserInterfaceItemIdentifier("column-enabled-cell")
            let button = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton
                ?? makeEnabledButton(identifier: identifier)
            button.tag = row
            button.state = definition.isEnabled ? .on : .off
            button.setAccessibilityLabel("Show \(definition.title) column")
            return button
        }

        let identifier = NSUserInterfaceItemIdentifier("column-cell-\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTextCell(identifier: identifier)
        guard let label = cell.textField else { return cell }
        label.textColor = definition.isEnabled ? .labelColor : .tertiaryLabelColor
        label.toolTip = nil
        switch tableColumn.identifier {
        case .columnTitle:
            label.stringValue = definition.title
        case .columnID:
            label.stringValue = definition.id
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        case .columnSource:
            label.stringValue = definition.source.rawValue.uppercased()
        case .columnType:
            label.stringValue = Self.resultTypeTitle(definition.type)
        case .columnValue:
            label.stringValue = definition.expression ?? definition.value ?? "—"
            label.toolTip = definition.expression ?? definition.value
            label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        case .columnWidth:
            label.stringValue = definition.width.map { String(format: "%.0f", $0) } ?? "Automatic"
        default:
            label.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionAvailability()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save column changes?"
        alert.informativeText = "Unsaved changes for \(resourceTitle) will otherwise be discarded."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return persistDraft()
        case .alertSecondButtonReturn:
            onDraftChanged?(lastAppliedColumns)
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let parent = window?.sheetParent, let sheet = window {
            parent.endSheet(sheet)
        }
        onClose?()
    }

    private func configureContent(in window: NSWindow) {
        let root = NSView()

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (.columnEnabled, "", 32),
            (.columnTitle, "Title", 140),
            (.columnID, "ID", 125),
            (.columnSource, "Source", 75),
            (.columnType, "Type", 100),
            (.columnValue, "Expression / Value", 300),
            (.columnWidth, "Width", 80),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = identifier == .columnEnabled ? width : min(60, width)
            column.maxWidth = identifier == .columnEnabled ? width : .greatestFiniteMagnitude
            column.resizingMask = identifier == .columnEnabled ? [] : .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .medium
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(editSelected)
        tableView.setAccessibilityLabel("Columns for \(resourceTitle)")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let addNativeButton = NSButton(
            title: "Add Built-in/Metric…",
            target: self,
            action: #selector(addNative)
        )
        let addButton = NSButton(title: "Add CEL…", target: self, action: #selector(addCEL))
        editButton.target = self
        editButton.action = #selector(editSelected)
        moveUpButton.target = self
        moveUpButton.action = #selector(moveSelectedUp)
        moveDownButton.target = self
        moveDownButton.action = #selector(moveSelectedDown)
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let reloadButton = NSButton(title: "Reload File", target: self, action: #selector(reloadFile))
        let openButton = NSButton(title: "Open in Editor", target: self, action: #selector(openInEditor))
        let controls = NSStackView(views: [
            addNativeButton, addButton, editButton, moveUpButton, moveDownButton, resetButton,
            NSView(), reloadButton, openButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 7
        controls.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [statusLabel, NSView(), closeButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(controls)
        root.addSubview(scrollView)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
        ])
        window.contentView = root
    }

    private var scopeDescription: String {
        let group = match.group.isEmpty ? "core" : match.group
        return "Exact resource: \(group)/\(match.version)/\(match.resource) · CEL \(ColumnConfigurationSchema.celEnvironment)"
    }

    private var selectedIndex: Int? {
        draft.columns.indices.contains(tableView.selectedRow) ? tableView.selectedRow : nil
    }

    private func makeEnabledButton(identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
        button.identifier = identifier
        button.imagePosition = .imageOnly
        return button
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func updateActionAvailability() {
        let index = selectedIndex
        editButton.isEnabled = index.map { draft.columns[$0].source == .cel } ?? false
        moveUpButton.isEnabled = index.map { $0 > 0 } ?? false
        moveDownButton.isEnabled = index.map { $0 + 1 < draft.columns.count } ?? false
        saveButton.isEnabled = persistenceAvailable && dirty
    }

    private func markChanged(selecting index: Int? = nil) {
        dirty = draft.columns != lastAppliedColumns
        tableView.reloadData()
        if let index, draft.columns.indices.contains(index) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
        updateActionAvailability()
        onDraftChanged?(draft.columns)
        showStatus(dirty ? "Unsaved changes · \(scopeDescription)" : scopeDescription, error: false)
    }

    private func showStatus(_ message: String, error: Bool) {
        statusLabel.stringValue = message
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = message
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard draft.columns.indices.contains(sender.tag) else { return }
        let id = draft.columns[sender.tag].id
        guard draft.setEnabled(sender.state == .on, columnID: id) else { return }
        markChanged(selecting: sender.tag)
    }

    @objc private func moveSelectedUp() {
        guard let index = selectedIndex, index > 0,
            draft.move(columnID: draft.columns[index].id, to: index - 1)
        else { return }
        markChanged(selecting: index - 1)
    }

    @objc private func moveSelectedDown() {
        guard let index = selectedIndex, index + 1 < draft.columns.count,
            draft.move(columnID: draft.columns[index].id, to: index + 1)
        else { return }
        markChanged(selecting: index + 1)
    }

    @objc private func resetToDefaults() {
        draft.reset(to: defaultColumns)
        markChanged(selecting: defaultColumns.isEmpty ? nil : 0)
    }

    @objc private func addCEL() {
        presentEditor(existingIndex: nil)
    }

    @objc private func addNative() {
        guard catalogController == nil, let parent = window else { return }
        let picker = NativeColumnPickerWindowController(
            match: match,
            existingColumns: draft.columns
        )
        picker.onCommit = { [weak self] definition in
            guard let self else { return }
            do {
                try self.draft.appendNative(definition)
                self.markChanged(selecting: self.draft.columns.count - 1)
            } catch {
                self.showStatus(error.localizedDescription, error: true)
            }
        }
        picker.onDismiss = { [weak self] in self?.catalogController = nil }
        catalogController = picker
        picker.beginSheet(for: parent)
    }

    @objc private func editSelected() {
        guard let index = selectedIndex, draft.columns[index].source == .cel else {
            NSSound.beep()
            return
        }
        presentEditor(existingIndex: index)
    }

    private func presentEditor(existingIndex: Int?) {
        guard editorController == nil, let parent = window else { return }
        let existing = existingIndex.map { draft.columns[$0] }
        var reservedIDs = Set(draft.columns.map(\.id))
        if let existing { reservedIDs.remove(existing.id) }
        let editor = CELColumnEditorWindowController(
            definition: existing,
            reservedIDs: reservedIDs
        )
        editor.onCommit = { [weak self] definition in
            guard let self else { return }
            do {
                if let existingIndex {
                    var columns = self.draft.columns
                    guard columns.indices.contains(existingIndex) else { return }
                    columns[existingIndex] = definition
                    self.draft = ResourceColumnDraft(match: self.match, columns: columns)
                    self.markChanged(selecting: existingIndex)
                } else {
                    try self.draft.appendCEL(definition)
                    self.markChanged(selecting: self.draft.columns.count - 1)
                }
            } catch {
                self.showStatus(error.localizedDescription, error: true)
            }
        }
        editor.onDismiss = { [weak self] in self?.editorController = nil }
        editorController = editor
        editor.beginSheet(for: parent)
    }

    @objc private func reloadFile() {
        do {
            let loaded = try fileStore.load()
            configurationDocument = loaded
            let columns = loaded.views.first(where: { $0.match == match })?.columns
                ?? defaultColumns
            draft = ResourceColumnDraft(match: match, columns: columns)
            lastAppliedColumns = columns
            dirty = false
            persistenceAvailable = true
            tableView.reloadData()
            tableView.deselectAll(nil)
            updateActionAvailability()
            onDraftChanged?(columns)
            showStatus("Reloaded · \(scopeDescription)", error: false)
        } catch {
            persistenceAvailable = false
            updateActionAvailability()
            showStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func openInEditor() {
        do {
            let url = try fileStore.ensureFileExists()
            guard NSWorkspace.shared.open(url) else {
                throw ColumnConfigurationFileIssue("No application could open \(url.path).")
            }
            showStatus("Opened \(url.lastPathComponent). Reload after external edits.", error: false)
        } catch {
            showStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func save() {
        _ = persistDraft()
    }

    private func persistDraft() -> Bool {
        guard persistenceAvailable else {
            showStatus("Reload a valid configuration before saving.", error: true)
            return false
        }
        do {
            let currentOnDisk = try fileStore.load()
            guard currentOnDisk == configurationDocument else {
                persistenceAvailable = false
                updateActionAvailability()
                throw ColumnConfigurationFileIssue(
                    "The column configuration changed outside this window. Reload it before saving so no external edit is overwritten."
                )
            }
            var updated = configurationDocument
            let view = ResourceColumnConfiguration(match: match, columns: draft.columns)
            if let index = updated.views.firstIndex(where: { $0.match == match }) {
                updated.views[index] = view
            } else {
                updated.views.append(view)
            }
            try fileStore.save(updated)
            configurationDocument = updated
            lastAppliedColumns = draft.columns
            dirty = false
            persistenceAvailable = true
            updateActionAvailability()
            showStatus("Saved \(draft.columns.count.formatted()) columns · \(scopeDescription)", error: false)
            onSaved?(draft.columns)
            return true
        } catch {
            showStatus(error.localizedDescription, error: true)
            return false
        }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    fileprivate static func resultTypeTitle(_ type: ColumnResultType) -> String {
        switch type {
        case .resourceUsage: "Resource usage"
        default: type.rawValue.capitalized
        }
    }
}

@MainActor
private final class NativeColumnPickerWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate
{
    private let match: ColumnResourceMatch
    private let draft: ResourceColumnDraft
    private let items: [NativeColumnCatalogItem]
    private let exactResourceSupported: Bool
    private let tableView = NSTableView()
    private let addSelectedButton = NSButton(title: "Add Disabled", target: nil, action: nil)
    private let exactResourceField = NSTextField()
    private let exactTitleField = NSTextField()
    private let addExactButton = NSButton(title: "Add Exact Resource Disabled", target: nil, action: nil)
    private let exactErrorLabel = NSTextField(wrappingLabelWithString: "")

    var onCommit: ((ColumnDefinition) -> Void)?
    var onDismiss: (() -> Void)?

    init(match: ColumnResourceMatch, existingColumns: [ColumnDefinition]) {
        self.match = match
        draft = ResourceColumnDraft(match: match, columns: existingColumns)
        exactResourceSupported = NativeColumnCatalog.supportsExactResources(
            group: match.group,
            version: match.version,
            resource: match.resource
        )
        items = NativeColumnCatalog.items(
            group: match.group,
            version: match.version,
            resource: match.resource,
            existingColumns: existingColumns
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Add Built-in or Metric Column"
        panel.minSize = NSSize(width: 650, height: 480)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
        updateSelection()
        validateExactResource()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onDismiss?() }
        window.makeFirstResponder(tableView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row), let tableColumn else { return nil }
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier(
            "native-picker-\(tableColumn.identifier.rawValue)"
        )
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeTextCell(identifier: identifier)
        guard let label = cell.textField else { return cell }
        label.textColor = item.isAlreadyAdded ? .tertiaryLabelColor : .labelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        cell.toolTip = item.exactIdentity
        switch tableColumn.identifier {
        case .nativeTitle:
            label.stringValue = item.descriptor.title
            label.toolTip = item.exactIdentity
        case .nativeSource:
            label.stringValue = item.descriptor.source.rawValue.uppercased()
        case .nativeType:
            label.stringValue = ColumnsManagerWindowController.resultTypeTitle(
                item.descriptor.type
            )
        case .nativeIdentity:
            label.stringValue = item.exactIdentity
            label.toolTip = item.exactIdentity
            label.font = .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
        case .nativeAvailability:
            label.stringValue = item.isAlreadyAdded ? "Already added" : "Available"
        default:
            label.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
    }

    func controlTextDidChange(_ obj: Notification) {
        validateExactResource()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let parent = sender.sheetParent {
            parent.endSheet(sender, returnCode: .cancel)
            return false
        }
        return true
    }

    private func configureContent(in panel: NSPanel) {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (.nativeTitle, "Title", 145),
            (.nativeSource, "Source", 75),
            (.nativeType, "Type", 120),
            (.nativeIdentity, "Exact identity", 225),
            (.nativeAvailability, "Status", 100),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 65
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowSizeStyle = .medium
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(addSelected)
        tableView.setAccessibilityLabel("Available built-in and metric columns")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let catalogHelp = NSTextField(wrappingLabelWithString:
            "Only extractors supported for this exact GVR are listed. Added columns start disabled, so metrics and scheduler-accounting providers remain idle until you explicitly enable the column in the manager."
        )
        catalogHelp.textColor = .secondaryLabelColor
        catalogHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        exactResourceField.delegate = self
        exactResourceField.placeholderString = "nvidia.com/gpu or hugepages-2Mi"
        exactResourceField.setAccessibilityLabel("Exact Kubernetes resource name")
        exactTitleField.delegate = self
        exactTitleField.placeholderString = "Optional display title"
        exactTitleField.setAccessibilityLabel("Exact resource display title")
        let exactGrid = NSGridView(views: [
            gridRow("Resource name", exactResourceField),
            gridRow("Title", exactTitleField),
        ])
        exactGrid.rowSpacing = 7
        exactGrid.columnSpacing = 10
        exactGrid.column(at: 0).xPlacement = .trailing
        exactGrid.column(at: 1).xPlacement = .fill

        exactErrorLabel.textColor = .systemRed
        exactErrorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        exactErrorLabel.maximumNumberOfLines = 2
        exactErrorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addExactButton.target = self
        addExactButton.action = #selector(addExactResource)
        let exactFooter = NSStackView(views: [exactErrorLabel, NSView(), addExactButton])
        exactFooter.orientation = .horizontal
        exactFooter.alignment = .centerY
        exactFooter.spacing = 8

        var exactBox: NSBox?
        if exactResourceSupported {
            let exactStack = NSStackView(views: [exactGrid, exactFooter])
            exactStack.orientation = .vertical
            exactStack.alignment = .leading
            exactStack.spacing = 8
            exactGrid.widthAnchor.constraint(equalTo: exactStack.widthAnchor).isActive = true
            exactFooter.widthAnchor.constraint(equalTo: exactStack.widthAnchor).isActive = true

            let box = NSBox()
            box.title = "Arbitrary Exact Scheduler Resource"
            box.contentViewMargins = NSSize(width: 12, height: 10)
            box.contentView = exactStack
            box.translatesAutoresizingMaskIntoConstraints = false
            exactBox = box
        }

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        addSelectedButton.target = self
        addSelectedButton.action = #selector(addSelected)
        addSelectedButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), cancelButton, addSelectedButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        for view in [scrollView, catalogHelp] + [exactBox].compactMap({ $0 }) + [footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        var constraints = [
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            catalogHelp.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            catalogHelp.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            catalogHelp.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 7),
            footer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ]
        if let exactBox {
            constraints += [
                exactBox.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                exactBox.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                exactBox.topAnchor.constraint(equalTo: catalogHelp.bottomAnchor, constant: 11),
                footer.topAnchor.constraint(equalTo: exactBox.bottomAnchor, constant: 11),
            ]
        } else {
            constraints.append(
                footer.topAnchor.constraint(equalTo: catalogHelp.bottomAnchor, constant: 11)
            )
        }
        NSLayoutConstraint.activate(constraints)
        panel.contentView = root
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func gridRow(_ title: String, _ control: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return [label, control]
    }

    private func updateSelection() {
        let row = tableView.selectedRow
        addSelectedButton.isEnabled = items.indices.contains(row) && !items[row].isAlreadyAdded
    }

    private func exactDefinition() throws -> ColumnDefinition {
        try NativeColumnCatalog.exactResourceDefinition(
            resourceName: exactResourceField.stringValue,
            title: exactTitleField.stringValue,
            group: match.group,
            version: match.version,
            resource: match.resource
        )
    }

    private func validateExactResource() {
        guard exactResourceSupported else { return }
        do {
            let definition = try exactDefinition()
            guard draft.canAppendNative(definition) else {
                throw ColumnDraftError.invalidOrDuplicateNativeColumn
            }
            exactErrorLabel.stringValue = "Full identity: metric:\(definition.value ?? "")"
            exactErrorLabel.textColor = .secondaryLabelColor
            exactErrorLabel.toolTip = definition.value
            addExactButton.isEnabled = true
        } catch {
            exactErrorLabel.stringValue = error.localizedDescription
            exactErrorLabel.textColor = .systemRed
            exactErrorLabel.toolTip = error.localizedDescription
            addExactButton.isEnabled = false
        }
    }

    @objc private func addSelected() {
        let row = tableView.selectedRow
        guard items.indices.contains(row), !items[row].isAlreadyAdded else { return }
        finish(with: items[row].descriptor.definition(enabled: false))
    }

    @objc private func addExactResource() {
        guard let definition = try? exactDefinition(), draft.canAppendNative(definition) else {
            validateExactResource()
            return
        }
        finish(with: definition)
    }

    private func finish(with definition: ColumnDefinition) {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        onCommit?(definition)
        parent.endSheet(sheet, returnCode: .OK)
    }

    @objc private func cancel() {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet, returnCode: .cancel)
    }
}

@MainActor
private final class CELColumnEditorWindowController: NSWindowController,
    NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate
{
    private let original: ColumnDefinition?
    private let reservedIDs: Set<String>
    private let idField = NSTextField()
    private let titleField = NSTextField()
    private let expressionView = NSTextView()
    private let typeButton = NSPopUpButton()
    private let alignmentButton = NSPopUpButton()
    private let missingField = NSTextField()
    private let widthField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let commitButton = NSButton(title: "Add", target: nil, action: nil)

    var onCommit: ((ColumnDefinition) -> Void)?
    var onDismiss: (() -> Void)?

    init(definition: ColumnDefinition?, reservedIDs: Set<String>) {
        original = definition
        self.reservedIDs = reservedIDs
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = definition == nil ? "Add CEL Column" : "Edit CEL Column"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
        install(definition)
        validate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.onDismiss?() }
        window.makeFirstResponder(idField)
    }

    func controlTextDidChange(_ obj: Notification) { validate() }
    func textDidChange(_ notification: Notification) { validate() }

    private func configureContent(in panel: NSPanel) {
        for field in [idField, titleField, missingField, widthField] {
            field.delegate = self
            field.bezelStyle = .roundedBezel
        }
        idField.placeholderString = "team"
        titleField.placeholderString = "Team"
        missingField.placeholderString = "—"
        widthField.placeholderString = "Automatic"
        widthField.alignment = .right

        typeButton.addItems(withTitles: ColumnResultType.allCases.map(ColumnsManagerWindowController.resultTypeTitle))
        typeButton.target = self
        typeButton.action = #selector(choiceChanged)
        alignmentButton.addItems(withTitles: ColumnAlignment.allCases.map { $0.rawValue.capitalized })
        alignmentButton.target = self
        alignmentButton.action = #selector(choiceChanged)

        expressionView.delegate = self
        expressionView.isRichText = false
        expressionView.isAutomaticQuoteSubstitutionEnabled = false
        expressionView.isAutomaticDashSubstitutionEnabled = false
        expressionView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        expressionView.textContainerInset = NSSize(width: 6, height: 6)
        expressionView.setAccessibilityLabel("CEL expression")
        let expressionScroll = NSScrollView()
        expressionScroll.documentView = expressionView
        expressionScroll.hasVerticalScroller = true
        expressionScroll.borderType = .bezelBorder
        expressionScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let grid = NSGridView(views: [
            gridRow("ID", idField),
            gridRow("Title", titleField),
            gridRow("Expression", expressionScroll),
            gridRow("Result type", typeButton),
            gridRow("Alignment", alignmentButton),
            gridRow("Missing value", missingField),
            gridRow("Width", widthField),
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        let help = NSTextField(wrappingLabelWithString:
            "The Go engine compiles CEL against \(ColumnConfigurationSchema.celEnvironment) before activation. Invalid external edits leave the last valid compiled configuration active."
        )
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.maximumNumberOfLines = 2
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        commitButton.title = original == nil ? "Add" : "Apply"
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [errorLabel, NSView(), cancelButton, commitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [grid, help, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        panel.contentView = root
    }

    private func gridRow(_ title: String, _ control: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return [label, control]
    }

    private func install(_ definition: ColumnDefinition?) {
        guard let definition else {
            typeButton.selectItem(at: ColumnResultType.allCases.firstIndex(of: .string) ?? 0)
            alignmentButton.selectItem(at: ColumnAlignment.allCases.firstIndex(of: .leading) ?? 0)
            return
        }
        idField.stringValue = definition.id
        titleField.stringValue = definition.title
        expressionView.string = definition.expression ?? ""
        typeButton.selectItem(at: ColumnResultType.allCases.firstIndex(of: definition.type) ?? 0)
        alignmentButton.selectItem(at: ColumnAlignment.allCases.firstIndex(of: definition.alignment ?? .leading) ?? 0)
        missingField.stringValue = definition.missing ?? ""
        widthField.stringValue = definition.width.map { String($0) } ?? ""
    }

    private func definitionFromControls() -> ColumnDefinition? {
        guard validationMessage() == nil else { return nil }
        let type = ColumnResultType.allCases[typeButton.indexOfSelectedItem]
        let alignment = ColumnAlignment.allCases[alignmentButton.indexOfSelectedItem]
        let missing = missingField.stringValue.isEmpty ? nil : missingField.stringValue
        let widthText = widthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let width = widthText.isEmpty ? nil : Double(widthText)
        return ColumnDefinition(
            id: idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            title: titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .cel,
            expression: expressionView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            type: type,
            alignment: alignment,
            missing: missing,
            width: width,
            listJoiner: original?.listJoiner,
            enabled: original?.enabled ?? true
        )
    }

    private func validationMessage() -> String? {
        let id = idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "Column ID is required." }
        if reservedIDs.contains(id) { return "Column ID “\(id)” already exists in this resource view." }
        if titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }
        if expressionView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "CEL expression is required."
        }
        let width = widthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !width.isEmpty {
            guard let value = Double(width), value.isFinite, value >= 0 else {
                return "Width must be a finite non-negative number or left empty."
            }
        }
        return nil
    }

    private func validate() {
        let message = validationMessage()
        errorLabel.stringValue = message ?? ""
        commitButton.isEnabled = message == nil
    }

    @objc private func choiceChanged() { validate() }

    @objc private func commit() {
        guard let definition = definitionFromControls(), let sheet = window,
            let parent = sheet.sheetParent
        else { return }
        onCommit?(definition)
        parent.endSheet(sheet, returnCode: .OK)
    }

    @objc private func cancel() {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet, returnCode: .cancel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let parent = sender.sheetParent {
            parent.endSheet(sender, returnCode: .cancel)
            return false
        }
        return true
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let columnEnabled = Self("column-enabled")
    static let columnTitle = Self("column-title")
    static let columnID = Self("column-id")
    static let columnSource = Self("column-source")
    static let columnType = Self("column-type")
    static let columnValue = Self("column-value")
    static let columnWidth = Self("column-width")
    static let nativeTitle = Self("native-title")
    static let nativeSource = Self("native-source")
    static let nativeType = Self("native-type")
    static let nativeIdentity = Self("native-identity")
    static let nativeAvailability = Self("native-availability")
}
