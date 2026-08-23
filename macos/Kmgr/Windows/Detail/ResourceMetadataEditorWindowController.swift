import AppKit
import KmgrCore

/// A kind-specific labels or annotations editor. It loads one authoritative,
/// UID-pinned object snapshot and submits only the sparse changes made against
/// that resource version. Failed saves retain the complete local draft.
@MainActor
final class ResourceMetadataEditorWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSTextViewDelegate, NSTextFieldDelegate, ContextualShortcutProviding
{
    private enum RowState: String {
        case saved = "Saved"
        case added = "Added"
        case modified = "Modified"
        case deleted = "Deleted"
    }

    private let session: OpenedClusterSession
    private let identity: ResourceIdentity
    let kind: ResourceMetadataKind
    private let initialKey: String?
    private let detailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let tableLayoutStore: TableLayoutStore

    private let splitView = KeyValueEditorSplitView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let keysTable = KeyValueEditorTableView()
    private let keysScroll = NSScrollView()
    private let newKeyField = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let keyField = NSTextField()
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let stateLabel = NSTextField(labelWithString: "")
    private let valueTextView = NSTextView()
    private let valueScroll = NSScrollView()
    private let instructionLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var draft: ResourceMetadataDraft?
    private var expectedResourceVersion: String?
    private var visibleKeys: [String] = []
    private var selectedKey: String?
    private var isInstallingState = false
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var parentWindow: NSWindow?
    private var tableLayoutBinding: TableLayoutBinding?
    private var didDismiss = false

    var onSaved: (() -> Void)?
    var onDismiss: (() -> Void)?
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        ContextualShortcutCatalog.metadataEditor(kind: kind)
    }

    init(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        kind: ResourceMetadataKind,
        initialKey: String? = nil,
        detailProvider: any ObjectDetailProviding,
        operationProvider: any ResourceOperationProviding,
        tableLayoutStore: TableLayoutStore? = nil
    ) {
        self.session = session
        self.identity = identity
        self.kind = kind
        self.initialKey = initialKey
        self.detailProvider = detailProvider
        self.operationProvider = operationProvider
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 570),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let cluster = ClusterIdentityPresentation(session: session)
        panel.title = "\(cluster.titlePrefix) — Edit \(kind.title)"
        panel.minSize = NSSize(width: 720, height: 460)
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configure(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        operationTask?.cancel()
    }

    func beginSheet(for parent: NSWindow) {
        guard let window else { return }
        parentWindow = parent
        parent.beginSheet(window)
        loadMetadata()
    }

    func dismissForEngineRecovery() {
        loadTask?.cancel()
        operationTask?.cancel()
        loadTask = nil
        operationTask = nil
        dismissSheet()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard operationTask == nil else {
            NSSound.beep()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        finishDismissal()
    }

    private func configure(in panel: NSPanel) {
        let target = NSTextField(wrappingLabelWithString:
            ClusterIdentityPresentation(session: session).targetDetails(identity)
        )
        target.lineBreakMode = .byTruncatingMiddle
        target.setAccessibilityLabel("Metadata editor target")
        instructionLabel.stringValue = kind.setInstruction
        instructionLabel.textColor = .secondaryLabelColor
        instructionLabel.setAccessibilityLabel("\(kind.title) editing rules")

        configureKeyPane()
        configureValuePane()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.identifier = .init("resource-metadata-editor-split")
        splitView.autosaveName = "kmgr.resource-metadata-master-detail"
        splitView.preferredLeadingFraction = 0.46
        splitView.paneMinimumsProvider = {
            KeyValueEditorSplitView.PaneMinimums(leading: 280, trailing: 300)
        }
        splitView.onDidResize = { [weak self] in
            guard let self else { return }
            TextDocumentGeometry.update(
                self.valueTextView,
                in: self.valueScroll,
                wrapsToViewport: true
            )
        }

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Metadata save in progress")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Metadata editor status")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        let footer = NSStackView(views: [
            progress, statusLabel, NSView(), cancelButton, saveButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let root = NSView()
        target.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        for child in [target, instructionLabel, splitView, footer] {
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            target.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            target.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            instructionLabel.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            instructionLabel.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            instructionLabel.topAnchor.constraint(equalTo: target.bottomAnchor, constant: 5),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        panel.contentView = root
        updateControls()
    }

    private func configureKeyPane() {
        for (identifier, title, width, minimumWidth) in [
            ("key", "Key", CGFloat(210), CGFloat(120)),
            ("value", "Value", CGFloat(240), CGFloat(120)),
            ("state", "State", CGFloat(82), CGFloat(68)),
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = minimumWidth
            column.resizingMask = .userResizingMask
            keysTable.addTableColumn(column)
        }
        keysTable.delegate = self
        keysTable.dataSource = self
        keysTable.usesAlternatingRowBackgroundColors = true
        keysTable.allowsEmptySelection = true
        keysTable.allowsMultipleSelection = false
        keysTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        keysTable.setAccessibilityLabel("\(kind.title) keys and values")
        keysTable.onFocusSearch = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
        }
        keysTable.onActivateValue = { [weak self] in
            guard let self, self.valueTextView.isEditable else { return }
            self.window?.makeFirstResponder(self.valueTextView)
        }
        keysTable.onBack = { [weak self] in self?.cancel() }
        tableLayoutBinding = TableLayoutBinding(
            tableView: keysTable,
            surface: .objectMetadataKeys,
            store: tableLayoutStore
        )
        keysScroll.documentView = keysTable
        keysScroll.hasVerticalScroller = true
        keysScroll.hasHorizontalScroller = true
        keysScroll.autohidesScrollers = true
        keysScroll.identifier = .init("resource-metadata-keys-scroll")

        searchField.placeholderString = "Search keys and values"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search \(kind.title.lowercased())")
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        let searchRow = NSStackView(views: [searchField, countLabel])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8

        newKeyField.placeholderString = "New \(kind.singularTitle.lowercased()) key"
        newKeyField.delegate = self
        newKeyField.target = self
        newKeyField.action = #selector(addKey)
        newKeyField.setAccessibilityLabel("New \(kind.singularTitle.lowercased()) key")
        addButton.target = self
        addButton.action = #selector(addKey)
        deleteButton.target = self
        deleteButton.action = #selector(deleteKey)
        revertButton.target = self
        revertButton.action = #selector(revertKey)
        for button in [addButton, deleteButton, revertButton] {
            button.controlSize = .small
        }
        let addRow = NSStackView(views: [newKeyField, addButton])
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 6
        let actions = NSStackView(views: [deleteButton, revertButton, NSView()])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let pane = NSView()
        pane.identifier = .init("resource-metadata-keys-pane")
        for child in [searchRow, addRow, actions, keysScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(child)
        }
        NSLayoutConstraint.activate([
            searchRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            searchRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            searchRow.topAnchor.constraint(equalTo: pane.topAnchor, constant: 7),
            addRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            addRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            addRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            actions.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            actions.topAnchor.constraint(equalTo: addRow.bottomAnchor, constant: 5),
            keysScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            keysScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            keysScroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 6),
            keysScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        splitView.addArrangedSubview(pane)
    }

    private func configureValuePane() {
        let keyLabel = NSTextField(labelWithString: "Key")
        keyLabel.setAccessibilityLabel("Selected metadata key label")
        keyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        keyField.delegate = self
        keyField.target = self
        keyField.action = #selector(renameKey)
        keyField.setAccessibilityLabel("Selected \(kind.singularTitle.lowercased()) key")
        renameButton.target = self
        renameButton.action = #selector(renameKey)
        renameButton.controlSize = .small
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .right
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setAccessibilityLabel("Selected metadata entry state")
        let header = NSStackView(views: [keyLabel, keyField, renameButton, stateLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7

        valueTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueTextView.isRichText = false
        valueTextView.isEditable = false
        valueTextView.isSelectable = true
        valueTextView.allowsUndo = true
        valueTextView.isAutomaticQuoteSubstitutionEnabled = false
        valueTextView.isAutomaticDashSubstitutionEnabled = false
        valueTextView.isAutomaticTextReplacementEnabled = false
        valueTextView.isAutomaticSpellingCorrectionEnabled = false
        valueTextView.delegate = self
        valueTextView.setAccessibilityLabel("Selected \(kind.singularTitle.lowercased()) value")
        valueScroll.documentView = valueTextView
        valueScroll.hasVerticalScroller = true
        valueScroll.hasHorizontalScroller = false
        valueScroll.identifier = .init("resource-metadata-value-scroll")
        TextDocumentGeometry.configure(
            valueTextView,
            in: valueScroll,
            wrapsToViewport: true
        )

        let pane = NSView()
        pane.identifier = .init("resource-metadata-value-pane")
        header.translatesAutoresizingMaskIntoConstraints = false
        valueScroll.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(header)
        pane.addSubview(valueScroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 7),
            valueScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            valueScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            valueScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            valueScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        splitView.addArrangedSubview(pane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }

    private func loadMetadata() {
        guard loadTask == nil, draft == nil else { return }
        setStatus("Loading current \(kind.title.lowercased())…", busy: true)
        updateControls()
        loadTask = Task { [weak self, detailProvider, identity, kind] in
            guard let self else { return }
            defer {
                loadTask = nil
                updateControls()
            }
            do {
                let detail = try await detailProvider.getObject(identity: identity)
                guard !Task.isCancelled else { return }
                let target = try OptimisticResourceMutationTarget(
                    selectedIdentity: identity,
                    authoritativeDetail: detail
                )
                expectedResourceVersion = target.expectedResourceVersion
                draft = ResourceMetadataDraft(
                    kind: kind,
                    baselineValues: kind.values(in: detail)
                )
                rebuildVisibleKeys(selecting: initialKey)
                setStatus(
                    "Resource version \(target.expectedResourceVersion) · \(draft?.allKeys.count ?? 0) \(kind.title.lowercased())"
                )
                window?.makeFirstResponder(
                    draft?.allKeys.isEmpty == true ? newKeyField : keysTable
                )
            } catch {
                guard !Task.isCancelled else { return }
                show(error)
            }
        }
    }

    @objc private func searchChanged() {
        captureSelectedValue()
        rebuildVisibleKeys(selecting: selectedKey)
    }

    @objc private func addKey() {
        guard draft != nil, operationTask == nil else { return }
        let key = newKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            window?.makeFirstResponder(newKeyField)
            return
        }
        captureSelectedValue()
        guard var draft = self.draft else { return }
        do {
            try draft.addKey(key)
            self.draft = draft
            newKeyField.stringValue = ""
            searchField.stringValue = ""
            rebuildVisibleKeys(selecting: key)
            setStatus("Added \(kind.singularTitle.lowercased()) \(key)")
            window?.makeFirstResponder(valueTextView)
        } catch {
            show(error)
            window?.makeFirstResponder(newKeyField)
        }
    }

    @objc private func renameKey() {
        guard let selectedKey, draft?.value(for: selectedKey) != nil,
            operationTask == nil
        else { return }
        captureSelectedValue()
        guard var draft = self.draft else { return }
        let newKey = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newKey != selectedKey else { return }
        do {
            try draft.renameKey(selectedKey, to: newKey)
            self.draft = draft
            searchField.stringValue = ""
            rebuildVisibleKeys(selecting: newKey)
            setStatus("Renamed \(kind.singularTitle.lowercased()) to \(newKey)")
        } catch {
            show(error)
            window?.makeFirstResponder(keyField)
        }
    }

    @objc private func deleteKey() {
        guard let selectedKey, draft?.value(for: selectedKey) != nil,
            operationTask == nil
        else { return }
        captureSelectedValue()
        guard var draft = self.draft else { return }
        let wasAdded = draft.isAdded(selectedKey)
        draft.removeKey(selectedKey)
        self.draft = draft
        rebuildVisibleKeys(selecting: selectedKey)
        setStatus(
            wasAdded
                ? "Discarded added \(kind.singularTitle.lowercased()) \(selectedKey)"
                : "Marked \(selectedKey) for deletion"
        )
    }

    @objc private func revertKey() {
        guard let selectedKey, var draft, draft.isChanged(selectedKey),
            operationTask == nil
        else { return }
        draft.revertKey(selectedKey)
        self.draft = draft
        rebuildVisibleKeys(selecting: selectedKey)
        setStatus("Reverted \(selectedKey)")
    }

    @objc private func save() {
        guard operationTask == nil, draft != nil,
            let expectedResourceVersion
        else { return }
        captureSelectedValue()
        guard let draft = self.draft else { return }
        let changes: ResourceMetadataChanges
        do {
            changes = try draft.changes()
        } catch {
            show(error)
            return
        }
        setStatus("Saving \(kind.title.lowercased())…", busy: true)
        updateControls()
        operationTask = Task { [weak self, operationProvider, identity] in
            guard let self else { return }
            defer {
                operationTask = nil
                progress.stopAnimation(nil)
                updateControls()
            }
            do {
                let stream = try await operationProvider.updateMetadata(
                    identity: identity,
                    expectedResourceVersion: expectedResourceVersion,
                    changes: changes
                )
                for try await value in stream {
                    guard !Task.isCancelled else { return }
                    setStatus(
                        "Saving… \(value.completedItems)/\(value.totalItems)",
                        busy: !value.state.isTerminal
                    )
                    guard value.state.isTerminal else { continue }
                    guard value.state == .succeeded else {
                        throw value.issue ?? ClusterManagerIssue(
                            category: .internalFailure,
                            reason: "MetadataMutationFailed",
                            message: "The Kubernetes metadata mutation did not succeed. Your local edits are still open.",
                            contextName: session.contextName,
                            operation: "edit \(kind.title.lowercased())"
                        )
                    }
                    onSaved?()
                    dismissSheet()
                    return
                }
                throw ClusterManagerIssue(
                    category: .unavailable,
                    reason: "MetadataMutationEnded",
                    message: "The metadata mutation ended without a final result. Your local edits are still open.",
                    retryable: true,
                    contextName: session.contextName,
                    operation: "edit \(kind.title.lowercased())"
                )
            } catch {
                guard !Task.isCancelled else { return }
                show(error)
            }
        }
    }

    @objc private func cancel() {
        guard operationTask == nil else {
            NSSound.beep()
            return
        }
        dismissSheet()
    }

    @objc func saveDocument(_ sender: Any?) {
        if saveButton.isEnabled { save() }
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateControls()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === valueTextView,
            !isInstallingState, let selectedKey, var draft,
            draft.value(for: selectedKey) != nil
        else { return }
        draft.setValue(valueTextView.string, for: selectedKey)
        self.draft = draft
        reloadSelectedRow()
        updateSelectedStatePresentation(selectedKey, in: draft)
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleKeys.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visibleKeys.indices.contains(row), let tableColumn,
            let draft
        else { return nil }
        let key = visibleKeys[row]
        let state = rowState(key, in: draft)
        let value: String
        switch tableColumn.identifier.rawValue {
        case "key": value = key
        case "value":
            value = valuePreview(draft.value(for: key) ?? draft.baselineValue(for: key) ?? "")
        case "state": value = state.rawValue
        default: value = ""
        }
        let cell = textCell(value, table: tableView, column: tableColumn)
        cell.setAccessibilityLabel(tableColumn.title)
        cell.setAccessibilityValue(value)
        cell.textField?.textColor = tableColumn.identifier.rawValue == "state"
            && state != .saved ? stateColor(state) : .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === keysTable,
            !isInstallingState
        else { return }
        captureSelectedValue()
        guard visibleKeys.indices.contains(keysTable.selectedRow) else {
            selectKey(nil)
            return
        }
        selectKey(visibleKeys[keysTable.selectedRow])
    }

    private func captureSelectedValue() {
        guard !isInstallingState, let selectedKey, var draft,
            draft.value(for: selectedKey) != nil
        else { return }
        draft.setValue(valueTextView.string, for: selectedKey)
        self.draft = draft
    }

    private func rebuildVisibleKeys(selecting preferredKey: String?) {
        guard let draft else {
            visibleKeys = []
            keysTable.reloadData()
            selectKey(nil)
            return
        }
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allKeys = draft.allKeys
        if query.isEmpty {
            visibleKeys = allKeys
        } else {
            visibleKeys = allKeys.filter { key in
                key.lowercased().contains(query)
                    || (draft.value(for: key) ?? draft.baselineValue(for: key) ?? "")
                        .lowercased().contains(query)
            }
        }
        keysTable.reloadData()
        countLabel.stringValue = query.isEmpty
            ? "\(allKeys.count.formatted())"
            : "\(visibleKeys.count.formatted()) of \(allKeys.count.formatted())"

        let selection = preferredKey.flatMap { key in
            visibleKeys.firstIndex(of: key)
        } ?? visibleKeys.indices.first
        isInstallingState = true
        if let selection {
            keysTable.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
            selectKey(visibleKeys[selection])
        } else {
            keysTable.deselectAll(nil)
            selectKey(nil)
        }
        isInstallingState = false
        updateControls()
    }

    private func selectKey(_ key: String?) {
        selectedKey = key
        updateSelectionPresentation()
        updateControls()
    }

    private func updateSelectionPresentation() {
        let wasInstalling = isInstallingState
        isInstallingState = true
        defer { isInstallingState = wasInstalling }
        guard let selectedKey, let draft else {
            keyField.stringValue = ""
            stateLabel.stringValue = ""
            valueTextView.string = draft == nil
                ? "Loading current metadata…"
                : "No \(kind.title.lowercased()). Enter a key on the left to add one."
            valueTextView.undoManager?.removeAllActions()
            return
        }
        keyField.stringValue = selectedKey
        updateSelectedStatePresentation(selectedKey, in: draft)
        valueTextView.string = draft.value(for: selectedKey)
            ?? draft.baselineValue(for: selectedKey) ?? ""
        valueTextView.undoManager?.removeAllActions()
    }

    private func updateSelectedStatePresentation(
        _ key: String,
        in draft: ResourceMetadataDraft
    ) {
        let state = rowState(key, in: draft)
        stateLabel.stringValue = state.rawValue
        stateLabel.textColor = stateColor(state)
    }

    private func updateControls() {
        let idle = loadTask == nil && operationTask == nil
        let loaded = draft != nil && expectedResourceVersion != nil
        let currentExists = selectedKey.flatMap { draft?.value(for: $0) } != nil
        let currentChanged = selectedKey.map { draft?.isChanged($0) == true } == true
        newKeyField.isEnabled = idle && loaded
        addButton.isEnabled = idle && loaded
            && !newKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        keyField.isEnabled = idle && currentExists
        renameButton.isEnabled = idle && currentExists
            && selectedKey != keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteButton.isEnabled = idle && currentExists
        revertButton.isEnabled = idle && currentChanged
        valueTextView.isEditable = idle && currentExists
        valueTextView.isSelectable = loaded
        saveButton.isEnabled = idle && loaded && draft?.hasChanges == true
        cancelButton.isEnabled = operationTask == nil
        if loadTask != nil || operationTask != nil {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private func rowState(_ key: String, in draft: ResourceMetadataDraft) -> RowState {
        if draft.isDeleted(key) { return .deleted }
        if draft.isAdded(key) { return .added }
        if draft.isChanged(key) { return .modified }
        return .saved
    }

    private func stateColor(_ state: RowState) -> NSColor {
        switch state {
        case .saved: .secondaryLabelColor
        case .added: .systemGreen
        case .modified: .systemOrange
        case .deleted: .systemRed
        }
    }

    private func valuePreview(_ value: String) -> String {
        let maximumCharacters = 160
        var preview = ""
        preview.reserveCapacity(maximumCharacters)
        var characterCount = 0
        var pendingSpace = false
        for character in value {
            let collapsible = character.isWhitespace || character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
            if collapsible {
                pendingSpace = characterCount > 0
                continue
            }
            let needed = (pendingSpace ? 1 : 0) + 1
            if characterCount + needed > maximumCharacters {
                while characterCount > maximumCharacters - 1 {
                    preview.removeLast()
                    characterCount -= 1
                }
                return preview + "…"
            }
            if pendingSpace {
                preview.append(" ")
                characterCount += 1
                pendingSpace = false
            }
            preview.append(character)
            characterCount += 1
        }
        return preview.isEmpty ? "—" : preview
    }

    private func textCell(
        _ value: String,
        table: NSTableView,
        column: NSTableColumn
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(
            "metadata.\(column.identifier.rawValue)"
        )
        let cell = table.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
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
        }
        cell.textField?.stringValue = value
        cell.textField?.toolTip = value
        return cell
    }

    private func reloadSelectedRow() {
        guard let selectedKey,
            let row = visibleKeys.firstIndex(of: selectedKey)
        else { return }
        keysTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(
            integersIn: 0..<keysTable.numberOfColumns
        ))
    }

    private func setStatus(_ text: String, busy: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.toolTip = nil
        statusLabel.textColor = .secondaryLabelColor
        if busy { progress.startAnimation(nil) }
    }

    private func show(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.inlineText
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
        progress.stopAnimation(nil)
        updateControls()
    }

    private func dismissSheet() {
        loadTask?.cancel()
        loadTask = nil
        guard let window else { return }
        if let parentWindow, window.sheetParent === parentWindow {
            parentWindow.endSheet(window)
        }
        window.orderOut(nil)
        finishDismissal()
    }

    private func finishDismissal() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismiss?()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.setAccessibilityLabel("Edit Kubernetes \(kind.title.lowercased())")
    }

}
