import AppKit
import KmgrCore

/// Bounded destructive confirmation for either an explicit UID list or an
/// engine-owned immutable selection token. The token path never retains a
/// complete target/result table in the macOS process.
@MainActor
final class DeleteResourcesWindowController: NSWindowController,
    NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    private static let previewLimit = 64
    private static let aggregateFailureLimit = 64

    private let session: OpenedClusterSession
    private let request: DeleteResourcesRequest
    private let provider: any ResourceOperationProviding
    private let tableLayoutStore: TableLayoutStore
    private let currentSelectionRevision: @MainActor (
        ResourceSelectionDeleteReference,
        ResourceSelectionRevision
    ) -> ResourceSelectionRevision?
    private let tableView = NSTableView()
    private var tableLayoutBinding: TableLayoutBinding?
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let highImpactWarning = NSTextField(wrappingLabelWithString: "")
    private let selectionSummaryLabel = NSTextField(wrappingLabelWithString: "")
    private let advancedButton = NSButton(title: "", target: nil, action: nil)
    private let advancedOptions = NSStackView()
    private let propagationButton = NSPopUpButton()
    private let graceField = NSTextField()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "Delete", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var preparation: ResourceSelectionDeletePreparation?
    private var resultsByUID: [ResourceUID: OperationItemResult] = [:]
    private var aggregateFailureResults: [OperationItemResult] = []
    private var aggregateFailureUIDs: Set<ResourceUID> = []
    private var aggregateBackendOmittedDetails: UInt64 = 0
    private var aggregateLocallyHiddenDetails: UInt64 = 0
    private var aggregateProgress = false
    private var preparationTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var operationID = ""
    private var terminal = false
    private var parentWindow: NSWindow?
    private var advancedExpanded = false

    var onDismiss: (() -> Void)?

    convenience init(
        session: OpenedClusterSession,
        targets: [ResourceDeleteTarget],
        provider: any ResourceOperationProviding,
        tableLayoutStore: TableLayoutStore? = nil
    ) {
        self.init(
            session: session,
            request: .explicit(targets),
            provider: provider,
            tableLayoutStore: tableLayoutStore,
            currentSelectionRevision: { _, revision in revision }
        )
    }

    init(
        session: OpenedClusterSession,
        request: DeleteResourcesRequest,
        provider: any ResourceOperationProviding,
        tableLayoutStore: TableLayoutStore? = nil,
        currentSelectionRevision: @escaping @MainActor (
            ResourceSelectionDeleteReference,
            ResourceSelectionRevision
        ) -> ResourceSelectionRevision?
    ) {
        if case .explicit(let targets) = request { precondition(!targets.isEmpty) }
        self.session = session
        self.request = request
        self.provider = provider
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.currentSelectionRevision = currentSelectionRevision
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        window.title = "\(clusterPresentation.titlePrefix) — Delete Resources"
        window.minSize = NSSize(width: 650, height: 440)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        preparationTask?.cancel()
        expiryTask?.cancel()
        operationTask?.cancel()
    }

    func beginSheet(for parent: NSWindow) {
        parentWindow = parent
        parent.beginSheet(window!)
        window?.makeFirstResponder(cancelButton)
        if case .selection = request { prepareTokenConfirmation() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard operationTask == nil else {
            cancelPendingItems()
            return false
        }
        preparationTask?.cancel()
        return true
    }

    func windowWillClose(_ notification: Notification) { onDismiss?() }

    private var explicitTargets: [ResourceDeleteTarget] {
        guard case .explicit(let targets) = request else { return [] }
        return targets
    }

    private var previewTargets: [ResourceDeleteTarget] {
        preparation?.preview ?? explicitTargets
    }

    private var totalCount: UInt64 {
        switch request {
        case .explicit(let targets): UInt64(targets.count)
        case .selection(let reference, _): reference.selectedCount
        }
    }

    private var isAggregateRequest: Bool {
        if case .selection = request { return true }
        return false
    }

    private var aggregateOmittedDetails: UInt64 {
        aggregateBackendOmittedDetails + aggregateLocallyHiddenDetails
    }

    private func configureContent(in window: NSWindow) {
        warningLabel.stringValue = isAggregateRequest
            ? "This permanently deletes the exact Kubernetes UIDs in the immutable selection. The table is a bounded preview, not the complete target list."
            : "This permanently deletes the exact Kubernetes UIDs listed below. A same-name replacement will not satisfy a delete precondition."
        warningLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        warningLabel.textColor = .systemRed

        highImpactWarning.font = .systemFont(ofSize: 13, weight: .bold)
        highImpactWarning.textColor = .systemRed
        highImpactWarning.isHidden = true

        selectionSummaryLabel.font = .systemFont(ofSize: 12)
        selectionSummaryLabel.textColor = .secondaryLabelColor
        selectionSummaryLabel.maximumNumberOfLines = 4
        selectionSummaryLabel.setAccessibilityLabel("Deletion selection summary")

        let cluster = NSTextField(wrappingLabelWithString:
            "\(ClusterIdentityPresentation(session: session).labeledLines)\nServer: \(session.serverHostname)"
        )
        cluster.font = .systemFont(ofSize: 14, weight: .bold)
        cluster.textColor = .labelColor

        for (id, title, width) in [
            ("gvr", "GVR", 220.0), ("namespace", "Namespace", 130.0),
            ("name", "Name", 240.0), ("uid", "UID", 190.0),
            ("visibility", "Filter Status", 150.0),
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
        tableLayoutBinding = TableLayoutBinding(
            tableView: tableView,
            surface: .deleteConfirmation,
            store: tableLayoutStore
        )
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        propagationButton.addItems(withTitles: [
            "Background", "Foreground", "Orphan dependents",
        ])
        graceField.placeholderString = "Server default"
        graceField.alignment = .right
        graceField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        advancedOptions.setViews([
            NSTextField(labelWithString: "Propagation"), propagationButton,
            NSTextField(labelWithString: "Grace seconds"), graceField, NSView(),
        ], in: .leading)
        advancedOptions.orientation = .horizontal
        advancedOptions.alignment = .centerY
        advancedOptions.spacing = 8
        advancedOptions.isHidden = true
        advancedButton.bezelStyle = .disclosure
        advancedButton.controlSize = .small
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced)
        advancedButton.setAccessibilityLabel("Show advanced deletion options")
        advancedButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        advancedButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let advancedLabel = NSTextField(labelWithString: "Advanced")
        let advancedHeader = NSStackView(views: [advancedButton, advancedLabel])
        advancedHeader.orientation = .horizontal
        advancedHeader.alignment = .centerY
        advancedHeader.spacing = 4
        let advancedContainer = NSStackView(views: [advancedHeader, advancedOptions])
        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 6

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = Double(totalCount)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 4
        statusLabel.setAccessibilityLabel("Deletion status")
        primaryButton.target = self
        primaryButton.action = #selector(beginDelete)
        primaryButton.keyEquivalent = ""
        primaryButton.contentTintColor = .systemRed
        cancelButton.target = self
        cancelButton.action = #selector(cancelOrClose)
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [statusLabel, NSView(), cancelButton, primaryButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [
            cluster, warningLabel, highImpactWarning, selectionSummaryLabel,
            scroll, advancedContainer, progressIndicator, footer,
        ])
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210),
            cluster.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            warningLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            highImpactWarning.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            selectionSummaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            advancedContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            advancedOptions.widthAnchor.constraint(equalTo: advancedContainer.widthAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window.contentView = root
        window.defaultButtonCell = nil

        switch request {
        case .explicit(let targets):
            installExplicitSummary(targets)
            primaryButton.isEnabled = true
        case .selection(let reference, _):
            selectionSummaryLabel.stringValue = tokenLoadingSummary(reference)
            statusLabel.stringValue = "Validating the immutable selection…"
            primaryButton.isEnabled = false
        }
    }

    private func installExplicitSummary(_ targets: [ResourceDeleteTarget]) {
        let summary = ResourceDeleteConfirmationSummary(targets: targets)
        selectionSummaryLabel.stringValue = summary.selectionText
        highImpactWarning.stringValue = summary.highImpactWarningText ?? ""
        highImpactWarning.isHidden = summary.highImpactWarningText == nil
    }

    private func tokenLoadingSummary(
        _ reference: ResourceSelectionDeleteReference
    ) -> String {
        "\(reference.selectedCount.formatted()) exact UID-pinned resources selected\nGVR: \(displayedGVR(reference.gvr)) · Loading hidden count, expiry, and bounded UID preview…"
    }

    private func prepareTokenConfirmation() {
        guard case .selection(let reference, let requestedRevision) = request,
            preparationTask == nil,
            let initialRevision = currentSelectionRevision(
                reference,
                requestedRevision
            )
        else {
            failForReselection("The resource view changed before the selection could be confirmed.")
            return
        }
        preparationTask = Task { [weak self, provider] in
            guard let self else { return }
            do {
                var attemptedRevision = initialRevision
                var prepared: ResourceSelectionDeletePreparation?
                for attempt in 0..<2 {
                    do {
                        prepared = try await provider.prepareDeleteSelection(
                            selection: reference,
                            currentRevision: attemptedRevision,
                            previewLimit: Self.previewLimit
                        )
                        break
                    } catch {
                        guard attempt == 0,
                            preparationViewChanged(error),
                            let latestRevision = currentSelectionRevision(
                                reference,
                                attemptedRevision
                            ),
                            latestRevision != attemptedRevision
                        else { throw error }
                        attemptedRevision = latestRevision
                    }
                }
                guard !Task.isCancelled, let prepared else { return }
                preparationTask = nil
                guard currentSelectionRevision(reference, attemptedRevision) != nil,
                    prepared.selection == reference,
                    prepared.currentRevision == attemptedRevision,
                    prepared.preview.count <= Self.previewLimit
                else {
                    failForReselection(
                        "The selection or resource view changed before confirmation completed."
                    )
                    return
                }
                guard prepared.expiresAt > Date() else {
                    failForReselection(
                        "The immutable selection expired. Reselect the resources before deleting."
                    )
                    return
                }
                preparation = prepared
                installTokenPreparation(prepared)
            } catch {
                guard !Task.isCancelled else { return }
                preparationTask = nil
                if preparationViewChanged(error),
                    currentSelectionRevision(reference, initialRevision) != nil
                {
                    offerConfirmationRetry()
                    return
                }
                let presentation = UserFacingErrorPresentation(error)
                var message = presentation.inlineText
                if preparationFailureRequiresReselection(error),
                    !message.localizedCaseInsensitiveContains("select")
                {
                    message += " Reselect the resources and try again."
                }
                failForReselection(
                    message,
                    toolTip: presentation.detailedText
                )
            }
        }
    }

    private func installTokenPreparation(
        _ prepared: ResourceSelectionDeletePreparation
    ) {
        let reference = prepared.selection
        let noun = reference.selectedCount == 1 ? "resource" : "resources"
        let hidden = prepared.hiddenCount.formatted()
        let preview = prepared.preview.count.formatted()
        let previewText = prepared.previewTruncated
            ? "Showing \(preview) bounded UID previews."
            : "Showing all \(preview) UID\(prepared.preview.count == 1 ? "" : "s")."
        selectionSummaryLabel.stringValue = [
            "\(reference.selectedCount.formatted()) exact UID-pinned \(noun) selected · \(hidden) hidden by the current index",
            "GVR: \(displayedGVR(reference.gvr))",
            "Expires: \(fullDate(prepared.expiresAt)) (\(relativeDate(prepared.expiresAt)))",
            previewText,
        ].joined(separator: "\n")
        if let identity = prepared.preview.first?.identity,
            let kind = ResourceDeleteConfirmationSummary.highImpactKind(for: identity)
        {
            highImpactWarning.stringValue = "High-impact selection: \(kind.displayName) (\(reference.selectedCount.formatted())). Deleting these resources can disrupt the cluster, remove stored data, or change cluster-wide access."
            highImpactWarning.isHidden = false
        }
        statusLabel.stringValue = "Review the exact total, hidden count, expiry, GVR, and bounded UID preview before deleting."
        statusLabel.textColor = .secondaryLabelColor
        primaryButton.title = "Delete"
        primaryButton.isHidden = false
        primaryButton.isEnabled = true
        advancedButton.isEnabled = true
        cancelButton.title = "Cancel"
        tableView.reloadData()
        scheduleExpiry(prepared.expiresAt)
    }

    private func scheduleExpiry(_ expiry: Date) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, operationTask == nil, !terminal
            else { return }
            failForReselection(
                "The immutable selection expired. Reselect the resources before deleting."
            )
        }
    }

    private func failForReselection(_ message: String, toolTip: String? = nil) {
        terminal = true
        primaryButton.isEnabled = false
        primaryButton.isHidden = true
        advancedButton.isEnabled = false
        statusLabel.stringValue = message
        statusLabel.toolTip = toolTip
        statusLabel.textColor = .systemRed
        cancelButton.title = "Close"
    }

    private func offerConfirmationRetry() {
        preparation = nil
        terminal = false
        primaryButton.title = "Retry"
        primaryButton.isHidden = false
        primaryButton.isEnabled = true
        advancedButton.isEnabled = false
        statusLabel.stringValue = "The resource view is still changing. The immutable selection remains valid; retry confirmation when the list settles."
        statusLabel.toolTip = nil
        statusLabel.textColor = .systemOrange
        cancelButton.title = "Close"
        tableView.reloadData()
    }

    private func preparationViewChanged(_ error: Error) -> Bool {
        (error as? ClusterManagerIssue)?.reason == "SelectionViewChanged"
    }

    private func preparationFailureRequiresReselection(_ error: Error) -> Bool {
        guard let issue = error as? ClusterManagerIssue else { return false }
        return [
            "SelectionTokenExpired",
            "SelectionTokenUnavailable",
            "SelectionConfirmationMismatch",
            "SelectionConfirmationEnvelopeMismatch",
        ].contains(issue.reason)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        aggregateProgress ? aggregateFailureResults.count : previewTargets.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let target: ResourceDeleteTarget
        let result: OperationItemResult?
        if aggregateProgress {
            guard aggregateFailureResults.indices.contains(row) else { return nil }
            result = aggregateFailureResults[row]
            target = ResourceDeleteTarget(identity: result!.identity)
        } else {
            guard previewTargets.indices.contains(row) else { return nil }
            target = previewTargets[row]
            result = resultsByUID[target.identity.uid]
        }
        let identity = target.identity
        let value: String
        switch tableColumn.identifier.rawValue {
        case "gvr": value = ResourceDeleteConfirmationSummary.displayedGVR(for: identity)
        case "namespace": value = identity.namespace.isEmpty ? "Cluster" : identity.namespace
        case "name": value = identity.name
        case "uid": value = identity.uid.rawValue
        case "visibility":
            value = aggregateProgress
                ? "Not tracked"
                : (target.hiddenByFilter ? "Hidden by filter" : "Visible")
        case "state": value = resultText(result)
        default: value = ""
        }
        let identifier = NSUserInterfaceItemIdentifier(
            "delete.\(tableColumn.identifier.rawValue)"
        )
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
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
        cell.textField?.toolTip = resultTooltip(result) ?? value
        if tableColumn.identifier.rawValue == "visibility" {
            cell.setAccessibilityLabel("Filter status")
            cell.setAccessibilityValue(value)
        }
        if tableColumn.identifier.rawValue == "visibility", aggregateProgress {
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.toolTip = "Per-resource current-index visibility is not retained for aggregate deletion progress."
        } else if tableColumn.identifier.rawValue == "visibility", target.hiddenByFilter {
            cell.textField?.textColor = .systemOrange
            cell.textField?.toolTip = "This selected resource is not visible in the current filtered table."
        } else if let result {
            cell.textField?.textColor = result.state == .succeeded
                ? .systemGreen : (result.state == .running ? .labelColor : .systemRed)
        } else {
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    @objc private func toggleAdvanced() {
        guard operationTask == nil, !terminal else { return }
        advancedExpanded.toggle()
        advancedButton.state = advancedExpanded ? .on : .off
        advancedButton.setAccessibilityLabel(
            advancedExpanded
                ? "Hide advanced deletion options"
                : "Show advanced deletion options"
        )
        advancedOptions.isHidden = !advancedExpanded
    }

    @objc private func beginDelete() {
        guard preparationTask == nil, operationTask == nil, !terminal else { return }
        if case .selection = request, preparation == nil {
            primaryButton.title = "Delete"
            primaryButton.isEnabled = false
            cancelButton.title = "Cancel"
            statusLabel.stringValue = "Validating the immutable selection…"
            statusLabel.textColor = .secondaryLabelColor
            prepareTokenConfirmation()
            return
        }
        statusLabel.toolTip = nil
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
        if case .selection = request {
            guard let preparation, preparation.expiresAt > Date() else {
                failForReselection(
                    "The immutable selection expired. Reselect the resources before deleting."
                )
                return
            }
        }
        let propagation: DeletePropagationPolicy = switch propagationButton.indexOfSelectedItem {
        case 1: .foreground
        case 2: .orphan
        default: .background
        }
        let options = ResourceDeleteOptions(
            propagationPolicy: propagation,
            gracePeriodSeconds: grace,
            maxConcurrency: 4
        )
        expiryTask?.cancel()
        expiryTask = nil
        setRunning(true)
        operationTask = Task { [weak self, provider] in
            guard let self else { return }
            do {
                let stream: AsyncThrowingStream<OperationProgress, Error>
                switch request {
                case .explicit(let targets):
                    stream = try await provider.deleteResources(
                        targets: targets,
                        options: options
                    )
                case .selection:
                    stream = try await provider.deleteSelection(
                        selection: preparation!.selection,
                        options: options
                    )
                }
                for try await progress in stream {
                    guard !Task.isCancelled else { return }
                    receive(progress)
                    if progress.state.isTerminal { finish(progress) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
                terminal = true
                setRunning(false)
                primaryButton.isHidden = true
                cancelButton.title = "Close"
            }
            operationTask = nil
        }
    }

    private func receive(_ progress: OperationProgress) {
        operationID = progress.operationID
        let wasAggregateProgress = aggregateProgress
        aggregateProgress = aggregateProgress || progress.aggregateOnly || isAggregateRequest
        if aggregateProgress, !wasAggregateProgress {
            warningLabel.stringValue = "Aggregate deletion is in progress. The table now shows only bounded non-success details; successful target identities are not retained."
            tableView.setAccessibilityLabel("Bounded deletion non-success details")
        }
        if aggregateProgress {
            for result in progress.itemResults where result.state != .succeeded {
                guard aggregateFailureUIDs.insert(result.identity.uid).inserted
                else { continue }
                if aggregateFailureResults.count < Self.aggregateFailureLimit {
                    aggregateFailureResults.append(result)
                } else {
                    aggregateLocallyHiddenDetails += 1
                }
            }
            aggregateBackendOmittedDetails = max(
                aggregateBackendOmittedDetails,
                UInt64(progress.omittedItemResults)
            )
        } else {
            for result in progress.itemResults {
                resultsByUID[result.identity.uid] = result
            }
        }
        progressIndicator.maxValue = max(
            progressIndicator.maxValue,
            Double(progress.totalItems)
        )
        progressIndicator.doubleValue = Double(progress.completedItems)
        tableView.reloadData()
        statusLabel.stringValue = progressStatus(progress)
        statusLabel.textColor = .secondaryLabelColor
    }

    private func progressStatus(_ progress: OperationProgress) -> String {
        var text = "Deleting… \(progress.completedItems.formatted())/\(progress.totalItems.formatted())"
        if aggregateProgress, !aggregateFailureResults.isEmpty {
            text += " · showing \(aggregateFailureResults.count.formatted()) failure details"
        }
        if aggregateOmittedDetails > 0 {
            text += " · \(aggregateOmittedDetails.formatted()) additional details omitted"
        }
        return text
    }

    private func finish(_ progress: OperationProgress) {
        terminal = true
        setRunning(false)
        primaryButton.isHidden = true
        cancelButton.title = "Close"
        statusLabel.toolTip = nil
        if aggregateProgress {
            finishAggregate(progress)
            return
        }
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
            installTerminalFailure(progress)
        }
    }

    private func finishAggregate(_ progress: OperationProgress) {
        let nonSuccess = UInt64(aggregateFailureUIDs.count)
            + aggregateBackendOmittedDetails
        let total = UInt64(progress.totalItems)
        let succeeded = total >= nonSuccess ? total - nonSuccess : 0
        let detailSuffix: String = {
            var parts: [String] = []
            if !aggregateFailureResults.isEmpty {
                parts.append("showing \(aggregateFailureResults.count.formatted()) bounded failure details")
            }
            if aggregateOmittedDetails > 0 {
                parts.append("\(aggregateOmittedDetails.formatted()) additional details omitted")
            }
            return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
        }()
        switch progress.state {
        case .succeeded:
            statusLabel.stringValue = "Deleted \(succeeded.formatted()) resources."
            statusLabel.textColor = .secondaryLabelColor
        case .partiallySucceeded:
            let counts = "Partial result: \(succeeded.formatted()) deleted, \(nonSuccess.formatted()) failed, skipped, or cancelled\(detailSuffix)."
            if let issue = progress.issue {
                let presentation = issue.userFacingPresentation
                statusLabel.stringValue = counts + " " + presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
            } else {
                statusLabel.stringValue = counts
            }
            statusLabel.textColor = .systemOrange
        case .cancelled:
            statusLabel.stringValue = "Deletion cancelled: \(succeeded.formatted()) deleted, \(nonSuccess.formatted()) failed, skipped, or cancelled\(detailSuffix)."
            statusLabel.textColor = .systemOrange
        case .failed:
            let counts = "Deletion failed: \(succeeded.formatted()) deleted, \(nonSuccess.formatted()) failed, skipped, or cancelled\(detailSuffix)."
            if let issue = progress.issue {
                let presentation = issue.userFacingPresentation
                statusLabel.stringValue = counts + " " + presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
            } else {
                statusLabel.stringValue = counts
            }
            statusLabel.textColor = .systemRed
        default:
            installTerminalFailure(progress, suffix: detailSuffix)
        }
    }

    private func installTerminalFailure(
        _ progress: OperationProgress,
        suffix: String = ""
    ) {
        if let issue = progress.issue {
            let presentation = issue.userFacingPresentation
            statusLabel.stringValue = presentation.inlineText + suffix
            statusLabel.toolTip = presentation.detailedText
        } else {
            statusLabel.stringValue = "Deletion failed\(suffix)."
            statusLabel.toolTip = nil
        }
        statusLabel.textColor = .systemRed
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
        statusLabel.stringValue = isAggregateRequest
            ? "Cancelling the aggregate deletion…"
            : "Cancelling work that has not started…"
        Task { [weak self, provider, session] in
            guard let self else { return }
            do {
                try await provider.cancelOperation(
                    sessionID: session.sessionID,
                    operationID: operationID,
                    // Aggregate token deletion has no retained per-item queue
                    // to selectively cancel, so cancellation is intentionally
                    // operation-wide.
                    cancelNotStartedOnly: !isAggregateRequest
                )
            } catch {
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
                cancelButton.isEnabled = true
            }
        }
    }

    private func setRunning(_ running: Bool) {
        primaryButton.isEnabled = !running
        advancedButton.isEnabled = !running
        propagationButton.isEnabled = !running
        graceField.isEnabled = !running
        cancelButton.title = running
            ? (isAggregateRequest ? "Cancel" : "Cancel Pending")
            : "Cancel"
        cancelButton.isEnabled = true
    }

    private func closeSheet() {
        guard let window else { return }
        preparationTask?.cancel()
        expiryTask?.cancel()
        if let parentWindow { parentWindow.endSheet(window) }
        window.orderOut(nil)
        onDismiss?()
    }

    private func resultText(_ result: OperationItemResult?) -> String {
        guard let result else { return operationTask == nil ? "Pending" : "Queued" }
        return result.state.rawValue.capitalized
    }

    private func resultTooltip(_ result: OperationItemResult?) -> String? {
        result?.issue?.userFacingPresentation.detailedText
    }

    private func displayedGVR(_ gvr: GVR) -> String {
        "\(gvr.group.isEmpty ? "core" : gvr.group)/\(gvr.version)/\(gvr.resource)"
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
