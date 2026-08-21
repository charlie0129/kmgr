import AppKit
import KmgrCore

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    struct Context {
        var session: OpenedClusterSession
        var resources: [DiscoveredResource]
        var namespaces: [String]
        var namespaceScope: NamespaceSelection
        let commandContext: CommandContext
        var recentObjects: [RecentObject]
    }

    private enum Mode {
        case root
        case objects(DiscoveredResource)
    }

    private enum Item: Hashable {
        fileprivate enum StableIdentity: Hashable {
            case operation(PaletteOperation)
            case resource(String)
            case searchResource(String)
            case namespace(String)
            case object(String, String, String, ResourceUID)
        }

        case operation(PaletteOperation)
        case result(PaletteResult)

        fileprivate var stableIdentity: StableIdentity {
            switch self {
            case .operation(let operation):
                return .operation(operation)
            case .result(.resource(let resource)):
                return .resource(resource.id)
            case .result(.searchResource(let resource)):
                return .searchResource(resource.id)
            case .result(.namespace(let namespace)):
                return .namespace(namespace)
            case .result(.object(let result)):
                let identity = result.identity
                return .object(
                    identity.group,
                    identity.version,
                    identity.resource,
                    identity.uid
                )
            }
        }

        var title: String {
            switch self {
            case .operation(let operation): operation.title
            case .result(let result): result.title
            }
        }

        var detail: String {
            switch self {
            case .operation:
                return "Captured resource selection"
            case .result(.resource(let resource)):
                return resource.group.isEmpty ? resource.resource : "\(resource.resource).\(resource.group)"
            case .result(.searchResource):
                return "Choose this kind, then search only its objects"
            case .result(.namespace):
                return "Change this workspace's namespace scope"
            case .result(.object(let result)):
                switch result.origin {
                case .authoritative:
                    return result.detailText
                case .cached:
                    return result.detailText + " · Cached — opens with a fresh GET"
                case .recent:
                    return result.detailText + " · Opens with a fresh GET"
                }
            }
        }

        var imageName: String {
            switch self {
            case .operation(let operation):
                switch operation {
                case .openDetails: "info.circle"
                case .openYAML: "doc.plaintext"
                case .openEvents: "clock.arrow.circlepath"
                case .openLogs: "text.alignleft"
                case .openExec: "terminal"
                case .startPortForward: "arrow.left.arrow.right"
                case .delete: "trash"
                case .scale: "arrow.up.left.and.arrow.down.right"
                case .restart: "arrow.clockwise"
                case .editMetadata: "tag"
                case .copyName, .copyNamespacedName, .copyReference: "doc.on.doc"
                }
            case .result(.resource): "tablecells"
            case .result(.searchResource): "magnifyingglass"
            case .result(.namespace): "folder"
            case .result(.object): "shippingbox"
            }
        }

        static func operationDetail(
            _ operation: PaletteOperation,
            context: CommandContext
        ) -> String {
            let selection = context.selectedIdentities
            if let reference = context.selectionReference {
                let noun = reference.selectedCount == 1 ? "resource" : "resources"
                return "\(reference.selectedCount.formatted()) captured \(noun) · immutable token"
            }
            guard let only = selection.first, selection.count == 1 else {
                return "\(selection.count.formatted()) captured resources"
            }
            let qualified = only.namespace.isEmpty ? only.name : "\(only.namespace)/\(only.name)"
            switch operation {
            case .copyName, .copyNamespacedName, .copyReference:
                return "Copy from captured \(qualified)"
            default:
                return "Captured \(qualified) · UID-pinned"
            }
        }
    }

    private let context: Context
    private let objectSearchProvider: any ObjectSearchProviding
    private let searchID = UUID().uuidString.lowercased()
    private let searchField = PaletteSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let scopeLabel = NSTextField(labelWithString: "")
    private var mode = Mode.root
    private var items: [Item] = []
    // Query revisions intentionally overlap until the engine confirms that a
    // replacement attached to the shared metadata scan. Keeping every local
    // task reachable also lets palette dismissal cancel a replacement that
    // has not reached the engine yet without stranding its predecessor.
    private var searchTasks: [UInt64: Task<Void, Never>] = [:]
    private var debounceTask: Task<Void, Never>?
    private var rootSearchTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var queryRevision: UInt64 = 0
    private var runningRevisions: Set<UInt64> = []
    private var gate = GenerationSequenceGate()
    private var resultByIdentity: [String: ObjectSearchResult] = [:]
    private var latestProgress: ObjectSearchProgress?
    private var closing = false

    private static let numberedShortcutCount = 9

    var onOpenResource: ((DiscoveredResource) -> Void)?
    var onChangeNamespace: ((String) -> Void)?
    var onOpenObject: ((ResourceIdentity) -> Void)?
    var onOperation: ((PaletteOperation, CommandContext) -> Void)?
    var onClose: (() -> Void)?

    init(
        context: Context,
        objectSearchProvider: any ObjectSearchProviding
    ) {
        self.context = context
        self.objectSearchProvider = objectSearchProvider
        let window = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Command Palette"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.transient, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.handleCancel() }
        window.onToggle = { [weak self] in self?.dismissPalette() }
        window.onChooseNumberedItem = { [weak self] index in
            self?.chooseNumberedItem(at: index) ?? false
        }
        configureContent(in: window)
        updateRootItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        positionRelativeToParent()
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        rootSearchTask?.cancel()
        cancelPendingSearch()
        onClose?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("palette-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PaletteResultCell
            ?? PaletteResultCell(identifier: identifier)
        let item = items[row]
        let detail: String
        if case .operation(let operation) = item {
            detail = Item.operationDetail(
                operation,
                context: context.commandContext
            )
        } else {
            detail = item.detail
        }
        cell.configure(
            title: item.title,
            detail: detail,
            image: NSImage(systemSymbolName: item.imageName, accessibilityDescription: nil),
            shortcut: row < Self.numberedShortcutCount ? "⌘\(row + 1)" : nil
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection is intentionally row-based only within this transient
        // surface; all resource/object actions carry stable identities.
    }

    func controlTextDidChange(_ obj: Notification) {
        switch mode {
        case .root:
            updateRootItems()
        case .objects:
            scheduleObjectSearch()
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleCancel()
            return true
        default:
            return false
        }
    }

    @objc private func activateSelection() {
        guard activateItem(at: tableView.selectedRow) else {
            NSSound.beep()
            return
        }
    }

    @discardableResult
    private func activateItem(at row: Int) -> Bool {
        guard items.indices.contains(row) else { return false }
        let item = items[row]
        switch item {
        case .operation(let operation):
            let callback = onOperation
            let commandContext = context.commandContext
            closeAndRun { callback?(operation, commandContext) }
        case .result(.resource(let resource)):
            let callback = onOpenResource
            closeAndRun { callback?(resource) }
        case .result(.searchResource(let resource)):
            enterObjectSearch(resource)
        case .result(.namespace(let namespace)):
            let callback = onChangeNamespace
            closeAndRun { callback?(namespace) }
        case .result(.object(let result)):
            let callback = onOpenObject
            closeAndRun { callback?(result.identity) }
        }
        return true
    }

    private func chooseNumberedItem(at index: Int) -> Bool {
        guard (0..<Self.numberedShortcutCount).contains(index),
            items.indices.contains(index)
        else { return false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        return activateItem(at: index)
    }

    private func configureContent(in window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true

        searchField.placeholderString = "Type a command or resource kind"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.font = .systemFont(ofSize: 20)
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Command palette search")

        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        scopeLabel.lineBreakMode = .byTruncatingTail
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("result"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.setAccessibilityLabel("Command palette results")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setAccessibilityLabel("Command palette status")

        root.addSubview(searchField)
        root.addSubview(scopeLabel)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            // This panel uses a full-size transparent title bar, so the raw
            // content top sits behind the window controls. The safe-area top
            // keeps the Command-K field below the traffic lights at every
            // window scale and accessibility setting.
            searchField.topAnchor.constraint(
                equalTo: root.safeAreaLayoutGuide.topAnchor,
                constant: 12
            ),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            scopeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            scopeLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            scopeLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: scopeLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -5),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
        ])
        window.contentView = root
    }

    private func updateRootItems() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [Item] = []
        let listableResources = context.resources.filter { $0.verbs.contains("list") }
        let matchingResources = PaletteRanking.matchingResources(
            query: query,
            resources: listableResources
        )

        values.append(contentsOf: PaletteOperationRanking.operations(
            query: query,
            context: context.commandContext
        ).map(Item.operation))

        values.append(contentsOf: PaletteRanking.resources(
            query: query,
            resources: listableResources
        ).map(Item.result))

        values.append(contentsOf: PaletteRanking.namespaces(
            query: query,
            namespaces: context.namespaces
        ).map(Item.result))

        let recent = PaletteRanking.recentObjects(
            query: query,
            values: context.recentObjects,
            matchingResources: matchingResources,
            limit: 20
        )
        values.append(contentsOf: recent.map(Item.result))

        items = Array(values.prefix(50))
        scopeLabel.stringValue = "\(context.session.contextName) · \(context.namespaceScope.presentation)"
        statusLabel.stringValue = items.isEmpty
            ? "No matching commands or resource kinds"
            : "\(items.count.formatted()) results · ↑↓ navigate · Return open · Esc close"
        reloadSelectingFirst()
        scheduleRootCacheSearch(
            query: query,
            baseItems: values,
            recent: recent,
            resourceFilters: matchingResources
        )
    }

    private func scheduleRootCacheSearch(
        query: String,
        baseItems: [Item],
        recent: [PaletteResult],
        resourceFilters: [DiscoveredResource]
    ) {
        rootSearchTask?.cancel()
        guard !query.isEmpty else { return }
        let sessionID = context.session.sessionID
        let scope = context.namespaceScope
        rootSearchTask = Task { [weak self, objectSearchProvider] in
            do {
                try await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                let response = try await objectSearchProvider.searchCachedObjects(request: .init(
                    sessionID: sessionID,
                    namespaceScope: scope,
                    query: query,
                    resultLimit: 30,
                    examinationLimit: 50_000,
                    resourceFilters: resourceFilters
                ))
                guard !Task.isCancelled, let self,
                    case .root = mode,
                    searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
                else { return }
                let objects = PaletteRanking.mergingObjects(
                    recent: recent,
                    cached: response.results,
                    limit: 30
                ).map(Item.result)
                replaceItemsPreservingSelection(Array((baseItems.filter {
                    if case .result(.object) = $0 { return false }
                    return true
                } + objects).prefix(50)))
                let qualifier = response.examinationTruncated ? " · cache scan bounded" : ""
                statusLabel.stringValue = "\(items.count.formatted()) results · \(response.objectsExamined.formatted()) cached examined\(qualifier)"
            } catch {
                guard !Task.isCancelled else { return }
                // Recent/kind/namespace results remain useful when the helper's
                // strictly local cache query is temporarily unavailable.
            }
        }
    }

    private func enterObjectSearch(_ resource: DiscoveredResource) {
        rootSearchTask?.cancel()
        cancelPendingSearch()
        mode = .objects(resource)
        generation &+= 1
        if generation == 0 { generation = 1 }
        queryRevision = 0
        gate.reset()
        resultByIdentity.removeAll(keepingCapacity: true)
        latestProgress = nil
        items = []
        searchField.stringValue = ""
        searchField.placeholderString = "Search \(resource.kind.isEmpty ? resource.resource : resource.kind) by name or namespace/name"
        scopeLabel.stringValue = "\(resource.kind.isEmpty ? resource.resource : resource.kind) · \(context.namespaceScope.presentation) · Esc returns"
        statusLabel.stringValue = "Type a name to search this resource kind"
        tableView.reloadData()
        window?.makeFirstResponder(searchField)
    }

    private func scheduleObjectSearch() {
        debounceTask?.cancel()
        statusLabel.toolTip = nil
        resultByIdentity.removeAll(keepingCapacity: true)
        latestProgress = nil
        items = []
        tableView.reloadData()

        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            cancelRunningSearches()
            statusLabel.stringValue = "Type a name to search this resource kind"
            return
        }
        queryRevision &+= 1
        if queryRevision == 0 { queryRevision = 1 }
        let revision = queryRevision
        statusLabel.stringValue = objectSearchStatus(examined: 0, complete: false)
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            guard !Task.isCancelled, let self, revision == queryRevision else { return }
            beginObjectSearch(query: query, revision: revision)
        }
    }

    private func beginObjectSearch(query: String, revision: UInt64) {
        guard case .objects(let resource) = mode else { return }
        gate.reset()
        runningRevisions.insert(revision)
        let request = ObjectSearchRequest(
            sessionID: context.session.sessionID,
            searchID: searchID,
            generation: generation,
            queryRevision: revision,
            resource: resource,
            namespaceScope: resource.namespaced ? context.namespaceScope : NamespaceSelection(),
            query: query,
            resultLimit: 100,
            allowPaginatedList: true
        )
        searchTasks[revision] = Task { [weak self, objectSearchProvider] in
            defer { self?.searchDidFinish(revision: revision) }
            do {
                for try await message in objectSearchProvider.searchObjects(request: request) {
                    guard !Task.isCancelled else { return }
                    self?.receive(message, expectedRevision: revision)
                }
            } catch {
                guard !Task.isCancelled, let self, revision == queryRevision else { return }
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
            }
        }
    }

    private func receive(
        _ message: ObjectSearchMessage,
        expectedRevision: UInt64
    ) {
        guard case .objects = mode,
            message.cursor.generation == generation,
            message.queryRevision == expectedRevision,
            message.progress.queryRevision == expectedRevision,
            expectedRevision == queryRevision
        else { return }
        let disposition = gate.accept(message.cursor)
        guard disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence else {
            return
        }
        for result in message.results {
            resultByIdentity[objectIdentityKey(result.identity)] = result
        }
        latestProgress = message.progress
        replaceItemsPreservingSelection(PaletteRanking.objects(
            Array(resultByIdentity.values),
            limit: 100
        ).map(Item.result))
        if let issue = message.issue {
            let presentation = issue.userFacingPresentation
            statusLabel.stringValue = presentation.inlineText
            statusLabel.toolTip = presentation.detailedText
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = objectSearchStatus(
                examined: message.progress.objectsExamined,
                complete: message.progress.complete
            )
            statusLabel.toolTip = nil
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func objectSearchStatus(examined: UInt64, complete: Bool) -> String {
        let kind: String
        if case .objects(let resource) = mode {
            kind = resource.kind.isEmpty ? resource.resource : resource.kind
        } else {
            kind = "objects"
        }
        if complete {
            let count = resultByIdentity.count
            return "\(count.formatted()) matches · \(examined.formatted()) examined · Complete"
        }
        return examined == 0
            ? "Searching \(kind)…"
            : "Searching \(kind)… \(examined.formatted()) examined · \(resultByIdentity.count.formatted()) matches"
    }

    private func cancelPendingSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        cancelRunningSearches()
    }

    private func searchDidFinish(revision: UInt64) {
        searchTasks.removeValue(forKey: revision)
        runningRevisions.remove(revision)
    }

    private func cancelRunningSearches() {
        let tasks = Array(searchTasks.values)
        searchTasks.removeAll(keepingCapacity: true)
        for task in tasks { task.cancel() }
        guard generation > 0, !runningRevisions.isEmpty else { return }
        let revisions = runningRevisions
        runningRevisions.removeAll(keepingCapacity: true)
        let generation = generation
        Task { [objectSearchProvider, context, searchID] in
            for revision in revisions {
                await objectSearchProvider.cancelSearch(
                    sessionID: context.session.sessionID,
                    searchID: searchID,
                    generation: generation,
                    queryRevision: revision
                )
            }
        }
    }

    private func handleCancel() {
        switch mode {
        case .root:
            dismissPalette()
        case .objects:
            cancelPendingSearch()
            mode = .root
            searchField.stringValue = ""
            searchField.placeholderString = "Type a command or resource kind"
            resultByIdentity.removeAll(keepingCapacity: true)
            latestProgress = nil
            updateRootItems()
            window?.makeFirstResponder(searchField)
        }
    }

    private func closeAndRun(_ operation: @escaping @MainActor () -> Void) {
        cancelPendingSearch()
        dismissPalette()
        operation()
    }

    private func dismissPalette() {
        guard !closing else { return }
        rootSearchTask?.cancel()
        window?.close()
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow
        let next = current < 0
            ? (delta > 0 ? 0 : items.count - 1)
            : min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func objectIdentityKey(_ identity: ResourceIdentity) -> String {
        [identity.group, identity.version, identity.resource, identity.uid.rawValue]
            .joined(separator: "\u{0}")
    }

    private func reloadSelectingFirst() {
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func replaceItemsPreservingSelection(_ updatedItems: [Item]) {
        let priorIdentity = items.indices.contains(tableView.selectedRow)
            ? items[tableView.selectedRow].stableIdentity : nil
        items = updatedItems
        tableView.reloadData()
        let selected = priorIdentity.flatMap { identity in
            items.firstIndex { $0.stableIdentity == identity }
        } ?? (items.isEmpty ? nil : 0)
        if let selected {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func positionRelativeToParent() {
        guard let window, let parent = window.parent ?? NSApp.keyWindow else {
            window?.center()
            return
        }
        let frame = window.frame
        let parentFrame = parent.frame
        let origin = NSPoint(
            x: parentFrame.midX - frame.width / 2,
            y: parentFrame.maxY - frame.height - 90
        )
        window.setFrameOrigin(origin)
    }
}

@MainActor
private final class PalettePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onToggle: (() -> Void)?
    var onChooseNumberedItem: ((Int) -> Bool)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command), characters == "k" {
            onToggle?()
            return true
        }
        let modifiers = event.modifierFlags.intersection([
            .command, .shift, .control, .option,
        ])
        if modifiers == .command,
            let characters,
            characters.count == 1,
            let number = Int(characters),
            (1...9).contains(number),
            onChooseNumberedItem?(number - 1) == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
private final class PaletteSearchField: NSSearchField {
}

@MainActor
private final class PaletteResultCell: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .medium
        )
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setAccessibilityIdentifier("command-palette.shortcut")
        for value in [icon, titleLabel, detailLabel, shortcutLabel] {
            value.translatesAutoresizingMaskIntoConstraints = false
            addSubview(value)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func configure(title: String, detail: String, image: NSImage?, shortcut: String?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        icon.image = image
        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.isHidden = shortcut == nil
        shortcutLabel.setAccessibilityLabel(shortcut.map {
            "Keyboard shortcut \($0)"
        })
    }
}
