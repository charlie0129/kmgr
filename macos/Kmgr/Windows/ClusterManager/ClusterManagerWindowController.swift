import AppKit
import KmgrCore

struct ClusterManagerInitialNotice: Hashable, Sendable {
    var title: String
    var message: String
}

@MainActor
final class ClusterManagerWindowController: NSWindowController, NSWindowDelegate,
    ContextualShortcutProviding
{
    var onOpenSession: ((OpenedClusterSession) -> Void)?
    var onClose: (() -> Void)?
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        managerViewController.contextualShortcutSnapshot
    }

    private let closesAfterOpening: Bool
    private let managerViewController: ClusterManagerViewController

    init(
        provider: any ClusterContextProviding,
        sourceStore: KubeconfigSourceStore = .shared,
        initialNotice: ClusterManagerInitialNotice? = nil,
        closesAfterOpening: Bool = true,
        tableLayoutStore: TableLayoutStore? = nil
    ) {
        self.closesAfterOpening = closesAfterOpening
        self.managerViewController = ClusterManagerViewController(
            provider: provider,
            sourceStore: sourceStore,
            initialNotice: initialNotice,
            tableLayoutStore: tableLayoutStore ?? TableLayoutStore()
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cluster Manager"
        window.minSize = NSSize(width: 680, height: 400)
        window.tabbingMode = .disallowed
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentViewController = managerViewController
        managerViewController.onContextualShortcutsChanged = { [weak self] in
            self?.contextualShortcutsDidChange?()
        }
        managerViewController.onOpenSession = { [weak self] session in
            guard let self else { return }
            onOpenSession?(session)
            if closesAfterOpening {
                self.window?.close()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterManagerWindowController is programmatic")
    }

    /// Cancel local context loading or an in-flight OpenSession RPC before the
    /// engine begins draining. The chooser itself remains owned by AppKit
    /// until asynchronous application termination is approved.
    func prepareForTermination() {
        managerViewController.cancelWork()
    }

    @objc func addKubeconfigFiles(_ sender: Any?) {
        managerViewController.addKubeconfigFiles(sender)
    }

    func windowWillClose(_ notification: Notification) {
        prepareForTermination()
        onClose?()
    }
}

@MainActor
private final class ClusterManagerViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    var onOpenSession: ((OpenedClusterSession) -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot {
        ContextualShortcutCatalog.clusterChooser(
            canOpenSelection: model.canOpenSelectedContext && openingContextName == nil
        )
    }

    private enum Column: String, CaseIterable {
        case context
        case server
        case namespace
        case source

        var title: String {
            switch self {
            case .context: "Context"
            case .server: "Cluster / Server"
            case .namespace: "Namespace"
            case .source: "Kubeconfig Source"
            }
        }

        var width: CGFloat {
            switch self {
            case .context: 190
            case .server: 230
            case .namespace: 115
            case .source: 285
            }
        }
    }

    private let provider: any ClusterContextProviding
    private let sourceStore: KubeconfigSourceStore
    private let initialNotice: ClusterManagerInitialNotice?
    private let tableLayoutStore: TableLayoutStore
    private var model = ClusterManagerModel()
    private var loadTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var nextOpenAttemptID: UInt64 = 0
    private var activeOpenAttemptID: UInt64?
    private var hasStarted = false
    private var isProjectingSelection = false
    private var openingContextName: String?
    private var operationIssue: ClusterManagerIssue?
    private var addedSourceStatuses: [AddedKubeconfigSourceStatus] = []
    private var sourceStoreObserver: UUID?
    private var lastRequestedSourcePaths: [String]?
    private var sourcesPopover: NSPopover?

    private let searchField = NSSearchField()
    private let sourcesButton = NSButton(title: "Kubeconfig Files…", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal Source", target: nil, action: nil)
    private let tableView = ContextTableView()
    private let scrollView = NSScrollView()
    private let stateView = ClusterManagerStateView()
    private let stateImageView = NSImageView()
    private let stateTitleLabel = NSTextField(labelWithString: "")
    private let stateMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let stateProgress = NSProgressIndicator()
    private let issueView = NSView()
    private let issueImageView = NSImageView()
    private let issueTitleLabel = NSTextField(labelWithString: "")
    private let issueMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let issueMetadataLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let openProgress = NSProgressIndicator()
    private let cancelOpenButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let normalFooterRow = NSStackView()
    private let dropFooterRow = NSStackView()
    private let dropFooterImageView = NSImageView()
    private let dropFooterLabel = NSTextField(labelWithString: "")
    private var tableLayoutBinding: TableLayoutBinding?
    private var separatorBelowIssueConstraint: NSLayoutConstraint?
    private var separatorBelowTableConstraint: NSLayoutConstraint?

    init(
        provider: any ClusterContextProviding,
        sourceStore: KubeconfigSourceStore,
        initialNotice: ClusterManagerInitialNotice?,
        tableLayoutStore: TableLayoutStore
    ) {
        self.provider = provider
        self.sourceStore = sourceStore
        self.initialNotice = initialNotice
        self.tableLayoutStore = tableLayoutStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterManagerViewController is programmatic")
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Open a Kubernetes context")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let explanationLabel = NSTextField(
            wrappingLabelWithString:
                "Contexts are read from kubeconfig locally. A cluster is contacted only when you open it."
        )
        explanationLabel.textColor = .secondaryLabelColor

        searchField.placeholderString = "Search contexts"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search kubeconfig contexts")

        configureToolbarButton(
            sourcesButton,
            action: #selector(showKubeconfigSources(_:)),
            imageName: "doc.on.doc",
            accessibilityLabel: "Manage added kubeconfig files"
        )
        configureToolbarButton(
            reloadButton,
            action: #selector(reloadContexts(_:)),
            imageName: "arrow.clockwise",
            accessibilityLabel: "Reload kubeconfig contexts"
        )
        configureToolbarButton(
            revealButton,
            action: #selector(revealSource(_:)),
            imageName: "folder",
            accessibilityLabel: "Reveal selected kubeconfig source"
        )

        let actionRow = NSStackView(
            views: [searchField, sourcesButton, reloadButton, revealButton]
        )
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourcesButton.setContentHuggingPriority(.required, for: .horizontal)
        reloadButton.setContentHuggingPriority(.required, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)

        configureTable()
        tableLayoutBinding = TableLayoutBinding(
            tableView: tableView,
            surface: .clusterContexts,
            store: tableLayoutStore
        )
        configureStateView()
        configureIssueView()

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        openProgress.style = .spinning
        openProgress.controlSize = .small
        openProgress.isDisplayedWhenStopped = false

        cancelOpenButton.bezelStyle = .rounded
        cancelOpenButton.keyEquivalent = "\u{1b}"
        cancelOpenButton.target = self
        cancelOpenButton.action = #selector(cancelOpeningContext(_:))
        cancelOpenButton.setAccessibilityLabel("Cancel opening cluster context")

        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openSelectedContext(_:))
        openButton.setAccessibilityLabel("Open selected cluster context")

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for item in [countLabel, footerSpacer, openProgress, cancelOpenButton, openButton] {
            normalFooterRow.addArrangedSubview(item)
        }
        normalFooterRow.orientation = .horizontal
        normalFooterRow.alignment = .centerY
        normalFooterRow.spacing = 8
        normalFooterRow.identifier = .init("cluster-manager-normal-footer")
        normalFooterRow.translatesAutoresizingMaskIntoConstraints = false

        dropFooterImageView.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: nil
        )
        dropFooterImageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .medium
        )
        dropFooterImageView.imageScaling = .scaleProportionallyDown
        dropFooterImageView.contentTintColor = .controlAccentColor
        dropFooterLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        dropFooterLabel.textColor = .labelColor
        dropFooterLabel.lineBreakMode = .byTruncatingTail
        dropFooterLabel.maximumNumberOfLines = 1
        dropFooterLabel.identifier = .init("cluster-manager-drop-footer-label")
        dropFooterRow.addArrangedSubview(dropFooterImageView)
        dropFooterRow.addArrangedSubview(dropFooterLabel)
        dropFooterRow.orientation = .horizontal
        dropFooterRow.alignment = .centerY
        dropFooterRow.spacing = 7
        dropFooterRow.identifier = .init("cluster-manager-drop-footer")
        dropFooterRow.translatesAutoresizingMaskIntoConstraints = false
        dropFooterRow.isHidden = true

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(normalFooterRow)
        footer.addSubview(dropFooterRow)
        NSLayoutConstraint.activate([
            normalFooterRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            normalFooterRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            normalFooterRow.topAnchor.constraint(equalTo: footer.topAnchor),
            normalFooterRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            dropFooterRow.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            dropFooterRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            dropFooterRow.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor),
            dropFooterRow.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor)
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let tableContainer = KubeconfigDropView()
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scrollView)
        tableContainer.addSubview(stateView)
        tableContainer.onDropFiles = { [weak self] urls in
            self?.addKubeconfigURLs(urls)
        }
        tableContainer.onDropStateChange = { [weak self] fileCount in
            self?.updateDropFooter(fileCount: fileCount)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor)
        ])

        for subview in [titleLabel, explanationLabel, actionRow, tableContainer, issueView, separator, footer] {
            root.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }

        let separatorBelowIssueConstraint = separator.topAnchor.constraint(
            equalTo: issueView.bottomAnchor,
            constant: 8
        )
        let separatorBelowTableConstraint = separator.topAnchor.constraint(
            equalTo: tableContainer.bottomAnchor,
            constant: 8
        )
        self.separatorBelowIssueConstraint = separatorBelowIssueConstraint
        self.separatorBelowTableConstraint = separatorBelowTableConstraint

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            explanationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            explanationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            explanationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            actionRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            actionRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            actionRow.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 14),

            tableContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tableContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            tableContainer.topAnchor.constraint(equalTo: actionRow.bottomAnchor, constant: 10),
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),

            issueView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            issueView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            issueView.topAnchor.constraint(equalTo: tableContainer.bottomAnchor, constant: 8),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separatorBelowTableConstraint,

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        view = root
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasStarted else { return }
        hasStarted = true
        sourceStoreObserver = sourceStore.observe { [weak self] paths in
            self?.sourcePathsDidChange(paths)
        }
    }

    func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
        cancelOpenAttempt(render: false)
        if let sourceStoreObserver {
            sourceStore.removeObserver(sourceStoreObserver)
            self.sourceStoreObserver = nil
        }
        sourcesPopover?.close()
        sourcesPopover = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.displayedContexts.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard model.displayedContexts.indices.contains(row),
            let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else { return nil }

        let context = model.displayedContexts[row]
        let identifier = NSUserInterfaceItemIdentifier("cluster-manager-text-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
        {
            cell = reused
        } else {
            cell = makeTextCell(identifier: identifier)
        }

        let value: String
        let tooltip: String
        switch column {
        case .context:
            var suffix = context.isCurrent ? " · Current" : ""
            if !context.authentication.isSupported { suffix += " · Unsupported auth" }
            value = context.name + suffix
            tooltip = context.authentication.issue?.userFacingPresentation.detailedText
                ?? context.name
        case .server:
            let pieces = [context.clusterName, context.serverHostname].filter { !$0.isEmpty }
            value = pieces.isEmpty ? "—" : pieces.joined(separator: " — ")
            tooltip = value
        case .namespace:
            value = context.displayedNamespace
            tooltip = "Default namespace: \(value)"
        case .source:
            value = context.displayedSourcePath
            tooltip = context.sourcePaths.isEmpty
                ? "No source path reported"
                : context.sourcePaths.joined(separator: "\n")
        }

        let textColor: NSColor = context.authentication.isSupported
            ? .labelColor
            : .secondaryLabelColor
        if let textField = cell.textField {
            ClusterManagerSearchHighlighting.apply(
                value,
                query: model.searchQuery,
                color: textColor,
                to: textField
            )
            textField.toolTip = tooltip
        }
        cell.toolTip = tooltip
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProjectingSelection else { return }
        let row = tableView.selectedRow
        let contexts = model.displayedContexts
        model.selectContext(id: contexts.indices.contains(row) ? contexts[row].id : nil)
        operationIssue = nil
        renderControlsAndIssue()
    }

    func controlTextDidChange(_ obj: Notification) {
        model.setSearchQuery(searchField.stringValue)
        operationIssue = nil
        render()
    }

    @objc private func reloadContexts(_ sender: Any?) {
        loadContexts(reload: true)
    }

    @objc fileprivate func addKubeconfigFiles(_ sender: Any?) {
        guard openingContextName == nil, let window = view.window else { return }
        sourcesPopover?.close()

        let panel = NSOpenPanel()
        panel.title = "Add Kubeconfig Files"
        panel.message = "Choose one or more kubeconfig files. Kmgr remembers their locations."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.addKubeconfigURLs(panel.urls)
        }
    }

    @objc private func showKubeconfigSources(_ sender: Any?) {
        if let sourcesPopover, sourcesPopover.isShown {
            sourcesPopover.close()
            self.sourcesPopover = nil
            return
        }

        let controller = KubeconfigSourcesPopoverViewController()
        controller.update(paths: sourceStore.paths, statuses: addedSourceStatuses)
        controller.onAdd = { [weak self] in self?.addKubeconfigFiles(nil) }
        controller.onRemove = { [weak self] paths in
            guard let self, sourceStore.remove(paths: paths) else { return }
            operationIssue = nil
        }
        controller.onReveal = { paths in
            let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        sourcesPopover = popover
        popover.show(
            relativeTo: sourcesButton.bounds,
            of: sourcesButton,
            preferredEdge: .maxY
        )
    }

    private func addKubeconfigURLs(_ urls: [URL]) {
        guard openingContextName == nil else { return }
        let candidates = urls.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            return KubeconfigSourceStore.normalizedFilePath(url.path)
        }
        let existing = Set(sourceStore.paths)
        var seen = existing
        let newPaths = candidates.filter { seen.insert($0).inserted }
        guard !newPaths.isEmpty else {
            operationIssue = ClusterManagerIssue(
                category: .conflict,
                reason: "KubeconfigAlreadyAdded",
                message: "The selected kubeconfig files are already in Kmgr.",
                operation: "add kubeconfig files"
            )
            renderControlsAndIssue()
            return
        }
        guard sourceStore.paths.count + newPaths.count
            <= KubeconfigSourceStore.maximumSources
        else {
            operationIssue = ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "KubeconfigSourceLimitExceeded",
                message: "Kmgr can remember at most \(KubeconfigSourceStore.maximumSources) added kubeconfig files.",
                operation: "add kubeconfig files"
            )
            renderControlsAndIssue()
            return
        }
        validateAndAddKubeconfigPaths(newPaths)
    }

    private func validateAndAddKubeconfigPaths(_ newPaths: [String]) {
        loadTask?.cancel()
        let proposedPaths = sourceStore.paths + newPaths
        lastRequestedSourcePaths = proposedPaths
        let revision = model.beginLoading(reload: true)
        operationIssue = nil
        render()

        loadTask = Task { [weak self, provider] in
            do {
                let catalog = try await provider.listContexts(
                    reload: true,
                    addedKubeconfigPaths: proposedPaths
                )
                guard let self, !Task.isCancelled else { return }
                let proposedStatuses = statuses(
                    for: proposedPaths,
                    from: catalog.addedKubeconfigSources
                )
                let statusByPath = Dictionary(
                    uniqueKeysWithValues: proposedStatuses.map { ($0.path, $0) }
                )
                let accepted = newPaths.filter { path in
                    guard let status = statusByPath[path] else { return false }
                    return status.issue == nil
                }
                let rejected = newPaths.compactMap { path -> AddedKubeconfigSourceStatus? in
                    guard let status = statusByPath[path], status.issue != nil else { return nil }
                    return status
                }
                let finalPaths = sourceStore.paths + accepted
                lastRequestedSourcePaths = finalPaths
                if !accepted.isEmpty, !sourceStore.add(paths: accepted) {
                    throw ClusterManagerIssue(
                        category: .internalFailure,
                        reason: "KubeconfigSourcePersistenceFailed",
                        message: "Kmgr could not remember the selected kubeconfig files.",
                        operation: "add kubeconfig files"
                    )
                }
                guard model.finishLoading(catalog.contexts, revision: revision) else { return }
                addedSourceStatuses = statuses(
                    for: finalPaths,
                    from: proposedStatuses
                )
                loadTask = nil
                operationIssue = rejectedIssue(rejected)
                render()
            } catch is CancellationError {
                // A newer source set owns presentation.
            } catch {
                guard let self, !Task.isCancelled else { return }
                let issue = Self.presentationIssue(
                    from: error,
                    contextName: "",
                    operation: "add kubeconfig files"
                )
                guard model.failLoading(with: issue, revision: revision) else { return }
                loadTask = nil
                render()
            }
        }
    }

    private func rejectedIssue(
        _ rejected: [AddedKubeconfigSourceStatus]
    ) -> ClusterManagerIssue? {
        guard let first = rejected.first, let firstIssue = first.issue else { return nil }
        let firstName = URL(fileURLWithPath: first.path).lastPathComponent
        if rejected.count == 1 {
            var issue = firstIssue
            issue.message = "\(firstName) wasn’t added. \(firstIssue.message)"
            issue.operation = "add kubeconfig files"
            return issue
        }
        return ClusterManagerIssue(
            category: .validation,
            reason: "KubeconfigFilesRejected",
            message: "\(rejected.count) kubeconfig files weren’t added. \(firstName): \(firstIssue.message)",
            operation: "add kubeconfig files"
        )
    }

    @objc private func revealSource(_ sender: Any?) {
        guard let context = model.selectedContext else { return }
        let urls = context.sourcePaths.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL
        }
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else {
            operationIssue = ClusterManagerIssue(
                category: .notFound,
                reason: "KubeconfigSourceMissing",
                message: "The kubeconfig source for context \(context.name) is no longer available.",
                contextName: context.name,
                operation: "reveal kubeconfig source"
            )
            renderControlsAndIssue()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existingURLs)
    }

    @objc private func openSelectedContext(_ sender: Any?) {
        guard openTask == nil, let context = model.selectedContext else { return }
        guard context.authentication.isSupported else {
            operationIssue = context.authentication.issue
            renderControlsAndIssue()
            return
        }

        operationIssue = nil
        openingContextName = context.name
        nextOpenAttemptID &+= 1
        let attemptID = nextOpenAttemptID
        activeOpenAttemptID = attemptID
        renderControlsAndIssue()
        openTask = Task {
            [
                weak self,
                provider,
                contextName = context.name,
                contextReference = context.id,
                addedKubeconfigPaths = sourceStore.paths
            ] in
            do {
                let session = try await provider.openContext(
                    reference: contextReference,
                    addedKubeconfigPaths: addedKubeconfigPaths
                )
                guard let self, !Task.isCancelled,
                    finishOpenAttempt(attemptID)
                else { return }
                renderControlsAndIssue()
                onOpenSession?(session)
            } catch is CancellationError {
                guard let self, finishOpenAttempt(attemptID) else { return }
                renderControlsAndIssue()
            } catch {
                guard let self, !Task.isCancelled,
                    finishOpenAttempt(attemptID)
                else { return }
                operationIssue = Self.presentationIssue(
                    from: error,
                    contextName: contextName,
                    operation: "open cluster session"
                )
                renderControlsAndIssue()
            }
        }
    }

    @objc private func cancelOpeningContext(_ sender: Any?) {
        cancelOpenAttempt(render: true)
    }

    private func cancelOpenAttempt(render: Bool) {
        guard let task = openTask else { return }
        openTask = nil
        activeOpenAttemptID = nil
        openingContextName = nil
        task.cancel()
        if render { renderControlsAndIssue() }
    }

    private func finishOpenAttempt(_ attemptID: UInt64) -> Bool {
        guard activeOpenAttemptID == attemptID else { return false }
        openTask = nil
        activeOpenAttemptID = nil
        openingContextName = nil
        return true
    }

    private func loadContexts(reload: Bool) {
        loadTask?.cancel()
        let addedKubeconfigPaths = sourceStore.paths
        lastRequestedSourcePaths = addedKubeconfigPaths
        let revision = model.beginLoading(reload: reload)
        operationIssue = nil
        render()

        loadTask = Task { [weak self, provider] in
            do {
                let catalog = try await provider.listContexts(
                    reload: reload,
                    addedKubeconfigPaths: addedKubeconfigPaths
                )
                guard let self, !Task.isCancelled else { return }
                guard lastRequestedSourcePaths == addedKubeconfigPaths else { return }
                guard model.finishLoading(catalog.contexts, revision: revision) else { return }
                addedSourceStatuses = statuses(
                    for: addedKubeconfigPaths,
                    from: catalog.addedKubeconfigSources
                )
                loadTask = nil
                render()
            } catch is CancellationError {
                // A newer revision or window closure owns presentation now.
            } catch {
                guard let self, !Task.isCancelled else { return }
                let issue = Self.presentationIssue(
                    from: error,
                    contextName: "",
                    operation: reload ? "reload kubeconfig" : "list kubeconfig contexts"
                )
                guard model.failLoading(with: issue, revision: revision) else { return }
                loadTask = nil
                render()
            }
        }
    }

    private func sourcePathsDidChange(_ paths: [String]) {
        updateSourcesPresentation()
        guard lastRequestedSourcePaths != paths else { return }
        loadContexts(reload: lastRequestedSourcePaths != nil)
    }

    private func statuses(
        for paths: [String],
        from statuses: [AddedKubeconfigSourceStatus]
    ) -> [AddedKubeconfigSourceStatus] {
        let byPath = Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0) })
        return paths.map { path in
            byPath[path] ?? AddedKubeconfigSourceStatus(
                path: path,
                issue: ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "KubeconfigSourceStatusMissing",
                    message: "The engine did not report this kubeconfig file’s status.",
                    operation: "list kubeconfig contexts"
                )
            )
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        projectModelSelection()

        let displayedCount = model.displayedContexts.count
        let totalCount = model.allContexts.count
        if model.searchQuery.isEmpty {
            countLabel.stringValue = countDescription(displayedCount)
        } else {
            countLabel.stringValue = "\(displayedCount) of \(totalCount) contexts"
        }

        let shouldOverlay: Bool
        switch model.phase {
        case .idle:
            shouldOverlay = true
            showState(
                symbol: "externaldrive",
                title: "Kubeconfig contexts",
                message: "Kmgr will read your configured kubeconfig files.",
                spinning: false
            )
        case .loading(let reload):
            shouldOverlay = model.allContexts.isEmpty
            if shouldOverlay {
                showState(
                    symbol: nil,
                    title: reload ? "Reloading contexts…" : "Reading contexts…",
                    message: "Inspecting kubeconfig files without contacting clusters.",
                    spinning: true
                )
            }
        case .failed(let issue):
            shouldOverlay = model.allContexts.isEmpty
            if shouldOverlay {
                let presentation = issue.userFacingPresentation
                showState(
                    symbol: symbolName(for: issue.category),
                    title: issue.presentationTitle,
                    message: presentation.inlineText,
                    spinning: false
                )
            }
        case .loaded:
            shouldOverlay = displayedCount == 0
            if shouldOverlay {
                if model.allContexts.isEmpty {
                    showState(
                        symbol: "externaldrive.badge.questionmark",
                        title: "No kubeconfig contexts found",
                        message: "Add a kubeconfig file, drop one here, or reload after changing your standard kubeconfig files.",
                        spinning: false
                    )
                } else {
                    showState(
                        symbol: "magnifyingglass",
                        title: "No matching contexts",
                        message: "Try a different context, server, namespace, or source path.",
                        spinning: false
                    )
                }
            }
        }

        stateView.isHidden = !shouldOverlay
        scrollView.isHidden = shouldOverlay
        renderControlsAndIssue()
    }

    private func renderControlsAndIssue() {
        guard isViewLoaded else { return }
        defer { onContextualShortcutsChanged?() }
        let isOpening = openingContextName != nil
        reloadButton.isEnabled = !model.isLoading && !isOpening
        sourcesButton.isEnabled = !isOpening
        searchField.isEnabled = !isOpening
        tableView.isEnabled = !isOpening
        revealButton.isEnabled = model.selectedContext?.sourcePaths.isEmpty == false
        cancelOpenButton.isHidden = !isOpening
        cancelOpenButton.isEnabled = isOpening
        openButton.isEnabled = model.canOpenSelectedContext && !isOpening
        openButton.title = isOpening ? "Opening…" : "Open"
        if isOpening {
            openProgress.startAnimation(nil)
        } else {
            openProgress.stopAnimation(nil)
        }
        updateSourcesPresentation()

        var issue = operationIssue ?? model.selectedContextIssue
        if issue == nil, case .failed(let loadIssue) = model.phase, !model.allContexts.isEmpty {
            issue = loadIssue
        }

        guard let issue else {
            if let initialNotice {
                setIssueVisible(true)
                issueImageView.image = NSImage(
                    systemSymbolName: "exclamationmark.triangle",
                    accessibilityDescription: initialNotice.title
                )
                issueImageView.contentTintColor = .systemOrange
                issueTitleLabel.stringValue = initialNotice.title
                issueMessageLabel.stringValue = initialNotice.message
                issueMessageLabel.toolTip = nil
                issueMetadataLabel.stringValue = ""
                issueMetadataLabel.toolTip = nil
                issueMetadataLabel.isHidden = true
                return
            }
            setIssueVisible(false)
            return
        }
        setIssueVisible(true)
        issueImageView.image = NSImage(
            systemSymbolName: symbolName(for: issue.category),
            accessibilityDescription: issue.presentationTitle
        )
        issueImageView.contentTintColor = issue.category == .unsupported
            ? .systemOrange
            : .systemRed
        let presentation = issue.userFacingPresentation
        issueTitleLabel.stringValue = issue.presentationTitle
        issueMessageLabel.stringValue = presentation.message
        issueMessageLabel.toolTip = presentation.detailedText
        issueMetadataLabel.stringValue = presentation.supplementaryText
        issueMetadataLabel.toolTip = presentation.detailedText
        issueMetadataLabel.isHidden = presentation.supplementaryText.isEmpty
    }

    private func updateSourcesPresentation() {
        guard isViewLoaded else { return }
        let count = sourceStore.paths.count
        sourcesButton.title = count == 0
            ? "Kubeconfig Files…"
            : "Kubeconfig Files (\(count))…"
        let currentPaths = Set(sourceStore.paths)
        let issueCount = addedSourceStatuses.reduce(into: 0) { count, status in
            if currentPaths.contains(status.path), status.issue != nil { count += 1 }
        }
        let symbol = issueCount == 0 ? "doc.on.doc" : "exclamationmark.triangle"
        sourcesButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        sourcesButton.contentTintColor = issueCount == 0 ? nil : .systemOrange
        sourcesButton.toolTip = issueCount == 0
            ? "Manage kubeconfig files added to Kmgr"
            : "\(issueCount) added kubeconfig \(issueCount == 1 ? "file needs" : "files need") attention"
        (sourcesPopover?.contentViewController as? KubeconfigSourcesPopoverViewController)?
            .update(paths: sourceStore.paths, statuses: addedSourceStatuses)
    }

    private func updateDropFooter(fileCount: Int?) {
        let count = fileCount.flatMap { $0 > 0 ? $0 : nil }
        normalFooterRow.isHidden = count != nil
        dropFooterRow.isHidden = count == nil
        guard let count else { return }
        let noun = count == 1 ? "kubeconfig file" : "kubeconfig files"
        dropFooterLabel.stringValue = "Release to add \(count) \(noun)"
        dropFooterLabel.toolTip = dropFooterLabel.stringValue
    }

    private func setIssueVisible(_ visible: Bool) {
        // AppKit does not remove a hidden plain NSView from an Auto Layout
        // chain. Bypass its label-derived height while hidden so the context
        // table receives the space; restore the full banner chain when shown.
        if visible {
            separatorBelowTableConstraint?.isActive = false
            separatorBelowIssueConstraint?.isActive = true
        } else {
            separatorBelowIssueConstraint?.isActive = false
            separatorBelowTableConstraint?.isActive = true
        }
        issueView.isHidden = !visible
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnResizing = true
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.headerView = NSTableHeaderView()
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedContext(_:))
        tableView.returnAction = { [weak self] in self?.openSelectedContext(nil) }
        tableView.setAccessibilityLabel("Kubeconfig contexts")

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .namespace ? 90 : 120
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableView.addTableColumn(tableColumn)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    private func configureStateView() {
        stateView.translatesAutoresizingMaskIntoConstraints = false

        stateImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        stateImageView.contentTintColor = .secondaryLabelColor
        stateImageView.imageScaling = .scaleProportionallyDown

        stateTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        stateTitleLabel.alignment = .center
        stateMessageLabel.textColor = .secondaryLabelColor
        stateMessageLabel.alignment = .center
        stateMessageLabel.maximumNumberOfLines = 3

        stateProgress.style = .spinning
        stateProgress.controlSize = .regular
        stateProgress.isHidden = true

        let stack = NSStackView(
            views: [stateImageView, stateProgress, stateTitleLabel, stateMessageLabel]
        )
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stateView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: stateView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: stateView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: stateView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: stateView.trailingAnchor, constant: -24),
            stateMessageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
    }

    private func configureIssueView() {
        issueView.translatesAutoresizingMaskIntoConstraints = false
        issueImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        issueImageView.imageScaling = .scaleProportionallyDown
        issueImageView.translatesAutoresizingMaskIntoConstraints = false

        issueTitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        issueTitleLabel.identifier = .init("cluster-manager-issue-title")
        issueMessageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        issueMessageLabel.identifier = .init("cluster-manager-issue-message")
        issueMessageLabel.textColor = .secondaryLabelColor
        issueMessageLabel.maximumNumberOfLines = 2
        issueMetadataLabel.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize - 1,
            weight: .regular
        )
        issueMetadataLabel.textColor = .tertiaryLabelColor

        let labels = NSStackView(views: [issueTitleLabel, issueMessageLabel, issueMetadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        issueView.addSubview(issueImageView)
        issueView.addSubview(labels)
        NSLayoutConstraint.activate([
            issueImageView.leadingAnchor.constraint(equalTo: issueView.leadingAnchor, constant: 2),
            issueImageView.topAnchor.constraint(equalTo: issueView.topAnchor, constant: 2),
            issueImageView.widthAnchor.constraint(equalToConstant: 18),
            issueImageView.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: issueImageView.trailingAnchor, constant: 7),
            labels.trailingAnchor.constraint(equalTo: issueView.trailingAnchor),
            labels.topAnchor.constraint(equalTo: issueView.topAnchor),
            labels.bottomAnchor.constraint(equalTo: issueView.bottomAnchor)
        ])
        issueView.isHidden = true
    }

    private func configureToolbarButton(
        _ button: NSButton,
        action: Selector,
        imageName: String,
        accessibilityLabel: String
    ) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func projectModelSelection() {
        let displayed = model.displayedContexts
        let selectedRow = model.selectedContextID.flatMap { id in
            displayed.firstIndex { $0.id == id }
        }
        isProjectingSelection = true
        defer { isProjectingSelection = false }
        if let selectedRow {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func showState(
        symbol: String?,
        title: String,
        message: String,
        spinning: Bool
    ) {
        stateImageView.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)
        }
        stateImageView.isHidden = symbol == nil
        stateTitleLabel.stringValue = title
        stateMessageLabel.stringValue = message
        if spinning {
            stateProgress.isHidden = false
            stateProgress.startAnimation(nil)
        } else {
            stateProgress.stopAnimation(nil)
            stateProgress.isHidden = true
        }
    }

    private func countDescription(_ count: Int) -> String {
        count == 1 ? "1 context" : "\(count) contexts"
    }

    private func symbolName(for category: ClusterManagerIssue.Category) -> String {
        switch category {
        case .authentication, .authorization: "person.crop.circle.badge.exclamationmark"
        case .tls: "lock.trianglebadge.exclamationmark"
        case .timeout, .unavailable: "network.slash"
        case .unsupported: "exclamationmark.triangle"
        case .notFound: "doc.badge.ellipsis"
        case .validation, .conflict: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        case .internalFailure, .resourceExhausted: "bolt.trianglebadge.exclamationmark"
        }
    }

    private static func presentationIssue(
        from error: Error,
        contextName: String,
        operation: String
    ) -> ClusterManagerIssue {
        if var issue = error as? ClusterManagerIssue {
            if issue.contextName.isEmpty { issue.contextName = contextName }
            if issue.operation.isEmpty { issue.operation = operation }
            return issue
        }
        return ClusterManagerIssue(
            category: .internalFailure,
            reason: String(describing: type(of: error)),
            message: error.localizedDescription,
            contextName: contextName,
            operation: operation
        )
    }
}

@MainActor
final class KubeconfigSourcesPopoverViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate
{
    var onAdd: (() -> Void)?
    var onRemove: (([String]) -> Void)?
    var onReveal: (([String]) -> Void)?

    private var paths: [String] = []
    private var statusByPath: [String: AddedKubeconfigSourceStatus] = [:]
    private let tableView = KubeconfigSourceTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No kubeconfig files have been added.")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Added Kubeconfig Files")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        configureTable()

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let addButton = NSButton(title: "Add Files…", target: self, action: #selector(addFiles(_:)))
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: nil
        )
        addButton.imagePosition = .imageLeading
        addButton.setAccessibilityLabel("Add kubeconfig files")

        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.bezelStyle = .rounded
        removeButton.setAccessibilityLabel("Remove selected kubeconfig files from Kmgr")

        revealButton.target = self
        revealButton.action = #selector(revealSelected(_:))
        revealButton.bezelStyle = .rounded
        revealButton.setAccessibilityLabel("Reveal selected kubeconfig files")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [addButton, removeButton, spacer, revealButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let footer = NSTextField(
            wrappingLabelWithString:
                "Kmgr also reads $KUBECONFIG; when unset, it reads kubeconfig files in ~/.kube."
        )
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 2

        for subview in [title, scrollView, emptyLabel, actions, footer] {
            root.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            scrollView.heightAnchor.constraint(equalToConstant: 170),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            actions.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            actions.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),

            footer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            footer.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])

        tableView.deleteAction = { [weak self] in self?.removeSelected(nil) }
        view = root
        preferredContentSize = NSSize(width: 540, height: 286)
        render()
    }

    func update(paths: [String], statuses: [AddedKubeconfigSourceStatus]) {
        let selected = selectedPaths
        self.paths = paths
        statusByPath = Dictionary(uniqueKeysWithValues: statuses.map { ($0.path, $0) })
        guard isViewLoaded else { return }
        tableView.reloadData()
        let indexes = IndexSet(paths.indices.filter { selected.contains(paths[$0]) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        render()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard paths.indices.contains(row), let tableColumn else { return nil }
        let path = paths[row]
        let identifier = NSUserInterfaceItemIdentifier(
            "kubeconfig-source-\(tableColumn.identifier.rawValue)"
        )
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
        {
            cell = reused
        } else {
            cell = makeCell(identifier: identifier)
        }

        let value: String
        let color: NSColor
        if tableColumn.identifier.rawValue == "file" {
            let name = URL(fileURLWithPath: path).lastPathComponent
            let abbreviated = (path as NSString).abbreviatingWithTildeInPath
            value = "\(name) — \(abbreviated)"
            color = .labelColor
        } else if let status = statusByPath[path] {
            if let issue = status.issue {
                value = statusText(for: issue)
                color = .systemOrange
            } else {
                value = status.contextCount == 1
                    ? "1 context"
                    : "\(status.contextCount) contexts"
                color = .secondaryLabelColor
            }
        } else {
            value = "Loading…"
            color = .secondaryLabelColor
        }
        cell.textField?.stringValue = value
        cell.textField?.textColor = color
        cell.textField?.toolTip = statusByPath[path]?.issue?.userFacingPresentation.detailedText
            ?? path
        cell.toolTip = cell.textField?.toolTip
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        renderControls()
    }

    private var selectedPaths: Set<String> {
        Set(tableView.selectedRowIndexes.compactMap { index in
            paths.indices.contains(index) ? paths[index] : nil
        })
    }

    private func configureTable() {
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityLabel("Added kubeconfig files")

        let file = NSTableColumn(identifier: .init("file"))
        file.title = "File"
        file.width = 390
        file.minWidth = 220
        file.resizingMask = [.autoresizingMask, .userResizingMask]
        tableView.addTableColumn(file)

        let status = NSTableColumn(identifier: .init("status"))
        status.title = "Status"
        status.width = 110
        status.minWidth = 90
        status.maxWidth = 150
        status.resizingMask = [.userResizingMask]
        tableView.addTableColumn(status)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func statusText(for issue: ClusterManagerIssue) -> String {
        switch issue.reason {
        case "KubeconfigFileMissing": "Missing"
        case "KubeconfigFileUnreadable": "Unreadable"
        case "KubeconfigAlreadyDiscovered": "Already read"
        default: "Invalid"
        }
    }

    private func render() {
        emptyLabel.isHidden = !paths.isEmpty
        renderControls()
    }

    private func renderControls() {
        let selected = selectedPaths
        removeButton.isEnabled = !selected.isEmpty
        revealButton.isEnabled = selected.contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    @objc private func addFiles(_ sender: Any?) {
        onAdd?()
    }

    @objc private func removeSelected(_ sender: Any?) {
        let selected = paths.filter(selectedPaths.contains)
        guard !selected.isEmpty else { return }
        onRemove?(selected)
    }

    @objc private func revealSelected(_ sender: Any?) {
        let selected = paths.filter(selectedPaths.contains)
        guard !selected.isEmpty else { return }
        onReveal?(selected)
    }
}

@MainActor
private final class ClusterManagerStateView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("cluster-manager-state-view")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterManagerStateView is programmatic")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class KubeconfigSourceTableView: NSTableView {
    var deleteAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteAction?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class KubeconfigDropView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropStateChange: ((Int?) -> Void)?

    private var activeDropFileCount: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("cluster-manager-drop-target")
        wantsLayer = true
        layer?.cornerRadius = 8
        updateAccentColor()
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KubeconfigDropView is programmatic")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAccentColor()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropState(from: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropState(from: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        updateDropState(fileCount: nil)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        updateDropState(fileCount: nil)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        updateDropState(fileCount: nil)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        updateDropState(fileCount: nil)
    }

    func updateDropState(fileCount: Int?) {
        let count = fileCount.flatMap { $0 > 0 ? $0 : nil }
        guard activeDropFileCount != count else { return }
        activeDropFileCount = count
        layer?.borderWidth = count == nil ? 0 : 2
        onDropStateChange?(count)
    }

    private func updateDropState(from sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else {
            updateDropState(fileCount: nil)
            return []
        }
        sender.numberOfValidItemsForDrop = urls.count
        updateDropState(fileCount: urls.count)
        return .copy
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]) ?? []
    }

    private func updateAccentColor() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

@MainActor
private final class ContextTableView: NSTableView {
    var returnAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            returnAction?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Produces attributed text only for cells requested by AppKit. NSTableView's
/// reuse/virtualization therefore bounds this work to the visible viewport,
/// even when the chooser contains thousands of contexts.
@MainActor
enum ClusterManagerSearchHighlighting {
    static func apply(
        _ value: String,
        query: String,
        color: NSColor,
        to textField: NSTextField
    ) {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textField.font = baseFont
        textField.textColor = color
        textField.stringValue = value

        let ranges = matchingRanges(in: value, query: query)
        guard !ranges.isEmpty else { return }

        let fullRange = NSRange(location: 0, length: (value as NSString).length)
        let highlighted = NSMutableAttributedString(
            string: value,
            attributes: [
                .font: baseFont,
                .foregroundColor: color,
            ]
        )
        let boldFont = NSFontManager.shared.convert(
            baseFont,
            toHaveTrait: .boldFontMask
        )
        for range in ranges where NSMaxRange(range) <= NSMaxRange(fullRange) {
            highlighted.addAttribute(.font, value: boldFont, range: range)
        }
        textField.attributedStringValue = highlighted
    }

    static func matchingRanges(in value: String, query: String) -> [NSRange] {
        let terms = query
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty, !value.isEmpty else { return [] }

        let source = value as NSString
        let options: NSString.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive,
        ]
        var matches: [NSRange] = []
        for term in terms {
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let match = source.range(
                    of: term,
                    options: options,
                    range: searchRange,
                    locale: .current
                )
                guard match.location != NSNotFound else { break }
                matches.append(match)
                let nextLocation = NSMaxRange(match)
                searchRange = NSRange(
                    location: nextLocation,
                    length: source.length - nextLocation
                )
            }
        }

        let sorted = matches.sorted {
            if $0.location != $1.location { return $0.location < $1.location }
            return $0.length < $1.length
        }
        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
