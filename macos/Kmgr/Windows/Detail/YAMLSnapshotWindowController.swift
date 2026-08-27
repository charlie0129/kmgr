import AppKit
import KmgrCore

/// A deliberately small, independent YAML document window.
///
/// It installs the server's UTF-8 bytes directly in AppKit's factory-created
/// plain document text view. Editing uses the same backend validation and
/// optimistic apply contract as the standalone YAML utility, without adding Yams, a
/// custom ruler, or `TextDocumentGeometry` to this presentation path.
@MainActor
final class YAMLSnapshotWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation, ContextualShortcutProviding
{
    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession
    private let provider: any ObjectDetailProviding
    private let tableLayoutStore: TableLayoutStore
    private var refreshTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var refreshRevision: UInt64 = 0
    private var hasRequestedSnapshot = false
    private var displayedDetail: ObjectDetail?
    private var displayedYAMLUTF8: Data?
    private var editingBasis: ObjectDetail?
    private var isEditingYAML = false
    private var isConnected = true
    private var isClosing = false
    private var editWhenReady = false

    private let scrollView: NSScrollView
    private let textView: YAMLTextView
    private var syntaxHighlighter: SyntaxHighlighter?
    private let targetLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let byteCountLabel = NSTextField(labelWithString: "No bytes received")
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    var onClose: (() -> Void)?
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        ContextualShortcutCatalog.yamlSnapshot(isEditing: isEditingYAML)
    }

    init(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        tableLayoutStore: TableLayoutStore? = nil,
        initiallyEditing: Bool = false
    ) {
        self.session = session
        self.identity = identity
        self.provider = provider
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.editWhenReady = initiallyEditing

        // This factory supplies AppKit's complete plain-document TextKit stack,
        // including the clip view, scrollers, and document sizing behavior.
        // Keep it intact instead of reconstructing or resizing its document.
        let scrollView = YAMLTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollView.documentView as? YAMLTextView else {
            preconditionFailure("AppKit did not create a text view for its plain document")
        }
        self.scrollView = scrollView
        self.textView = textView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        refreshTask?.cancel()
        operationTask?.cancel()
    }

    override func showWindow(_ sender: Any?) {
        let firstPresentation = !hasRequestedSnapshot
        super.showWindow(sender)
        if firstPresentation {
            window?.center()
            refresh()
        }
        if firstPresentation || window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(textView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        editWhenReady = false
        stop()
        onClose?()
    }

    func stop() {
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        operationTask?.cancel()
        operationTask = nil
        updateEditingControls()
    }

    /// Requests editing for the next usable snapshot. This is intentionally
    /// idempotent so the resource-list `E` shortcut can focus an existing YAML
    /// window without creating a duplicate controller or losing a pending
    /// load.
    func beginEditingWhenReady() {
        guard !isClosing else { return }
        if isEditingYAML {
            // The request has already been fulfilled. Do not leave a stale
            // deferred intent that could unexpectedly re-enter edit mode after
            // a later refresh or recovery.
            editWhenReady = false
            return
        }
        editWhenReady = true
        beginInitialEditIfReady()
    }

    /// Invalidates every request made with the old helper session while
    /// retaining the last successfully rendered bytes as an offline snapshot.
    func engineDidDisconnect() {
        isConnected = false
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        operationTask?.cancel()
        operationTask = nil
        statusLabel.stringValue = displayedYAMLUTF8 == nil
            ? "Engine disconnected · no YAML snapshot available"
            : isEditingYAML
                ? "Engine disconnected · local YAML edit preserved"
                : "Engine disconnected · YAML snapshot preserved"
        statusLabel.textColor = .systemOrange
        statusLabel.toolTip = nil
        updateEditingControls()
    }

    /// Rebinds the same UID to a newly authenticated helper session and
    /// performs a fresh GET. No request from the previous generation can be
    /// accepted after this point.
    func recover(with recoveredSession: OpenedClusterSession) {
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        session = recoveredSession
        identity.clusterSessionID = recoveredSession.sessionID
        if var editingBasis {
            editingBasis.identity.clusterSessionID = recoveredSession.sessionID
            self.editingBasis = editingBasis
        }
        isConnected = true
        updateIdentityPresentation()
        refresh(preservingLocalEdit: isEditingYAML)
    }

    @objc private func refreshPressed(_ sender: Any?) { refresh() }

    private func refresh(preservingLocalEdit: Bool = false) {
        guard isConnected, refreshTask == nil, operationTask == nil, !isClosing,
            !isEditingYAML || preservingLocalEdit
        else { return }
        guard identity.clusterSessionID == session.sessionID else {
            installFailure(ClusterManagerIssue(
                category: .conflict,
                reason: "StaleClusterSession",
                message: "The YAML window belongs to an expired cluster session.",
                contextName: session.contextName,
                operation: "load YAML snapshot"
            ))
            return
        }

        hasRequestedSnapshot = true
        refreshRevision &+= 1
        let revision = refreshRevision
        let requestedIdentity = identity
        let requestedSessionID = session.sessionID
        refreshButton.isEnabled = false
        statusLabel.stringValue = displayedYAMLUTF8 == nil ? "Loading YAML…" : "Refreshing YAML…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil

        refreshTask = Task { [weak self, provider] in
            guard let self else { return }
            defer {
                if refreshRevision == revision {
                    refreshTask = nil
                    updateEditingControls()
                    if editWhenReady {
                        DispatchQueue.main.async { [weak self] in
                            self?.beginInitialEditIfReady()
                        }
                    }
                }
            }
            do {
                let detail = try await provider.getObject(identity: requestedIdentity)
                guard !Task.isCancelled, refreshRevision == revision,
                    isConnected, session.sessionID == requestedSessionID
                else { return }
                guard detail.identity == requestedIdentity else {
                    throw ClusterManagerIssue(
                        category: .conflict,
                        reason: "ObjectRecreated",
                        message: "The YAML response did not match the requested UID-pinned object.",
                        contextName: session.contextName,
                        operation: "load YAML snapshot"
                    )
                }
                install(detail)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, refreshRevision == revision else { return }
                installFailure(error)
            }
        }
        updateEditingControls()
    }

    private func install(_ detail: ObjectDetail) {
        let yamlUTF8 = detail.yamlUTF8
        let receivedCount = yamlUTF8.count
        byteCountLabel.stringValue = Self.receivedByteText(receivedCount)
        byteCountLabel.toolTip = nil

        guard !yamlUTF8.isEmpty else {
            editWhenReady = false
            if let displayedYAMLUTF8, !displayedYAMLUTF8.isEmpty {
                byteCountLabel.stringValue += " · showing previous \(Self.byteText(displayedYAMLUTF8.count))"
                statusLabel.stringValue = "Empty YAML response · previous snapshot preserved"
                statusLabel.textColor = .systemOrange
                statusLabel.toolTip = "The refresh returned zero YAML bytes, so kmgr kept the last non-empty snapshot."
                emptyStateLabel.isHidden = true
            } else {
                displayedYAMLUTF8 = yamlUTF8
                textView.string = ""
                emptyStateLabel.stringValue = "No YAML content was returned (0 bytes)."
                emptyStateLabel.isHidden = false
                statusLabel.stringValue = "Empty YAML response"
                statusLabel.textColor = .systemOrange
                statusLabel.toolTip = "The object response succeeded but contained zero YAML bytes."
            }
            updateEditingControls()
            return
        }

        displayedDetail = detail
        displayedYAMLUTF8 = yamlUTF8
        // Decode the received bytes directly. In particular, do not parse,
        // normalize, serialize, or remove managedFields before first display.
        if !isEditingYAML {
            replaceYAMLText(with: String(decoding: yamlUTF8, as: UTF8.self))
        }
        emptyStateLabel.isHidden = true
        if isEditingYAML {
            statusLabel.stringValue = "Server YAML refreshed · local edit preserved"
            statusLabel.textColor = .systemOrange
            statusLabel.toolTip = "Saving still uses the resource version from the start of this local edit."
        } else {
            installSnapshotStatus()
        }
        updateEditingControls()
    }

    private func installFailure(_ error: Error) {
        editWhenReady = false
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.inlineText
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
        if displayedYAMLUTF8 == nil {
            emptyStateLabel.stringValue = "YAML could not be loaded."
            emptyStateLabel.isHidden = false
        }
        updateEditingControls()
    }

    private func configureWindow() {
        updateIdentityPresentation()

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.configureAsTechnicalTextInput()
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.setAccessibilityLabel("Kubernetes YAML snapshot")

        scrollView.identifier = .init("yaml-snapshot-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.identifier = .init("yaml-snapshot-target")
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.identifier = .init("yaml-snapshot-status")
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        byteCountLabel.identifier = .init("yaml-snapshot-byte-count")
        byteCountLabel.lineBreakMode = .byTruncatingTail
        byteCountLabel.textColor = .secondaryLabelColor
        byteCountLabel.alignment = .right

        emptyStateLabel.identifier = .init("yaml-snapshot-empty-state")
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed(_:))
        refreshButton.identifier = .init("yaml-snapshot-refresh")
        refreshButton.toolTip = "Fetch a fresh snapshot of this exact UID."

        editButton.target = self
        editButton.action = #selector(beginYAMLEdit)
        editButton.identifier = .init("yaml-snapshot-edit")
        editButton.toolTip = "Edit this exact UID-pinned object."
        saveButton.target = self
        saveButton.action = #selector(saveYAML)
        saveButton.identifier = .init("yaml-snapshot-save")
        saveButton.toolTip = "Validate and apply this YAML edit."
        cancelButton.target = self
        cancelButton.action = #selector(cancelYAMLEdit)
        cancelButton.identifier = .init("yaml-snapshot-cancel")
        cancelButton.toolTip = "Discard the local edit and restore the latest snapshot."
        saveButton.isHidden = true
        cancelButton.isHidden = true

        let spacer = NSView()
        let header = NSStackView(views: [
            targetLabel, spacer, editButton, saveButton, cancelButton, refreshButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for button in [editButton, saveButton, cancelButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let statusSpacer = NSView()
        let footer = NSStackView(views: [statusLabel, statusSpacer, byteCountLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        byteCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let root = NSView()
        root.addSubview(header)
        root.addSubview(scrollView)
        root.addSubview(emptyStateLabel)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24
            ),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24
            ),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window?.contentView = root
        syntaxHighlighter = SyntaxHighlighter(textView: textView, scrollView: scrollView)
        textView.onPlainEditShortcut = { [weak self] in
            guard let self, !self.isEditingYAML, self.editButton.isEnabled else {
                return false
            }
            self.beginYAMLEdit()
            return true
        }
        updateEditingControls()
    }

    private func updateIdentityPresentation() {
        let cluster = ClusterIdentityPresentation(session: session)
        let scope = identity.namespace.isEmpty ? identity.name : "\(identity.namespace)/\(identity.name)"
        let api = identity.group.isEmpty
            ? "\(identity.version)/\(identity.resource)"
            : "\(identity.group)/\(identity.version)/\(identity.resource)"
        window?.title = "\(cluster.titlePrefix) — YAML — \(scope)"
        window?.subtitle = "\(api) · UID \(identity.uid.rawValue)"
        targetLabel.stringValue = "\(api) · \(scope) · UID \(identity.uid.rawValue)"
        targetLabel.toolTip = cluster.targetDetails(identity)
    }

    @objc private func beginYAMLEdit() {
        guard let displayedDetail, !displayedDetail.yamlUTF8.isEmpty,
            isConnected, refreshTask == nil, operationTask == nil, !isClosing
        else { return }
        editWhenReady = false
        editingBasis = displayedDetail
        isEditingYAML = true
        statusLabel.stringValue = displayedDetail.resourceVersion.isEmpty
            ? "Editing local YAML"
            : "Editing local YAML · resource version \(displayedDetail.resourceVersion)"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = "Save validates this edit against the exact resource version shown."
        updateEditingControls()
        window?.makeFirstResponder(textView)
    }

    private func beginInitialEditIfReady() {
        guard editWhenReady else { return }
        guard !isEditingYAML, refreshTask == nil,
            displayedDetail?.yamlUTF8.isEmpty == false,
            isConnected, operationTask == nil, !isClosing
        else { return }
        editWhenReady = false
        beginYAMLEdit()
    }

    @objc private func cancelYAMLEdit() {
        guard isEditingYAML, operationTask == nil, refreshTask == nil else { return }
        finishYAMLEdit()
        installSnapshotStatus()
    }

    @objc private func saveYAML() {
        guard let editingBasis, isEditingYAML, isConnected,
            operationTask == nil, refreshTask == nil, !isClosing
        else { return }
        let edited = Data(textView.string.utf8)
        statusLabel.stringValue = "Validating…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        operationTask = Task { [weak self, provider, identity] in
            guard let self else { return }
            var refreshAfterSuccess = false
            defer {
                operationTask = nil
                if refreshAfterSuccess {
                    refresh()
                } else {
                    updateEditingControls()
                }
            }
            do {
                let prepared = try await provider.prepareYAML(
                    identity: identity,
                    yamlUTF8: edited,
                    expectedResourceVersion: editingBasis.resourceVersion,
                    forceFieldOwnership: false
                )
                guard await confirm(prepared: prepared) else {
                    statusLabel.stringValue = "Save cancelled"
                    return
                }
                let stream = try await provider.applyYAML(
                    identity: identity,
                    yamlUTF8: prepared.normalizedYAMLUTF8,
                    expectedResourceVersion: editingBasis.resourceVersion,
                    forceFieldOwnership: false
                )
                var reachedTerminalState = false
                for try await progress in stream {
                    guard !Task.isCancelled else { return }
                    statusLabel.stringValue =
                        "Saving… \(progress.completedItems)/\(progress.totalItems)"
                    guard progress.state.isTerminal else { continue }
                    reachedTerminalState = true
                    guard progress.state == .succeeded else {
                        throw progress.issue ?? ClusterManagerIssue(
                            category: .conflict,
                            reason: "YAMLApplyFailed",
                            message: "The YAML edit was not applied. Your local edit is still open.",
                            operation: "apply YAML"
                        )
                    }
                    displayedYAMLUTF8 = prepared.normalizedYAMLUTF8
                    if var detail = displayedDetail {
                        detail.yamlUTF8 = prepared.normalizedYAMLUTF8
                        displayedDetail = detail
                    }
                    byteCountLabel.stringValue = Self.receivedByteText(
                        prepared.normalizedYAMLUTF8.count
                    )
                    finishYAMLEdit()
                    refreshAfterSuccess = true
                    break
                }
                guard reachedTerminalState else {
                    throw ClusterManagerIssue(
                        category: .unavailable,
                        reason: "YAMLApplyEnded",
                        message: "The YAML apply stream ended without a final result. Your local edit is still open.",
                        retryable: true,
                        operation: "apply YAML"
                    )
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
            }
        }
        updateEditingControls()
    }

    private func confirm(prepared: PreparedYAMLEdit) async -> Bool {
        guard !prepared.diff.isEmpty else { return true }
        guard let parent = window else { return false }
        let controller = YAMLDiffConfirmationWindowController(
            targetDetails: ClusterIdentityPresentation(session: session).targetDetails(identity),
            prepared: prepared,
            tableLayoutStore: tableLayoutStore
        )
        return await controller.runSheet(for: parent) == .apply
    }

    private func finishYAMLEdit() {
        isEditingYAML = false
        editingBasis = nil
        if let displayedYAMLUTF8 {
            replaceYAMLText(with: String(decoding: displayedYAMLUTF8, as: UTF8.self))
        }
        textView.undoManager?.removeAllActions()
        updateEditingControls()
    }

    private func updateEditingControls() {
        let idle = refreshTask == nil && operationTask == nil
        editButton.isHidden = isEditingYAML
        saveButton.isHidden = !isEditingYAML
        cancelButton.isHidden = !isEditingYAML
        editButton.isEnabled = !isEditingYAML && idle && isConnected && !isClosing
            && displayedDetail?.yamlUTF8.isEmpty == false
        saveButton.isEnabled = isEditingYAML && idle && isConnected && !isClosing
        cancelButton.isEnabled = isEditingYAML && idle && !isClosing
        refreshButton.isEnabled = !isEditingYAML && idle && isConnected && !isClosing
        textView.isEditable = isEditingYAML && idle && isConnected && !isClosing
        contextualShortcutsDidChange?()
    }

    private func installSnapshotStatus() {
        statusLabel.stringValue = displayedDetail?.resourceVersion.isEmpty == false
            ? "YAML snapshot · resource version \(displayedDetail?.resourceVersion ?? "")"
            : "YAML snapshot"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
    }

    private func replaceYAMLText(with text: String) {
        guard textView.string != text else { return }
        let selectedRanges = textView.selectedRanges
        let visibleOrigin = scrollView.contentView.bounds.origin
        textView.string = text
        let length = (text as NSString).length
        let restoredRanges = selectedRanges.compactMap { value -> NSValue? in
            let range = value.rangeValue
            guard range.location <= length else { return nil }
            return NSValue(range: NSRange(
                location: range.location,
                length: min(range.length, length - range.location)
            ))
        }
        if !restoredRanges.isEmpty { textView.selectedRanges = restoredRanges }
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        syntaxHighlighter?.invalidate()
    }

    @objc func saveDocument(_ sender: Any?) {
        if isEditingYAML { saveYAML() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSDocument.save(_:)) {
            return saveButton.isEnabled
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditingYAML { cancelYAMLEdit() }
        else { super.cancelOperation(sender) }
    }

    static func receivedByteText(_ count: Int) -> String {
        "Received \(byteText(count))"
    }

    private static func byteText(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "byte" : "bytes")"
    }
}
