import AppKit
import KmgrCore
import SwiftTerm

/// One remote process in one independent window. Reconnect always asks the
/// provider to create a new generation; this controller never reuses a dead
/// stream or persists terminal contents.
@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let terminalController: RemoteTerminalViewController
    var onClose: (() -> Void)?

    init(request: ExecSessionRequest, provider: any ExecSessionProviding) {
        terminalController = RemoteTerminalViewController(request: request, provider: provider)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(request.pod.name) — \(Product.applicationName)"
        window.subtitle = Self.subtitle(for: request)
        window.minSize = NSSize(width: 560, height: 360)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = terminalController
        window.toolbar = terminalController.makeToolbar()
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
        alert.informativeText = "Closing this window will terminate the remote process in \(terminalController.podDisplayName)."
        alert.addButton(withTitle: "Close Terminal")
        alert.addButton(withTitle: "Keep Open")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        terminalController.stop()
        onClose?()
    }

    private static func subtitle(for request: ExecSessionRequest) -> String {
        let namespace = request.pod.namespace.isEmpty ? "default" : request.pod.namespace
        return "\(request.contextName) · \(namespace)/\(request.pod.name) · \(request.container)"
    }
}

@MainActor
private final class RemoteTerminalViewController: NSViewController, @preconcurrency TerminalViewDelegate,
    NSToolbarDelegate
{
    let terminalView: TerminalView
    let podDisplayName: String

    private let baseRequest: ExecSessionRequest
    private let provider: any ExecSessionProviding
    private let statusLabel = NSTextField(labelWithString: "Not connected")
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private var generation: UInt64
    private var session: (any ExecSession)?
    private var streamTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<TerminalCommand>.Continuation?
    private var state: ExecConnectionState?
    private var lastSentSize: TerminalSize?
    private var stopped = false

    var remoteProcessIsActive: Bool {
        state == .connecting || state == .running
    }

    init(request: ExecSessionRequest, provider: any ExecSessionProviding) {
        baseRequest = request
        self.provider = provider
        generation = request.generation
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
        guard streamTask == nil, !stopped else { return }
        connect()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        streamTask?.cancel()
        streamTask = nil
        stopCommandPump()
        if let session {
            Task { await session.cancel() }
        }
        session = nil
    }

    private func connect() {
        var request = baseRequest
        request.generation = generation
        let currentSize = TerminalSize(
            columns: UInt32(clamping: max(1, terminalView.getTerminal().cols)),
            rows: UInt32(clamping: max(1, terminalView.getTerminal().rows))
        )
        request.initialSize = request.tty ? currentSize : nil
        state = .connecting
        updateStatus(ExecStatus(state: .connecting, statusReason: "Connecting"))
        reconnectButton.isEnabled = false
        streamTask = Task { [weak self, provider] in
            guard let self else { return }
            do {
                let opened = try await provider.startExec(request: request)
                guard !Task.isCancelled, !stopped else {
                    await opened.cancel()
                    return
                }
                session = opened
                startCommandPump(session: opened)
                lastSentSize = currentSize
                for try await event in opened.events {
                    guard !Task.isCancelled else { break }
                    apply(event)
                }
            } catch is CancellationError {
                // Normal window close or explicit reconnect.
            } catch {
                applyFailure(error)
            }
            stopCommandPump()
            session = nil
            streamTask = nil
            if state == .connecting || state == .running {
                state = .failed
                statusLabel.stringValue = "Disconnected"
                statusLabel.textColor = .systemRed
            }
            reconnectButton.isEnabled = !stopped
        }
    }

    private func reconnect() {
        guard !remoteProcessIsActive else { return }
        streamTask?.cancel()
        streamTask = nil
        stopCommandPump()
        generation &+= 1
        state = nil
        connect()
    }

    private func apply(_ event: ExecServerEvent) {
        switch event {
        case .stdout(_, let data), .stderr(_, let data):
            // Feed raw bytes; decoding them as String would corrupt split UTF-8
            // and escape/control sequences.
            terminalView.feed(byteArray: Array(data)[...])
        case .status(_, let status):
            state = status.state
            updateStatus(status)
            reconnectButton.isEnabled = status.state.isTerminal
        case .failure(_, let issue):
            state = .failed
            showIssue(issue)
            reconnectButton.isEnabled = true
        }
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
            if let issue = status.issue { showIssue(issue) }
            else {
                statusLabel.stringValue = "Failed"
                statusLabel.textColor = .systemRed
            }
        }
        statusLabel.toolTip = status.issue?.message ?? status.statusReason
    }

    private func showIssue(_ issue: ClusterManagerIssue) {
        statusLabel.stringValue = issue.presentationTitle
        statusLabel.textColor = .systemRed
        statusLabel.toolTip = issue.message
    }

    private func startCommandPump(session: any ExecSession) {
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
                self?.applyFailure(error)
                await session.cancel()
            }
        }
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
        enqueue(.stdin(Data(data)))
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
            let label = NSTextField(
                labelWithString: "\(baseRequest.contextName) · \(podDisplayName) · \(baseRequest.container)"
            )
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = "Context \(baseRequest.contextName), Pod \(podDisplayName), container \(baseRequest.container)"
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
