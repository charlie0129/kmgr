import AppKit
import KmgrCore
import KmgrIPC

@MainActor
final class EngineDiagnosticsWindowController: NSWindowController,
    NSWindowDelegate, NSSearchFieldDelegate
{
    private let store: EngineDiagnosticsStore
    private var snapshot: EngineDiagnosticsSnapshot?
    private var displayConfiguration: LogDisplayConfiguration
    private var maximumRenderedUTF8Bytes: Int
    private var maximumDisplayedLineUTF8Bytes: Int
    private var renderTask: Task<Void, Never>?
    private var renderRevision: UInt64 = 0
    private var snapshotRevision: UInt64 = 0
    private var isClosing = false
    private var renderedDisplayChunks: [String] = []
    private var followsVisibleTail = true
    private var lastObservedViewportOrigin = NSPoint.zero
    private var viewportTrackingSuppressionDepth = 0

    private let logView = LogViewportView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 320)
    )
    private let scrollView = NSScrollView()
    private let metadataLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Loading…")
    private let searchField = NSSearchField()
    private let wrapButton = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)

    var onClose: (() -> Void)?

    init(
        store: EngineDiagnosticsStore,
        displayConfiguration: LogDisplayConfiguration = .default
    ) {
        self.store = store
        self.displayConfiguration = displayConfiguration
        self.maximumRenderedUTF8Bytes = min(
            displayConfiguration.byteLimit,
            displayConfiguration.maximumRenderedUTF8Bytes
        )
        self.maximumDisplayedLineUTF8Bytes =
            displayConfiguration.maximumDisplayedLineUTF8Bytes

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Engine Diagnostics"
        window.minSize = NSSize(width: 680, height: 320)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        refreshSnapshot()
    }

    func prepareForTermination() {
        isClosing = true
        renderRevision &+= 1
        snapshotRevision &+= 1
        renderTask?.cancel()
        renderTask = nil
    }

    func windowWillClose(_ notification: Notification) {
        prepareForTermination()
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        let wasFollowingTail = followsVisibleTail
        let anchor = wasFollowingTail ? nil : logView.verticalAnchor(
            at: scrollView.contentView.bounds.minY
        )
        updateLogViewportFrame()
        if wasFollowingTail { scrollToTail() }
        else if let anchor { restoreViewport(anchor) }
    }

    func controlTextDidChange(_ obj: Notification) {
        scheduleRender()
    }

    func applyDisplayConfiguration(_ configuration: LogDisplayConfiguration) {
        guard configuration != displayConfiguration else { return }
        displayConfiguration = configuration
        maximumRenderedUTF8Bytes = min(
            configuration.byteLimit,
            configuration.maximumRenderedUTF8Bytes
        )
        maximumDisplayedLineUTF8Bytes = configuration.maximumDisplayedLineUTF8Bytes
        scheduleRender()
    }

    private func configureContent(in window: NSWindow) {
        let root = NSView()

        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.maximumNumberOfLines = 1
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.cell?.usesSingleLineMode = true
        metadataLabel.cell?.wraps = false
        metadataLabel.setAccessibilityLabel("Engine diagnostic scope")
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.usesSingleLineMode = true
        statusLabel.cell?.wraps = false
        statusLabel.setAccessibilityLabel("Engine diagnostic status")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.identifier = NSUserInterfaceItemIdentifier("engine-diagnostics-status")

        searchField.placeholderString = "Filter diagnostics"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Filter engine diagnostics")
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        wrapButton.state = .off
        wrapButton.target = self
        wrapButton.action = #selector(toggleWrap)
        wrapButton.setAccessibilityLabel("Wrap engine diagnostics")

        refreshButton.target = self
        refreshButton.action = #selector(refreshSnapshot)
        refreshButton.setAccessibilityLabel("Refresh engine diagnostics")

        let toolbar = NSStackView(views: [
            wrapButton, refreshButton, NSView(), searchField,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = logView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.identifier = NSUserInterfaceItemIdentifier("engine-diagnostics-content")
        let clipView = scrollView.contentView
        lastObservedViewportOrigin = clipView.bounds.origin
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSStackView(views: [statusLabel, NSView()])
        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 8
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(metadataLabel)
        root.addSubview(scrollView)
        root.addSubview(statusBar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            metadataLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            metadataLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            metadataLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        updateLogViewportFrame()
        logView.setAccessibilityLabel("Engine diagnostics log")
    }

    @objc private func refreshSnapshot() {
        guard !isClosing else { return }
        snapshotRevision &+= 1
        let revision = snapshotRevision
        let store = self.store
        Task { [weak self] in
            let value = await store.preferredSnapshot()
            guard let self, !isClosing, revision == snapshotRevision else { return }
            snapshot = value
            updateMetadata()
            scheduleRender(immediate: true)
        }
    }

    private func updateMetadata() {
        guard let snapshot else {
            metadataLabel.stringValue = "No engine diagnostics have been captured."
            metadataLabel.toolTip = nil
            metadataLabel.setAccessibilityValue(metadataLabel.stringValue)
            metadataLabel.setAccessibilityHelp(nil)
            return
        }
        let source = snapshot.isCurrent
            ? "Current engine generation"
            : (snapshot.unexpected ? "Last unexpected engine generation" : "Engine generation")
        var details = [source, "generation \(snapshot.generation)"]
        if let termination = snapshot.termination {
            details.append(termination.summary)
        }
        if snapshot.statistics.droppedBytes > 0 {
            details.append("older output omitted")
        }
        metadataLabel.stringValue = details.joined(separator: " · ")
        metadataLabel.toolTip = diagnosticDetails(for: snapshot)
        metadataLabel.setAccessibilityValue(metadataLabel.stringValue)
        metadataLabel.setAccessibilityHelp(metadataLabel.toolTip)
    }

    private func diagnosticDetails(for snapshot: EngineDiagnosticsSnapshot) -> String {
        var lines = [
            "Generation: \(snapshot.generation)",
            "Started: \(Self.dateFormatter.string(from: snapshot.startedAt))",
        ]
        if let readyAt = snapshot.readyAt {
            lines.append("Ready: \(Self.dateFormatter.string(from: readyAt))")
        }
        if let endedAt = snapshot.endedAt {
            lines.append("Ended: \(Self.dateFormatter.string(from: endedAt))")
        }
        if let readyDuration = snapshot.readyDurationMilliseconds {
            lines.append("Ready duration: \(readyDuration.formatted()) ms")
        }
        if let instanceID = snapshot.engineInstanceID, !instanceID.isEmpty {
            lines.append("Instance: \(instanceID)")
        }
        if let termination = snapshot.termination {
            lines.append("Termination: \(termination.summary)")
        }
        lines.append(
            "Retained: \(snapshot.statistics.byteCount.formatted()) bytes in \(snapshot.statistics.recordCount.formatted()) records"
        )
        if snapshot.statistics.droppedBytes > 0 {
            lines.append(
                "Evicted: \(snapshot.statistics.droppedBytes.formatted()) bytes in \(snapshot.statistics.droppedRecords.formatted()) records"
            )
        }
        return lines.joined(separator: "\n")
    }

    private func scheduleRender(immediate: Bool = false) {
        guard !isClosing else { return }
        renderRevision &+= 1
        let revision = renderRevision
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                try? await Task.sleep(
                    for: .milliseconds(displayConfiguration.renderBatchMilliseconds)
                )
            }
            guard !Task.isCancelled, revision == renderRevision else { return }
            await render(revision: revision)
        }
    }

    private func render(revision: UInt64) async {
        let selectedRange = logView.selectedRange()
        let records = snapshot?.records ?? []
        let filter = searchField.stringValue
        let byteLimit = maximumRenderedUTF8Bytes
        let displayedLineByteLimit = maximumDisplayedLineUTF8Bytes
        let previousChunks = renderedDisplayChunks
        let previousProjection = logView.projection
        let renderer = Task.detached(priority: .userInitiated) {
            let rendered = try LogTextRenderer.render(
                records: records,
                sourceLabels: ["engine": "engine"],
                showSourceLabels: false,
                filter: filter,
                maximumOutputUTF8Bytes: byteLimit,
                maximumDisplayedLineUTF8Bytes: displayedLineByteLimit,
                displayTruncationMarker: LogTextRenderer
                    .retainedBufferDisplayTruncationMarker
            )
            let install = LogTextInstallPlanner.plan(
                previousChunks: previousChunks,
                currentChunks: rendered.displayChunks
            )
            let projection = try LogViewportProjection.make(
                chunks: rendered.displayChunks,
                previous: previousProjection,
                retainedChunkCount: install.retainedChunkCount,
                style: previousProjection.style,
                highlightedText: filter
            )
            return (
                rendered: rendered,
                install: install,
                projection: projection
            )
        }
        let result: (
            rendered: RenderedLogText,
            install: LogTextInstallPlan,
            projection: LogViewportProjection
        )
        do {
            result = try await withTaskCancellationHandler {
                try await renderer.value
            } onCancel: {
                renderer.cancel()
            }
        } catch {
            return
        }
        guard !Task.isCancelled, !isClosing, revision == renderRevision else { return }

        let wasFollowingTail = followsVisibleTail
        var anchor = wasFollowingTail ? nil : logView.verticalAnchor(
            at: scrollView.contentView.bounds.minY
        )
        if var value = anchor {
            value.textIndex = result.install.remapSelection(NSRange(
                location: value.textIndex,
                length: 0
            )).location
            anchor = value
        }
        withViewportTrackingSuppressed {
            logView.install(
                result.projection,
                viewportSize: scrollView.contentSize
            )
        }
        renderedDisplayChunks = result.rendered.displayChunks
        logView.setSelectedRange(result.install.remapSelection(selectedRange))
        if let anchor {
            restoreViewport(anchor)
        } else {
            scrollToTail()
        }
        updateStatus(
            renderedRecords: result.rendered.renderedRecords,
            omittedRecords: result.rendered.omittedRecords,
            displayTruncatedLines: result.rendered.displayTruncatedLines
        )
    }

    private func updateStatus(
        renderedRecords: Int,
        omittedRecords: Int,
        displayTruncatedLines: Int
    ) {
        guard let snapshot else {
            statusLabel.stringValue = "No engine output"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.toolTip = nil
            statusLabel.setAccessibilityValue(statusLabel.stringValue)
            statusLabel.setAccessibilityHelp(nil)
            return
        }
        var parts = [
            "\(renderedRecords.formatted()) displayed",
            "\(snapshot.statistics.byteCount.formatted()) retained bytes",
        ]
        if omittedRecords > 0 {
            parts.append("\(omittedRecords.formatted()) omitted by display limit")
        }
        if displayTruncatedLines > 0 {
            parts.append("\(displayTruncatedLines.formatted()) long lines truncated")
        }
        statusLabel.stringValue = parts.joined(separator: " · ")
        statusLabel.textColor = snapshot.unexpected ? .systemOrange : .secondaryLabelColor
        statusLabel.toolTip = snapshot.statistics.droppedBytes > 0
            ? "The oldest \(snapshot.statistics.droppedBytes.formatted()) bytes were evicted from the bounded buffer."
            : nil
        statusLabel.setAccessibilityValue(statusLabel.stringValue)
        statusLabel.setAccessibilityHelp(statusLabel.toolTip)
    }

    @objc private func toggleWrap() {
        let wasFollowingTail = followsVisibleTail
        let anchor = wasFollowingTail ? nil : logView.verticalAnchor(
            at: scrollView.contentView.bounds.minY
        )
        let enabled = wrapButton.state == .on
        withViewportTrackingSuppressed {
            scrollView.hasHorizontalScroller = !enabled
            scrollView.tile()
            logView.setWrapsLines(enabled, viewportSize: scrollView.contentSize)
        }
        if wasFollowingTail { scrollToTail() }
        else if let anchor { restoreViewport(anchor) }
    }

    @objc private func viewportBoundsDidChange(_ notification: Notification) {
        let origin = scrollView.contentView.bounds.origin
        defer { lastObservedViewportOrigin = origin }
        guard viewportTrackingSuppressionDepth == 0,
            origin != lastObservedViewportOrigin
        else { return }
        followsVisibleTail = isAtTail
    }

    private func updateLogViewportFrame() {
        withViewportTrackingSuppressed {
            logView.updateDocumentFrame(for: scrollView.contentSize)
        }
    }

    private var isAtTail: Bool {
        scrollView.contentView.bounds.maxY >= logView.bounds.maxY - 4
    }

    private func scrollToTail() {
        updateLogViewportFrame()
        let clipView = scrollView.contentView
        let maximumX = max(0, logView.bounds.width - clipView.bounds.width)
        let maximumY = max(0, logView.bounds.height - clipView.bounds.height)
        withViewportTrackingSuppressed {
            clipView.scroll(to: NSPoint(
                x: logView.wrapsLines
                    ? 0
                    : min(max(0, clipView.bounds.origin.x), maximumX),
                y: maximumY
            ))
            scrollView.reflectScrolledClipView(clipView)
        }
        followsVisibleTail = true
    }

    private func restoreViewport(_ anchor: LogViewportAnchor) {
        updateLogViewportFrame()
        let clipView = scrollView.contentView
        let maximumX = max(0, logView.bounds.width - clipView.bounds.width)
        let maximumY = max(0, logView.bounds.height - clipView.bounds.height)
        withViewportTrackingSuppressed {
            clipView.scroll(to: NSPoint(
                x: logView.wrapsLines
                    ? 0
                    : min(max(0, clipView.bounds.origin.x), maximumX),
                y: min(max(0, logView.verticalOffset(for: anchor)), maximumY)
            ))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func withViewportTrackingSuppressed<T>(_ operation: () throws -> T) rethrows -> T {
        viewportTrackingSuppressionDepth += 1
        defer { viewportTrackingSuppressionDepth -= 1 }
        return try operation()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
