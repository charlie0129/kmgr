import AppKit
import KmgrCore

/// UID-pinned configuration sheet for exactly one Pod exec process. Opening
/// the sheet performs a fresh authoritative GET before enabling Connect; the
/// Go exec runner repeats the UID check immediately before remotecommand.
@MainActor
final class ExecConfigurationWindowController: NSWindowController,
    NSWindowDelegate, NSTextFieldDelegate
{
    private enum Mode: Int {
        case shell
        case command
    }

    private let session: OpenedClusterSession
    private let podIdentity: ResourceIdentity
    private let preferredContainer: String?
    private let objectDetailProvider: any ObjectDetailProviding
    private let execProvider: any ExecSessionProviding

    private let containerButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeControl = NSSegmentedControl(
        labels: ["Shell", "Command"], trackingMode: .selectOne,
        target: nil, action: nil
    )
    private let shellButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let executableField = NSTextField()
    private let argumentsScrollView = NSScrollView()
    private let argumentsTextView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)

    private var containers: [ExecContainerCandidate] = []
    private var loadTask: Task<Void, Never>?
    private var didFinish = false
    private var didLoadAuthoritativePod = false

    var onOpenWindow: ((TerminalWindowController) -> Void)?
    var onDismiss: (() -> Void)?

    init(
        session: OpenedClusterSession,
        podIdentity: ResourceIdentity,
        preferredContainer: String? = nil,
        objectDetailProvider: any ObjectDetailProviding,
        execProvider: any ExecSessionProviding
    ) {
        self.session = session
        self.podIdentity = podIdentity
        self.preferredContainer = preferredContainer
        self.objectDetailProvider = objectDetailProvider
        self.execProvider = execProvider

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        panel.title = "\(clusterPresentation.titlePrefix) — Configure Terminal"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
        validateForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit { loadTask?.cancel() }

    func beginSheet(for parent: NSWindow) {
        guard let panel = window, panel.sheetParent == nil else { return }
        parent.beginSheet(panel) { [weak self] _ in self?.finishDismissal() }
        loadAuthoritativePod()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let parent = sender.sheetParent {
            parent.endSheet(sender, returnCode: .cancel)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) { finishDismissal() }

    func controlTextDidChange(_ obj: Notification) { validateForm() }

    private func configureContent(in panel: NSPanel) {
        let namespace = podIdentity.namespace.isEmpty ? "(cluster scoped)" : podIdentity.namespace
        let identityGrid = NSGridView(views: [
            gridRow("Cluster", identityValue(session.clusterName)),
            gridRow("Context", identityValue(session.contextName)),
            gridRow("Pod", identityValue("\(namespace)/\(podIdentity.name)")),
            gridRow("UID", identityValue(podIdentity.uid.rawValue, monospaced: true)),
        ])
        configure(grid: identityGrid)

        containerButton.setAccessibilityLabel("Exec container")
        containerButton.addItem(withTitle: "Loading containers…")
        containerButton.isEnabled = false
        containerButton.target = self
        containerButton.action = #selector(formChanged)

        modeControl.selectedSegment = Mode.shell.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("Exec command type")

        shellButton.addItems(withTitles: ["Probe /bin/bash, then /bin/sh", "/bin/bash", "/bin/sh"])
        shellButton.target = self
        shellButton.action = #selector(formChanged)
        shellButton.setAccessibilityLabel("Shell executable")

        executableField.stringValue = "/bin/sh"
        executableField.placeholderString = "/path/to/executable"
        executableField.delegate = self
        executableField.setAccessibilityLabel("Remote executable")

        argumentsTextView.isRichText = false
        argumentsTextView.isAutomaticQuoteSubstitutionEnabled = false
        argumentsTextView.isAutomaticDashSubstitutionEnabled = false
        argumentsTextView.isAutomaticTextReplacementEnabled = false
        argumentsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        argumentsTextView.textContainerInset = NSSize(width: 6, height: 6)
        argumentsTextView.delegate = self
        argumentsTextView.setAccessibilityLabel("Remote command arguments, one per line")
        argumentsScrollView.documentView = argumentsTextView
        argumentsScrollView.hasVerticalScroller = true
        argumentsScrollView.borderType = .bezelBorder
        argumentsScrollView.heightAnchor.constraint(equalToConstant: 104).isActive = true

        let commandGrid = NSGridView(views: [
            gridRow("Container", containerButton),
            gridRow("Connect with", modeControl),
            gridRow("Shell", shellButton),
            gridRow("Executable", executableField),
            gridRow("Arguments", argumentsScrollView),
        ])
        configure(grid: commandGrid)

        let help = NSTextField(wrappingLabelWithString:
            "Shell probing starts /bin/bash and, only when that executable is unavailable, opens a new /bin/sh process. Custom arguments are one per line and are sent directly without shell parsing."
        )
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.maximumNumberOfLines = 2

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [
            progressIndicator, statusLabel, NSView(), cancelButton, connectButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [
            identityGrid, separator, commandGrid, help, validationLabel, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for child in [identityGrid, separator, commandGrid, help, validationLabel, footer] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            executableField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        panel.contentView = root
        updateModeControls()
    }

    private func configure(grid: NSGridView) {
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    private func gridRow(_ title: String, _ value: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        return [label, value]
    }

    private func identityValue(_ value: String, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        if monospaced {
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        return field
    }

    private func loadAuthoritativePod() {
        guard loadTask == nil, !didLoadAuthoritativePod else { return }
        guard identityValidationMessage() == nil else {
            validateForm()
            return
        }
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Refreshing the UID-pinned Pod and discovering containers…"
        statusLabel.textColor = .secondaryLabelColor
        progressIndicator.startAnimation(nil)
        let identity = podIdentity
        loadTask = Task { [weak self, objectDetailProvider] in
            do {
                let detail = try await objectDetailProvider.getObject(identity: identity)
                guard !Task.isCancelled, let self else { return }
                guard detail.identity == identity else {
                    throw ClusterManagerIssue(
                        category: .conflict,
                        reason: "ObjectIdentityMismatch",
                        message: "The engine returned a different Kubernetes object for the selected Pod.",
                        contextName: session.contextName,
                        operation: "configure Pod exec"
                    )
                }
                let discovered = ExecContainerCatalog.candidates(from: detail.summaryFields)
                guard !discovered.isEmpty else {
                    throw ClusterManagerIssue(
                        category: .validation,
                        reason: "NoExecContainer",
                        message: "The selected Pod declares no container eligible for exec.",
                        contextName: session.contextName,
                        operation: "configure Pod exec"
                    )
                }
                didLoadAuthoritativePod = true
                installContainers(discovered)
                statusLabel.stringValue = "Pod identity refreshed. Choose a container and command."
                statusLabel.textColor = .secondaryLabelColor
                panelFirstResponder()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
                showIssue(error)
            }
            guard let self else { return }
            progressIndicator.stopAnimation(nil)
            loadTask = nil
            validateForm()
        }
    }

    private func installContainers(_ values: [ExecContainerCandidate]) {
        containers = values
        containerButton.removeAllItems()
        containerButton.addItems(withTitles: values.map(\.displayTitle))
        let selectedIndex = preferredContainer.flatMap { preferred in
            values.firstIndex(where: { $0.name == preferred })
        } ?? values.firstIndex(where: { $0.kind == .regular })
        if let selectedIndex { containerButton.selectItem(at: selectedIndex) }
        containerButton.isEnabled = true
    }

    private func panelFirstResponder() {
        guard let panel = window else { return }
        if selectedMode == .shell { panel.makeFirstResponder(containerButton) }
        else { panel.makeFirstResponder(executableField) }
    }

    private var selectedMode: Mode {
        Mode(rawValue: modeControl.selectedSegment) ?? .shell
    }

    @objc private func modeChanged() {
        updateModeControls()
        validateForm()
        panelFirstResponder()
    }

    @objc private func formChanged() { validateForm() }

    private func updateModeControls() {
        shellButton.isEnabled = selectedMode == .shell
        executableField.isEnabled = selectedMode == .command
        argumentsTextView.isEditable = selectedMode == .command
        argumentsTextView.textColor = selectedMode == .command ? .textColor : .disabledControlTextColor
    }

    private func selectedContainer() -> ExecContainerCandidate? {
        let index = containerButton.indexOfSelectedItem
        return containers.indices.contains(index) ? containers[index] : nil
    }

    private func commandChoice() -> ExecCommandChoice {
        if selectedMode == .shell {
            let path = shellButton.indexOfSelectedItem == 2 ? "/bin/sh" : "/bin/bash"
            return .shell(path: path)
        }
        return .executable(
            path: executableField.stringValue,
            arguments: ExecCommandChoice.arguments(onePerLine: argumentsTextView.string)
        )
    }

    private func identityValidationMessage() -> String? {
        guard podIdentity.clusterSessionID == session.sessionID,
            podIdentity.group.isEmpty,
            podIdentity.version == "v1",
            podIdentity.resource == "pods",
            !podIdentity.namespace.isEmpty,
            !podIdentity.name.isEmpty,
            !podIdentity.uid.rawValue.isEmpty
        else { return "Exec requires exactly one complete, UID-pinned Pod from this cluster session." }
        return nil
    }

    private func validationMessage() -> String? {
        if let identity = identityValidationMessage() { return identity }
        guard didLoadAuthoritativePod else { return "Waiting for the authoritative Pod refresh." }
        guard selectedContainer() != nil else { return "Choose a container." }
        do {
            _ = try commandChoice().validatedCommand()
        } catch {
            return error.localizedDescription
        }
        return nil
    }

    private func validateForm() {
        let message = validationMessage()
        validationLabel.stringValue = message ?? ""
        connectButton.isEnabled = message == nil
    }

    @objc private func connect() {
        guard validationMessage() == nil,
            let container = selectedContainer(),
            let command = try? commandChoice().validatedCommand()
        else {
            validateForm()
            NSSound.beep()
            return
        }
        let probeFallback = selectedMode == .shell && shellButton.indexOfSelectedItem == 0
        let request = ExecSessionRequest(
            sessionID: session.sessionID,
            execSessionID: UUID().uuidString.lowercased(),
            generation: 1,
            target: .pod(PodExecDestination(
                pod: podIdentity,
                container: container.name
            )),
            contextName: session.contextName,
            clusterName: session.clusterName,
            command: command
        )
        let controller = TerminalWindowController(
            request: request,
            provider: execProvider,
            fallbackShellCommand: probeFallback ? ["/bin/sh"] : nil
        )
        onOpenWindow?(controller)
        dismiss(returnCode: .OK)
    }

    private func showIssue(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.message
            + (presentation.supplementaryText.isEmpty
                ? "" : "\n\(presentation.supplementaryText)")
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
    }

    @objc private func cancel() { dismiss(returnCode: .cancel) }

    private func dismiss(returnCode: NSApplication.ModalResponse) {
        guard let panel = window else { return }
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: returnCode) }
        else {
            panel.close()
            finishDismissal()
        }
    }

    private func finishDismissal() {
        guard !didFinish else { return }
        didFinish = true
        loadTask?.cancel()
        loadTask = nil
        onDismiss?()
        onDismiss = nil
    }
}

extension ExecConfigurationWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { validateForm() }
}
