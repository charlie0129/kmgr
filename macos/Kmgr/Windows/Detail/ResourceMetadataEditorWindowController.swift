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
        case renamed = "Renamed"
        case deleted = "Deleted"
    }

    private let session: OpenedClusterSession
    private let identity: ResourceIdentity
    let kind: ResourceMetadataKind
    private let initialKey: String?
    private let detailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let changeConfirmation: (@MainActor (
        KeyValueDiffConfirmationWindowController
    ) async -> KeyValueDiffConfirmationWindowController.Choice)?
    private let discardChangesConfirmation: (@MainActor () -> Bool)?
    private let keyPrompt: (@MainActor (KeyValueEditorKeyPrompt.Request) -> String?)?

    private let editorView: KeyValueEditorView
    private var splitView: KeyValueEditorSplitView { editorView.splitView }
    private var searchField: NSSearchField { editorView.searchField }
    private var countLabel: NSTextField { editorView.resultLabel }
    private var keysTable: KeyValueEditorTableView { editorView.tableView }
    private var valueTextView: NSTextView { editorView.valueTextView }
    private var valueScrollView: NSScrollView { editorView.valueScrollView }
    private let addButton = NSButton(title: "Add Key", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Key", target: nil, action: nil)
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    private let instructionLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Changes", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var draft: ResourceMetadataDraft?
    private var expectedResourceVersion: String?
    private var visibleKeys: [String] = []
    private var appliedSearchQuery = ""
    private var selectedKey: String?
    private var isInstallingState = false
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var reviewController: KeyValueDiffConfirmationWindowController?
    private var parentWindow: NSWindow?
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
        tableLayoutStore: TableLayoutStore? = nil,
        changeConfirmation: (@MainActor (
            KeyValueDiffConfirmationWindowController
        ) async -> KeyValueDiffConfirmationWindowController.Choice)? = nil,
        discardChangesConfirmation: (@MainActor () -> Bool)? = nil,
        keyPrompt: (@MainActor (KeyValueEditorKeyPrompt.Request) -> String?)? = nil
    ) {
        let resolvedTableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.session = session
        self.identity = identity
        self.kind = kind
        self.initialKey = initialKey
        self.detailProvider = detailProvider
        self.operationProvider = operationProvider
        self.changeConfirmation = changeConfirmation
        self.discardChangesConfirmation = discardChangesConfirmation
        self.keyPrompt = keyPrompt
        self.editorView = KeyValueEditorView(
            configuration: Self.editorConfiguration(kind: kind),
            tableLayoutStore: resolvedTableLayoutStore
        )

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
        reviewTask?.cancel()
    }

    private static func editorConfiguration(
        kind: ResourceMetadataKind
    ) -> KeyValueEditorView.Configuration {
        KeyValueEditorView.Configuration(
            identifierPrefix: "resource-metadata-editor",
            splitAutosaveName: "kmgr.resource-metadata-master-detail",
            tableAccessibilityLabel: "\(kind.title) keys and values",
            valueAccessibilityLabel: "Selected \(kind.singularTitle.lowercased()) value",
            tableSurface: .objectMetadataKeys,
            columns: [
                .init(id: "key", title: "Key", width: 210, minimumWidth: 120),
                .init(id: "value", title: "Value", width: 240, minimumWidth: 120),
                .init(id: "state", title: "State", width: 82, minimumWidth: 68),
            ],
            preferredLeadingFraction: 0.46,
            paneMinimums: .init(leading: 280, trailing: 300)
        )
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
        reviewTask?.cancel()
        reviewController?.cancelReview()
        loadTask = nil
        operationTask = nil
        reviewTask = nil
        reviewController = nil
        dismissSheet()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard operationTask == nil, reviewTask == nil,
            reviewController == nil
        else {
            NSSound.beep()
            return false
        }
        captureSelectedValue()
        return shouldDiscardChangesIfNeeded()
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

        configureEditor()

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
        let footer = NSStackView(views: [progress, statusLabel, NSView(), cancelButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let root = NSView()
        target.translatesAutoresizingMaskIntoConstraints = false
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        editorView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        for child in [target, instructionLabel, editorView, footer] {
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            target.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            target.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            target.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            instructionLabel.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            instructionLabel.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            instructionLabel.topAnchor.constraint(equalTo: target.bottomAnchor, constant: 5),
            editorView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: instructionLabel.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            footer.topAnchor.constraint(equalTo: editorView.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        panel.contentView = root
        updateControls()
    }

    private func configureEditor() {
        keysTable.delegate = self
        keysTable.dataSource = self
        keysTable.onFocusSearch = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
        }
        keysTable.onActivateValue = { [weak self] in
            guard let self, self.valueTextView.isEditable else { return }
            self.window?.makeFirstResponder(self.valueTextView)
        }
        keysTable.onBack = { [weak self] in self?.cancel() }

        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search \(kind.title.lowercased())")
        addButton.target = self
        addButton.action = #selector(addKey)
        renameButton.target = self
        renameButton.action = #selector(renameKey)
        deleteButton.target = self
        deleteButton.action = #selector(deleteKey)
        revertButton.target = self
        revertButton.action = #selector(revertKey)
        valueTextView.delegate = self
        for button in [addButton, renameButton, deleteButton, revertButton, saveButton] {
            button.controlSize = .small
        }
        editorView.setLeadingActionViews([
            addButton, renameButton, deleteButton, NSView(),
        ])
        editorView.setHeaderActionViews([saveButton])
        editorView.setTrailingActionViews([revertButton, NSView()])
        editorView.selectedKeyLabel.setAccessibilityLabel(
            "Selected \(kind.singularTitle.lowercased()) key"
        )
        editorView.selectedKeyDetailsLabel.setAccessibilityLabel(
            "Selected metadata entry state"
        )
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
                    draft?.allKeys.isEmpty == true ? addButton : keysTable
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
        guard draft != nil, editorInteractionIdle else { return }
        let request = KeyValueEditorKeyPrompt.Request(
            action: .add,
            singularTitle: kind.singularTitle,
            currentValue: nil,
            informativeText: mutationTargetDetails(
                note: "The new \(kind.singularTitle.lowercased()) remains local until Save Changes."
            )
        )
        let requestedKey = keyPrompt.map { $0(request) }
            ?? KeyValueEditorKeyPrompt.run(request)
        guard let key = requestedKey else { return }
        captureSelectedValue()
        guard var draft = self.draft else { return }
        do {
            try draft.addKey(key)
            self.draft = draft
            searchField.stringValue = ""
            rebuildVisibleKeys(selecting: key)
            setStatus(
                "Added \(kind.singularTitle.lowercased()) \(key) locally · Save Changes to apply"
            )
            window?.makeFirstResponder(valueTextView)
        } catch {
            show(error)
        }
    }

    @objc private func renameKey() {
        guard let selectedKey, draft?.value(for: selectedKey) != nil,
            editorInteractionIdle
        else { return }
        captureSelectedValue()
        guard var draft = self.draft else { return }
        let request = KeyValueEditorKeyPrompt.Request(
            action: .rename,
            singularTitle: kind.singularTitle,
            currentValue: selectedKey,
            informativeText: mutationTargetDetails(
                note: "The rename remains local until Save Changes."
            )
        )
        let requestedKey = keyPrompt.map { $0(request) }
            ?? KeyValueEditorKeyPrompt.run(request)
        guard let newKey = requestedKey else { return }
        guard newKey != selectedKey else { return }
        do {
            try draft.renameKey(selectedKey, to: newKey)
            self.draft = draft
            searchField.stringValue = ""
            rebuildVisibleKeys(selecting: newKey)
            setStatus(
                "Renamed \(selectedKey) to \(newKey) locally · Save Changes to apply"
            )
        } catch {
            show(error)
        }
    }

    @objc private func deleteKey() {
        guard let selectedKey, draft?.value(for: selectedKey) != nil,
            editorInteractionIdle
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
            editorInteractionIdle
        else { return }
        let preferredKey = draft.renameSource(for: selectedKey) ?? selectedKey
        draft.revertKey(selectedKey)
        self.draft = draft
        rebuildVisibleKeys(selecting: preferredKey)
        setStatus("Reverted \(selectedKey)")
    }

    @objc private func save() {
        guard editorInteractionIdle, draft != nil,
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
        let inputs = draft.changeList.map { change in
            KeyValueDiffInput(
                beforeKey: change.beforeKey,
                afterKey: change.afterKey,
                beforeKind: change.beforeValue == nil ? nil : .text,
                beforeValue: change.beforeValue.map { Data($0.utf8) },
                afterKind: change.afterValue == nil ? nil : .text,
                afterValue: change.afterValue.map { Data($0.utf8) },
                sensitive: false
            )
        }
        reviewChanges(
            inputs: inputs,
            changes: changes,
            expectedResourceVersion: expectedResourceVersion
        )
    }

    private func reviewChanges(
        inputs: [KeyValueDiffInput],
        changes: ResourceMetadataChanges,
        expectedResourceVersion: String
    ) {
        guard !inputs.isEmpty, let parent = window else { return }
        setStatus("Preparing change review…", busy: true)
        updateControls()
        reviewTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer { finishReviewIfNeeded() }
            let controller = KeyValueDiffConfirmationWindowController(
                editorTitle: kind.title,
                targetDetails: mutationTargetDetails(note: kind.setInstruction),
                inputs: inputs
            )
            reviewController = controller
            setStatus("Review \(inputs.count.formatted()) staged changes")
            updateControls()
            let choice: KeyValueDiffConfirmationWindowController.Choice
            if let changeConfirmation {
                choice = await changeConfirmation(controller)
            } else {
                choice = await controller.runSheet(for: parent)
            }
            controller.discardTransientPresentation()
            guard !Task.isCancelled, reviewController === controller else { return }
            reviewController = nil
            reviewTask = nil
            updateControls()
            switch choice {
            case .save:
                submitChanges(
                    changes,
                    expectedResourceVersion: expectedResourceVersion
                )
            case .keepEditing:
                setStatus("Save cancelled · local changes preserved")
                window?.makeFirstResponder(keysTable)
            }
        }
    }

    private func submitChanges(
        _ changes: ResourceMetadataChanges,
        expectedResourceVersion: String
    ) {
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

    private func finishReviewIfNeeded() {
        guard reviewTask != nil || reviewController != nil else { return }
        reviewController?.discardTransientPresentation()
        reviewController = nil
        reviewTask = nil
        updateControls()
    }

    @objc private func cancel() {
        guard operationTask == nil, reviewTask == nil,
            reviewController == nil
        else {
            NSSound.beep()
            return
        }
        captureSelectedValue()
        guard shouldDiscardChangesIfNeeded() else { return }
        dismissSheet()
    }

    @objc func saveDocument(_ sender: Any?) {
        if saveButton.isEnabled { save() }
    }

    override func cancelOperation(_ sender: Any?) {
        if leaveValueEditorIfActive() { return }
        cancel()
    }

    private func leaveValueEditorIfActive() -> Bool {
        guard let window,
            let responderView = window.firstResponder as? NSView,
            responderView === valueTextView
                || responderView.isDescendant(of: valueScrollView)
        else { return false }
        captureSelectedValue()
        window.makeFirstResponder(keysTable)
        return true
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
        editorView.updateSyntaxHighlighting(key: selectedKey, isTextValue: true)
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
        if !appliedSearchQuery.isEmpty {
            editorView.applySearchHighlight(
                to: cell.textField,
                query: appliedSearchQuery
            )
        }
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
        let query = KeyValueTextSearch.normalizedQuery(searchField.stringValue)
        appliedSearchQuery = query
        let allKeys = draft.allKeys
        if query.isEmpty {
            visibleKeys = allKeys
        } else {
            visibleKeys = allKeys.filter { key in
                KeyValueTextSearch.contains(key, query: query)
                    || KeyValueTextSearch.contains(
                        draft.value(for: key) ?? draft.baselineValue(for: key) ?? "",
                        query: query
                    )
            }
        }
        keysTable.reloadData()
        countLabel.stringValue = query.isEmpty
            ? "\(allKeys.count.formatted()) key\(allKeys.count == 1 ? "" : "s")"
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
            editorView.selectedKeyLabel.stringValue = "No key selected"
            editorView.selectedKeyLabel.setAccessibilityValue("No key selected")
            editorView.selectedKeyDetailsLabel.stringValue = ""
            editorView.selectedKeyDetailsLabel.setAccessibilityValue("")
            valueTextView.string = draft == nil
                ? "Loading current metadata…"
                : "No \(kind.title.lowercased()). Use Add Key to create one."
            valueTextView.undoManager?.removeAllActions()
            editorView.clearSyntaxHighlighting()
            return
        }
        editorView.selectedKeyLabel.stringValue = selectedKey
        editorView.selectedKeyLabel.toolTip = selectedKey
        editorView.selectedKeyLabel.setAccessibilityValue(selectedKey)
        updateSelectedStatePresentation(selectedKey, in: draft)
        valueTextView.string = draft.value(for: selectedKey)
            ?? draft.baselineValue(for: selectedKey) ?? ""
        valueTextView.undoManager?.removeAllActions()
        editorView.updateSyntaxHighlighting(
            key: selectedKey,
            isTextValue: true,
            detectingIndentation: true
        )
    }

    private func updateSelectedStatePresentation(
        _ key: String,
        in draft: ResourceMetadataDraft
    ) {
        let state = rowState(key, in: draft)
        editorView.selectedKeyDetailsLabel.stringValue = state.rawValue
        editorView.selectedKeyDetailsLabel.textColor = stateColor(state)
        editorView.selectedKeyDetailsLabel.setAccessibilityValue(state.rawValue)
    }

    private var editorInteractionIdle: Bool {
        loadTask == nil && operationTask == nil
            && reviewTask == nil && reviewController == nil
    }

    private func updateControls() {
        let idle = editorInteractionIdle
        let loaded = draft != nil && expectedResourceVersion != nil
        let currentExists = selectedKey.flatMap { draft?.value(for: $0) } != nil
        let currentChanged = selectedKey.map { draft?.isChanged($0) == true } == true
        addButton.isEnabled = idle && loaded
        renameButton.isEnabled = idle && currentExists
        deleteButton.isEnabled = idle && currentExists
        revertButton.isEnabled = idle && currentChanged
        valueTextView.isEditable = idle && currentExists
        valueTextView.isSelectable = loaded
        saveButton.isEnabled = idle && loaded && draft?.hasChanges == true
        cancelButton.isEnabled = operationTask == nil
        if loadTask != nil || operationTask != nil || reviewTask != nil {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private func rowState(_ key: String, in draft: ResourceMetadataDraft) -> RowState {
        if draft.isDeleted(key) { return .deleted }
        if draft.isAdded(key) { return .added }
        if draft.isRenamed(key) { return .renamed }
        if draft.isChanged(key) { return .modified }
        return .saved
    }

    private func stateColor(_ state: RowState) -> NSColor {
        switch state {
        case .saved: .secondaryLabelColor
        case .added: .systemGreen
        case .modified, .renamed: .systemOrange
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

    private func mutationTargetDetails(note: String) -> String {
        let target = ClusterIdentityPresentation(session: session).targetDetails(identity)
        return "\(target)\n\n\(note)"
    }

    private func shouldDiscardChangesIfNeeded() -> Bool {
        guard draft?.hasChanges == true else { return true }
        return discardChangesConfirmation?()
            ?? KeyValueEditorDiscardConfirmation.shouldDiscard(
                editorTitle: kind.title,
                targetDetails: ClusterIdentityPresentation(session: session)
                    .targetDetails(identity)
            )
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
