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
        var selectedIdentities: [ResourceIdentity]
    }

    enum Operation: Hashable {
        case startPortForward(ResourceIdentity)
    }

    private enum Mode {
        case root
        case objects(DiscoveredResource)
    }

    private enum Item: Hashable {
        case operation(Operation)
        case result(PaletteResult)

        var title: String {
            switch self {
            case .operation(.startPortForward): "Start Port Forward…"
            case .result(let result): result.title
            }
        }

        var detail: String {
            switch self {
            case .operation(.startPortForward(let identity)):
                let namespace = identity.namespace.isEmpty ? "cluster-scoped" : identity.namespace
                return "\(namespace)/\(identity.name)"
            case .result(.resource(let resource)):
                return resource.group.isEmpty ? resource.resource : "\(resource.resource).\(resource.group)"
            case .result(.searchResource):
                return "Choose this kind, then search only its objects"
            case .result(.namespace):
                return "Change this workspace's namespace scope"
            case .result(.object(let result)):
                return result.detailText + (result.stale ? " · Cached — opens with a fresh GET" : "")
            }
        }

        var imageName: String {
            switch self {
            case .operation(.startPortForward): "arrow.left.arrow.right"
            case .result(.resource): "tablecells"
            case .result(.searchResource): "magnifyingglass"
            case .result(.namespace): "folder"
            case .result(.object): "shippingbox"
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
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var queryRevision: UInt64 = 0
    private var runningRevision: UInt64?
    private var gate = GenerationSequenceGate()
    private var resultByUID: [ResourceUID: ObjectSearchResult] = [:]
    private var latestProgress: ObjectSearchProgress?
    private var closing = false

    var onOpenResource: ((DiscoveredResource) -> Void)?
    var onChangeNamespace: ((String) -> Void)?
    var onOpenObject: ((ResourceIdentity) -> Void)?
    var onOperation: ((Operation) -> Void)?
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
        cell.configure(
            title: item.title,
            detail: item.detail,
            image: NSImage(systemSymbolName: item.imageName, accessibilityDescription: nil)
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
        guard items.indices.contains(tableView.selectedRow) else {
            NSSound.beep()
            return
        }
        let item = items[tableView.selectedRow]
        switch item {
        case .operation(let operation):
            let callback = onOperation
            closeAndRun { callback?(operation) }
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

        root.addSubview(searchField)
        root.addSubview(scopeLabel)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            searchField.heightAnchor.constraint(equalToConstant: 34),
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

        if let target = eligiblePortForwardTarget(), matchesPortForwardOperation(query) {
            values.append(.operation(.startPortForward(target)))
        }

        values.append(contentsOf: PaletteRanking.resources(
            query: query,
            resources: context.resources.filter { $0.verbs.contains("list") }
        ).map(Item.result))

        values.append(contentsOf: PaletteRanking.namespaces(
            query: query,
            namespaces: context.namespaces
        ).map(Item.result))

        items = Array(values.prefix(50))
        scopeLabel.stringValue = "\(context.session.contextName) · \(context.namespaceScope.presentation)"
        statusLabel.stringValue = items.isEmpty
            ? "No matching commands or resource kinds"
            : "\(items.count.formatted()) results · ↑↓ navigate · Return open · Esc close"
        reloadSelectingFirst()
    }

    private func enterObjectSearch(_ resource: DiscoveredResource) {
        cancelPendingSearch()
        mode = .objects(resource)
        generation &+= 1
        if generation == 0 { generation = 1 }
        queryRevision = 0
        gate.reset()
        resultByUID.removeAll(keepingCapacity: true)
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
        searchTask?.cancel()
        cancelRunningSearch()
        resultByUID.removeAll(keepingCapacity: true)
        latestProgress = nil
        items = []
        tableView.reloadData()

        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
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
        runningRevision = revision
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
        searchTask = Task { [weak self, objectSearchProvider] in
            do {
                for try await message in objectSearchProvider.searchObjects(request: request) {
                    guard !Task.isCancelled else { return }
                    self?.receive(message, expectedRevision: revision)
                }
                if self?.runningRevision == revision {
                    self?.runningRevision = nil
                }
            } catch {
                guard !Task.isCancelled, let self, revision == queryRevision else { return }
                statusLabel.stringValue = error.localizedDescription
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
        if let issue = message.issue {
            statusLabel.stringValue = issue.message
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
        for result in message.results {
            resultByUID[result.identity.uid] = result
        }
        latestProgress = message.progress
        items = PaletteRanking.objects(
            Array(resultByUID.values),
            limit: 100
        ).map(Item.result)
        statusLabel.stringValue = objectSearchStatus(
            examined: message.progress.objectsExamined,
            complete: message.progress.complete
        )
        reloadPreservingSelection()
    }

    private func objectSearchStatus(examined: UInt64, complete: Bool) -> String {
        let kind: String
        if case .objects(let resource) = mode {
            kind = resource.kind.isEmpty ? resource.resource : resource.kind
        } else {
            kind = "objects"
        }
        if complete {
            let count = resultByUID.count
            return "\(count.formatted()) matches · \(examined.formatted()) examined · Complete"
        }
        return examined == 0
            ? "Searching \(kind)…"
            : "Searching \(kind)… \(examined.formatted()) examined · \(resultByUID.count.formatted()) matches"
    }

    private func cancelPendingSearch() {
        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        cancelRunningSearch()
    }

    private func cancelRunningSearch() {
        guard generation > 0, let revision = runningRevision else { return }
        runningRevision = nil
        let generation = generation
        Task { [objectSearchProvider, context, searchID] in
            await objectSearchProvider.cancelSearch(
                sessionID: context.session.sessionID,
                searchID: searchID,
                generation: generation,
                queryRevision: revision
            )
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
            resultByUID.removeAll(keepingCapacity: true)
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

    private func reloadSelectingFirst() {
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func reloadPreservingSelection() {
        let priorItem = items.indices.contains(tableView.selectedRow)
            ? items[tableView.selectedRow] : nil
        tableView.reloadData()
        let selected = priorItem.flatMap { item in
            items.firstIndex(of: item)
        } ?? (items.isEmpty ? nil : 0)
        if let selected {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
    }

    private func eligiblePortForwardTarget() -> ResourceIdentity? {
        guard context.selectedIdentities.count == 1, let value = context.selectedIdentities.first else {
            return nil
        }
        let isPod = value.group.isEmpty && value.version == "v1" && value.resource == "pods"
        let isService = value.group.isEmpty && value.version == "v1" && value.resource == "services"
        return isPod || isService ? value : nil
    }

    private func matchesPortForwardOperation(_ query: String) -> Bool {
        let needle = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty
            || "start port forward".contains(needle)
            || "port-forward".contains(needle)
            || "forward".hasPrefix(needle)
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

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "k"
        {
            onToggle?()
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

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for value in [icon, titleLabel, detailLabel] {
            value.translatesAutoresizingMaskIntoConstraints = false
            addSubview(value)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func configure(title: String, detail: String, image: NSImage?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        icon.image = image
    }
}
