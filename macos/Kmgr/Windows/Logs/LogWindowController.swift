import AppKit
import KmgrCore
import OSLog

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate,
    NSSearchFieldDelegate
{
    let session: OpenedClusterSession
    let sources: [LogSource]
    private let provider: any LogStreamProviding
    private let streamID = UUID().uuidString.lowercased()
    private var generation: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var gate = GenerationSequenceGate()
    private let recordStore: LogRecordStore
    private var options: LogOptions
    private let renderBatchMilliseconds: Int
    private let maximumRenderedUTF8Bytes: Int
    private let sourceLabels: [String: String]
    private var isPaused = false
    private var pendingRender = false
    private var renderDirty = false
    private var needsRenderWhenVisible = false
    private var isClosing = false
    private var latestStoreDrops: UInt64 = 0
    private var latestStreamDrops: UInt64 = 0
    private var latestRenderOmissions = 0
    private var latestStreamState: LogStreamState = .connecting
    private let logSignposter = OSSignposter(
        subsystem: PerformanceSignpostCatalog.subsystem,
        category: PerformanceSignpostCatalog.logsCategory
    )

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private let searchField = NSSearchField()
    private let followButton = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let previousButton = NSButton(checkboxWithTitle: "Previous", target: nil, action: nil)
    private let timestampsButton = NSButton(checkboxWithTitle: "Timestamps", target: nil, action: nil)
    private let wrapButton = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)

    var onClose: (() -> Void)?

    init(
        session: OpenedClusterSession,
        sources: [LogSource],
        provider: any LogStreamProviding,
        options: LogOptions = LogOptions(),
        displayConfiguration: LogDisplayConfiguration = .default
    ) {
        precondition(!sources.isEmpty)
        self.session = session
        self.sources = sources
        self.provider = provider
        self.options = options
        self.recordStore = LogRecordStore(
            recordLimit: displayConfiguration.recordLimit,
            byteLimit: displayConfiguration.byteLimit
        )
        self.renderBatchMilliseconds = displayConfiguration.renderBatchMilliseconds
        // Preferences may retain far more history than AppKit can safely lay
        // out in one main-thread NSTextView.string replacement.
        self.maximumRenderedUTF8Bytes = min(displayConfiguration.byteLimit, 32 << 20)
        self.sourceLabels = Dictionary(
            sources.map { ($0.sourceID, $0.label) },
            uniquingKeysWith: { first, _ in first }
        )
        let titleSources = sources.count == 1 ? sources[0].label : "\(sources.count) Pods"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(session.contextName) — Logs — \(titleSources)"
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        startStream()
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        stopStream()
        onClose?()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        suspendRenderingWhileHidden()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        resumeRenderingIfVisible()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if canRenderNow { resumeRenderingIfVisible() }
        else { suspendRenderingWhileHidden() }
    }

    func controlTextDidChange(_ obj: Notification) { scheduleRender() }

    private func configureContent(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        followButton.state = options.follow ? .on : .off
        previousButton.state = options.previous ? .on : .off
        timestampsButton.state = options.timestamps ? .on : .off
        wrapButton.state = .off
        for button in [followButton, previousButton, timestampsButton] {
            button.target = self
            button.action = #selector(restartFromControls)
        }
        wrapButton.target = self
        wrapButton.action = #selector(toggleWrap)
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        searchField.placeholderString = "Filter visible logs"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearVisibleBuffer))
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(saveVisibleBuffer))
        let toolbar = NSStackView(views: [
            followButton, previousButton, timestampsButton, wrapButton, pauseButton,
            clearButton, saveButton, NSView(), searchField,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 7),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])
        window.contentView = root
    }

    @objc private func restartFromControls() {
        options.follow = followButton.state == .on
        options.previous = previousButton.state == .on
        options.timestamps = timestampsButton.state == .on
        startStream()
    }

    private func startStream() {
        let previousGeneration = generation
        streamTask?.cancel()
        if previousGeneration > 0 {
            Task { [provider, session, streamID] in
                await provider.cancelLogs(
                    sessionID: session.sessionID,
                    streamID: streamID,
                    generation: previousGeneration
                )
            }
        }
        generation &+= 1
        gate.reset()
        statusLabel.stringValue = "Connecting…"
        let request = LogStreamRequest(
            sessionID: session.sessionID,
            streamID: streamID,
            generation: generation,
            sources: sources,
            options: options
        )
        streamTask = Task { [weak self, provider] in
            do {
                for try await message in provider.streamLogs(request: request) {
                    guard !Task.isCancelled else { return }
                    await self?.receive(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.statusLabel.stringValue = error.localizedDescription
                self?.statusLabel.textColor = .systemRed
            }
        }
    }

    private func stopStream() {
        renderTask?.cancel()
        renderTask = nil
        streamTask?.cancel()
        let generation = generation
        Task { [provider, session, streamID] in
            await provider.cancelLogs(
                sessionID: session.sessionID,
                streamID: streamID,
                generation: generation
            )
        }
    }

    private func receive(_ message: LogStreamMessage) async {
        let disposition = gate.accept(message.cursor)
        guard disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence else { return }
        switch message {
        case .records(_, let records, _):
            let interval = logSignposter.beginInterval(
                PerformanceSignpostCatalog.logStoreAppend,
                "incoming_records=\(records.count)"
            )
            let statistics = await recordStore.append(contentsOf: records)
            logSignposter.endInterval(
                PerformanceSignpostCatalog.logStoreAppend,
                interval,
                "stored_records=\(statistics.recordCount) stored_bytes=\(statistics.byteCount) dropped_records=\(statistics.droppedRecords) cancelled=\(Task.isCancelled)"
            )
            guard !Task.isCancelled else { return }
            latestStoreDrops = statistics.droppedRecords
            updateStatusLabel()
            if !isPaused { scheduleRender() }
        case .status(_, let status):
            latestStreamState = status.state
            latestStreamDrops = status.droppedRecords
            updateStatusLabel()
            statusLabel.textColor = status.state == .failed ? .systemRed : .secondaryLabelColor
            if let issue = status.issue { statusLabel.stringValue += " · \(issue.message)" }
        case .failure(_, let issue):
            statusLabel.stringValue = issue.message
            statusLabel.textColor = .systemRed
        }
    }

    private func updateStatusLabel() {
        let state = latestStreamState.rawValue.capitalized
        let drops = latestStreamDrops + latestStoreDrops
        var parts = [state]
        if drops > 0 { parts.append("\(drops.formatted()) records dropped") }
        if latestRenderOmissions > 0 {
            parts.append("\(latestRenderOmissions.formatted()) omitted from display")
        }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    /// Coalesce main-thread text rebuilding to at most one pass per 40 ms.
    private func scheduleRender() {
        guard !isPaused, !isClosing else { return }
        guard canRenderNow else {
            needsRenderWhenVisible = true
            return
        }
        guard !pendingRender else {
            renderDirty = true
            return
        }
        pendingRender = true
        renderDirty = false
        renderTask = Task { [weak self] in
            guard let delay = self?.renderBatchMilliseconds else { return }
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self else { return }
            if !Task.isCancelled {
                if canRenderNow, !isPaused {
                    await render()
                } else {
                    needsRenderWhenVisible = true
                }
            }

            let needsFollowUp = renderDirty
            pendingRender = false
            renderTask = nil
            if needsFollowUp {
                scheduleRender()
            }
        }
    }

    private func render() async {
        let wasAtTail = isAtTail
        let selectedRange = textView.selectedRange()
        let filter = searchField.stringValue
        let showLabels = sources.count > 1
        let snapshot = await recordStore.snapshot()
        let records = snapshot.records
        let labels = sourceLabels
        let byteLimit = maximumRenderedUTF8Bytes
        let rendered: RenderedLogText
        let renderer = Task.detached(priority: .userInitiated) { [logSignposter] in
            let interval = logSignposter.beginInterval(
                PerformanceSignpostCatalog.logTextFormat,
                "input_records=\(records.count) output_byte_limit=\(byteLimit) shows_labels=\(showLabels) has_filter=\(!filter.isEmpty)"
            )
            do {
                let result = try LogTextRenderer.render(
                    records: records,
                    sourceLabels: labels,
                    showSourceLabels: showLabels,
                    filter: filter,
                    maximumOutputUTF8Bytes: byteLimit
                )
                logSignposter.endInterval(
                    PerformanceSignpostCatalog.logTextFormat,
                    interval,
                    "rendered_records=\(result.renderedRecords) omitted_records=\(result.omittedRecords) output_bytes=\(result.outputUTF8Bytes)"
                )
                return result
            } catch {
                logSignposter.endInterval(
                    PerformanceSignpostCatalog.logTextFormat,
                    interval,
                    "outcome=cancelled"
                )
                throw error
            }
        }
        do {
            rendered = try await withTaskCancellationHandler {
                try await renderer.value
            } onCancel: {
                renderer.cancel()
            }
        } catch {
            return
        }
        guard !Task.isCancelled, canRenderNow, !isPaused else {
            needsRenderWhenVisible = true
            return
        }
        let installInterval = logSignposter.beginInterval(
            PerformanceSignpostCatalog.logTextInstall,
            "output_bytes=\(rendered.outputUTF8Bytes) rendered_records=\(rendered.renderedRecords)"
        )
        textView.string = rendered.text
        latestRenderOmissions = rendered.omittedRecords
        updateStatusLabel()
        let length = (textView.string as NSString).length
        if selectedRange.location <= length {
            textView.setSelectedRange(NSRange(
                location: selectedRange.location,
                length: min(selectedRange.length, length - selectedRange.location)
            ))
        }
        if wasAtTail { textView.scrollToEndOfDocument(nil) }
        needsRenderWhenVisible = false
        logSignposter.endInterval(
            PerformanceSignpostCatalog.logTextInstall,
            installInterval
        )
    }

    private var isAtTail: Bool {
        let visibleMaxY = scrollView.contentView.bounds.maxY
        return visibleMaxY >= textView.bounds.maxY - 4
    }

    @objc private func togglePause() {
        isPaused.toggle()
        pauseButton.title = isPaused ? "Resume" : "Pause"
        if !isPaused { scheduleRender() }
    }

    @objc private func toggleWrap() {
        let enabled = wrapButton.state == .on
        textView.textContainer?.widthTracksTextView = enabled
        textView.isHorizontallyResizable = !enabled
        scrollView.hasHorizontalScroller = !enabled
    }

    @objc private func clearVisibleBuffer() {
        // Prevent an in-flight formatting pass from restoring the snapshot the
        // user just cleared. New records mark the cancelled pass dirty and are
        // picked up by its single serialized follow-up.
        renderTask?.cancel()
        Task { [weak self, recordStore] in
            _ = await recordStore.clear()
            guard let self else { return }
            latestStoreDrops = 0
            latestRenderOmissions = 0
            updateStatusLabel()
        }
        textView.string = ""
    }

    private var canRenderNow: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func suspendRenderingWhileHidden() {
        guard !canRenderNow else { return }
        if pendingRender || !textView.string.isEmpty {
            needsRenderWhenVisible = true
        }
        renderTask?.cancel()
    }

    private func resumeRenderingIfVisible() {
        guard canRenderNow, !isPaused, needsRenderWhenVisible else { return }
        scheduleRender()
    }

    @objc private func saveVisibleBuffer() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kmgr-logs.txt"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let value = self?.textView.string else { return }
            do {
                try value.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
                self?.statusLabel.textColor = .systemRed
            }
        }
    }
}
