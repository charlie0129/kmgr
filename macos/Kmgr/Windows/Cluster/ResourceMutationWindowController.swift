import AppKit
import KmgrCore

/// Compact native configuration/progress sheet for one optimistic-concurrency
/// resource mutation. A fresh UID-authoritative GET supplies the resource
/// version immediately before the operation is submitted, and the scale sheet
/// prefills its field from the workload's current `spec.replicas`.
@MainActor
final class ResourceMutationWindowController: NSWindowController, NSWindowDelegate {
    enum Mutation {
        case scale
        case rolloutRestart

        var title: String {
            switch self {
            case .scale: "Scale Resource"
            case .rolloutRestart: "Rollout Restart"
            }
        }
    }

    private let session: OpenedClusterSession
    private let identity: ResourceIdentity
    private let mutation: Mutation
    private let confirmationPreferences: ConfirmationPreferences
    private let detailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let replicasField = TechnicalTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton(title: "Apply", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var parentWindow: NSWindow?
    private var terminal = false

    private static let sheetWidth: CGFloat = 640

    var onDismiss: (() -> Void)?

    init(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        mutation: Mutation,
        confirmationPreferences: ConfirmationPreferences,
        detailProvider: any ObjectDetailProviding,
        operationProvider: any ResourceOperationProviding
    ) {
        self.session = session
        self.identity = identity
        self.mutation = mutation
        self.confirmationPreferences = confirmationPreferences
        self.detailProvider = detailProvider
        self.operationProvider = operationProvider
        // The provisional height is replaced by content-driven sizing in
        // configure(in:) before the panel is ever shown.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        panel.title = "\(clusterPresentation.titlePrefix) — \(mutation.title)"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configure(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit { task?.cancel(); loadTask?.cancel() }

    func beginSheet(for parent: NSWindow) {
        parentWindow = parent
        guard case .rolloutRestart = mutation else {
            parent.beginSheet(window!)
            loadCurrentReplicas()
            return
        }

        let draft: MutationDraft
        do { draft = try mutationDraft() }
        catch {
            parent.beginSheet(window!)
            show(error)
            return
        }
        if confirmationPreferences.requiresConfirmation(for: .workloadRestart) {
            confirmInitialRolloutRestart(draft, for: parent)
        } else {
            beginProgressSheet(for: parent, draft: draft)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard task == nil else { NSSound.beep(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        onDismiss?()
    }

    private func configure(in panel: NSPanel) {
        let heading = NSTextField(wrappingLabelWithString:
            ClusterIdentityPresentation(session: session).targetDetails(identity)
        )
        heading.lineBreakMode = .byTruncatingMiddle
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 9
        switch mutation {
        case .scale:
            replicasField.placeholderString = "Non-negative integer"
            replicasField.setAccessibilityLabel("Replica count")
            form.addArrangedSubview(row("Replicas", replicasField))
        case .rolloutRestart:
            let warning = NSTextField(wrappingLabelWithString:
                "This updates the Pod template restart annotation after a fresh UID and resource-version check."
            )
            warning.textColor = .systemOrange
            form.addArrangedSubview(warning)
            primaryButton.title = "Restart"
        }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Resource mutation in progress")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityLabel("Resource mutation status")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        primaryButton.target = self
        primaryButton.action = #selector(apply)
        primaryButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [progress, statusLabel, NSView(), cancel, primaryButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let stack = NSStackView(views: [heading, form, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 15, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            // The sheet keeps a fixed width, so the wrapping heading and
            // status label measure their line counts at the real width.
            root.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
        ])
        panel.contentView = root
        resizeToFitContent()
    }

    private func row(_ label: String, _ field: NSView) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 130).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 390).isActive = true
        let row = NSStackView(views: [title, field])
        row.orientation = .horizontal
        row.alignment = field is NSScrollView ? .top : .centerY
        row.spacing = 8
        return row
    }

    /// Prefills the field with the workload's current replica count so the
    /// default equals what a no-op apply would submit. The apply path performs
    /// its own UID-authoritative refresh, so a failed prefill only leaves the
    /// field empty for manual entry.
    private func loadCurrentReplicas() {
        guard loadTask == nil else { return }
        primaryButton.isEnabled = false
        progress.startAnimation(nil)
        setStatus("Loading current replicas…")
        loadTask = Task { [weak self, detailProvider, identity] in
            guard let self else { return }
            defer {
                loadTask = nil
                progress.stopAnimation(nil)
                primaryButton.isEnabled = !terminal
            }
            do {
                let detail = try await detailProvider.getObject(identity: identity)
                guard !Task.isCancelled else { return }
                if replicasField.stringValue.isEmpty,
                    let desired = detail.summaryFields.first(where: {
                        $0.sectionID == "replicas" && $0.fieldID == "desiredReplicas"
                    }),
                    let replicas = Int32(desired.displayText)
                {
                    replicasField.stringValue = String(replicas)
                    window?.makeFirstResponder(replicasField)
                    replicasField.selectText(nil)
                }
                setStatus("")
            } catch {
                guard !Task.isCancelled else { return }
                show(error)
            }
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        resizeToFitContent()
    }

    private func resizeToFitContent() {
        guard let panel = window, let contentView = panel.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let targetHeight = ceil(contentView.fittingSize.height)
        guard abs(contentView.bounds.height - targetHeight) > 0.5 else { return }
        panel.setContentSize(NSSize(width: contentView.bounds.width, height: targetHeight))
        contentView.layoutSubtreeIfNeeded()
    }

    @objc private func apply() {
        guard task == nil, !terminal else { return }
        let draft: MutationDraft
        do { draft = try mutationDraft() }
        catch { show(error); return }

        if let controlledMutation = mutation.preferenceControlledMutation,
            confirmationPreferences.requiresConfirmation(for: controlledMutation)
        {
            confirm(draft)
        } else {
            perform(draft)
        }
    }

    private func confirm(_ draft: MutationDraft) {
        guard let panel = window, let alert = confirmationAlert(for: draft) else { return }
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.perform(draft)
        }
    }

    private func confirmInitialRolloutRestart(
        _ draft: MutationDraft,
        for parent: NSWindow
    ) {
        guard let alert = confirmationAlert(for: draft) else { return }
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                onDismiss?()
                return
            }
            beginProgressSheet(for: parent, draft: draft)
        }
    }

    private func beginProgressSheet(for parent: NSWindow, draft: MutationDraft) {
        primaryButton.isHidden = true
        guard let panel = window else { return }
        parent.beginSheet(panel)
        perform(draft)
    }

    private func confirmationAlert(for draft: MutationDraft) -> NSAlert? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch draft {
        case .scale(let replicas):
            alert.messageText = "Scale \(identity.name) to \(replicas) replicas?"
            alert.informativeText = Self.confirmationInformativeText(
                session: session,
                identity: identity,
                note: "The object identity and resource version will be refreshed before scaling."
            )
            alert.addButton(withTitle: "Scale")
        case .restart:
            alert.messageText = "Restart \(identity.name)?"
            alert.informativeText = Self.confirmationInformativeText(
                session: session,
                identity: identity,
                note: "The Pod template will be updated after a fresh object identity and resource-version check."
            )
            alert.addButton(withTitle: "Restart")
        }
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func confirmationInformativeText(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        note: String
    ) -> String {
        "\(ClusterIdentityPresentation(session: session).targetDetails(identity))\n\n\(note)"
    }

    private func perform(_ draft: MutationDraft) {
        guard task == nil, !terminal else { return }
        if case .restart = draft { primaryButton.isHidden = true }
        primaryButton.isEnabled = false
        progress.startAnimation(nil)
        statusLabel.toolTip = nil
        setStatus("Refreshing exact object identity…")
        task = Task { [weak self, detailProvider, operationProvider, identity] in
            guard let self else { return }
            do {
                let detail = try await detailProvider.getObject(identity: identity)
                let target = try OptimisticResourceMutationTarget(
                    selectedIdentity: identity,
                    authoritativeDetail: detail
                )
                let stream: AsyncThrowingStream<OperationProgress, Error>
                switch draft {
                case .scale(let replicas):
                    stream = try await operationProvider.scaleResource(
                        identity: target.identity, replicas: replicas,
                        expectedResourceVersion: target.expectedResourceVersion
                    )
                case .restart:
                    stream = try await operationProvider.rolloutRestart(
                        identity: target.identity,
                        expectedResourceVersion: target.expectedResourceVersion
                    )
                }
                for try await value in stream {
                    setStatus("Applying… \(value.completedItems)/\(value.totalItems)")
                    if value.state.isTerminal {
                        guard value.state == .succeeded else {
                            throw value.issue ?? ClusterManagerIssue(
                                category: .internalFailure,
                                reason: "MutationFailed",
                                message: "The Kubernetes mutation did not succeed.",
                                contextName: session.contextName,
                                operation: mutation.title
                            )
                        }
                        terminal = true
                        setStatus("Succeeded")
                        statusLabel.textColor = .systemGreen
                        primaryButton.isHidden = true
                    }
                }
            } catch {
                show(error)
            }
            progress.stopAnimation(nil)
            primaryButton.isEnabled = !terminal
            task = nil
        }
    }

    private enum MutationDraft {
        case scale(Int32)
        case restart
    }

    private func mutationDraft() throws -> MutationDraft {
        switch mutation {
        case .scale:
            return .scale(try ResourceMutationDraftValidator.replicaCount(
                replicasField.stringValue
            ))
        case .rolloutRestart:
            try ResourceMutationDraftValidator.validateRolloutRestart(identity)
            return .restart
        }
    }

    private func show(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        setStatus(presentation.inlineText)
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
        if case .rolloutRestart = mutation {
            primaryButton.title = "Retry"
            primaryButton.isHidden = false
        }
        primaryButton.isEnabled = true
    }

    @objc private func cancel() {
        guard task == nil, let window else { NSSound.beep(); return }
        loadTask?.cancel()
        loadTask = nil
        if let parentWindow { parentWindow.endSheet(window) }
        window.orderOut(nil)
        onDismiss?()
    }
}

private extension ResourceMutationWindowController.Mutation {
    var preferenceControlledMutation: PreferenceControlledMutation? {
        switch self {
        case .scale: .scaling
        case .rolloutRestart: .workloadRestart
        }
    }
}
