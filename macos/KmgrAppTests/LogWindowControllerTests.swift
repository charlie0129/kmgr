import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Log windows", .serialized)
struct LogWindowControllerTests {
    @Test("deferred reconciliation never restores tail after a user scroll")
    func deferredTailIntentRequiresCurrentTailPosition() {
        #expect(LogTailReconciliationPolicy.shouldPreserveTail(
            requestedAtScheduleTime: true,
            currentlyAtTail: true
        ))
        #expect(!LogTailReconciliationPolicy.shouldPreserveTail(
            requestedAtScheduleTime: true,
            currentlyAtTail: false
        ))
        #expect(!LogTailReconciliationPolicy.shouldPreserveTail(
            requestedAtScheduleTime: false,
            currentlyAtTail: true
        ))
        #expect(!LogTailReconciliationPolicy.shouldPreserveTail(
            requestedAtScheduleTime: false,
            currentlyAtTail: false
        ))
    }

    @Test("streaming log geometry requests only viewport or bounded tail layout")
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
        let tailRequest = try #require(layoutManager.characterRangeRequests.last)
        #expect(tailRequest.upperBound == storage.length)
        #expect(tailRequest.length <= 512 << 10)
        TextDocumentGeometry.scrollStreamingLogToTail(textView, in: scrollView)
        #expect(textView.selectedRange() == selection)
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))
    }

    @Test("lazy TextKit layout cannot replace streaming log geometry")
    func streamingGeometryOwnsDocumentFrame() throws {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 320)
        )
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 320)
        )
        scrollView.documentView = textView
        TextDocumentGeometry.configureStreamingLog(textView, in: scrollView)

        let chunks = (0..<200).map { "line-\($0) value value value\n" }
        textView.string = chunks.joined()
        let metrics = LogTextLayoutMetrics(
            chunks: chunks,
            wrappingColumnCapacity: TextDocumentGeometry
                .streamingLogWrappingColumnCapacity(textView, in: scrollView)
        )
        TextDocumentGeometry.updateStreamingLog(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            metrics: metrics,
            followingTail: false
        )
        let authoritativeFrame = textView.frame

        let layoutManager = try #require(textView.layoutManager)
        let textLength = try #require(textView.textStorage?.length)
        layoutManager.ensureLayout(forCharacterRange: NSRange(
            location: textLength - 1,
            length: 1
        ))
        #expect(textView.frame == authoritativeFrame)

        TextDocumentGeometry.updateStreamingLog(
            textView,
            in: scrollView,
            wrapsToViewport: false,
            metrics: metrics,
            followingTail: true
        )
        TextDocumentGeometry.scrollStreamingLogToTail(textView, in: scrollView)

        #expect(textView.frame == authoritativeFrame)
        #expect(!textView.isVerticallyResizable)
        #expect(!textView.isHorizontallyResizable)
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))
        #expect(try visibleLogLineFragmentCount(textView, in: scrollView) >= 10)
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

    @Test("16 MiB single log line has bounded tail-layout work")
    func multiMegabyteSingleLineTailLayoutStaysWithinBudget() async throws {
        let fragment = String(repeating: "x", count: 64 << 10)
        let diagnostics = ProcessInfo.processInfo.environment["KMGR_PERF_DIAGNOSTICS"] == "1"
        let sizesMiB = diagnostics ? [4, 16, 32] : [16]
        for sizeMiB in sizesMiB {
            let fragmentCount = (sizeMiB << 20) / fragment.utf8.count
            var displayChunks = [fragment]
            displayChunks.append("\n")
            displayChunks.reserveCapacity(fragmentCount * 3)
            for _ in 1..<fragmentCount {
                displayChunks.append(LogTextRenderer.displayContinuationMarker)
                displayChunks.append(fragment)
                displayChunks.append("\n")
            }

            let textView = NSTextView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 520)
            )
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.font = font
            let scrollView = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 520)
            )
            scrollView.documentView = textView
            TextDocumentGeometry.configureStreamingLog(textView, in: scrollView)
            let capacity = TextDocumentGeometry.streamingLogWrappingColumnCapacity(
                textView,
                in: scrollView
            )
            let (metrics, appendText) = await Task.detached(priority: .userInitiated) {
                (
                    LogTextLayoutMetrics(
                        chunks: displayChunks,
                        wrappingColumnCapacity: capacity
                    ),
                    displayChunks.joined()
                )
            }.value

            let clock = ContinuousClock()
            let installStart = clock.now
            let storage = try #require(textView.textStorage)
            storage.append(NSAttributedString(
                string: appendText,
                attributes: [.font: font]
            ))
            let installDuration = installStart.duration(to: clock.now)
            let tailStart = clock.now
            for _ in 0..<2 {
                TextDocumentGeometry.updateStreamingLog(
                    textView,
                    in: scrollView,
                    wrapsToViewport: false,
                    metrics: metrics,
                    followingTail: true
                )
                TextDocumentGeometry.scrollStreamingLogToTail(textView, in: scrollView)
            }
            TextDocumentGeometry.updateStreamingLog(
                textView,
                in: scrollView,
                wrapsToViewport: false,
                metrics: metrics,
                followingTail: true
            )
            let tailDuration = tailStart.duration(to: clock.now)
            let totalDuration = installStart.duration(to: clock.now)

            if diagnostics {
                print(String(format:
                    "kmgr log diagnostic: %d MiB single line install %.3f ms, tail %.3f ms, total %.3f ms",
                    sizeMiB,
                    milliseconds(installDuration),
                    milliseconds(tailDuration),
                    milliseconds(totalDuration)
                ))
            }
            let mainActorBudget: Duration = sizeMiB <= 16 ? .seconds(1) : .seconds(2)
            #expect(totalDuration < mainActorBudget)
            #expect(storage.length == appendText.utf16.count)
            #expect(metrics.logicalLineCount == fragmentCount + 1)
            #expect(metrics.maximumLineWidthUnits <= fragment.utf8.count + 4)
            #expect(textView.frame.height > scrollView.contentSize.height)
            #expect(scrollView.contentView.bounds.maxY == textView.bounds.maxY)
        }
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

    @Test("log shortcuts drive controls without stealing editable text")
    func logWindowShortcuts() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "production",
                clusterName: "cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let views = descendants(of: root)
        let textView = try #require(views.compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Pod logs" })
        let scrollView = try #require(views.compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "log-content-scroll" })
        let follow = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Follow" })
        let wrap = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Wrap" })
        let pause = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Pause" })
        let search = try #require(views.compactMap { $0 as? NSSearchField }.first)
        let tail = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-tail-lines" })
        let since = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-since-seconds" })

        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitStreaming(generation: 1, sequence: 1)
        try await waitForLogWindowControl(follow, enabled: true)
        #expect(controller.contextualShortcutSnapshot == ContextualShortcutCatalog.logs)
        #expect(window.makeFirstResponder(textView))

        try sendLogWindowKey("p", to: window)
        #expect(pause.title == "Resume")
        try sendLogWindowKey("p", isARepeat: true, to: window)
        #expect(pause.title == "Resume")
        try sendLogWindowKey("p", to: window)
        #expect(pause.title == "Pause")

        try sendLogWindowKey("w", to: window)
        #expect(wrap.state == .on)
        #expect(!scrollView.hasHorizontalScroller)
        try sendLogWindowKey("w", to: window)
        #expect(wrap.state == .off)
        #expect(scrollView.hasHorizontalScroller)

        try sendLogWindowKey("/", to: window)
        #expect(window.firstResponder === search.currentEditor())
        let editableF = try #require(logWindowKeyEvent("f", window: window))
        for field in [search, tail, since] {
            field.selectText(nil)
            #expect((window.firstResponder as? NSTextView)?.isEditable == true)
            #expect(!controller.performLogShortcut(editableF))
        }

        #expect(window.makeFirstResponder(textView))
        try sendLogWindowKey("f", isARepeat: true, to: window)
        #expect(follow.state == .on)
        #expect(!provider.snapshot().contains("start:2"))

        try sendLogWindowKey("f", to: window)
        #expect(follow.state == .off)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        #expect(provider.request(generation: 2)?.options.follow == false)

        // A replacement stream disables its controls. A second press is
        // consumed without mutating the checkbox or starting another stream.
        try sendLogWindowKey("f", to: window)
        #expect(follow.state == .off)
        #expect(!provider.snapshot().contains("start:3"))

        provider.emitStreaming(generation: 2, sequence: 1)
        try await waitForLogWindowControl(follow, enabled: true)
        try sendLogWindowKey("F", modifiers: .shift, to: window)
        #expect(follow.state == .on)
        try await waitForLogWindowEvent(provider) { $0.contains("start:3") }
        #expect(provider.request(generation: 3)?.options.follow == true)
    }

    @Test("log shortcut matching rejects modified and editable input")
    func logShortcutMatching() {
        #expect(LogWindowShortcut.action(
            characters: "F",
            modifiers: .shift,
            textIsEditable: false
        ) == .toggleFollow)
        #expect(LogWindowShortcut.action(
            characters: "p",
            modifiers: .command,
            textIsEditable: false
        ) == nil)
        #expect(LogWindowShortcut.action(
            characters: "w",
            modifiers: .control,
            textIsEditable: false
        ) == nil)
        #expect(LogWindowShortcut.action(
            characters: "/",
            modifiers: .option,
            textIsEditable: false
        ) == nil)
        #expect(LogWindowShortcut.action(
            characters: "f",
            modifiers: [],
            textIsEditable: true
        ) == nil)
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

    @Test("long lines install a short preview while Save keeps the full line")
    func longLinePreviewIsBoundedAndSaveIsLossless() async throws {
        let provider = OrderedLogWindowProvider()
        let writer = LogFileWriterProbe()
        let source = logSource(pod: "api", uid: "api-uid", container: "app")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [source],
            provider: provider,
            displayConfiguration: LogDisplayConfiguration(renderBatchMilliseconds: 1),
            fileWriter: { value, url in
                try writer.write(value, to: url, failure: nil)
            }
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let textView = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Pod logs" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }

        controller.applyDisplayConfiguration(LogDisplayConfiguration(
            renderBatchMilliseconds: 1,
            maximumDisplayedLineUTF8Bytes: 1 << 10
        ))

        window.orderOut(nil)
        provider.emitStreaming(generation: 1, sequence: 1)
        let original = String(repeating: "x", count: 128 << 10)
        provider.emitRecords(
            generation: 1,
            sequence: 2,
            records: [LogRecord(
                sourceID: source.sourceID,
                data: Data(original.utf8),
                startsLine: true,
                endsWithNewline: true
            )]
        )
        try await Task.sleep(for: .milliseconds(50))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) {
            $0.contains(LogTextRenderer.displayTruncationMarker)
        }

        #expect(textView.string.utf8.count < 2 << 10)
        #expect(status.stringValue.contains("1 long line truncated"))
        #expect(status.toolTip?.contains("1 KiB") == true)
        controller.saveVisibleBufferSnapshot(
            to: URL(fileURLWithPath: "/tmp/kmgr-long-line-preview-test.txt")
        )
        try await waitForLogFileWrite(writer)
        let saved = try #require(writer.snapshot)
        #expect(saved.value.utf8.count == original.utf8.count + 1)
        #expect(saved.value.last == "\n")
        #expect(saved.value.dropLast().allSatisfy { $0 == "x" })
        #expect(!saved.ranOnMainThread)
    }

    @Test("continuous tail following keeps the real final line visible")
    func continuousTailFollowKeepsActualTailVisible() async throws {
        let provider = OrderedLogWindowProvider()
        let source = logSource(pod: "api", uid: "api-uid", container: "app")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [source],
            provider: provider,
            displayConfiguration: LogDisplayConfiguration(renderBatchMilliseconds: 1)
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
            records: (0..<200).map { index in
                LogRecord(
                    sourceID: source.sourceID,
                    data: Data("initial-\(index)".utf8),
                    endsWithNewline: true
                )
            }
        )
        try await Task.sleep(for: .milliseconds(50))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { $0.contains("initial-199") }
        #expect(isLogViewAtTail(textView, in: scrollView))
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))
        try await Task.sleep(for: .milliseconds(20))

        provider.emitRecords(
            generation: 1,
            sequence: 3,
            records: [LogRecord(
                sourceID: source.sourceID,
                data: Data("after-correction".utf8),
                endsWithNewline: true
            )]
        )
        try await Task.sleep(for: .milliseconds(20))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { $0.contains("after-correction") }
        #expect(isLogViewAtTail(textView, in: scrollView))
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))
    }

    @Test("large initial tail remains pinned after deferred layout")
    func largeInitialTailRemainsPinnedAfterDeferredLayout() async throws {
        let provider = OrderedLogWindowProvider()
        let source = logSource(pod: "api", uid: "api-uid", container: "app")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [source],
            provider: provider,
            displayConfiguration: LogDisplayConfiguration(renderBatchMilliseconds: 1)
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
        let follow = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Follow" })
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }

        window.orderOut(nil)
        provider.emitStreaming(generation: 1, sequence: 1)
        let suffix = String(repeating: " value", count: 80)
        provider.emitRecords(
            generation: 1,
            sequence: 2,
            records: (0..<500).map { index in
                LogRecord(
                    sourceID: source.sourceID,
                    data: Data("initial-\(index)\(suffix)".utf8),
                    endsWithNewline: true
                )
            }
        )
        try await Task.sleep(for: .milliseconds(50))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { $0.contains("initial-499") }
        #expect(isLogViewAtTail(textView, in: scrollView))
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))

        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(follow.state == .on)
        #expect(isLogViewAtTail(textView, in: scrollView),
            "A deferred layout pass moved the initial tail away from the bottom")
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))
    }

    @Test("viewport scrolling pauses and resumes tail following")
    func viewportPositionControlsTailFollowing() async throws {
        let provider = OrderedLogWindowProvider()
        let source = logSource(pod: "api", uid: "api-uid", container: "app")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [source],
            provider: provider,
            displayConfiguration: LogDisplayConfiguration(renderBatchMilliseconds: 1)
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
        let follow = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Follow" })
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }

        window.orderOut(nil)
        provider.emitStreaming(generation: 1, sequence: 1)
        provider.emitRecords(
            generation: 1,
            sequence: 2,
            records: (0..<200).map { index in
                LogRecord(
                    sourceID: source.sourceID,
                    data: Data("initial-\(index)".utf8),
                    endsWithNewline: true
                )
            }
        )
        try await Task.sleep(for: .milliseconds(50))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { $0.contains("initial-199") }
        #expect(isLogViewAtTail(textView, in: scrollView))
        try await waitForLogWindowControl(follow, enabled: true)
        #expect(follow.state == .on)

        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clipView)
        #expect(!isLogViewAtTail(textView, in: scrollView))
        #expect(follow.state == .off)
        let scrolledAwayOrigin = clipView.bounds.origin

        provider.emitRecords(
            generation: 1,
            sequence: 3,
            records: (0..<100).map { index in
                LogRecord(
                    sourceID: source.sourceID,
                    data: Data("while-scrolled-away-\(index)".utf8),
                    endsWithNewline: true
                )
            }
        )
        try await Task.sleep(for: .milliseconds(20))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { $0.contains("while-scrolled-away-99") }
        #expect(!isLogViewAtTail(textView, in: scrollView))
        #expect(clipView.bounds.origin == scrolledAwayOrigin)

        follow.performClick(nil)
        #expect(follow.state == .on)
        #expect(isLogViewAtTail(textView, in: scrollView))
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!provider.snapshot().contains("start:2"))

        window.setContentSize(NSSize(width: 720, height: 420))
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        #expect(try isActualLogTailFullyVisible(textView, in: scrollView))

        // Returning to the tail manually also re-arms the presentation.
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clipView)
        #expect(follow.state == .off)
        clipView.scroll(to: NSPoint(
            x: clipView.bounds.origin.x,
            y: max(0, textView.bounds.maxY - clipView.bounds.height)
        ))
        scrollView.reflectScrolledClipView(clipView)
        #expect(isLogViewAtTail(textView, in: scrollView))
        #expect(follow.state == .on)

        provider.emitRecords(
            generation: 1,
            sequence: 4,
            records: [LogRecord(
                sourceID: source.sourceID,
                data: Data("after-returning-to-tail".utf8),
                endsWithNewline: true
            )]
        )
        try await Task.sleep(for: .milliseconds(20))
        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(textView) { $0.contains("after-returning-to-tail") }
        #expect(isLogViewAtTail(textView, in: scrollView))
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
        super.ensureLayout(for: textContainer)
    }

    override func ensureLayout(
        forBoundingRect bounds: NSRect,
        in textContainer: NSTextContainer
    ) {
        boundingRectRequests.append(bounds)
        super.ensureLayout(forBoundingRect: bounds, in: textContainer)
    }

    override func ensureLayout(forCharacterRange charRange: NSRange) {
        characterRangeRequests.append(charRange)
        super.ensureLayout(forCharacterRange: charRange)
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
private func sendLogWindowKey(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = [],
    isARepeat: Bool = false,
    to window: NSWindow
) throws {
    window.sendEvent(try #require(logWindowKeyEvent(
        characters,
        modifiers: modifiers,
        isARepeat: isARepeat,
        window: window
    )))
}

@MainActor
private func logWindowKeyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = [],
    isARepeat: Bool = false,
    window: NSWindow
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters.lowercased(),
        isARepeat: isARepeat,
        keyCode: 0
    )
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

@MainActor
private func isLogViewAtTail(_ textView: NSTextView, in scrollView: NSScrollView) -> Bool {
    scrollView.contentView.bounds.maxY >= textView.bounds.maxY - 4
}

@MainActor
private func visibleLogLineFragmentCount(
    _ textView: NSTextView,
    in scrollView: NSScrollView
) throws -> Int {
    let layoutManager = try #require(textView.layoutManager)
    let textLength = try #require(textView.textStorage?.length)
    guard textLength > 0 else { return 0 }

    let characterRange = NSRange(
        location: max(0, textLength - (512 << 10)),
        length: min(textLength, 512 << 10)
    )
    layoutManager.ensureLayout(forCharacterRange: characterRange)
    let glyphRange = layoutManager.glyphRange(
        forCharacterRange: characterRange,
        actualCharacterRange: nil
    )
    let origin = textView.textContainerOrigin
    let visible = scrollView.contentView.bounds.offsetBy(
        dx: -origin.x,
        dy: -origin.y
    )
    var count = 0
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
        rect, _, _, _, _ in
        if rect.intersects(visible) { count += 1 }
    }
    if !layoutManager.extraLineFragmentRect.isEmpty,
        layoutManager.extraLineFragmentRect.intersects(visible)
    {
        count += 1
    }
    return count
}

@MainActor
private func isActualLogTailFullyVisible(
    _ textView: NSTextView,
    in scrollView: NSScrollView
) throws -> Bool {
    let layoutManager = try #require(textView.layoutManager)
    let textLength = try #require(textView.textStorage?.length)
    guard textLength > 0 else { return true }

    let characterRange = NSRange(location: textLength - 1, length: 1)
    layoutManager.ensureLayout(forCharacterRange: characterRange)
    let glyphRange = layoutManager.glyphRange(
        forCharacterRange: characterRange,
        actualCharacterRange: nil
    )
    let finalGlyph = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
    var tailRect = layoutManager.lineFragmentRect(
        forGlyphAt: finalGlyph,
        effectiveRange: nil
    )
    if !layoutManager.extraLineFragmentRect.isEmpty {
        tailRect = tailRect.union(layoutManager.extraLineFragmentRect)
    }
    tailRect = tailRect.offsetBy(
        dx: textView.textContainerOrigin.x,
        dy: textView.textContainerOrigin.y
    )
    let visible = scrollView.contentView.bounds
    return tailRect.minY >= visible.minY - 0.5
        && tailRect.maxY <= visible.maxY + 0.5
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
    private var recordedRequests: [LogStreamRequest] = []
    private var continuations: [UInt64: AsyncThrowingStream<LogStreamMessage, Error>.Continuation] = [:]

    func streamLogs(request: LogStreamRequest)
        -> AsyncThrowingStream<LogStreamMessage, Error> {
        return AsyncThrowingStream { continuation in
            lock.withLock {
                continuations[request.generation] = continuation
                recordedRequests.append(request)
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

    func request(generation: UInt64) -> LogStreamRequest? {
        lock.withLock { recordedRequests.first { $0.generation == generation } }
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
