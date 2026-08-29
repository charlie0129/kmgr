import AppKit
import KmgrCore

@MainActor
protocol ObjectDetailEventsControlling: AnyObject {
    var onSnapshotChanged: ((ObjectDetailEventsSnapshot) -> Void)? { get set }

    func activate()
    func deactivate()
    func stop()
    func engineDidDisconnect()
    func recover(session: OpenedClusterSession)
}

struct ObjectDetailEventSummary: Hashable, Sendable {
    var uid: ResourceUID
    var type: String
    var reason: String
    var message: String
    var lastSeen: String
    var count: Int64
    var severity: CellSeverity
}

enum ObjectDetailEventsSnapshot: Hashable, Sendable {
    case loading
    case loaded(events: [ObjectDetailEventSummary], totalCount: UInt64)
    case failed(message: String, toolTip: String)
}

struct ObjectDetailSummaryRow: Hashable, Sendable {
    var sectionID: String
    var fieldID: String
    var label: String
    var displayText: String
    var copyLabel: String
    var copyValue: String
    var tooltip: String
    var severity: CellSeverity
    var metadataKind: ResourceMetadataKind? = nil
    var metadataKey: String? = nil
}

struct ObjectDetailSummarySection: Hashable, Sendable {
    var id: String
    var title: String
    var rows: [ObjectDetailSummaryRow]
}

enum ObjectDetailSummaryTableItem: Hashable, Sendable {
    case section(ObjectDetailSummarySection)
    case row(ObjectDetailSummaryRow)
    case empty
}

enum ObjectDetailSummaryPresentation {
    static let maximumMetadataEntriesPerSection = 64
    static let maximumRecentEvents = 10
    static let maximumVisibleKeyCharacters = 120
    static let maximumVisibleValueCharacters = 512

    static func sections(
        for detail: ObjectDetail,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> [ObjectDetailSummarySection] {
        let timestampFormatting = SummaryTimestampFormatting(timeZone: timeZone)
        let fields = detail.summaryFields.map {
            summaryRow($0, timestampFormatting: timestampFormatting, now: now)
        }
            + metadataRows(sectionID: "labels", values: detail.labels)
            + metadataRows(sectionID: "annotations", values: detail.annotations)
        var sectionOrder: [String] = []
        var rowsBySection: [String: [ObjectDetailSummaryRow]] = [:]
        for field in fields {
            if rowsBySection[field.sectionID] == nil {
                sectionOrder.append(field.sectionID)
            }
            rowsBySection[field.sectionID, default: []].append(field)
        }
        for sectionID in ["labels", "annotations"] where rowsBySection[sectionID] == nil {
            sectionOrder.append(sectionID)
            rowsBySection[sectionID] = []
        }
        let originalOrder = Dictionary(uniqueKeysWithValues: sectionOrder.enumerated().map {
            ($0.element, $0.offset)
        })
        sectionOrder.sort { lhs, rhs in
            let left = sectionPriority(lhs)
            let right = sectionPriority(rhs)
            if left != right { return left < right }
            return originalOrder[lhs, default: 0] < originalOrder[rhs, default: 0]
        }
        return sectionOrder.map { sectionID in
            ObjectDetailSummarySection(
                id: sectionID,
                title: sectionTitle(sectionID),
                rows: rowsBySection[sectionID] ?? []
            )
        }
    }

    static func eventsSection(
        for snapshot: ObjectDetailEventsSnapshot
    ) -> ObjectDetailSummarySection {
        let rows: [ObjectDetailSummaryRow]
        switch snapshot {
        case .loading:
            rows = [eventStatusRow(
                fieldID: "loading",
                text: "Loading recent events…",
                severity: .muted
            )]
        case .failed(let message, let toolTip):
            rows = [ObjectDetailSummaryRow(
                sectionID: "events",
                fieldID: "failure",
                label: "Status",
                displayText: visibleValue(normalizedText(message)),
                copyLabel: "Status",
                copyValue: normalizedText(message),
                tooltip: toolTip,
                severity: .critical
            )]
        case .loaded(let events, let totalCount):
            if events.isEmpty {
                rows = [eventStatusRow(
                    fieldID: "empty",
                    text: "No recent events",
                    severity: .muted
                )]
            } else {
                let visibleEvents = events.prefix(maximumRecentEvents)
                var eventRows = visibleEvents.map(eventRow)
                let shown = UInt64(visibleEvents.count)
                let representedTotal = max(totalCount, UInt64(events.count))
                if representedTotal > shown {
                    let omitted = representedTotal - shown
                    let value = "\(omitted.formatted()) more · Press E to open the complete Events list in a new workspace"
                    eventRows.append(ObjectDetailSummaryRow(
                        sectionID: "events",
                        fieldID: "additional",
                        label: "Additional Events",
                        displayText: value,
                        copyLabel: "Additional Events",
                        copyValue: value,
                        tooltip: "",
                        severity: .informational
                    ))
                }
                rows = eventRows
            }
        }
        return ObjectDetailSummarySection(id: "events", title: "Events", rows: rows)
    }

    private static func eventRow(
        _ event: ObjectDetailEventSummary
    ) -> ObjectDetailSummaryRow {
        let reason = normalizedText(event.reason)
        let type = normalizedText(event.type)
        var label = reason.isEmpty ? (type.isEmpty ? "Event" : type) : reason
        if !type.isEmpty, label.caseInsensitiveCompare(type) != .orderedSame {
            label += " · \(type)"
        }
        let message = normalizedText(event.message)
        var parts = message.isEmpty ? ["No message"] : [message]
        let lastSeen = normalizedText(event.lastSeen)
        if !lastSeen.isEmpty {
            parts.append("last seen \(lastSeen) ago")
        }
        if event.count > 1 {
            parts.append("\(event.count.formatted()) occurrences")
        }
        let value = parts.joined(separator: " · ")
        return ObjectDetailSummaryRow(
            sectionID: "events",
            fieldID: "event:\(event.uid.rawValue)",
            label: bounded(label, maximumCharacters: maximumVisibleKeyCharacters),
            displayText: visibleValue(value),
            copyLabel: label,
            copyValue: value,
            tooltip: value.count > maximumVisibleValueCharacters
                ? copyHint(forCharacterCount: value.count) : "",
            severity: event.severity
        )
    }

    private static func eventStatusRow(
        fieldID: String,
        text: String,
        severity: CellSeverity
    ) -> ObjectDetailSummaryRow {
        ObjectDetailSummaryRow(
            sectionID: "events",
            fieldID: fieldID,
            label: "Status",
            displayText: text,
            copyLabel: "Status",
            copyValue: text,
            tooltip: "",
            severity: severity
        )
    }

    private static func summaryRow(
        _ field: ObjectSummaryField,
        timestampFormatting: SummaryTimestampFormatting,
        now: Date
    ) -> ObjectDetailSummaryRow {
        let label = normalizedText(field.label)
        let normalizedValue = normalizedText(field.displayText)
        let value: String
        switch field.timestamp {
        case .elapsedSince(let timestamp):
            let timing = "for \(compactAge(since: timestamp, now: now)) (since \(timestampFormatting.localized(timestamp)))"
            value = normalizedValue.isEmpty ? timing : "\(normalizedValue) · \(timing)"
        case .occurredAt(let timestamp):
            let timing = "\(compactAge(since: timestamp, now: now)) ago (at \(timestampFormatting.localized(timestamp)))"
            value = normalizedValue.isEmpty ? timing : "\(normalizedValue) · \(timing)"
        case nil:
            value = normalizedValue
        }
        let shortened = value.count > maximumVisibleValueCharacters
        return ObjectDetailSummaryRow(
            sectionID: field.sectionID,
            fieldID: field.fieldID,
            label: bounded(label, maximumCharacters: maximumVisibleKeyCharacters),
            displayText: visibleValue(value),
            copyLabel: label,
            copyValue: value,
            tooltip: shortened
                ? copyHint(forCharacterCount: value.count)
                : field.tooltip,
            severity: field.severity
        )
    }

    private static func metadataRows(
        sectionID: String,
        values: [String: String]
    ) -> [ObjectDetailSummaryRow] {
        let kind: ResourceMetadataKind = sectionID == "labels" ? .labels : .annotations
        let ordered = values.sorted { $0.key < $1.key }
        let visible = ordered.prefix(maximumMetadataEntriesPerSection)
        var rows = visible.map { key, value in
            let normalizedKey = normalizedText(key)
            let normalizedValue = normalizedText(value)
            let shortened = normalizedValue.count > maximumVisibleValueCharacters
            return ObjectDetailSummaryRow(
                sectionID: sectionID,
                fieldID: key,
                label: bounded(
                    normalizedKey,
                    maximumCharacters: maximumVisibleKeyCharacters
                ),
                displayText: visibleValue(normalizedValue),
                copyLabel: normalizedKey,
                copyValue: normalizedValue,
                tooltip: shortened
                    ? copyHint(forCharacterCount: normalizedValue.count)
                    : "",
                severity: .normal,
                metadataKind: kind,
                metadataKey: key
            )
        }
        let omitted = ordered.count - visible.count
        if omitted > 0 {
            rows.append(ObjectDetailSummaryRow(
                sectionID: sectionID,
                fieldID: "additionalEntries",
                label: "Additional Entries",
                displayText: "\(omitted) not shown",
                copyLabel: "Additional Entries",
                copyValue: "\(omitted) not shown",
                tooltip: "",
                severity: .normal,
                metadataKind: kind
            ))
        }
        return rows
    }

    private static func visibleValue(_ value: String) -> String {
        guard !value.isEmpty else { return "—" }
        return bounded(value, maximumCharacters: maximumVisibleValueCharacters)
    }

    private static func normalizedText(_ value: String) -> String {
        value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    static func compactAge(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        guard seconds >= 60 else { return "<1m" }
        let minutes = seconds / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        let hours = minutes / 60
        guard hours >= 24 else { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private struct SummaryTimestampFormatting {
        private let local: DateFormatter

        init(timeZone: TimeZone) {
            local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.calendar = Calendar(identifier: .gregorian)
            local.timeZone = timeZone
            local.dateFormat = "yyyy-MM-dd HH:mm:ss XXX"
        }

        func localized(_ value: Date) -> String { local.string(from: value) }
    }

    private static func copyHint(forCharacterCount count: Int) -> String {
        "Value shortened in Summary (\(count.formatted()) characters). Click the cell and press Command-C, or choose Copy Cell, to copy it."
    }

    private static func sectionTitle(_ sectionID: String) -> String {
        sectionID
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func sectionPriority(_ sectionID: String) -> Int {
        switch sectionID {
        case "identity": 0
        case "labels": 10
        case "annotations": 20
        case "status": 30
        case "replicas": 31
        case "rollout": 32
        case "scheduling": 33
        case "network": 34
        case "routing": 35
        case "service": 36
        case "resources": 37
        case "storage": 38
        case "security": 39
        case "policy": 40
        case "job": 41
        case "secret": 42
        case "data": 43
        case "system": 44
        case "event": 45
        case "owners": 50
        case "selectors": 51
        case "containers": 60
        case "ports": 61
        case "endpoints": 62
        case "conditions": 1_000
        default: 900
        }
    }

    private static func bounded(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}

/// All open Details surfaces share one minute ticker. Relative Summary ages
/// are presentation-only and never cause a Kubernetes request.
@MainActor
private final class ObjectDetailRelativeTimeRefreshCenter {
    static let shared = ObjectDetailRelativeTimeRefreshCenter()

    private var callbacks: [UUID: () -> Void] = [:]
    private var timer: Timer?

    func add(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = callback
        if timer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return id
    }

    func remove(_ id: UUID?) {
        guard let id else { return }
        callbacks.removeValue(forKey: id)
        if callbacks.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func fire() {
        for callback in callbacks.values { callback() }
    }
}

/// A fresh, UID-authoritative Summary surface hosted by the utility Details
/// window.
@MainActor
final class ObjectSummaryViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, WorkspaceStatusPublishing
{
    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession?
    private let provider: any ObjectDetailProviding
    private let tableLayoutStore: TableLayoutStore
    private let eventsController: (any ObjectDetailEventsControlling)?
    private let summaryTable = ObjectDetailSummaryTableView()
    private let summaryScrollView = ObjectDetailSummaryScrollView()
    private var detail: ObjectDetail?
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var summaryItems: [ObjectDetailSummaryTableItem] = []
    private var eventsSnapshot = ObjectDetailEventsSnapshot.loading
    private var relativeTimeRefreshID: UUID?
    private var summaryTableLayoutBinding: TableLayoutBinding?
    private var watchGate = GenerationSequenceGate()
    private var terminalObjectState = false

    var onOpenEvents: ((ResourceIdentity) -> Void)?
    var onEditMetadata: ((ResourceIdentity, ResourceMetadataKind, String?) -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?
    private(set) var workspaceStatus = WorkspaceStatus("Loading…", busy: true)
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot {
        return ContextualShortcutCatalog.objectDetails(
            canEditSelectedMetadata: true,
            canOpenEvents: eventsController != nil && onOpenEvents != nil
        )
    }

    init(
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        session: OpenedClusterSession? = nil,
        tableLayoutStore: TableLayoutStore? = nil,
        eventsController: (any ObjectDetailEventsControlling)? = nil
    ) {
        self.identity = identity
        self.session = session
        self.provider = provider
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.eventsController = eventsController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        watchTask?.cancel()
        recoveryTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        let breadcrumb = NSTextField(labelWithString: breadcrumbText)
        breadcrumb.font = .systemFont(ofSize: 15, weight: .semibold)
        breadcrumb.lineBreakMode = .byTruncatingMiddle

        let header = NSStackView(views: [breadcrumb])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        summaryScrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(summaryScrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            summaryScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            summaryScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            summaryScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            summaryScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        if let eventsController {
            eventsController.onSnapshotChanged = { [weak self] snapshot in
                self?.install(eventsSnapshot: snapshot)
            }
        }
        configureSummary()
        view = root
        updateEventsActivation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        loadObject()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.view.window?.makeFirstResponder(self.summaryTable)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateSummaryTableGeometry()
    }

    private func updateSummaryTableGeometry(availableWidth: CGFloat? = nil) {
        let width = max(1, availableWidth ?? summaryScrollView.contentSize.width)
        summaryTableLayoutBinding?.fitLastColumn(to: width)
        let columnWidth = summaryTable.tableColumns.reduce(0) { $0 + $1.width }
            + summaryTable.intercellSpacing.width
                * CGFloat(max(0, summaryTable.tableColumns.count - 1))
        let documentWidth = max(width, columnWidth)
        if abs(summaryTable.frame.width - documentWidth) > 0.5 {
            summaryTable.setFrameSize(NSSize(
                width: documentWidth,
                height: summaryTable.frame.height
            ))
        }
    }

    func stop() {
        loadTask?.cancel()
        watchTask?.cancel()
        recoveryTask?.cancel()
        eventsController?.stop()
        recoveryTask = nil
        ObjectDetailRelativeTimeRefreshCenter.shared.remove(relativeTimeRefreshID)
        relativeTimeRefreshID = nil
    }

    func refreshAfterMetadataMutation(_ savedIdentity: ResourceIdentity) {
        guard savedIdentity.uid == identity.uid, !terminalObjectState else { return }
        loadTask?.cancel()
        loadTask = nil
        loadObject()
    }

    /// Helper restart invalidates the session behind this Summary. The utility
    /// window keeps its last rendered rows visible until a fresh GET succeeds.
    func engineDidDisconnect() {
        loadTask?.cancel()
        loadTask = nil
        watchTask?.cancel()
        watchTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        eventsController?.engineDidDisconnect()
        publishStatus(WorkspaceStatus(
            "Engine disconnected · reopening this UID when ready",
            severity: .warning
        ))
    }

    /// Rebinds this exact UID to a newly authenticated helper session. Drafts
    /// stay local and no interrupted operation is replayed. The fresh GET also
    /// detects a same-name replacement because the identity remains UID-pinned.
    func recover(
        session recoveredSession: OpenedClusterSession,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard recoveryTask == nil else { return }
        session = recoveredSession
        eventsController?.recover(session: recoveredSession)
        var reboundIdentity = identity
        reboundIdentity.clusterSessionID = recoveredSession.sessionID
        publishStatus(WorkspaceStatus("Reopening this UID…", busy: true))
        recoveryTask = Task { [weak self, provider] in
            guard let self else { return }
            defer { recoveryTask = nil }
            do {
                let updatedDetail = try await provider.getObject(identity: reboundIdentity)
                guard !Task.isCancelled else { return }
                try installRecovery(detail: updatedDetail)
                completion(.success(()))
            } catch {
                guard !Task.isCancelled else { return }
                let presentation = UserFacingErrorPresentation(error)
                publishStatus(WorkspaceStatus(
                    presentation.inlineText,
                    severity: .error,
                    toolTip: presentation.detailedText
                ))
                completion(.failure(error))
            }
        }
    }

    private var breadcrumbText: String {
        let scope = identity.namespace.isEmpty ? "" : " · \(identity.namespace)"
        return "\(identity.resource)\(scope) · \(identity.name)"
    }

    private func configureSummary() {
        configureTable(
            summaryTable,
            columns: [("field", "Field", 220), ("value", "Value", 520)]
        )
        summaryTable.style = .plain
        summaryTable.identifier = .init("object-detail-summary-table")
        summaryTable.setAccessibilityLabel("Kubernetes object summary")
        summaryTable.allowsMultipleSelection = false
        summaryTable.allowsEmptySelection = true
        summaryTable.rowHeight = 24
        summaryTable.intercellSpacing = NSSize(width: 1, height: 1)
        summaryTable.gridStyleMask = [.solidHorizontalGridLineMask]
        summaryTable.cellValueProvider = { [weak self] row, column in
            self?.summaryCellCopyValue(row: row, column: column)
        }
        summaryTable.onEditSelectedMetadata = { [weak self] in
            self?.editSelectedMetadata() ?? false
        }
        summaryTable.onOpenEvents = { [weak self] in
            self?.openEvents() ?? false
        }
        summaryTable.toolTip = "Click a cell and press Command-C, or choose Copy Cell, to copy its full value."
        let summaryMenu = NSMenu()
        summaryTable.addCopyCellMenuItem(to: summaryMenu)
        summaryTable.menu = summaryMenu
        summaryScrollView.documentView = summaryTable
        summaryScrollView.hasVerticalScroller = true
        summaryScrollView.hasHorizontalScroller = true
        summaryScrollView.autohidesScrollers = true
        summaryScrollView.identifier = .init("object-detail-summary-scroll")
        summaryTableLayoutBinding = TableLayoutBinding(
            tableView: summaryTable,
            surface: .objectSummary,
            store: tableLayoutStore
        )
        summaryScrollView.onViewportLayout = { [weak self] width in
            self?.updateSummaryTableGeometry(availableWidth: width)
        }
    }

    private func configureTable(
        _ table: NSTableView,
        columns: [(String, String, CGFloat)]
    ) {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    private func loadObject() {
        guard loadTask == nil else { return }
        publishStatus(WorkspaceStatus("Loading…", busy: true))
        loadTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer { loadTask = nil }
            do {
                let fetched = try await provider.getObject(identity: identity)
                guard !Task.isCancelled else { return }
                install(detail: fetched)
            } catch {
                show(error: error)
            }
        }
    }

    private func install(detail: ObjectDetail) {
        identity = detail.identity
        self.detail = detail
        renderSummary(detail)
        publishStatus(WorkspaceStatus("Resource version \(detail.resourceVersion)"))
        startObjectWatch(resourceVersion: detail.resourceVersion)
        updateEventsActivation()
    }

    private func installRecovery(detail updatedDetail: ObjectDetail) throws {
        guard updatedDetail.identity.uid == identity.uid else {
            terminalObjectState = true
            throw ClusterManagerIssue(
                category: .conflict,
                reason: "ObjectRecreated",
                message: "A same-name object has a different UID and cannot replace this Summary.",
                operation: "recover object details"
            )
        }
        identity = updatedDetail.identity
        terminalObjectState = false
        detail = updatedDetail
        renderSummary(updatedDetail)
        watchTask?.cancel()
        watchTask = nil
        startObjectWatch(resourceVersion: updatedDetail.resourceVersion)
        publishStatus(WorkspaceStatus(
            "Reconnected · resource version \(updatedDetail.resourceVersion)",
            severity: .informational
        ))
    }

    private func renderSummary(_ detail: ObjectDetail) {
        synchronizeRelativeTimeRefresh(for: detail)
        let selectedIDs = Set(summaryTable.selectedRowIndexes.compactMap { index -> String? in
            guard summaryItems.indices.contains(index),
                case .row(let row) = summaryItems[index]
            else { return nil }
            return "\(row.sectionID)\u{0}\(row.fieldID)"
        })
        var sections = ObjectDetailSummaryPresentation.sections(for: detail)
        if eventsController != nil {
            sections.append(ObjectDetailSummaryPresentation.eventsSection(
                for: eventsSnapshot
            ))
        }
        summaryItems = sections.flatMap { section in
            [.section(section)] + section.rows.map(ObjectDetailSummaryTableItem.row)
        }
        if summaryItems.isEmpty { summaryItems = [.empty] }
        summaryTable.reloadData()
        updateSummaryTableGeometry()
        let restored = IndexSet(summaryItems.indices.filter { index in
            guard case .row(let row) = summaryItems[index] else { return false }
            return selectedIDs.contains("\(row.sectionID)\u{0}\(row.fieldID)")
        })
        if !restored.isEmpty {
            summaryTable.selectRowIndexes(restored, byExtendingSelection: false)
        }
    }

    private func install(eventsSnapshot: ObjectDetailEventsSnapshot) {
        self.eventsSnapshot = eventsSnapshot
        guard let detail else { return }
        renderSummary(detail)
    }

    private func synchronizeRelativeTimeRefresh(for detail: ObjectDetail) {
        let needsRefresh = detail.summaryFields.contains {
            $0.timestamp != nil
        }
        if needsRefresh, relativeTimeRefreshID == nil {
            relativeTimeRefreshID = ObjectDetailRelativeTimeRefreshCenter.shared.add {
                [weak self] in
                guard let self, let detail = self.detail else { return }
                self.renderSummary(detail)
            }
        } else if !needsRefresh, relativeTimeRefreshID != nil {
            ObjectDetailRelativeTimeRefreshCenter.shared.remove(relativeTimeRefreshID)
            relativeTimeRefreshID = nil
        }
    }

    private func summaryCellCopyValue(row: Int, column: Int) -> String? {
        guard summaryItems.indices.contains(row),
            case .row(let item) = summaryItems[row],
            summaryTable.tableColumns.indices.contains(column)
        else { return nil }
        switch summaryTable.tableColumns[column].identifier.rawValue {
        case "field": return item.copyLabel
        case "value": return item.copyValue
        default: return nil
        }
    }

    private func updateEventsActivation() {
        guard detail != nil else {
            eventsController?.deactivate()
            return
        }
        eventsController?.activate()
    }

    private func startObjectWatch(resourceVersion: String) {
        guard watchTask == nil, !terminalObjectState else { return }
        watchGate.reset()
        watchTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            do {
                for try await event in provider.watchObject(
                    identity: identity,
                    resourceVersion: resourceVersion
                ) {
                    guard !Task.isCancelled else { return }
                    let disposition = watchGate.accept(event.cursor)
                    guard disposition == .acceptedNewGeneration
                        || disposition == .acceptedNextSequence else { continue }
                    switch event {
                    case .status(_, let currentVersion):
                        if !currentVersion.isEmpty {
                            publishStatus(WorkspaceStatus(
                                "Watching · resource version \(currentVersion)"
                            ))
                        }
                    case .updated(_, let updated):
                        installWatchUpdate(updated)
                    case .deleted(_, _):
                        terminalObjectState = true
                        publishStatus(WorkspaceStatus(
                            "Deleted · this UID no longer exists",
                            severity: .error
                        ))
                    case .failure(_, let issue):
                        if issue.reason == "ObjectRecreated" || issue.reason == "NotFound" {
                            terminalObjectState = true
                            publishStatus(WorkspaceStatus(
                                "Unavailable · same-name objects are not substituted for this UID",
                                severity: .error
                            ))
                        } else {
                            let presentation = issue.userFacingPresentation
                            publishStatus(WorkspaceStatus(
                                presentation.inlineText,
                                severity: .warning,
                                toolTip: presentation.detailedText
                            ))
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, !terminalObjectState else { return }
                show(error: error)
            }
            watchTask = nil
        }
    }

    private func installWatchUpdate(_ updated: ObjectDetail) {
        guard updated.identity.uid == identity.uid else { return }
        // Kubernetes resourceVersion identifies the complete serialized
        // object. Re-presenting the same version only reloads the Summary
        // without adding any information.
        if !updated.resourceVersion.isEmpty,
            updated.resourceVersion == detail?.resourceVersion
        {
            return
        }
        detail = updated
        renderSummary(updated)
        publishStatus(WorkspaceStatus(
            "Watching · resource version \(updated.resourceVersion)"
        ))
    }

    override func cancelOperation(_ sender: Any?) {
        super.cancelOperation(sender)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case summaryTable: summaryItems.count
        default: 0
        }
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === summaryTable {
            guard summaryItems.indices.contains(row) else { return nil }
            switch summaryItems[row] {
            case .section(let section):
                return summarySectionView(section)
            case .row(let item):
                guard let tableColumn else { return nil }
                let isValue = tableColumn.identifier.rawValue == "value"
                return summaryTextCell(
                    isValue ? item.displayText : item.label,
                    table: tableView,
                    column: tableColumn,
                    tooltip: summaryCellTooltip(item, valueColumn: isValue),
                    color: isValue
                        ? summaryValueColor(item.severity) : .labelColor
                )
            case .empty:
                let label = NSTextField(labelWithString: "No summary fields are available.")
                label.identifier = .init("object-detail-summary-empty")
                label.textColor = .secondaryLabelColor
                return label
            }
        }
        return nil
    }

    private func summaryCellTooltip(
        _ row: ObjectDetailSummaryRow,
        valueColumn: Bool
    ) -> String {
        if valueColumn {
            return row.tooltip.isEmpty ? row.displayText : row.tooltip
        }
        guard row.label != row.copyLabel else { return row.label }
        return "Field name shortened in Summary. Click the cell and press Command-C, or choose Copy Cell, to copy it."
    }

    private func summarySectionView(_ section: ObjectDetailSummarySection) -> NSView {
        let container = NSView()
        container.identifier = .init("object-detail-summary-section")
        let heading = NSTextField(labelWithString: section.title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(heading)
        var constraints = [
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            heading.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ]
        if let kind = metadataKind(for: section.id) {
            let button = NSButton(
                title: "Edit \(kind.title)…",
                target: self,
                action: #selector(editMetadataSection(_:))
            )
            button.tag = kind == .labels ? 0 : 1
            button.bezelStyle = .inline
            button.controlSize = .small
            button.identifier = .init("object-detail-edit-\(kind.rawValue)")
            button.setAccessibilityLabel("Edit Kubernetes \(kind.title.lowercased())")
            button.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(button)
            constraints.append(contentsOf: [
                button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                heading.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            ])
        } else {
            constraints.append(heading.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -6
            ))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    @objc private func editMetadataSection(_ sender: NSButton) {
        let kind: ResourceMetadataKind = sender.tag == 0 ? .labels : .annotations
        openMetadataEditor(kind: kind, key: nil)
    }

    private func editSelectedMetadata() -> Bool {
        guard summaryItems.indices.contains(summaryTable.selectedRow),
            case .row(let row) = summaryItems[summaryTable.selectedRow],
            let kind = row.metadataKind
        else { return false }
        openMetadataEditor(kind: kind, key: row.metadataKey)
        return true
    }

    private func openMetadataEditor(kind: ResourceMetadataKind, key: String?) {
        guard detail != nil, !terminalObjectState else {
            NSSound.beep()
            return
        }
        onEditMetadata?(identity, kind, key)
    }

    private func openEvents() -> Bool {
        guard eventsController != nil, detail != nil, !terminalObjectState,
            let onOpenEvents
        else {
            return false
        }
        onOpenEvents(identity)
        return true
    }

    private func metadataKind(for sectionID: String) -> ResourceMetadataKind? {
        switch sectionID {
        case "labels": .labels
        case "annotations": .annotations
        default: nil
        }
    }

    private func summaryValueColor(_ severity: CellSeverity) -> NSColor {
        switch severity {
        case .warning: .systemOrange
        case .critical: .systemRed
        case .muted: .secondaryLabelColor
        case .terminating: .systemPurple
        case .normal, .informational: .labelColor
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === summaryTable, summaryItems.indices.contains(row),
            case .section = summaryItems[row]
        else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === summaryTable else { return true }
        guard summaryItems.indices.contains(row), case .row = summaryItems[row] else {
            return false
        }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === summaryTable, summaryItems.indices.contains(row),
            case .section = summaryItems[row]
        else { return tableView.rowHeight }
        return 30
    }

    private func summaryTextCell(
        _ value: String,
        table: NSTableView,
        column: NSTableColumn,
        tooltip: String,
        color: NSColor
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(
            "summary.\(column.identifier.rawValue)"
        )
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.identifier = .init(
                column.identifier.rawValue == "value"
                    ? "object-detail-summary-value"
                    : "object-detail-summary-field"
            )
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = value
        cell.textField?.toolTip = tooltip.isEmpty ? nil : tooltip
        cell.textField?.textColor = color
        cell.setAccessibilityLabel(column.title)
        cell.setAccessibilityValue(value)
        return cell
    }

    private func show(error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        publishStatus(WorkspaceStatus(
            presentation.inlineText,
            severity: .error,
            toolTip: presentation.detailedText
        ))
    }

    private func publishStatus(_ status: WorkspaceStatus) {
        workspaceStatus = status
        onWorkspaceStatusChanged?(status)
    }

}

@MainActor
private final class ObjectDetailSummaryScrollView: NSScrollView {
    var onViewportLayout: ((CGFloat) -> Void)?
    private var lastReportedViewportWidth: CGFloat = -1

    override func layout() {
        super.layout()
        let width = contentSize.width
        guard width.isFinite,
            abs(width - lastReportedViewportWidth) > 0.5
        else { return }
        lastReportedViewportWidth = width
        onViewportLayout?(width)
    }
}

@MainActor
private final class ObjectDetailSummaryTableView: CapturedCellTableView {
    var onEditSelectedMetadata: (() -> Bool)?
    var onOpenEvents: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ])
        if event.keyCode == 36, modifiers.isEmpty,
            onEditSelectedMetadata?() == true
        {
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "e",
            modifiers.isEmpty,
            onOpenEvents?() == true
        {
            return
        }
        super.keyDown(with: event)
    }
}
