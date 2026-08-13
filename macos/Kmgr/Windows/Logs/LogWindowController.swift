import AppKit
import KmgrCore

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
    private var ring: LogRecordRing
    private var options: LogOptions
    private var isPaused = false
    private var pendingRender = false

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
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20
    ) {
        precondition(!sources.isEmpty)
        self.session = session
        self.sources = sources
        self.provider = provider
        self.options = options
        self.ring = LogRecordRing(recordLimit: recordLimit, byteLimit: byteLimit)
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
        stopStream()
        onClose?()
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
                    self?.receive(message)
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

    private func receive(_ message: LogStreamMessage) {
        let disposition = gate.accept(message.cursor)
        guard disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence else { return }
        switch message {
        case .records(_, let records, _):
            ring.append(contentsOf: records)
            if !isPaused { scheduleRender() }
        case .status(_, let status):
            let state = status.state.rawValue.capitalized
            let drops = status.droppedRecords + ring.droppedRecords
            statusLabel.stringValue = drops == 0
                ? state
                : "\(state) · \(drops.formatted()) records dropped"
            statusLabel.textColor = status.state == .failed ? .systemRed : .secondaryLabelColor
            if let issue = status.issue { statusLabel.stringValue += " · \(issue.message)" }
        case .failure(_, let issue):
            statusLabel.stringValue = issue.message
            statusLabel.textColor = .systemRed
        }
    }

    /// Coalesce main-thread text rebuilding to at most one pass per 40 ms.
    private func scheduleRender() {
        guard !pendingRender else { return }
        pendingRender = true
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            pendingRender = false
            render()
        }
    }

    private func render() {
        let wasAtTail = isAtTail
        let selectedRange = textView.selectedRange()
        let filter = searchField.stringValue.lowercased()
        let showLabels = sources.count > 1
        var output = Data()
        for record in ring.records {
            if !filter.isEmpty,
                !String(decoding: record.data, as: UTF8.self).lowercased().contains(filter)
            { continue }
            if showLabels, let source = sources.first(where: { $0.sourceID == record.sourceID }) {
                output.append(contentsOf: "[\(source.label)] ".utf8)
            }
            output.append(record.data)
            if record.endsWithNewline { output.append(0x0a) }
        }
        textView.string = String(decoding: output, as: UTF8.self)
        let length = (textView.string as NSString).length
        if selectedRange.location <= length {
            textView.setSelectedRange(NSRange(
                location: selectedRange.location,
                length: min(selectedRange.length, length - selectedRange.location)
            ))
        }
        if wasAtTail { textView.scrollToEndOfDocument(nil) }
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
        ring.clear()
        textView.string = ""
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
