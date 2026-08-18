import AppKit
import KmgrCore

@MainActor
final class ColumnsManagerWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    @MainActor
    struct WindowDismissal {
        let sheetParent: (NSWindow) -> NSWindow?
        let endSheet: (NSWindow, NSWindow) -> Void
        let close: (NSWindow) -> Void

        static let appKit = Self(
            sheetParent: { $0.sheetParent },
            endSheet: { parent, sheet in
                parent.endSheet(sheet, returnCode: .cancel)
            },
            close: { $0.close() }
        )

        func dismiss(_ window: NSWindow) {
            if let parent = sheetParent(window) {
                endSheet(parent, window)
            } else {
                close(window)
            }
        }
    }

    private let resourceTitle: String
    private let match: ColumnResourceMatch
    private let defaultColumns: [ColumnDefinition]
    private let discoveredColumns: [ColumnDefinition]
    private let previewProvider: any ColumnPreviewProviding
    private let previewContext: ColumnPreviewContext
    private let fileStore: ColumnConfigurationFileStore
    private let windowDismissal: WindowDismissal
    private var configurationDocument: ColumnsConfigurationDocument
    private var draft: ResourceColumnDraft
    private var lastAppliedColumns: [ColumnDefinition]
    private var persistenceAvailable: Bool
    private var configurationReady = false
    private var fileOperationTask: Task<Void, Never>?
    private var dirty = false
    private var didFinishDismissal = false
    private var editorController: CELColumnEditorWindowController?
    private var catalogController: NativeColumnPickerWindowController?

    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let addNativeButton = NSButton(title: "Add Built-in/Metric…", target: nil, action: nil)
    private let addCELButton = NSButton(title: "Add CEL…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload File", target: nil, action: nil)
    private let openButton = NSButton(title: "Open in Editor", target: nil, action: nil)
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
        discoveredColumns: [ColumnDefinition] = [],
        previewProvider: any ColumnPreviewProviding,
        previewContext: ColumnPreviewContext,
        configurationPath: String = AppPreferences.defaultColumnsConfigurationPath,
        windowDismissal: WindowDismissal = .appKit
    ) {
        let mergedDefaults = Self.mergingDiscoveredColumns(
            discoveredColumns,
            into: defaultColumns
        )
        self.resourceTitle = resourceTitle
        self.match = match
        self.discoveredColumns = discoveredColumns
        self.defaultColumns = mergedDefaults
        self.previewProvider = previewProvider
        self.previewContext = previewContext
        self.windowDismissal = windowDismissal
        fileStore = ColumnConfigurationFileStore(path: configurationPath)

        configurationDocument = ColumnsConfigurationDocument()
        draft = ResourceColumnDraft(match: match, columns: mergedDefaults)
        lastAppliedColumns = mergedDefaults
        persistenceAvailable = false

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
        showStatus("Loading column configuration…", error: false)
        loadConfiguration(statusPrefix: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    /// Adds cache-discovered native columns to a configured/default layout
    /// without overriding a user's display ID or exact extractor identity.
    /// Disabled huge-page definitions therefore appear in Columns and can be
    /// enabled without requiring the user to type their exact resource key.
    static func mergingDiscoveredColumns(
        _ discovered: [ColumnDefinition],
        into base: [ColumnDefinition]
    ) -> [ColumnDefinition] {
        OptionalResourceColumnOverlay(definitions: discovered).applying(to: base)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(sender)
    }

    func beginSheet(for parent: NSWindow) {
        guard let window, window.sheetParent == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.finishDismissal()
        }
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
        guard !dirty else {
            approveDismissal { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.windowDismissal.dismiss(sender)
            }
            return false
        }
        if let parent = sender.sheetParent {
            parent.endSheet(sender, returnCode: .cancel)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        finishDismissal()
    }

    private func approveDismissal(_ completion: @escaping @MainActor () -> Void) {
        guard dirty else {
            completion()
            return
        }
        guard fileOperationTask == nil else {
            showStatus("Wait for the current column file operation to finish before closing.", error: true)
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save column changes?"
        alert.informativeText = "Unsaved changes for \(resourceTitle) will otherwise be discarded."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            persistDraft(onSuccess: completion)
        case .alertSecondButtonReturn:
            onDraftChanged?(lastAppliedColumns)
            dirty = false
            completion()
        default:
            break
        }
    }

    private func finishDismissal() {
        guard !didFinishDismissal else { return }
        didFinishDismissal = true
        fileOperationTask?.cancel()
        fileOperationTask = nil
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

        addNativeButton.target = self
        addNativeButton.action = #selector(addNative)
        addCELButton.target = self
        addCELButton.action = #selector(addCEL)
        editButton.target = self
        editButton.action = #selector(editSelected)
        moveUpButton.target = self
        moveUpButton.action = #selector(moveSelectedUp)
        moveDownButton.target = self
        moveDownButton.action = #selector(moveSelectedDown)
        resetButton.target = self
        resetButton.action = #selector(resetToDefaults)
        reloadButton.target = self
        reloadButton.action = #selector(reloadFile)
        openButton.target = self
        openButton.action = #selector(openInEditor)
        let controls = NSStackView(views: [
            addNativeButton, addCELButton, editButton, moveUpButton, moveDownButton, resetButton,
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
        let idle = configurationReady && fileOperationTask == nil
        let index = selectedIndex
        tableView.isEnabled = idle
        addNativeButton.isEnabled = idle
        addCELButton.isEnabled = idle
        editButton.isEnabled = idle && (index.map { draft.columns[$0].source == .cel } ?? false)
        moveUpButton.isEnabled = idle && (index.map { $0 > 0 } ?? false)
        moveDownButton.isEnabled = idle && (index.map { $0 + 1 < draft.columns.count } ?? false)
        resetButton.isEnabled = idle
        reloadButton.isEnabled = fileOperationTask == nil
        openButton.isEnabled = fileOperationTask == nil
        saveButton.isEnabled = idle && persistenceAvailable && dirty
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
            reservedIDs: reservedIDs,
            previewProvider: previewProvider,
            previewContext: previewContext
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
        loadConfiguration(statusPrefix: "Reloaded")
    }

    private func loadConfiguration(statusPrefix: String?) {
        guard fileOperationTask == nil else { return }
        showStatus(statusPrefix == nil ? "Loading column configuration…" : "Reloading column configuration…", error: false)
        updateActionAvailability()
        let fileStore = fileStore
        fileOperationTask = Task { [weak self] in
            do {
                let loaded = try await fileStore.loadOffMain()
                try Task.checkCancellation()
                guard let self else { return }
                configurationDocument = loaded
                let configured = loaded.views.first(where: { $0.match == match })?.columns
                    ?? defaultColumns
                let columns = Self.mergingDiscoveredColumns(
                    discoveredColumns,
                    into: configured
                )
                draft = ResourceColumnDraft(match: match, columns: columns)
                lastAppliedColumns = columns
                dirty = false
                persistenceAvailable = true
                configurationReady = true
                tableView.reloadData()
                tableView.deselectAll(nil)
                onDraftChanged?(columns)
                let prefix = statusPrefix.map { "\($0) · " } ?? ""
                showStatus("\(prefix)\(scopeDescription)", error: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                persistenceAvailable = false
                configurationReady = true
                showStatus(error.localizedDescription, error: true)
            }
            guard let self else { return }
            fileOperationTask = nil
            updateActionAvailability()
        }
        updateActionAvailability()
    }

    @objc private func openInEditor() {
        guard fileOperationTask == nil else { return }
        showStatus("Preparing column configuration…", error: false)
        updateActionAvailability()
        let fileStore = fileStore
        fileOperationTask = Task { [weak self] in
            do {
                let url = try await fileStore.ensureFileExistsOffMain()
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(url) else {
                    throw ColumnConfigurationFileIssue("No application could open \(url.path).")
                }
                self?.showStatus("Opened \(url.lastPathComponent). Reload after external edits.", error: false)
            } catch is CancellationError {
                return
            } catch {
                self?.showStatus(error.localizedDescription, error: true)
            }
            self?.fileOperationTask = nil
            self?.updateActionAvailability()
        }
        updateActionAvailability()
    }

    @objc private func save() {
        persistDraft()
    }

    private func persistDraft(onSuccess: (@MainActor () -> Void)? = nil) {
        guard configurationReady, fileOperationTask == nil, persistenceAvailable else {
            showStatus("Reload a valid configuration before saving.", error: true)
            return
        }
        let baseline = configurationDocument
        let columns = draft.columns
        var updated = baseline
        let view = ResourceColumnConfiguration(match: match, columns: columns)
        if let index = updated.views.firstIndex(where: { $0.match == match }) {
            updated.views[index] = view
        } else {
            updated.views.append(view)
        }
        showStatus("Saving column configuration…", error: false)
        let fileStore = fileStore
        fileOperationTask = Task { [weak self] in
            do {
                let currentOnDisk = try await fileStore.loadOffMain()
                try Task.checkCancellation()
                guard currentOnDisk == baseline else {
                    self?.persistenceAvailable = false
                    throw ColumnConfigurationFileIssue(
                        "The column configuration changed outside this window. Reload it before saving so no external edit is overwritten."
                    )
                }
                try await fileStore.saveOffMain(updated)
                try Task.checkCancellation()
                guard let self else { return }
                configurationDocument = updated
                lastAppliedColumns = columns
                dirty = false
                persistenceAvailable = true
                showStatus("Saved \(columns.count.formatted()) columns · \(scopeDescription)", error: false)
                onSaved?(columns)
                onSuccess?()
            } catch is CancellationError {
                return
            } catch {
                self?.showStatus(error.localizedDescription, error: true)
            }
            self?.fileOperationTask = nil
            self?.updateActionAvailability()
        }
        updateActionAvailability()
    }

    @objc private func closeWindow() {
        guard let window else { return }
        approveDismissal { [weak self, weak window] in
            guard let self, let window else { return }
            self.windowDismissal.dismiss(window)
        }
    }

    fileprivate static func resultTypeTitle(_ type: ColumnResultType) -> String {
        switch type {
        case .resourceUsage: "Resource usage"
        default: type.rawValue.capitalized
        }
    }
}

@MainActor
final class NativeColumnPickerWindowController: NSWindowController,
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

        var exactSection: NSStackView?
        if exactResourceSupported {
            let separator = NSBox()
            separator.boxType = .separator
            let heading = NSTextField(labelWithString: "Arbitrary Exact Scheduler Resource")
            heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            let section = NSStackView(views: [separator, heading, exactGrid, exactFooter])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 7
            for view in [separator, exactGrid, exactFooter] {
                view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
            }
            exactSection = section
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

        let arrangedViews = [scrollView, catalogHelp]
            + [exactSection].compactMap { $0 }
            + [footer]
        let contentStack = NSStackView(views: arrangedViews)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.setCustomSpacing(14, after: exactSection ?? catalogHelp)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(.init(1), for: .vertical)

        let root = NSView()
        root.addSubview(contentStack)
        var constraints = [
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            catalogHelp.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ]
        if let exactSection {
            constraints.append(
                exactSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
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
final class CELColumnEditorWindowController: NSWindowController,
    NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate
{
    private let original: ColumnDefinition?
    private let reservedIDs: Set<String>
    private let previewProvider: any ColumnPreviewProviding
    private let previewContext: ColumnPreviewContext
    private let idField = NSTextField()
    private let titleField = NSTextField()
    private let expressionView = NSTextView()
    private let typeButton = NSPopUpButton()
    private let alignmentButton = NSPopUpButton()
    private let missingField = NSTextField()
    private let widthField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let examplesLabel = NSTextField(wrappingLabelWithString: "")
    private let previewStateLabel = NSTextField(labelWithString: "")
    private let previewValueLabel = NSTextField(wrappingLabelWithString: "")
    private let previewSourceLabel = NSTextField(labelWithString: "")
    private let previewEnvironmentLabel = NSTextField(labelWithString: "")
    private let commitButton = NSButton(title: "Add", target: nil, action: nil)
    private var previewValidation = ColumnPreviewValidationState()
    private var previewTask: Task<Void, Never>?

    var onCommit: ((ColumnDefinition) -> Void)?
    var onDismiss: (() -> Void)?

    init(
        definition: ColumnDefinition?,
        reservedIDs: Set<String>,
        previewProvider: any ColumnPreviewProviding,
        previewContext: ColumnPreviewContext
    ) {
        original = definition
        self.reservedIDs = reservedIDs
        self.previewProvider = previewProvider
        self.previewContext = previewContext
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = definition == nil ? "Add CEL Column" : "Edit CEL Column"
        panel.minSize = NSSize(width: 520, height: 700)
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
        idField.setAccessibilityLabel("Column ID")
        titleField.placeholderString = "Team"
        titleField.setAccessibilityLabel("Column title")
        missingField.placeholderString = "—"
        missingField.setAccessibilityLabel("Missing value")
        widthField.placeholderString = "Automatic"
        widthField.setAccessibilityLabel("Column width")
        for field in [idField, titleField, missingField, widthField] {
            field.alignment = .left
        }

        typeButton.addItems(withTitles: ColumnResultType.allCases.map(ColumnsManagerWindowController.resultTypeTitle))
        typeButton.alignment = .left
        typeButton.setAccessibilityLabel("Column result type")
        typeButton.target = self
        typeButton.action = #selector(choiceChanged)
        alignmentButton.addItems(withTitles: ColumnAlignment.allCases.map { $0.rawValue.capitalized })
        alignmentButton.alignment = .left
        alignmentButton.setAccessibilityLabel("Column alignment")
        alignmentButton.target = self
        alignmentButton.action = #selector(choiceChanged)

        expressionView.delegate = self
        expressionView.frame = NSRect(x: 0, y: 0, width: 560, height: 140)
        expressionView.isEditable = true
        expressionView.isSelectable = true
        expressionView.allowsUndo = true
        expressionView.isRichText = false
        expressionView.isVerticallyResizable = true
        expressionView.isHorizontallyResizable = false
        expressionView.autoresizingMask = [.width]
        expressionView.isAutomaticQuoteSubstitutionEnabled = false
        expressionView.isAutomaticDashSubstitutionEnabled = false
        expressionView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        expressionView.textContainerInset = NSSize(width: 6, height: 6)
        expressionView.textContainer?.widthTracksTextView = true
        expressionView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )
        expressionView.setAccessibilityLabel("CEL expression")
        let expressionScroll = NSScrollView()
        expressionScroll.documentView = expressionView
        expressionScroll.hasVerticalScroller = true
        expressionScroll.autohidesScrollers = true
        expressionScroll.borderType = .bezelBorder
        expressionScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let idRow = formRow("ID", idField)
        let titleRow = formRow("Title", titleField)
        let expressionRow = formRow("Expression", expressionScroll)
        let typeRow = formRow("Result type", typeButton)
        let alignmentRow = formRow("Alignment", alignmentButton)
        let missingRow = formRow("Missing value", missingField)
        let widthRow = formRow("Width", widthField)
        let formSections = [
            pairedFormRow(idRow, titleRow),
            expressionRow,
            pairedFormRow(typeRow, alignmentRow),
            pairedFormRow(missingRow, widthRow),
        ]
        let form = NSStackView(views: formSections)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(formSections.map {
            $0.widthAnchor.constraint(equalTo: form.widthAnchor)
        })

        let help = NSTextField(wrappingLabelWithString:
            "The Go engine compiles CEL against \(ColumnConfigurationSchema.celEnvironment) before activation. Live preview keeps showing the evaluated value while you fix a temporary type or expression mismatch."
        )
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        examplesLabel.stringValue = Self.examplesText(for: previewContext)
        examplesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        examplesLabel.textColor = .secondaryLabelColor
        examplesLabel.maximumNumberOfLines = 0
        examplesLabel.lineBreakMode = .byWordWrapping
        examplesLabel.setAccessibilityLabel("CEL examples and preview source")
        examplesLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previewStateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        previewValueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        previewValueLabel.maximumNumberOfLines = 6
        previewValueLabel.lineBreakMode = .byTruncatingTail
        previewValueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewSourceLabel.textColor = .secondaryLabelColor
        previewSourceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewEnvironmentLabel.textColor = .tertiaryLabelColor
        previewEnvironmentLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let previewStack = NSStackView(views: [
            previewStateLabel,
            previewValueLabel,
            previewSourceLabel,
            previewEnvironmentLabel,
        ])
        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 4
        previewStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        previewStack.wantsLayer = true
        previewStack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        previewStack.layer?.cornerRadius = 6

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.maximumNumberOfLines = 3
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        commitButton.title = original == nil ? "Add" : "Apply"
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = [.command]
        let footer = NSStackView(views: [errorLabel, NSView(), cancelButton, commitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [form, help, examplesLabel, previewStack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        form.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        examplesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        previewStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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

        idField.nextKeyView = titleField
        titleField.nextKeyView = expressionView
        expressionView.nextKeyView = typeButton
        typeButton.nextKeyView = alignmentButton
        alignmentButton.nextKeyView = missingField
        missingField.nextKeyView = widthField
        widthField.nextKeyView = cancelButton
        cancelButton.nextKeyView = commitButton
        commitButton.nextKeyView = idField
        panel.initialFirstResponder = idField
    }

    private func formRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        let row = NSStackView(views: [label, control])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    private func pairedFormRow(_ leading: NSStackView, _ trailing: NSStackView) -> NSStackView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    private static func examplesText(for context: ColumnPreviewContext) -> String {
        let resourceName = context.resource.kind.isEmpty
            ? context.resource.resource : context.resource.kind
        let source: String
        if let selected = context.selectedObject {
            let name = selected.namespace.isEmpty
                ? selected.name : selected.namespace + "/" + selected.name
            source = "Preview input: selected object " + name
                + ". It is fetched again by UID as you type."
        } else {
            source = "Preview input: safe sample " + resourceName
                + " object. Select one row before opening Columns to use its live fields."
        }
        return source + """
        Try these (the preview can show maps/lists while you explore):
          object.apiVersion            → string
          object.kind                  → string
          object.metadata.name       → string (for example, "sample")
          object.metadata.namespace  → string (for example, "default")
          object.metadata.labels["app"] → string (when present)
          object.metadata            → map (inspect all metadata fields; index a key for a string column)
          context.kind               → string
          now                        → timestamp
        Map/list values remain visible in the preview when temporarily invalid; transform them to a scalar before saving.
        """
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
        return locallyValidDefinition()
    }

    private func locallyValidDefinition() -> ColumnDefinition {
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
        previewTask?.cancel()
        previewTask = nil
        let message = validationMessage()
        guard message == nil else {
            _ = previewValidation.beginRevision(localFailure: message)
            renderPreviewValidation()
            return
        }

        let definition = locallyValidDefinition()
        let revision = previewValidation.beginRevision()
        renderPreviewValidation()
        let request = ColumnPreviewRequest(context: previewContext, column: definition)
        previewTask = Task { [weak self, previewProvider] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let result = try await previewProvider.previewColumn(request)
                guard !Task.isCancelled else { return }
                self?.acceptPreview(result, revision: revision)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.rejectPreview(error, revision: revision)
            }
        }
    }

    private func acceptPreview(_ result: ColumnPreviewResult, revision: UInt64) {
        guard previewValidation.accept(result, for: revision) else { return }
        previewTask = nil
        renderPreviewValidation()
    }

    private func rejectPreview(_ error: Error, revision: UInt64) {
        let message: String
        if let issue = error as? ClusterManagerIssue {
            let metadata = issue.presentationMetadata
            message = metadata.isEmpty ? issue.message : "\(issue.message) · \(metadata)"
        } else {
            message = error.localizedDescription
        }
        guard previewValidation.reject(message, for: revision) else { return }
        previewTask = nil
        renderPreviewValidation()
    }

    private func renderPreviewValidation() {
        commitButton.isEnabled = previewValidation.canCommit
        switch previewValidation.phase {
        case .idle:
            errorLabel.textColor = .systemRed
            previewStateLabel.textColor = .labelColor
            errorLabel.stringValue = ""
            previewStateLabel.stringValue = "Preview"
            previewValueLabel.stringValue = ""
            previewValueLabel.toolTip = nil
            previewSourceLabel.stringValue = ""
            previewEnvironmentLabel.stringValue = ""
        case .localFailure(let message):
            errorLabel.textColor = .systemRed
            previewStateLabel.textColor = .secondaryLabelColor
            errorLabel.stringValue = message
            previewStateLabel.stringValue = "Preview unavailable"
            previewValueLabel.stringValue = ""
            previewValueLabel.toolTip = nil
            previewSourceLabel.stringValue = ""
            previewEnvironmentLabel.stringValue = ""
        case .validating:
            errorLabel.textColor = .systemRed
            previewStateLabel.textColor = .secondaryLabelColor
            errorLabel.stringValue = ""
            previewStateLabel.stringValue = "Validating…"
            previewValueLabel.stringValue = ""
            previewValueLabel.toolTip = nil
            previewSourceLabel.stringValue = previewContext.selectedObject == nil
                ? "Using sample object for this preview"
                : "Using selected object (fresh UID-pinned lookup)"
            previewEnvironmentLabel.stringValue = ""
        case .failed(let message):
            errorLabel.textColor = .systemRed
            previewStateLabel.textColor = .systemRed
            errorLabel.stringValue = message
            previewStateLabel.stringValue = "Preview failed"
            previewValueLabel.stringValue = ""
            previewValueLabel.toolTip = nil
            previewSourceLabel.stringValue = ""
            previewEnvironmentLabel.stringValue = ""
        case .succeeded(let result):
            let issue = result.validationIssue
            let invalid = issue != nil
            errorLabel.textColor = invalid ? .systemOrange : .systemRed
            previewStateLabel.textColor = invalid ? .systemOrange : .labelColor
            if let issue {
                let metadata = issue.presentationMetadata
                let suffix = metadata.isEmpty ? "" : " · \(metadata)"
                errorLabel.stringValue = "Result is not valid for this column: \(issue.message)\(suffix)"
            } else {
                errorLabel.stringValue = ""
            }
            previewStateLabel.stringValue = invalid ? "Preview (invalid result)" : "Preview"
            previewValueLabel.stringValue = result.preview.displayText.isEmpty
                ? "(empty value)" : result.preview.displayText
            previewValueLabel.toolTip = result.preview.tooltip.isEmpty
                ? result.preview.displayText : result.preview.tooltip
            if result.usedSampleObject {
                previewSourceLabel.stringValue = "Using sample object"
            } else if let identity = result.evaluatedObject {
                let name = identity.namespace.isEmpty
                    ? identity.name : "\(identity.namespace)/\(identity.name)"
                previewSourceLabel.stringValue = "Using selected object: \(name)"
            } else {
                previewSourceLabel.stringValue = "Using selected object"
            }
            if invalid, !result.preview.tooltip.isEmpty {
                previewEnvironmentLabel.stringValue =
                    "CEL environment: \(result.celEnvironment) · \(result.preview.tooltip)"
            } else {
                previewEnvironmentLabel.stringValue = "CEL environment: \(result.celEnvironment)"
            }
        }
    }

    @objc private func choiceChanged() { validate() }

    @objc private func commit() {
        guard previewValidation.canCommit,
            let definition = definitionFromControls(), let sheet = window,
            let parent = sheet.sheetParent
        else { return }
        previewTask?.cancel()
        previewTask = nil
        onCommit?(definition)
        parent.endSheet(sheet, returnCode: .OK)
    }

    @objc private func cancel() {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        previewTask?.cancel()
        previewTask = nil
        parent.endSheet(sheet, returnCode: .cancel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let parent = sender.sheetParent {
            previewTask?.cancel()
            previewTask = nil
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
