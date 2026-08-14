import AppKit
import KmgrCore

struct ClusterManagerInitialNotice: Hashable, Sendable {
    var title: String
    var message: String
}

@MainActor
final class ClusterManagerWindowController: NSWindowController, NSWindowDelegate {
    var onOpenSession: ((OpenedClusterSession) -> Void)?
    var onClose: (() -> Void)?

    private let closesAfterOpening: Bool
    private let managerViewController: ClusterManagerViewController

    init(
        provider: any ClusterContextProviding,
        initialNotice: ClusterManagerInitialNotice? = nil,
        closesAfterOpening: Bool = true
    ) {
        self.closesAfterOpening = closesAfterOpening
        self.managerViewController = ClusterManagerViewController(
            provider: provider,
            initialNotice: initialNotice
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

    func windowWillClose(_ notification: Notification) {
        managerViewController.cancelWork()
        onClose?()
    }
}

@MainActor
private final class ClusterManagerViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    var onOpenSession: ((OpenedClusterSession) -> Void)?

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
    private let initialNotice: ClusterManagerInitialNotice?
    private var model = ClusterManagerModel()
    private var loadTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var hasStarted = false
    private var isProjectingSelection = false
    private var openingContextName: String?
    private var operationIssue: ClusterManagerIssue?

    private let searchField = NSSearchField()
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal Source", target: nil, action: nil)
    private let tableView = ContextTableView()
    private let scrollView = NSScrollView()
    private let stateView = NSView()
    private let stateImageView = NSImageView()
    private let stateTitleLabel = NSTextField(labelWithString: "")
    private let stateMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let stateProgress = NSProgressIndicator()
    private let stateRetryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let issueView = NSView()
    private let issueImageView = NSImageView()
    private let issueTitleLabel = NSTextField(labelWithString: "")
    private let issueMessageLabel = NSTextField(wrappingLabelWithString: "")
    private let issueMetadataLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let openProgress = NSProgressIndicator()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)

    init(
        provider: any ClusterContextProviding,
        initialNotice: ClusterManagerInitialNotice?
    ) {
        self.provider = provider
        self.initialNotice = initialNotice
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

        let actionRow = NSStackView(views: [searchField, reloadButton, revealButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        reloadButton.setContentHuggingPriority(.required, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)

        configureTable()
        configureStateView()
        configureIssueView()

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        openProgress.style = .spinning
        openProgress.controlSize = .small
        openProgress.isDisplayedWhenStopped = false

        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openSelectedContext(_:))
        openButton.setAccessibilityLabel("Open selected cluster context")

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [countLabel, footerSpacer, openProgress, openButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let tableContainer = NSView()
        tableContainer.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scrollView)
        tableContainer.addSubview(stateView)
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
            separator.topAnchor.constraint(equalTo: issueView.bottomAnchor, constant: 8),

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
        loadContexts(reload: false)
    }

    func cancelWork() {
        loadTask?.cancel()
        openTask?.cancel()
        loadTask = nil
        openTask = nil
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
        renderControlsAndIssue()
        openTask = Task {
            [weak self, provider, contextName = context.name, contextReference = context.id] in
            do {
                let session = try await provider.openContext(reference: contextReference)
                guard let self, !Task.isCancelled else { return }
                openTask = nil
                openingContextName = nil
                renderControlsAndIssue()
                onOpenSession?(session)
            } catch is CancellationError {
                guard let self else { return }
                openTask = nil
                openingContextName = nil
                renderControlsAndIssue()
            } catch {
                guard let self, !Task.isCancelled else { return }
                openTask = nil
                openingContextName = nil
                operationIssue = Self.presentationIssue(
                    from: error,
                    contextName: contextName,
                    operation: "open cluster session"
                )
                renderControlsAndIssue()
            }
        }
    }

    private func loadContexts(reload: Bool) {
        loadTask?.cancel()
        let revision = model.beginLoading(reload: reload)
        operationIssue = nil
        render()

        loadTask = Task { [weak self, provider] in
            do {
                let contexts = try await provider.listContexts(reload: reload)
                guard let self, !Task.isCancelled else { return }
                guard model.finishLoading(contexts, revision: revision) else { return }
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
                spinning: false,
                retry: false
            )
        case .loading(let reload):
            shouldOverlay = model.allContexts.isEmpty
            if shouldOverlay {
                showState(
                    symbol: nil,
                    title: reload ? "Reloading contexts…" : "Reading contexts…",
                    message: "Inspecting kubeconfig files without contacting clusters.",
                    spinning: true,
                    retry: false
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
                    spinning: false,
                    retry: true
                )
            }
        case .loaded:
            shouldOverlay = displayedCount == 0
            if shouldOverlay {
                if model.allContexts.isEmpty {
                    showState(
                        symbol: "externaldrive.badge.questionmark",
                        title: "No kubeconfig contexts found",
                        message: "Reload after adding a context to your kubeconfig files.",
                        spinning: false,
                        retry: true
                    )
                } else {
                    showState(
                        symbol: "magnifyingglass",
                        title: "No matching contexts",
                        message: "Try a different context, server, namespace, or source path.",
                        spinning: false,
                        retry: false
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
        let isOpening = openingContextName != nil
        reloadButton.isEnabled = !model.isLoading && !isOpening
        searchField.isEnabled = !isOpening
        tableView.isEnabled = !isOpening
        revealButton.isEnabled = model.selectedContext?.sourcePaths.isEmpty == false
        openButton.isEnabled = model.canOpenSelectedContext && !isOpening
        openButton.title = isOpening ? "Opening…" : "Open"
        if isOpening {
            openProgress.startAnimation(nil)
        } else {
            openProgress.stopAnimation(nil)
        }

        var issue = operationIssue ?? model.selectedContextIssue
        if issue == nil, case .failed(let loadIssue) = model.phase, !model.allContexts.isEmpty {
            issue = loadIssue
        }

        guard let issue else {
            if let initialNotice {
                issueView.isHidden = false
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
            issueView.isHidden = true
            return
        }
        issueView.isHidden = false
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

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
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
            tableColumn.resizingMask = .autoresizingMask
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
        stateView.wantsLayer = true
        stateView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
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
        stateProgress.isDisplayedWhenStopped = false

        stateRetryButton.target = self
        stateRetryButton.action = #selector(reloadContexts(_:))

        let stack = NSStackView(
            views: [stateImageView, stateProgress, stateTitleLabel, stateMessageLabel, stateRetryButton]
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
        spinning: Bool,
        retry: Bool
    ) {
        stateImageView.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)
        }
        stateImageView.isHidden = symbol == nil
        stateTitleLabel.stringValue = title
        stateMessageLabel.stringValue = message
        stateRetryButton.isHidden = !retry
        if spinning {
            stateProgress.startAnimation(nil)
        } else {
            stateProgress.stopAnimation(nil)
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
