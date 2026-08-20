import AppKit
import KmgrCore
import SwiftTerm

/// One remote process in one independent window. Reconnect always asks the
/// provider to create a new generation; this controller never reuses a dead
/// stream or persists terminal contents.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let terminalController: RemoteTerminalViewController
    private let request: ExecSessionRequest
    var onClose: (() -> Void)?

    init(
        request: ExecSessionRequest,
        provider: any ExecSessionProviding,
        fallbackShellCommand: [String]? = nil
    ) {
        self.request = request
        terminalController = RemoteTerminalViewController(
            request: request,
            provider: provider,
            fallbackShellCommand: fallbackShellCommand
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(
            clusterName: request.clusterName,
            contextName: request.contextName
        )
        window.title = "\(clusterPresentation.titlePrefix) — Terminal — \(request.pod.name)"
        window.subtitle = Self.subtitle(for: request)
        window.minSize = NSSize(width: 560, height: 360)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = terminalController
        window.toolbar = terminalController.makeToolbar()
        terminalController.onConfirmedEOFExit = { [weak self] in
            self?.window?.performClose(nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalWindowController is programmatic")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        terminalController.start()
        window?.makeFirstResponder(terminalController.terminalView)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard terminalController.remoteProcessIsActive else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close active terminal?"
        alert.informativeText = Self.closeConfirmationInformativeText(for: request)
        alert.addButton(withTitle: "Close Terminal")
        alert.addButton(withTitle: "Keep Open")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func prepareForTermination() {
        terminalController.stop()
    }

    func windowWillClose(_ notification: Notification) {
        prepareForTermination()
        onClose?()
    }

    private static func subtitle(for request: ExecSessionRequest) -> String {
        let namespace = request.pod.namespace.isEmpty ? "default" : request.pod.namespace
        return "\(namespace)/\(request.pod.name) · \(request.container)"
    }

    static func closeConfirmationInformativeText(for request: ExecSessionRequest) -> String {
        let clusterPresentation = ClusterIdentityPresentation(
            clusterName: request.clusterName,
            contextName: request.contextName
        )
        return """
        \(clusterPresentation.targetDetails(request.pod))
        Container: \(request.container)

        Closing this window will terminate the remote process.
        """
    }
}

@MainActor
private final class RemoteTerminalViewController: NSViewController, @preconcurrency TerminalViewDelegate,
    NSToolbarDelegate
{
    let terminalView: TerminalView
    let podDisplayName: String
    var onConfirmedEOFExit: (() -> Void)?

    private let baseRequest: ExecSessionRequest
    private let provider: any ExecSessionProviding
    private let fallbackShellCommand: [String]?
    private let statusLabel = NSTextField(labelWithString: "Not connected")
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private var generation: UInt64
    private var activeGeneration: UInt64?
    private var connectionGeneration: UInt64?
    private var session: (any ExecSession)?
    private var streamTask: Task<Void, Never>?
    // A replacement session is only locally constructed until its first valid
    // server event. Keep the previous generation alive across that interval so
    // the backend can transfer its retained cluster-session authority even
    // after the originating workspace has closed.
    private var retainedSession: (any ExecSession)?
    private var retainedStreamTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<TerminalCommand>.Continuation?
    private var state: ExecConnectionState?
    private var activeCommand: [String]
    private var currentAttemptProducedOutput = false
    private var usedFallbackShell = false
    private var lastIssue: ClusterManagerIssue?
    private var lastExitCode: Int32?
    private var lastSentSize: TerminalSize?
    private var eofAutoClosePolicy = TerminalEOFAutoClosePolicy()
    private var stopped = false

    var remoteProcessIsActive: Bool {
        state == .connecting || state == .running
    }

    init(
        request: ExecSessionRequest,
        provider: any ExecSessionProviding,
        fallbackShellCommand: [String]? = nil
    ) {
        baseRequest = request
        self.provider = provider
        self.fallbackShellCommand = fallbackShellCommand
        generation = request.generation
        activeCommand = request.command
        podDisplayName = request.pod.namespace.isEmpty
            ? request.pod.name : "\(request.pod.namespace)/\(request.pod.name)"
        var options = TerminalOptions.default
        options.cols = Int(request.initialSize?.columns ?? 80)
        options.rows = Int(request.initialSize?.rows ?? 24)
        options.scrollback = 10_000
        options.termName = "xterm-256color"
        terminalView = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 550),
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            options: options
        )
        super.init(nibName: nil, bundle: nil)
        terminalView.terminalDelegate = self
        terminalView.configureNativeColors()
        terminalView.setAccessibilityLabel("Terminal for \(podDisplayName), container \(request.container)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RemoteTerminalViewController is programmatic")
    }

    override func loadView() {
        let root = NSView()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: root.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "remote-terminal")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func start() {
        guard session == nil, connectionTask == nil, !stopped else { return }
        connect()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        connectionTask?.cancel()
        connectionTask = nil
        connectionGeneration = nil
        streamTask?.cancel()
        streamTask = nil
        retainedStreamTask?.cancel()
        retainedStreamTask = nil
        stopCommandPump()
        let activeSession = session
        let previousSession = retainedSession
        session = nil
        retainedSession = nil
        activeGeneration = nil
        if activeSession != nil || previousSession != nil {
            Task {
                await activeSession?.cancel()
                await previousSession?.cancel()
            }
        }
    }

    private func connect(statusOverride: String? = nil) {
        guard connectionTask == nil, !stopped else { return }
        var request = baseRequest
        request.generation = generation
        request.command = activeCommand
        let attemptGeneration = request.generation
        let currentSize = TerminalSize(
            columns: UInt32(clamping: max(1, terminalView.getTerminal().cols)),
            rows: UInt32(clamping: max(1, terminalView.getTerminal().rows))
        )
        request.initialSize = request.tty ? currentSize : nil
        currentAttemptProducedOutput = false
        eofAutoClosePolicy.beginGeneration(attemptGeneration)
        lastIssue = nil
        lastExitCode = nil
        state = .connecting
        updateStatus(ExecStatus(state: .connecting, statusReason: "Connecting"))
        if let statusOverride {
            statusLabel.stringValue = statusOverride
            statusLabel.toolTip = statusOverride
        }
        reconnectButton.isEnabled = false
        connectionGeneration = attemptGeneration
        connectionTask = Task { [weak self, provider] in
            guard let self else { return }
            do {
                let opened = try await provider.startExec(request: request)
                guard !Task.isCancelled, !stopped,
                    connectionGeneration == attemptGeneration,
                    generation == attemptGeneration
                else {
                    await opened.cancel()
                    return
                }
                connectionTask = nil
                connectionGeneration = nil
                install(
                    opened,
                    generation: attemptGeneration,
                    initialSize: currentSize
                )
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                finishConnectionAttempt(
                    generation: attemptGeneration,
                    error: ClusterManagerIssue(
                        category: .unavailable,
                        reason: "ExecStartCancelled",
                        message: "The engine cancelled the terminal connection attempt.",
                        retryable: true,
                        contextName: baseRequest.contextName,
                        operation: "exec Pod"
                    )
                )
            } catch {
                finishConnectionAttempt(
                    generation: attemptGeneration,
                    error: error
                )
            }
        }
    }

    private func reconnect() {
        guard !remoteProcessIsActive, connectionTask == nil, !stopped else { return }
        generation &+= 1
        state = nil
        connect()
    }

    private func finishConnectionAttempt(generation attemptGeneration: UInt64, error: Error) {
        guard connectionGeneration == attemptGeneration else { return }
        connectionTask = nil
        connectionGeneration = nil
        guard !stopped, generation == attemptGeneration else { return }
        applyFailure(error)
        reconnectButton.isEnabled = true
    }

    private func install(
        _ opened: any ExecSession,
        generation attemptGeneration: UInt64,
        initialSize: TerminalSize
    ) {
        guard !stopped, generation == attemptGeneration else {
            Task { await opened.cancel() }
            return
        }
        let previousSession = session ?? retainedSession
        let previousStreamTask = streamTask ?? retainedStreamTask

        session = opened
        activeGeneration = attemptGeneration
        retainedSession = previousSession
        retainedStreamTask = previousStreamTask
        startCommandPump(session: opened, generation: attemptGeneration)
        lastSentSize = initialSize
        streamTask = Task { [weak self] in
            guard let self else {
                await opened.cancel()
                return
            }
            var streamError: Error?
            do {
                for try await event in opened.events {
                    guard !Task.isCancelled else { break }
                    acceptReplacement(generation: attemptGeneration)
                    apply(event, generation: attemptGeneration)
                }
            } catch is CancellationError {
            } catch {
                streamError = error
            }
            finishStream(generation: attemptGeneration, error: streamError)
        }

    }

    private func acceptReplacement(generation attemptGeneration: UInt64) {
        guard activeGeneration == attemptGeneration,
            let previousSession = retainedSession
        else { return }
        let previousStreamTask = retainedStreamTask
        retainedSession = nil
        retainedStreamTask = nil
        previousStreamTask?.cancel()
        Task { await previousSession.cancel() }
    }

    private func finishStream(generation attemptGeneration: UInt64, error: Error?) {
        guard activeGeneration == attemptGeneration else { return }
        session = nil
        activeGeneration = nil
        streamTask = nil
        stopCommandPump()
        guard !stopped, generation == attemptGeneration else { return }

        if let error {
            applyFailure(error)
            if startFallbackShellIfNeeded(from: attemptGeneration) { return }
        } else if state == .connecting || state == .running {
            applyFailure(ClusterManagerIssue(
                category: .unavailable,
                reason: "ExecDisconnected",
                message: "The terminal disconnected from the engine.",
                retryable: true,
                contextName: baseRequest.contextName,
                operation: "exec Pod"
            ))
            if startFallbackShellIfNeeded(from: attemptGeneration) { return }
        }
        reconnectButton.isEnabled = true
    }

    private func shouldTryFallbackShell() -> Bool {
        guard !usedFallbackShell,
            let fallbackShellCommand,
            !fallbackShellCommand.isEmpty,
            fallbackShellCommand != activeCommand,
            !currentAttemptProducedOutput
        else { return false }
        if state == .exited, lastExitCode == 126 || lastExitCode == 127 {
            return true
        }
        guard state == .failed, let lastIssue else { return false }
        // Authentication, replacement, transport, timeout, and capacity
        // failures cannot be repaired by selecting another executable.
        return lastIssue.category == .notFound || lastIssue.category == .internalFailure
    }

    private func apply(_ event: ExecServerEvent, generation attemptGeneration: UInt64) {
        guard activeGeneration == attemptGeneration,
            generation == attemptGeneration
        else { return }
        switch event {
        case .stdout(_, let data), .stderr(_, let data):
            if !data.isEmpty { currentAttemptProducedOutput = true }
            // Feed raw bytes; decoding them as String would corrupt split UTF-8
            // and escape/control sequences.
            terminalView.feed(byteArray: Array(data)[...])
        case .status(_, let status):
            state = status.state
            lastExitCode = status.exitCode
            lastIssue = status.issue
            updateStatus(status)
            reconnectButton.isEnabled = status.state.isTerminal
            if status.state.isTerminal,
                startFallbackShellIfNeeded(from: attemptGeneration)
            {
                return
            }
            if eofAutoClosePolicy.shouldClose(
                after: status,
                generation: attemptGeneration
            ) {
                onConfirmedEOFExit?()
            }
        case .failure(_, let issue):
            state = .failed
            lastIssue = issue
            showIssue(issue)
            reconnectButton.isEnabled = true
            if startFallbackShellIfNeeded(from: attemptGeneration) { return }
        }
    }

    @discardableResult
    private func startFallbackShellIfNeeded(from attemptGeneration: UInt64) -> Bool {
        guard generation == attemptGeneration,
            connectionTask == nil,
            shouldTryFallbackShell()
        else { return false }
        usedFallbackShell = true
        activeCommand = fallbackShellCommand ?? activeCommand
        generation &+= 1
        connect(statusOverride: "\(baseRequest.command[0]) unavailable; trying \(activeCommand[0])")
        return true
    }

    private func applyFailure(_ error: Error) {
        let issue = error as? ClusterManagerIssue ?? ClusterManagerIssue(
            category: .unavailable,
            reason: "ExecDisconnected",
            message: "The terminal disconnected from the engine.",
            retryable: true,
            contextName: baseRequest.contextName,
            operation: "exec Pod"
        )
        state = .failed
        lastIssue = issue
        showIssue(issue)
    }

    private func updateStatus(_ status: ExecStatus) {
        switch status.state {
        case .connecting:
            statusLabel.stringValue = "Connecting"
            statusLabel.textColor = .secondaryLabelColor
        case .running:
            statusLabel.stringValue = "Connected"
            statusLabel.textColor = .systemGreen
        case .exited:
            statusLabel.stringValue = status.exitCode.map { "Exited (\($0))" } ?? "Exited"
            statusLabel.textColor = status.exitCode == 0 ? .secondaryLabelColor : .systemOrange
        case .cancelled:
            statusLabel.stringValue = "Cancelled"
            statusLabel.textColor = .secondaryLabelColor
        case .failed:
            if let issue = status.issue {
                showIssue(issue)
                return
            }
            statusLabel.stringValue = "Failed"
            statusLabel.textColor = .systemRed
        }
        statusLabel.toolTip = status.statusReason.isEmpty ? nil : status.statusReason
    }

    private func showIssue(_ issue: ClusterManagerIssue) {
        let presentation = issue.userFacingPresentation
        statusLabel.stringValue = presentation.title
        statusLabel.textColor = .systemRed
        statusLabel.toolTip = presentation.detailedText
    }

    private func startCommandPump(session: any ExecSession, generation attemptGeneration: UInt64) {
        stopCommandPump()
        let pair = AsyncStream<TerminalCommand>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        commandContinuation = pair.continuation
        commandTask = Task { [weak self] in
            do {
                for await command in pair.stream {
                    try Task.checkCancellation()
                    switch command {
                    case .stdin(let data): try await session.sendStdin(data)
                    case .resize(let size): try await session.resize(size)
                    }
                }
            } catch is CancellationError {
            } catch {
                await self?.handleCommandPumpFailure(
                    error,
                    session: session,
                    generation: attemptGeneration
                )
            }
        }
    }

    private func handleCommandPumpFailure(
        _ error: Error,
        session: any ExecSession,
        generation attemptGeneration: UInt64
    ) async {
        guard activeGeneration == attemptGeneration,
            generation == attemptGeneration
        else { return }
        applyFailure(error)
        await session.cancel()
        stopCommandPump()
    }

    private func stopCommandPump() {
        commandContinuation?.finish()
        commandContinuation = nil
        commandTask?.cancel()
        commandTask = nil
    }

    private func enqueue(_ command: TerminalCommand) {
        guard let commandContinuation else { return }
        switch commandContinuation.yield(command) {
        case .enqueued:
            break
        case .dropped:
            applyFailure(ClusterManagerIssue(
                category: .resourceExhausted,
                reason: "TerminalInputBufferExceeded",
                message: "Terminal input arrived faster than it could be sent. Reconnect to start a new process.",
                retryable: true,
                contextName: baseRequest.contextName,
                operation: "send terminal input"
            ))
            if let session { Task { await session.cancel() } }
            stopCommandPump()
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let payload = Data(data)
        if commandContinuation != nil, activeGeneration == generation {
            eofAutoClosePolicy.observeInput(payload, generation: generation)
        }
        enqueue(.stdin(payload))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard baseRequest.tty, newCols > 0, newRows > 0 else { return }
        let size = TerminalSize(
            columns: UInt32(clamping: newCols),
            rows: UInt32(clamping: newRows)
        )
        guard size != lastSentSize else { return }
        lastSentSize = size
        enqueue(.resize(size))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Keep immutable cluster/Pod/container identity in the native title.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.identity, .flexibleSpace, .status, .reconnect]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.identity, .flexibleSpace, .status, .reconnect]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .identity:
            let clusterPresentation = ClusterIdentityPresentation(
                clusterName: baseRequest.clusterName,
                contextName: baseRequest.contextName
            )
            let label = NSTextField(
                labelWithString: "\(clusterPresentation.titlePrefix) · \(podDisplayName) · \(baseRequest.container)"
            )
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = "\(clusterPresentation.labeledInline), Pod \(podDisplayName), container \(baseRequest.container)"
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Target"
            item.view = label
            return item
        case .status:
            statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Status"
            item.view = statusLabel
            return item
        case .reconnect:
            reconnectButton.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: "Reconnect terminal"
            )
            reconnectButton.target = self
            reconnectButton.action = #selector(reconnectPressed)
            reconnectButton.bezelStyle = .texturedRounded
            reconnectButton.isEnabled = false
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reconnect"
            item.view = reconnectButton
            return item
        default:
            return nil
        }
    }

    @objc private func reconnectPressed() {
        reconnect()
    }
}

private enum TerminalCommand: Sendable {
    case stdin(Data)
    case resize(TerminalSize)
}

private extension NSToolbarItem.Identifier {
    static let identity = Self("terminal.identity")
    static let status = Self("terminal.status")
    static let reconnect = Self("terminal.reconnect")
}
