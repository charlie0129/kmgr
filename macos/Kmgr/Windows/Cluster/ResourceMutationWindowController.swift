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
    private let detailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let replicasField = NSTextField()
    private let labelsField = NSTextField()
    private let annotationsField = NSTextField()
    private let removeLabelsField = NSTextField()
    private let removeAnnotationsField = NSTextField()
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
        detailProvider: any ObjectDetailProviding,
        operationProvider: any ResourceOperationProviding
    ) {
        self.session = session
        self.identity = identity
        self.mutation = mutation
        self.detailProvider = detailProvider
        self.operationProvider = operationProvider
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: mutation == .metadata ? 510 : 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = mutation.title
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
        parent.beginSheet(window!)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard task == nil else { NSSound.beep(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) { onDismiss?() }

    private func configure(in panel: NSPanel) {
        let namespace = identity.namespace.isEmpty ? "Cluster" : identity.namespace
        let heading = NSTextField(wrappingLabelWithString:
            "Context: \(session.contextName)\nTarget: \(identity.resource) · \(namespace)/\(identity.name)\nUID: \(identity.uid.rawValue)"
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
            form.addArrangedSubview(row("Replicas", replicasField))
        case .rolloutRestart:
            let warning = NSTextField(wrappingLabelWithString:
                "This updates the Pod template restart annotation after a fresh UID and resource-version check."
            )
            warning.textColor = .systemOrange
            form.addArrangedSubview(warning)
            primaryButton.title = "Restart"
        case .metadata:
            labelsField.placeholderString = "One key=value entry per line"
            annotationsField.placeholderString = "One key=value entry per line"
            removeLabelsField.placeholderString = "One key per line"
            removeAnnotationsField.placeholderString = "One key per line"
            form.addArrangedSubview(row("Set labels", labelsField))
            form.addArrangedSubview(row("Set annotations", annotationsField))
            form.addArrangedSubview(row("Remove labels", removeLabelsField))
            form.addArrangedSubview(row("Remove annotations", removeAnnotationsField))
        }
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
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

    private func row(_ label: String, _ field: NSTextField) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 130).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 390).isActive = true
        let row = NSStackView(views: [title, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func apply() {
        guard task == nil, !terminal else { return }
        let draft: MutationDraft
        do { draft = try mutationDraft() }
        catch { show(error); return }
        primaryButton.isEnabled = false
        progress.startAnimation(nil)
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
                labels: labelsField.stringValue,
                annotations: annotationsField.stringValue,
                removeLabels: removeLabelsField.stringValue,
                removeAnnotations: removeAnnotationsField.stringValue
            ))
        }
    }

    private func show(_ error: Error) {
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .systemRed
        primaryButton.isEnabled = true
    }

    @objc private func cancel() {
        guard task == nil, let window else { NSSound.beep(); return }
        if let parentWindow { parentWindow.endSheet(window) }
        window.orderOut(nil)
        onDismiss?()
    }
}
