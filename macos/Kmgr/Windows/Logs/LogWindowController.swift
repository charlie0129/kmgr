import AppKit
import KmgrCore
import OSLog

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate,
    NSSearchFieldDelegate
{
    private struct AppliedStreamConfiguration {
        var sources: [LogSource]
        var options: LogOptions
        var containerTitle: String
    }

    let session: OpenedClusterSession
    private(set) var sources: [LogSource]
    private let availableSources: [LogSource]
    private let staticWorkloadSnapshot: Bool
    private let provider: any LogStreamProviding
    private let fileWriter: @Sendable (String, URL) throws -> Void
    private let streamID = UUID().uuidString.lowercased()
    private var generation: UInt64 = 0
    private var streamTasks: [UInt64: Task<Void, Never>] = [:]
    private var pendingGeneration: UInt64?
    private var renderTask: Task<Void, Never>?
    private var streamGate = LogStreamGenerationGate()
    private let recordStore: LogRecordStore
    private var options: LogOptions
    private var displayConfiguration: LogDisplayConfiguration
    private var renderBatchMilliseconds: Int
    private var maximumRenderedUTF8Bytes: Int
    private var configurationRevision: UInt64 = 0
    private var renderScheduleRevision: UInt64 = 0
    private let sourceLabels: [String: String]
    private var isPaused = false
    private var pendingRender = false
    private var renderDirty = false
    private var needsRenderWhenVisible = false
    private var keyVisibilityWakePending = false
    private var isClosing = false
    private var latestStoreDrops: UInt64 = 0
    private var latestStreamDrops: UInt64 = 0
    private var latestRenderOmissions = 0
    private var latestStreamState: LogStreamState = .connecting
    private var renderedChunks: [String] = []
    private var appliedContainerTitle = ""
    private var establishedConfiguration: AppliedStreamConfiguration?
    private let logSignposter = OSSignposter(
        subsystem: PerformanceSignpostCatalog.subsystem,
        category: PerformanceSignpostCatalog.logsCategory
    )

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let followButton = NSButton(checkboxWithTitle: "Follow", target: nil, action: nil)
    private let previousButton = NSButton(checkboxWithTitle: "Previous", target: nil, action: nil)
    private let timestampsButton = NSButton(checkboxWithTitle: "Timestamps", target: nil, action: nil)
    private let containerButton = NSPopUpButton()
    private let tailField = NSTextField()
    private let sinceField = NSTextField()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let wrapButton = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)

    var onClose: (() -> Void)?

    init(
        session: OpenedClusterSession,
        sources: [LogSource],
        availableSources: [LogSource]? = nil,
        provider: any LogStreamProviding,
        options: LogOptions = LogOptions(),
        displayConfiguration: LogDisplayConfiguration = .default,
        staticWorkloadSnapshot: Bool = false,
        fileWriter: @escaping @Sendable (String, URL) throws -> Void = { value, url in
            try value.write(to: url, atomically: true, encoding: .utf8)
        }
    ) {
        precondition(!sources.isEmpty)
        let allSources = availableSources ?? sources
        precondition(!allSources.isEmpty)
        precondition(Set(sources.map(\.sourceID)).isSubset(of: Set(allSources.map(\.sourceID))))
        self.session = session
        self.sources = sources
        self.availableSources = allSources
        self.staticWorkloadSnapshot = staticWorkloadSnapshot
        self.provider = provider
        self.fileWriter = fileWriter
        self.options = options
        self.recordStore = LogRecordStore(
            recordLimit: displayConfiguration.recordLimit,
            byteLimit: displayConfiguration.byteLimit
        )
        self.displayConfiguration = displayConfiguration
        self.renderBatchMilliseconds = displayConfiguration.renderBatchMilliseconds
        // Preferences may retain far more history than AppKit can safely lay
        // out in one main-thread NSTextView.string replacement.
        self.maximumRenderedUTF8Bytes = min(displayConfiguration.byteLimit, 32 << 20)
        self.sourceLabels = LogSourcePresentation.prefixLabels(for: allSources)
        let titleSources = LogSourcePresentation.titleSummary(for: sources)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        window.title = "\(clusterPresentation.titlePrefix) — Logs — \(titleSources)"
        window.minSize = NSSize(width: 560, height: 320)
        window.tabbingMode = .disallowed
        // A log stream is an ephemeral, independently configured surface.
        // Reopening a workspace must never recreate it or merge it into a
        // cluster-window tab group.
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        configureContent(in: window)
        establishedConfiguration = AppliedStreamConfiguration(
            sources: sources,
            options: options,
            containerTitle: appliedContainerTitle
        )
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

    /// A stream can deliver its first records between `showWindow` and the
    /// application making this independent window key. Treat that transition
    /// as a rendering wake-up so an early, already-downloaded batch cannot sit
    /// buffered until a later occlusion change.
    func windowDidBecomeKey(_ notification: Notification) {
        guard needsRenderWhenVisible else { return }
        keyVisibilityWakePending = true
        resumeRenderingIfVisible()
    }

    func controlTextDidChange(_ obj: Notification) { scheduleRender() }

    /// Applies saved limits to an existing log window without interrupting its
    /// stream. Resizes are serialized so rapid preference saves cannot leave
    /// the actor-backed ring using an older configuration.
    func applyDisplayConfiguration(_ configuration: LogDisplayConfiguration) {
        guard configuration != displayConfiguration else { return }
        displayConfiguration = configuration
        renderBatchMilliseconds = configuration.renderBatchMilliseconds
        maximumRenderedUTF8Bytes = min(configuration.byteLimit, 32 << 20)
        configurationRevision &+= 1
        let revision = configurationRevision
        cancelScheduledRender()
        needsRenderWhenVisible = true
        Task { [weak self, recordStore] in
            guard let self, !isClosing else { return }
            let statistics = await recordStore.resize(
                recordLimit: configuration.recordLimit,
                byteLimit: configuration.byteLimit,
                revision: revision
            )
            guard !Task.isCancelled, revision == configurationRevision else { return }
            latestStoreDrops = statistics.droppedRecords
            updateStatusLabel()
            if !isPaused { scheduleRender() }
        }
    }

    private func configureContent(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        followButton.state = options.follow ? .on : .off
        previousButton.state = options.previous ? .on : .off
        timestampsButton.state = options.timestamps ? .on : .off
        tailField.stringValue = options.tailLines.map(String.init) ?? ""
        tailField.placeholderString = "Default"
        tailField.alignment = .right
        tailField.setAccessibilityLabel("Log tail lines")
        tailField.identifier = NSUserInterfaceItemIdentifier("log-tail-lines")
        tailField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        sinceField.stringValue = options.sinceSeconds.map(String.init) ?? ""
        sinceField.placeholderString = "All"
        sinceField.alignment = .right
        sinceField.setAccessibilityLabel("Log since seconds")
        sinceField.identifier = NSUserInterfaceItemIdentifier("log-since-seconds")
        sinceField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        configureContainerButton()
        wrapButton.state = .off
        for button in [followButton, previousButton, timestampsButton] {
            button.target = self
            button.action = #selector(restartFromControls)
        }
        wrapButton.target = self
        wrapButton.action = #selector(toggleWrap)
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        containerButton.target = self
        containerButton.action = #selector(restartFromControls)
        searchField.placeholderString = "Filter visible logs"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.identifier = NSUserInterfaceItemIdentifier("log-status")
        updateSourcePresentation()
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.setAccessibilityLabel("Log sources")
        sourceLabel.setAccessibilityValue(sourceLabel.stringValue)

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearVisibleBuffer))
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(saveVisibleBuffer))
        applyButton.target = self
        applyButton.action = #selector(restartFromControls)
        applyButton.setAccessibilityLabel("Apply log stream options")
        let containerLabel = NSTextField(labelWithString: "Container")
        let tailLabel = NSTextField(labelWithString: "Tail")
        let sinceLabel = NSTextField(labelWithString: "Since (s)")
        for label in [containerLabel, tailLabel, sinceLabel] {
            label.textColor = .secondaryLabelColor
        }
        let streamToolbar = NSStackView(views: [
            containerLabel, containerButton, followButton, previousButton, timestampsButton,
            tailLabel, tailField, sinceLabel, sinceField, applyButton, NSView(),
        ])
        streamToolbar.orientation = .horizontal
        streamToolbar.alignment = .centerY
        streamToolbar.spacing = 7
        let viewToolbar = NSStackView(views: [
            wrapButton, pauseButton, clearButton, saveButton, NSView(), searchField,
        ])
        viewToolbar.orientation = .horizontal
        viewToolbar.alignment = .centerY
        viewToolbar.spacing = 8
        let toolbar = NSStackView(views: [streamToolbar, viewToolbar])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 5
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
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(sourceLabel)
        root.addSubview(scrollView)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sourceLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            sourceLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            sourceLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])
        window.contentView = root
    }

    @objc private func restartFromControls() {
        guard pendingGeneration == nil else { return }
        statusLabel.toolTip = nil
        let tailText = tailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sinceText = sinceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tailText.isEmpty || (Int64(tailText).map { $0 >= -1 } ?? false),
            sinceText.isEmpty || (Int64(sinceText).map { $0 >= 0 } ?? false)
        else {
            restoreAppliedStreamControls()
            statusLabel.stringValue = "Tail must be -1 or greater; since seconds must be non-negative."
            statusLabel.textColor = .systemRed
            return
        }
        let tail = tailText.isEmpty ? nil : Int64(tailText)
        let since = sinceText.isEmpty ? nil : Int64(sinceText)
        let selectedContainer = containerButton.titleOfSelectedItem ?? "All Containers"
        let selectedSources = selectedContainer == "All Containers"
            ? availableSources
            : availableSources.filter { $0.container == selectedContainer }
        guard !selectedSources.isEmpty, selectedSources.count <= 128 else {
            restoreAppliedStreamControls()
            statusLabel.stringValue = "This container choice expands to too many streams (maximum 128)."
            statusLabel.textColor = .systemRed
            return
        }
        sources = selectedSources
        appliedContainerTitle = selectedContainer
        options.follow = followButton.state == .on
        options.previous = previousButton.state == .on
        options.timestamps = timestampsButton.state == .on
        options.since = nil
        options.sinceSeconds = since.flatMap { $0 == 0 ? nil : $0 }
        options.tailLines = tail
        updateSourcePresentation()
        startStream()
    }

    private func configureContainerButton() {
        var inventories: [ResourceIdentity: Set<String>] = [:]
        for source in availableSources {
            inventories[source.identity, default: []].insert(source.container)
        }
        let values = inventories.map { identity, containers in
            PodLogSourceInventory(identity: identity, containers: Array(containers))
        }
        let selections = PodLogSourcePlanner.selections(for: values)
        containerButton.addItems(withTitles: selections.map(\.title))
        containerButton.identifier = NSUserInterfaceItemIdentifier("log-container")
        containerButton.setAccessibilityLabel("Log container")
        containerButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let selectedContainers = Set(sources.map(\.container))
        let selectedTitle: String
        if Set(sources.map(\.sourceID)) == Set(availableSources.map(\.sourceID)),
            selections.contains(.all)
        {
            selectedTitle = PodLogContainerSelection.all.title
        } else if selectedContainers.count == 1, let name = selectedContainers.first {
            selectedTitle = name
        } else {
            selectedTitle = PodLogContainerSelection.all.title
        }
        containerButton.selectItem(withTitle: selectedTitle)
        appliedContainerTitle = selectedTitle
        if availableSources.count > 128,
            let allItem = containerButton.item(withTitle: PodLogContainerSelection.all.title)
        {
            allItem.isEnabled = false
            containerButton.toolTip = "All Containers would exceed the 128-stream limit. Choose one common container."
        }
    }

    private func restoreAppliedStreamControls() {
        followButton.state = options.follow ? .on : .off
        previousButton.state = options.previous ? .on : .off
        timestampsButton.state = options.timestamps ? .on : .off
        containerButton.selectItem(withTitle: appliedContainerTitle)
        tailField.stringValue = options.tailLines.map(String.init) ?? ""
        sinceField.stringValue = options.sinceSeconds.map(String.init) ?? ""
    }

    private func restoreEstablishedStreamConfiguration() {
        guard let establishedConfiguration else { return }
        sources = establishedConfiguration.sources
        options = establishedConfiguration.options
        appliedContainerTitle = establishedConfiguration.containerTitle
        restoreAppliedStreamControls()
        updateSourcePresentation()
    }

    private func setStreamControlsEnabled(_ enabled: Bool) {
        for control: NSControl in [
            containerButton, followButton, previousButton, timestampsButton,
            tailField, sinceField, applyButton,
        ] {
            control.isEnabled = enabled
        }
    }

    private func updateSourcePresentation() {
        let summary = LogSourcePresentation.toolbarSummary(
            contextName: session.contextName,
            sources: sources
        )
        let clusterSummary = "\(ClusterIdentityPresentation(session: session).labeledCluster) · \(summary)"
        let snapshotNote = staticWorkloadSnapshot
            ? "Static workload Pod snapshot; membership changes are not followed—reopen Logs to refresh."
            : ""
        sourceLabel.stringValue = snapshotNote.isEmpty
            ? clusterSummary
            : "\(clusterSummary) · \(snapshotNote)"
        sourceLabel.toolTip = sourceLabel.stringValue
        sourceLabel.setAccessibilityValue(sourceLabel.stringValue)
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        window?.title = "\(clusterPresentation.titlePrefix) — Logs — \(LogSourcePresentation.titleSummary(for: sources))"
    }

    private func startStream() {
        guard pendingGeneration == nil else { return }
        generation &+= 1
        if generation == 0 { generation = 1 }
        let activeGeneration = generation
        pendingGeneration = activeGeneration
        setStreamControlsEnabled(false)
        statusLabel.toolTip = nil
        statusLabel.stringValue = "Connecting…"
        statusLabel.textColor = .secondaryLabelColor
        let request = LogStreamRequest(
            sessionID: session.sessionID,
            streamID: streamID,
            generation: activeGeneration,
            sources: sources,
            options: options
        )
        let task = Task { [weak self, provider] in
            var replacementEstablished = false
            defer {
                self?.streamTasks.removeValue(forKey: activeGeneration)
            }
            do {
                for try await message in provider.streamLogs(request: request) {
                    guard !Task.isCancelled else { return }
                    if !replacementEstablished {
                        guard activeGeneration == self?.generation,
                            activeGeneration == self?.pendingGeneration
                        else { continue }
                        guard message.cursor.generation == activeGeneration,
                            message.cursor.sequence > 0
                        else { continue }
                        if let issue = Self.replacementRejectionIssue(
                            for: message,
                            contextName: self?.session.contextName ?? ""
                        ) {
                            self?.pendingGeneration = nil
                            self?.setStreamControlsEnabled(true)
                            self?.restoreEstablishedStreamConfiguration()
                            self?.updateStatusLabel()
                            let presentation = issue.userFacingPresentation
                            self?.statusLabel.stringValue += " · Replacement failed: \(presentation.inlineText)"
                            self?.statusLabel.toolTip = presentation.detailedText
                            self?.statusLabel.textColor = .systemRed
                            await provider.cancelLogs(
                                sessionID: request.sessionID,
                                streamID: request.streamID,
                                generation: activeGeneration
                            )
                            return
                        }
                        replacementEstablished = true
                        self?.establishedConfiguration = AppliedStreamConfiguration(
                            sources: request.sources,
                            options: request.options,
                            containerTitle: self?.appliedContainerTitle ?? ""
                        )
                        self?.pendingGeneration = nil
                        self?.setStreamControlsEnabled(true)
                        self?.streamGate.begin(generation: activeGeneration)
                        self?.retireGenerations(before: activeGeneration)
                    }
                    await self?.receive(message)
                }
                guard replacementEstablished || Task.isCancelled ||
                    activeGeneration != self?.generation
                else {
                    self?.pendingGeneration = nil
                    self?.setStreamControlsEnabled(true)
                    self?.restoreEstablishedStreamConfiguration()
                    self?.statusLabel.stringValue = "The log stream ended before connecting."
                    self?.statusLabel.textColor = .systemRed
                    return
                }
            } catch {
                guard !Task.isCancelled, let self,
                    activeGeneration == generation
                else { return }
                if pendingGeneration == activeGeneration {
                    pendingGeneration = nil
                    setStreamControlsEnabled(true)
                }
                restoreEstablishedStreamConfiguration()
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
            }
        }
        streamTasks[activeGeneration] = task
    }

    /// A replacement is not usable when its first accepted server message is
    /// terminal failure. Keep the established generation and its presentation
    /// alive so a rejected option change cannot interrupt healthy log output.
    private static func replacementRejectionIssue(
        for message: LogStreamMessage,
        contextName: String
    ) -> ClusterManagerIssue? {
        switch message {
        case .failure(_, let issue):
            return issue
        case .status(_, let status) where status.state == .failed:
            return status.issue ?? ClusterManagerIssue(
                category: .unavailable,
                reason: "LogReplacementFailed",
                message: "The replacement log stream failed before it connected.",
                retryable: true,
                contextName: contextName,
                operation: "stream Pod logs"
            )
        case .status(_, let status) where status.state == .cancelled:
            return status.issue ?? ClusterManagerIssue(
                category: .cancelled,
                reason: "LogReplacementCancelled",
                message: "The replacement log stream was cancelled before it connected.",
                contextName: contextName,
                operation: "stream Pod logs"
            )
        case .records, .status:
            return nil
        }
    }

    private func retireGenerations(before replacement: UInt64) {
        let obsolete = streamTasks.keys.filter { $0 < replacement }
        for generation in obsolete {
            streamTasks.removeValue(forKey: generation)?.cancel()
            Task { [provider, session, streamID] in
                await provider.cancelLogs(
                    sessionID: session.sessionID,
                    streamID: streamID,
                    generation: generation
                )
            }
        }
    }

    private func stopStream() {
        cancelScheduledRender()
        let activeGenerations = Array(streamTasks.keys)
        for generation in activeGenerations {
            streamTasks.removeValue(forKey: generation)?.cancel()
            Task { [provider, session, streamID] in
                await provider.cancelLogs(
                    sessionID: session.sessionID,
                    streamID: streamID,
                    generation: generation
                )
            }
        }
    }

    private func receive(_ message: LogStreamMessage) async {
        let disposition = streamGate.accept(message.cursor)
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
            needsRenderWhenVisible = true
            if !isPaused { scheduleRender() }
        case .status(_, let status):
            latestStreamState = status.state
            latestStreamDrops = status.droppedRecords
            updateStatusLabel()
            statusLabel.textColor = status.state == .failed ? .systemRed : .secondaryLabelColor
            if let issue = status.issue {
                let presentation = issue.userFacingPresentation
                statusLabel.stringValue += " · \(presentation.inlineText)"
                statusLabel.toolTip = presentation.detailedText
            }
        case .failure(_, let issue):
            let presentation = issue.userFacingPresentation
            statusLabel.stringValue = presentation.inlineText
            statusLabel.toolTip = presentation.detailedText
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
        statusLabel.toolTip = nil
    }

    /// Coalesce detached formatting and incremental text installation to at
    /// most one pass per configured render interval.
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
        let revision = renderScheduleRevision
        renderTask = Task { [weak self] in
            guard let delay = self?.renderBatchMilliseconds else { return }
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, revision == renderScheduleRevision else { return }
            if !Task.isCancelled {
                if canRenderNow, !isPaused {
                    await render()
                } else {
                    needsRenderWhenVisible = true
                }
            }

            guard revision == renderScheduleRevision else { return }
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
        let showLabels = availableSources.count > 1
        let snapshot = await recordStore.snapshot()
        let records = snapshot.records
        let labels = sourceLabels
        let byteLimit = maximumRenderedUTF8Bytes
        let previousChunks = renderedChunks
        let result: (rendered: RenderedLogText, install: LogTextInstallPlan)
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
                return (
                    result,
                    LogTextInstallPlanner.plan(
                        previousChunks: previousChunks,
                        currentChunks: result.chunks
                    )
                )
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
            result = try await withTaskCancellationHandler {
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
            "output_bytes=\(result.rendered.outputUTF8Bytes) rendered_records=\(result.rendered.renderedRecords) removed_utf16=\(result.install.removePrefixUTF16Length) appended_utf8=\(result.install.appendText.utf8.count)"
        )
        let storage = textView.textStorage!
        if storage.length == result.install.previousUTF16Length {
            storage.beginEditing()
            if result.install.removePrefixUTF16Length > 0 {
                storage.replaceCharacters(
                    in: NSRange(location: 0, length: result.install.removePrefixUTF16Length),
                    with: ""
                )
            }
            if !result.install.appendText.isEmpty {
                storage.append(NSAttributedString(
                    string: result.install.appendText,
                    attributes: [.font: textView.font!]
                ))
            }
            storage.endEditing()
        } else {
            // Defensive recovery for an unexpected NSTextStorage mutation;
            // normal streaming updates always take the incremental path.
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: result.rendered.text
            )
            if storage.length > 0, let font = textView.font {
                storage.addAttribute(
                    .font,
                    value: font,
                    range: NSRange(location: 0, length: storage.length)
                )
            }
        }
        renderedChunks = result.rendered.chunks
        latestRenderOmissions = result.rendered.omittedRecords
        updateStatusLabel()
        textView.setSelectedRange(result.install.remapSelection(selectedRange))
        if wasAtTail { textView.scrollToEndOfDocument(nil) }
        needsRenderWhenVisible = false
        keyVisibilityWakePending = false
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
        cancelScheduledRender()
        Task { [weak self, recordStore] in
            _ = await recordStore.clear()
            guard let self else { return }
            latestStoreDrops = 0
            latestRenderOmissions = 0
            updateStatusLabel()
        }
        textView.string = ""
        renderedChunks.removeAll(keepingCapacity: true)
    }

    private var canRenderNow: Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return keyVisibilityWakePending || window.isKeyWindow
            || window.occlusionState.contains(.visible)
    }

    private func suspendRenderingWhileHidden() {
        guard !canRenderNow else { return }
        if pendingRender || !textView.string.isEmpty {
            needsRenderWhenVisible = true
        }
        cancelScheduledRender()
    }

    private func cancelScheduledRender() {
        renderScheduleRevision &+= 1
        renderTask?.cancel()
        renderTask = nil
        pendingRender = false
        renderDirty = false
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
            guard response == .OK, let url = panel.url else { return }
            self?.saveVisibleBufferSnapshot(to: url)
        }
    }

    /// NSTextView is AppKit-owned, so capture its immutable String snapshot on
    /// the main actor. UTF-8 encoding and atomic file I/O then run on a detached
    /// utility task and cannot stall rendering for a multi-megabyte log line.
    func saveVisibleBufferSnapshot(to url: URL) {
        let value = textView.string
        let writer = fileWriter
        statusLabel.stringValue = "Saving \(url.lastPathComponent)…"
        statusLabel.toolTip = nil
        statusLabel.textColor = .secondaryLabelColor
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try writer(value, url)
                }.value
                guard let self, !isClosing else { return }
                statusLabel.stringValue = "Saved \(url.lastPathComponent)"
                statusLabel.toolTip = nil
                statusLabel.textColor = .secondaryLabelColor
            } catch {
                guard let self, !isClosing else { return }
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = "Save failed: \(presentation.inlineText)"
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
            }
        }
    }
}
