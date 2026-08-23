import AppKit
import KmgrCore

/// Configures one UID-pinned Linux Node shell. The engine performs the final
/// Node UID/OS checks and owns creation and cleanup of the privileged helper
/// Pod immediately before attaching the terminal.
@MainActor
final class NodeShellConfigurationWindowController: NSWindowController,
    NSWindowDelegate, NSTextFieldDelegate
{
    private enum Mode: Int {
        case shell
        case command
    }

    private let session: OpenedClusterSession
    private let target: NodeShellTarget
    private let execProvider: any ExecSessionProviding
    private let saveClusterImage: (String?) throws -> Void

    private let imageField = NSTextField()
    private let namespaceField = NSTextField()
    private let saveClusterImageButton = NSButton(
        checkboxWithTitle: "Use this image as the default for this cluster",
        target: nil,
        action: nil
    )
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
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private var didFinish = false

    var onOpenWindow: ((TerminalWindowController) -> Void)?
    var onDismiss: (() -> Void)?

    init(
        session: OpenedClusterSession,
        target: NodeShellTarget,
        image: String,
        namespace: String,
        usesClusterImageOverride: Bool,
        execProvider: any ExecSessionProviding,
        saveClusterImage: @escaping (String?) throws -> Void
    ) {
        self.session = session
        self.target = target
        self.execProvider = execProvider
        self.saveClusterImage = saveClusterImage

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let cluster = ClusterIdentityPresentation(session: session)
        panel.title = "\(cluster.titlePrefix) — Configure Node Shell"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
        imageField.stringValue = image
        namespaceField.stringValue = namespace
        saveClusterImageButton.state = usesClusterImageOverride ? .on : .off
        validateForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func beginSheet(for parent: NSWindow) {
        guard let panel = window, panel.sheetParent == nil else { return }
        parent.beginSheet(panel) { [weak self] _ in self?.finishDismissal() }
        panel.makeFirstResponder(imageField)
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
        let node = target.node
        let identityGrid = NSGridView(views: [
            gridRow("Cluster", identityValue(session.clusterName)),
            gridRow("Context", identityValue(session.contextName)),
            gridRow("Node", identityValue(node.name)),
            gridRow("UID", identityValue(node.uid.rawValue, monospaced: true)),
        ])
        configure(grid: identityGrid)

        imageField.placeholderString = NodeShellPreferences.defaultImage
        imageField.delegate = self
        imageField.lineBreakMode = .byTruncatingMiddle
        imageField.setAccessibilityIdentifier("node-shell.image")
        imageField.setAccessibilityLabel("Node shell helper image")

        namespaceField.placeholderString = "default"
        namespaceField.delegate = self
        namespaceField.setAccessibilityIdentifier("node-shell.namespace")
        namespaceField.setAccessibilityLabel("Node shell helper namespace")

        saveClusterImageButton.target = self
        saveClusterImageButton.action = #selector(formChanged)
        saveClusterImageButton.setAccessibilityIdentifier("node-shell.save-cluster-image")

        modeControl.selectedSegment = Mode.shell.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityIdentifier("node-shell.command-mode")
        modeControl.setAccessibilityLabel("Node shell command type")

        shellButton.addItems(withTitles: [
            "Probe bash, then sh",
            "bash",
            "sh",
        ])
        shellButton.target = self
        shellButton.action = #selector(formChanged)
        shellButton.setAccessibilityIdentifier("node-shell.shell")
        shellButton.setAccessibilityLabel("Host shell executable")

        executableField.stringValue = "sh"
        executableField.placeholderString = "Host executable"
        executableField.delegate = self
        executableField.setAccessibilityIdentifier("node-shell.executable")
        executableField.setAccessibilityLabel("Host executable")

        TextDocumentGeometry.prepareForPreciseScrolling(argumentsTextView)
        argumentsTextView.isRichText = false
        argumentsTextView.isAutomaticQuoteSubstitutionEnabled = false
        argumentsTextView.isAutomaticDashSubstitutionEnabled = false
        argumentsTextView.isAutomaticTextReplacementEnabled = false
        argumentsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        argumentsTextView.textContainerInset = NSSize(width: 6, height: 6)
        argumentsTextView.delegate = self
        argumentsTextView.setAccessibilityIdentifier("node-shell.arguments")
        argumentsTextView.setAccessibilityLabel("Host command arguments, one per line")
        argumentsScrollView.documentView = argumentsTextView
        argumentsScrollView.hasVerticalScroller = true
        argumentsScrollView.borderType = .bezelBorder
        argumentsScrollView.heightAnchor.constraint(equalToConstant: 82).isActive = true

        let optionsGrid = NSGridView(views: [
            gridRow("Helper image", imageField),
            gridRow("Helper namespace", namespaceField),
            gridRow("Connect with", modeControl),
            gridRow("Host shell", shellButton),
            gridRow("Executable", executableField),
            gridRow("Arguments", argumentsScrollView),
        ])
        configure(grid: optionsGrid)

        let warning = NSTextField(wrappingLabelWithString:
            "This creates a temporary privileged Pod on the selected Node, enters PID 1's Linux namespaces with nsenter, and deletes the helper when the terminal ends. The image must contain nsenter."
        )
        warning.textColor = .secondaryLabelColor
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityIdentifier("node-shell.status")
        validationLabel.textColor = .systemRed
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.maximumNumberOfLines = 2
        validationLabel.setAccessibilityIdentifier("node-shell.validation")

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.keyEquivalent = "\r"
        connectButton.setAccessibilityIdentifier("node-shell.connect")

        let footer = NSStackView(views: [
            statusLabel, NSView(), cancelButton, connectButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [
            identityGrid, separator, optionsGrid, saveClusterImageButton,
            warning, validationLabel, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for child in [
            identityGrid, separator, optionsGrid, saveClusterImageButton,
            warning, validationLabel, footer,
        ] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            imageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
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
            field.font = .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
        }
        return field
    }

    private var selectedMode: Mode {
        Mode(rawValue: modeControl.selectedSegment) ?? .shell
    }

    @objc private func modeChanged() {
        updateModeControls()
        validateForm()
        window?.makeFirstResponder(selectedMode == .shell ? shellButton : executableField)
    }

    @objc private func formChanged() { validateForm() }

    private func updateModeControls() {
        shellButton.isEnabled = selectedMode == .shell
        executableField.isEnabled = selectedMode == .command
        argumentsTextView.isEditable = selectedMode == .command
        argumentsTextView.textColor = selectedMode == .command
            ? .textColor : .disabledControlTextColor
    }

    private func commandChoice() -> ExecCommandChoice {
        if selectedMode == .shell {
            return .executable(
                path: shellButton.indexOfSelectedItem == 2 ? "sh" : "bash",
                arguments: ["-l"]
            )
        }
        return .executable(
            path: executableField.stringValue,
            arguments: ExecCommandChoice.arguments(onePerLine: argumentsTextView.string)
        )
    }

    private func identityValidationMessage() -> String? {
        let node = target.node
        guard node.clusterSessionID == session.sessionID,
            node.group.isEmpty,
            node.version == "v1",
            node.resource == "nodes",
            node.namespace.isEmpty,
            !node.name.isEmpty,
            !node.uid.rawValue.isEmpty
        else {
            return "Node shell requires exactly one complete, UID-pinned core/v1 Node from this cluster session."
        }
        return nil
    }

    private func validationMessage() -> String? {
        if let identity = identityValidationMessage() { return identity }
        guard NodeShellPreferences.isValidImage(imageField.stringValue) else {
            return "Enter a nonempty helper image reference without whitespace or control characters."
        }
        guard NodeShellLaunchPlanner.isValidNamespace(namespaceField.stringValue) else {
            return "Enter a lowercase Kubernetes namespace name of at most 63 characters."
        }
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
            let command = try? commandChoice().validatedCommand()
        else {
            validateForm()
            NSSound.beep()
            return
        }
        do {
            try saveClusterImage(
                saveClusterImageButton.state == .on ? imageField.stringValue : nil
            )
            let plan = try NodeShellLaunchPlanner.plan(
                session: session,
                target: target,
                image: imageField.stringValue,
                namespace: namespaceField.stringValue,
                command: command,
                fallbackShellCommand: selectedMode == .shell
                    && shellButton.indexOfSelectedItem == 0 ? ["sh", "-l"] : nil,
                execSessionID: UUID().uuidString.lowercased()
            )
            onOpenWindow?(TerminalWindowController(
                request: plan.request,
                provider: execProvider,
                fallbackShellCommand: plan.fallbackShellCommand
            ))
            dismiss(returnCode: .OK)
        } catch {
            let presentation = UserFacingErrorPresentation(error)
            statusLabel.stringValue = presentation.message
            statusLabel.toolTip = presentation.detailedText
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func cancel() { dismiss(returnCode: .cancel) }

    private func dismiss(returnCode: NSApplication.ModalResponse) {
        guard let panel = window else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: returnCode)
        } else {
            panel.close()
            finishDismissal()
        }
    }

    private func finishDismissal() {
        guard !didFinish else { return }
        didFinish = true
        onDismiss?()
        onDismiss = nil
    }
}

extension NodeShellConfigurationWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { validateForm() }
}
