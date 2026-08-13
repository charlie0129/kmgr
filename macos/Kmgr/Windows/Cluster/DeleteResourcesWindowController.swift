import AppKit
import KmgrCore

/// High-identity bulk-delete confirmation and progress. Targets are immutable
/// Kubernetes UID identities captured before the sheet opens.
@MainActor
final class DeleteResourcesWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    private let session: OpenedClusterSession
    private let targets: [ResourceDeleteTarget]
    private let provider: any ResourceOperationProviding
    private let tableView = NSTableView()
    private let propagationButton = NSPopUpButton()
    private let graceField = NSTextField()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "Delete", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var resultsByUID: [ResourceUID: OperationItemResult] = [:]
    private var operationTask: Task<Void, Never>?
    private var operationID = ""
    private var terminal = false
    private var parentWindow: NSWindow?

    var onDismiss: (() -> Void)?

    init(
        session: OpenedClusterSession,
        targets: [ResourceDeleteTarget],
        provider: any ResourceOperationProviding
    ) {
        precondition(!targets.isEmpty)
        self.session = session
        self.targets = targets
        self.provider = provider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Delete Resources — \(session.contextName)"
        window.minSize = NSSize(width: 650, height: 420)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit { operationTask?.cancel() }

    func beginSheet(for parent: NSWindow) {
        parentWindow = parent
        parent.beginSheet(window!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard operationTask == nil else {
            cancelPendingItems()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { onDismiss?() }

    private func configureContent(in window: NSWindow) {
        let warning = NSTextField(wrappingLabelWithString:
            "This permanently deletes the exact Kubernetes UIDs listed below. A same-name replacement will not satisfy a delete precondition."
        )
        warning.font = .systemFont(ofSize: 13, weight: .semibold)
        warning.textColor = .systemRed

        let cluster = NSTextField(wrappingLabelWithString:
            "Context: \(session.contextName)\nCluster: \(session.clusterName) · \(session.serverHostname)"
        )
        cluster.textColor = .secondaryLabelColor

        for (id, title, width) in [
            ("namespace", "Namespace", 150.0), ("resource", "Resource", 130.0),
            ("name", "Name", 240.0), ("uid", "UID", 190.0),
            ("state", "Result", 130.0),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel("Resources awaiting deletion")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        propagationButton.addItems(withTitles: ["Background", "Foreground", "Orphan dependents"])
        graceField.placeholderString = "Server default"
        graceField.alignment = .right
        graceField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let options = NSStackView(views: [
            NSTextField(labelWithString: "Propagation"), propagationButton,
            NSTextField(labelWithString: "Grace seconds"), graceField, NSView(),
        ])
        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = 8

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(targets.count)
        progressIndicator.doubleValue = 0
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        primaryButton.target = self
        primaryButton.action = #selector(beginDelete)
        primaryButton.keyEquivalent = "\r"
        primaryButton.contentTintColor = .systemRed
        cancelButton.target = self
        cancelButton.action = #selector(cancelOrClose)
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [statusLabel, NSView(), cancelButton, primaryButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [warning, cluster, scroll, options, progressIndicator, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            cluster.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window.contentView = root
        let hidden = targets.lazy.filter(\.hiddenByFilter).count
        statusLabel.stringValue = hidden == 0
            ? "\(targets.count) selected resource\(targets.count == 1 ? "" : "s")"
            : "\(targets.count) selected · \(hidden) hidden by the current filter"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { targets.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard targets.indices.contains(row), let tableColumn else { return nil }
        let target = targets[row]
        let identity = target.identity
        let value: String
        switch tableColumn.identifier.rawValue {
        case "namespace": value = identity.namespace.isEmpty ? "Cluster" : identity.namespace
        case "resource": value = identity.resource
        case "name": value = identity.name
        case "uid": value = identity.uid.rawValue
        case "state": value = resultText(resultsByUID[identity.uid])
        default: value = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("delete.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
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
        cell.textField?.toolTip = resultTooltip(resultsByUID[identity.uid]) ?? value
        if let result = resultsByUID[identity.uid] {
            cell.textField?.textColor = result.state == .succeeded
                ? .systemGreen : (result.state == .running ? .labelColor : .systemRed)
        } else {
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    @objc private func beginDelete() {
        guard operationTask == nil, !terminal else { return }
        let graceText = graceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let grace: Int64?
        if graceText.isEmpty {
            grace = nil
        } else if let parsed = Int64(graceText), parsed >= 0 {
            grace = parsed
        } else {
            statusLabel.stringValue = "Grace seconds must be a non-negative integer or blank."
            statusLabel.textColor = .systemRed
            return
        }
        let propagation: DeletePropagationPolicy = switch propagationButton.indexOfSelectedItem {
        case 1: .foreground
        case 2: .orphan
        default: .background
        }
        setRunning(true)
        operationTask = Task { [weak self, provider, targets] in
            guard let self else { return }
            do {
                let stream = try await provider.deleteResources(
                    targets: targets,
                    options: ResourceDeleteOptions(
                        propagationPolicy: propagation,
                        gracePeriodSeconds: grace,
                        maxConcurrency: 4
                    )
                )
                for try await progress in stream {
                    guard !Task.isCancelled else { return }
                    operationID = progress.operationID
                    for result in progress.itemResults {
                        resultsByUID[result.identity.uid] = result
                    }
                    progressIndicator.doubleValue = Double(progress.completedItems)
                    tableView.reloadData()
                    statusLabel.stringValue = "Deleting… \(progress.completedItems)/\(progress.totalItems)"
                    if progress.state.isTerminal {
                        finish(progress)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                terminal = true
                setRunning(false)
                primaryButton.isHidden = true
                cancelButton.title = "Close"
            }
            operationTask = nil
        }
    }

    private func finish(_ progress: OperationProgress) {
        terminal = true
        setRunning(false)
        primaryButton.isHidden = true
        cancelButton.title = "Close"
        let succeeded = resultsByUID.values.lazy.filter { $0.state == .succeeded }.count
        let failed = resultsByUID.values.lazy.filter {
            $0.state == .failed || $0.state == .skipped || $0.state == .cancelled
        }.count
        switch progress.state {
        case .succeeded:
            statusLabel.stringValue = "Deleted \(succeeded) resource\(succeeded == 1 ? "" : "s")."
            statusLabel.textColor = .secondaryLabelColor
        case .partiallySucceeded:
            statusLabel.stringValue = "Partial result: \(succeeded) deleted, \(failed) failed or skipped. Review the Result column."
            statusLabel.textColor = .systemOrange
        case .cancelled:
            statusLabel.stringValue = "Deletion cancelled. Already dispatched API requests may still complete."
            statusLabel.textColor = .systemOrange
        default:
            statusLabel.stringValue = progress.issue?.message
                ?? "Deletion failed. Review individual results."
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func cancelOrClose() {
        if operationTask != nil {
            cancelPendingItems()
        } else {
            closeSheet()
        }
    }

    private func cancelPendingItems() {
        guard !operationID.isEmpty else {
            operationTask?.cancel()
            operationTask = nil
            terminal = true
            statusLabel.stringValue = "Cancellation requested before the operation was accepted."
            setRunning(false)
            cancelButton.title = "Close"
            return
        }
        cancelButton.isEnabled = false
        statusLabel.stringValue = "Cancelling work that has not started…"
        Task { [weak self, provider, session] in
            guard let self else { return }
            do {
                try await provider.cancelOperation(
                    sessionID: session.sessionID,
                    operationID: operationID,
                    cancelNotStartedOnly: true
                )
            } catch {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                cancelButton.isEnabled = true
            }
        }
    }

    private func setRunning(_ running: Bool) {
        primaryButton.isEnabled = !running
        propagationButton.isEnabled = !running
        graceField.isEnabled = !running
        cancelButton.title = running ? "Cancel Pending" : "Cancel"
        cancelButton.isEnabled = true
    }

    private func closeSheet() {
        guard let window else { return }
        if let parentWindow { parentWindow.endSheet(window) }
        window.orderOut(nil)
        onDismiss?()
    }

    private func resultText(_ result: OperationItemResult?) -> String {
        guard let result else { return operationTask == nil ? "Pending" : "Queued" }
        return result.state.rawValue.capitalized
    }

    private func resultTooltip(_ result: OperationItemResult?) -> String? {
        result?.issue?.message
    }
}
