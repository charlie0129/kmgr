import Foundation
import GRPCCore
import KmgrCore
import KmgrIPC
import KmgrProto
import Testing

private actor ExecRPCCapture: ExecRPC {
    var sent: [Kmgr_V1_ExecClientMessage] = []
    var responses: [Kmgr_V1_ExecServerMessage] = []
    var expectedOutboundCount = 1

    func setResponses(_ values: [Kmgr_V1_ExecServerMessage]) {
        responses = values
    }

    func expectOutboundMessages(_ count: Int) {
        expectedOutboundCount = count
    }

    func exec(
        outbound: AsyncThrowingStream<Kmgr_V1_ExecClientMessage, Error>,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ExecServerMessage) throws -> Void
    ) async throws {
        var iterator = outbound.makeAsyncIterator()
        for _ in 0..<expectedOutboundCount {
            guard let message = try await iterator.next() else { break }
            sent.append(message)
        }
        for response in responses { try receive(response) }
    }

    func messages() -> [Kmgr_V1_ExecClientMessage] { sent }
}

@Test func execProviderMapsStartInputResizeStatusAndOpaqueOutput() async throws {
    let rpc = ExecRPCCapture()
    var stdout = Kmgr_V1_ExecServerMessage()
    stdout.cursor.streamID = "terminal-1"
    stdout.cursor.generation = 4
    stdout.cursor.sequence = 1
    stdout.stdout = Data([0xff, 0, 0x1b, 0x5b])
    var status = Kmgr_V1_ExecServerMessage()
    status.cursor.streamID = "terminal-1"
    status.cursor.generation = 4
    status.cursor.sequence = 2
    status.status.state = .exited
    status.status.exitCode = 17
    status.status.statusReason = "NonZeroExit"
    status.status.droppedOutputItems = 3
    status.status.droppedOutputBytes = 12_345
    await rpc.setResponses([stdout, status])
    await rpc.expectOutboundMessages(4)

    let provider = EngineExecSessionProvider(
        rpc: rpc,
        streamTimeout: .seconds(20),
        now: { Date(timeIntervalSince1970: 1_000) },
        requestID: { "request-1" }
    )
    let request = makeRequest()
    let session = try await provider.startExec(request: request)
    try await session.sendStdin(Data([0, 0xff, 0x61]))
    try await session.resize(TerminalSize(columns: 132, rows: 50))
    try await session.closeStdin()

    var events: [ExecServerEvent] = []
    for try await event in session.events { events.append(event) }
    #expect(events.count == 2)
    guard case .stdout(let cursor, let data) = events[0] else {
        Issue.record("expected stdout")
        return
    }
    #expect(cursor == StreamCursor(generation: 4, sequence: 1))
    #expect(data == Data([0xff, 0, 0x1b, 0x5b]))
    guard case .status(let statusCursor, let value) = events[1] else {
        Issue.record("expected status")
        return
    }
    #expect(statusCursor == StreamCursor(generation: 4, sequence: 2))
    #expect(value.state == .exited)
    #expect(value.exitCode == 17)
    #expect(value.droppedOutputItems == 3)
    #expect(value.droppedOutputBytes == 12_345)

    let sent = await rpc.messages()
    #expect(sent.count == 4)
    let start = sent[0].start
    #expect(sent[0].sequence == 1)
    #expect(start.context.requestID == "request-1")
    #expect(start.context.clusterSessionID == "cluster-session")
    #expect(start.context.deadlineUnixMs == 1_020_000)
    #expect(start.execSessionID == "terminal-1")
    #expect(start.pod.uid == "pod-uid")
    #expect(start.container == "main")
    #expect(start.command == ["/bin/sh"])
    #expect(start.tty && start.stdin)
    #expect(start.initialColumns == 120 && start.initialRows == 35)
    #expect(sent.map(\.sequence) == [1, 2, 3, 4])
    #expect(sent[1].stdin == Data([0, 0xff, 0x61]))
    #expect(sent[2].resize.columns == 132 && sent[2].resize.rows == 50)
    #expect(sent[3].closeStdin)
}

@Test func execProviderRejectsWrongGenerationBeforeDisplayingBytes() async throws {
    let rpc = ExecRPCCapture()
    var response = Kmgr_V1_ExecServerMessage()
    response.cursor.streamID = "terminal-1"
    response.cursor.generation = 99
    response.cursor.sequence = 1
    response.stdout = Data("stale".utf8)
    await rpc.setResponses([response])
    let provider = EngineExecSessionProvider(rpc: rpc)
    let session = try await provider.startExec(request: makeRequest())
    do {
        for try await _ in session.events {}
        Issue.record("stale generation was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "ExecCursorMismatch")
    }
}

@Test func execProviderDropsOldestBufferedOutputWithoutEndingSession() async throws {
    let rpc = ExecRPCCapture()
    var first = Kmgr_V1_ExecServerMessage()
    first.cursor.streamID = "terminal-1"
    first.cursor.generation = 4
    first.cursor.sequence = 1
    first.stdout = Data("old".utf8)
    var second = Kmgr_V1_ExecServerMessage()
    second.cursor.streamID = "terminal-1"
    second.cursor.generation = 4
    second.cursor.sequence = 2
    second.stdout = Data("new".utf8)
    var terminal = Kmgr_V1_ExecServerMessage()
    terminal.cursor.streamID = "terminal-1"
    terminal.cursor.generation = 4
    terminal.cursor.sequence = 3
    terminal.status.state = .exited
    terminal.status.exitCode = 0
    await rpc.setResponses([first, second, terminal])

    let provider = EngineExecSessionProvider(rpc: rpc, eventMessageLimit: 1)
    let session = try await provider.startExec(request: makeRequest())
    try await Task.sleep(for: .milliseconds(30))
    var events: [ExecServerEvent] = []
    for try await event in session.events { events.append(event) }

    #expect(events.count == 1)
    guard case .status(_, let status) = events[0] else {
        Issue.record("expected newest terminal status")
        return
    }
    #expect(status.state == .exited)
    #expect(status.exitCode == 0)
    #expect(status.droppedOutputItems == 1)
    #expect(status.droppedOutputBytes == 3)
}

@Test func execProviderEncodesNodeShellTargetWithoutPodFields() async throws {
    let rpc = ExecRPCCapture()
    let provider = EngineExecSessionProvider(rpc: rpc)
    let request = ExecSessionRequest(
        sessionID: "cluster-session",
        execSessionID: "node-terminal-1",
        generation: 2,
        target: .nodeShell(NodeShellDestination(
            node: ResourceIdentity(
                clusterSessionID: "cluster-session",
                group: "", version: "v1", resource: "nodes",
                namespace: "", name: "worker-a", uid: "node-uid"
            ),
            namespace: "ops-tools",
            image: "registry.example/node-shell:1"
        )),
        contextName: "production",
        command: ["bash", "-l"]
    )
    let session = try await provider.startExec(request: request)
    for try await _ in session.events {}

    let sent = await rpc.messages()
    let start = try #require(sent.first?.start)
    #expect(!start.hasPod)
    #expect(start.container.isEmpty)
    #expect(start.hasNodeShell)
    #expect(start.nodeShell.node.resource == "nodes")
    #expect(start.nodeShell.node.name == "worker-a")
    #expect(start.nodeShell.node.uid == "node-uid")
    #expect(start.nodeShell.namespace == "ops-tools")
    #expect(start.nodeShell.image == "registry.example/node-shell:1")
    #expect(start.command == ["bash", "-l"])
}

@Test func execSessionRejectsResizeWithoutTTYLocally() async throws {
    let rpc = ExecRPCCapture()
    var request = makeRequest()
    request.tty = false
    request.initialSize = nil
    let provider = EngineExecSessionProvider(rpc: rpc)
    let session = try await provider.startExec(request: request)
    do {
        try await session.resize(TerminalSize(columns: 90, rows: 30))
        Issue.record("non-TTY resize was accepted")
    } catch let issue as ClusterManagerIssue {
        #expect(issue.reason == "ExecResizeWithoutTTY")
    }
    await session.cancel()
}

private func makeRequest() -> ExecSessionRequest {
    ExecSessionRequest(
        sessionID: "cluster-session",
        execSessionID: "terminal-1",
        generation: 4,
        target: .pod(PodExecDestination(
            pod: ResourceIdentity(
                clusterSessionID: "cluster-session",
                group: "",
                version: "v1",
                resource: "pods",
                namespace: "default",
                name: "api-0",
                uid: "pod-uid"
            ),
            container: "main"
        )),
        contextName: "local",
        command: ["/bin/sh"]
    )
}
