import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Log windows", .serialized)
struct LogWindowControllerTests {
    @Test("automatic log retry uses bounded backoff and server hints")
    func automaticRetryPolicy() {
        #expect(LogStreamRetryPolicy.delayMilliseconds(
            failureCount: 1,
            issue: nil
        ) == 250)
        #expect(LogStreamRetryPolicy.delayMilliseconds(
            failureCount: 2,
            issue: nil
        ) == 500)
        #expect(LogStreamRetryPolicy.delayMilliseconds(
            failureCount: 6,
            issue: nil
        ) == 5_000)
        #expect(LogStreamRetryPolicy.delayMilliseconds(
            failureCount: 1,
            issue: ClusterManagerIssue(
                category: .unavailable,
                message: "Wait before retrying.",
                retryable: true,
                retryAfterMilliseconds: 7_000
            )
        ) == 7_000)
    }

    @Test("virtual log rows use immutable, non-overlapping geometry")
    func virtualRowsRemainStableAcrossFastScrolling() throws {
        let chunks = (0..<8_000).map { index in
            "line-\(index) \(String(repeating: "value ", count: index.isMultiple(of: 31) ? 80 : 2))\n"
        }
        let (logView, scrollView) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 700, height: 420
        ))
        let projection = try LogViewportProjection.make(
            chunks: chunks,
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style
        )
        logView.install(projection, viewportSize: scrollView.contentSize)

        #expect(projection.lines.count == 8_001)
        #expect(logView.visualRowCount == 8_001)
        #expect(logView.frame.height > scrollView.contentSize.height)
        let lineHeight = CGFloat(projection.style.lineHeight)
        for index in stride(from: 0, to: logView.visualRowCount - 1, by: 137) {
            let current = logViewportRowRect(index, in: logView)
            let next = logViewportRowRect(index + 1, in: logView)
            #expect(current.maxY == next.minY)
            #expect(current.height == lineHeight)
        }

        let clipView = scrollView.contentView
        for index in stride(from: logView.visualRowCount - 1, through: 0, by: -211) {
            clipView.scroll(to: NSPoint(
                x: 0,
                y: CGFloat(index) * lineHeight
            ))
            scrollView.reflectScrolledClipView(clipView)
            let visibleRows = logViewportVisibleRowRects(logView, in: scrollView)
            #expect(!visibleRows.isEmpty)
            for pair in zip(visibleRows, visibleRows.dropFirst()) {
                #expect(pair.0.maxY == pair.1.minY)
            }
        }
    }

    @Test("newline controls never share one virtual row")
    func virtualRowsSegmentCRLFAcrossStreamingChunks() throws {
        let (logView, _) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 500, height: 300
        ))
        let chunks = ["alpha\r", "\n", "beta\u{2028}gamma\u{0085}", "delta"]
        let projection = try LogViewportProjection.make(
            chunks: chunks,
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style
        )

        #expect(projection.joinedText() == chunks.joined())
        #expect(projection.lines.count == 4)
        #expect(projection.lines.map { projection.substring(in: $0.textRange) } == [
            "alpha", "beta", "gamma", "delta",
        ])
    }

    @Test("only exact object-boundary log lines receive JSON highlighting")
    func JSONHighlightingRequiresExactObjectBoundaries() throws {
        let values = [
            "{\"name\":\"api\",\"replicas\":3,\"ready\":true}",
            "[{\"name\":\"array-root\"}]",
            " {\"name\":\"leading-space\"}",
            "{\"name\":\"trailing-space\"} ",
            "{\"name\":\"wrong-closing-delimiter\"]",
        ]
        let (logView, scrollView) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 800, height: 400
        ))
        let projection = try LogViewportProjection.make(
            chunks: [
                "{\"name\":\"api\",",
                "\"replicas\":3,\"ready\":true}",
                "\n" + values.dropFirst().joined(separator: "\n") + "\n",
            ],
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style
        )

        #expect(projection.lines.prefix(values.count).map(\.hasJSONObjectBoundaries) == [
            true, false, false, false, false,
        ])
        let line = projection.lines[0]
        let highlight = projection.jsonHighlight(
            inLine: 0,
            intersecting: 0..<line.cellCount
        )
        func texts(for kind: SyntaxTokenKind) -> [String] {
            highlight.tokens.filter { $0.kind == kind }.map {
                projection.substring(in: $0.range)
            }
        }
        #expect(texts(for: .key) == ["\"name\"", "\"replicas\"", "\"ready\""])
        #expect(texts(for: .string) == ["\"api\""])
        #expect(texts(for: .number) == ["3"])
        #expect(texts(for: .keyword) == ["true"])
        for lineIndex in 1..<values.count {
            let plainLine = projection.lines[lineIndex]
            let plain = projection.jsonHighlight(
                inLine: lineIndex,
                intersecting: 0..<plainLine.cellCount
            )
            #expect(plain.tokens.isEmpty)
            #expect(plain.scannedUTF16Length == 0)
        }

        logView.install(projection, viewportSize: scrollView.contentSize)
        let bitmap = try #require(
            logView.bitmapImageRepForCachingDisplay(in: logView.bounds)
        )
        logView.cacheDisplay(in: logView.bounds, to: bitmap)
        #expect(logView.lastJSONTokenCount == highlight.tokens.count)
        #expect(logView.lastJSONScannedUTF16Length == line.textRange.length)

        let wrappedWidth = CGFloat(projection.style.cellWidth * 12)
            + logView.textContainerInset.width * 2
        logView.setWrapsLines(
            true,
            viewportSize: NSSize(width: wrappedWidth, height: 400)
        )
        let wrappedBitmap = try #require(
            logView.bitmapImageRepForCachingDisplay(in: logView.bounds)
        )
        logView.cacheDisplay(in: logView.bounds, to: wrappedBitmap)
        #expect(logView.visualRowCount > projection.lines.count)
        #expect(logView.lastJSONTokenCount > 0)
    }

    @Test("tail scrolling always exposes the complete final empty row")
    func virtualTailIsFullyVisibleAfterResize() throws {
        let chunks = (0..<500).map { index in
            "line-\(index) \(String(repeating: "long-value-", count: 80))\n"
        }
        let (logView, scrollView) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 560, height: 320
        ))
        let projection = try LogViewportProjection.make(
            chunks: chunks,
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style
        )
        logView.install(projection, viewportSize: scrollView.contentSize)

        for size in [
            NSSize(width: 560, height: 320),
            NSSize(width: 900, height: 510),
            NSSize(width: 480, height: 260),
        ] {
            scrollView.setFrameSize(size)
            logView.updateDocumentFrame(for: scrollView.contentSize)
            scrollLogViewportToTail(logView, in: scrollView)
            #expect(isLogViewAtTail(logView, in: scrollView))
            #expect(isActualLogTailFullyVisible(logView, in: scrollView))
        }
    }

    @Test("16 MiB single line uses arithmetic width and virtual horizontal drawing")
    func multiMegabyteSingleLineProjectionStaysVirtual() async throws {
        let targetLength = 16 << 20
        let prefix = "{\"value\":\""
        let suffix = "\"}"
        let value = prefix
            + String(
                repeating: "x",
                count: targetLength - prefix.utf8.count - suffix.utf8.count
            )
            + suffix
        let chunks = [value, "\n"]
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let style = LogViewportTextStyle(font: font)
        let clock = ContinuousClock()
        let start = clock.now
        let projection = try LogViewportProjection.make(
            chunks: chunks,
            previous: nil,
            retainedChunkCount: 0,
            style: style
        )
        let duration = start.duration(to: clock.now)

        #expect(duration < .milliseconds(10))
        #expect(projection.textUTF16Length == (16 << 20) + 1)
        #expect(projection.lines.count == 2)
        #expect(projection.maximumWidth > 100_000_000)
        #expect(projection.maximumCellCount == 16 << 20)
        #expect(projection.lines[0].indexedVariableBoundaryCount == 0)
        #expect(projection.lines[0].hasJSONObjectBoundaries)

        let (logView, scrollView) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 800, height: 520
        ))
        let installStart = clock.now
        logView.install(projection, viewportSize: scrollView.contentSize)
        let installDuration = installStart.duration(to: clock.now)
        #expect(installDuration < .milliseconds(100))
        #expect(logView.string.utf16.count == projection.textUTF16Length)
        #expect(logView.frame.width > scrollView.contentSize.width)

        let farRight = NSRect(
            x: max(0, logView.bounds.maxX - 800),
            y: logView.textContainerInset.height,
            width: 800,
            height: CGFloat(projection.style.lineHeight)
        )
        let bitmap = try #require(
            logView.bitmapImageRepForCachingDisplay(in: farRight)
        )
        let drawStart = clock.now
        logView.cacheDisplay(in: farRight, to: bitmap)
        #expect(drawStart.duration(to: clock.now) < .milliseconds(100))
        #expect(logView.lastDrawnCellCount < 256)
        #expect(logView.lastJSONTokenCount > 0)
        #expect(
            logView.lastJSONScannedUTF16Length
                <= LogViewportProjection.maximumJSONHighlightCells
        )

        let appendedChunks = chunks + ["tail\n"]
        let appendStart = clock.now
        let appended = try await Task.detached(priority: .userInitiated) {
            try LogViewportProjection.make(
                chunks: appendedChunks,
                previous: projection,
                retainedChunkCount: chunks.count,
                style: style
            )
        }.value
        #expect(appendStart.duration(to: clock.now) < .milliseconds(100))
        #expect(appended.lines.count == 3)
        #expect(appended.joinedText().hasSuffix("\ntail\n"))
    }

    @Test("fixed Unicode cells wrap arithmetically without changing copied text")
    func fixedUnicodeCellsWrapWithoutMaterializedRows() throws {
        let (logView, scrollView) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 500, height: 300
        ))
        let value = "A🐈界e\u{301}BCDEFG\n"
        let projection = try LogViewportProjection.make(
            chunks: [value],
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style
        )
        logView.install(projection, viewportSize: scrollView.contentSize)

        #expect(projection.lines.count == 2)
        #expect(projection.lines[0].cellCount == 10)
        #expect(projection.lines[0].indexedVariableBoundaryCount == 2)
        #expect(projection.maximumWidth
            == Double(10) * projection.style.cellWidth)

        let widthForFourCells = CGFloat(projection.style.cellWidth * 4)
            + logView.textContainerInset.width * 2
        logView.setWrapsLines(
            true,
            viewportSize: NSSize(width: widthForFourCells, height: 300)
        )
        #expect(logView.wrappingColumnCapacity == 4)
        #expect(logView.visualRowCount == 4)
        #expect((0..<3).map { logView.visualRowText(at: $0) } == [
            "A🐈界e\u{301}", "BCDE", "FG",
        ])
        #expect(logView.string == value)

        let bitmap = try #require(logView.bitmapImageRepForCachingDisplay(
            in: logView.bounds
        ))
        logView.cacheDisplay(in: logView.bounds, to: bitmap)
        #expect(logView.lastDrawnCellCount == 10)
        #expect(logView.lastDrawnUnicodeCellCount == 3)
    }

    @Test("filter matches are highlighted case-insensitively across soft wraps")
    func filterMatchesAreHighlightedAcrossSoftWraps() throws {
        let (logView, _) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 500, height: 300
        ))
        let value = "before ERROR after error\n"
        let projection = try LogViewportProjection.make(
            chunks: [value],
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style,
            highlightedText: "error"
        )
        let widthForNineCells = CGFloat(projection.style.cellWidth * 9)
            + logView.textContainerInset.width * 2
        logView.install(
            projection,
            viewportSize: NSSize(width: widthForNineCells, height: 300)
        )
        logView.setWrapsLines(
            true,
            viewportSize: NSSize(width: widthForNineCells, height: 300)
        )

        let highlighted = (0..<logView.visualRowCount).flatMap {
            logView.filterHighlightRanges(forVisualRow: $0)
        }
        let unique = Set(highlighted.map { "\($0.location):\($0.length)" })
        #expect(unique.count == 2)
        #expect(highlighted.allSatisfy {
            (value as NSString).substring(with: $0).lowercased() == "error"
        })
    }

    @Test("virtual logs remain selectable and copy exact text")
    func virtualLogSelectionAndCopy() throws {
        let (logView, scrollView) = makeLogViewport(frame: NSRect(
            x: 0, y: 0, width: 500, height: 300
        ))
        let chunks = ["alpha ", "🐈", "\n", "beta\n"]
        let projection = try LogViewportProjection.make(
            chunks: chunks,
            previous: nil,
            retainedChunkCount: 0,
            style: logView.projection.style
        )
        logView.install(projection, viewportSize: scrollView.contentSize)
        let range = (projection.joinedText() as NSString).range(of: "🐈\nbeta")
        logView.setSelectedRange(range)

        NSPasteboard.general.clearContents()
        logView.copy(nil)

        #expect(logView.selectedRange() == range)
        #expect(NSPasteboard.general.string(forType: .string) == "🐈\nbeta")
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
        let logView = try #require(views.compactMap { $0 as? LogViewportView }
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
        #expect(window.makeFirstResponder(logView))

        try sendLogWindowKey("p", to: window)
        #expect(pause.title == "Resume")
        try sendLogWindowKey("p", isARepeat: true, to: window)
        #expect(pause.title == "Resume")
        try sendLogWindowKey("p", to: window)
        #expect(pause.title == "Pause")

        try sendLogWindowKey("w", to: window)
        #expect(wrap.state == .on)
        #expect(logView.wrapsLines)
        #expect(!scrollView.hasHorizontalScroller)
        try sendLogWindowKey("w", to: window)
        #expect(wrap.state == .off)
        #expect(!logView.wrapsLines)
        #expect(scrollView.hasHorizontalScroller)

        try sendLogWindowKey("/", to: window)
        #expect(window.firstResponder === search.currentEditor())
        let editableF = try #require(logWindowKeyEvent("f", window: window))
        for field in [search, tail, since] {
            field.selectText(nil)
            #expect((window.firstResponder as? NSTextView)?.isEditable == true)
            #expect(!controller.performLogShortcut(editableF))
        }

        #expect(window.makeFirstResponder(logView))
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
            modifiers: [],
            textIsEditable: false
        ) == .toggleWrap)
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

    @Test("many log sources truncate without widening the window")
    func longSourceSummaryStaysWithinWindow() throws {
        let sources = (0..<128).map { index in
            logSource(
                pod: "pod-\(index)-" + String(repeating: "x", count: 48),
                uid: "uid-\(index)",
                container: "application"
            )
        }
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
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let label = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Log sources" })

        root.layoutSubtreeIfNeeded()

        #expect(root.frame.width <= window.contentLayoutRect.width + 0.5)
        #expect(label.frame.maxX <= root.bounds.maxX + 0.5)
        #expect(label.intrinsicContentSize.width > label.frame.width)
        #expect(label.lineBreakMode == .byTruncatingMiddle)
        #expect(label.maximumNumberOfLines == 1)
        #expect(label.stringValue.contains("… +"))
        #expect(label.toolTip?.count ?? 0 > label.stringValue.count)
        #expect(label.toolTip?.contains("pod-127-") == true)

        window.setContentSize(NSSize(width: window.minSize.width, height: 320))
        root.layoutSubtreeIfNeeded()
        #expect(root.frame.width <= window.contentLayoutRect.width + 0.5)
    }

    @Test("long container names do not widen the log toolbar")
    func longContainerNameStaysWithinWindow() throws {
        let container = String(repeating: "c", count: 63)
        let source = logSource(pod: "api", uid: "api-uid", container: container)
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "production",
                clusterName: "cluster",
                serverHostname: "example.invalid",
                defaultNamespace: "default"
            ),
            sources: [source],
            provider: NoopLogWindowProvider()
        )
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let popup = try #require(descendants(of: root).compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "log-container" })

        root.layoutSubtreeIfNeeded()

        #expect(root.frame.width <= window.contentLayoutRect.width + 0.5)
        #expect(popup.frame.maxX <= root.bounds.maxX + 0.5)
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
        let logView = try #require(descendants(of: root)
            .compactMap { $0 as? LogViewportView }
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
        #expect(logView.string.isEmpty)

        window.makeKeyAndOrderFront(nil)
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitForLogText(logView) { value in
            value.contains("[app] hello") && value.contains("[sidecar] ready")
        }
        root.layoutSubtreeIfNeeded()
        let laidOutText = laidOutLogTextRect(in: logView)
        #expect(logView.frame.width >= scrollView.contentSize.width)
        #expect(logView.frame.height >= scrollView.contentSize.height)
        #expect(logView.frame.intersects(scrollView.contentView.bounds))
        #expect(laidOutText.width > 0)
        #expect(laidOutText.height > 0)
        #expect(laidOutText.intersects(logView.visibleRect))
    }

    @Test("live filter keeps only matching records and highlights its keyword")
    func liveFilterHighlightsVisibleMatches() async throws {
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
        let logView = try #require(descendants(of: root)
            .compactMap { $0 as? LogViewportView }
            .first { $0.accessibilityLabel() == "Pod logs" })
        let search = try #require(descendants(of: root)
            .compactMap { $0 as? NSSearchField }.first)
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        window.orderOut(nil)
        provider.emitStreaming(generation: 1, sequence: 1)
        provider.emitRecords(
            generation: 1,
            sequence: 2,
            records: [
                LogRecord(
                    sourceID: source.sourceID,
                    data: Data("request ERROR while loading".utf8),
                    endsWithNewline: true
                ),
                LogRecord(
                    sourceID: source.sourceID,
                    data: Data("request completed".utf8),
                    endsWithNewline: true
                ),
            ]
        )
        window.makeKeyAndOrderFront(nil)
        try await waitForLogText(
            logView,
            waking: controller,
            in: window
        ) { $0.contains("request completed") }

        search.stringValue = "error"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: search
        ))
        try await waitForLogText(logView, waking: controller, in: window) {
            $0.contains("request ERROR") && !$0.contains("request completed")
        }

        #expect(logView.projection.highlightedText == "error")
        let matches = (0..<logView.visualRowCount).flatMap {
            logView.filterHighlightRanges(forVisualRow: $0)
        }
        #expect(matches.contains {
            (logView.string as NSString).substring(with: $0) == "ERROR"
        })
    }

    @Test("long lines use the configured display limit and save losslessly")
    func longLineDisplayIsBoundedAndSaveIsLossless() async throws {
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
            displayConfiguration: LogDisplayConfiguration(
                renderBatchMilliseconds: 1,
                maximumDisplayedLineUTF8Bytes: 16 << 10
            ),
            fileWriter: { value, url in
                try writer.write(value, to: url, failure: nil)
            }
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let logView = try #require(descendants(of: root)
            .compactMap { $0 as? LogViewportView }
            .first { $0.accessibilityLabel() == "Pod logs" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }

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
        try await waitForLogText(logView) {
            $0.contains(LogTextRenderer.displayTruncationMarker)
        }

        #expect(logView.string.hasPrefix(String(repeating: "x", count: 16 << 10)))
        #expect(logView.string.hasSuffix("\(LogTextRenderer.displayTruncationMarker)\n"))
        #expect(logView.string.utf8.count < (17 << 10))
        #expect(status.stringValue.contains("1 long line truncated"))
        #expect(status.toolTip?.contains("16 KiB") == true)
        #expect(status.toolTip?.contains("Save preserves") == true)
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
        let logView = try #require(descendants(of: root)
            .compactMap { $0 as? LogViewportView }
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
        try await waitForLogText(logView) { $0.contains("initial-199") }
        #expect(isLogViewAtTail(logView, in: scrollView))
        #expect(isActualLogTailFullyVisible(logView, in: scrollView))
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
        try await waitForLogText(logView) { $0.contains("after-correction") }
        #expect(isLogViewAtTail(logView, in: scrollView))
        #expect(isActualLogTailFullyVisible(logView, in: scrollView))
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
        let logView = try #require(descendants(of: root)
            .compactMap { $0 as? LogViewportView }
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
        try await waitForLogText(logView) { $0.contains("initial-499") }
        #expect(isLogViewAtTail(logView, in: scrollView))
        #expect(isActualLogTailFullyVisible(logView, in: scrollView))

        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(follow.state == .on)
        #expect(isLogViewAtTail(logView, in: scrollView),
            "A deferred layout pass moved the initial tail away from the bottom")
        #expect(isActualLogTailFullyVisible(logView, in: scrollView))
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
        let logView = try #require(descendants(of: root)
            .compactMap { $0 as? LogViewportView }
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
        try await waitForLogText(logView) { $0.contains("initial-199") }
        #expect(isLogViewAtTail(logView, in: scrollView))
        try await waitForLogWindowControl(follow, enabled: true)
        #expect(follow.state == .on)

        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clipView)
        #expect(!isLogViewAtTail(logView, in: scrollView))
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
        try await waitForLogText(logView) { $0.contains("while-scrolled-away-99") }
        #expect(!isLogViewAtTail(logView, in: scrollView))
        #expect(clipView.bounds.origin == scrolledAwayOrigin)

        follow.performClick(nil)
        #expect(follow.state == .on)
        #expect(isLogViewAtTail(logView, in: scrollView))
        #expect(isActualLogTailFullyVisible(logView, in: scrollView))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!provider.snapshot().contains("start:2"))

        window.setContentSize(NSSize(width: 720, height: 420))
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        #expect(isActualLogTailFullyVisible(logView, in: scrollView))

        // Returning to the tail manually also re-arms the presentation.
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(clipView)
        #expect(follow.state == .off)
        clipView.scroll(to: NSPoint(
            x: clipView.bounds.origin.x,
            y: max(0, logView.bounds.maxY - clipView.bounds.height)
        ))
        scrollView.reflectScrolledClipView(clipView)
        #expect(isLogViewAtTail(logView, in: scrollView))
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
        try await waitForLogText(logView) { $0.contains("after-returning-to-tail") }
        #expect(isLogViewAtTail(logView, in: scrollView))
    }

    @Test("failed replacement restores controls without retiring established stream")
    func failedReplacementRestoresAppliedConfiguration() async throws {
        let provider = OrderedLogWindowProvider()
        let source = logSource(pod: "api", uid: "api-uid", container: "app")
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [source],
            provider: provider
        )
        controller.showWindow(nil)
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

        // Records from the still-established generation must restore its
        // streaming presentation after the replacement reports an error.
        provider.emitRecords(
            generation: 1,
            sequence: 2,
            records: [LogRecord(
                sourceID: source.sourceID,
                data: Data("still streaming".utf8),
                endsWithNewline: true
            )]
        )
        try await waitForLogStatus(status) { $0 == "Streaming" }
        controller.close()
    }

    @Test("failed non-following streams expose an immediate manual retry")
    func failedNonFollowingStreamCanRetryManually() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider,
            options: LogOptions(follow: false)
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }
        provider.emitStreaming(generation: 1, sequence: 1)

        let root = try #require(controller.window?.contentView)
        let retry = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Retry" })
        #expect(retry.isHidden)

        provider.emitFailed(generation: 1, sequence: 2)
        try await waitForLogWindowControl(retry, hidden: false)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!provider.snapshot().contains("start:2"))

        retry.performClick(nil)
        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        #expect(retry.isHidden)
        #expect(provider.request(generation: 2)?.options.follow == false)
    }

    @Test("an initial terminal failure exposes retry before any stream is established")
    func initialTerminalFailureCanRetry() async throws {
        let provider = OrderedLogWindowProvider()
        let controller = LogWindowController(
            session: OpenedClusterSession(
                sessionID: "session", contextName: "production", clusterName: "cluster",
                serverHostname: "example.invalid", defaultNamespace: "default"
            ),
            sources: [logSource(pod: "api", uid: "api-uid", container: "app")],
            provider: provider,
            options: LogOptions(follow: false)
        )
        controller.showWindow(nil)
        defer { controller.close() }
        try await waitForLogWindowEvent(provider) { $0.contains("start:1") }

        let root = try #require(controller.window?.contentView)
        let retry = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Retry" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        provider.emitFailed(generation: 1, sequence: 1)

        try await waitForLogWindowControl(retry, hidden: false)
        try await waitForLogStatus(status) { $0.contains("The test log stream failed") }
        #expect(status.stringValue.hasPrefix("Failed"))
        #expect(provider.snapshot().contains("cancel:1"))
    }

    @Test("failed following streams retry automatically after a delay")
    func failedFollowingStreamRetriesAutomatically() async throws {
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
        let retry = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Retry" })
        provider.emitFailed(generation: 1, sequence: 2)
        try await waitForLogWindowControl(retry, hidden: false)

        try await waitForLogWindowEvent(provider) { $0.contains("start:2") }
        #expect(retry.isHidden)
        #expect(provider.request(generation: 2)?.options.follow == true)
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
        let logView = try #require(descendants(of: root).compactMap {
            $0 as? LogViewportView
        }.first)
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        let original = String(repeating: "multi-megabyte-log-line", count: 100_000)
        try installLogText(original, in: logView)
        let destination = URL(fileURLWithPath: "/tmp/kmgr-log-snapshot-test.txt")

        controller.saveVisibleBufferSnapshot(to: destination)
        #expect(status.stringValue == "Saving kmgr-log-snapshot-test.txt…")
        #expect(!probe.isFinished)
        try installLogText("new text rendered while the save is running", in: logView)

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
        let logView = try #require(descendants(of: root).compactMap {
            $0 as? LogViewportView
        }.first)
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "log-status" })
        try installLogText("snapshot that cannot be written", in: logView)

        controller.saveVisibleBufferSnapshot(to: URL(fileURLWithPath: "/tmp/rejected.txt"))
        try await waitForLogFileWrite(probe)
        try await waitForLogStatus(status) { $0.contains("Save failed") }

        #expect(probe.snapshot?.ranOnMainThread == false)
        #expect(status.stringValue.contains("test writer rejected the save"))
        #expect(status.textColor == .systemRed)
    }
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

@MainActor
private func makeLogViewport(frame: NSRect) -> (LogViewportView, NSScrollView) {
    let logView = LogViewportView(frame: frame)
    let scrollView = NSScrollView(frame: frame)
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.documentView = logView
    logView.updateDocumentFrame(for: scrollView.contentSize)
    return (logView, scrollView)
}

@MainActor
private func installLogText(
    _ value: String,
    in logView: LogViewportView,
    viewportSize: NSSize = NSSize(width: 700, height: 400)
) throws {
    let projection = try LogViewportProjection.make(
        chunks: value.isEmpty ? [] : [value],
        previous: nil,
        retainedChunkCount: 0,
        style: logView.projection.style
    )
    logView.install(projection, viewportSize: viewportSize)
}

@MainActor
private func logViewportRowRect(
    _ index: Int,
    in logView: LogViewportView
) -> NSRect {
    let lineHeight = CGFloat(logView.projection.style.lineHeight)
    return NSRect(
        x: logView.textContainerInset.width,
        y: logView.textContainerInset.height + CGFloat(index) * lineHeight,
        width: CGFloat(logView.visualRowCellCount(at: index))
            * CGFloat(logView.projection.style.cellWidth),
        height: lineHeight
    )
}

@MainActor
private func logViewportVisibleRowRects(
    _ logView: LogViewportView,
    in scrollView: NSScrollView
) -> [NSRect] {
    guard logView.visualRowCount > 0 else { return [] }
    let visible = scrollView.contentView.bounds
    let lineHeight = CGFloat(logView.projection.style.lineHeight)
    let first = max(0, Int(floor(
        (visible.minY - logView.textContainerInset.height) / lineHeight
    )))
    let last = min(logView.visualRowCount - 1, Int(floor(
        (visible.maxY - logView.textContainerInset.height) / lineHeight
    )))
    guard first <= last else { return [] }
    return (first...last).map { logViewportRowRect($0, in: logView) }
}

@MainActor
private func scrollLogViewportToTail(
    _ logView: LogViewportView,
    in scrollView: NSScrollView
) {
    let clipView = scrollView.contentView
    clipView.scroll(to: NSPoint(
        x: clipView.bounds.origin.x,
        y: max(0, logView.bounds.maxY - clipView.bounds.height)
    ))
    scrollView.reflectScrolledClipView(clipView)
}

@MainActor
private func isLogViewAtTail(
    _ logView: LogViewportView,
    in scrollView: NSScrollView
) -> Bool {
    scrollView.contentView.bounds.maxY >= logView.bounds.maxY - 4
}

@MainActor
private func isActualLogTailFullyVisible(
    _ logView: LogViewportView,
    in scrollView: NSScrollView
) -> Bool {
    guard logView.visualRowCount > 0 else { return true }
    let tail = logViewportRowRect(
        logView.visualRowCount - 1,
        in: logView
    )
    let visible = scrollView.contentView.bounds
    return tail.minY >= visible.minY - 0.5
        && tail.maxY <= visible.maxY + 0.5
}

@MainActor
private func laidOutLogTextRect(in logView: LogViewportView) -> NSRect {
    NSRect(
        x: logView.textContainerInset.width,
        y: logView.textContainerInset.height,
        width: CGFloat(logView.projection.maximumWidth),
        height: CGFloat(logView.visualRowCount)
            * CGFloat(logView.projection.style.lineHeight)
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

    func emitFailed(generation: UInt64, sequence: UInt64) {
        let continuation = lock.withLock { continuations[generation] }
        continuation?.yield(.status(
            cursor: StreamCursor(generation: generation, sequence: sequence),
            status: LogStatus(
                state: .failed,
                issue: ClusterManagerIssue(
                    category: .unavailable,
                    reason: "PodLogFailed",
                    message: "The test log stream failed.",
                    retryable: true,
                    contextName: "production",
                    operation: "stream Pod logs"
                )
            )
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
private func waitForLogWindowControl(
    _ control: NSControl,
    hidden: Bool
) async throws {
    for _ in 0..<200 {
        if control.isHidden == hidden { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for log control hidden=\(hidden)")
}

@MainActor
private func waitForLogText(
    _ logView: LogViewportView,
    condition: (String) -> Bool
) async throws {
    for _ in 0..<200 {
        if condition(logView.string) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for rendered log text; got \(logView.string)")
}

/// SwiftPM's test host is not an active app, so `makeKeyAndOrderFront` does not
/// reliably preserve AppKit's key-window state across an asynchronous render.
/// Repeat the real delegate wake while waiting instead of racing scheduler
/// cleanup from the preceding render.
@MainActor
private func waitForLogText(
    _ logView: LogViewportView,
    waking controller: LogWindowController,
    in window: NSWindow,
    condition: (String) -> Bool
) async throws {
    for _ in 0..<200 {
        if condition(logView.string) { return }
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for rendered log text; got \(logView.string)")
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
