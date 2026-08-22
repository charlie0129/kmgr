import AppKit
import KmgrCore

/// The single ConfigMap/Secret key-value surface. It owns the authoritative
/// UID-pinned Data GET and every decoded value remains process-memory-only.
@MainActor
final class ObjectDataViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, @preconcurrency NSSplitViewDelegate, NSTextViewDelegate,
    WorkspaceStatusPublishing
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
    private let valueChangeConfirmation: @MainActor (
        DataValueDiffConfirmationWindowController
    ) -> DataValueDiffConfirmationWindowController.Choice

    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let splitView = ObjectDataSplitView()
    private let keysTable = ObjectDataKeysTableView()
    private let searchField = NSSearchField()
    private let searchResultLabel = NSTextField(labelWithString: "")
    private let valueTextView = NSTextView()
    private let valueScroll = NSScrollView()
    private let selectedKeyLabel = NSTextField(labelWithString: "No key selected")
    private let selectedKeyDetailsLabel = NSTextField(labelWithString: "")
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
    private var visibleRows: [KeyRow] = []
    private var totalRowCount = 0
    private var searchMatches: [String: SearchMatch] = [:]
    private var appliedSearchQuery = ""
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
    private var valueDiffTask: Task<Void, Never>?
    private var dataFileGeneration: UInt64 = 0
    private var authoritativeRefreshInFlight = false
    private var establishedInitialSplitPosition = false
    private var conflictController: DataConflictWindowController?
    private var valueDiffController: DataValueDiffConfirmationWindowController?

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
        valueChangeConfirmation: @escaping @MainActor (
            DataValueDiffConfirmationWindowController
        ) -> DataValueDiffConfirmationWindowController.Choice = {
            $0.runModal()
        }
    ) {
        precondition(Self.supports(identity), "Data requires a core/v1 ConfigMap or Secret")
        self.identity = identity
        self.session = session
        self.provider = provider
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.dataFileReader = dataFileReader
        self.dataFileWriter = dataFileWriter
        self.valueChangeConfirmation = valueChangeConfirmation
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
        establishSplitPositionIfNeeded()
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
        cancelValueDiffReview()
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
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.identifier = .init("object-data-split")
        splitView.delegate = self
        splitView.autosaveName = "kmgr.object-data-master-detail"
        splitView.onResetDivider = { [weak self] in self?.resetSplitPosition() }
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
        keysTable.onFocusSearch = { [weak self] in self?.focusSearch() }
        let keyScroll = NSScrollView()
        keyScroll.identifier = .init("object-data-keys-scroll")
        keyScroll.documentView = keysTable
        keyScroll.hasVerticalScroller = true
        keyScroll.hasHorizontalScroller = true
        keyScroll.autohidesScrollers = true

        searchField.placeholderString = searchPlaceholder
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Search ConfigMap or Secret data keys and values")
        searchResultLabel.textColor = .secondaryLabelColor
        searchResultLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchResultLabel.alignment = .right
        searchResultLabel.lineBreakMode = .byClipping
        searchResultLabel.setContentHuggingPriority(.required, for: .horizontal)

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
        for button in [
            addKeyButton, renameKeyButton, deleteKeyButton, revertKeyButton,
            importKeyButton, exportKeyButton, revealButton, saveKeyButton,
        ] {
            button.controlSize = .small
        }

        let searchRow = NSStackView(views: [searchField, searchResultLabel])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        let keyControls = NSStackView(views: [
            addKeyButton, renameKeyButton, deleteKeyButton, NSView(),
        ])
        keyControls.orientation = .horizontal
        keyControls.alignment = .centerY
        keyControls.spacing = 8
        let keyPane = NSView()
        keyPane.identifier = .init("object-data-keys-pane")
        for subview in [searchRow, keyControls, revealButton, keyScroll] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            keyPane.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            searchRow.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor, constant: 8),
            searchRow.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor, constant: -8),
            searchRow.topAnchor.constraint(equalTo: keyPane.topAnchor, constant: 7),
            keyControls.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor, constant: 8),
            keyControls.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor, constant: -8),
            keyControls.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 6),
            revealButton.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor, constant: 8),
            revealButton.topAnchor.constraint(equalTo: keyControls.bottomAnchor, constant: 4),
            keyScroll.leadingAnchor.constraint(equalTo: keyPane.leadingAnchor),
            keyScroll.trailingAnchor.constraint(equalTo: keyPane.trailingAnchor),
            keyScroll.topAnchor.constraint(
                equalTo: isSecretObject
                    ? revealButton.bottomAnchor
                    : keyControls.bottomAnchor,
                constant: 6
            ),
            keyScroll.bottomAnchor.constraint(equalTo: keyPane.bottomAnchor),
        ])

        selectedKeyLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        selectedKeyLabel.lineBreakMode = .byTruncatingMiddle
        selectedKeyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectedKeyLabel.setAccessibilityLabel("Selected data key")
        selectedKeyDetailsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        selectedKeyDetailsLabel.textColor = .secondaryLabelColor
        selectedKeyDetailsLabel.lineBreakMode = .byTruncatingTail
        selectedKeyDetailsLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        selectedKeyDetailsLabel.setAccessibilityLabel("Selected data key details")
        let selectedKeyHeader = NSStackView(views: [
            selectedKeyLabel, selectedKeyDetailsLabel,
        ])
        selectedKeyHeader.orientation = .vertical
        selectedKeyHeader.alignment = .leading
        selectedKeyHeader.spacing = 1
        let header = NSStackView(views: [selectedKeyHeader, NSView(), saveKeyButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let valueControls = NSStackView(views: [
            revertKeyButton, importKeyButton, exportKeyButton, NSView(),
        ])
        valueControls.orientation = .horizontal
        valueControls.alignment = .centerY
        valueControls.spacing = 8
        let editor = NSView()
        editor.identifier = .init("object-data-editor-pane")
        header.translatesAutoresizingMaskIntoConstraints = false
        valueControls.translatesAutoresizingMaskIntoConstraints = false
        valueScroll.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(header)
        editor.addSubview(valueControls)
        editor.addSubview(valueScroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: editor.topAnchor, constant: 7),
            valueControls.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 8),
            valueControls.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -8),
            valueControls.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            valueScroll.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            valueScroll.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            valueScroll.topAnchor.constraint(equalTo: valueControls.bottomAnchor, constant: 5),
            valueScroll.bottomAnchor.constraint(equalTo: editor.bottomAnchor),
        ])
        splitView.addArrangedSubview(keyPane)
        splitView.addArrangedSubview(editor)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        updateSearchPresentation()
        updateSelectedKeyHeader()
    }

    private var searchPlaceholder: String {
        if isSecretObject && !secretRevealed {
            return "Search keys · show decoded values to search values"
        }
        return "Search keys and values"
    }

    private func establishSplitPositionIfNeeded() {
        guard !establishedInitialSplitPosition,
            splitView.arrangedSubviews.count == 2,
            splitView.bounds.width > splitView.dividerThickness
        else { return }
        establishedInitialSplitPosition = true
        let minimums = splitPaneMinimumWidths()
        let leftWidth = splitView.arrangedSubviews[0].frame.width
        let rightWidth = splitView.arrangedSubviews[1].frame.width
        if leftWidth < minimums.left || rightWidth < minimums.right {
            resetSplitPosition()
        }
    }

    private func resetSplitPosition() {
        guard splitView.arrangedSubviews.count == 2 else { return }
        let available = max(0, splitView.bounds.width - splitView.dividerThickness)
        guard available > 0 else { return }
        let minimums = splitPaneMinimumWidths()
        let preferred = available * 0.45
        let position = min(
            max(preferred, minimums.left),
            max(minimums.left, available - minimums.right)
        )
        splitView.setPosition(position, ofDividerAt: 0)
    }

    private func splitPaneMinimumWidths() -> (left: CGFloat, right: CGFloat) {
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
        return (left, right)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView, dividerIndex == 0 else {
            return proposedMinimumPosition
        }
        return max(proposedMinimumPosition, splitView.bounds.minX + splitPaneMinimumWidths().left)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView, dividerIndex == 0 else {
            return proposedMaximumPosition
        }
        return min(proposedMaximumPosition, splitView.bounds.maxX - splitPaneMinimumWidths().right)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(
        _ splitView: NSSplitView,
        shouldCollapseSubview subview: NSView,
        forDoubleClickOnDividerAt dividerIndex: Int
    ) -> Bool {
        false
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
        let storedKeys = Set(entries.map(\.id))
        let missing = drafts.keys
            .filter { !storedKeys.contains($0) }
            .sorted()
            .compactMap { key -> KeyRow? in
                drafts.metadata(for: key).map { .missingDraft(key: key, metadata: $0) }
            }
        return entries.map(KeyRow.stored) + missing
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
        let query = ObjectDataTextSearch.normalizedQuery(searchField.stringValue)
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
        let keyMatched = ObjectDataTextSearch.contains(row.key, query: query)
        var valueMatch: ObjectDataTextSearchMatch?
        if !(objectData?.secret ?? isSecretObject) || secretRevealed {
            if var draft = drafts.snapshot(for: row.key) {
                defer { draft.wipe() }
                valueMatch = ObjectDataTextSearch.match(in: draft.value, query: query)
            } else if let entry = row.entry {
                var bytes = copyBytes(from: entry)
                defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
                valueMatch = ObjectDataTextSearch.match(in: bytes, query: query)
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
        let row: KeyRow
        if let selectedEntry {
            row = .stored(selectedEntry)
        } else if let metadata = drafts.metadata(for: key) {
            row = .missingDraft(key: key, metadata: metadata)
        } else {
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
            applySearchHighlight(to: cell.textField, query: appliedSearchQuery)
        } else if columnID == "value", match?.valueMatched == true {
            cell.setAccessibilityValue(
                "Value match: \(valuePreview?.accessibilityValue ?? value)"
            )
            applySearchHighlight(to: cell.textField, query: appliedSearchQuery)
        } else {
            cell.setAccessibilityValue(
                valuePreview?.accessibilityValue ?? presentation.accessibilityValue
            )
        }
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
        guard let data = objectData, let key = selectedKey else { return }
        let draftMetadata = drafts.metadata(for: key)
        guard selectedEntry != nil || draftMetadata != nil else { return }
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
            let presentation = DataValuePreviewPresentation(
                kind: draft.kind,
                value: draft.value,
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

    private func applySearchHighlight(to field: NSTextField?, query: String) {
        guard let field, !query.isEmpty, !field.stringValue.isEmpty else { return }
        let value = field.stringValue as NSString
        let attributed = NSMutableAttributedString(string: field.stringValue)
        var remaining = NSRange(location: 0, length: value.length)
        while remaining.length > 0 {
            let match = value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: remaining
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35),
                range: match
            )
            let next = match.location + match.length
            remaining = NSRange(location: next, length: value.length - next)
        }
        field.attributedStringValue = attributed
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
        let editedKey = selectedKey
        captureSelectedDraft()
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
        return drafts.snapshot(for: key)?.value ?? selectedEntry.map(copyBytes(from:))
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
        rebuildVisibleRows(selecting: selectedEntry == nil ? nil : key)
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
        let keys = Set(allEditorRows.map(\.key))
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
        let preferredKey = selectedKey
        if preferredKey == key {
            selectedDraftKind = replacementKind
            selectedEntry = entry
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

    @objc private func saveCurrentKey() {
        captureSelectedDraft()
        guard let data = objectData, let key = selectedKey,
            valueDiffTask == nil, valueDiffController == nil,
            var draft = drafts.snapshot(for: key)
        else { return }
        defer { draft.wipe() }
        let input = DataValueDiffInput(
            key: key,
            beforeKind: selectedEntry?.kind,
            beforeValue: selectedEntry.map(copyBytes(from:)),
            afterKind: draft.kind,
            afterValue: draft.value,
            secret: data.secret
        )
        let mutation = DataMutationKind.set(
            key: key,
            kind: draft.kind,
            value: draft.value,
            expectedContentHash: selectedEntry == nil ? Data() : draft.expectedContentHash
        )
        reviewValueChange(input: input, mutation: mutation)
    }

    private func reviewValueChange(
        input: DataValueDiffInput,
        mutation: DataMutationKind
    ) {
        guard valueDiffTask == nil, valueDiffController == nil else { return }
        publishStatus(WorkspaceStatus("Preparing value comparison…", busy: true))
        valueDiffTask = Task { [weak self, mutation] in
            var protectedInput = input
            defer { protectedInput.wipe() }
            do {
                let presentation = try await Self.prepareValueDiff(protectedInput)
                guard let self else { return }
                defer { finishValueDiffReviewIfNeeded() }
                guard !Task.isCancelled,
                    selectedKey == protectedInput.key,
                    objectData != nil,
                    !authorityUnavailable,
                    !terminalObjectState,
                    !protectedInput.secret || secretRevealed
                else { return }

                let controller = DataValueDiffConfirmationWindowController(
                    targetDetails: mutationConfirmationIdentityText,
                    presentation: presentation
                )
                valueDiffController = controller
                publishStatus(WorkspaceStatus("Review value change"))
                updateControls()
                let choice = valueChangeConfirmation(controller)
                controller.discardTransientPresentation()
                guard !Task.isCancelled, valueDiffController === controller else { return }
                valueDiffController = nil
                valueDiffTask = nil
                updateControls()

                switch choice {
                case .save:
                    performMutation(mutation, successMessage: "Saved \(protectedInput.key)")
                case .keepEditing:
                    publishStatus(WorkspaceStatus("Save cancelled · local edit preserved"))
                    updateControls()
                    view.window?.makeFirstResponder(valueTextView)
                }
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                valueDiffController?.discardTransientPresentation()
                valueDiffController = nil
                valueDiffTask = nil
                show(error: error)
                updateControls()
            }
        }
        updateControls()
    }

    private nonisolated static func prepareValueDiff(
        _ input: DataValueDiffInput
    ) async throws -> DataValueDiffPresentation {
        try Task.checkCancellation()
        let presentation = DataValueDiffPresentation(input: input)
        try Task.checkCancellation()
        return presentation
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
private final class ObjectDataSplitView: NSSplitView {
    var onResetDivider: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let location = convert(event.locationInWindow, from: nil)
            if dividerIndex(at: location) != nil {
                onResetDivider?()
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func dividerIndex(at point: NSPoint) -> Int? {
        guard arrangedSubviews.count > 1 else { return nil }
        for index in 0..<(arrangedSubviews.count - 1) {
            let preceding = arrangedSubviews[index].frame
            let divider: NSRect
            if isVertical {
                divider = NSRect(
                    x: preceding.maxX - 3,
                    y: bounds.minY,
                    width: dividerThickness + 6,
                    height: bounds.height
                )
            } else {
                divider = NSRect(
                    x: bounds.minX,
                    y: preceding.maxY - 3,
                    width: bounds.width,
                    height: dividerThickness + 6
                )
            }
            if divider.contains(point) { return index }
        }
        return nil
    }
}

@MainActor
private final class ObjectDataKeysTableView: NSTableView {
    var onToggleReveal: (() -> Void)?
    var onBack: (() -> Void)?
    var onFocusSearch: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ])
        switch (event.charactersIgnoringModifiers?.lowercased(), event.keyCode) {
        case ("d", _) where modifiers.isEmpty:
            onToggleReveal?()
        case ("/", _) where modifiers.isEmpty:
            onFocusSearch?()
        case ("f", _) where modifiers == .command:
            onFocusSearch?()
        case (_, 53) where modifiers.isEmpty:
            onBack?()
        default:
            super.keyDown(with: event)
        }
    }
}
