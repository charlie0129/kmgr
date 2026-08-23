import AppKit
import KmgrCore

/// The single ConfigMap/Secret key-value surface. It owns the authoritative
/// UID-pinned Data GET and every decoded value remains process-memory-only.
@MainActor
final class ObjectDataViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate, WorkspaceStatusPublishing
{
    private struct SearchMatch {
        var keyMatched: Bool
        var valueMatched: Bool
        var valueSnippet: String?
    }

    private struct ValueCellPresentation {
        var displayText: String
        var accessibilityValue: String
    }

    private struct KeyRow {
        var key: String
        var entry: ObjectDataEntry?
        var draft: DataEditorDraftStore.Metadata?
        var deleted: Bool
    }

    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession?
    private let provider: any ObjectDetailProviding
    private let dataFileReader: @Sendable (URL) throws -> Data
    private let dataFileWriter: @Sendable (Data, URL) throws -> Void
    private let valueChangeConfirmation: (@MainActor (
        KeyValueDiffConfirmationWindowController
    ) async -> KeyValueDiffConfirmationWindowController.Choice)?
    private let discardChangesConfirmation: (@MainActor () -> Bool)?

    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let editorView: KeyValueEditorView
    private var splitView: KeyValueEditorSplitView { editorView.splitView }
    private var keysTable: KeyValueEditorTableView { editorView.tableView }
    private var searchField: NSSearchField { editorView.searchField }
    private var searchResultLabel: NSTextField { editorView.resultLabel }
    private var valueTextView: NSTextView { editorView.valueTextView }
    private var valueScroll: NSScrollView { editorView.valueScrollView }
    private var selectedKeyLabel: NSTextField { editorView.selectedKeyLabel }
    private var selectedKeyDetailsLabel: NSTextField {
        editorView.selectedKeyDetailsLabel
    }
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
    private let saveKeyButton = NSButton(title: "Save Changes", target: nil, action: nil)

    private var objectData: ObjectData?
    private var selectedKey: String?
    private var selectedEntry: ObjectDataEntry?
    private var selectedDraftKind: DataValueKind?
    private var selectedCanEditText = false
    private var isInstallingState = false
    private var visibleRows: [KeyRow] = []
    private var totalRowCount = 0
    private var searchMatches: [String: SearchMatch] = [:]
    private var appliedSearchQuery = ""
    private var secretRevealed = false
    private var authorityUnavailable = false
    private var terminalObjectState = false
    private var conflictedKey: String?
    private let drafts = DataEditorDraftStore()

    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var dataFileTask: Task<Void, Never>?
    private var valueDiffTask: Task<Void, Never>?
    private var dataFileGeneration: UInt64 = 0
    private var authoritativeRefreshInFlight = false
    private var conflictController: DataConflictWindowController?
    private var valueDiffController: KeyValueDiffConfirmationWindowController?

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
        },
        valueChangeConfirmation: (@MainActor (
            KeyValueDiffConfirmationWindowController
        ) async -> KeyValueDiffConfirmationWindowController.Choice)? = nil,
        discardChangesConfirmation: (@MainActor () -> Bool)? = nil
    ) {
        precondition(Self.supports(identity), "Data requires a core/v1 ConfigMap or Secret")
        let resolvedTableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.identity = identity
        self.session = session
        self.provider = provider
        self.editorView = KeyValueEditorView(
            configuration: Self.editorConfiguration,
            tableLayoutStore: resolvedTableLayoutStore
        )
        self.dataFileReader = dataFileReader
        self.dataFileWriter = dataFileWriter
        self.valueChangeConfirmation = valueChangeConfirmation
        self.discardChangesConfirmation = discardChangesConfirmation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        dataFileTask?.cancel()
        valueDiffTask?.cancel()
    }

    static func supports(_ identity: ResourceIdentity) -> Bool {
        identity.group.isEmpty && identity.version == "v1"
            && (identity.resource == "configmaps" || identity.resource == "secrets")
    }

    private static let editorConfiguration = KeyValueEditorView.Configuration(
        identifierPrefix: "object-data",
        splitAutosaveName: "kmgr.object-data-master-detail",
        tableAccessibilityLabel: "ConfigMap or Secret data keys and values",
        valueAccessibilityLabel: "Selected decoded data value editor",
        tableSurface: .objectDataKeys,
        columns: [
            .init(id: "key", title: "Key", width: 175, minimumWidth: 100),
            .init(id: "value", title: "Value", width: 300, minimumWidth: 140),
            .init(id: "type", title: "Type", width: 70, minimumWidth: 58),
            .init(id: "size", title: "Size", width: 82, minimumWidth: 68),
            .init(id: "state", title: "State", width: 84, minimumWidth: 72),
        ]
    )

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
        editorView.translatesAutoresizingMaskIntoConstraints = false
        configureEditor()
        root.addSubview(header)
        root.addSubview(editorView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            editorView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            editorView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        editorView.updateDocumentGeometry()
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        operationTask?.cancel()
        operationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        cancelDataFileOperation()
        cancelValueDiffReview()
        editorView.clearSyntaxHighlighting()
        conflictController?.close()
        conflictController = nil
        searchMatches.removeAll(keepingCapacity: false)
        visibleRows.removeAll(keepingCapacity: false)
        totalRowCount = 0
        appliedSearchQuery = ""
        searchField.stringValue = ""
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
        cancelValueDiffReview()
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
        splitView.paneMinimumsProvider = { [weak self] in
            self?.splitPaneMinimumWidths()
                ?? KeyValueEditorSplitView.PaneMinimums(leading: 260, trailing: 340)
        }
        keysTable.delegate = self
        keysTable.dataSource = self
        keysTable.onUnmodifiedKey = { [weak self] key in
            guard key == "d" else { return false }
            self?.toggleSecretReveal()
            return true
        }
        keysTable.onBack = { [weak self] in self?.requestBack() }
        keysTable.onFocusSearch = { [weak self] in self?.focusSearch() }
        keysTable.onActivateValue = { [weak self] in
            guard let self, self.valueTextView.isEditable else { return }
            self.view.window?.makeFirstResponder(self.valueTextView)
        }

        searchField.placeholderString = searchPlaceholder
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search ConfigMap or Secret data keys and values")
        valueTextView.delegate = self

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
        saveKeyButton.action = #selector(saveChanges)
        for button in [
            addKeyButton, renameKeyButton, deleteKeyButton, revertKeyButton,
            importKeyButton, exportKeyButton, revealButton, saveKeyButton,
        ] {
            button.controlSize = .small
        }
        editorView.setLeadingActionViews([
            addKeyButton, renameKeyButton, deleteKeyButton, NSView(),
        ])
        editorView.setLeadingAccessoryViews(isSecretObject ? [revealButton] : [])
        editorView.setHeaderActionViews([saveKeyButton])
        editorView.setTrailingActionViews([
            revertKeyButton, importKeyButton, exportKeyButton, NSView(),
        ])
        selectedKeyLabel.setAccessibilityLabel("Selected data key")
        selectedKeyDetailsLabel.setAccessibilityLabel("Selected data key details")
        updateSearchPresentation()
        updateSelectedKeyHeader()
    }

    private var searchPlaceholder: String {
        if isSecretObject && !secretRevealed {
            return "Search keys · show decoded values to search values"
        }
        return "Search keys and values"
    }

    private func splitPaneMinimumWidths() -> KeyValueEditorSplitView.PaneMinimums {
        let available = max(0, splitView.bounds.width - splitView.dividerThickness)
        var left = min(260, max(180, available * 0.30))
        var right = min(340, max(240, available * 0.38))
        let draggableReserve = min(40, available * 0.08)
        let maximumCombined = max(0, available - draggableReserve)
        if left + right > maximumCombined, left + right > 0 {
            let scale = maximumCombined / (left + right)
            left *= scale
            right *= scale
        }
        return KeyValueEditorSplitView.PaneMinimums(
            leading: left,
            trailing: right
        )
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
        rebuildVisibleRows()

        let rows = visibleRows
        let selected = preferredKey.flatMap { key in
            rows.firstIndex { $0.key == key }
        } ?? rows.indices.first
        guard let selected else {
            clearSelectedRow(message: emptyEditorMessage)
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

    private var allEditorRows: [KeyRow] {
        let entries = objectData?.entries ?? []
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return drafts.displayedKeys(baselineKeys: entries.map(\.id)).map { key in
            let metadata = drafts.metadata(for: key)
            let sourceKey = metadata?.sourceKey ?? key
            return KeyRow(
                key: key,
                entry: byKey[sourceKey],
                draft: metadata,
                deleted: drafts.isDeleted(key)
            )
        }
    }

    private var emptyEditorMessage: String {
        if !appliedSearchQuery.isEmpty {
            if isSecretObject && !secretRevealed {
                return "No keys match. Show decoded values to search Secret contents."
            }
            return "No keys or values match the current search."
        }
        return "No Data entries. Use Add Key to create one."
    }

    @objc private func searchChanged() {
        captureSelectedDraft()
        rebuildVisibleRows(selecting: selectedKey)
    }

    private func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    private func rebuildVisibleRows(selecting preferredKey: String? = nil) {
        rebuildVisibleRows()
        reconcileVisibleSelection(preferredKey: preferredKey)
        updateControls()
    }

    private func rebuildVisibleRows() {
        let rows = allEditorRows
        totalRowCount = rows.count
        let query = KeyValueTextSearch.normalizedQuery(searchField.stringValue)
        appliedSearchQuery = query
        searchMatches.removeAll(keepingCapacity: true)
        if query.isEmpty {
            visibleRows = rows
        } else {
            visibleRows = rows.filter { row in
                guard let match = searchMatch(for: row, query: query) else {
                    return false
                }
                searchMatches[row.key] = match
                return true
            }
        }
        keysTable.reloadData()
        updateSearchPresentation()
    }

    private func searchMatch(for row: KeyRow, query: String) -> SearchMatch? {
        let keyMatched = KeyValueTextSearch.contains(row.key, query: query)
        var valueMatch: KeyValueTextSearchMatch?
        if !(objectData?.secret ?? isSecretObject) || secretRevealed {
            if var draft = drafts.snapshot(for: row.key) {
                defer { draft.wipe() }
                if let value = draft.afterValue {
                    valueMatch = KeyValueTextSearch.match(in: value, query: query)
                }
            } else if let entry = row.entry {
                var bytes = copyBytes(from: entry)
                defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
                valueMatch = KeyValueTextSearch.match(in: bytes, query: query)
            }
        }
        guard keyMatched || valueMatch != nil else { return nil }
        return SearchMatch(
            keyMatched: keyMatched,
            valueMatched: valueMatch != nil,
            valueSnippet: valueMatch?.snippet
        )
    }

    private func reconcileVisibleSelection(preferredKey: String?) {
        let wasInstalling = isInstallingState
        isInstallingState = true
        defer { isInstallingState = wasInstalling }
        let row = preferredKey.flatMap { key in
            visibleRows.firstIndex { $0.key == key }
        } ?? visibleRows.indices.first
        guard let row else {
            clearSelectedRow(message: emptyEditorMessage)
            return
        }
        keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        installSelectedRow(visibleRows[row])
    }

    private func clearSelectedRow(message: String) {
        keysTable.deselectAll(nil)
        selectedKey = nil
        selectedEntry = nil
        selectedDraftKind = nil
        selectedCanEditText = false
        valueTextView.string = message
        valueTextView.undoManager?.removeAllActions()
        editorView.clearSyntaxHighlighting()
        updateSelectedKeyHeader()
    }

    private func updateSearchPresentation() {
        searchField.placeholderString = searchPlaceholder
        let total = totalRowCount
        if appliedSearchQuery.isEmpty {
            searchResultLabel.stringValue = "\(total.formatted()) key\(total == 1 ? "" : "s")"
        } else {
            searchResultLabel.stringValue = "\(visibleRows.count.formatted()) of \(total.formatted())"
        }
        searchResultLabel.toolTip = isSecretObject && !secretRevealed
            ? "Secret contents remain concealed. Reveal decoded values to include them in search."
            : nil
    }

    private func updateSelectedKeyHeader() {
        guard let key = selectedKey else {
            selectedKeyLabel.stringValue = "No key selected"
            selectedKeyLabel.setAccessibilityValue("No key selected")
            selectedKeyDetailsLabel.stringValue = ""
            selectedKeyDetailsLabel.setAccessibilityValue("")
            return
        }
        guard let row = allEditorRows.first(where: { $0.key == key }) else {
            selectedKeyLabel.stringValue = "No key selected"
            selectedKeyLabel.setAccessibilityValue("No key selected")
            selectedKeyDetailsLabel.stringValue = ""
            selectedKeyDetailsLabel.setAccessibilityValue("")
            return
        }
        let presentation = rowPresentation(for: row)
        let details = [
            presentation.typeText.capitalized,
            presentation.sizeText,
            presentation.state.displayText,
        ].joined(separator: " · ")
        selectedKeyLabel.stringValue = key
        selectedKeyLabel.toolTip = key
        selectedKeyLabel.setAccessibilityValue(key)
        selectedKeyDetailsLabel.stringValue = details
        selectedKeyDetailsLabel.setAccessibilityValue(details)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let rows = visibleRows
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
        let match = searchMatches[dataRow.key]
        if columnID == "key", match?.keyMatched == true {
            cell.setAccessibilityValue("Key match: \(presentation.keyText)")
            editorView.applySearchHighlight(to: cell.textField, query: appliedSearchQuery)
        } else if columnID == "value", match?.valueMatched == true {
            cell.setAccessibilityValue(
                "Value match: \(valuePreview?.accessibilityValue ?? value)"
            )
            editorView.applySearchHighlight(to: cell.textField, query: appliedSearchQuery)
        } else {
            cell.setAccessibilityValue(
                valuePreview?.accessibilityValue ?? presentation.accessibilityValue
            )
        }
        switch presentation.state {
        case .saved:
            cell.textField?.textColor = .labelColor
        case .added, .modified, .renamed:
            cell.textField?.textColor = columnID == "state" ? .systemOrange : .labelColor
        case .deleted:
            cell.textField?.textColor = columnID == "state" ? .systemRed : .labelColor
        case .conflict:
            cell.textField?.textColor = columnID == "state" ? .systemRed : .labelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === keysTable, !isInstallingState else {
            return
        }
        let previousRow = visibleRows.firstIndex { $0.key == selectedKey }
        captureSelectedDraft()
        let rows = visibleRows
        guard rows.indices.contains(keysTable.selectedRow) else {
            clearSelectedRow(message: emptyEditorMessage)
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
        updateSelectedKeyHeader()
    }

    @objc private func toggleSecretReveal() {
        guard isSecretObject, objectData != nil, !terminalObjectState,
            dataInteractionIdle
        else { return }
        if secretRevealed { captureSelectedDraft() }
        setSecretReveal(!secretRevealed)
        updateControls()
    }

    private func setSecretReveal(_ revealed: Bool) {
        secretRevealed = isSecretObject && revealed
        if isSecretObject && !secretRevealed {
            // A Secret search term can itself disclose plaintext. Revoking
            // reveal authority clears it alongside every value snippet.
            searchField.stringValue = ""
        }
        revealButton.state = secretRevealed ? .on : .off
        rebuildVisibleRows(selecting: selectedKey)
    }

    private func displaySelectedData() {
        guard let data = objectData, let key = selectedKey else {
            editorView.clearSyntaxHighlighting()
            return
        }
        let draftMetadata = drafts.metadata(for: key)
        guard selectedEntry != nil || draftMetadata != nil else {
            editorView.clearSyntaxHighlighting()
            return
        }
        let wasInstalling = isInstallingState
        isInstallingState = true
        defer { isInstallingState = wasInstalling }
        selectedDraftKind = draftMetadata?.kind ?? selectedEntry?.kind
        updateSelectedKeyHeader()
        if data.secret && !secretRevealed {
            let count = draftMetadata?.byteCount ?? Int(selectedEntry?.byteSize ?? 0)
            valueTextView.string = "Secret value concealed · \(count.formatted()) bytes"
            selectedCanEditText = false
            valueTextView.undoManager?.removeAllActions()
            updateValueSyntaxHighlighting()
            updateControls()
            return
        }
        var draft = drafts.snapshot(for: key)
        defer { draft?.wipe() }
        var bytes = draft?.afterValue ?? selectedEntry.map(copyBytes(from:)) ?? Data()
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let kind = draft?.afterKind ?? selectedEntry?.kind ?? .binary
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
        updateValueSyntaxHighlighting()
        updateControls()
        if selectedEntry == nil { showMissingDraftStatus() }
    }

    private func updateValueSyntaxHighlighting() {
        editorView.updateSyntaxHighlighting(
            key: selectedKey,
            isTextValue: selectedCanEditText
        )
    }

    private func valuePreview(for row: KeyRow) -> ValueCellPresentation? {
        if let snippet = searchMatches[row.key]?.valueSnippet {
            return ValueCellPresentation(
                displayText: snippet,
                accessibilityValue: snippet
            )
        }
        let secret = objectData?.secret ?? isSecretObject
        if var draft = drafts.snapshot(for: row.key) {
            defer { draft.wipe() }
            guard let kind = draft.afterKind, let value = draft.afterValue else {
                return row.entry.map { entry in
                    var bytes = copyBytes(from: entry)
                    defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
                    let presentation = DataValuePreviewPresentation(
                        kind: entry.kind,
                        value: bytes,
                        secret: secret,
                        hasRevealAuthority: secretRevealed
                    )
                    return ValueCellPresentation(
                        displayText: presentation.displayText,
                        accessibilityValue: presentation.accessibilityValue
                    )
                }
            }
            let presentation = DataValuePreviewPresentation(
                kind: kind,
                value: value,
                secret: secret,
                hasRevealAuthority: secretRevealed
            )
            return ValueCellPresentation(
                displayText: presentation.displayText,
                accessibilityValue: presentation.accessibilityValue
            )
        }
        guard let entry = row.entry else { return nil }
        var bytes = copyBytes(from: entry)
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        let presentation = DataValuePreviewPresentation(
            kind: entry.kind,
            value: bytes,
            secret: secret,
            hasRevealAuthority: secretRevealed
        )
        return ValueCellPresentation(
            displayText: presentation.displayText,
            accessibilityValue: presentation.accessibilityValue
        )
    }

    private func rowPresentation(for row: KeyRow) -> DataEditorRowPresentation {
        let selected = selectedKey == row.key
        // `visibleRows` is a stable selection/search projection. Draft values
        // can change without rebuilding that projection, so presentation must
        // read the live transaction metadata instead of its row-build snapshot.
        let metadata = drafts.metadata(for: row.key) ?? row.draft
        let storedKind = row.entry?.kind ?? metadata?.kind ?? .binary
        let storedSize = row.entry?.byteSize ?? UInt64(metadata?.byteCount ?? 0)
        let state: DataEditorRowState? = if row.deleted {
            .deleted
        } else {
            switch metadata?.state {
            case .added: .added
            case .modified: .modified
            case .renamed: .renamed
            case .deleted: .deleted
            case nil: nil
            }
        }
        return DataEditorRowPresentation(
            key: row.key,
            storedKind: storedKind,
            storedByteSize: storedSize,
            isSelected: selected,
            draftKind: metadata?.kind,
            draftByteSize: metadata.map { UInt64($0.byteCount) },
            draftState: state,
            hasConflict: conflictedKey == row.key
        )
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
        requestBack()
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
        if saveKeyButton.isEnabled { saveChanges() }
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === valueTextView, !isInstallingState else {
            return
        }
        let editedKey = selectedKey
        captureSelectedDraft()
        updateValueSyntaxHighlighting()
        refreshRowsAfterDraftChange(for: editedKey)
    }

    private func refreshRowsAfterDraftChange(for editedKey: String?) {
        if !appliedSearchQuery.isEmpty, let editedKey,
            let row = visibleRows.first(where: { $0.key == editedKey })
        {
            // Keep the active editor stable even when an edit removes its
            // current match. The next query change performs the authoritative
            // full filter using this draft; the row preview updates now.
            if let match = searchMatch(for: row, query: appliedSearchQuery) {
                searchMatches[editedKey] = match
            } else {
                searchMatches.removeValue(forKey: editedKey)
            }
        }
        updateSearchPresentation()
        updateSelectedKeyHeader()
        updateControls()
        reloadSelectedRow()
    }

    private var currentDraftBytes: Data? {
        guard let data = objectData, let key = selectedKey else { return nil }
        guard !data.secret || secretRevealed else { return nil }
        if selectedCanEditText { return Data(valueTextView.string.utf8) }
        return drafts.snapshot(for: key)?.afterValue ?? selectedEntry.map(copyBytes(from:))
    }

    private var hasSelectedDraftChanges: Bool {
        selectedKey.map(drafts.contains) ?? false
    }

    private var hasAnyDraftChanges: Bool { !drafts.isEmpty }

    private var dataInteractionIdle: Bool {
        operationTask == nil && conflictController == nil
            && dataFileTask == nil && loadTask == nil && recoveryTask == nil
            && valueDiffTask == nil && valueDiffController == nil
            && !authoritativeRefreshInFlight && !authorityUnavailable
    }

    private func updateControls() {
        let hasSelection = selectedKey != nil && !terminalObjectState
        let selectedDeleted = selectedKey.map(drafts.isDeleted) == true
        let idle = dataInteractionIdle
        addKeyButton.isEnabled = objectData != nil && !terminalObjectState && idle
        renameKeyButton.isEnabled = hasSelection && idle && !selectedDeleted
        deleteKeyButton.isEnabled = hasSelection && idle && !selectedDeleted
        let accessible = !(objectData?.secret ?? false) || secretRevealed
        importKeyButton.isEnabled = hasSelection && idle && accessible && !selectedDeleted
        exportKeyButton.isEnabled = hasSelection && idle && accessible && !selectedDeleted
        revertKeyButton.isEnabled = hasSelection && idle && hasSelectedDraftChanges
        saveKeyButton.isEnabled = idle && accessible && hasAnyDraftChanges
        valueTextView.isEditable = hasSelection && idle && accessible
            && selectedCanEditText && !selectedDeleted
        revealButton.isEnabled = objectData != nil && !terminalObjectState && idle
        let reviewingValue = valueDiffTask != nil || valueDiffController != nil
        keysTable.isEnabled = !reviewingValue
        searchField.isEnabled = !reviewingValue
        updateSelectedKeyHeader()
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
        editorView.clearSyntaxHighlighting()
    }

    private func captureSelectedDraft() {
        guard let data = objectData, let key = selectedKey else { return }
        guard !data.secret || secretRevealed else { return }
        guard !drafts.isDeleted(key) else { return }
        guard var value = currentDraftBytes else { return }
        defer { value.resetBytes(in: value.startIndex..<value.endIndex) }
        if let entry = selectedEntry {
            drafts.update(
                key: key,
                kind: selectedDraftKind ?? entry.kind,
                value: value,
                baselineKind: entry.kind,
                valueMatchesBaseline: valueMatchesEntry(value, entry: entry),
                baselineContentHash: entry.contentHash
            )
        } else if let metadata = drafts.metadata(for: key) {
            drafts.update(
                key: key,
                kind: selectedDraftKind ?? metadata.kind,
                value: value,
                baselineKind: metadata.kind,
                valueMatchesBaseline: false,
                baselineContentHash: Data()
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
            "Added key is staged locally · Save Changes creates it"
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

    @objc private func backPressed() { requestBack() }

    func requestBack() {
        guard operationTask == nil, conflictController == nil,
            dataFileTask == nil, valueDiffTask == nil,
            valueDiffController == nil
        else {
            NSSound.beep()
            return
        }
        captureSelectedDraft()
        if hasAnyDraftChanges {
            let shouldDiscard = discardChangesConfirmation?()
                ?? KeyValueEditorDiscardConfirmation.shouldDiscard(
                    editorTitle: isSecretObject ? "Secret Data" : "ConfigMap Data",
                    targetDetails: mutationConfirmationIdentityText
                )
            guard shouldDiscard else {
                publishStatus(WorkspaceStatus("Continue editing · local changes preserved"))
                return
            }
            releaseDrafts()
        }
        onBack?()
    }
}

extension ObjectDataViewController {
    @objc private func revertCurrentKey() {
        guard let key = selectedKey else { return }
        let preferredKey = drafts.revert(key: key)
        conflictedKey = nil
        rebuildVisibleRows(selecting: preferredKey)
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
        let keys = Set(allEditorRows.map(\.key))
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
                    self?.stageAddedDataKey(key: key, kind: .binary, value: bytes)
                }
            }
        } else {
            stageAddedDataKey(key: key, kind: .text, value: Data())
        }
    }

    private func stageAddedDataKey(
        key: String,
        kind: DataValueKind,
        value: Data
    ) {
        drafts.add(key: key, kind: kind, value: value)
        searchField.stringValue = ""
        rebuildVisibleRows(selecting: key)
        publishStatus(WorkspaceStatus("Added \(key) locally · Save Changes to apply"))
        if kind == .text { view.window?.makeFirstResponder(valueTextView) }
    }

    @objc private func renameDataKey() {
        captureSelectedDraft()
        guard objectData != nil, let key = selectedKey, !drafts.isDeleted(key) else { return }
        let request = KeyValueEditorKeyPrompt.Request(
            action: .rename,
            singularTitle: "Key",
            currentValue: key,
            informativeText: confirmationInformativeText(
                note: "The rename remains local until Save Changes."
            )
        )
        guard let newKey = KeyValueEditorKeyPrompt.run(request) else { return }
        let keys = Set(allEditorRows.map(\.key))
        if let message = KubernetesDataKeyValidator.validationMessage(
            for: newKey,
            existingKeys: keys,
            allowingExistingKey: key
        ) {
            showValidation(message)
            return
        }
        guard newKey != key, var value = currentDraftBytes else { return }
        defer { value.resetBytes(in: value.startIndex..<value.endIndex) }
        let kind = selectedDraftKind ?? selectedEntry?.kind ?? .binary
        drafts.rename(
            key: key,
            to: newKey,
            baselineKind: selectedEntry?.kind ?? kind,
            baselineValue: value,
            baselineContentHash: selectedEntry?.contentHash ?? Data()
        )
        searchField.stringValue = ""
        rebuildVisibleRows(selecting: newKey)
        publishStatus(WorkspaceStatus(
            "Renamed \(key) to \(newKey) locally · Save Changes to apply"
        ))
    }

    @objc private func deleteDataKey() {
        captureSelectedDraft()
        guard let key = selectedKey, !drafts.isDeleted(key) else { return }
        let deletionKey = drafts.sourceKey(for: key) ?? key
        drafts.delete(key: key, baselineContentHash: selectedEntry?.contentHash)
        rebuildVisibleRows(selecting: drafts.isDeleted(deletionKey) ? deletionKey : nil)
        publishStatus(WorkspaceStatus(
            "Marked \(deletionKey) for deletion · Revert or Save Changes"
        ))
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
        let row = allEditorRows.first { $0.key == key }
        let entry = row?.entry
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
                baselineKind: entry.kind,
                valueMatchesBaseline: valueMatchesEntry(bytes, entry: entry),
                baselineContentHash: entry.contentHash
            )
        } else if let metadata = drafts.metadata(for: key) {
            drafts.update(
                key: key,
                kind: replacementKind,
                value: bytes,
                baselineKind: metadata.kind,
                valueMatchesBaseline: false,
                baselineContentHash: Data()
            )
        }
        let preferredKey = selectedKey
        if preferredKey == key {
            selectedDraftKind = replacementKind
            displaySelectedData()
        }
        rebuildVisibleRows(selecting: preferredKey)
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
        guard allEditorRows.contains(where: { $0.key == key }) else { return }
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

    @objc private func saveChanges() {
        captureSelectedDraft()
        guard let data = objectData, valueDiffTask == nil,
            valueDiffController == nil, !drafts.isEmpty,
            !data.secret || secretRevealed
        else { return }

        var snapshots = drafts.allSnapshots()
        defer {
            for index in snapshots.indices { snapshots[index].wipe() }
        }
        let entries = Dictionary(uniqueKeysWithValues: data.entries.map { ($0.id, $0) })
        var inputs: [KeyValueDiffInput] = []
        inputs.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let beforeEntry = snapshot.beforeKey.flatMap { entries[$0] }
            inputs.append(KeyValueDiffInput(
                beforeKey: snapshot.beforeKey,
                afterKey: snapshot.afterKey,
                beforeKind: beforeEntry?.kind,
                beforeValue: beforeEntry.map(copyBytes(from:)),
                afterKind: snapshot.afterKind,
                afterValue: snapshot.afterValue,
                sensitive: data.secret
            ))
        }
        var mutations = drafts.mutations()
        reviewChanges(inputs: inputs, mutations: mutations)
        Self.wipeMutationValues(&mutations)
    }

    private func reviewChanges(
        inputs: [KeyValueDiffInput],
        mutations: [DataMutationKind]
    ) {
        guard valueDiffTask == nil, valueDiffController == nil,
            !inputs.isEmpty, !mutations.isEmpty
        else { return }
        publishStatus(WorkspaceStatus("Preparing change review…", busy: true))
        valueDiffTask = Task { [weak self, inputs, mutations] in
            var protectedInputs = inputs
            var protectedMutations = mutations
            defer {
                for index in protectedInputs.indices { protectedInputs[index].wipe() }
                Self.wipeMutationValues(&protectedMutations)
            }
            guard let self, !Task.isCancelled, objectData != nil,
                !authorityUnavailable, !terminalObjectState
            else { return }
            defer { finishValueDiffReviewIfNeeded() }

            let controller = KeyValueDiffConfirmationWindowController(
                editorTitle: isSecretObject ? "Secret Data" : "ConfigMap Data",
                targetDetails: mutationConfirmationIdentityText,
                inputs: protectedInputs
            )
            valueDiffController = controller
            publishStatus(WorkspaceStatus("Review \(inputs.count.formatted()) staged changes"))
            updateControls()
            let choice: KeyValueDiffConfirmationWindowController.Choice
            if let valueChangeConfirmation {
                choice = await valueChangeConfirmation(controller)
            } else if let parent = view.window {
                choice = await controller.runSheet(for: parent)
            } else {
                choice = .keepEditing
            }
            controller.discardTransientPresentation()
            guard !Task.isCancelled, valueDiffController === controller else { return }
            valueDiffController = nil
            valueDiffTask = nil
            updateControls()

            switch choice {
            case .save:
                submitMutations(protectedMutations)
            case .keepEditing:
                publishStatus(WorkspaceStatus("Save cancelled · local changes preserved"))
                updateControls()
                view.window?.makeFirstResponder(keysTable)
            }
        }
        updateControls()
    }

    private func cancelValueDiffReview() {
        valueDiffTask?.cancel()
        valueDiffController?.cancelReview()
        valueDiffController = nil
        valueDiffTask = nil
    }

    private func finishValueDiffReviewIfNeeded() {
        guard valueDiffTask != nil || valueDiffController != nil else { return }
        valueDiffController?.discardTransientPresentation()
        valueDiffController = nil
        valueDiffTask = nil
        updateControls()
    }

    private func submitMutations(_ mutations: [DataMutationKind]) {
        guard let data = objectData, operationTask == nil,
            !authorityUnavailable, !mutations.isEmpty
        else { return }
        conflictedKey = nil
        publishStatus(WorkspaceStatus("Saving key/value data…", busy: true))
        operationTask = Task { [weak self, provider, identity, mutations] in
            var protectedMutations = mutations
            defer { Self.wipeMutationValues(&protectedMutations) }
            guard let self else { return }
            defer {
                operationTask = nil
                updateControls()
            }
            do {
                let stream = try await provider.updateData(
                    identity: identity,
                    expectedResourceVersion: data.resourceVersion,
                    mutations: protectedMutations
                )
                var completed = false
                for try await progress in stream where progress.state.isTerminal {
                    if progress.state != .succeeded {
                        throw progress.issue ?? ClusterManagerIssue(
                            category: .conflict,
                            reason: "DataUpdateFailed",
                            message: "The changes were not saved. Your local transaction remains in the editor.",
                            operation: "update key/value data"
                        )
                    }
                    completed = true
                    let count = drafts.changedKeyCount
                    let preferredKey = selectedKey
                    drafts.removeAll()
                    conflictedKey = nil
                    loadTask?.cancel()
                    loadTask = nil
                    loadData(
                        preservingDrafts: true,
                        preferredKey: preferredKey,
                        lockingUntilInstalled: true,
                        successMessage: "Saved \(count.formatted()) key \(count == 1 ? "change" : "changes")"
                    )
                    break
                }
                guard completed else {
                    throw ClusterManagerIssue(
                        category: .unavailable,
                        reason: "DataMutationEnded",
                        message: "The Data mutation ended without a final result. Your local changes remain open.",
                        retryable: true,
                        operation: "update key/value data"
                    )
                }
            } catch {
                if Self.clusterIssue(from: error)?.category == .conflict {
                    await prepareBatchConflictRecovery(mutations: protectedMutations)
                } else {
                    show(error: error)
                }
            }
        }
        updateControls()
    }

    private nonisolated static func wipeMutationValues(
        _ mutations: inout [DataMutationKind]
    ) {
        for index in mutations.indices {
            guard case .set(let key, let kind, var value, let hash) = mutations[index] else {
                continue
            }
            value.resetBytes(in: value.startIndex..<value.endIndex)
            mutations[index] = .set(
                key: key,
                kind: kind,
                value: Data(),
                expectedContentHash: hash
            )
        }
    }

    private func prepareBatchConflictRecovery(
        mutations: [DataMutationKind]
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
            guard let mutation = firstConflictingMutation(
                mutations,
                currentEntries: currentData.entries
            ) else {
                try install(
                    currentData,
                    preservingDrafts: true,
                    preferredKey: selectedKey
                )
                publishStatus(WorkspaceStatus(
                    "The resource changed outside the staged keys · review and Save Changes again",
                    severity: .warning
                ))
                return
            }
            let displayKey = drafts.displayKey(forSourceKey: mutation.sourceKey)
                ?? mutation.sourceKey
            let currentEntry = currentData.entries.first { $0.id == mutation.sourceKey }
            conflictedKey = displayKey
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
                displayKey: displayKey,
                currentData: currentData,
                currentEntry: currentEntry,
                retryPlan: retryPlan
            )
        } catch {
            publishStatus(WorkspaceStatus(
                "Conflict · current server data could not be loaded · local edit preserved",
                severity: .error
            ))
        }
    }

    private func presentConflict(
        mutation: DataMutationKind,
        displayKey: String,
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
                _ = drafts.revert(key: displayKey)
                installCurrentDataAfterConflict(currentData, selecting: mutation.sourceKey)
                publishStatus(WorkspaceStatus(
                    "Discarded the conflicting local change and loaded current server data"
                ))
            case .copyLocal:
                copyLocalConflictValueToPasteboard(mutation: mutation)
                publishStatus(WorkspaceStatus(
                    "Copied local value · local edit preserved"
                ))
            case .retry:
                guard case .retry = retryPlan else { return }
                conflictedKey = nil
                var currentValue = currentEntry.map(copyBytes(from:))
                defer {
                    if var protectedValue = currentValue {
                        currentValue = nil
                        protectedValue.resetBytes(
                            in: protectedValue.startIndex..<protectedValue.endIndex
                        )
                    }
                }
                drafts.rebase(
                    displayKey: displayKey,
                    currentKind: currentEntry?.kind,
                    currentValue: currentValue,
                    currentContentHash: currentEntry?.contentHash
                )
                installCurrentDataAfterConflict(currentData, selecting: displayKey)
                publishStatus(WorkspaceStatus(
                    "Accepted the current key as the new baseline · review and Save Changes again",
                    severity: .warning
                ))
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

    private func firstConflictingMutation(
        _ mutations: [DataMutationKind],
        currentEntries: [ObjectDataEntry]
    ) -> DataMutationKind? {
        let current = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        for mutation in mutations {
            let entry = current[mutation.sourceKey]
            let expectedHash: Data
            switch mutation {
            case .set(_, _, _, let hash), .delete(_, let hash), .rename(_, _, let hash):
                expectedHash = hash
            }
            if expectedHash.isEmpty {
                if entry != nil { return mutation }
            } else if entry?.contentHash != expectedHash {
                return mutation
            }
            if let destination = mutation.destinationKey,
                destination != mutation.sourceKey,
                current[destination] != nil
            {
                return mutation
            }
        }
        return nil
    }

    private static func clusterIssue(from error: Error) -> ClusterManagerIssue? {
        error as? ClusterManagerIssue
    }
}
