import AppKit
import KmgrCore

@MainActor
final class ClusterOperationHistoryWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    private let tableView = NSTableView()
    private let activeOnlyButton = NSButton(
        checkboxWithTitle: "Active Only",
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "No operations")
    private let connectionIssueLabel = NSTextField(wrappingLabelWithString: "")
    private var tableLayoutBinding: TableLayoutBinding?
    private var recordsByID: [UInt64: ClusterOperationRecord] = [:]
    private var activeIDs: Set<UInt64> = []
    private var displayedRecords: [ClusterOperationRecord] = []
    private var droppedCompleted: UInt64 = 0
    private var streamIssue: UserFacingErrorPresentation?
    private var connectionState: ClusterConnectionState = .connecting
    private var connectionErrorMessage: String?
    private var isWatching = false
    private var isPresenting = false
    private var sortReferenceUnixNanos: Int64 = 0

    init(
        session: OpenedClusterSession,
        tableLayoutStore: TableLayoutStore,
        frameAutosaveName: String = "OperationHistory"
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 760, height: 260)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.animationBehavior = .utilityWindow
        panel.setFrameAutosaveName(frameAutosaveName)
        panel.setAccessibilityLabel("Kubernetes API operation history")
        super.init(window: panel)
        panel.delegate = self
        updateSession(session)
        configureContent(in: panel, tableLayoutStore: tableLayoutStore)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        isPresenting = true
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) {
        isPresenting = false
    }

    func updateSession(_ session: OpenedClusterSession) {
        let identity = ClusterIdentityPresentation(session: session)
        window?.title = "Kubernetes API Operations — \(identity.titlePrefix)"
        window?.subtitle = session.serverHostname
    }

    func install(_ snapshot: ClusterOperationHistorySnapshot) {
        guard isPresenting else { return }
        recordsByID.removeAll(keepingCapacity: true)
        activeIDs = Set(snapshot.active.map(\.id))
        for record in snapshot.completed { recordsByID[record.id] = record }
        for record in snapshot.active { recordsByID[record.id] = record }
        droppedCompleted = snapshot.droppedCompleted
        rebuildDisplayedRecords()
    }

    func apply(_ change: ClusterOperationHistoryChange) {
        guard isPresenting else { return }
        let selectedIDs = selectedRecordIDs
        let previousActiveIDs = activeIDs
        let nextActiveIDs = Set(change.active.map(\.id))
        let evictedIDs = Set(change.evictedCompletedIDs)

        var replacedIDs = previousActiveIDs
        replacedIDs.formUnion(nextActiveIDs)
        replacedIDs.formUnion(change.completed.map(\.id))
        replacedIDs.formUnion(evictedIDs)
        displayedRecords.removeAll { replacedIDs.contains($0.id) }

        for id in previousActiveIDs { recordsByID.removeValue(forKey: id) }
        for id in evictedIDs { recordsByID.removeValue(forKey: id) }
        for record in change.completed where !evictedIDs.contains(record.id) {
            recordsByID[record.id] = record
        }
        for record in change.active { recordsByID[record.id] = record }
        activeIDs = nextActiveIDs
        droppedCompleted = change.droppedCompleted

        var additions = change.completed.filter {
            !evictedIDs.contains($0.id) && accepts($0)
        }
        additions.append(contentsOf: change.active.filter(accepts))
        sortReferenceUnixNanos = Self.currentUnixNanos()
        additions.sort(by: isOrderedBefore)
        displayedRecords = mergeSorted(displayedRecords, additions)
        tableView.reloadData()
        restoreSelection(selectedIDs)
        updateStatus()
    }

    func setStreamState(
        watching: Bool,
        issue: UserFacingErrorPresentation? = nil
    ) {
        isWatching = watching
        streamIssue = issue
        guard isPresenting else { return }
        updateStatus()
    }

    func setConnectionState(
        _ state: ClusterConnectionState,
        errorMessage: String? = nil
    ) {
        connectionState = state
        connectionErrorMessage = errorMessage
        guard isPresenting else { return }
        updateConnectionIssue()
        updateStatus()
    }

    func clearForNewSession() {
        guard isPresenting else { return }
        recordsByID.removeAll(keepingCapacity: true)
        activeIDs.removeAll(keepingCapacity: true)
        displayedRecords.removeAll(keepingCapacity: true)
        droppedCompleted = 0
        tableView.reloadData()
        updateStatus()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRecords.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard displayedRecords.indices.contains(row), let tableColumn else { return nil }
        let record = displayedRecords[row]
        let identifier = NSUserInterfaceItemIdentifier(
            "operation-cell-\(tableColumn.identifier.rawValue)"
        )
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? makeCell(identifier: identifier)
        guard let label = cell.textField else { return cell }
        label.textColor = .labelColor
        label.toolTip = nil
        switch tableColumn.identifier {
        case .operationState:
            label.stringValue = stateText(record.state)
            label.textColor = stateColor(record.state)
        case .operationVerb:
            label.stringValue = record.operation
        case .operationNamespace:
            label.stringValue = record.namespace.isEmpty ? "—" : record.namespace
        case .operationTarget:
            label.stringValue = targetText(record)
            label.toolTip = apiVersionText(record)
        case .operationStatus:
            label.stringValue = statusText(record)
            if record.state == .failed || record.state == .timedOut {
                label.textColor = .systemRed
            }
        case .operationError:
            if let errorMessage = record.errorMessage {
                label.stringValue = errorMessage
                label.toolTip = errorMessage
                label.textColor = switch record.state {
                case .cancelled: .secondaryLabelColor
                case .timedOut: .systemOrange
                case .failed: .systemRed
                case .active, .finished: .labelColor
                }
            } else {
                label.stringValue = "—"
                label.textColor = .tertiaryLabelColor
            }
        case .operationReceived:
            label.stringValue = Self.byteText(record.bytesReceived)
            label.alignment = .right
        case .operationSent:
            label.stringValue = Self.byteText(record.bytesSent)
            label.alignment = .right
        case .operationStarted:
            label.stringValue = Self.dateText(record.startedAtUnixNanos)
        case .operationDuration:
            label.stringValue = Self.durationText(durationNanos(record))
            label.alignment = .right
        default:
            label.stringValue = ""
        }
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        rebuildDisplayedRecords()
    }

    private func configureContent(
        in panel: NSPanel,
        tableLayoutStore: TableLayoutStore
    ) {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, NSTextAlignment)] = [
            (.operationState, "State", 90, .left),
            (.operationVerb, "Operation", 90, .left),
            (.operationNamespace, "Namespace", 125, .left),
            (.operationTarget, "Resource / Target", 220, .left),
            (.operationStatus, "Status", 135, .left),
            (.operationError, "Error", 310, .left),
            (.operationReceived, "Received", 90, .right),
            (.operationSent, "Sent", 90, .right),
            (.operationStarted, "Started", 155, .left),
            (.operationDuration, "Duration", 90, .right),
        ]
        for (identifier, title, width, alignment) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = min(64, width)
            column.resizingMask = .userResizingMask
            column.headerCell.alignment = alignment
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: identifier.rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowSizeStyle = .medium
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.sortDescriptors = [NSSortDescriptor(
            key: NSUserInterfaceItemIdentifier.operationStarted.rawValue,
            ascending: false
        )]
        tableView.setAccessibilityLabel("Kubernetes API operation history")
        tableLayoutBinding = TableLayoutBinding(
            tableView: tableView,
            surface: .operationHistory,
            store: tableLayoutStore
        )

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        activeOnlyButton.target = self
        activeOnlyButton.action = #selector(toggleActiveOnly)
        activeOnlyButton.setAccessibilityIdentifier("operation-history.active-only")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityIdentifier("operation-history.status")
        let footer = NSStackView(views: [activeOnlyButton, statusLabel, NSView()])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        connectionIssueLabel.isSelectable = true
        connectionIssueLabel.maximumNumberOfLines = 3
        connectionIssueLabel.lineBreakMode = .byWordWrapping
        connectionIssueLabel.textColor = .systemRed
        connectionIssueLabel.setAccessibilityIdentifier(
            "operation-history.connection-error"
        )
        connectionIssueLabel.isHidden = true

        let diagnostics = NSStackView(views: [connectionIssueLabel, footer])
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = 5
        diagnostics.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(scrollView)
        root.addSubview(diagnostics)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: diagnostics.topAnchor, constant: -6),
            diagnostics.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            diagnostics.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            diagnostics.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
            connectionIssueLabel.widthAnchor.constraint(equalTo: diagnostics.widthAnchor),
        ])
        panel.contentView = root
        updateConnectionIssue()
        updateStatus()
    }

    @objc private func toggleActiveOnly() {
        rebuildDisplayedRecords()
    }

    private func rebuildDisplayedRecords() {
        let selectedIDs = selectedRecordIDs
        sortReferenceUnixNanos = Self.currentUnixNanos()
        displayedRecords = recordsByID.values.filter(accepts)
        displayedRecords.sort(by: isOrderedBefore)
        tableView.reloadData()
        restoreSelection(selectedIDs)
        updateStatus()
    }

    private func accepts(_ record: ClusterOperationRecord) -> Bool {
        activeOnlyButton.state != .on || activeIDs.contains(record.id)
    }

    private var selectedRecordIDs: Set<UInt64> {
        Set(tableView.selectedRowIndexes.compactMap { index in
            displayedRecords.indices.contains(index) ? displayedRecords[index].id : nil
        })
    }

    private func restoreSelection(_ ids: Set<UInt64>) {
        let indexes = IndexSet(displayedRecords.indices.filter {
            ids.contains(displayedRecords[$0].id)
        })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }

    private func mergeSorted(
        _ existing: [ClusterOperationRecord],
        _ additions: [ClusterOperationRecord]
    ) -> [ClusterOperationRecord] {
        var merged: [ClusterOperationRecord] = []
        merged.reserveCapacity(existing.count + additions.count)
        var existingIndex = 0
        var additionIndex = 0
        while existingIndex < existing.count && additionIndex < additions.count {
            if isOrderedBefore(additions[additionIndex], existing[existingIndex]) {
                merged.append(additions[additionIndex])
                additionIndex += 1
            } else {
                merged.append(existing[existingIndex])
                existingIndex += 1
            }
        }
        merged.append(contentsOf: existing[existingIndex...])
        merged.append(contentsOf: additions[additionIndex...])
        return merged
    }

    private func isOrderedBefore(
        _ lhs: ClusterOperationRecord,
        _ rhs: ClusterOperationRecord
    ) -> Bool {
        for descriptor in tableView.sortDescriptors {
            guard let key = descriptor.key else { continue }
            let comparison = compare(lhs, rhs, key: key)
            guard comparison != .orderedSame else { continue }
            return descriptor.ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
        if lhs.startedAtUnixNanos != rhs.startedAtUnixNanos {
            return lhs.startedAtUnixNanos > rhs.startedAtUnixNanos
        }
        return lhs.id > rhs.id
    }

    private func compare(
        _ lhs: ClusterOperationRecord,
        _ rhs: ClusterOperationRecord,
        key: String
    ) -> ComparisonResult {
        switch NSUserInterfaceItemIdentifier(key) {
        case .operationState:
            return stateText(lhs.state).localizedStandardCompare(stateText(rhs.state))
        case .operationVerb:
            return lhs.operation.localizedStandardCompare(rhs.operation)
        case .operationNamespace:
            return lhs.namespace.localizedStandardCompare(rhs.namespace)
        case .operationTarget:
            return targetText(lhs).localizedStandardCompare(targetText(rhs))
        case .operationStatus:
            return compareValues(lhs.httpStatusCode, rhs.httpStatusCode)
        case .operationError:
            return (lhs.errorMessage ?? "").localizedStandardCompare(
                rhs.errorMessage ?? ""
            )
        case .operationReceived:
            return compareValues(lhs.bytesReceived, rhs.bytesReceived)
        case .operationSent:
            return compareValues(lhs.bytesSent, rhs.bytesSent)
        case .operationStarted:
            return compareValues(lhs.startedAtUnixNanos, rhs.startedAtUnixNanos)
        case .operationDuration:
            return compareValues(durationNanos(lhs), durationNanos(rhs))
        default:
            return .orderedSame
        }
    }

    private func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func durationNanos(_ record: ClusterOperationRecord) -> Int64 {
        let end = record.finishedAtUnixNanos ?? sortReferenceUnixNanos
        return max(0, end - record.startedAtUnixNanos)
    }

    private func targetText(_ record: ClusterOperationRecord) -> String {
        var components = [Self.resourceText(record.resource)]
        if !record.name.isEmpty { components.append(record.name) }
        if !record.subresource.isEmpty { components.append(record.subresource) }
        return components.joined(separator: " / ")
    }

    private func apiVersionText(_ record: ClusterOperationRecord) -> String? {
        guard !record.version.isEmpty else { return nil }
        return record.group.isEmpty
            ? record.version
            : "\(record.group)/\(record.version)"
    }

    private func stateText(_ state: ClusterOperationState) -> String {
        switch state {
        case .active: "Active"
        case .finished: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        }
    }

    private func stateColor(_ state: ClusterOperationState) -> NSColor {
        switch state {
        case .active: .systemBlue
        case .finished: .labelColor
        case .failed: .systemRed
        case .cancelled: .secondaryLabelColor
        case .timedOut: .systemOrange
        }
    }

    private func statusText(_ record: ClusterOperationRecord) -> String {
        guard record.httpStatusCode > 0 else {
            return switch record.state {
            case .active, .finished: "—"
            case .failed: "Transport error"
            case .cancelled: "Cancelled"
            case .timedOut: "Timed out"
            }
        }
        let reason = Self.httpReason(record.httpStatusCode)
        return reason.isEmpty ? String(record.httpStatusCode) : "\(record.httpStatusCode) \(reason)"
    }

    private func updateStatus() {
        let active = activeIDs.count
        let completed = max(0, recordsByID.count - active)
        var parts = [
            "\(active.formatted()) active",
            "\(completed.formatted()) completed retained",
        ]
        if droppedCompleted > 0 {
            parts.append("\(droppedCompleted.formatted()) missed before delivery")
        }
        parts.append(isWatching ? "watching" : "watch stopped")
        parts.append("connection: \(connectionStateText)")
        if let streamIssue {
            parts.append(streamIssue.inlineText)
            statusLabel.toolTip = streamIssue.detailedText
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.toolTip = nil
            statusLabel.textColor = .secondaryLabelColor
        }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    private func updateConnectionIssue() {
        guard let connectionErrorMessage else {
            connectionIssueLabel.stringValue = ""
            connectionIssueLabel.toolTip = nil
            connectionIssueLabel.isHidden = true
            return
        }
        connectionIssueLabel.stringValue = "Connection: \(connectionErrorMessage)"
        connectionIssueLabel.toolTip = connectionErrorMessage
        connectionIssueLabel.textColor = connectionState == .failed
            ? .systemRed : .systemOrange
        connectionIssueLabel.isHidden = false
    }

    private var connectionStateText: String {
        switch connectionState {
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        }
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

    private static func resourceText(_ value: String) -> String {
        guard !value.isEmpty else { return "Kubernetes API" }
        guard value == value.lowercased() else { return value }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    private static func byteText(_ bytes: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var scaled = Double(bytes)
        var unit = 0
        while scaled >= 1_024, unit < units.count - 1 {
            scaled /= 1_024
            unit += 1
        }
        if unit == 0 { return "\(bytes.formatted()) B" }
        return String(format: scaled < 10 ? "%.1f %@" : "%.0f %@", scaled, units[unit])
    }

    private static func dateText(_ unixNanos: Int64) -> String {
        let seconds = TimeInterval(unixNanos) / 1_000_000_000
        return operationDateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func durationText(_ nanos: Int64) -> String {
        let seconds = Double(nanos) / 1_000_000_000
        if seconds < 1 { return "\(Int((seconds * 1_000).rounded())) ms" }
        if seconds < 60 { return String(format: seconds < 10 ? "%.1f s" : "%.0f s", seconds) }
        if seconds < 3_600 {
            return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
        }
        return "\(Int(seconds) / 3_600)h \((Int(seconds) % 3_600) / 60)m"
    }

    private static func currentUnixNanos() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    private static func httpReason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 410: "Gone"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Entity"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }

    private static let operationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private extension NSUserInterfaceItemIdentifier {
    static let operationState = Self("operation-history.state")
    static let operationVerb = Self("operation-history.operation")
    static let operationNamespace = Self("operation-history.namespace")
    static let operationTarget = Self("operation-history.target")
    static let operationStatus = Self("operation-history.status-code")
    static let operationError = Self("operation-history.error")
    static let operationReceived = Self("operation-history.received")
    static let operationSent = Self("operation-history.sent")
    static let operationStarted = Self("operation-history.started")
    static let operationDuration = Self("operation-history.duration")
}
