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

/// A fresh, UID-authoritative detail surface. It replaces the table area in a
/// workspace; no inspector or bottom drawer is introduced.
@MainActor
final class ObjectDetailViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextViewDelegate
{
    private(set) var identity: ResourceIdentity
    private let provider: any ObjectDetailProviding
    private let initialTab: ObjectDetailInitialTab
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
    private let yamlTextView = NSTextView()
    private let yamlScrollView = NSScrollView()
    private let yamlContainerView = NSView()
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
    private var selectedDataEntry: ObjectDataEntry?
    private var originalYAML = Data()
    private var yamlPresentation = YAMLManagedFieldsPresentation(yamlUTF8: Data())
    private var yamlLineNumberRuler: LineNumberRulerView?
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var relationshipsTask: Task<Void, Never>?
    private var relationshipScanTask: Task<Void, Never>?
    private var activeRelationshipScan: (id: String, generation: UInt64)?
    private var operationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var dataConflictController: DataConflictWindowController?
    private var conflictedDataKey: String?
    private var secretRevealed = false
    private var selectedDataOriginalBytes: Data?
    private var selectedDataBinaryDraft: Data?
    private var selectedDataDraftKind: DataValueKind?
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
        initialTab: ObjectDetailInitialTab = .automatic
    ) {
        self.identity = identity
        self.provider = provider
        self.initialTab = initialTab
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
        loadObject()
    }

    func stop() {
        loadTask?.cancel()
        watchTask?.cancel()
        eventsTask?.cancel()
        relationshipsTask?.cancel()
        relationshipScanTask?.cancel()
        operationTask?.cancel()
        recoveryTask?.cancel()
        recoveryTask = nil
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
        dataConflictController?.close()
        dataConflictController = nil
        activeRelationshipScan = nil
        statusLabel.stringValue = isEditingYAML || hasDataDraftChanges
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
        sessionID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard recoveryTask == nil else { return }
        var reboundIdentity = identity
        reboundIdentity.clusterSessionID = sessionID
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
                    async let fetchedData = provider.getData(identity: dataIdentity)
                    let (updatedDetail, updatedData) = try await (fetchedDetail, fetchedData)
                    guard !Task.isCancelled else { return }
                    try installRecovery(detail: updatedDetail, data: updatedData)
                } else {
                    let updatedDetail = try await provider.getObject(identity: reboundIdentity)
                    guard !Task.isCancelled else { return }
                    try installRecovery(detail: updatedDetail, data: nil)
                }
                completion(.success(()))
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                completion(.failure(error))
            }
        }
    }

    private var breadcrumbText: String {
        let scope = identity.namespace.isEmpty ? "" : " · \(identity.namespace)"
        return "\(identity.resource)\(scope) · \(identity.name)"
    }

    private var supportsDataEditor: Bool {
        identity.group.isEmpty && identity.version == "v1"
            && (identity.resource == "configmaps" || identity.resource == "secrets")
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
        summaryScrollView.documentView = summaryStack
        summaryScrollView.hasVerticalScroller = true
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
        metricsScrollView.documentView = metricsStack
        metricsScrollView.hasVerticalScroller = true
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
        yamlScrollView.documentView = yamlTextView
        yamlScrollView.hasVerticalScroller = true
        yamlScrollView.hasHorizontalScroller = true
        yamlScrollView.identifier = .init("object-detail-yaml-scroll")
        let lineNumberRuler = LineNumberRulerView(
            textView: yamlTextView,
            scrollView: yamlScrollView
        )
        yamlLineNumberRuler = lineNumberRuler
        yamlScrollView.verticalRulerView = lineNumberRuler
        yamlScrollView.hasVerticalRuler = true
        yamlScrollView.rulersVisible = true

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
        yamlScrollView.translatesAutoresizingMaskIntoConstraints = false
        yamlContainerView.addSubview(controls)
        yamlContainerView.addSubview(yamlScrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: yamlContainerView.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: yamlContainerView.trailingAnchor, constant: -10),
            controls.topAnchor.constraint(equalTo: yamlContainerView.topAnchor, constant: 6),
            yamlScrollView.leadingAnchor.constraint(equalTo: yamlContainerView.leadingAnchor),
            yamlScrollView.trailingAnchor.constraint(equalTo: yamlContainerView.trailingAnchor),
            yamlScrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5),
            yamlScrollView.bottomAnchor.constraint(equalTo: yamlContainerView.bottomAnchor),
        ])
    }

    private func configureDataEditor() {
        dataSplitView.isVertical = true
        dataSplitView.dividerStyle = .thin
        dataSplitView.identifier = .init("object-detail-data-split")
        let columns: [(String, String, CGFloat, CGFloat)] = [
            ("key", "Key", 175, 100),
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
        keyScroll.frame = NSRect(x: 0, y: 0, width: 430, height: 500)

        dataValueTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        dataValueTextView.isRichText = false
        dataValueTextView.isEditable = false
        dataValueTextView.isSelectable = true
        dataValueTextView.allowsUndo = true
        dataValueTextView.delegate = self
        dataValueScroll.documentView = dataValueTextView
        dataValueScroll.hasVerticalScroller = true
        dataValueScroll.setAccessibilityLabel("Selected data value editor")
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
        dataSplitView.setPosition(430, ofDividerAt: 0)
    }

    private func loadObject() {
        guard loadTask == nil else { return }
        statusLabel.stringValue = "Loading…"
        statusLabel.textColor = .secondaryLabelColor
        loadTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            do {
                async let fetchedDetail = provider.getObject(identity: identity)
                if supportsDataEditor {
                    async let fetchedData = provider.getData(identity: identity)
                    let (detail, data) = try await (fetchedDetail, fetchedData)
                    install(detail: detail, data: data)
                } else {
                    install(detail: try await fetchedDetail, data: nil)
                }
            } catch {
                show(error: error)
            }
            loadTask = nil
        }
    }

    private func install(detail: ObjectDetail, data: ObjectData?) {
        releaseDataDrafts()
        identity = detail.identity
        self.detail = detail
        objectData = data
        conflictedDataKey = nil
        installYAML(detail.yamlUTF8)
        renderSummary(detail.summaryFields)
        keysTable.reloadData()
        updateDataEditorControls()
        renderMetrics(detail.metrics)
        statusLabel.stringValue = "Resource version \(detail.resourceVersion)"
        statusLabel.textColor = .secondaryLabelColor
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
        let preserveData = hasDataDraftChanges
        let selectedRow = keysTable.selectedRow

        identity = updatedDetail.identity
        terminalObjectState = false
        editButton.isEnabled = true
        saveButton.isEnabled = isEditingYAML
        originalYAML = updatedDetail.yamlUTF8
        yamlPresentation = YAMLManagedFieldsPresentation(yamlUTF8: updatedDetail.yamlUTF8)
        managedFieldsButton.isHidden = !yamlPresentation.hasManagedFields
        if preserveYAML, var editingBasis = detail {
            editingBasis.identity = updatedDetail.identity
            detail = editingBasis
        } else {
            detail = updatedDetail
            showYAMLPresentation()
        }
        renderSummary(updatedDetail.summaryFields)
        renderMetrics(updatedDetail.metrics)

        if let updatedData {
            if preserveData {
                if var editingBasis = objectData {
                    editingBasis.identity = updatedData.identity
                    objectData = editingBasis
                }
                dataValueTextView.isEditable = (!updatedData.secret || secretRevealed)
                    && selectedDataBinaryDraft == nil
            } else {
                releaseDataDrafts()
                objectData = updatedData
                keysTable.reloadData()
                let row = updatedData.entries.indices.contains(selectedRow) ? selectedRow : -1
                if row >= 0 {
                    keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    selectedDataEntry = updatedData.entries[row]
                    secretRevealed = !updatedData.secret
                    displaySelectedData()
                } else {
                    selectedDataEntry = nil
                    dataValueTextView.string = ""
                }
            }
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

    private func renderSummary(_ fields: [ObjectSummaryField]) {
        clear(summaryStack)
        var lastSection = ""
        for field in fields {
            if field.sectionID != lastSection {
                let heading = NSTextField(labelWithString: field.sectionID.capitalized)
                heading.font = .systemFont(ofSize: 13, weight: .semibold)
                summaryStack.addArrangedSubview(heading)
                lastSection = field.sectionID
            }
            let label = NSTextField(labelWithString: "\(field.label):  \(field.displayText)")
            label.toolTip = field.tooltip
            label.textColor = field.severity == .critical ? .systemRed : .labelColor
            summaryStack.addArrangedSubview(label)
        }
        if fields.isEmpty {
            let label = NSTextField(labelWithString: "No summary fields are available.")
            label.textColor = .secondaryLabelColor
            summaryStack.addArrangedSubview(label)
        }
    }

    private func renderMetrics(_ metrics: [ResourceUsageValue]) {
        clear(metricsStack)
        guard !metrics.isEmpty else {
            let label = NSTextField(labelWithString: "Metrics unavailable or not yet reported.")
            label.textColor = .secondaryLabelColor
            metricsStack.addArrangedSubview(label)
            return
        }
        for value in metrics {
            let title = value.resourceName.isEmpty ? "Resource" : value.resourceName
            let used = value.usage.map { metricNumber($0, unit: value.unit) } ?? "Unavailable"
            let requested = value.request.map { metricNumber($0, unit: value.unit) } ?? "—"
            let limit = value.limit.map { metricNumber($0, unit: value.unit) } ?? "—"
            let label = NSTextField(
                labelWithString: "\(title):  \(used) used · \(requested) requested · \(limit) limit"
            )
            if let measured = value.measuredAtUnixMilliseconds {
                label.toolTip = "Measured \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(measured) / 1_000))) · \(value.provider)"
            }
            metricsStack.addArrangedSubview(label)
        }
    }

    private func clear(_ stack: NSStackView) {
        stack.arrangedSubviews.forEach { child in
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }

    private func metricNumber(_ value: Double, unit: String) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + (unit.isEmpty ? "" : " \(unit)")
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
                            statusLabel.stringValue = "Watching · resource version \(currentVersion)"
                            statusLabel.textColor = .secondaryLabelColor
                        }
                    case .updated(_, let updated):
                        installWatchUpdate(updated)
                    case .deleted(_, _):
                        terminalObjectState = true
                        statusLabel.stringValue = "Deleted · this UID no longer exists"
                        statusLabel.textColor = .systemRed
                        disableEditingAfterDeletion()
                    case .failure(_, let issue):
                        if issue.reason == "ObjectRecreated" || issue.reason == "NotFound" {
                            terminalObjectState = true
                            statusLabel.stringValue = "Unavailable · same-name objects are not substituted for this UID"
                            statusLabel.textColor = .systemRed
                            disableEditingAfterDeletion()
                        } else {
                            statusLabel.stringValue = issue.message
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
        guard updated.identity.uid == identity.uid, !isEditingYAML else {
            if isEditingYAML {
                statusLabel.stringValue = "Server object changed · local YAML edit preserved"
                statusLabel.textColor = .systemOrange
            }
            return
        }
        detail = updated
        installYAML(updated.yamlUTF8)
        renderSummary(updated.summaryFields)
        renderMetrics(updated.metrics)
        statusLabel.stringValue = "Watching · resource version \(updated.resourceVersion)"
        statusLabel.textColor = .secondaryLabelColor
    }

    private func disableEditingAfterDeletion() {
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
    }

    @objc private func beginYAMLEdit() {
        // Editing always starts from the complete authoritative YAML even when
        // managedFields were hidden in the read-only presentation. The backend
        // protects them from apply along with the other server-owned fields.
        yamlTextView.string = yamlPresentation.completeYAML
        isEditingYAML = true
        yamlTextView.isEditable = true
        editButton.isHidden = true
        managedFieldsButton.isHidden = true
        saveButton.isHidden = false
        cancelButton.isHidden = false
        view.window?.makeFirstResponder(yamlTextView)
    }

    @objc private func cancelYAMLEdit() {
        finishYAMLEdit()
    }

    @objc private func saveYAML() {
        guard let detail else { return }
        let edited = Data(yamlTextView.string.utf8)
        operationTask?.cancel()
        statusLabel.stringValue = "Validating…"
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
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
    }

    private func confirm(diff: [SemanticDiffEntry]) -> Bool {
        guard !diff.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Apply \(diff.count) YAML change\(diff.count == 1 ? "" : "s")?"
        alert.informativeText = diff.prefix(12).map {
            "\($0.path): \($0.beforeSummary) → \($0.afterSummary)"
        }.joined(separator: "\n")
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func finishYAMLEdit() {
        isEditingYAML = false
        yamlTextView.isEditable = false
        editButton.isHidden = false
        managedFieldsButton.isHidden = !yamlPresentation.hasManagedFields
        saveButton.isHidden = true
        cancelButton.isHidden = true
        showYAMLPresentation()
    }

    @objc private func toggleManagedFields() {
        guard !isEditingYAML else { return }
        showYAMLPresentation()
    }

    private func installYAML(_ yamlUTF8: Data) {
        originalYAML = yamlUTF8
        yamlPresentation = YAMLManagedFieldsPresentation(yamlUTF8: yamlUTF8)
        if !yamlPresentation.hasManagedFields { managedFieldsButton.state = .off }
        managedFieldsButton.isHidden = !yamlPresentation.hasManagedFields || isEditingYAML
        if !isEditingYAML { showYAMLPresentation() }
    }

    private func showYAMLPresentation() {
        yamlTextView.string = yamlPresentation.text(
            showingManagedFields: managedFieldsButton.state == .on
        )
        yamlLineNumberRuler?.textDidChange()
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditingYAML {
            cancelYAMLEdit()
        } else {
            onBack?()
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if isEditingYAML {
            saveYAML()
        } else if saveKeyButton.isEnabled {
            saveCurrentKey()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case eventsTable: events.count
        case relationshipsTable: relationships.count
        default: objectData?.entries.count ?? 0
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
        guard let entries = objectData?.entries, entries.indices.contains(row), let tableColumn else {
            return nil
        }
        let presentation = dataRowPresentation(for: entries[row])
        let value: String
        switch tableColumn.identifier.rawValue {
        case "key": value = presentation.keyText
        case "type": value = presentation.typeText
        case "size": value = presentation.sizeText
        case "state": value = presentation.state.displayText
        default: value = ""
        }
        let cell = textCell(value, table: tableView, column: tableColumn)
        cell.setAccessibilityLabel(tableColumn.title)
        cell.setAccessibilityValue(presentation.accessibilityValue)
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

    private func dataRowPresentation(for entry: ObjectDataEntry) -> DataEditorRowPresentation {
        let selected = selectedDataEntry?.id == entry.id
        let draft = selected ? currentDraftBytes : nil
        let changed = selected && hasDataDraftChanges
        let hasConflict = conflictedDataKey == entry.id
        return DataEditorRowPresentation(
            key: entry.id,
            storedKind: entry.kind,
            storedByteSize: entry.byteSize,
            isSelected: selected,
            draftKind: changed || hasConflict ? selectedDataDraftKind : nil,
            draftByteSize: changed || hasConflict
                ? draft.map { UInt64($0.count) }
                : nil,
            hasUnsavedChanges: changed,
            hasConflict: hasConflict
        )
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
        let previouslySelectedKey = selectedDataEntry?.id
        let previouslySelectedRow = objectData?.entries.firstIndex {
            $0.id == previouslySelectedKey
        }
        releaseDataDrafts()
        reloadDataRows([previouslySelectedRow, keysTable.selectedRow].compactMap { $0 })
        guard let data = objectData, data.entries.indices.contains(keysTable.selectedRow) else {
            selectedDataEntry = nil
            dataValueTextView.string = ""
            updateDataEditorControls()
            return
        }
        selectedDataEntry = data.entries[keysTable.selectedRow]
        secretRevealed = !data.secret
        revealButton.isHidden = !data.secret
        revealButton.title = "Reveal"
        displaySelectedData()
        updateDataEditorControls()
        reloadSelectedDataRow()
    }

    @objc private func toggleSecretReveal() {
        secretRevealed.toggle()
        revealButton.title = secretRevealed ? "Conceal" : "Reveal"
        if !secretRevealed { releaseDataDrafts() }
        displaySelectedData()
        updateDataEditorControls()
        reloadSelectedDataRow()
    }

    private func displaySelectedData() {
        guard let data = objectData, let entry = selectedDataEntry else { return }
        if data.secret && !secretRevealed {
            dataValueTextView.string = "Secret value concealed · \(entry.byteSize) bytes"
            dataValueTextView.isEditable = false
            saveKeyButton.isEnabled = false
            return
        }
        var bytes = copyBytes(from: entry)
        selectedDataOriginalBytes = bytes
        selectedDataDraftKind = entry.kind
        if let text = String(data: bytes, encoding: .utf8), !text.contains("\0") {
            dataValueTextView.string = text
            dataValueTextView.isEditable = true
            selectedDataBinaryDraft = nil
        } else {
            dataValueTextView.string = "Binary value · \(entry.byteSize) bytes"
            dataValueTextView.isEditable = false
            selectedDataBinaryDraft = bytes
        }
        bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
        updateDataEditorControls()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === dataValueTextView else { return }
        updateDataEditorControls()
        reloadSelectedDataRow()
    }

    private var currentDraftBytes: Data? {
        guard selectedDataEntry != nil else { return nil }
        if selectedDataDraftKind == .binary, !dataValueTextView.isEditable {
            return selectedDataBinaryDraft
        }
        return Data(dataValueTextView.string.utf8)
    }

    private var hasDataDraftChanges: Bool {
        guard let draft = currentDraftBytes, let original = selectedDataOriginalBytes else { return false }
        return draft != original
    }

    private func updateDataEditorControls() {
        let hasSelection = selectedDataEntry != nil && !terminalObjectState
        let idle = operationTask == nil
        addKeyButton.isEnabled = objectData != nil && !terminalObjectState && idle
        renameKeyButton.isEnabled = hasSelection && idle
        deleteKeyButton.isEnabled = hasSelection && idle
        importKeyButton.isEnabled = hasSelection && idle && (!((objectData?.secret ?? false)) || secretRevealed)
        exportKeyButton.isEnabled = hasSelection && idle && (!((objectData?.secret ?? false)) || secretRevealed)
        revertKeyButton.isEnabled = hasSelection && idle && hasDataDraftChanges
        saveKeyButton.isEnabled = hasSelection && idle && hasDataDraftChanges
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
        if var value = selectedDataOriginalBytes {
            value.resetBytes(in: value.startIndex..<value.endIndex)
        }
        if var value = selectedDataBinaryDraft {
            value.resetBytes(in: value.startIndex..<value.endIndex)
        }
        selectedDataOriginalBytes = nil
        selectedDataBinaryDraft = nil
        selectedDataDraftKind = nil
        if objectData?.secret == true {
            dataValueTextView.string = ""
            dataValueTextView.undoManager?.removeAllActions()
        }
    }

    private func copyBytes(from entry: ObjectDataEntry) -> Data {
        var result = Data()
        entry.value.withUnsafeBytes { result.append(contentsOf: $0) }
        return result
    }

    @objc private func revertCurrentKey() {
        releaseDataDrafts()
        displaySelectedData()
        reloadSelectedDataRow()
        statusLabel.stringValue = "Local key changes reverted"
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func addDataKey() {
        guard let data = objectData else { return }
        let alert = NSAlert()
        alert.messageText = "Add Key"
        alert.informativeText = "The new key is created only if it still does not exist on the server."
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
        let keys = Set(data.entries.map(\.id))
        if let message = KubernetesDataKeyValidator.validationMessage(for: key, existingKeys: keys) {
            showValidation(message)
            return
        }
        if kindButton.indexOfSelectedItem == 1 {
            chooseImportedBytes { [weak self] bytes in
                self?.performDataMutation(.set(
                    key: key, kind: .binary, value: bytes, expectedContentHash: Data()
                ), successMessage: "Added \(key)")
            }
        } else {
            performDataMutation(.set(
                key: key, kind: .text, value: Data(), expectedContentHash: Data()
            ), successMessage: "Added \(key)")
        }
    }

    @objc private func renameDataKey() {
        guard let data = objectData, let entry = selectedDataEntry else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Key"
        alert.informativeText = "Rename \(entry.id) without changing its value or text/binary kind."
        let field = NSTextField(string: entry.id)
        field.frame.size = NSSize(width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newKey = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Set(data.entries.map(\.id))
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
        guard let entry = selectedDataEntry else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete key \(entry.id)?"
        alert.informativeText = "The delete uses the loaded content hash and will fail if this key changed on the server."
        alert.addButton(withTitle: "Delete Key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDataMutation(.delete(
            key: entry.id, expectedContentHash: entry.contentHash
        ), successMessage: "Deleted \(entry.id)")
    }

    @objc private func importCurrentKey() {
        guard let entry = selectedDataEntry else { return }
        chooseImportedBytes { [weak self] bytes in
            guard let self else { return }
            selectedDataDraftKind = .binary
            if let text = String(data: bytes, encoding: .utf8), !text.contains("\0") {
                selectedDataBinaryDraft = nil
                dataValueTextView.string = text
                dataValueTextView.isEditable = true
            } else {
                selectedDataBinaryDraft = bytes
                dataValueTextView.string = "Binary value · \(bytes.count) bytes · unsaved"
                dataValueTextView.isEditable = false
            }
            updateDataEditorControls()
            reloadSelectedDataRow()
            statusLabel.stringValue = "Loaded \(bytes.count.formatted()) bytes locally for \(entry.id)"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func chooseImportedBytes(_ completion: @escaping (Data) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                completion(try Data(contentsOf: url, options: .mappedIfSafe))
            } catch {
                self.show(error: error)
            }
        }
    }

    @objc private func exportCurrentKey() {
        guard let entry = selectedDataEntry, let window = view.window else { return }
        var bytes = currentDraftBytes ?? copyBytes(from: entry)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.id
        panel.beginSheetModal(for: window) { [weak self] response in
            defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
            guard response == .OK, let url = panel.url else { return }
            do {
                try bytes.write(to: url, options: .atomic)
                self?.statusLabel.stringValue = "Exported \(entry.id)"
                self?.statusLabel.textColor = .secondaryLabelColor
            } catch {
                self?.show(error: error)
            }
        }
    }

    @objc private func saveCurrentKey() {
        guard let entry = selectedDataEntry, let localValue = currentDraftBytes else { return }
        performDataMutation(.set(
            key: entry.id,
            kind: selectedDataDraftKind ?? entry.kind,
            value: localValue,
            expectedContentHash: entry.contentHash
        ), successMessage: "Saved \(entry.id)")
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
                    loadTask?.cancel()
                    loadTask = nil
                    loadObject()
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
            canCopyLocal = currentDraftBytes != nil
                && (!currentData.secret || secretRevealed)
        case .delete, .rename:
            canCopyLocal = false
        }
        let controller = DataConflictWindowController(
            key: mutation.sourceKey,
            resourceVersion: currentData.resourceVersion,
            local: localDisplay,
            current: currentDisplay,
            canCopyLocal: canCopyLocal,
            retryUnavailableReason: retryUnavailableReason
        ) { [weak self] choice in
            guard let self else { return }
            dataConflictController = nil
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
        releaseDataDrafts()
        conflictedDataKey = nil
        objectData = currentData
        keysTable.reloadData()
        guard let row = currentData.entries.firstIndex(where: { $0.id == key }) else {
            selectedDataEntry = nil
            keysTable.deselectAll(nil)
            dataValueTextView.string = ""
            updateDataEditorControls()
            return
        }
        keysTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectedDataEntry = currentData.entries[row]
        secretRevealed = !currentData.secret
        revealButton.title = "Reveal"
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
        statusLabel.stringValue = error.localizedDescription
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
