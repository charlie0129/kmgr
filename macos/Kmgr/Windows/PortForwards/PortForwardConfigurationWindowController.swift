import AppKit
import Darwin
import KmgrCore

/// Native, target-pinned configuration sheet for one app-owned port-forward.
/// The Kubernetes object is read only to offer declared ports; the helper
/// performs another authoritative UID check before it opens the listener.
@MainActor
final class PortForwardConfigurationWindowController: NSWindowController,
    NSWindowDelegate, NSTextFieldDelegate
{
    private struct DeclaredPort: Hashable {
        var protocolName: String
        var number: UInt16
        var name: String

        var menuTitle: String {
            name.isEmpty
                ? "\(number)/\(protocolName)"
                : "\(name) — \(number)/\(protocolName)"
        }
    }

    private enum BindAddressKind {
        case loopback
        case nonLoopback
        case invalid
    }

    private struct Draft {
        var remotePort: UInt16
        var localPort: UInt16
        var bindAddress: String
        var label: String
        var bindKind: BindAddressKind
    }

    private let session: OpenedClusterSession
    private let targetIdentity: ResourceIdentity
    private let objectDetailProvider: any ObjectDetailProviding
    private let coordinator: PortForwardCoordinator

    private let declaredPortButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let remotePortField = TechnicalTextField()
    private let localPortField = TechnicalTextField()
    private let bindAddressField = TechnicalTextField()
    private let labelField = TechnicalTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let startButton = NSButton(title: "Start", target: nil, action: nil)

    private var declaredPorts: [DeclaredPort] = []
    private var contentStack: NSStackView?
    private var loadTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var loadStarted = false
    private var localPortWasEdited = false
    private var hasStartAttempted = false
    private var isStarting = false
    private var didFinish = false
    private var didStartSuccessfully = false

    var onDismiss: (() -> Void)?
    var onStartSucceeded: (() -> Void)?

    init(
        session: OpenedClusterSession,
        targetIdentity: ResourceIdentity,
        objectDetailProvider: any ObjectDetailProviding,
        coordinator: PortForwardCoordinator
    ) {
        self.session = session
        self.targetIdentity = targetIdentity
        self.objectDetailProvider = objectDetailProvider
        self.coordinator = coordinator

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        panel.title = "\(clusterPresentation.titlePrefix) — Start Port Forward"
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
        validateForm()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        loadTask?.cancel()
        startTask?.cancel()
    }

    func beginSheet(for parent: NSWindow) {
        guard let panel = window, panel.sheetParent == nil else { return }
        parent.beginSheet(panel) { [weak self] _ in
            self?.finishDismissal()
        }
        panel.makeFirstResponder(remotePortField)
        loadDeclaredPortsIfNeeded()
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as AnyObject?) === localPortField {
            localPortWasEdited = true
        } else if (obj.object as AnyObject?) === remotePortField {
            updateDefaultLocalPort()
        }
        validateForm()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isStarting else {
            NSSound.beep()
            return false
        }
        if let parent = sender.sheetParent {
            parent.endSheet(sender, returnCode: .cancel)
            return false
        }
        return true
    }

    private func configureContent(in panel: NSPanel) {
        let targetKind = targetIdentity.resource == "services" ? "Service" : "Pod"
        let namespace = targetIdentity.namespace.isEmpty ? "(cluster scoped)" : targetIdentity.namespace

        let contextValue = identityValue(session.contextName)
        let targetValue = identityValue("\(targetKind) · \(namespace)/\(targetIdentity.name)")
        let uidValue = identityValue(targetIdentity.uid.rawValue, monospaced: true)
        uidValue.lineBreakMode = .byTruncatingMiddle
        uidValue.toolTip = targetIdentity.uid.rawValue

        let identityGrid = NSGridView(views: [
            gridRow("Cluster", identityValue(session.clusterName)),
            gridRow("Context", contextValue),
            gridRow("Target", targetValue),
            gridRow("UID", uidValue),
        ])
        configure(grid: identityGrid)

        declaredPortButton.target = self
        declaredPortButton.action = #selector(declaredPortChanged)
        declaredPortButton.setAccessibilityLabel("Declared remote port")
        declaredPortButton.identifier = .init("port-forward-declared-port")
        declaredPortButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        installDeclaredPortMenu(status: "Loading declared TCP ports…", enabled: false)

        for field in [remotePortField, localPortField, bindAddressField, labelField] {
            field.delegate = self
            field.bezelStyle = .roundedBezel
        }
        remotePortField.placeholderString = "1–65535"
        remotePortField.setAccessibilityLabel("Remote port")
        localPortField.stringValue = "0"
        localPortField.placeholderString = "0 for automatic"
        localPortField.setAccessibilityLabel("Local port")
        bindAddressField.stringValue = "127.0.0.1"
        bindAddressField.placeholderString = "127.0.0.1"
        bindAddressField.setAccessibilityLabel("Bind address")
        labelField.placeholderString = "Optional description"
        labelField.setAccessibilityLabel("Port-forward label")

        let configurationGrid = NSGridView(views: [
            gridRow("Declared port", declaredPortButton),
            gridRow("Remote port", remotePortField),
            gridRow("Local port", localPortField),
            gridRow("Bind address", bindAddressField),
            gridRow("Label", labelField),
        ])
        configure(grid: configurationGrid)

        let localPortHelp = NSTextField(wrappingLabelWithString:
            "Local port defaults to remote. Busy ports try +10,000 fallbacks, then an automatic port; enter 0 to always let the OS choose. Kubernetes port-forward supports TCP."
        )
        localPortHelp.textColor = .secondaryLabelColor
        localPortHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

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
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [
            progressIndicator, statusLabel, NSView(), cancelButton, startButton,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [
            identityGrid, separator, configurationGrid, localPortHelp,
            validationLabel, footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [identityGrid, separator, configurationGrid, localPortHelp, validationLabel, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        contentStack = stack

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            declaredPortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            remotePortField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        panel.contentView = root
    }

    private func configure(grid: NSGridView) {
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    private func gridRow(_ title: String, _ value: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        label.textColor = .secondaryLabelColor
        label.identifier = .init("port-forward-label-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        return [label, value]
    }

    private func identityValue(_ value: String, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        if monospaced {
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        return field
    }

    private func loadDeclaredPortsIfNeeded() {
        guard !loadStarted else { return }
        loadStarted = true
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Refreshing the selected object and loading declared ports…"
        statusLabel.textColor = .secondaryLabelColor
        progressIndicator.startAnimation(nil)
        resizeToFitContent()
        let identity = targetIdentity
        loadTask = Task { [weak self, objectDetailProvider] in
            do {
                let detail = try await objectDetailProvider.getObject(identity: identity)
                guard !Task.isCancelled, let self else { return }
                guard detail.identity == identity else {
                    throw ClusterManagerIssue(
                        category: .conflict,
                        reason: "ObjectIdentityMismatch",
                        message: "The engine returned details for a different Kubernetes object.",
                        contextName: session.contextName,
                        operation: "load declared port-forward ports"
                    )
                }
                installDeclaredPorts(Self.declaredPorts(from: detail.summaryFields))
                if !hasStartAttempted {
                    statusLabel.stringValue = declaredPorts.isEmpty
                        ? "No declared TCP ports were found. Enter a remote port manually."
                        : "Choose a declared port or enter a remote port manually."
                    statusLabel.textColor = .secondaryLabelColor
                    resizeToFitContent()
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
                installDeclaredPorts([])
                if !hasStartAttempted {
                    showIssue(error, prefix: "Declared ports unavailable")
                }
            }
            guard let self else { return }
            if !isStarting {
                progressIndicator.stopAnimation(nil)
            }
            loadTask = nil
        }
    }

    private static func declaredPorts(from fields: [ObjectSummaryField]) -> [DeclaredPort] {
        var result = Set<DeclaredPort>()
        for field in fields where field.sectionID == "ports" {
            let components = field.fieldID.split(separator: ":", omittingEmptySubsequences: false)
            guard components.count == 4, components[0] == "port",
                let number = UInt16(components[2]), number > 0
            else { continue }
            let protocolName = components[1].uppercased()
            // Kubernetes port-forward transports TCP streams. Do not present a
            // UDP/SCTP declaration as though the helper could honor it.
            guard protocolName == "TCP" else { continue }
            let name = String(components[3])
            guard name.count <= 63 else { continue }
            result.insert(DeclaredPort(protocolName: protocolName, number: number, name: name))
        }
        return result.sorted { lhs, rhs in
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.protocolName < rhs.protocolName
        }
    }

    private func installDeclaredPorts(_ values: [DeclaredPort]) {
        declaredPorts = Array(values.prefix(128))
        guard !declaredPorts.isEmpty else {
            installDeclaredPortMenu(status: "No declared TCP ports", enabled: false)
            validateForm()
            return
        }
        declaredPortButton.removeAllItems()
        declaredPortButton.addItem(withTitle: "Choose a declared port…")
        declaredPortButton.item(at: 0)?.isEnabled = false
        declaredPortButton.addItems(withTitles: declaredPorts.map(\.menuTitle))
        declaredPortButton.selectItem(at: 0)
        declaredPortButton.isEnabled = !isStarting
        if remotePortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let first = declaredPorts.first
        {
            remotePortField.stringValue = String(first.number)
            declaredPortButton.selectItem(at: 1)
        }
        updateDefaultLocalPort()
        validateForm()
    }

    private func installDeclaredPortMenu(status: String, enabled: Bool) {
        declaredPortButton.removeAllItems()
        declaredPortButton.addItem(withTitle: status)
        declaredPortButton.isEnabled = enabled
    }

    @objc private func declaredPortChanged() {
        let index = declaredPortButton.indexOfSelectedItem - 1
        guard declaredPorts.indices.contains(index) else { return }
        remotePortField.stringValue = String(declaredPorts[index].number)
        updateDefaultLocalPort()
        validateForm()
    }

    private func updateDefaultLocalPort() {
        guard !localPortWasEdited else { return }
        let remoteText = remotePortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remote = UInt16(remoteText), remote > 0 else { return }
        localPortField.stringValue = String(remote)
    }

    private func draft() -> Draft? {
        let remoteText = remotePortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remote = UInt16(remoteText), remote > 0 else { return nil }
        let localText = localPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let local = UInt16(localText) else { return nil }
        let bindAddress = bindAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindKind = Self.bindAddressKind(bindAddress)
        guard bindKind != .invalid, label.utf8.count <= 128 else { return nil }
        return Draft(
            remotePort: remote,
            localPort: local,
            bindAddress: bindAddress,
            label: label,
            bindKind: bindKind
        )
    }

    private func validationMessage() -> String? {
        guard targetIdentity.clusterSessionID == session.sessionID,
            targetIdentity.group.isEmpty, targetIdentity.version == "v1",
            targetIdentity.resource == "pods" || targetIdentity.resource == "services",
            !targetIdentity.namespace.isEmpty, !targetIdentity.name.isEmpty,
            !targetIdentity.uid.rawValue.isEmpty
        else {
            return "The selected target is not an eligible, session-bound Pod or Service."
        }
        let remoteText = remotePortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteText.isEmpty { return "Remote port is required." }
        guard let remote = UInt16(remoteText), remote > 0 else {
            return "Remote port must be an integer from 1 through 65535."
        }
        let localText = localPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UInt16(localText) != nil else {
            return "Local port must be an integer from 0 through 65535."
        }
        let bindAddress = bindAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.bindAddressKind(bindAddress) == .invalid {
            return "Bind address must be an IPv4 or IPv6 address."
        }
        if labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 128 {
            return "Label must be no more than 128 UTF-8 bytes."
        }
        return nil
    }

    private func validateForm() {
        let message = validationMessage()
        validationLabel.stringValue = message ?? ""
        validationLabel.isHidden = message == nil
        startButton.isEnabled = message == nil && !isStarting
        resizeToFitContent()
    }

    private func resizeToFitContent() {
        guard let panel = window, let contentStack,
            let contentView = panel.contentView
        else { return }
        contentView.layoutSubtreeIfNeeded()
        let targetHeight = ceil(contentStack.fittingSize.height + 34)
        guard abs(contentView.bounds.height - targetHeight) > 0.5 else { return }
        panel.setContentSize(NSSize(width: contentView.bounds.width, height: targetHeight))
        contentView.layoutSubtreeIfNeeded()
    }

    @objc private func start() {
        guard !isStarting, let draft = draft() else {
            validateForm()
            NSSound.beep()
            return
        }
        if draft.bindKind == .nonLoopback {
            confirmNonLoopback(draft)
        } else {
            performStart(draft, allowNonLoopback: false)
        }
    }

    private func confirmNonLoopback(_ draft: Draft) {
        guard let panel = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Expose this port beyond localhost?"
        alert.informativeText = Self.nonLoopbackConfirmationInformativeText(
            session: session,
            target: targetIdentity,
            bindAddress: draft.bindAddress
        )
        alert.addButton(withTitle: "Start Non-Loopback Forward")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performStart(draft, allowNonLoopback: true)
        }
    }

    static func nonLoopbackConfirmationInformativeText(
        session: OpenedClusterSession,
        target: ResourceIdentity,
        bindAddress: String
    ) -> String {
        let identity = ClusterIdentityPresentation(session: session).targetDetails(target)
        return """
        \(identity)
        Bind address: \(bindAddress)

        Other machines may be able to connect, depending on host firewall and network settings.
        """
    }

    private func performStart(_ draft: Draft, allowNonLoopback: Bool) {
        guard !isStarting else { return }
        hasStartAttempted = true
        isStarting = true
        setFormEnabled(false)
        progressIndicator.startAnimation(nil)
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
        statusLabel.toolTip = nil
        statusLabel.textColor = .secondaryLabelColor
        let localDescription = draft.localPort == 0 ? "an automatic local port" : "local port \(draft.localPort)"
        statusLabel.stringValue = "Starting \(draft.bindAddress) on \(localDescription) → remote port \(draft.remotePort)…"
        resizeToFitContent()
        let request = StartPortForwardRequest(
            target: targetIdentity,
            remotePort: draft.remotePort,
            localPort: draft.localPort,
            bindAddress: draft.bindAddress,
            label: draft.label,
            allowNonLoopback: allowNonLoopback
        )
        startTask = Task { [weak self, coordinator] in
            do {
                _ = try await coordinator.start(request)
                guard !Task.isCancelled, let self else { return }
                startTask = nil
                didStartSuccessfully = true
                dismiss(returnCode: .OK)
            } catch is CancellationError {
                guard let self, !didFinish else { return }
                startTask = nil
                isStarting = false
                progressIndicator.stopAnimation(nil)
                setFormEnabled(true)
                statusLabel.stringValue = "Port-forward start was cancelled."
                statusLabel.textColor = .secondaryLabelColor
                validateForm()
            } catch {
                guard !Task.isCancelled, let self else { return }
                startTask = nil
                isStarting = false
                progressIndicator.stopAnimation(nil)
                setFormEnabled(true)
                showIssue(error, prefix: "Port-forward failed")
                validateForm()
            }
        }
    }

    private func setFormEnabled(_ enabled: Bool) {
        for control in [remotePortField, localPortField, bindAddressField, labelField] {
            control.isEnabled = enabled
        }
        declaredPortButton.isEnabled = enabled && !declaredPorts.isEmpty
        cancelButton.isEnabled = enabled
        startButton.isEnabled = enabled && validationMessage() == nil
    }

    private func showIssue(_ error: Error, prefix: String) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = "\(prefix): \(presentation.message)"
            + (presentation.supplementaryText.isEmpty
                ? "" : "\n\(presentation.supplementaryText)")
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
        resizeToFitContent()
    }

    @objc private func cancel() {
        guard !isStarting else {
            NSSound.beep()
            return
        }
        dismiss(returnCode: .cancel)
    }

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
        loadTask?.cancel()
        loadTask = nil
        if !isStarting {
            startTask?.cancel()
            startTask = nil
        }
        progressIndicator.stopAnimation(nil)
        let startSucceeded = didStartSuccessfully ? onStartSucceeded : nil
        onStartSucceeded = nil
        onDismiss?()
        onDismiss = nil
        startSucceeded?()
    }

    private static func bindAddressKind(_ value: String) -> BindAddressKind {
        guard !value.isEmpty, !value.contains("%") else { return .invalid }

        var ipv4 = in_addr()
        let ipv4Result = value.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4)
        }
        if ipv4Result == 1 {
            let firstByte = withUnsafeBytes(of: &ipv4) { bytes in bytes.first }
            return firstByte == 127 ? .loopback : .nonLoopback
        }

        var ipv6 = in6_addr()
        let ipv6Result = value.withCString { pointer in
            inet_pton(AF_INET6, pointer, &ipv6)
        }
        if ipv6Result == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let loopback = bytes.count == 16
                && bytes.dropLast().allSatisfy { $0 == 0 }
                && bytes.last == 1
            return loopback ? .loopback : .nonLoopback
        }
        return .invalid
    }
}
