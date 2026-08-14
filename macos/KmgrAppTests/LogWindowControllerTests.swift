import AppKit
import KmgrCore
import Testing
@testable import Kmgr

@MainActor
@Suite("Log windows", .serialized)
struct LogWindowControllerTests {
    @Test("exact context and every source remain visible above the buffer")
    func exactSourcesRemainVisible() throws {
        let sources = [
            logSource(pod: "api", uid: "api-uid", container: "app"),
            logSource(pod: "worker", uid: "worker-uid", container: "sidecar"),
        ]
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "production",
                clusterName: "cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            sources: sources,
            provider: NoopLogWindowProvider()
        )

        let root = try #require(controller.window?.contentView)
        let label = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Log sources" })
        #expect(label.stringValue.contains("Context: production"))
        #expect(label.stringValue.contains("team-a/api/app"))
        #expect(label.stringValue.contains("team-a/worker/sidecar"))
        #expect(label.toolTip == label.stringValue)
        #expect(controller.window?.title.contains("2 sources") == true)
    }
}

private func logSource(pod: String, uid: String, container: String) -> LogSource {
    let identity = ResourceIdentity(
        clusterSessionID: "session",
        group: "",
        version: "v1",
        resource: "pods",
        namespace: "team-a",
        name: pod,
        uid: ResourceUID(uid)
    )
    return LogSource(
        identity: identity,
        container: container,
        sourceID: "\(uid)/\(container)",
        label: "team-a/\(pod)/\(container)"
    )
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants(of:))
}

private struct NoopLogWindowProvider: LogStreamProviding {
    func streamLogs(request: LogStreamRequest)
        -> AsyncThrowingStream<LogStreamMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async {}
}
