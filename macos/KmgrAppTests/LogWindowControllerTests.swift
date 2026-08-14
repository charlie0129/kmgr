import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Log windows", .serialized)
struct LogWindowControllerTests {
    @Test("streaming log geometry requests only viewport or tail layout")
    func streamingGeometryNeverRequestsWholeContainerLayout() throws {
        let storage = NSTextStorage()
        let layoutManager = LayoutRequestSpy()
        let textContainer = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 420),
            textContainer: textContainer
        )
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 420)
        )
        scrollView.documentView = textView
        TextDocumentGeometry.configureStreamingLog(textView, in: scrollView)

        let chunks = (0..<8_000).map { "line-\($0) value value value\n" }
        textView.string = chunks.joined()
        let capacity = TextDocumentGeometry.streamingLogWrappingColumnCapacity(
            textView,
            in: scrollView
        )
        let metrics = LogTextLayoutMetrics(
            chunks: chunks,
            wrappingColumnCapacity: capacity
        )
        textView.setSelectedRange(NSRange(location: 137, length: 23))
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin

        layoutManager.resetRequests()
        TextDocumentGeometry.updateStreamingLog(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            metrics: metrics,
            followingTail: false
        )

        #expect(layoutManager.wholeContainerRequestCount == 0)
        #expect(layoutManager.characterRangeRequests.isEmpty)
        let viewportRequest = try #require(layoutManager.boundingRectRequests.last)
        #expect(viewportRequest.height <= scrollView.contentSize.height * 3 + 1)
        #expect(textView.selectedRange() == selection)
        #expect(scrollView.contentView.bounds.origin == origin)
        #expect(textView.frame.height > scrollView.contentSize.height)

        layoutManager.resetRequests()
        TextDocumentGeometry.updateStreamingLog(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            metrics: metrics,
            followingTail: true
        )
        #expect(layoutManager.wholeContainerRequestCount == 0)
        #expect(layoutManager.boundingRectRequests.isEmpty)
        #expect(layoutManager.characterRangeRequests == [NSRange(
            location: storage.length - 1,
            length: 1
        )])
        #expect(textView.selectedRange() == selection)
    }

    @Test("detached log metrics handle chunked CRLF and wrapped lines")
    func logLayoutMetricsMeasureWithoutRetainingText() {
        let metrics = LogTextLayoutMetrics(
            chunks: ["ab\r", "\n12345\n", ""],
            wrappingColumnCapacity: 3
        )

        #expect(metrics.logicalLineCount == 3)
        #expect(metrics.maximumLineWidthUnits == 5)
        #expect(metrics.totalLineWidthUnits == 7)
        #expect(metrics.measuredVisualLineCount == 4)
        #expect(metrics.estimatedVisualLineCount(wrappingColumnCapacity: 3) == 4)
        #expect(!Mirror(reflecting: metrics).children.contains { $0.value is String })
    }

    @Test("16 MiB streaming geometry remains viewport-bounded on MainActor")
    func largeStreamingGeometryStaysWithinBudget() async {
        let line = String(repeating: "x", count: 95) + "\n"
        let source = String(repeating: line, count: (16 << 20) / line.utf8.count)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 520)
        )
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 520)
        )
        scrollView.documentView = textView
        TextDocumentGeometry.configureStreamingLog(textView, in: scrollView)
        let capacity = TextDocumentGeometry.streamingLogWrappingColumnCapacity(
            textView,
            in: scrollView
        )
        let metrics = await Task.detached(priority: .userInitiated) {
            LogTextLayoutMetrics(
                chunks: [source],
                wrappingColumnCapacity: capacity
            )
        }.value
        textView.string = source

        let clock = ContinuousClock()
        let start = clock.now
        TextDocumentGeometry.updateStreamingLog(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            metrics: metrics,
            followingTail: false
        )
        let duration = start.duration(to: clock.now)

        if ProcessInfo.processInfo.environment["KMGR_PERF_DIAGNOSTICS"] == "1" {
            let components = duration.components
            let milliseconds = Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            print(String(format:
                "kmgr log geometry diagnostic: 16 MiB viewport update %.3f ms",
                milliseconds
            ))
        }
        #expect(duration < .seconds(1))
        #expect(textView.frame.height > scrollView.contentSize.height)
    }

    @Test("log streams remain independent ephemeral windows")
    func logWindowIsIndependentAndNotRestored() throws {
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "production",
                clusterName: "cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: NoopLogWindowProvider()
        )
        let window = try #require(controller.window)

        #expect(window.tabbingMode == .disallowed)
        #expect(!window.isRestorable)
    }

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
        #expect(label.stringValue.contains("Cluster: cluster · Context: production"))
        #expect(label.stringValue.contains("team-a/api/app"))
        #expect(label.stringValue.contains("team-a/worker/sidecar"))
        #expect(label.toolTip == label.stringValue)
        #expect(controller.window?.title.contains("2 sources") == true)
        #expect(controller.window?.title.contains("cluster — production") == true)
    }

    @Test("live toolbar exposes container tail and since controls and static scope")
    func liveStreamControlsRemainAvailable() throws {
        let app = logSource(pod: "api", uid: "api-uid", container: "app")
        let sidecar = logSource(pod: "api", uid: "api-uid", container: "sidecar")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "production",
                clusterName: "cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            sources: [app],
            availableSources: [app, sidecar],
            provider: NoopLogWindowProvider(),
            options: LogOptions(sinceSeconds: 60, tailLines: 200),
            staticWorkloadSnapshot: true
        )

        let root = try #require(controller.window?.contentView)
        let views = descendants(of: root)
        let container = try #require(views.compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "log-container" })
        let tail = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-tail-lines" })
        let since = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-since-seconds" })
        let sources = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Log sources" })

        #expect(container.itemTitles == ["All Containers", "app", "sidecar"])
        #expect(tail.stringValue == "200")
        #expect(since.stringValue == "60")
        #expect(sources.stringValue.contains("Static workload Pod snapshot"))
        #expect(sources.stringValue.contains("reopen Logs to refresh"))
    }

    @Test("All Containers is disabled when it exceeds the bounded stream limit")
    func oversizedAllContainersCannotMisrepresentTheActiveStream() throws {
        let allSources = (0..<65).flatMap { index in
            [
                logSource(pod: "pod-\(index)", uid: "uid-\(index)", container: "app"),
                logSource(pod: "pod-\(index)", uid: "uid-\(index)", container: "sidecar"),
            ]
        }
        let appSources = allSources.filter { $0.container == "app" }
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: appSources,
            availableSources: allSources,
            provider: NoopLogWindowProvider()
        )

        let root = try #require(controller.window?.contentView)
        let container = try #require(descendants(of: root).compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "log-container" })
        #expect(container.titleOfSelectedItem == "app")
        #expect(container.item(withTitle: "All Containers")?.isEnabled == false)
        #expect(container.toolTip?.contains("128-stream limit") == true)
    }

    @Test("replacement stream starts before the established generation is retired")
    func replacementStartsBeforePriorCancellation() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider
        )
        controller.showWindow(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitStreaming(generation: 1, sequence: 1)

        let root = try #require(controller.window?.contentView)
        let apply = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Apply" })
        try await waitForLogWindowControl(apply, enabled: true)
        apply.performClick(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        var events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))

        provider.emitConnecting(generation: 2)
        try await waitForLogWindowEvent(provider) {
            $0.contains("cancel:1") && $0.contains("terminated:1")
        }
        events = provider.snapshot()
        #expect(events.firstIndex(of: "start:2")! < events.firstIndex(of: "cancel:1")!)
        #expect(events.firstIndex(of: "start:2")! < events.firstIndex(of: "terminated:1")!)
        controller.close()
    }

    @Test("records downloaded before the log window becomes key are rendered")
    func earlyDownloadedRecordsRenderAfterVisibilityWake() async throws {
        let provider = OrderedLogWindowProvider()
        let app = logSource(pod: "api", uid: "api-uid", container: "app")
        let sidecar = logSource(pod: "api", uid: "api-uid", container: "sidecar")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [app, sidecar],
            provider: provider,
            displayConfiguration: LogDisplayConfiguration(renderBatchMilliseconds: 30)
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let textView = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Pod logs" })
        let scrollView = try #require(descendants(of: root)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "log-content-scroll" })
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }

        window.orderOut(nil)
        provider.emitStreaming(generation: 1, sequence: 1)
        provider.emitRecords(
            generation: 1,
            sequence: 2,
            records: [
                LogRecord(
                    sourceID: app.sourceID, data: Data("hello".utf8),
                    endsWithNewline: true
                ),
                LogRecord(
                    sourceID: sidecar.sourceID, data: Data("ready".utf8),
                    endsWithNewline: true
                ),
            ]
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(textView.string.isEmpty)

        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { value in
            value.contains("[app] hello") && value.contains("[sidecar] ready")
        }
        root.layoutSubtreeIfNeeded()
        let laidOutText = try #require(laidOutLogTextRect(in: textView))
        #expect(textView.frame.width >= scrollView.contentSize.width)
        #expect(textView.frame.height >= scrollView.contentSize.height)
        #expect(textView.frame.intersects(scrollView.contentView.bounds))
        #expect(laidOutText.width > 0)
        #expect(laidOutText.height > 0)
        #expect(laidOutText.intersects(textView.visibleRect))
    }

    @Test("failed replacement restores controls without retiring established stream")
    func failedReplacementRestoresAppliedConfiguration() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider
        )
        controller.showWindow(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitConnecting(generation: 1)

        let root = try #require(controller.window?.contentView)
        let follow = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Follow" })
        try await waitForLogWindowControl(follow, enabled: true)
        #expect(follow.state == .on)
        follow.performClick(nil)
        #expect(follow.state == .off)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        provider.fail(generation: 2)
        for _ in 0..<200 {
            if follow.state == .on { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(follow.state == .on)
        let events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))
        controller.close()
    }

    @Test("first failure message does not retire the established stream")
    func firstFailureMessagePreservesEstablishedGeneration() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitStreaming(generation: 1, sequence: 1)

        let root = try #require(controller.window?.contentView)
        let follow = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Follow" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        try await waitForLogWindowControl(follow, enabled: true)
        #expect(follow.state == .on)

        follow.performClick(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        provider.emitFailureMessage(generation: 2, message: "new options rejected")
        try await waitForLogWindowControl(follow, enabled: true)
        try await waitForLogStatus(status) { $0.contains("new options rejected") }

        #expect(follow.state == .on)
        var events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))
        #expect(events.contains("cancel:2"))

        // The prior generation remains admitted by the unchanged stream gate.
        provider.emitStreaming(generation: 1, sequence: 2)
        try await waitForLogStatus(status) { $0 == "Streaming" }
        events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))
    }

    @Test("rapid Apply clicks serialize replacement generations")
    func rapidApplyClicksDoNotOverlapPendingStarts() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider
        )
        controller.showWindow(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitConnecting(generation: 1)

        let root = try #require(controller.window?.contentView)
        let apply = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Apply" })
        try await waitForLogWindowControl(apply, enabled: true)
        apply.performClick(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        #expect(!apply.isEnabled)
        apply.performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!provider.snapshot().contains("start:3"))

        provider.fail(generation: 2)
        for _ in 0..<200 {
            if apply.isEnabled { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(apply.isEnabled)
        let events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))
        controller.close()
    }

    @Test("replacement ending before its first event restores established configuration")
    func emptyReplacementRestoresAppliedConfiguration() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider
        )
        controller.showWindow(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitConnecting(generation: 1)

        let root = try #require(controller.window?.contentView)
        let follow = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Follow" })
        try await waitForLogWindowControl(follow, enabled: true)
        follow.performClick(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        provider.finish(generation: 2)
        for _ in 0..<200 {
            if follow.state == .on { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(follow.state == .on)
        let events = provider.snapshot()
        #expect(!events.contains("cancel:1"))
        #expect(!events.contains("terminated:1"))
        controller.close()
    }

    @Test("visible log saves snapshot on main and write the snapshot off main")
    func visibleBufferSaveRunsFileIOOffMain() async throws {
        let probe = LogFileWriterProbe()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: NoopLogWindowProvider(),
            fileWriter: { value, url in
                try probe.write(value, to: url, failure: nil)
            }
        )
        let root = try #require(controller.window?.contentView)
        let textView = try #require(descendants(of: root).compactMap { $0 as? NSTextView }.first)
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        let original = String(repeating: "multi-megabyte-log-line", count: 100_000)
        textView.string = original
        let destination = URL(fileURLWithPath: "/tmp/kmgr-log-snapshot-test.txt")

        controller.saveVisibleBufferSnapshot(to: destination)
        #expect(status.stringValue == "Saving kmgr-log-snapshot-test.txt…")
        #expect(!probe.isFinished)
        textView.string = "new text rendered while the save is running"

        try await waitForLogFileWrite(probe)
        let write = try #require(probe.snapshot)
        #expect(write.value == original)
        #expect(write.url == destination)
        #expect(!write.ranOnMainThread)
        try await waitForLogStatus(status) { $0.hasPrefix("Saved ") }
        #expect(status.textColor == .secondaryLabelColor)
    }

    @Test("log save failures return to the main actor for status presentation")
    func visibleBufferSaveFailureUpdatesStatus() async throws {
        let probe = LogFileWriterProbe()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: NoopLogWindowProvider(),
            fileWriter: { value, url in
                try probe.write(value, to: url, failure: .rejected)
            }
        )
        let root = try #require(controller.window?.contentView)
        let textView = try #require(descendants(of: root).compactMap { $0 as? NSTextView }.first)
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        textView.string = "snapshot that cannot be written"

        controller.saveVisibleBufferSnapshot(to: URL(fileURLWithPath: "/tmp/rejected.txt"))
        try await waitForLogFileWrite(probe)
        try await waitForLogStatus(status) { $0.contains("Save failed") }

        #expect(probe.snapshot?.ranOnMainThread == false)
        #expect(status.stringValue.contains("test writer rejected the save"))
        #expect(status.textColor == .systemRed)
    }
}
}

private final class LayoutRequestSpy: NSLayoutManager {
    private(set) var wholeContainerRequestCount = 0
    private(set) var boundingRectRequests: [NSRect] = []
    private(set) var characterRangeRequests: [NSRange] = []

    override func ensureLayout(for textContainer: NSTextContainer) {
        wholeContainerRequestCount += 1
    }

    override func ensureLayout(
        forBoundingRect bounds: NSRect,
        in textContainer: NSTextContainer
    ) {
        boundingRectRequests.append(bounds)
    }

    override func ensureLayout(forCharacterRange charRange: NSRange) {
        characterRangeRequests.append(charRange)
    }

    func resetRequests() {
        wholeContainerRequestCount = 0
        boundingRectRequests.removeAll(keepingCapacity: true)
        characterRangeRequests.removeAll(keepingCapacity: true)
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

@MainActor
private func laidOutLogTextRect(in textView: NSTextView) -> NSRect? {
    guard let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer
    else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).offsetBy(
        dx: textView.textContainerOrigin.x,
        dy: textView.textContainerOrigin.y
    )
}

private struct NoopLogWindowProvider: LogStreamProviding {
    func streamLogs(request: LogStreamRequest)
        -> AsyncThrowingStream<LogStreamMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async {}
}

private final class OrderedLogWindowProvider: LogStreamProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var continuations: [UInt64: AsyncThrowingStream<LogStreamMessage, Error>.Continuation] = [:]

    func streamLogs(request: LogStreamRequest)
        -> AsyncThrowingStream<LogStreamMessage, Error> {
        return AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[request.generation] = continuation
                recordedEvents.append("start:\(request.generation)")
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock {
                    continuations.removeValue(forKey: request.generation)
                    recordedEvents.append("terminated:\(request.generation)")
                }
            }
        }
    }

    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async {
        lock.withLock { recordedEvents.append("cancel:\(generation)") }
    }

    func emitConnecting(generation: UInt64) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.yield(.status(
            cursor: StreamCursor(generation: generation, sequence: 1),
            status: LogStatus(state: .connecting)
        ))
    }

    func emitStreaming(generation: UInt64, sequence: UInt64) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.yield(.status(
            cursor: StreamCursor(generation: generation, sequence: sequence),
            status: LogStatus(state: .streaming)
        ))
    }

    func emitRecords(generation: UInt64, sequence: UInt64, records: [LogRecord]) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.yield(.records(
            cursor: StreamCursor(generation: generation, sequence: sequence),
            records: records,
            totalBytes: UInt64(records.reduce(0) { $0 + $1.data.count })
        ))
    }

    func emitFailureMessage(generation: UInt64, message: String) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.yield(.failure(
            cursor: StreamCursor(generation: generation, sequence: 1),
            issue: ClusterManagerIssue(
                category: .unavailable,
                reason: "ReplacementRejected",
                message: message,
                retryable: true,
                contextName: "production",
                operation: "stream Pod logs"
            )
        ))
    }

    func fail(generation: UInt64) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.finish(throwing: OrderedLogWindowProviderError.rejected)
    }

    func finish(generation: UInt64) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.finish()
    }

    func snapshot() -> [String] {
        lock.withLock { recordedEvents }
    }
}

private enum OrderedLogWindowProviderError: Error {
    case rejected
}

private enum LogFileWriterTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "The test writer rejected the save." }
}

private final class LogFileWriterProbe: @unchecked Sendable {
    struct Snapshot {
        var value: String
        var url: URL
        var ranOnMainThread: Bool
    }

    private let lock = NSLock()
    private var recordedSnapshot: Snapshot?
    private var finished = false

    var snapshot: Snapshot? { lock.withLock { recordedSnapshot } }

    var isFinished: Bool { lock.withLock { finished } }

    func write(
        _ value: String,
        to url: URL,
        failure: LogFileWriterTestError?
    ) throws {
        lock.withLock {
            recordedSnapshot = Snapshot(
                value: value,
                url: url,
                ranOnMainThread: Thread.isMainThread
            )
        }
        Thread.sleep(forTimeInterval: 0.04)
        defer { lock.withLock { finished = true } }
        if let failure { throw failure }
    }
}

@MainActor
private func waitForLogWindowEvent(
    _ provider: OrderedLogWindowProvider,
    condition: ([String]) -> Bool
) async throws {
    for _ in 0..<200 {
        if condition(provider.snapshot()) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for log window event; got \(provider.snapshot())")
}

@MainActor
private func waitForLogWindowControl(
    _ control: NSControl,
    enabled: Bool
) async throws {
    for _ in 0..<200 {
        if control.isEnabled == enabled { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for log control enabled=\(enabled)")
}

@MainActor
private func waitForLogText(
    _ textView: NSTextView,
    condition: (String) -> Bool
) async throws {
    for _ in 0..<200 {
        if condition(textView.string) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for rendered log text; got \(textView.string)")
}

@MainActor
private func waitForLogFileWrite(_ probe: LogFileWriterProbe) async throws {
    for _ in 0..<300 {
        if probe.isFinished { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for the log file writer")
}

@MainActor
private func waitForLogStatus(
    _ status: NSTextField,
    condition: (String) -> Bool
) async throws {
    for _ in 0..<300 {
        if condition(status.stringValue) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for log status; got \(status.stringValue)")
}
