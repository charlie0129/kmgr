import AppKit
import KmgrCore

enum ObjectDetailInitialTab {
    case automatic
    case summary
    case yaml
    case events
    case relationships
    case metrics
    case data

    func segment(supportsDataEditor: Bool, supportsMetrics: Bool) -> Int {
        switch self {
        case .automatic:
            supportsDataEditor ? 5 : 0
        case .summary:
            0
        case .yaml:
            1
        case .events:
            2
        case .relationships:
            3
        case .metrics:
            supportsMetrics ? 4 : 0
        case .data:
            supportsDataEditor ? 5 : 0
        }
    }
}

enum ObjectDetailSummaryPresentation {
    static let maximumMetadataEntriesPerSection = 64
    static let maximumMetadataKeyCharacters = 320
    static let maximumMetadataValueCharacters = 256

    static func fields(for detail: ObjectDetail) -> [ObjectSummaryField] {
        detail.summaryFields
            + metadataFields(sectionID: "labels", values: detail.labels)
            + metadataFields(sectionID: "annotations", values: detail.annotations)
    }

    private static func metadataFields(
        sectionID: String,
        values: [String: String]
    ) -> [ObjectSummaryField] {
        let ordered = values.sorted { $0.key < $1.key }
        let visible = ordered.prefix(maximumMetadataEntriesPerSection)
        var fields = visible.map { key, value in
            let normalized = normalizedMetadataText(value)
            let display = bounded(normalized, maximumCharacters: maximumMetadataValueCharacters)
            let truncated = display != normalized
            return ObjectSummaryField(
                sectionID: sectionID,
                fieldID: key,
                label: bounded(
                    normalizedMetadataText(key),
                    maximumCharacters: maximumMetadataKeyCharacters
                ),
                displayText: display.isEmpty ? "—" : display,
                tooltip: truncated
                    ? "Value truncated after \(maximumMetadataValueCharacters) characters."
                    : ""
            )
        }
        let omitted = ordered.count - visible.count
        if omitted > 0 {
            fields.append(ObjectSummaryField(
                sectionID: sectionID,
                fieldID: "additionalEntries",
                label: "Additional Entries",
                displayText: "\(omitted) not shown"
            ))
        }
        return fields
    }

    private static func normalizedMetadataText(_ value: String) -> String {
        value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func bounded(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }
}

enum ObjectDetailWatchPresentation {
    /// WatchObject has no include-metrics contract. An empty metrics array on
    /// a watch update therefore means "not carried by this stream", not that
    /// the Metrics API retracted the values fetched by GetObject.
    static func merging(_ update: ObjectDetail, previous: ObjectDetail?) -> ObjectDetail {
        guard let previous else { return update }
        var merged = update
        // A watch payload with no YAML is not an authoritative deletion of the
        // object's serialization. Retain the last non-empty snapshot so a
        // transient helper/watch omission cannot blank either YAML renderer.
        if update.yamlUTF8.isEmpty, !previous.yamlUTF8.isEmpty {
            merged.yamlUTF8 = previous.yamlUTF8
        }
        if update.metrics.isEmpty, !previous.metrics.isEmpty {
            merged.metrics = previous.metrics
        }
        return merged
    }
}

/// A fresh, UID-authoritative detail surface. It replaces the table area in a
/// workspace; no inspector or bottom drawer is introduced.
@MainActor
final class ObjectDetailViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate
{
    private enum DataEditorKeyRow {
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
    private let initialTab: ObjectDetailInitialTab
    private let dataFileReader: @Sendable (URL) throws -> Data
    private let dataFileWriter: @Sendable (Data, URL) throws -> Void
    private let yamlPresentationBuilder:
        @Sendable (Data) -> YAMLManagedFieldsPresentation
    private let segmented = NSSegmentedControl(
        labels: ["Summary", "YAML", "Events", "Relationships", "Metrics", "Data"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private let contentContainer = NSView()
    private let summaryStack = NSStackView()
    private let summaryScrollView = NSScrollView()
    private let eventsTable = NSTableView()
    private let eventsScrollView = NSScrollView()
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
    private let metricsStack = NSStackView()
    private let metricsScrollView = NSScrollView()
    private lazy var yamlScrollView = NSTextView.scrollablePlainDocumentContentTextView()
    private lazy var yamlTextView: NSTextView = {
        guard let textView = yamlScrollView.documentView as? NSTextView else {
            preconditionFailure("AppKit did not create a YAML document text view")
        }
        return textView
    }()
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
    private let dataSplitView = NSSplitView()
    private let keysTable = NSTableView()
    private let dataValueTextView = NSTextView()
    private let dataValueScroll = NSScrollView()
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let addKeyButton = NSButton(title: "Add Key", target: nil, action: nil)
    private let renameKeyButton = NSButton(title: "Rename", target: nil, action: nil)
    private let deleteKeyButton = NSButton(title: "Delete Key", target: nil, action: nil)
    private let revertKeyButton = NSButton(title: "Revert", target: nil, action: nil)
    private let importKeyButton = NSButton(title: "Replace from File…", target: nil, action: nil)
    private let exportKeyButton = NSButton(title: "Export…", target: nil, action: nil)
    private let saveKeyButton = NSButton(title: "Save Key", target: nil, action: nil)

    private var detail: ObjectDetail?
    private var objectData: ObjectData?
    private var selectedDataKey: String?
    private var selectedDataEntry: ObjectDataEntry?
    private var originalYAML = Data()
    private var yamlPresentation = YAMLManagedFieldsPresentation(
        unprocessedYAMLUTF8: Data()
    )
    private var yamlPresentationTask: Task<Void, Never>?
    private var pendingYAMLPresentation: (yamlUTF8: Data, generation: UInt64)?
    private var yamlPresentationGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var relationshipsTask: Task<Void, Never>?
    private var relationshipScanTask: Task<Void, Never>?
    private var activeRelationshipScan: (id: String, generation: UInt64)?
    private var operationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var dataFileTask: Task<Void, Never>?
    private var dataFileGeneration: UInt64 = 0
    private var authoritativeMutationRefreshInFlight = false
    /// True when the YAML GET succeeded but the independent ConfigMap/Secret
    /// Data GET did not. Existing drafts may remain visible, but no value may
    /// be edited or submitted against an unverified resource version.
    private var dataAuthorityUnavailable = false
    private var dataConflictController: DataConflictWindowController?
    private var conflictedDataKey: String?
    private let dataDrafts = DataEditorDraftStore()
    private var secretRevealed = false
    private var selectedDataDraftKind: DataValueKind?
    private var selectedDataCanEditText = false
    private var isInstallingDataEditorState = false
    private var isEditingYAML = false
    private var events: [KubernetesObjectEvent] = []
    private var relationships: [ObjectRelationship] = []
    private var eventsLoaded = false
    private var relationshipsLoaded = false
    private var childrenPotentiallyIncomplete = true
    private var watchGate = GenerationSequenceGate()
    private var terminalObjectState = false

    var onBack: (() -> Void)?

    init(
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        initialTab: ObjectDetailInitialTab = .automatic,
        session: OpenedClusterSession? = nil,
        dataFileReader: @escaping @Sendable (URL) throws -> Data = {
            try DataValueFileIO.readBounded(from: $0)
        },
        dataFileWriter: @escaping @Sendable (Data, URL) throws -> Void = {
            try DataValueFileIO.write($0, to: $1)
        },
        yamlPresentationBuilder: @escaping @Sendable (Data)
            -> YAMLManagedFieldsPresentation = {
            YAMLManagedFieldsPresentation(yamlUTF8: $0)
        }
    ) {
        self.identity = identity
        self.session = session
        self.provider = provider
        self.initialTab = initialTab
        self.dataFileReader = dataFileReader
        self.dataFileWriter = dataFileWriter
        self.yamlPresentationBuilder = yamlPresentationBuilder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        watchTask?.cancel()
        eventsTask?.cancel()
        relationshipsTask?.cancel()
        relationshipScanTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        dataFileTask?.cancel()
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
        segmented.selectedSegment = initialSegment
        segmented.target = self
        segmented.action = #selector(tabChanged)
        if !supportsMetrics { segmented.setEnabled(false, forSegment: 4) }
        if !supportsDataEditor { segmented.setEnabled(false, forSegment: 5) }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [backButton, breadcrumb, NSView(), segmented, statusLabel])
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
        configureSummary()
        configureEvents()
        configureRelationships()
        configureMetrics()
        configureYAML()
        configureDataEditor()
        view = root
        tabChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        updateVisibleTextDocumentGeometry()
        loadObject()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateVisibleTextDocumentGeometry()
        resizeStackDocument(summaryStack, in: summaryScrollView)
        resizeStackDocument(metricsStack, in: metricsScrollView)
    }

    private func updateVisibleTextDocumentGeometry() {
        TextDocumentGeometry.update(
            dataValueTextView,
            in: dataValueScroll,
            wrapsToViewport: true
        )
    }

    func stop() {
        loadTask?.cancel()
        watchTask?.cancel()
        eventsTask?.cancel()
        relationshipsTask?.cancel()
        relationshipScanTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        cancelYAMLPresentationPreparation()
        cancelDataFileOperation()
        recoveryTask = nil
        authoritativeMutationRefreshInFlight = false
        dataConflictController?.close()
        dataConflictController = nil
        releaseDataDrafts()
    }

    /// Helper restart invalidates the session behind this detail. Keep any
    /// local editor buffer visible, but stop all work and disable mutation
    /// controls until the workspace fresh-GETs this exact UID in a new session.
    func engineDidDisconnect() {
        loadTask?.cancel()
        loadTask = nil
        watchTask?.cancel()
        watchTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        relationshipsTask?.cancel()
        relationshipsTask = nil
        relationshipScanTask?.cancel()
        relationshipScanTask = nil
        operationTask?.cancel()
        operationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        cancelYAMLPresentationPreparation()
        cancelDataFileOperation()
        authoritativeMutationRefreshInFlight = false
        dataConflictController?.close()
        dataConflictController = nil
        activeRelationshipScan = nil
        statusLabel.toolTip = nil
        statusLabel.stringValue = isEditingYAML || hasAnyDataDraftChanges
            ? "Engine disconnected · local edit preserved"
            : "Engine disconnected · reopening this UID when ready"
        statusLabel.textColor = .systemOrange
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
        var reboundIdentity = identity
        reboundIdentity.clusterSessionID = recoveredSession.sessionID
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Reopening this UID…"
        statusLabel.textColor = .secondaryLabelColor
        recoveryTask = Task { [weak self, provider] in
            guard let self else { return }
            defer { recoveryTask = nil }
            do {
                if supportsDataEditor {
                    let detailIdentity = reboundIdentity
                    let dataIdentity = reboundIdentity
                    async let fetchedDetail = provider.getObject(identity: detailIdentity)
                    async let fetchedData: ObjectData? = try? await provider.getData(
                        identity: dataIdentity
                    )
                    let updatedDetail = try await fetchedDetail
                    let updatedData = await fetchedData
                    guard !Task.isCancelled else { return }
                    dataAuthorityUnavailable = updatedData == nil
                    try installRecovery(detail: updatedDetail, data: updatedData)
                    if updatedData == nil {
                        statusLabel.stringValue = hasAnyDataDraftChanges
                            ? "Reconnected · YAML refreshed · local Data draft preserved and locked"
                            : "Reconnected · YAML refreshed · key/value data unavailable"
                        statusLabel.textColor = .systemOrange
                    }
                } else {
                    let updatedDetail = try await provider.getObject(identity: reboundIdentity)
                    guard !Task.isCancelled else { return }
                    try installRecovery(detail: updatedDetail, data: nil)
                }
                completion(.success(()))
            } catch {
                guard !Task.isCancelled else { return }
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
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

    private var supportsDataEditor: Bool {
        identity.group.isEmpty && identity.version == "v1"
            && (identity.resource == "configmaps" || identity.resource == "secrets")
    }

    private var isSecretObject: Bool {
        identity.group.isEmpty && identity.version == "v1" && identity.resource == "secrets"
    }

    private var supportsMetrics: Bool {
        identity.group.isEmpty && identity.version == "v1"
            && (identity.resource == "pods" || identity.resource == "nodes")
    }

    private func configureSummary() {
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 7
        summaryStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        summaryStack.frame = NSRect(x: 0, y: 0, width: 640, height: 1)
        summaryStack.autoresizingMask = [.width]
        summaryScrollView.documentView = summaryStack
        summaryScrollView.hasVerticalScroller = true
        summaryScrollView.identifier = .init("object-detail-summary-scroll")
    }

    private func configureEvents() {
        configureTable(
            eventsTable,
            columns: [
                ("type", "Type", 80), ("reason", "Reason", 150),
                ("message", "Message", 420), ("last", "Last Seen", 150),
                ("count", "Count", 70),
            ]
        )
        eventsTable.setAccessibilityLabel("Kubernetes object events")
        eventsScrollView.documentView = eventsTable
        eventsScrollView.hasVerticalScroller = true
        eventsScrollView.hasHorizontalScroller = true
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

    private func configureMetrics() {
        metricsStack.orientation = .vertical
        metricsStack.alignment = .leading
        metricsStack.spacing = 8
        metricsStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        metricsStack.frame = NSRect(x: 0, y: 0, width: 640, height: 1)
        metricsStack.autoresizingMask = [.width]
        metricsScrollView.documentView = metricsStack
        metricsScrollView.hasVerticalScroller = true
        metricsScrollView.identifier = .init("object-detail-metrics-scroll")
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
        yamlTextView.isAutomaticQuoteSubstitutionEnabled = false
        yamlTextView.isAutomaticDashSubstitutionEnabled = false
        yamlTextView.allowsUndo = true
        yamlTextView.delegate = self
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
    }

    private func configureDataEditor() {
        dataSplitView.isVertical = true
        dataSplitView.dividerStyle = .thin
        dataSplitView.identifier = .init("object-detail-data-split")
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("key", "Key", 175, 100),
            ("value", "Value", 240, 120),
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
        keysTable.setAccessibilityLabel("ConfigMap and Secret data keys")
        let keyScroll = NSScrollView()
        keyScroll.identifier = .init("object-detail-data-keys-scroll")
        keyScroll.documentView = keysTable
        keyScroll.hasVerticalScroller = true
        keyScroll.hasHorizontalScroller = true
        keyScroll.autohidesScrollers = true
        keyScroll.frame = NSRect(x: 0, y: 0, width: 620, height: 500)

        dataValueTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        dataValueTextView.isRichText = false
        dataValueTextView.isEditable = false
        dataValueTextView.isSelectable = true
        dataValueTextView.allowsUndo = true
        dataValueTextView.delegate = self
        dataValueScroll.documentView = dataValueTextView
        dataValueScroll.hasVerticalScroller = true
        dataValueScroll.identifier = .init("object-detail-data-value-scroll")
        dataValueScroll.setAccessibilityLabel("Selected data value editor")
        TextDocumentGeometry.configure(
            dataValueTextView,
            in: dataValueScroll,
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
        saveKeyButton.target = self
        saveKeyButton.action = #selector(saveCurrentKey)
        saveKeyButton.isEnabled = false
        for button in [renameKeyButton, deleteKeyButton, revertKeyButton, importKeyButton, exportKeyButton] {
            button.isEnabled = false
        }
        let controls = NSStackView(views: [
            addKeyButton, renameKeyButton, deleteKeyButton, revertKeyButton,
            importKeyButton, exportKeyButton, revealButton, saveKeyButton, NSView(),
        ])
        controls.orientation = .horizontal
        let editor = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        dataValueScroll.translatesAutoresizingMaskIntoConstraints = false
        editor.addSubview(controls)
        editor.addSubview(dataValueScroll)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: editor.topAnchor, constant: 7),
            dataValueScroll.leadingAnchor.constraint(equalTo: editor.leadingAnchor),
            dataValueScroll.trailingAnchor.constraint(equalTo: editor.trailingAnchor),
            dataValueScroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            dataValueScroll.bottomAnchor.constraint(equalTo: editor.bottomAnchor),
        ])
        dataSplitView.addArrangedSubview(keyScroll)
        dataSplitView.addArrangedSubview(editor)
        dataSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        dataSplitView.setPosition(620, ofDividerAt: 0)
    }

    private func loadObject(
        preservingDataDrafts: Bool = false,
        lockingDataEditorUntilInstalled: Bool = false
    ) {
        guard loadTask == nil else { return }
        if lockingDataEditorUntilInstalled {
            authoritativeMutationRefreshInFlight = true
            updateDataEditorControls()
        }
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Loading…"
        statusLabel.textColor = .secondaryLabelColor
        loadTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            do {
                async let fetchedDetail = provider.getObject(identity: identity)
                if supportsDataEditor {
                    async let fetchedData: ObjectData? = try? await provider.getData(
                        identity: identity
                    )
                    let detail = try await fetchedDetail
                    let data = await fetchedData
                    guard !Task.isCancelled else { return }
                    install(
                        detail: detail,
                        data: data ?? (preservingDataDrafts ? objectData : nil),
                        preservingDataDrafts: preservingDataDrafts
                    )
                    if data == nil {
                        dataAuthorityUnavailable = true
                        statusLabel.stringValue = hasAnyDataDraftChanges
                            ? "YAML loaded · local Data draft preserved and locked"
                            : "YAML loaded · key/value data unavailable"
                        statusLabel.textColor = .systemOrange
                        updateDataEditorControls()
                    }
                } else {
                    let detail = try await fetchedDetail
                    guard !Task.isCancelled else { return }
                    install(detail: detail, data: nil)
                }
            } catch {
                show(error: error)
            }
            if lockingDataEditorUntilInstalled {
                authoritativeMutationRefreshInFlight = false
            }
            loadTask = nil
            updateDataEditorControls()
        }
    }

    private func install(
        detail: ObjectDetail,
        data: ObjectData?,
        preservingDataDrafts: Bool = false
    ) {
        let selectedKey = preservingDataDrafts ? selectedDataKey : nil
        if !preservingDataDrafts {
            releaseDataDrafts()
        }
        let wasInstallingDataEditorState = isInstallingDataEditorState
        isInstallingDataEditorState = true
        defer { isInstallingDataEditorState = wasInstallingDataEditorState }
        identity = detail.identity
        self.detail = detail
        objectData = data
        if data != nil { dataAuthorityUnavailable = false }
        selectedDataKey = nil
        selectedDataEntry = nil
        conflictedDataKey = nil
        installYAML(detail.yamlUTF8)
        renderSummary(detail)
        keysTable.reloadData()
        let rows = dataEditorRows
        if let data, let selectedKey,
            let row = rows.firstIndex(where: { $0.key == selectedKey })
        {
            keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            installSelectedDataRow(rows[row], secret: data.secret)
        } else {
            keysTable.deselectAll(nil)
            selectedDataKey = nil
            selectedDataDraftKind = nil
            selectedDataCanEditText = false
            dataValueTextView.string = ""
        }
        updateDataEditorControls()
        renderMetrics(detail.metrics)
        if selectedDataKey != nil, selectedDataEntry == nil {
            showMissingDataDraftStatus()
        } else {
            statusLabel.stringValue = "Resource version \(detail.resourceVersion)"
            statusLabel.textColor = .secondaryLabelColor
        }
        startObjectWatch(resourceVersion: detail.resourceVersion)
        if initialTab == .automatic, supportsDataEditor {
            segmented.selectedSegment = 5
            tabChanged()
        }
    }

    private func installRecovery(
        detail updatedDetail: ObjectDetail,
        data updatedData: ObjectData?
    ) throws {
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
        if let updatedData, updatedData.identity.uid != identity.uid {
            throw ClusterManagerIssue(
                category: .conflict,
                reason: "ObjectRecreated",
                message: "The key/value response belongs to a different Kubernetes UID.",
                operation: "recover key/value data"
            )
        }
        let preserveYAML = isEditingYAML
        let preserveData = hasAnyDataDraftChanges
        let selectedRow = keysTable.selectedRow

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
        renderMetrics(updatedDetail.metrics)

        if let updatedData {
            let wasInstallingDataEditorState = isInstallingDataEditorState
            isInstallingDataEditorState = true
            defer { isInstallingDataEditorState = wasInstallingDataEditorState }
            if preserveData {
                if var editingBasis = objectData {
                    editingBasis.identity = updatedData.identity
                    objectData = editingBasis
                }
                displaySelectedData()
            } else {
                releaseDataDrafts()
                objectData = updatedData
                secretRevealed = !updatedData.secret
                revealButton.title = "Reveal"
                keysTable.reloadData()
                let row = updatedData.entries.indices.contains(selectedRow) ? selectedRow : -1
                if row >= 0 {
                    keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    selectedDataKey = updatedData.entries[row].id
                    selectedDataEntry = updatedData.entries[row]
                    displaySelectedData()
                } else {
                    selectedDataKey = nil
                    selectedDataEntry = nil
                    selectedDataCanEditText = false
                    dataValueTextView.string = ""
                }
            }
            dataAuthorityUnavailable = false
        } else if !preserveData {
            releaseDataDrafts()
            objectData = nil
            selectedDataKey = nil
            selectedDataEntry = nil
            selectedDataCanEditText = false
            keysTable.reloadData()
            keysTable.deselectAll(nil)
            dataValueTextView.string = ""
        }
        watchTask?.cancel()
        watchTask = nil
        startObjectWatch(resourceVersion: updatedDetail.resourceVersion)
        eventsLoaded = false
        relationshipsLoaded = false
        tabChanged()
        updateDataEditorControls()
        if preserveYAML || preserveData {
            statusLabel.stringValue = "Reconnected · server refreshed · local edit preserved"
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "Reconnected · resource version \(updatedDetail.resourceVersion)"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func renderSummary(_ detail: ObjectDetail) {
        clear(summaryStack)
        let fields = ObjectDetailSummaryPresentation.fields(for: detail)
        var lastSection = ""
        for field in fields {
            if field.sectionID != lastSection {
                let heading = NSTextField(labelWithString: field.sectionID.capitalized)
                heading.identifier = NSUserInterfaceItemIdentifier("object-detail-summary-section")
                heading.font = .systemFont(ofSize: 13, weight: .semibold)
                summaryStack.addArrangedSubview(heading)
                lastSection = field.sectionID
            }
            let label = NSTextField(labelWithString: "\(field.label):  \(field.displayText)")
            label.identifier = NSUserInterfaceItemIdentifier("object-detail-summary-field")
            label.toolTip = field.tooltip
            label.textColor = field.severity == .critical ? .systemRed : .labelColor
            summaryStack.addArrangedSubview(label)
        }
        if fields.isEmpty {
            let label = NSTextField(labelWithString: "No summary fields are available.")
            label.textColor = .secondaryLabelColor
            summaryStack.addArrangedSubview(label)
        }
        resizeStackDocument(summaryStack, in: summaryScrollView)
    }

    private func renderMetrics(_ metrics: [ResourceUsageValue]) {
        clear(metricsStack)
        guard !metrics.isEmpty else {
            let label = NSTextField(labelWithString: "Metrics unavailable or not yet reported.")
            label.textColor = .secondaryLabelColor
            metricsStack.addArrangedSubview(label)
            resizeStackDocument(metricsStack, in: metricsScrollView)
            return
        }
        for value in metrics {
            let title = value.resourceName.isEmpty ? "Resource" : value.resourceName
            let used = value.usage.map { metricNumber($0, unit: value.unit) } ?? "Unavailable"

            var components = ["\(used) used"]
            if value.request != nil || value.limit != nil {
                let requested = value.request.map { metricNumber($0, unit: value.unit) } ?? "—"
                let limit = value.limit.map { metricNumber($0, unit: value.unit) } ?? "—"
                components.append("\(requested) requested")
                components.append("\(limit) limit")
            }
            if let capacity = value.capacity {
                components.append("\(metricNumber(capacity, unit: value.unit)) allocatable")
            }
            let label = NSTextField(labelWithString: "\(title):  \(components.joined(separator: " · "))")
            label.identifier = NSUserInterfaceItemIdentifier("object-detail-metric")
            if let measured = value.measuredAtUnixMilliseconds {
                label.toolTip = "Measured \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(measured) / 1_000))) · \(value.provider)"
            }
            metricsStack.addArrangedSubview(label)
        }
        resizeStackDocument(metricsStack, in: metricsScrollView)
    }

    /// Stack views also arrive with a zero document frame. Keep their width
    /// attached to the clip view and grow the document to its intrinsic
    /// content height after each render and window resize.
    private func resizeStackDocument(_ stack: NSStackView, in scrollView: NSScrollView) {
        let viewport = scrollView.contentSize
        let width = max(1, viewport.width)
        if stack.frame.width != width {
            stack.setFrameSize(NSSize(width: width, height: max(1, stack.frame.height)))
        }
        stack.layoutSubtreeIfNeeded()
        let height = max(viewport.height, stack.fittingSize.height, 1)
        if stack.frame.height != height {
            stack.setFrameSize(NSSize(width: width, height: height))
        }
    }

    private func clear(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { child in
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }

    private func metricNumber(_ value: Double, unit: String) -> String {
        KubernetesResourceQuantityFormatter.compact(value, unit: unit)
    }

    @objc private func tabChanged() {
        switch segmented.selectedSegment {
        case 1:
            show(yamlContainerView)
        case 2:
            show(eventsScrollView)
            loadEventsIfNeeded()
        case 3:
            show(relationshipsContainerView)
            loadRelationshipsIfNeeded()
        case 4 where supportsMetrics:
            show(metricsScrollView)
        case 5 where supportsDataEditor:
            show(dataSplitView)
        default:
            show(summaryScrollView)
        }
    }

    private var initialSegment: Int {
        initialTab.segment(
            supportsDataEditor: supportsDataEditor,
            supportsMetrics: supportsMetrics
        )
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
                            statusLabel.toolTip = nil
                            statusLabel.stringValue = "Watching · resource version \(currentVersion)"
                            statusLabel.textColor = .secondaryLabelColor
                        }
                    case .updated(_, let updated):
                        installWatchUpdate(updated)
                    case .deleted(_, _):
                        terminalObjectState = true
                        statusLabel.toolTip = nil
                        statusLabel.stringValue = "Deleted · this UID no longer exists"
                        statusLabel.textColor = .systemRed
                        disableEditingAfterDeletion()
                    case .failure(_, let issue):
                        if issue.reason == "ObjectRecreated" || issue.reason == "NotFound" {
                            terminalObjectState = true
                            statusLabel.toolTip = nil
                            statusLabel.stringValue = "Unavailable · same-name objects are not substituted for this UID"
                            statusLabel.textColor = .systemRed
                            disableEditingAfterDeletion()
                        } else {
                            let presentation = issue.userFacingPresentation
                            statusLabel.stringValue = presentation.inlineText
                            statusLabel.toolTip = presentation.detailedText
                            statusLabel.textColor = .systemOrange
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
        statusLabel.toolTip = nil
        guard updated.identity.uid == identity.uid, !isEditingYAML else {
            if isEditingYAML {
                statusLabel.stringValue = "Server object changed · local YAML edit preserved"
                statusLabel.textColor = .systemOrange
            }
            return
        }
        let presented = ObjectDetailWatchPresentation.merging(updated, previous: detail)
        detail = presented
        installYAML(presented.yamlUTF8)
        renderSummary(presented)
        renderMetrics(presented.metrics)
        statusLabel.stringValue = "Watching · resource version \(updated.resourceVersion)"
        statusLabel.textColor = .secondaryLabelColor
    }

    private func disableEditingAfterDeletion() {
        cancelDataFileOperation()
        editButton.isEnabled = false
        saveButton.isEnabled = false
        saveKeyButton.isEnabled = false
        for button in [addKeyButton, renameKeyButton, deleteKeyButton, revertKeyButton, importKeyButton] {
            button.isEnabled = false
        }
        dataValueTextView.isEditable = false
    }

    private func loadEventsIfNeeded() {
        guard !eventsLoaded, eventsTask == nil else { return }
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Loading events…"
        eventsTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer { eventsTask = nil }
            do {
                events = try await provider.getEvents(identity: identity, limit: 200)
                guard !Task.isCancelled else { return }
                eventsLoaded = true
                eventsTable.reloadData()
                statusLabel.stringValue = events.isEmpty
                    ? "No recent events" : "\(events.count) recent event\(events.count == 1 ? "" : "s")"
                statusLabel.textColor = .secondaryLabelColor
            } catch {
                guard !Task.isCancelled else { return }
                show(error: error)
            }
        }
    }

    private func loadRelationshipsIfNeeded() {
        guard !relationshipsLoaded, relationshipsTask == nil else { return }
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Loading relationships…"
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
                statusLabel.stringValue = relationships.isEmpty
                    ? "No relationships found in current caches"
                    : "\(relationships.count) relationship\(relationships.count == 1 ? "" : "s")"
                statusLabel.textColor = .secondaryLabelColor
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
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Starting relationship scan…"
        statusLabel.textColor = .secondaryLabelColor
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
                        statusLabel.stringValue = message.progress.potentiallyIncomplete
                            ? "Scan finished with \(message.progress.resourcesFailed) inaccessible resource type(s) · results potentially incomplete"
                            : "Scan complete · \(message.progress.objectsExamined.formatted()) objects examined"
                        statusLabel.textColor = message.progress.potentiallyIncomplete
                            ? .systemOrange : .secondaryLabelColor
                    } else {
                        let current = message.progress.currentResource.isEmpty
                            ? "discovering resources" : message.progress.currentResource
                        statusLabel.stringValue = "Scanning \(message.progress.resourcesScanned)/\(message.progress.resourcesTotal) · \(message.progress.objectsExamined.formatted()) objects · \(current)"
                        statusLabel.textColor = message.warning == nil
                            ? .secondaryLabelColor : .systemOrange
                    }
                }
            } catch {
                guard !Task.isCancelled else {
                    statusLabel.stringValue = "Relationship scan cancelled"
                    statusLabel.textColor = .secondaryLabelColor
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
        replaceYAMLText(with: yamlPresentation.completeYAML)
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
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Validating…"
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer {
                operationTask = nil
                updateYAMLEditControls()
                updateDataEditorControls()
            }
            do {
                let prepared = try await provider.prepareYAML(
                    identity: identity,
                    yamlUTF8: edited,
                    expectedResourceVersion: detail.resourceVersion,
                    forceFieldOwnership: false
                )
                guard confirm(diff: prepared.diff) else {
                    statusLabel.stringValue = "Save cancelled"
                    return
                }
                let stream = try await provider.applyYAML(
                    identity: identity,
                    yamlUTF8: prepared.normalizedYAMLUTF8,
                    expectedResourceVersion: detail.resourceVersion,
                    forceFieldOwnership: false
                )
                for try await progress in stream {
                    statusLabel.stringValue = "Saving… \(progress.completedItems)/\(progress.totalItems)"
                    if progress.state.isTerminal {
                        if progress.state == .succeeded {
                            originalYAML = prepared.normalizedYAMLUTF8
                            finishYAMLEdit()
                            loadTask?.cancel()
                            loadTask = nil
                            loadObject(
                                preservingDataDrafts: true,
                                lockingDataEditorUntilInstalled: true
                            )
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
        updateDataEditorControls()
    }

    private func confirm(diff: [SemanticDiffEntry]) -> Bool {
        guard !diff.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Apply \(diff.count) YAML change\(diff.count == 1 ? "" : "s")?"
        let changes = diff.prefix(12).map {
            "\($0.path): \($0.beforeSummary) → \($0.afterSummary)"
        }.joined(separator: "\n")
        alert.informativeText = confirmationInformativeText(
            note: "Changes:\n\(changes)"
        )
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
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
        yamlPresentation = YAMLManagedFieldsPresentation(
            unprocessedYAMLUTF8: yamlUTF8
        )
        managedFieldsButton.isHidden = true
        if !isEditingYAML { showYAMLPresentation() }

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
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditingYAML {
            cancelYAMLEdit()
        } else if leaveDataValueEditorIfActive() {
            return
        } else {
            onBack?()
        }
    }

    /// Escape follows the workspace priority order: while the value editor is
    /// active it first ends text entry and retains the in-memory key draft.
    /// A subsequent Escape from the key table may navigate back normally.
    private func leaveDataValueEditorIfActive() -> Bool {
        guard supportsDataEditor, segmented.selectedSegment == 5,
            let window = view.window,
            let responderView = window.firstResponder as? NSView,
            responderView === dataValueTextView
                || responderView.isDescendant(of: dataValueScroll)
        else { return false }
        window.makeFirstResponder(keysTable)
        return true
    }

    @objc func saveDocument(_ sender: Any?) {
        if isEditingYAML {
            saveYAML()
        } else if saveKeyButton.isEnabled {
            saveCurrentKey()
        }
    }

    private var dataEditorRows: [DataEditorKeyRow] {
        let entries = objectData?.entries ?? []
        let storedKeys = Set(entries.map(\.id))
        let missing = dataDrafts.keys
            .filter { !storedKeys.contains($0) }
            .sorted()
            .compactMap { key -> DataEditorKeyRow? in
                dataDrafts.metadata(for: key).map {
                    .missingDraft(key: key, metadata: $0)
                }
            }
        return entries.map(DataEditorKeyRow.stored) + missing
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case eventsTable: events.count
        case relationshipsTable: relationships.count
        default: dataEditorRows.count
        }
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === eventsTable {
            guard events.indices.contains(row), let tableColumn else { return nil }
            let event = events[row]
            let value: String
            switch tableColumn.identifier.rawValue {
            case "type": value = event.type
            case "reason": value = event.reason
            case "message": value = event.message
            case "last": value = event.lastObservedAt.map(Self.dateFormatter.string) ?? "—"
            case "count": value = event.count.formatted()
            default: value = ""
            }
            return textCell(value, table: tableView, column: tableColumn)
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
        let dataRows = dataEditorRows
        guard dataRows.indices.contains(row), let tableColumn else {
            return nil
        }
        let dataRow = dataRows[row]
        let presentation = dataRowPresentation(for: dataRow)
        let columnIdentifier = tableColumn.identifier.rawValue
        let valuePreview = columnIdentifier == "value"
            ? dataValuePreview(for: dataRow)
            : nil
        let value: String
        switch columnIdentifier {
        case "key": value = presentation.keyText
        case "value": value = valuePreview?.displayText ?? ""
        case "type": value = presentation.typeText
        case "size": value = presentation.sizeText
        case "state": value = presentation.state.displayText
        default: value = ""
        }
        let cell = textCell(value, table: tableView, column: tableColumn)
        cell.setAccessibilityLabel(tableColumn.title)
        cell.setAccessibilityValue(
            valuePreview?.accessibilityValue ?? presentation.accessibilityValue
        )
        switch presentation.state {
        case .saved:
            cell.textField?.textColor = .labelColor
        case .unsaved:
            cell.textField?.textColor = tableColumn.identifier.rawValue == "state"
                ? .systemOrange : .labelColor
        case .conflict:
            cell.textField?.textColor = tableColumn.identifier.rawValue == "state"
                ? .systemRed : .labelColor
        }
        return cell
    }

    /// Produces a short-lived preview from decoded bytes. Neither this helper
    /// nor `DataValuePreviewPresentation` retains the source value; draft and
    /// entry copies are wiped immediately after the presentation is built.
    private func dataValuePreview(
        for row: DataEditorKeyRow
    ) -> DataValuePreviewPresentation? {
        let secret = objectData?.secret ?? isSecretObject
        let hasRevealAuthority = secretRevealed && selectedDataKey == row.key
        if var draft = dataDrafts.snapshot(for: row.key) {
            defer { draft.wipe() }
            return DataValuePreviewPresentation(
                kind: draft.kind,
                value: draft.value,
                secret: secret,
                hasRevealAuthority: hasRevealAuthority
            )
        }
        if let entry = row.entry {
            var bytes = copyBytes(from: entry)
            defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
            return DataValuePreviewPresentation(
                kind: entry.kind,
                value: bytes,
                secret: secret,
                hasRevealAuthority: hasRevealAuthority
            )
        }
        return nil
    }

    private func dataRowPresentation(for row: DataEditorKeyRow) -> DataEditorRowPresentation {
        let selected = selectedDataKey == row.key
        switch row {
        case .stored(let entry):
            let draft = dataDrafts.metadata(for: entry.id)
            let changed = draft != nil
            let hasConflict = conflictedDataKey == entry.id
            return DataEditorRowPresentation(
                key: entry.id,
                storedKind: entry.kind,
                storedByteSize: entry.byteSize,
                isSelected: selected,
                draftKind: draft?.kind,
                draftByteSize: changed || hasConflict
                    ? draft.map { UInt64($0.byteCount) }
                    : nil,
                hasUnsavedChanges: changed,
                hasConflict: hasConflict
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === keysTable else { return }
        guard !isInstallingDataEditorState else { return }
        let previouslySelectedRow = dataEditorRows.firstIndex { $0.key == selectedDataKey }
        captureSelectedDataDraft()
        let rows = dataEditorRows
        guard let data = objectData, rows.indices.contains(keysTable.selectedRow) else {
            selectedDataKey = nil
            selectedDataEntry = nil
            selectedDataDraftKind = nil
            selectedDataCanEditText = false
            dataValueTextView.string = ""
            dataValueTextView.undoManager?.removeAllActions()
            updateDataEditorControls()
            reloadDataRows([previouslySelectedRow].compactMap { $0 })
            return
        }
        installSelectedDataRow(rows[keysTable.selectedRow], secret: data.secret)
        updateDataEditorControls()
        reloadDataRows([previouslySelectedRow, keysTable.selectedRow].compactMap { $0 })
    }

    private func installSelectedDataRow(_ row: DataEditorKeyRow, secret: Bool) {
        selectedDataKey = row.key
        selectedDataEntry = row.entry
        secretRevealed = !secret
        revealButton.isHidden = !secret
        revealButton.title = "Reveal"
        displaySelectedData()
    }

    @objc private func toggleSecretReveal() {
        if secretRevealed {
            captureSelectedDataDraft()
        }
        secretRevealed.toggle()
        revealButton.title = secretRevealed ? "Conceal" : "Reveal"
        displaySelectedData()
        updateDataEditorControls()
        reloadSelectedDataRow()
    }

    private func displaySelectedData() {
        guard let data = objectData, let key = selectedDataKey else { return }
        let entry = selectedDataEntry
        let draftMetadata = dataDrafts.metadata(for: key)
        guard entry != nil || draftMetadata != nil else { return }
        let wasInstallingDataEditorState = isInstallingDataEditorState
        isInstallingDataEditorState = true
        defer { isInstallingDataEditorState = wasInstallingDataEditorState }
        selectedDataDraftKind = draftMetadata?.kind ?? entry?.kind
        if data.secret && !secretRevealed {
            let byteCount = draftMetadata?.byteCount ?? Int(entry?.byteSize ?? 0)
            dataValueTextView.string = "Secret value concealed · \(byteCount) bytes"
            selectedDataCanEditText = false
            dataValueTextView.undoManager?.removeAllActions()
            saveKeyButton.isEnabled = false
            return
        }
        var draft = dataDrafts.snapshot(for: key)
        defer { draft?.wipe() }
        var bytes = draft?.value ?? entry.map { copyBytes(from: $0) } ?? Data()
        if let text = String(data: bytes, encoding: .utf8), !text.contains("\0") {
            dataValueTextView.string = text
            selectedDataCanEditText = true
        } else {
            let suffix = draft == nil ? "" : " · unsaved"
            dataValueTextView.string = "Binary value · \(bytes.count) bytes\(suffix)"
            selectedDataCanEditText = false
        }
        bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
        dataValueTextView.undoManager?.removeAllActions()
        updateDataEditorControls()
        if entry == nil {
            showMissingDataDraftStatus()
        }
    }

    private func showMissingDataDraftStatus() {
        statusLabel.stringValue = "Conflict · key missing on server · local draft preserved · Save Key recreates it"
        statusLabel.textColor = .systemOrange
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === dataValueTextView else { return }
        guard !isInstallingDataEditorState else { return }
        captureSelectedDataDraft()
        updateDataEditorControls()
        reloadSelectedDataRow()
    }

    private var currentDraftBytes: Data? {
        guard let data = objectData, let key = selectedDataKey else { return nil }
        guard !data.secret || secretRevealed else { return nil }
        if selectedDataCanEditText {
            return Data(dataValueTextView.string.utf8)
        }
        return dataDrafts.snapshot(for: key)?.value
            ?? selectedDataEntry.map { copyBytes(from: $0) }
    }

    private var hasDataDraftChanges: Bool {
        selectedDataKey.map(dataDrafts.contains) ?? false
    }

    private var hasAnyDataDraftChanges: Bool { !dataDrafts.isEmpty }

    private func updateDataEditorControls() {
        let hasSelection = selectedDataKey != nil && !terminalObjectState
        let hasStoredSelection = selectedDataEntry != nil && !terminalObjectState
        let idle = operationTask == nil && dataConflictController == nil
            && dataFileTask == nil && !authoritativeMutationRefreshInFlight
            && !dataAuthorityUnavailable
        addKeyButton.isEnabled = objectData != nil && !terminalObjectState && idle
        renameKeyButton.isEnabled = hasStoredSelection && idle && !hasDataDraftChanges
        deleteKeyButton.isEnabled = hasStoredSelection && idle && !hasDataDraftChanges
        let valueIsAccessible = !(objectData?.secret ?? false) || secretRevealed
        importKeyButton.isEnabled = hasSelection && idle && valueIsAccessible
        exportKeyButton.isEnabled = hasSelection && idle && valueIsAccessible
        revertKeyButton.isEnabled = hasSelection && idle && valueIsAccessible
            && hasDataDraftChanges
        saveKeyButton.isEnabled = hasSelection && idle && valueIsAccessible
            && hasDataDraftChanges
        dataValueTextView.isEditable = hasSelection && idle && valueIsAccessible
            && selectedDataCanEditText
    }

    private func reloadSelectedDataRow() {
        reloadDataRows([keysTable.selectedRow])
    }

    private func reloadDataRows(_ rows: [Int]) {
        let validRows = IndexSet(rows.filter { $0 >= 0 && $0 < keysTable.numberOfRows })
        guard !validRows.isEmpty else { return }
        keysTable.reloadData(
            forRowIndexes: validRows,
            columnIndexes: IndexSet(integersIn: 0..<keysTable.numberOfColumns)
        )
    }

    private func releaseDataDrafts() {
        let wasInstallingDataEditorState = isInstallingDataEditorState
        isInstallingDataEditorState = true
        defer { isInstallingDataEditorState = wasInstallingDataEditorState }
        dataDrafts.removeAll()
        selectedDataDraftKind = nil
        selectedDataCanEditText = false
        if objectData?.secret == true {
            dataValueTextView.string = ""
            dataValueTextView.undoManager?.removeAllActions()
        }
    }

    private func captureSelectedDataDraft() {
        guard let data = objectData, let key = selectedDataKey else { return }
        guard !data.secret || secretRevealed else { return }
        guard var value = currentDraftBytes else { return }
        if let entry = selectedDataEntry {
            dataDrafts.update(
                key: key,
                kind: selectedDataDraftKind ?? entry.kind,
                value: value,
                storedKind: entry.kind,
                valueMatchesStored: valueMatchesEntry(value, entry: entry),
                storedContentHash: entry.contentHash
            )
        } else {
            dataDrafts.replaceExisting(
                key: key,
                kind: selectedDataDraftKind ?? .binary,
                value: value
            )
        }
        value.resetBytes(in: value.startIndex..<value.endIndex)
    }

    private func copyBytes(from entry: ObjectDataEntry) -> Data {
        var result = Data()
        entry.value.withUnsafeBytes { result.append(contentsOf: $0) }
        return result
    }

    private func valueMatchesEntry(_ value: Data, entry: ObjectDataEntry) -> Bool {
        guard value.count == entry.value.count else { return false }
        return value.withUnsafeBytes { localBytes in
            entry.value.withUnsafeBytes { storedBytes in
                localBytes.elementsEqual(storedBytes)
            }
        }
    }

    @objc private func revertCurrentKey() {
        guard let key = selectedDataKey else { return }
        dataDrafts.remove(key)
        if let entry = selectedDataEntry {
            selectedDataDraftKind = entry.kind
            displaySelectedData()
            reloadSelectedDataRow()
        } else {
            selectedDataKey = nil
            selectedDataDraftKind = nil
            selectedDataCanEditText = false
            keysTable.reloadData()
            keysTable.deselectAll(nil)
            dataValueTextView.string = ""
            dataValueTextView.undoManager?.removeAllActions()
            updateDataEditorControls()
        }
        statusLabel.stringValue = "Local key changes reverted"
        statusLabel.textColor = .secondaryLabelColor
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
        let keys = Set(dataEditorRows.map(\.key))
        if let message = KubernetesDataKeyValidator.validationMessage(for: key, existingKeys: keys) {
            showValidation(message)
            return
        }
        if kindButton.indexOfSelectedItem == 1 {
            chooseImportedFile { [weak self] url in
                self?.readImportedBytes(from: url) { [weak self] bytes in
                    self?.performDataMutation(.set(
                        key: key, kind: .binary, value: bytes, expectedContentHash: Data()
                    ), successMessage: "Added \(key)")
                }
            }
        } else {
            performDataMutation(.set(
                key: key, kind: .text, value: Data(), expectedContentHash: Data()
            ), successMessage: "Added \(key)")
        }
    }

    @objc private func renameDataKey() {
        guard objectData != nil, let entry = selectedDataEntry,
            !hasDataDraftChanges
        else { return }
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
        let keys = Set(dataEditorRows.map(\.key))
        if let message = KubernetesDataKeyValidator.validationMessage(
            for: newKey, existingKeys: keys, allowingExistingKey: entry.id
        ) {
            showValidation(message)
            return
        }
        guard newKey != entry.id else { return }
        performDataMutation(.rename(
            key: entry.id, newKey: newKey, expectedContentHash: entry.contentHash
        ), successMessage: "Renamed \(entry.id) to \(newKey)")
    }

    @objc private func deleteDataKey() {
        guard let entry = selectedDataEntry, !hasDataDraftChanges else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete key \(entry.id)?"
        alert.informativeText = confirmationInformativeText(
            note: "The delete uses the loaded content hash and will fail if this key changed on the server."
        )
        alert.addButton(withTitle: "Delete Key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDataMutation(.delete(
            key: entry.id, expectedContentHash: entry.contentHash
        ), successMessage: "Deleted \(entry.id)")
    }

    @objc private func importCurrentKey() {
        guard let key = selectedDataKey else { return }
        chooseImportedFile { [weak self] url in
            self?.importDataFile(from: url, forKey: key)
        }
    }

    func replaceSelectedDataWithImportedBytes(_ bytes: Data) {
        guard let key = selectedDataKey else { return }
        replaceDataWithImportedBytes(bytes, forKey: key)
    }

    private func replaceDataWithImportedBytes(_ bytes: Data, forKey key: String) {
        let entry = objectData?.entries.first { $0.id == key }
        let replacementKind: DataValueKind
        if objectData?.secret == true {
            // Secret values all belong to `.data`; their text/binary kind is a
            // presentation hint, so a file import continues to be raw bytes.
            replacementKind = .binary
        } else {
            // Replacing a ConfigMap value must not silently move its key between
            // `.data` and `.binaryData`. Prefer an existing draft's explicit
            // kind, then the kind loaded from the server.
            replacementKind = dataDrafts.metadata(for: key)?.kind
                ?? entry?.kind
                ?? .binary
        }
        if let entry {
            dataDrafts.update(
                key: key,
                kind: replacementKind,
                value: bytes,
                storedKind: entry.kind,
                valueMatchesStored: valueMatchesEntry(bytes, entry: entry),
                storedContentHash: entry.contentHash
            )
        } else {
            dataDrafts.replaceExisting(key: key, kind: replacementKind, value: bytes)
        }
        if selectedDataKey == key {
            selectedDataDraftKind = replacementKind
            selectedDataEntry = entry
            displaySelectedData()
        }
        if let row = dataEditorRows.firstIndex(where: { $0.key == key }) {
            reloadDataRows([row])
        }
        statusLabel.stringValue = dataDrafts.contains(key)
            ? "Loaded \(bytes.count.formatted()) bytes locally for \(key)"
            : "Selected file matches the saved value for \(key)"
        statusLabel.textColor = .secondaryLabelColor
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

    /// Testable seam used after NSOpenPanel has supplied a URL. The key is
    /// captured before asynchronous I/O so a selection change cannot redirect
    /// imported bytes into a different ConfigMap or Secret entry.
    func importDataFile(from url: URL, forKey key: String) {
        guard dataEditorRows.contains(where: { $0.key == key }) else { return }
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
        guard let key = selectedDataKey, let window = view.window,
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

    /// Testable seam used after NSSavePanel has supplied its destination.
    func exportDataFile(_ bytes: Data, key: String, to url: URL) {
        let writer = dataFileWriter
        startDataFileOperation(status: "Exporting \(url.lastPathComponent)…") {
            var protectedBytes = bytes
            defer {
                protectedBytes.resetBytes(
                    in: protectedBytes.startIndex..<protectedBytes.endIndex
                )
            }
            try writer(protectedBytes, url)
        } completion: { [weak self] _ in
            self?.statusLabel.stringValue = "Exported \(key)"
            self?.statusLabel.textColor = .secondaryLabelColor
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
        statusLabel.stringValue = status
        statusLabel.textColor = .secondaryLabelColor
        dataFileTask = Task { [weak self] in
            do {
                // This nonisolated async call moves the same stored Task onto
                // the generic executor. Cancellation reaches the task doing
                // POSIX I/O instead of only an awaiting shell.
                let value = try await Self.performDataFileOperation(operation)
                guard let self, !Task.isCancelled,
                    dataFileGeneration == generation
                else { return }
                dataFileTask = nil
                completion(value)
                updateDataEditorControls()
            } catch {
                guard let self, !Task.isCancelled,
                    dataFileGeneration == generation
                else { return }
                dataFileTask = nil
                show(error: error)
                updateDataEditorControls()
            }
        }
        updateDataEditorControls()
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
        captureSelectedDataDraft()
        guard let key = selectedDataKey,
            var draft = dataDrafts.snapshot(for: key)
        else { return }
        defer { draft.wipe() }
        performDataMutation(.set(
            key: key,
            kind: draft.kind,
            value: draft.value,
            expectedContentHash: selectedDataEntry == nil
                ? Data()
                : draft.expectedContentHash
        ), successMessage: "Saved \(key)")
    }

    private func performDataMutation(_ mutation: DataMutationKind, successMessage: String) {
        guard let data = objectData, operationTask == nil else { return }
        submitDataMutation(
            mutation,
            expectedResourceVersion: data.resourceVersion,
            successMessage: successMessage,
            recoverConflicts: true
        )
    }

    private func submitDataMutation(
        _ mutation: DataMutationKind,
        expectedResourceVersion: String,
        successMessage: String,
        recoverConflicts: Bool
    ) {
        guard operationTask == nil else { return }
        if conflictedDataKey != mutation.sourceKey {
            conflictedDataKey = nil
            reloadSelectedDataRow()
        }
        updateDataEditorControls()
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Saving key/value data…"
        statusLabel.textColor = .secondaryLabelColor
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            defer {
                operationTask = nil
                updateDataEditorControls()
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
                    statusLabel.stringValue = successMessage
                    statusLabel.textColor = .secondaryLabelColor
                    dataDrafts.remove(mutation.sourceKey)
                    loadTask?.cancel()
                    loadTask = nil
                    loadObject(
                        preservingDataDrafts: true,
                        lockingDataEditorUntilInstalled: true
                    )
                }
            } catch {
                if recoverConflicts, Self.clusterIssue(from: error)?.category == .conflict {
                    await prepareDataConflictRecovery(
                        mutation: mutation,
                        successMessage: successMessage
                    )
                } else {
                    show(error: error)
                }
            }
        }
        updateDataEditorControls()
    }

    private func prepareDataConflictRecovery(
        mutation: DataMutationKind,
        successMessage: String
    ) async {
        statusLabel.stringValue = "Conflict detected · loading the current key…"
        statusLabel.textColor = .systemOrange
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
            conflictedDataKey = mutation.sourceKey
            reloadSelectedDataRow()
            let destinationExists = mutation.destinationKey.map { destination in
                currentData.entries.contains { $0.id == destination }
            } ?? false
            let retryPlan = mutation.conflictRetryPlan(
                currentContentHash: currentEntry?.contentHash,
                destinationExists: destinationExists
            )
            presentDataConflict(
                mutation: mutation,
                successMessage: successMessage,
                currentData: currentData,
                currentEntry: currentEntry,
                retryPlan: retryPlan
            )
        } catch {
            conflictedDataKey = mutation.sourceKey
            reloadSelectedDataRow()
            statusLabel.stringValue = "Conflict · current server data could not be loaded · local edit preserved"
            statusLabel.textColor = .systemRed
        }
    }

    private func presentDataConflict(
        mutation: DataMutationKind,
        successMessage: String,
        currentData: ObjectData,
        currentEntry: ObjectDataEntry?,
        retryPlan: DataConflictRetryPlan
    ) {
        guard let window = view.window else {
            statusLabel.stringValue = "Conflict · local edit preserved"
            statusLabel.textColor = .systemOrange
            return
        }
        let localDisplay = localConflictDisplay(for: mutation, secret: currentData.secret)
        let currentDisplay = currentEntry.map {
            conflictDisplay(entry: $0, secret: currentData.secret)
        } ?? .missing()
        let retryUnavailableReason: String?
        if case .unavailable(let reason) = retryPlan {
            retryUnavailableReason = reason
        } else {
            retryUnavailableReason = nil
        }
        let canCopyLocal: Bool
        switch mutation {
        case .set:
            canCopyLocal = !currentData.secret
                || (selectedDataKey == mutation.sourceKey && secretRevealed)
        case .delete, .rename:
            canCopyLocal = false
        }
        let controller = DataConflictWindowController(
            session: session,
            identity: identity,
            key: mutation.sourceKey,
            resourceVersion: currentData.resourceVersion,
            local: localDisplay,
            current: currentDisplay,
            canCopyLocal: canCopyLocal,
            retryUnavailableReason: retryUnavailableReason
        ) { [weak self] choice in
            guard let self else { return }
            dataConflictController = nil
            defer { updateDataEditorControls() }
            switch choice {
            case .reload:
                conflictedDataKey = nil
                installCurrentDataAfterConflict(currentData, selecting: mutation.sourceKey)
                statusLabel.stringValue = "Reloaded current server data"
                statusLabel.textColor = .secondaryLabelColor
            case .copyLocal:
                copyLocalConflictValueToPasteboard(mutation: mutation)
                statusLabel.stringValue = "Copied local value · local edit preserved"
                statusLabel.textColor = .secondaryLabelColor
            case .retry:
                guard case .retry(let retryMutation) = retryPlan else { return }
                conflictedDataKey = nil
                submitDataMutation(
                    retryMutation,
                    expectedResourceVersion: currentData.resourceVersion,
                    successMessage: successMessage,
                    recoverConflicts: true
                )
            case .keepEditing:
                statusLabel.stringValue = "Conflict · local edit preserved"
                statusLabel.textColor = .systemOrange
            }
        }
        dataConflictController = controller
        updateDataEditorControls()
        controller.beginSheet(for: window)
    }

    private func localConflictDisplay(
        for mutation: DataMutationKind,
        secret: Bool
    ) -> DataConflictValueDisplay {
        switch mutation {
        case .set(_, let kind, let value, _):
            return DataConflictValueDisplay(
                secret: secret,
                kind: kind,
                byteCount: value.count,
                contentHash: DataConflictValueDisplay.contentHash(of: value),
                decodedText: secret ? nil : safeUTF8(value)
            )
        case .delete:
            return .missing("Local action deletes this key.")
        case .rename(_, let newKey, _):
            return .missing("Local action renames this key to \(newKey).")
        }
    }

    private func conflictDisplay(
        entry: ObjectDataEntry,
        secret: Bool
    ) -> DataConflictValueDisplay {
        var bytes = copyBytes(from: entry)
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        return DataConflictValueDisplay(
            secret: secret,
            kind: entry.kind,
            byteCount: bytes.count,
            contentHash: entry.contentHash,
            decodedText: secret ? nil : safeUTF8(bytes)
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
        dataDrafts.remove(key)
        conflictedDataKey = nil
        let wasInstallingDataEditorState = isInstallingDataEditorState
        isInstallingDataEditorState = true
        defer { isInstallingDataEditorState = wasInstallingDataEditorState }
        objectData = currentData
        dataAuthorityUnavailable = false
        secretRevealed = !currentData.secret
        revealButton.title = "Reveal"
        keysTable.reloadData()
        guard let row = currentData.entries.firstIndex(where: { $0.id == key }) else {
            selectedDataKey = nil
            selectedDataEntry = nil
            selectedDataCanEditText = false
            keysTable.deselectAll(nil)
            dataValueTextView.string = ""
            updateDataEditorControls()
            return
        }
        keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectedDataKey = currentData.entries[row].id
        selectedDataEntry = currentData.entries[row]
        displaySelectedData()
        updateDataEditorControls()
    }

    private static func clusterIssue(from error: Error) -> ClusterManagerIssue? {
        if let issue = error as? ClusterManagerIssue { return issue }
        return nil
    }

    private func showValidation(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        NSSound.beep()
    }

    private func show(error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.inlineText
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
    }

    @objc private func backPressed() { onBack?() }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}
