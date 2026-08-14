import AppKit
import KmgrCore

@MainActor
final class PortForwardsWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    private let coordinator: PortForwardCoordinator
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "No port-forwards")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Address", target: nil, action: nil)
    private let browserButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private var records: [PortForwardRecord] = []
    private var observerToken: UUID?
    private var helperGenerationAvailable = false

    init(coordinator: PortForwardCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Port Forwards — \(Product.applicationName)"
        window.minSize = NSSize(width: 780, height: 300)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PortForwards")
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
        observerToken = coordinator.observe { [weak self] snapshot in
            self?.apply(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard records.indices.contains(row), let tableColumn else { return nil }
        let record = records[row]
        let identifier = NSUserInterfaceItemIdentifier("pf-cell-\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        guard let label = cell.textField else { return cell }
        label.textColor = .labelColor
        label.toolTip = nil

        switch tableColumn.identifier {
        case .status:
            label.stringValue = record.state.displayName
                + (record.exposesBeyondLocalMachine ? " ⚠︎" : "")
            label.textColor = color(for: record)
            if record.exposesBeyondLocalMachine {
                label.toolTip = "This listener is reachable beyond the local machine."
            }
        case .context:
            label.stringValue = Self.clusterContextText(for: record)
        case .target:
            label.stringValue = identityText(record.target, includeUID: false)
            label.toolTip = record.target.uid.rawValue
        case .resolvedPod:
            label.stringValue = record.resolvedPod.map {
                identityText($0, includeUID: true)
            } ?? "—"
            label.toolTip = record.resolvedPod?.uid.rawValue
        case .address:
            let local = record.localPort == 0 ? "allocating" : String(record.localPort)
            let bind = record.bindAddress.isEmpty ? "127.0.0.1" : record.bindAddress
            label.stringValue = "\(bind):\(local) → \(record.remotePort)"
        case .started:
            label.stringValue = Self.dateText(record.startedAt)
        case .updated:
            label.stringValue = Self.dateText(record.updatedAt)
        case .lastError:
            if record.exposesBeyondLocalMachine,
                record.state != .failed,
                record.state != .reconnecting
            {
                label.stringValue = "Exposed beyond this Mac"
                label.textColor = .systemOrange
            } else {
                label.stringValue = record.lastIssue?.userFacingPresentation.message ?? "—"
                if record.lastIssue != nil { label.textColor = .systemRed }
            }
            label.toolTip = record.lastIssue?.userFacingPresentation.detailedText
        default:
            label.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionAvailability()
    }

    private func configureContent(in window: NSWindow) {
        let root = NSView()

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (.status, "Status", 105),
            (.context, "Cluster — Context", 210),
            (.target, "Target", 180),
            (.resolvedPod, "Resolved Pod", 185),
            (.address, "Bind / Local → Remote", 175),
            (.started, "Started", 130),
            (.updated, "Updated", 130),
            (.lastError, "Last Error / Warning", 260),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = min(80, width)
            column.resizingMask = .userResizingMask
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .medium
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel("App-wide Kubernetes port-forwards")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stopButton.target = self
        stopButton.action = #selector(stopSelected)
        restartButton.target = self
        restartButton.action = #selector(restartSelected)
        copyButton.target = self
        copyButton.action = #selector(copySelectedAddress)
        browserButton.target = self
        browserButton.action = #selector(openSelectedAddress)
        for button in [stopButton, restartButton, copyButton, browserButton] {
            button.bezelStyle = .rounded
        }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [
            statusLabel, NSView(), copyButton, browserButton, restartButton, stopButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -7),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
        updateActionAvailability()
    }

    static func clusterContextText(for record: PortForwardRecord) -> String {
        ClusterIdentityPresentation(
            clusterName: record.clusterName,
            contextName: record.contextName
        ).titlePrefix
    }

    private func apply(_ snapshot: PortForwardCoordinator.Snapshot) {
        let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { index in
            records.indices.contains(index) ? records[index].id : nil
        })
        records = snapshot.records
        helperGenerationAvailable = snapshot.helperGenerationAvailable
        tableView.reloadData()
        let indexes = IndexSet(records.indices.filter { selectedIDs.contains(records[$0].id) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)

        var pieces = ["\(snapshot.activeCount.formatted()) active", "\(records.count.formatted()) retained"]
        if snapshot.hasFailure { pieces.append("failed forwards need attention") }
        if let issue = snapshot.connectionIssue {
            let presentation = issue.userFacingPresentation
            pieces.append(presentation.inlineText)
            statusLabel.toolTip = presentation.detailedText
            statusLabel.textColor = .systemOrange
        } else if snapshot.isWatching {
            statusLabel.toolTip = nil
            pieces.append("watching")
            statusLabel.textColor = snapshot.hasFailure ? .systemRed : .secondaryLabelColor
        } else if records.isEmpty {
            statusLabel.toolTip = nil
            pieces.append("open a cluster window to connect")
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.toolTip = nil
        }
        statusLabel.stringValue = pieces.joined(separator: " · ")
        updateActionAvailability()
    }

    private var selectedRecords: [PortForwardRecord] {
        tableView.selectedRowIndexes.compactMap { index in
            records.indices.contains(index) ? records[index] : nil
        }
    }

    private func updateActionAvailability() {
        let selected = selectedRecords
        stopButton.isEnabled = selected.contains { $0.state.isActive }
        restartButton.isEnabled = selected.contains {
            ($0.state == .failed || $0.state == .stopped)
                && $0.lastIssue?.reason != "EngineRestarted"
                && helperGenerationAvailable
        }
        copyButton.isEnabled = selected.count == 1 && selected[0].address != nil
        browserButton.isEnabled = selected.count == 1
            && selected[0].state == .listening
            && browserURL(for: selected[0]) != nil
    }

    @objc private func stopSelected() {
        let selected = selectedRecords.filter { $0.state.isActive }
        guard !selected.isEmpty else { return }
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Stopping \(selected.count.formatted()) port-forward(s)…"
        Task { [weak self, coordinator] in
            for record in selected {
                do {
                    try await coordinator.stop(record)
                } catch {
                    self?.showOperationError(error)
                }
            }
        }
    }

    @objc private func restartSelected() {
        let selected = selectedRecords.filter {
            ($0.state == .failed || $0.state == .stopped)
                && $0.lastIssue?.reason != "EngineRestarted"
        }
        guard !selected.isEmpty else { return }
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Restarting \(selected.count.formatted()) port-forward(s)…"
        Task { [weak self, coordinator] in
            for record in selected {
                do {
                    try await coordinator.restart(record)
                } catch {
                    self?.showOperationError(error)
                }
            }
        }
    }

    @objc private func copySelectedAddress() {
        guard selectedRecords.count == 1, let address = selectedRecords[0].address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Copied \(address)"
    }

    @objc private func openSelectedAddress() {
        guard selectedRecords.count == 1, let url = browserURL(for: selectedRecords[0]) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showOperationError(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.inlineText
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
    }

    private func browserURL(for record: PortForwardRecord) -> URL? {
        guard let address = record.address else { return nil }
        let scheme = [443, 8443].contains(record.remotePort) ? "https" : "http"
        return URL(string: "\(scheme)://\(address)")
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
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
        return cell
    }

    private func identityText(_ identity: ResourceIdentity, includeUID: Bool) -> String {
        let namespace = identity.namespace.isEmpty ? "cluster" : identity.namespace
        let kind = identity.resource.hasSuffix("s")
            ? String(identity.resource.dropLast()).capitalized
            : identity.resource.capitalized
        var value = "\(kind) \(namespace)/\(identity.name)"
        if includeUID, !identity.uid.rawValue.isEmpty {
            value += " · \(identity.uid.rawValue.prefix(8))"
        }
        return value
    }

    private func color(for record: PortForwardRecord) -> NSColor {
        switch record.state {
        case .listening:
            record.exposesBeyondLocalMachine ? .systemOrange : .systemGreen
        case .starting: .secondaryLabelColor
        case .reconnecting: .systemOrange
        case .failed: .systemRed
        case .stopped: .tertiaryLabelColor
        }
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(
            date: .abbreviated,
            time: .shortened
        )
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let status = Self("port-forward.status")
    static let context = Self("port-forward.context")
    static let target = Self("port-forward.target")
    static let resolvedPod = Self("port-forward.resolved-pod")
    static let address = Self("port-forward.address")
    static let started = Self("port-forward.started")
    static let updated = Self("port-forward.updated")
    static let lastError = Self("port-forward.last-error")
}
