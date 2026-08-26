import AppKit
import KmgrCore

enum ObjectDetailInitialTab {
    case automatic
    case summary
    case yaml
    case relationships

    var segment: Int {
        switch self {
        case .automatic, .summary: 0
        case .yaml: 1
        case .relationships: 2
        }
    }
}

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
        case "network": 32
        case "service": 33
        case "secret": 34
        case "owners": 40
        case "selectors": 41
        case "containers": 50
        case "ports": 51
        case "endpoints": 52
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

enum ObjectDetailWatchPresentation {
    static func merging(_ update: ObjectDetail, previous: ObjectDetail?) -> ObjectDetail {
        guard let previous else { return update }
        var merged = update
        // A watch payload with no YAML is not an authoritative deletion of the
        // object's serialization. Retain the last non-empty snapshot so a
        // transient helper/watch omission cannot blank either YAML renderer.
        if update.yamlUTF8.isEmpty, !previous.yamlUTF8.isEmpty {
            merged.yamlUTF8 = previous.yamlUTF8
        }
        return merged
    }
}

/// A fresh, UID-authoritative detail surface. It replaces the table area in a
/// workspace; no inspector or bottom drawer is introduced.
@MainActor
final class ObjectDetailViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate, WorkspaceStatusPublishing
{
    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession?
    private let provider: any ObjectDetailProviding
    private let tableLayoutStore: TableLayoutStore
    private let initialTab: ObjectDetailInitialTab
    private let eventsController: (any ObjectDetailEventsControlling)?
    private let yamlPresentationBuilder:
        @Sendable (Data) -> YAMLManagedFieldsPresentation
    private let segmented = NSSegmentedControl(
        labels: ["Summary", "YAML", "Relationships"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentContainer = NSView()
    private let summaryTable = ObjectDetailSummaryTableView()
    private let summaryScrollView = ObjectDetailSummaryScrollView()
    private let relationshipsTable = NSTableView()
    private let relationshipsScrollView = NSScrollView()
    private let relationshipsContainerView = NSView()
    private let relationshipsCoverageLabel = NSTextField(
        labelWithString: "Cached children are potentially incomplete."
    )
    private let scanRelationshipsButton = NSButton(
        title: "Scan All Resources…", target: nil, action: nil
    )
    private let cancelRelationshipScanButton = NSButton(
        title: "Cancel Scan", target: nil, action: nil
    )
    private lazy var yamlScrollView =
        YAMLTextView.scrollablePlainDocumentContentTextView()
    private lazy var yamlTextView: YAMLTextView = {
        guard let textView = yamlScrollView.documentView as? YAMLTextView else {
            preconditionFailure("AppKit did not create a YAML document text view")
        }
        return textView
    }()
    private var yamlSyntaxHighlighter: SyntaxHighlighter?
    private let yamlContainerView = NSView()
    private let secretYAMLEncodingNotice = NSTextField(labelWithString:
        "Secret data values in YAML use Kubernetes base64 encoding. Use Data to edit decoded values."
    )
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let managedFieldsButton = NSButton(
        checkboxWithTitle: "Show Managed Fields", target: nil, action: nil
    )
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var detail: ObjectDetail?
    private var originalYAML = Data()
    private var yamlPresentation = YAMLManagedFieldsPresentation(
        unprocessedYAMLUTF8: Data()
    )
    private var yamlPresentationTask: Task<Void, Never>?
    private var pendingYAMLPresentation: (yamlUTF8: Data, generation: UInt64)?
    private var yamlPresentationGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var relationshipsTask: Task<Void, Never>?
    private var relationshipScanTask: Task<Void, Never>?
    private var activeRelationshipScan: (id: String, generation: UInt64)?
    private var operationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var isEditingYAML = false
    private var summaryItems: [ObjectDetailSummaryTableItem] = []
    private var eventsSnapshot = ObjectDetailEventsSnapshot.loading
    private var relativeTimeRefreshID: UUID?
    private var relationships: [ObjectRelationship] = []
    private var relationshipsLoaded = false
    private var childrenPotentiallyIncomplete = true
    private var summaryTableLayoutBinding: TableLayoutBinding?
    private var relationshipsTableLayoutBinding: TableLayoutBinding?
    private var watchGate = GenerationSequenceGate()
    private var terminalObjectState = false

    var onBack: (() -> Void)?
    var onOpenEvents: ((ResourceIdentity) -> Void)?
    var onEditMetadata: ((ResourceIdentity, ResourceMetadataKind, String?) -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?
    private(set) var workspaceStatus = WorkspaceStatus("Loading…", busy: true)
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot {
        let summarySelected = segmented.selectedSegment
            == ObjectDetailInitialTab.summary.segment
        return ContextualShortcutCatalog.objectDetails(
            canEditSelectedMetadata: summarySelected,
            canOpenEvents: summarySelected
                && eventsController != nil
                && onOpenEvents != nil
        )
    }

    init(
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        initialTab: ObjectDetailInitialTab = .automatic,
        session: OpenedClusterSession? = nil,
        tableLayoutStore: TableLayoutStore? = nil,
        eventsController: (any ObjectDetailEventsControlling)? = nil,
        yamlPresentationBuilder: @escaping @Sendable (Data)
            -> YAMLManagedFieldsPresentation = {
            YAMLManagedFieldsPresentation(yamlUTF8: $0)
        }
    ) {
        self.identity = identity
        self.session = session
        self.provider = provider
        self.initialTab = initialTab
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.eventsController = eventsController
        self.yamlPresentationBuilder = yamlPresentationBuilder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        watchTask?.cancel()
        relationshipsTask?.cancel()
        relationshipScanTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        yamlPresentationTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        let backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            target: self,
            action: #selector(backPressed)
        )
        backButton.bezelStyle = .texturedRounded
        let breadcrumb = NSTextField(labelWithString: breadcrumbText)
        breadcrumb.font = .systemFont(ofSize: 15, weight: .semibold)
        breadcrumb.lineBreakMode = .byTruncatingMiddle
        segmented.selectedSegment = initialTab.segment
        segmented.target = self
        segmented.action = #selector(tabChanged)

        let header = NSStackView(views: [backButton, breadcrumb, NSView(), segmented])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        if let eventsController {
            eventsController.onSnapshotChanged = { [weak self] snapshot in
                self?.install(eventsSnapshot: snapshot)
            }
        }
        configureSummary()
        configureRelationships()
        configureYAML()
        view = root
        tabChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        loadObject()
        if segmented.selectedSegment == ObjectDetailInitialTab.yaml.segment {
            view.window?.makeFirstResponder(yamlTextView)
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
        relationshipsTask?.cancel()
        relationshipScanTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        eventsController?.stop()
        cancelYAMLPresentationPreparation()
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

    /// Helper restart invalidates the session behind this detail. Keep any
    /// local editor buffer visible, but stop all work and disable mutation
    /// controls until the workspace fresh-GETs this exact UID in a new session.
    func engineDidDisconnect() {
        loadTask?.cancel()
        loadTask = nil
        watchTask?.cancel()
        watchTask = nil
        relationshipsTask?.cancel()
        relationshipsTask = nil
        relationshipScanTask?.cancel()
        relationshipScanTask = nil
        operationTask?.cancel()
        operationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        eventsController?.engineDidDisconnect()
        cancelYAMLPresentationPreparation()
        activeRelationshipScan = nil
        publishStatus(WorkspaceStatus(
            isEditingYAML
                ? "Engine disconnected · local edit preserved"
                : "Engine disconnected · reopening this UID when ready",
            severity: .warning
        ))
        editButton.isEnabled = false
        saveButton.isEnabled = false
        disableEditingAfterDeletion()
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

    private var isSecretObject: Bool {
        identity.group.isEmpty && identity.version == "v1" && identity.resource == "secrets"
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

    private func configureRelationships() {
        configureTable(
            relationshipsTable,
            columns: [
                ("kind", "Relationship", 110), ("resource", "Resource", 150),
                ("namespace", "Namespace", 150), ("name", "Name", 280),
                ("state", "State", 110),
            ]
        )
        relationshipsTable.setAccessibilityLabel("Kubernetes object relationships")
        relationshipsScrollView.documentView = relationshipsTable
        relationshipsScrollView.hasVerticalScroller = true
        relationshipsScrollView.hasHorizontalScroller = true
        relationshipsTableLayoutBinding = TableLayoutBinding(
            tableView: relationshipsTable,
            surface: .objectRelationships,
            store: tableLayoutStore
        )
        relationshipsCoverageLabel.textColor = .secondaryLabelColor
        relationshipsCoverageLabel.lineBreakMode = .byTruncatingTail
        scanRelationshipsButton.target = self
        scanRelationshipsButton.action = #selector(scanAllRelationships)
        cancelRelationshipScanButton.target = self
        cancelRelationshipScanButton.action = #selector(cancelRelationshipScan)
        cancelRelationshipScanButton.isHidden = true
        let controls = NSStackView(views: [
            relationshipsCoverageLabel, NSView(),
            scanRelationshipsButton, cancelRelationshipScanButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        relationshipsScrollView.translatesAutoresizingMaskIntoConstraints = false
        relationshipsContainerView.addSubview(controls)
        relationshipsContainerView.addSubview(relationshipsScrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: relationshipsContainerView.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: relationshipsContainerView.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: relationshipsContainerView.topAnchor, constant: 6),
            relationshipsScrollView.leadingAnchor.constraint(equalTo: relationshipsContainerView.leadingAnchor),
            relationshipsScrollView.trailingAnchor.constraint(equalTo: relationshipsContainerView.trailingAnchor),
            relationshipsScrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            relationshipsScrollView.bottomAnchor.constraint(equalTo: relationshipsContainerView.bottomAnchor),
        ])
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

    private func configureYAML() {
        yamlTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        yamlTextView.isRichText = false
        yamlTextView.isEditable = false
        yamlTextView.isSelectable = true
        yamlTextView.usesFindBar = true
        yamlTextView.configureAsTechnicalTextInput()
        yamlTextView.allowsUndo = true
        yamlTextView.delegate = self
        yamlTextView.onPlainEditShortcut = { [weak self] in
            guard let self,
                segmented.selectedSegment == ObjectDetailInitialTab.yaml.segment,
                detail != nil,
                !isEditingYAML,
                editButton.isEnabled
            else { return false }
            beginYAMLEdit()
            return true
        }
        yamlTextView.setAccessibilityLabel("Kubernetes object YAML")
        yamlTextView.textContainerInset = NSSize(width: 10, height: 10)
        yamlScrollView.hasVerticalScroller = true
        yamlScrollView.hasHorizontalScroller = true
        yamlScrollView.identifier = .init("object-detail-yaml-scroll")
        yamlScrollView.autohidesScrollers = true

        editButton.target = self
        editButton.action = #selector(beginYAMLEdit)
        managedFieldsButton.target = self
        managedFieldsButton.action = #selector(toggleManagedFields)
        managedFieldsButton.state = .off
        managedFieldsButton.isHidden = true
        saveButton.target = self
        saveButton.action = #selector(saveYAML)
        cancelButton.target = self
        cancelButton.action = #selector(cancelYAMLEdit)
        saveButton.isHidden = true
        cancelButton.isHidden = true
        let controls = NSStackView(views: [
            editButton, managedFieldsButton, saveButton, cancelButton, NSView(),
        ])
        controls.orientation = .horizontal
        controls.translatesAutoresizingMaskIntoConstraints = false
        secretYAMLEncodingNotice.identifier = .init("secret-yaml-base64-notice")
        secretYAMLEncodingNotice.textColor = .secondaryLabelColor
        secretYAMLEncodingNotice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        secretYAMLEncodingNotice.lineBreakMode = .byWordWrapping
        secretYAMLEncodingNotice.maximumNumberOfLines = 2
        secretYAMLEncodingNotice.setAccessibilityLabel(
            "Secret YAML values are Kubernetes base64 encoded"
        )
        secretYAMLEncodingNotice.translatesAutoresizingMaskIntoConstraints = false
        yamlScrollView.translatesAutoresizingMaskIntoConstraints = false
        yamlContainerView.addSubview(controls)
        if isSecretObject {
            yamlContainerView.addSubview(secretYAMLEncodingNotice)
        }
        yamlContainerView.addSubview(yamlScrollView)
        var constraints = [
            controls.leadingAnchor.constraint(equalTo: yamlContainerView.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: yamlContainerView.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: yamlContainerView.topAnchor, constant: 6),
            yamlScrollView.leadingAnchor.constraint(equalTo: yamlContainerView.leadingAnchor),
            yamlScrollView.trailingAnchor.constraint(equalTo: yamlContainerView.trailingAnchor),
            yamlScrollView.bottomAnchor.constraint(equalTo: yamlContainerView.bottomAnchor),
        ]
        if isSecretObject {
            constraints.append(contentsOf: [
                secretYAMLEncodingNotice.leadingAnchor.constraint(
                    equalTo: yamlContainerView.leadingAnchor, constant: 12
                ),
                secretYAMLEncodingNotice.trailingAnchor.constraint(
                    lessThanOrEqualTo: yamlContainerView.trailingAnchor, constant: -12
                ),
                secretYAMLEncodingNotice.topAnchor.constraint(
                    equalTo: controls.bottomAnchor, constant: 4
                ),
                yamlScrollView.topAnchor.constraint(
                    equalTo: secretYAMLEncodingNotice.bottomAnchor, constant: 5
                ),
            ])
        } else {
            constraints.append(yamlScrollView.topAnchor.constraint(
                equalTo: controls.bottomAnchor, constant: 5
            ))
        }
        NSLayoutConstraint.activate(constraints)
        yamlSyntaxHighlighter = SyntaxHighlighter(
            textView: yamlTextView,
            scrollView: yamlScrollView
        )
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
        installYAML(detail.yamlUTF8)
        renderSummary(detail)
        publishStatus(WorkspaceStatus("Resource version \(detail.resourceVersion)"))
        startObjectWatch(resourceVersion: detail.resourceVersion)
        updateEventsActivation()
    }

    private func installRecovery(detail updatedDetail: ObjectDetail) throws {
        guard updatedDetail.identity.uid == identity.uid else {
            terminalObjectState = true
            disableEditingAfterDeletion()
            throw ClusterManagerIssue(
                category: .conflict,
                reason: "ObjectRecreated",
                message: "A same-name object has a different UID and cannot replace this detail view.",
                operation: "recover object details"
            )
        }
        let preserveYAML = isEditingYAML
        identity = updatedDetail.identity
        terminalObjectState = false
        editButton.isEnabled = true
        saveButton.isEnabled = isEditingYAML
        installYAML(updatedDetail.yamlUTF8)
        if preserveYAML, var editingBasis = detail {
            editingBasis.identity = updatedDetail.identity
            detail = editingBasis
        } else {
            detail = updatedDetail
            showYAMLPresentation()
        }
        renderSummary(updatedDetail)
        watchTask?.cancel()
        watchTask = nil
        startObjectWatch(resourceVersion: updatedDetail.resourceVersion)
        relationshipsLoaded = false
        tabChanged()
        publishStatus(WorkspaceStatus(
            preserveYAML
                ? "Reconnected · server refreshed · local YAML edit preserved"
                : "Reconnected · resource version \(updatedDetail.resourceVersion)",
            severity: preserveYAML ? .warning : .informational
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

    @objc private func tabChanged() {
        let selectedSegment = segmented.selectedSegment
        if selectedSegment != ObjectDetailInitialTab.summary.segment {
            eventsController?.deactivate()
        }
        switch selectedSegment {
        case 1:
            show(yamlContainerView)
            // Cmd-F is provided by NSTextView's find bar. When Y opens this
            // controller, focus the YAML document itself instead of leaving
            // the controller root as first responder.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    self.segmented.selectedSegment == ObjectDetailInitialTab.yaml.segment,
                    self.view.window != nil
                else { return }
                self.view.window?.makeFirstResponder(self.yamlTextView)
            }
        case ObjectDetailInitialTab.relationships.segment:
            show(relationshipsContainerView)
            loadRelationshipsIfNeeded()
        default:
            show(summaryScrollView)
            updateEventsActivation()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                    self.segmented.selectedSegment == ObjectDetailInitialTab.summary.segment,
                    self.view.window != nil
                else { return }
                self.view.window?.makeFirstResponder(self.summaryTable)
            }
        }
        onContextualShortcutsChanged?()
    }

    private func updateEventsActivation() {
        guard detail != nil,
            segmented.selectedSegment == ObjectDetailInitialTab.summary.segment
        else {
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
                        disableEditingAfterDeletion()
                    case .failure(_, let issue):
                        if issue.reason == "ObjectRecreated" || issue.reason == "NotFound" {
                            terminalObjectState = true
                            publishStatus(WorkspaceStatus(
                                "Unavailable · same-name objects are not substituted for this UID",
                                severity: .error
                            ))
                            disableEditingAfterDeletion()
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
        if isEditingYAML {
            if updated.resourceVersion != detail?.resourceVersion {
                publishStatus(WorkspaceStatus(
                    "Server object changed · local YAML edit preserved",
                    severity: .warning
                ))
            }
            return
        }
        // Kubernetes resourceVersion identifies the complete serialized
        // object. Re-presenting the same version only reloads both tables and
        // restarts YAML preparation without adding any information.
        if !updated.resourceVersion.isEmpty,
            updated.resourceVersion == detail?.resourceVersion
        {
            return
        }
        let presented = ObjectDetailWatchPresentation.merging(updated, previous: detail)
        detail = presented
        installYAML(presented.yamlUTF8)
        renderSummary(presented)
        publishStatus(WorkspaceStatus(
            "Watching · resource version \(updated.resourceVersion)"
        ))
    }

    private func disableEditingAfterDeletion() {
        editButton.isEnabled = false
        saveButton.isEnabled = false
    }

    private func loadRelationshipsIfNeeded() {
        guard !relationshipsLoaded, relationshipsTask == nil else { return }
        publishStatus(WorkspaceStatus("Loading relationships…", busy: true))
        relationshipsTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer { relationshipsTask = nil }
            do {
                let result = try await provider.getRelationships(
                    identity: identity,
                    includeChildren: true
                )
                guard !Task.isCancelled else { return }
                relationships = result.values
                childrenPotentiallyIncomplete = result.childrenPotentiallyIncomplete
                relationshipsLoaded = true
                relationshipsTable.reloadData()
                updateRelationshipCoverageLabel()
                publishStatus(WorkspaceStatus(
                    relationships.isEmpty
                        ? "No relationships found in current caches"
                        : "\(relationships.count) relationship\(relationships.count == 1 ? "" : "s")"
                ))
            } catch {
                guard !Task.isCancelled else { return }
                show(error: error)
            }
        }
    }

    private func updateRelationshipCoverageLabel() {
        relationshipsCoverageLabel.stringValue = childrenPotentiallyIncomplete
            ? "Cached children · potentially incomplete"
            : "All discovered resources scanned"
        relationshipsCoverageLabel.textColor = childrenPotentiallyIncomplete
            ? .systemOrange : .secondaryLabelColor
    }

    @objc private func scanAllRelationships() {
        guard relationshipScanTask == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Scan all listable resources?"
        alert.informativeText = "This performs metadata LIST requests across the cluster and may be slow or denied for some resource types."
        alert.addButton(withTitle: "Scan All Resources")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        scanRelationshipsButton.isHidden = true
        cancelRelationshipScanButton.isHidden = false
        publishStatus(WorkspaceStatus("Starting relationship scan…", busy: true))
        relationshipScanTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer {
                relationshipScanTask = nil
                activeRelationshipScan = nil
                scanRelationshipsButton.isHidden = false
                cancelRelationshipScanButton.isHidden = true
            }
            do {
                var collection = RelationshipScanCollection(baseline: relationships)
                for try await message in provider.scanRelationships(identity: identity) {
                    guard !Task.isCancelled else { return }
                    activeRelationshipScan = (message.scanID, message.cursor.generation)
                    collection.apply(message)
                    relationships = collection.values
                    relationshipsTable.reloadData()
                    childrenPotentiallyIncomplete = message.progress.potentiallyIncomplete
                    updateRelationshipCoverageLabel()
                    if message.progress.complete {
                        publishStatus(WorkspaceStatus(
                            message.progress.potentiallyIncomplete
                                ? "Scan finished with \(message.progress.resourcesFailed) inaccessible resource type(s) · results potentially incomplete"
                                : "Scan complete · \(message.progress.objectsExamined.formatted()) objects examined",
                            severity: message.progress.potentiallyIncomplete
                                ? .warning : .informational,
                            toolTip: message.warning?.userFacingPresentation.detailedText
                        ))
                    } else {
                        let current = message.progress.currentResource.isEmpty
                            ? "discovering resources" : message.progress.currentResource
                        publishStatus(WorkspaceStatus(
                            "Scanning \(message.progress.resourcesScanned)/\(message.progress.resourcesTotal) · \(message.progress.objectsExamined.formatted()) objects · \(current)",
                            severity: message.warning == nil ? .informational : .warning,
                            busy: true,
                            toolTip: message.warning?.userFacingPresentation.detailedText
                        ))
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    publishStatus(WorkspaceStatus("Relationship scan cancelled"))
                    return
                }
                childrenPotentiallyIncomplete = true
                updateRelationshipCoverageLabel()
                show(error: error)
            }
        }
    }

    @objc private func cancelRelationshipScan() {
        if let activeRelationshipScan {
            Task { [provider, identity] in
                await provider.cancelRelationshipScan(
                    sessionID: identity.clusterSessionID,
                    scanID: activeRelationshipScan.id,
                    generation: activeRelationshipScan.generation
                )
            }
        }
        relationshipScanTask?.cancel()
    }

    private func show(_ child: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        if child === yamlContainerView {
            // The factory-created scroll view still needs its new constraints
            // resolved at the moment a previously detached tab is installed.
            // AppKit then owns all document sizing; no custom TextKit geometry
            // or ruler reconciliation participates in this path.
            contentContainer.layoutSubtreeIfNeeded()
            yamlContainerView.layoutSubtreeIfNeeded()
            yamlScrollView.layoutSubtreeIfNeeded()
        }
    }

    @objc private func beginYAMLEdit() {
        guard operationTask == nil else { return }
        // Editing always starts from the complete authoritative YAML even when
        // managedFields were hidden in the read-only presentation. The backend
        // protects them from apply along with the other server-owned fields.
        replaceYAMLText(with: String(decoding: originalYAML, as: UTF8.self))
        isEditingYAML = true
        editButton.isHidden = true
        managedFieldsButton.isHidden = true
        saveButton.isHidden = false
        cancelButton.isHidden = false
        updateYAMLEditControls()
        view.window?.makeFirstResponder(yamlTextView)
    }

    @objc private func cancelYAMLEdit() {
        guard operationTask == nil else { return }
        finishYAMLEdit()
    }

    @objc private func saveYAML() {
        guard let detail, operationTask == nil else { return }
        let edited = Data(yamlTextView.string.utf8)
        publishStatus(WorkspaceStatus("Validating…", busy: true))
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer {
                operationTask = nil
                updateYAMLEditControls()
            }
            do {
                let prepared = try await provider.prepareYAML(
                    identity: identity,
                    yamlUTF8: edited,
                    expectedResourceVersion: detail.resourceVersion,
                    forceFieldOwnership: false
                )
                guard await confirm(prepared: prepared) else {
                    publishStatus(WorkspaceStatus("Save cancelled"))
                    return
                }
                let stream = try await provider.applyYAML(
                    identity: identity,
                    yamlUTF8: prepared.normalizedYAMLUTF8,
                    expectedResourceVersion: detail.resourceVersion,
                    forceFieldOwnership: false
                )
                for try await progress in stream {
                    publishStatus(WorkspaceStatus(
                        "Saving… \(progress.completedItems)/\(progress.totalItems)",
                        busy: !progress.state.isTerminal
                    ))
                    if progress.state.isTerminal {
                        if progress.state == .succeeded {
                            originalYAML = prepared.normalizedYAMLUTF8
                            finishYAMLEdit()
                            loadTask?.cancel()
                            loadTask = nil
                            loadObject()
                        } else {
                            throw progress.issue ?? ClusterManagerIssue(
                                category: .conflict,
                                reason: "YAMLApplyFailed",
                                message: "The YAML edit was not applied. Your local edit is still open.",
                                operation: "apply YAML"
                            )
                        }
                    }
                }
            } catch {
                // Preserve the local editor buffer on conflict or validation error.
                show(error: error)
            }
        }
        updateYAMLEditControls()
    }

    private func confirm(prepared: PreparedYAMLEdit) async -> Bool {
        guard !prepared.diff.isEmpty else { return true }
        guard let parent = view.window else { return false }
        let controller = YAMLDiffConfirmationWindowController(
            targetDetails: mutationConfirmationIdentityText,
            prepared: prepared,
            tableLayoutStore: tableLayoutStore
        )
        return await controller.runSheet(for: parent) == .apply
    }

    private func finishYAMLEdit() {
        isEditingYAML = false
        editButton.isHidden = false
        managedFieldsButton.isHidden = !yamlPresentation.hasManagedFields
        saveButton.isHidden = true
        cancelButton.isHidden = true
        updateYAMLEditControls()
        showYAMLPresentation()
    }

    private func updateYAMLEditControls() {
        let idle = operationTask == nil
        yamlTextView.isEditable = isEditingYAML && idle && !terminalObjectState
        saveButton.isEnabled = isEditingYAML && idle && !terminalObjectState
        cancelButton.isEnabled = isEditingYAML && idle
        editButton.isEnabled = !isEditingYAML && idle && !terminalObjectState
    }

    @objc private func toggleManagedFields() {
        guard !isEditingYAML else { return }
        showYAMLPresentation()
    }

    private func installYAML(_ yamlUTF8: Data) {
        originalYAML = yamlUTF8
        yamlPresentationGeneration &+= 1
        let generation = yamlPresentationGeneration
        pendingYAMLPresentation = (yamlUTF8, generation)
        // The first snapshot can be shown immediately while its managed-fields
        // presentation is prepared. Once a coherent presentation exists,
        // retain it until the replacement is ready. Installing raw YAML and
        // hiding the toggle for every busy WATCH event makes the view alternate
        // between raw and filtered states many times per second.
        if yamlPresentation.completeYAML.isEmpty {
            yamlPresentation = YAMLManagedFieldsPresentation(
                unprocessedYAMLUTF8: yamlUTF8
            )
            managedFieldsButton.isHidden = true
            if !isEditingYAML { showYAMLPresentation() }
        }

        if let yamlPresentationTask {
            // The synchronous builder cannot be interrupted once it begins.
            // Cancel its acceptance and retain only this latest pending input;
            // its completion will start the replacement worker.
            yamlPresentationTask.cancel()
        } else {
            startYAMLPresentationPreparation()
        }
    }

    private func startYAMLPresentationPreparation() {
        guard yamlPresentationTask == nil,
            let request = pendingYAMLPresentation
        else { return }
        pendingYAMLPresentation = nil
        let builder = yamlPresentationBuilder
        yamlPresentationTask = Task { [weak self] in
            do {
                let presentation = try await Self.prepareYAMLPresentation(
                    request.yamlUTF8,
                    using: builder
                )
                guard !Task.isCancelled else {
                    self?.finishYAMLPresentationPreparation()
                    return
                }
                self?.acceptYAMLPresentation(
                    presentation,
                    generation: request.generation
                )
            } catch is CancellationError {
                // A replacement or controller shutdown canceled this request.
            } catch {
                assertionFailure("Unexpected YAML presentation error: \(error)")
            }
            self?.finishYAMLPresentationPreparation()
        }
    }

    private func acceptYAMLPresentation(
        _ presentation: YAMLManagedFieldsPresentation,
        generation: UInt64
    ) {
        guard yamlPresentationGeneration == generation else { return }
        yamlPresentation = presentation
        if !presentation.hasManagedFields { managedFieldsButton.state = .off }
        managedFieldsButton.isHidden = !presentation.hasManagedFields || isEditingYAML
        if !isEditingYAML { showYAMLPresentation() }
    }

    private func finishYAMLPresentationPreparation() {
        yamlPresentationTask = nil
        startYAMLPresentationPreparation()
    }

    /// Nonisolated async functions execute on the generic executor. Keeping
    /// the synchronous Yams work inside this hop prevents large managedFields
    /// payloads from blocking AppKit's main actor.
    nonisolated static func prepareYAMLPresentation(
        _ yamlUTF8: Data,
        using builder: @Sendable (Data) -> YAMLManagedFieldsPresentation
    ) async throws -> YAMLManagedFieldsPresentation {
        try Task.checkCancellation()
        let presentation = builder(yamlUTF8)
        try Task.checkCancellation()
        return presentation
    }

    private func cancelYAMLPresentationPreparation() {
        yamlPresentationGeneration &+= 1
        pendingYAMLPresentation = nil
        yamlPresentationTask?.cancel()
    }

    private func showYAMLPresentation() {
        let text = yamlPresentation.text(
            showingManagedFields: managedFieldsButton.state == .on
        )
        replaceYAMLText(with: text)
    }

    private func replaceYAMLText(with text: String) {
        guard yamlTextView.string != text else { return }
        let selectedRanges = yamlTextView.selectedRanges
        let visibleOrigin = yamlScrollView.contentView.bounds.origin
        yamlTextView.string = text
        let textLength = (text as NSString).length
        let restoredRanges = selectedRanges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= textLength else { return nil }
            return NSValue(range: NSRange(
                location: range.location,
                length: min(range.length, textLength - range.location)
            ))
        }
        if !restoredRanges.isEmpty { yamlTextView.selectedRanges = restoredRanges }
        yamlScrollView.contentView.scroll(to: visibleOrigin)
        yamlScrollView.reflectScrolledClipView(yamlScrollView.contentView)
        yamlSyntaxHighlighter?.invalidate()
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditingYAML {
            cancelYAMLEdit()
        } else {
            onBack?()
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if isEditingYAML { saveYAML() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case summaryTable: summaryItems.count
        case relationshipsTable: relationships.count
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
        if tableView === relationshipsTable {
            guard relationships.indices.contains(row), let tableColumn else { return nil }
            let relationship = relationships[row]
            let value: String
            switch tableColumn.identifier.rawValue {
            case "kind": value = relationship.kind.rawValue.capitalized
            case "resource": value = relationship.identity.resource
            case "namespace": value = relationship.identity.namespace.isEmpty ? "Cluster" : relationship.identity.namespace
            case "name": value = relationship.identity.name
            case "state":
                if relationship.stale {
                    value = "Stale UID"
                } else if relationship.potentiallyIncomplete {
                    value = "Cached"
                } else {
                    value = "Current"
                }
            default: value = ""
            }
            let cell = textCell(value, table: tableView, column: tableColumn)
            cell.textField?.textColor = relationship.stale ? .systemOrange : .labelColor
            return cell
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

    private func textCell(
        _ value: String,
        table: NSTableView,
        column: NSTableColumn
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("detail.\(column.identifier.rawValue)")
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

    @objc private func backPressed() { onBack?() }

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
