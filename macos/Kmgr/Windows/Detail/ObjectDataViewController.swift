import AppKit
import KmgrCore

/// The single ConfigMap/Secret key-value surface. It owns the authoritative
/// UID-pinned Data GET and every decoded value remains process-memory-only.
@MainActor
final class ObjectDataViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate, WorkspaceStatusPublishing
{
    private enum KeyRow {
        case stored(ObjectDataEntry)
        case missingDraft(key: String, metadata: DataEditorDraftStore.Metadata)

        var key: String {
            switch self {
            case .stored(let entry): entry.id
            case .missingDraft(let key, _): key
            }
        }

        var entry: ObjectDataEntry? {
            guard case .stored(let entry) = self else { return nil }
            return entry
        }
    }

    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession?
    private let provider: any ObjectDetailProviding
    private let tableLayoutStore: TableLayoutStore
    private let dataFileReader: @Sendable (URL) throws -> Data
    private let dataFileWriter: @Sendable (Data, URL) throws -> Void

    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let splitView = NSSplitView()
    private let keysTable = ObjectDataKeysTableView()
    private let valueTextView = NSTextView()
    private let valueScroll = NSScrollView()
    private let revealButton = NSButton(
        checkboxWithTitle: "Show decoded values", target: nil, action: nil
    )
    private let addKeyButton = NSButton(title: "Add Key", target: nil, action: nil)
    private let renameKeyButton = NSButton(title: "Rename", target: nil, action: nil)
    private let deleteKeyButton = NSButton(title: "Delete Key", target: nil, action: nil)
    private let revertKeyButton = NSButton(title: "Revert", target: nil, action: nil)
    private let importKeyButton = NSButton(
        title: "Replace from File…", target: nil, action: nil
    )
    private let exportKeyButton = NSButton(title: "Export…", target: nil, action: nil)
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)

    private var objectData: ObjectData?
    private var selectedKey: String?
    private var selectedEntry: ObjectDataEntry?
    private var selectedDraftKind: DataValueKind?
    private var selectedCanEditText = false
    private var isInstallingState = false
    private var secretRevealed = false
    private var authorityUnavailable = false
    private var terminalObjectState = false
    private var conflictedKey: String?
    private let drafts = DataEditorDraftStore()
    private var tableLayoutBinding: TableLayoutBinding?

    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var dataFileTask: Task<Void, Never>?
    private var dataFileGeneration: UInt64 = 0
    private var authoritativeRefreshInFlight = false
    private var conflictController: DataConflictWindowController?

    var onBack: (() -> Void)?
    private(set) var workspaceStatus = WorkspaceStatus("Loading Data…", busy: true)
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot {
        ContextualShortcutCatalog.dataEditor(secret: isSecretObject)
    }

    init(
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        session: OpenedClusterSession? = nil,
        tableLayoutStore: TableLayoutStore? = nil,
        dataFileReader: @escaping @Sendable (URL) throws -> Data = {
            try DataValueFileIO.readBounded(from: $0)
        },
        dataFileWriter: @escaping @Sendable (Data, URL) throws -> Void = {
            try DataValueFileIO.write($0, to: $1)
        }
    ) {
        precondition(Self.supports(identity), "Data requires a core/v1 ConfigMap or Secret")
        self.identity = identity
        self.session = session
        self.provider = provider
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.dataFileReader = dataFileReader
        self.dataFileWriter = dataFileWriter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        dataFileTask?.cancel()
    }

    static func supports(_ identity: ResourceIdentity) -> Bool {
        identity.group.isEmpty && identity.version == "v1"
            && (identity.resource == "configmaps" || identity.resource == "secrets")
    }

    override func loadView() {
        let root = NSView()
        let backButton = NSButton(
            image: NSImage(
                systemSymbolName: "chevron.left",
                accessibilityDescription: "Back to resource list"
            )!,
            target: self,
            action: #selector(backPressed)
        )
        backButton.bezelStyle = .texturedRounded
        let breadcrumb = NSTextField(labelWithString: breadcrumbText)
        breadcrumb.font = .systemFont(ofSize: 15, weight: .semibold)
        breadcrumb.lineBreakMode = .byTruncatingMiddle
        retryButton.target = self
        retryButton.action = #selector(retryLoad)
        retryButton.isHidden = true

        let header = NSStackView(views: [
            backButton, breadcrumb, NSView(), retryButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false
        configureEditor()
        root.addSubview(header)
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        updateControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(keysTable)
        if objectData == nil, loadTask == nil { loadData() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        TextDocumentGeometry.update(
            valueTextView,
            in: valueScroll,
            wrapsToViewport: true
        )
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        operationTask?.cancel()
        operationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        cancelDataFileOperation()
        conflictController?.close()
        conflictController = nil
        releaseDrafts()
        objectData = nil
    }

    /// Keeps drafts visible across a helper restart but revokes mutation and
    /// reveal authority until a fresh UID-pinned Data response is installed.
    func engineDidDisconnect() {
        loadTask?.cancel()
        loadTask = nil
        operationTask?.cancel()
        operationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        cancelDataFileOperation()
        conflictController?.close()
        conflictController = nil
        authoritativeRefreshInFlight = false
        authorityUnavailable = true
        setSecretReveal(false)
        displaySelectedData()
        publishStatus(WorkspaceStatus(
            hasAnyDraftChanges
                ? "Engine disconnected · local Data edits preserved and locked"
                : "Engine disconnected · reopening this UID when ready",
            severity: .warning
        ))
        retryButton.isHidden = true
        updateControls()
    }

    func recover(
        session recoveredSession: OpenedClusterSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard recoveryTask == nil else { return }
        session = recoveredSession
        identity.clusterSessionID = recoveredSession.sessionID
        let rebound = identity
        publishStatus(WorkspaceStatus("Reopening Data for this UID…", busy: true))
        retryButton.isHidden = true
        recoveryTask = Task { [weak self, provider] in
            guard let self else { return }
            defer {
                recoveryTask = nil
                updateControls()
            }
            do {
                let current = try await provider.getData(identity: rebound)
                guard !Task.isCancelled else { return }
                try installRecovery(current)
                completion(.success(()))
            } catch {
                guard !Task.isCancelled else { return }
                authorityUnavailable = true
                show(error: error, allowsRetry: true)
                updateControls()
                completion(.failure(error))
            }
        }
    }

    private var breadcrumbText: String {
        let scope = identity.namespace.isEmpty ? "" : " · \(identity.namespace)"
        return "\(identity.resource)\(scope) · \(identity.name) · Data"
    }

    private var isSecretObject: Bool { identity.resource == "secrets" }

    var mutationConfirmationIdentityText: String {
        clusterPresentation.targetDetails(identity)
    }

    func confirmationInformativeText(note: String) -> String {
        "\(mutationConfirmationIdentityText)\n\n\(note)"
    }

    private var clusterPresentation: ClusterIdentityPresentation {
        session.map(ClusterIdentityPresentation.init(session:))
            ?? ClusterIdentityPresentation(clusterName: "", contextName: "")
    }

    private func configureEditor() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.identifier = .init("object-data-split")
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("key", "Key", 175, 100),
            ("value", "Value", 300, 140),
            ("type", "Type", 70, 58),
            ("size", "Size", 82, 68),
            ("state", "State", 84, 72),
        ]
        for (identifier, title, width, minimumWidth) in columns {
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
        keysTable.setAccessibilityLabel("ConfigMap or Secret data keys and values")
        tableLayoutBinding = TableLayoutBinding(
            tableView: keysTable,
            surface: .objectDataKeys,
            store: tableLayoutStore
        )
        keysTable.onToggleReveal = { [weak self] in self?.toggleSecretReveal() }
        keysTable.onBack = { [weak self] in self?.onBack?() }
        let keyScroll = NSScrollView()
        keyScroll.identifier = .init("object-data-keys-scroll")
        keyScroll.documentView = keysTable
        keyScroll.hasVerticalScroller = true
        keyScroll.hasHorizontalScroller = true
        keyScroll.autohidesScrollers = true
        keyScroll.frame = NSRect(x: 0, y: 0, width: 720, height: 500)

        valueTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueTextView.isRichText = false
        valueTextView.isEditable = false
        valueTextView.isSelectable = true
        valueTextView.allowsUndo = true
        valueTextView.delegate = self
        valueScroll.documentView = valueTextView
        valueScroll.hasVerticalScroller = true
        valueScroll.identifier = .init("object-data-value-scroll")
        valueScroll.setAccessibilityLabel("Selected decoded data value editor")
        TextDocumentGeometry.configure(
            valueTextView,
            in: valueScroll,
            wrapsToViewport: true
        )

        addKeyButton.target = self
        addKeyButton.action = #selector(addDataKey)
        renameKeyButton.target = self
        renameKeyButton.action = #selector(renameDataKey)
        deleteKeyButton.target = self
        deleteKeyButton.action = #selector(deleteDataKey)
        revertKeyButton.target = self
        revertKeyButton.action = #selector(revertCurrentKey)
        importKeyButton.target = self
        importKeyButton.action = #selector(importCurrentKey)
        exportKeyButton.target = self
        exportKeyButton.action = #selector(exportCurrentKey)
        revealButton.target = self
        revealButton.action = #selector(toggleSecretReveal)
        revealButton.isHidden = !isSecretObject
        revealButton.state = .off
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveCurrentKey)

        let controls = NSStackView(views: [
            addKeyButton, renameKeyButton, deleteKeyButton, revertKeyButton,
            importKeyButton, exportKeyButton, revealButton, saveKeyButton, NSView(),
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        let editor = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        valueScroll.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(controls)
        editor.addSubview(valueScroll)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: editor.topAnchor, constant: 7),
            valueScroll.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            valueScroll.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            valueScroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            valueScroll.bottomAnchor.constraint(equalTo: editor.bottomAnchor),
        ])
        splitView.addArrangedSubview(keyScroll)
        splitView.addArrangedSubview(editor)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setPosition(720, ofDividerAt: 0)
    }

    private func loadData(
        preservingDrafts: Bool = false,
        preferredKey: String? = nil,
        lockingUntilInstalled: Bool = false,
        successMessage: String? = nil
    ) {
        guard loadTask == nil else { return }
        if lockingUntilInstalled { authoritativeRefreshInFlight = true }
        authorityUnavailable = false
        retryButton.isHidden = true
        publishStatus(WorkspaceStatus(
            objectData == nil ? "Loading Data…" : "Refreshing Data…",
            busy: true
        ))
        updateControls()
        loadTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer {
                loadTask = nil
                if lockingUntilInstalled { authoritativeRefreshInFlight = false }
                updateControls()
            }
            do {
                let current = try await provider.getData(identity: identity)
                guard !Task.isCancelled else { return }
                try install(
                    current,
                    preservingDrafts: preservingDrafts,
                    preferredKey: preferredKey
                )
                publishStatus(WorkspaceStatus(
                    successMessage
                        ?? "Resource version \(current.resourceVersion) · \(current.entries.count.formatted()) key\(current.entries.count == 1 ? "" : "s")"
                ))
            } catch {
                guard !Task.isCancelled else { return }
                authorityUnavailable = true
                show(error: error, allowsRetry: true)
            }
        }
    }

    private func installRecovery(_ current: ObjectData) throws {
        try install(
            current,
            preservingDrafts: hasAnyDraftChanges,
            preferredKey: selectedKey
        )
        setSecretReveal(false)
        displaySelectedData()
        publishStatus(WorkspaceStatus(
            hasAnyDraftChanges
                ? "Reconnected · current Data loaded · local edits preserved"
                : "Reconnected · resource version \(current.resourceVersion)",
            severity: hasAnyDraftChanges ? .warning : .informational
        ))
    }

    private func install(
        _ current: ObjectData,
        preservingDrafts: Bool,
        preferredKey: String?
    ) throws {
        guard current.identity.uid == identity.uid else {
            terminalObjectState = true
            throw ClusterManagerIssue(
                category: .conflict,
                reason: "ObjectRecreated",
                message: "A same-name object has a different UID and cannot replace this Data view.",
                operation: "load key/value data"
            )
        }
        if !preservingDrafts { releaseDrafts() }
        let wasInstalling = isInstallingState
        isInstallingState = true
        defer { isInstallingState = wasInstalling }
        identity = current.identity
        objectData = current
        authorityUnavailable = false
        terminalObjectState = false
        conflictedKey = nil
        keysTable.reloadData()

        let rows = editorRows
        let selected = preferredKey.flatMap { key in
            rows.firstIndex { $0.key == key }
        } ?? rows.indices.first
        guard let selected else {
            keysTable.deselectAll(nil)
            selectedKey = nil
            selectedEntry = nil
            selectedDraftKind = nil
            selectedCanEditText = false
            valueTextView.string = "No Data entries. Use Add Key to create one."
            valueTextView.undoManager?.removeAllActions()
            updateControls()
            return
        }
        keysTable.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        installSelectedRow(rows[selected])
        updateControls()
    }

    @objc private func retryLoad() {
        loadData(
            preservingDrafts: hasAnyDraftChanges,
            preferredKey: selectedKey,
            lockingUntilInstalled: objectData != nil
        )
    }

    private var editorRows: [KeyRow] {
        let entries = objectData?.entries ?? []
        let storedKeys = Set(entries.map(\.id))
        let missing = drafts.keys
            .filter { !storedKeys.contains($0) }
            .sorted()
            .compactMap { key -> KeyRow? in
                drafts.metadata(for: key).map { .missingDraft(key: key, metadata: $0) }
            }
        return entries.map(KeyRow.stored) + missing
    }

    func numberOfRows(in tableView: NSTableView) -> Int { editorRows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let rows = editorRows
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let dataRow = rows[row]
        let presentation = rowPresentation(for: dataRow)
        let columnID = tableColumn.identifier.rawValue
        let valuePreview = columnID == "value" ? valuePreview(for: dataRow) : nil
        let value: String
        switch columnID {
        case "key": value = presentation.keyText
        case "value": value = valuePreview?.displayText ?? ""
        case "type": value = presentation.typeText
        case "size": value = presentation.sizeText
        case "state": value = presentation.state.displayText
        default: value = ""
        }
        let cell = textCell(value, table: tableView, column: tableColumn)
        cell.setAccessibilityLabel(tableColumn.title)
        cell.setAccessibilityValue(
            valuePreview?.accessibilityValue ?? presentation.accessibilityValue
        )
        switch presentation.state {
        case .saved:
            cell.textField?.textColor = .labelColor
        case .unsaved:
            cell.textField?.textColor = columnID == "state" ? .systemOrange : .labelColor
        case .conflict:
            cell.textField?.textColor = columnID == "state" ? .systemRed : .labelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === keysTable, !isInstallingState else {
            return
        }
        let previousRow = editorRows.firstIndex { $0.key == selectedKey }
        captureSelectedDraft()
        let rows = editorRows
        guard rows.indices.contains(keysTable.selectedRow) else {
            selectedKey = nil
            selectedEntry = nil
            selectedDraftKind = nil
            selectedCanEditText = false
            valueTextView.string = ""
            valueTextView.undoManager?.removeAllActions()
            updateControls()
            reloadRows([previousRow].compactMap { $0 })
            return
        }
        installSelectedRow(rows[keysTable.selectedRow])
        updateControls()
        reloadRows([previousRow, keysTable.selectedRow].compactMap { $0 })
    }

    private func installSelectedRow(_ row: KeyRow) {
        selectedKey = row.key
        selectedEntry = row.entry
        displaySelectedData()
    }

    @objc private func toggleSecretReveal() {
        guard isSecretObject, objectData != nil, !terminalObjectState,
            dataInteractionIdle
        else { return }
        if secretRevealed { captureSelectedDraft() }
        setSecretReveal(!secretRevealed)
        displaySelectedData()
        updateControls()
    }

    private func setSecretReveal(_ revealed: Bool) {
        secretRevealed = isSecretObject && revealed
        revealButton.state = secretRevealed ? .on : .off
        keysTable.reloadData()
    }

    private func displaySelectedData() {
        guard let data = objectData, let key = selectedKey else { return }
        let draftMetadata = drafts.metadata(for: key)
        guard selectedEntry != nil || draftMetadata != nil else { return }
        let wasInstalling = isInstallingState
        isInstallingState = true
        defer { isInstallingState = wasInstalling }
        selectedDraftKind = draftMetadata?.kind ?? selectedEntry?.kind
        if data.secret && !secretRevealed {
            let count = draftMetadata?.byteCount ?? Int(selectedEntry?.byteSize ?? 0)
            valueTextView.string = "Secret value concealed · \(count.formatted()) bytes"
            selectedCanEditText = false
            valueTextView.undoManager?.removeAllActions()
            updateControls()
            return
        }
        var draft = drafts.snapshot(for: key)
        defer { draft?.wipe() }
        var bytes = draft?.value ?? selectedEntry.map(copyBytes(from:)) ?? Data()
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let kind = draft?.kind ?? selectedEntry?.kind ?? .binary
        if kind == .text,
            let text = String(data: bytes, encoding: .utf8),
            !text.contains("\0")
        {
            valueTextView.string = text
            selectedCanEditText = true
        } else {
            valueTextView.string = BinaryHexASCIIPresentation.dump(bytes)
            selectedCanEditText = false
        }
        valueTextView.undoManager?.removeAllActions()
        updateControls()
        if selectedEntry == nil { showMissingDraftStatus() }
    }

    private func valuePreview(for row: KeyRow) -> DataValuePreviewPresentation? {
        let secret = objectData?.secret ?? isSecretObject
        if var draft = drafts.snapshot(for: row.key) {
            defer { draft.wipe() }
            return DataValuePreviewPresentation(
                kind: draft.kind,
                value: draft.value,
                secret: secret,
                hasRevealAuthority: secretRevealed
            )
        }
        guard let entry = row.entry else { return nil }
        var bytes = copyBytes(from: entry)
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        return DataValuePreviewPresentation(
            kind: entry.kind,
            value: bytes,
            secret: secret,
            hasRevealAuthority: secretRevealed
        )
    }

    private func rowPresentation(for row: KeyRow) -> DataEditorRowPresentation {
        let selected = selectedKey == row.key
        switch row {
        case .stored(let entry):
            let draft = drafts.metadata(for: entry.id)
            let changed = draft != nil
            let conflict = conflictedKey == entry.id
            return DataEditorRowPresentation(
                key: entry.id,
                storedKind: entry.kind,
                storedByteSize: entry.byteSize,
                isSelected: selected,
                draftKind: draft?.kind,
                draftByteSize: changed || conflict
                    ? draft.map { UInt64($0.byteCount) }
                    : nil,
                hasUnsavedChanges: changed,
                hasConflict: conflict
            )
        case .missingDraft(let key, let metadata):
            return DataEditorRowPresentation(
                key: key,
                storedKind: metadata.kind,
                storedByteSize: UInt64(metadata.byteCount),
                isSelected: selected,
                draftKind: metadata.kind,
                draftByteSize: UInt64(metadata.byteCount),
                hasUnsavedChanges: true,
                hasConflict: true
            )
        }
    }

    private func textCell(
        _ value: String,
        table: NSTableView,
        column: NSTableColumn
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("object-data.\(column.identifier.rawValue)")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
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
        cell.textField?.textColor = .labelColor
        return cell
    }

    override func cancelOperation(_ sender: Any?) {
        if leaveValueEditorIfActive() { return }
        onBack?()
    }

    private func leaveValueEditorIfActive() -> Bool {
        guard let window = view.window,
            let responderView = window.firstResponder as? NSView,
            responderView === valueTextView || responderView.isDescendant(of: valueScroll)
        else { return false }
        captureSelectedDraft()
        window.makeFirstResponder(keysTable)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if isSecretObject,
            event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
            event.charactersIgnoringModifiers?.lowercased() == "d"
        {
            toggleSecretReveal()
            return
        }
        super.keyDown(with: event)
    }

    @objc func saveDocument(_ sender: Any?) {
        if saveKeyButton.isEnabled { saveCurrentKey() }
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === valueTextView, !isInstallingState else {
            return
        }
        captureSelectedDraft()
        updateControls()
        reloadSelectedRow()
    }

    private var currentDraftBytes: Data? {
        guard let data = objectData, let key = selectedKey else { return nil }
        guard !data.secret || secretRevealed else { return nil }
        if selectedCanEditText { return Data(valueTextView.string.utf8) }
        return drafts.snapshot(for: key)?.value ?? selectedEntry.map(copyBytes(from:))
    }

    private var hasSelectedDraftChanges: Bool {
        selectedKey.map(drafts.contains) ?? false
    }

    private var hasAnyDraftChanges: Bool { !drafts.isEmpty }

    private var dataInteractionIdle: Bool {
        operationTask == nil && conflictController == nil
            && dataFileTask == nil && loadTask == nil && recoveryTask == nil
            && !authoritativeRefreshInFlight && !authorityUnavailable
    }

    private func updateControls() {
        let hasSelection = selectedKey != nil && !terminalObjectState
        let hasStoredSelection = selectedEntry != nil && !terminalObjectState
        let idle = dataInteractionIdle
        addKeyButton.isEnabled = objectData != nil && !terminalObjectState && idle
        renameKeyButton.isEnabled = hasStoredSelection && idle && !hasSelectedDraftChanges
        deleteKeyButton.isEnabled = hasStoredSelection && idle && !hasSelectedDraftChanges
        let accessible = !(objectData?.secret ?? false) || secretRevealed
        importKeyButton.isEnabled = hasSelection && idle && accessible
        exportKeyButton.isEnabled = hasSelection && idle && accessible
        revertKeyButton.isEnabled = hasSelection && idle && accessible
            && hasSelectedDraftChanges
        saveKeyButton.isEnabled = hasSelection && idle && accessible
            && hasSelectedDraftChanges
        valueTextView.isEditable = hasSelection && idle && accessible && selectedCanEditText
        revealButton.isEnabled = objectData != nil && !terminalObjectState && idle
    }

    private func reloadSelectedRow() { reloadRows([keysTable.selectedRow]) }

    private func reloadRows(_ rows: [Int]) {
        let valid = IndexSet(rows.filter { $0 >= 0 && $0 < keysTable.numberOfRows })
        guard !valid.isEmpty else { return }
        keysTable.reloadData(
            forRowIndexes: valid,
            columnIndexes: IndexSet(integersIn: 0..<keysTable.numberOfColumns)
        )
    }

    private func releaseDrafts() {
        let wasInstalling = isInstallingState
        isInstallingState = true
        defer { isInstallingState = wasInstalling }
        drafts.removeAll()
        selectedDraftKind = nil
        selectedCanEditText = false
        if objectData?.secret == true {
            valueTextView.string = ""
            valueTextView.undoManager?.removeAllActions()
        }
    }

    private func captureSelectedDraft() {
        guard let data = objectData, let key = selectedKey else { return }
        guard !data.secret || secretRevealed else { return }
        guard var value = currentDraftBytes else { return }
        defer { value.resetBytes(in: value.startIndex..<value.endIndex) }
        if let entry = selectedEntry {
            drafts.update(
                key: key,
                kind: selectedDraftKind ?? entry.kind,
                value: value,
                storedKind: entry.kind,
                valueMatchesStored: valueMatchesEntry(value, entry: entry),
                storedContentHash: entry.contentHash
            )
        } else {
            drafts.replaceExisting(
                key: key,
                kind: selectedDraftKind ?? .binary,
                value: value
            )
        }
    }

    private func copyBytes(from entry: ObjectDataEntry) -> Data {
        var result = Data()
        entry.value.withUnsafeBytes { result.append(contentsOf: $0) }
        return result
    }

    private func valueMatchesEntry(_ value: Data, entry: ObjectDataEntry) -> Bool {
        guard value.count == entry.value.count else { return false }
        return value.withUnsafeBytes { local in
            entry.value.withUnsafeBytes { stored in local.elementsEqual(stored) }
        }
    }

    private func showMissingDraftStatus() {
        publishStatus(WorkspaceStatus(
            "Conflict · key missing on server · local draft preserved · Save Key recreates it",
            severity: .warning
        ))
    }

    private func showValidation(_ message: String) {
        publishStatus(WorkspaceStatus(message, severity: .error))
        NSSound.beep()
    }

    private func show(error: Error, allowsRetry: Bool = false) {
        let presentation = UserFacingErrorPresentation(error)
        publishStatus(WorkspaceStatus(
            presentation.inlineText,
            severity: .error,
            toolTip: presentation.detailedText
        ))
        retryButton.isHidden = !allowsRetry
    }

    private func publishStatus(_ status: WorkspaceStatus) {
        workspaceStatus = status
        onWorkspaceStatusChanged?(status)
    }

    @objc private func backPressed() { onBack?() }
}

extension ObjectDataViewController {
    @objc private func revertCurrentKey() {
        guard let key = selectedKey else { return }
        drafts.remove(key)
        if let entry = selectedEntry {
            selectedDraftKind = entry.kind
            displaySelectedData()
            reloadSelectedRow()
        } else {
            selectedKey = nil
            selectedEntry = nil
            selectedDraftKind = nil
            selectedCanEditText = false
            keysTable.reloadData()
            keysTable.deselectAll(nil)
            valueTextView.string = ""
            valueTextView.undoManager?.removeAllActions()
            updateControls()
        }
        publishStatus(WorkspaceStatus("Local key changes reverted"))
    }

    @objc private func addDataKey() {
        guard objectData != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Add Key"
        alert.informativeText = confirmationInformativeText(
            note: "The new key is created only if it still does not exist on the server."
        )
        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 340, height: 24))
        nameField.placeholderString = "Key name"
        let kindButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        kindButton.addItems(withTitles: ["Text", "Binary from File"])
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 58))
        accessory.addSubview(nameField)
        accessory.addSubview(kindButton)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Set(editorRows.map(\.key))
        if let message = KubernetesDataKeyValidator.validationMessage(
            for: key,
            existingKeys: keys
        ) {
            showValidation(message)
            return
        }
        if kindButton.indexOfSelectedItem == 1 {
            chooseImportedFile { [weak self] url in
                self?.readImportedBytes(from: url) { [weak self] bytes in
                    self?.performMutation(.set(
                        key: key,
                        kind: .binary,
                        value: bytes,
                        expectedContentHash: Data()
                    ), successMessage: "Added \(key)")
                }
            }
        } else {
            performMutation(.set(
                key: key,
                kind: .text,
                value: Data(),
                expectedContentHash: Data()
            ), successMessage: "Added \(key)")
        }
    }

    @objc private func renameDataKey() {
        guard objectData != nil, let entry = selectedEntry, !hasSelectedDraftChanges else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename Key"
        alert.informativeText = confirmationInformativeText(
            note: "Rename \(entry.id) without changing its value or text/binary kind."
        )
        let field = NSTextField(string: entry.id)
        field.frame.size = NSSize(width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Set(editorRows.map(\.key))
        if let message = KubernetesDataKeyValidator.validationMessage(
            for: newKey,
            existingKeys: keys,
            allowingExistingKey: entry.id
        ) {
            showValidation(message)
            return
        }
        guard newKey != entry.id else { return }
        performMutation(.rename(
            key: entry.id,
            newKey: newKey,
            expectedContentHash: entry.contentHash
        ), successMessage: "Renamed \(entry.id) to \(newKey)")
    }

    @objc private func deleteDataKey() {
        guard let entry = selectedEntry, !hasSelectedDraftChanges else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete key \(entry.id)?"
        alert.informativeText = confirmationInformativeText(
            note: "The delete uses the loaded content hash and will fail if this key changed on the server."
        )
        alert.addButton(withTitle: "Delete Key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performMutation(.delete(
            key: entry.id,
            expectedContentHash: entry.contentHash
        ), successMessage: "Deleted \(entry.id)")
    }

    @objc private func importCurrentKey() {
        guard let key = selectedKey else { return }
        chooseImportedFile { [weak self] url in
            self?.importDataFile(from: url, forKey: key)
        }
    }

    func replaceSelectedDataWithImportedBytes(_ bytes: Data) {
        guard let key = selectedKey else { return }
        replaceDataWithImportedBytes(bytes, forKey: key)
    }

    private func replaceDataWithImportedBytes(_ bytes: Data, forKey key: String) {
        let entry = objectData?.entries.first { $0.id == key }
        let replacementKind: DataValueKind
        if objectData?.secret == true {
            replacementKind = .binary
        } else {
            replacementKind = drafts.metadata(for: key)?.kind ?? entry?.kind ?? .binary
        }
        if let entry {
            drafts.update(
                key: key,
                kind: replacementKind,
                value: bytes,
                storedKind: entry.kind,
                valueMatchesStored: valueMatchesEntry(bytes, entry: entry),
                storedContentHash: entry.contentHash
            )
        } else {
            drafts.replaceExisting(key: key, kind: replacementKind, value: bytes)
        }
        if selectedKey == key {
            selectedDraftKind = replacementKind
            selectedEntry = entry
            displaySelectedData()
        }
        if let row = editorRows.firstIndex(where: { $0.key == key }) {
            reloadRows([row])
        }
        publishStatus(WorkspaceStatus(
            drafts.contains(key)
                ? "Loaded \(bytes.count.formatted()) bytes locally for \(key)"
                : "Selected file matches the saved value for \(key)"
        ))
    }

    private func chooseImportedFile(_ completion: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    func importDataFile(from url: URL, forKey key: String) {
        guard editorRows.contains(where: { $0.key == key }) else { return }
        readImportedBytes(from: url) { [weak self] bytes in
            self?.replaceDataWithImportedBytes(bytes, forKey: key)
        }
    }

    private func readImportedBytes(
        from url: URL,
        completion: @escaping @MainActor @Sendable (Data) -> Void
    ) {
        let reader = dataFileReader
        startDataFileOperation(status: "Importing \(url.lastPathComponent)…") {
            try reader(url)
        } completion: { value in
            completion(value)
        }
    }

    @objc private func exportCurrentKey() {
        guard let key = selectedKey, let window = view.window,
            var bytes = currentDraftBytes
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = key
        panel.beginSheetModal(for: window) { [weak self] response in
            defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
            guard response == .OK, let url = panel.url else { return }
            self?.exportDataFile(bytes, key: key, to: url)
        }
    }

    func exportDataFile(_ bytes: Data, key: String, to url: URL) {
        let writer = dataFileWriter
        startDataFileOperation(status: "Exporting \(url.lastPathComponent)…") {
            var protected = bytes
            defer { protected.resetBytes(in: protected.startIndex..<protected.endIndex) }
            try writer(protected, url)
        } completion: { [weak self] _ in
            self?.publishStatus(WorkspaceStatus("Exported \(key)"))
        }
    }

    private func startDataFileOperation<Value: Sendable>(
        status: String,
        operation: @escaping @Sendable () throws -> Value,
        completion: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        guard dataFileTask == nil else { return }
        dataFileGeneration &+= 1
        let generation = dataFileGeneration
        publishStatus(WorkspaceStatus(status, busy: true))
        dataFileTask = Task { [weak self] in
            do {
                let value = try await Self.performDataFileOperation(operation)
                guard let self, !Task.isCancelled, dataFileGeneration == generation else {
                    return
                }
                dataFileTask = nil
                completion(value)
                updateControls()
            } catch {
                guard let self, !Task.isCancelled, dataFileGeneration == generation else {
                    return
                }
                dataFileTask = nil
                show(error: error)
                updateControls()
            }
        }
        updateControls()
    }

    private nonisolated static func performDataFileOperation<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }

    private func cancelDataFileOperation() {
        dataFileGeneration &+= 1
        dataFileTask?.cancel()
        dataFileTask = nil
    }

    @objc private func saveCurrentKey() {
        captureSelectedDraft()
        guard let key = selectedKey, var draft = drafts.snapshot(for: key) else { return }
        defer { draft.wipe() }
        performMutation(.set(
            key: key,
            kind: draft.kind,
            value: draft.value,
            expectedContentHash: selectedEntry == nil ? Data() : draft.expectedContentHash
        ), successMessage: "Saved \(key)")
    }

    private func performMutation(_ mutation: DataMutationKind, successMessage: String) {
        guard let data = objectData, operationTask == nil, !authorityUnavailable else { return }
        submitMutation(
            mutation,
            expectedResourceVersion: data.resourceVersion,
            successMessage: successMessage,
            recoverConflicts: true
        )
    }

    private func submitMutation(
        _ mutation: DataMutationKind,
        expectedResourceVersion: String,
        successMessage: String,
        recoverConflicts: Bool
    ) {
        guard operationTask == nil else { return }
        if conflictedKey != mutation.sourceKey {
            conflictedKey = nil
            reloadSelectedRow()
        }
        publishStatus(WorkspaceStatus("Saving key/value data…", busy: true))
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer {
                operationTask = nil
                updateControls()
            }
            do {
                let stream = try await provider.updateData(
                    identity: identity,
                    expectedResourceVersion: expectedResourceVersion,
                    mutations: [mutation]
                )
                for try await progress in stream where progress.state.isTerminal {
                    if progress.state != .succeeded {
                        throw progress.issue ?? ClusterManagerIssue(
                            category: .conflict,
                            reason: "DataUpdateFailed",
                            message: "The key was not saved. Your local value remains in the editor.",
                            operation: "update key/value data"
                        )
                    }
                    drafts.remove(mutation.sourceKey)
                    loadTask?.cancel()
                    loadTask = nil
                    loadData(
                        preservingDrafts: true,
                        preferredKey: postMutationSelection(for: mutation),
                        lockingUntilInstalled: true,
                        successMessage: successMessage
                    )
                }
            } catch {
                if recoverConflicts, Self.clusterIssue(from: error)?.category == .conflict {
                    await prepareConflictRecovery(
                        mutation: mutation,
                        successMessage: successMessage
                    )
                } else {
                    show(error: error)
                }
            }
        }
        updateControls()
    }

    private func postMutationSelection(for mutation: DataMutationKind) -> String? {
        switch mutation {
        case .set(let key, _, _, _): key
        case .rename(_, let newKey, _): newKey
        case .delete: nil
        }
    }

    private func prepareConflictRecovery(
        mutation: DataMutationKind,
        successMessage: String
    ) async {
        publishStatus(WorkspaceStatus(
            "Conflict detected · loading the current key…",
            severity: .warning,
            busy: true
        ))
        do {
            let currentData = try await provider.getData(identity: identity)
            guard !Task.isCancelled else { return }
            guard currentData.identity.uid == identity.uid else {
                throw ClusterManagerIssue(
                    category: .conflict,
                    reason: "ObjectRecreated",
                    message: "A same-name object has a different UID, so the local change cannot be retried.",
                    operation: "resolve key/value conflict"
                )
            }
            let currentEntry = currentData.entries.first { $0.id == mutation.sourceKey }
            conflictedKey = mutation.sourceKey
            reloadSelectedRow()
            let destinationExists = mutation.destinationKey.map { destination in
                currentData.entries.contains { $0.id == destination }
            } ?? false
            let retryPlan = mutation.conflictRetryPlan(
                currentContentHash: currentEntry?.contentHash,
                destinationExists: destinationExists
            )
            presentConflict(
                mutation: mutation,
                successMessage: successMessage,
                currentData: currentData,
                currentEntry: currentEntry,
                retryPlan: retryPlan
            )
        } catch {
            conflictedKey = mutation.sourceKey
            reloadSelectedRow()
            publishStatus(WorkspaceStatus(
                "Conflict · current server data could not be loaded · local edit preserved",
                severity: .error
            ))
        }
    }

    private func presentConflict(
        mutation: DataMutationKind,
        successMessage: String,
        currentData: ObjectData,
        currentEntry: ObjectDataEntry?,
        retryPlan: DataConflictRetryPlan
    ) {
        guard let window = view.window else {
            publishStatus(WorkspaceStatus(
                "Conflict · local edit preserved",
                severity: .warning
            ))
            return
        }
        let displays = conflictDisplays(
            mutation: mutation,
            currentEntry: currentEntry,
            secret: currentData.secret
        )
        let retryUnavailableReason: String?
        if case .unavailable(let reason) = retryPlan {
            retryUnavailableReason = reason
        } else {
            retryUnavailableReason = nil
        }
        let canCopyLocal: Bool
        switch mutation {
        case .set:
            canCopyLocal = !currentData.secret || secretRevealed
        case .delete, .rename:
            canCopyLocal = false
        }
        let controller = DataConflictWindowController(
            session: session,
            identity: identity,
            key: mutation.sourceKey,
            resourceVersion: currentData.resourceVersion,
            local: displays.local,
            current: displays.current,
            canCopyLocal: canCopyLocal,
            retryUnavailableReason: retryUnavailableReason
        ) { [weak self] choice in
            guard let self else { return }
            conflictController = nil
            defer { updateControls() }
            switch choice {
            case .reload:
                conflictedKey = nil
                installCurrentDataAfterConflict(currentData, selecting: mutation.sourceKey)
                publishStatus(WorkspaceStatus("Reloaded current server data"))
            case .copyLocal:
                copyLocalConflictValueToPasteboard(mutation: mutation)
                publishStatus(WorkspaceStatus(
                    "Copied local value · local edit preserved"
                ))
            case .retry:
                guard case .retry(let retryMutation) = retryPlan else { return }
                conflictedKey = nil
                submitMutation(
                    retryMutation,
                    expectedResourceVersion: currentData.resourceVersion,
                    successMessage: successMessage,
                    recoverConflicts: true
                )
            case .keepEditing:
                publishStatus(WorkspaceStatus(
                    "Conflict · local edit preserved",
                    severity: .warning
                ))
            }
        }
        conflictController = controller
        updateControls()
        controller.beginSheet(for: window)
    }

    private func conflictDisplays(
        mutation: DataMutationKind,
        currentEntry: ObjectDataEntry?,
        secret: Bool
    ) -> (local: DataConflictValueDisplay, current: DataConflictValueDisplay) {
        var localBinaryText: String?
        var currentBinaryText: String?
        if case .set(_, let kind, let localValue, _) = mutation, kind == .binary {
            if let currentEntry {
                var currentBytes = copyBytes(from: currentEntry)
                defer { currentBytes.resetBytes(in: currentBytes.startIndex..<currentBytes.endIndex) }
                let diff = BinaryHexASCIIPresentation.diff(
                    local: localValue,
                    current: currentBytes
                )
                localBinaryText = diff.local
                currentBinaryText = diff.current
            } else {
                localBinaryText = BinaryHexASCIIPresentation.dump(localValue)
            }
        }
        let local = localConflictDisplay(
            for: mutation,
            secret: secret,
            binaryText: localBinaryText
        )
        let current = currentEntry.map {
            conflictDisplay(
                entry: $0,
                secret: secret,
                binaryText: currentBinaryText
            )
        } ?? .missing()
        return (local, current)
    }

    private func localConflictDisplay(
        for mutation: DataMutationKind,
        secret: Bool,
        binaryText: String?
    ) -> DataConflictValueDisplay {
        switch mutation {
        case .set(_, let kind, let value, _):
            return DataConflictValueDisplay(
                secret: secret,
                kind: kind,
                byteCount: value.count,
                contentHash: DataConflictValueDisplay.contentHash(of: value),
                decodedText: kind == .text ? safeUTF8(value) : nil,
                binaryText: binaryText,
                secretRevealed: secretRevealed
            )
        case .delete:
            return .missing("Local action deletes this key.")
        case .rename(_, let newKey, _):
            return .missing("Local action renames this key to \(newKey).")
        }
    }

    private func conflictDisplay(
        entry: ObjectDataEntry,
        secret: Bool,
        binaryText: String?
    ) -> DataConflictValueDisplay {
        var bytes = copyBytes(from: entry)
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let boundedBinary = entry.kind == .binary
            ? (binaryText ?? BinaryHexASCIIPresentation.dump(bytes))
            : nil
        return DataConflictValueDisplay(
            secret: secret,
            kind: entry.kind,
            byteCount: bytes.count,
            contentHash: entry.contentHash,
            decodedText: entry.kind == .text ? safeUTF8(bytes) : nil,
            binaryText: boundedBinary,
            secretRevealed: secretRevealed
        )
    }

    private func safeUTF8(_ value: Data) -> String? {
        guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else {
            return nil
        }
        return text
    }

    private func copyLocalConflictValueToPasteboard(mutation: DataMutationKind) {
        guard case .set(_, _, let localValue, _) = mutation else { return }
        var bytes = localValue
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = safeUTF8(bytes) {
            pasteboard.setString(text, forType: .string)
        } else {
            pasteboard.setData(bytes, forType: NSPasteboard.PasteboardType("public.data"))
        }
    }

    private func installCurrentDataAfterConflict(
        _ currentData: ObjectData,
        selecting key: String
    ) {
        drafts.remove(key)
        conflictedKey = nil
        do {
            try install(
                currentData,
                preservingDrafts: true,
                preferredKey: key
            )
        } catch {
            authorityUnavailable = true
            show(error: error, allowsRetry: true)
        }
    }

    private static func clusterIssue(from error: Error) -> ClusterManagerIssue? {
        error as? ClusterManagerIssue
    }
}

@MainActor
private final class ObjectDataKeysTableView: NSTableView {
    var onToggleReveal: (() -> Void)?
    var onBack: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ])
        switch (event.charactersIgnoringModifiers?.lowercased(), event.keyCode) {
        case ("d", _) where modifiers.isEmpty:
            onToggleReveal?()
        case (_, 53) where modifiers.isEmpty:
            onBack?()
        default:
            super.keyDown(with: event)
        }
    }
}
