import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Terminal windows", .serialized)
struct TerminalWindowControllerTests {
    @Test("long terminal identities do not widen the window")
    func longIdentityStaysWithinWindow() throws {
        let controller = TerminalWindowController(
            request: execRequest(
                command: ["/bin/sh"],
                contextName: String(repeating: "context-", count: 80),
                clusterName: String(repeating: "cluster-", count: 30),
                namespace: String(repeating: "n", count: 63),
                podName: String(repeating: "p", count: 63),
                container: String(repeating: "c", count: 63)
            ),
            provider: OrderedExecProvider()
        )
        defer { closeTerminal(controller) }
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        window.toolbar?.validateVisibleItems()
        let identity = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "terminal.identity"
        }?.view as? NSTextField)

        #expect(window.contentLayoutRect.width <= 900.5)
        #expect(identity.lineBreakMode == .byTruncatingMiddle)
    }

    @Test("fallback waits for server acceptance before retiring the previous generation")
    func fallbackReplacesLiveLease() async throws {
        let provider = OrderedExecProvider()
        let controller = TerminalWindowController(
            request: execRequest(command: ["/bin/bash"]),
            provider: provider,
            fallbackShellCommand: ["/bin/sh"]
        )
        controller.showWindow(nil)
        defer { closeTerminal(controller) }
        try await waitForExecEvent(provider) { $0.contains("opened:1") }

        provider.emitStatus(
            generation: 1,
            status: ExecStatus(state: .exited, exitCode: 127, statusReason: "not found")
        )
        try await waitForExecEvent(provider) { $0.contains("opened:2") }
        try await Task.sleep(for: .milliseconds(30))
        var events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))

        provider.emitStatus(
            generation: 2,
            status: ExecStatus(state: .running, statusReason: "Running")
        )
        try await waitForExecEvent(provider) {
            $0.contains("cancel:1") && $0.contains("terminated:1")
        }

        events = provider.snapshot()
        let openedReplacement = try #require(events.firstIndex(of: "opened:2"))
        let acceptedReplacement = try #require(events.firstIndex(of: "emit:2"))
        let cancelledOriginal = try #require(events.firstIndex(of: "cancel:1"))
        let terminatedOriginal = try #require(events.firstIndex(of: "terminated:1"))
        #expect(openedReplacement < acceptedReplacement)
        #expect(acceptedReplacement < cancelledOriginal)
        #expect(acceptedReplacement < terminatedOriginal)
        let replacement = try #require(provider.request(generation: 2))
        #expect(replacement.command == ["/bin/sh"])
        #expect(replacement.execSessionID == "exec-session")

        let status = try terminalStatus(in: controller)
        try await waitForTerminalControl(status) { $0.stringValue == "Connected" }
        try await Task.sleep(for: .milliseconds(30))
        #expect(status.stringValue == "Connected")
    }

    @Test("failed reconnect retains the established lease and stale cleanup cannot clear its retry")
    func reconnectGenerationGuardsCleanup() async throws {
        let provider = OrderedExecProvider(failingGenerations: [2])
        let controller = TerminalWindowController(
            request: execRequest(command: ["/bin/sh"]),
            provider: provider
        )
        controller.showWindow(nil)
        defer { closeTerminal(controller) }
        try await waitForExecEvent(provider) { $0.contains("opened:1") }

        provider.emitStatus(
            generation: 1,
            status: ExecStatus(state: .exited, exitCode: 0, statusReason: "complete")
        )
        let reconnect = try terminalReconnectButton(in: controller)
        try await waitForTerminalControl(reconnect) { $0.isEnabled }
        reconnect.performClick(nil)
        try await waitForExecEvent(provider) { $0.contains("failed:2") }
        try await waitForTerminalControl(reconnect) { $0.isEnabled }
        let status = try terminalStatus(in: controller)
        try await waitForTerminalControl(status) {
            $0.stringValue == "Cluster unavailable"
        }
        #expect(status.toolTip?.contains("The replacement exec stream was rejected.") == true)
        #expect(status.toolTip?.contains("Operation: exec Pod") == true)
        #expect(status.toolTip?.contains("Context: production") == true)
        #expect(status.toolTip?.contains("Reason: ReplacementRejected") == true)
        #expect(status.toolTip?.contains("Retryable") == true)

        var events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))

        reconnect.performClick(nil)
        try await waitForExecEvent(provider) { $0.contains("opened:3") }
        try await Task.sleep(for: .milliseconds(30))
        events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))
        let openedRetry = try #require(events.firstIndex(of: "opened:3"))

        provider.emitStatus(
            generation: 3,
            status: ExecStatus(state: .running, statusReason: "Running")
        )
        try await waitForExecEvent(provider) {
            $0.contains("cancel:1") && $0.contains("terminated:1")
        }
        events = provider.snapshot()
        let acceptedRetry = try #require(events.firstIndex(of: "emit:3"))
        let cancelledOriginal = try #require(events.firstIndex(of: "cancel:1"))
        #expect(openedRetry < acceptedRetry)
        #expect(acceptedRetry < cancelledOriginal)
        try await waitForTerminalControl(status) { $0.stringValue == "Connected" }
        try await Task.sleep(for: .milliseconds(30))
        #expect(status.stringValue == "Connected")
        #expect(status.toolTip == "Running")
        #expect(!reconnect.isEnabled)
    }

    @Test("Control-D closes the window after the remote process confirms exit")
    func controlDClosesAfterConfirmedExit() async throws {
        let provider = OrderedExecProvider()
        let controller = TerminalWindowController(
            request: execRequest(command: ["/bin/sh"]),
            provider: provider
        )
        var closeCount = 0
        controller.onClose = { closeCount += 1 }
        controller.showWindow(nil)
        defer {
            if controller.window?.isVisible == true { closeTerminal(controller) }
        }
        try await waitForExecEvent(provider) { $0.contains("opened:1") }
        provider.emitStatus(
            generation: 1,
            status: ExecStatus(state: .running, statusReason: "Running")
        )
        let connectedStatus = try terminalStatus(in: controller)
        try await waitForTerminalControl(connectedStatus) {
            $0.stringValue == "Connected"
        }

        try sendControlD(to: controller)
        try await waitForExecEvent(provider) { $0.contains("stdin:1:04") }
        #expect(controller.window?.isVisible == true)
        #expect(closeCount == 0)

        provider.emitStatus(
            generation: 1,
            status: ExecStatus(state: .exited, exitCode: 0, statusReason: "complete")
        )
        try await waitForTerminalWindowClose(controller)
        #expect(closeCount == 1)
    }

    @Test("Control-D does not close on a failed or disconnected session")
    func controlDDoesNotCloseOnFailure() async throws {
        let provider = OrderedExecProvider()
        let controller = TerminalWindowController(
            request: execRequest(command: ["/bin/sh"]),
            provider: provider
        )
        var closeCount = 0
        controller.onClose = { closeCount += 1 }
        controller.showWindow(nil)
        defer { closeTerminal(controller) }
        try await waitForExecEvent(provider) { $0.contains("opened:1") }
        provider.emitStatus(
            generation: 1,
            status: ExecStatus(state: .running, statusReason: "Running")
        )
        let connectedStatus = try terminalStatus(in: controller)
        try await waitForTerminalControl(connectedStatus) {
            $0.stringValue == "Connected"
        }
        try sendControlD(to: controller)
        try await waitForExecEvent(provider) { $0.contains("stdin:1:04") }

        provider.emitStatus(
            generation: 1,
            status: ExecStatus(
                state: .failed,
                statusReason: "transport failed",
                issue: ClusterManagerIssue(
                    category: .unavailable,
                    reason: "ExecDisconnected",
                    message: "The terminal disconnected from the engine.",
                    retryable: true
                )
            )
        )
        let status = try terminalStatus(in: controller)
        try await waitForTerminalControl(status) {
            $0.stringValue == "Cluster unavailable"
        }
        #expect(controller.window?.isVisible == true)
        #expect(closeCount == 0)
    }

    @Test("dropped output remains a warning without ending the terminal")
    func droppedOutputWarnsWithoutEndingSession() async throws {
        let provider = OrderedExecProvider()
        let controller = TerminalWindowController(
            request: execRequest(command: ["/bin/sh"]),
            provider: provider
        )
        controller.showWindow(nil)
        defer { closeTerminal(controller) }
        try await waitForExecEvent(provider) { $0.contains("opened:1") }

        provider.emitStatus(
            generation: 1,
            status: ExecStatus(
                state: .running,
                statusReason: "Running",
                droppedOutputItems: 2,
                droppedOutputBytes: 8
            )
        )
        let status = try terminalStatus(in: controller)
        try await waitForTerminalControl(status) {
            $0.stringValue == "Connected — Output dropped"
        }
        #expect(status.textColor == .systemOrange)
        #expect(status.toolTip?.contains("2 output chunks (8 bytes)") == true)
        #expect(status.toolTip?.contains("remote process is still running") == true)
        #expect(!(try terminalReconnectButton(in: controller)).isEnabled)
    }
}
}

private func execRequest(
    command: [String],
    contextName: String = "production",
    clusterName: String = "cluster-a",
    namespace: String = "team-a",
    podName: String = "api",
    container: String = "app"
) -> ExecSessionRequest {
    ExecSessionRequest(
        sessionID: "cluster-session",
        execSessionID: "exec-session",
        generation: 1,
        target: .pod(PodExecDestination(
            pod: ResourceIdentity(
                clusterSessionID: "cluster-session",
                group: "",
                version: "v1",
                resource: "pods",
                namespace: namespace,
                name: podName,
                uid: ResourceUID("pod-uid")
            ),
            container: container
        )),
        contextName: contextName,
        clusterName: clusterName,
        command: command
    )
}

@MainActor
private func terminalStatus(
    in controller: TerminalWindowController
) throws -> NSTextField {
    let item = try #require(controller.window?.toolbar?.items.first {
        $0.itemIdentifier.rawValue == "terminal.status"
    })
    return try #require(item.view as? NSTextField)
}

@MainActor
private func terminalReconnectButton(
    in controller: TerminalWindowController
) throws -> NSButton {
    let item = try #require(controller.window?.toolbar?.items.first {
        $0.itemIdentifier.rawValue == "terminal.reconnect"
    })
    return try #require(item.view as? NSButton)
}

@MainActor
private func closeTerminal(_ controller: TerminalWindowController) {
    guard let window = controller.window else { return }
    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    window.delegate = nil
    controller.close()
}

@MainActor
private func sendControlD(to controller: TerminalWindowController) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control],
        timestamp: 0,
        windowNumber: controller.window?.windowNumber ?? 0,
        context: nil,
        characters: "\u{04}",
        charactersIgnoringModifiers: "d",
        isARepeat: false,
        keyCode: 2
    ))
    let responder = try #require(controller.window?.firstResponder)
    responder.keyDown(with: event)
}

@MainActor
private func waitForTerminalWindowClose(
    _ controller: TerminalWindowController
) async throws {
    for _ in 0..<300 {
        if controller.window?.isVisible == false { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for terminal window to close")
}

private final class OrderedExecProvider: ExecSessionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var requests: [UInt64: ExecSessionRequest] = [:]
    private var sessions: [UInt64: OrderedExecSession] = [:]
    private let failingGenerations: Set<UInt64>

    init(failingGenerations: Set<UInt64> = []) {
        self.failingGenerations = failingGenerations
    }

    func startExec(request: ExecSessionRequest) async throws -> any ExecSession {
        let shouldFail = lock.withLock { () -> Bool in
            requests[request.generation] = request
            recordedEvents.append("start:\(request.generation)")
            return failingGenerations.contains(request.generation)
        }
        if shouldFail {
            lock.withLock { recordedEvents.append("failed:\(request.generation)") }
            throw ClusterManagerIssue(
                category: .unavailable,
                reason: "ReplacementRejected",
                message: "The replacement exec stream was rejected.",
                retryable: true,
                contextName: request.contextName,
                operation: "exec Pod"
            )
        }
        let session = OrderedExecSession(generation: request.generation) { [weak self] event in
            self?.lock.withLock { self?.recordedEvents.append(event) }
        }
        lock.withLock {
            sessions[request.generation] = session
            recordedEvents.append("opened:\(request.generation)")
        }
        return session
    }

    func emitStatus(generation: UInt64, status: ExecStatus) {
        let session = lock.withLock {
            recordedEvents.append("emit:\(generation)")
            return sessions[generation]
        }
        session?.emit(.status(
            cursor: StreamCursor(generation: generation, sequence: 1),
            status: status
        ))
    }

    func snapshot() -> [String] {
        lock.withLock { recordedEvents }
    }

    func request(generation: UInt64) -> ExecSessionRequest? {
        lock.withLock { requests[generation] }
    }
}

private final class OrderedExecSession: ExecSession, @unchecked Sendable {
    let events: AsyncThrowingStream<ExecServerEvent, Error>
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<ExecServerEvent, Error>.Continuation
    private let generation: UInt64
    private let record: @Sendable (String) -> Void
    private var cancelled = false

    init(generation: UInt64, record: @escaping @Sendable (String) -> Void) {
        let pair = AsyncThrowingStream<ExecServerEvent, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.generation = generation
        self.record = record
        pair.continuation.onTermination = { _ in
            record("terminated:\(generation)")
        }
    }

    func emit(_ event: ExecServerEvent) {
        continuation.yield(event)
    }

    func sendStdin(_ data: Data) async throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        record("stdin:\(generation):\(hex)")
    }

    func resize(_ size: TerminalSize) async throws {}

    func closeStdin() async throws {}

    func cancel() async {
        let shouldCancel = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        record("cancel:\(generation)")
        continuation.finish()
    }
}

@MainActor
private func waitForExecEvent(
    _ provider: OrderedExecProvider,
    condition: ([String]) -> Bool
) async throws {
    for _ in 0..<300 {
        if condition(provider.snapshot()) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for terminal event; got \(provider.snapshot())")
}

@MainActor
private func waitForTerminalControl<Control: NSControl>(
    _ control: Control,
    condition: (Control) -> Bool
) async throws {
    for _ in 0..<300 {
        if condition(control) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for terminal control state")
}
