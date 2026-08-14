import AppKit
import KmgrCore

@MainActor
final class LogConfigurationWindowController: NSWindowController, NSWindowDelegate {
    private let session: OpenedClusterSession
    private let pods: [ResourceIdentity]
    private let detailProvider: any ObjectDetailProviding
    private let logProvider: any LogStreamProviding
    private let displayConfiguration: LogDisplayConfiguration
    private let containerButton = NSPopUpButton()
    private let followButton = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let previousButton = NSButton(checkboxWithTitle: "Previous container logs", target: nil, action: nil)
    private let timestampsButton = NSButton(checkboxWithTitle: "Request timestamps", target: nil, action: nil)
    private let tailField = NSTextField()
    private let sinceField = NSTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading Pod containers…")
    private let openButton = NSButton(title: "Open Logs", target: nil, action: nil)
    private var loadTask: Task<Void, Never>?
    private var podContainers: [PodLogSourceInventory] = []
    private var parentWindow: NSWindow?

    var onOpenWindow: ((LogWindowController) -> Void)?
    var onDismiss: (() -> Void)?

    init(
        session: OpenedClusterSession,
        pods: [ResourceIdentity],
        detailProvider: any ObjectDetailProviding,
        logProvider: any LogStreamProviding,
        displayConfiguration: LogDisplayConfiguration = .default
    ) {
        precondition(!pods.isEmpty && pods.count <= 128)
        self.session = session
        self.pods = pods
        self.detailProvider = detailProvider
        self.logProvider = logProvider
        self.displayConfiguration = displayConfiguration
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Open Logs — \(session.contextName)"
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit { loadTask?.cancel() }

    func beginSheet(for parent: NSWindow) {
        parentWindow = parent
        parent.beginSheet(window!)
        loadContainers()
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        onDismiss?()
    }

    private func configureContent(in window: NSWindow) {
        let identity = NSTextField(wrappingLabelWithString:
            "Context: \(session.contextName)\nPods: \(pods.map { $0.namespace + "/" + $0.name }.joined(separator: ", "))"
        )
        identity.lineBreakMode = .byTruncatingMiddle
        identity.maximumNumberOfLines = 3
        let containerRow = row("Container", containerButton)
        followButton.state = .on
        timestampsButton.state = .off
        previousButton.state = .off
        tailField.stringValue = "500"
        tailField.alignment = .right
        tailField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        sinceField.placeholderString = "All available"
        sinceField.alignment = .right
        sinceField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let options = NSStackView(views: [followButton, previousButton, timestampsButton])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 7
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        openButton.target = self
        openButton.action = #selector(openLogs)
        openButton.isEnabled = false
        openButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [statusLabel, NSView(), cancel, openButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [
            identity, containerRow, options, row("Tail lines", tailField),
            row("Since seconds", sinceField), NSView(), footer,
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
            identity.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            containerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window.contentView = root
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let row = NSStackView(views: [label, control, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func loadContainers() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self, detailProvider, pods] in
            guard let self else { return }
            var values: [PodLogSourceInventory] = []
            do {
                // Bound concurrent fresh GETs so a large multi-selection never
                // turns into an unbounded request burst.
                for chunkStart in stride(from: 0, to: pods.count, by: 8) {
                    let chunk = Array(pods[chunkStart..<min(chunkStart + 8, pods.count)])
                    let resolved = try await withThrowingTaskGroup(
                        of: PodLogSourceInventory.self
                    ) { group in
                        for pod in chunk {
                            group.addTask {
                                let detail = try await detailProvider.getObject(identity: pod)
                                let containers = detail.summaryFields.compactMap { field -> String? in
                                    guard field.sectionID == "containers",
                                        field.fieldID.hasPrefix("container:") else { return nil }
                                    return field.displayText
                                }
                                return PodLogSourceInventory(
                                    identity: detail.identity,
                                    containers: containers
                                )
                            }
                        }
                        var result: [PodLogSourceInventory] = []
                        for try await value in group { result.append(value) }
                        return result
                    }
                    values.append(contentsOf: resolved)
                }
                guard !Task.isCancelled else { return }
                values.sort { ($0.identity.namespace, $0.identity.name) < ($1.identity.namespace, $1.identity.name) }
                podContainers = values
                containerButton.removeAllItems()
                let selections = PodLogSourcePlanner.selections(for: values)
                containerButton.addItems(withTitles: selections.map(\.title))
                if containerButton.numberOfItems == 0 {
                    throw ClusterManagerIssue(
                        category: .validation,
                        reason: "NoLogContainers",
                        message: "At least one selected Pod declares no regular containers.",
                        contextName: session.contextName,
                        operation: "configure Pod logs"
                    )
                }
                statusLabel.stringValue = "Container selection is UID-pinned for \(pods.count) Pod\(pods.count == 1 ? "" : "s")."
                openButton.isEnabled = true
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
                openButton.isEnabled = false
            }
            loadTask = nil
        }
    }

    @objc private func openLogs() {
        let tailText = tailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sinceText = sinceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tail = tailText.isEmpty ? Int64(-1) : Int64(tailText), tail >= -1,
            let since = sinceText.isEmpty ? Int64(0) : Int64(sinceText), since >= 0
        else {
            statusLabel.stringValue = "Tail must be -1 or greater; since seconds must be non-negative."
            statusLabel.textColor = .systemRed
            return
        }
        let selected = containerButton.titleOfSelectedItem ?? ""
        let selection: PodLogContainerSelection = selected == "All Containers"
            ? .all : .named(selected)
        let sources = PodLogSourcePlanner.sources(
            for: podContainers,
            selection: selection
        )
        guard !sources.isEmpty, sources.count <= 128 else {
            statusLabel.stringValue = "The selection expands to too many log sources (maximum 128)."
            statusLabel.textColor = .systemRed
            return
        }
        let controller = LogWindowController(
            session: session,
            sources: sources,
            provider: logProvider,
            options: LogOptions(
                follow: followButton.state == .on,
                previous: previousButton.state == .on,
                timestamps: timestampsButton.state == .on,
                sinceSeconds: since > 0 ? since : nil,
                tailLines: tail
            ),
            displayConfiguration: displayConfiguration
        )
        onOpenWindow?(controller)
        closeSheet()
    }

    @objc private func cancel() { closeSheet() }

    private func closeSheet() {
        loadTask?.cancel()
        guard let window else { return }
        if let parentWindow { parentWindow.endSheet(window) }
        window.orderOut(nil)
        onDismiss?()
    }
}
