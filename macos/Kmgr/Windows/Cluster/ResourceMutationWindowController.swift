import AppKit
import KmgrCore

/// Compact native configuration/progress sheet for one optimistic-concurrency
/// resource mutation. A fresh UID-authoritative GET supplies the resource
/// version immediately before the operation is submitted.
@MainActor
final class ResourceMutationWindowController: NSWindowController, NSWindowDelegate {
    enum Mutation {
        case scale
        case rolloutRestart
        case metadata

        var title: String {
            switch self {
            case .scale: "Scale Resource"
            case .rolloutRestart: "Rollout Restart"
            case .metadata: "Edit Labels / Annotations"
            }
        }
    }

    private let session: OpenedClusterSession
    private let identity: ResourceIdentity
    private let mutation: Mutation
    private let confirmationPreferences: ConfirmationPreferences
    private let detailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let replicasField = NSTextField()
    private let labelsField = NSTextView()
    private let annotationsField = NSTextView()
    private let removeLabelsField = NSTextView()
    private let removeAnnotationsField = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton(title: "Apply", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var parentWindow: NSWindow?
    private var terminal = false

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
        let contentHeight: CGFloat = switch mutation {
        case .scale: 240
        case .rolloutRestart: 340
        case .metadata: 510
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: contentHeight),
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

    deinit { task?.cancel() }

    func beginSheet(for parent: NSWindow) {
        parentWindow = parent
        guard case .rolloutRestart = mutation else {
            parent.beginSheet(window!)
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

    func windowWillClose(_ notification: Notification) { onDismiss?() }

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
            replicasField.stringValue = "1"
            replicasField.setAccessibilityLabel("Replica count")
            form.addArrangedSubview(row("Replicas", replicasField))
        case .rolloutRestart:
            let warning = NSTextField(wrappingLabelWithString:
                "This updates the Pod template restart annotation after a fresh UID and resource-version check."
            )
            warning.textColor = .systemOrange
            form.addArrangedSubview(warning)
            primaryButton.title = "Restart"
        case .metadata:
            let instructions = NSTextField(wrappingLabelWithString:
                "Enter one key=value entry per line to set metadata, and one key per line to remove it."
            )
            instructions.textColor = .secondaryLabelColor
            instructions.maximumNumberOfLines = 2
            form.addArrangedSubview(instructions)
            form.addArrangedSubview(row(
                "Set labels",
                metadataEditor(labelsField, accessibilityLabel: "Labels to set")
            ))
            form.addArrangedSubview(row(
                "Set annotations",
                metadataEditor(annotationsField, accessibilityLabel: "Annotations to set")
            ))
            form.addArrangedSubview(row(
                "Remove labels",
                metadataEditor(removeLabelsField, accessibilityLabel: "Label keys to remove")
            ))
            form.addArrangedSubview(row(
                "Remove annotations",
                metadataEditor(
                    removeAnnotationsField,
                    accessibilityLabel: "Annotation keys to remove"
                )
            ))
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
        let stack = NSStackView(views: [heading, form, NSView(), footer])
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
        ])
        panel.contentView = root
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

    private func metadataEditor(
        _ textView: NSTextView,
        accessibilityLabel: String
    ) -> NSScrollView {
        TextDocumentGeometry.prepareForPreciseScrolling(textView)
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(
            accessibilityLabel.contains("remove")
                ? "Enter one Kubernetes metadata key per line."
                : "Enter one Kubernetes metadata key=value entry per line."
        )

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.heightAnchor.constraint(equalToConstant: 68).isActive = true
        return scrollView
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
        case .metadata:
            return nil
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
        statusLabel.stringValue = "Refreshing exact object identity…"
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
                case .metadata(let changes):
                    stream = try await operationProvider.updateMetadata(
                        identity: target.identity,
                        expectedResourceVersion: target.expectedResourceVersion,
                        changes: changes
                    )
                }
                for try await value in stream {
                    statusLabel.stringValue = "Applying… \(value.completedItems)/\(value.totalItems)"
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
                        statusLabel.stringValue = "Succeeded"
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
        case metadata(ResourceMetadataChanges)
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
        case .metadata:
            return .metadata(try ResourceMetadataDraftParser.changes(
                labels: labelsField.string,
                annotations: annotationsField.string,
                removeLabels: removeLabelsField.string,
                removeAnnotations: removeAnnotationsField.string
            ))
        }
    }

    private func show(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.inlineText
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
        case .metadata: nil
        }
    }
}
