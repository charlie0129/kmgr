import AppKit
import KmgrCore
import OSLog

enum LogTailReconciliationPolicy {
    static func shouldPreserveTail(
        requestedAtScheduleTime: Bool,
        currentlyAtTail: Bool
    ) -> Bool {
        requestedAtScheduleTime && currentlyAtTail
    }
}

enum LogWindowShortcut: Equatable {
    case focusFilter
    case toggleFollow
    case togglePause
    case toggleWrap

    static func action(
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        textIsEditable: Bool
    ) -> Self? {
        guard !textIsEditable,
            modifiers.intersection([.command, .control, .option]).isEmpty
        else { return nil }
        return switch characters?.lowercased() {
        case "/": .focusFilter
        case "f": .toggleFollow
        case "p": .togglePause
        case "w": .toggleWrap
        default: nil
        }
    }
}

@MainActor
final class LogWindowController: NSWindowController, NSWindowDelegate,
    NSSearchFieldDelegate, ContextualShortcutProviding
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
    private var layoutMetricsTask: Task<Void, Never>?
    private var layoutMetricsRevision: UInt64 = 0
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
    private var latestDisplayContinuationBreaks = 0
    private var latestDisplayTruncatedLines = 0
    private var latestStreamState: LogStreamState = .connecting
    private var renderedChunks: [String] = []
    private var renderedExportChunks: [String] = []
    private var renderedDisplayUTF16Length = 0
    private var textLayoutMetrics = LogTextLayoutMetrics.empty
    private var followsVisibleTail = true
    private var tailTrackingSuppressionDepth = 0
    private var lastObservedViewportOrigin = NSPoint.zero
    private var pendingFollowTailRestore: Bool?
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
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        ContextualShortcutCatalog.logs
    }

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
        let window = LogShortcutWindow(
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
        window.keyDownHandler = { [weak self] event in
            self?.performLogShortcut(event) ?? false
        }
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

    func prepareForTermination() {
        isClosing = true
        stopStream()
    }

    func windowWillClose(_ notification: Notification) {
        prepareForTermination()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.frameDidChangeNotification,
            object: textView
        )
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

    func windowDidResize(_ notification: Notification) {
        let wasFollowingTail = followsVisibleTail
        updateTextDocumentGeometry(followingTail: wasFollowingTail)
        if wasFollowingTail { scrollToTail() }
        scheduleLayoutMetricsReconciliation(preservingTail: wasFollowingTail)
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

    /// Tail-follow intent is a user interaction state, not a document-geometry
    /// measurement. TextKit can revise a noncontiguous document's extent after
    /// a render; only an actual viewport-origin change outside our own geometry
    /// and scroll operations may pause or resume automatic tail following. A
    /// viewport pause does not stop the already-established backend stream.
    @objc private func logViewportBoundsDidChange(_ notification: Notification) {
        let origin = scrollView.contentView.bounds.origin
        defer { lastObservedViewportOrigin = origin }
        guard !isClosing, tailTrackingSuppressionDepth == 0,
            origin != lastObservedViewportOrigin
        else { return }
        followsVisibleTail = isAtTail
        updateFollowButtonPresentation()
    }

    /// NSTextView can refine a noncontiguous document's height after the
    /// initial tail render has returned. Keep Follow pinned across those late
    /// frame corrections; a user scroll has already cleared
    /// `followsVisibleTail` through the clip-view bounds observer above.
    @objc private func logDocumentFrameDidChange(_ notification: Notification) {
        guard !isClosing, tailTrackingSuppressionDepth == 0, followsVisibleTail
        else { return }
        scrollToTail()
    }

    func controlTextDidChange(_ obj: Notification) { scheduleRender() }

    /// Route unmodified log-window accelerators through the same actions as
    /// their controls. AppKit field editors retain every key while the user is
    /// changing a filter or stream option.
    @discardableResult
    func performLogShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            let action = LogWindowShortcut.action(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags,
                textIsEditable: (window?.firstResponder as? NSTextView)?.isEditable == true
            )
        else { return false }
        guard !event.isARepeat else { return true }

        switch action {
        case .focusFilter:
            guard searchField.isEnabled else { return true }
            window?.makeFirstResponder(searchField)
            searchField.selectText(nil)
        case .toggleFollow:
            guard followButton.isEnabled else { return true }
            followButton.state = followButton.state == .on ? .off : .on
            toggleFollow()
        case .togglePause:
            guard pauseButton.isEnabled else { return true }
            togglePause()
        case .toggleWrap:
            guard wrapButton.isEnabled else { return true }
            wrapButton.state = wrapButton.state == .on ? .off : .on
            toggleWrap()
        }
        return true
    }

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
        followButton.target = self
        followButton.action = #selector(toggleFollow)
        for button in [previousButton, timestampsButton] {
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
        textView.setAccessibilityLabel("Pod logs")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.identifier = NSUserInterfaceItemIdentifier("log-content-scroll")
        TextDocumentGeometry.configureStreamingLog(
            textView,
            in: scrollView
        )
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(logDocumentFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        let clipView = scrollView.contentView
        lastObservedViewportOrigin = clipView.bounds.origin
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(logViewportBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
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
        root.layoutSubtreeIfNeeded()
        updateTextDocumentGeometry()
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
        options.previous = previousButton.state == .on
        options.timestamps = timestampsButton.state == .on
        options.since = nil
        options.sinceSeconds = since.flatMap { $0 == 0 ? nil : $0 }
        options.tailLines = tail
        updateSourcePresentation()
        startStream()
    }

    @objc private func toggleFollow() {
        guard pendingGeneration == nil else { return }
        let requestedFollow = followButton.state == .on
        if requestedFollow {
            let previousTailState = followsVisibleTail
            followsVisibleTail = true
            scrollToTail()
            guard !options.follow else {
                updateFollowButtonPresentation()
                return
            }
            pendingFollowTailRestore = previousTailState
            options.follow = true
            startStream()
        } else {
            let previousTailState = followsVisibleTail
            followsVisibleTail = false
            guard options.follow else {
                updateFollowButtonPresentation()
                return
            }
            pendingFollowTailRestore = previousTailState
            options.follow = false
            startStream()
        }
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
        updateFollowButtonPresentation()
        previousButton.state = options.previous ? .on : .off
        timestampsButton.state = options.timestamps ? .on : .off
        containerButton.selectItem(withTitle: appliedContainerTitle)
        tailField.stringValue = options.tailLines.map(String.init) ?? ""
        sinceField.stringValue = options.sinceSeconds.map(String.init) ?? ""
    }

    private func restoreEstablishedStreamConfiguration() {
        restorePendingFollowTailState()
        guard let establishedConfiguration else { return }
        sources = establishedConfiguration.sources
        options = establishedConfiguration.options
        appliedContainerTitle = establishedConfiguration.containerTitle
        restoreAppliedStreamControls()
        updateSourcePresentation()
    }

    private func restorePendingFollowTailState() {
        guard let pendingFollowTailRestore else { return }
        followsVisibleTail = pendingFollowTailRestore
        self.pendingFollowTailRestore = nil
    }

    private func updateFollowButtonPresentation() {
        followButton.state = options.follow && followsVisibleTail ? .on : .off
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
                        if !request.options.follow {
                            self?.followsVisibleTail = false
                            self?.updateFollowButtonPresentation()
                        }
                        self?.pendingFollowTailRestore = nil
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
        cancelLayoutMetricsReconciliation()
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
        if latestDisplayContinuationBreaks > 0 {
            parts.append("long lines segmented for display")
        }
        if latestDisplayTruncatedLines > 0 {
            parts.append(latestDisplayTruncatedLines == 1
                ? "1 long line truncated"
                : "\(latestDisplayTruncatedLines.formatted()) long lines truncated")
        }
        statusLabel.stringValue = parts.joined(separator: " · ")
        switch (latestDisplayContinuationBreaks > 0, latestDisplayTruncatedLines > 0) {
        case (_, true):
            statusLabel.toolTip = "Long lines show at most 4 KiB. Display markers and breaks are not included when saving."
        case (true, false):
            statusLabel.toolTip = "Continuation arrows and line breaks are display-only; Save preserves logical lines."
        case (false, false):
            statusLabel.toolTip = nil
        }
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
        let selectedRange = textView.selectedRange()
        let filter = searchField.stringValue
        let showLabels = availableSources.count > 1
        let snapshot = await recordStore.snapshot()
        let records = snapshot.records
        let labels = sourceLabels
        let byteLimit = maximumRenderedUTF8Bytes
        let previousChunks = renderedChunks
        let wrappingColumnCapacity = TextDocumentGeometry
            .streamingLogWrappingColumnCapacity(textView, in: scrollView)
        let result: (
            rendered: RenderedLogText,
            install: LogTextInstallPlan,
            layoutMetrics: LogTextLayoutMetrics
        )
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
                    rendered: result,
                    install: LogTextInstallPlanner.plan(
                        previousChunks: previousChunks,
                        currentChunks: result.displayChunks
                    ),
                    layoutMetrics: LogTextLayoutMetrics(
                        chunks: result.displayChunks,
                        wrappingColumnCapacity: wrappingColumnCapacity
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
        let shouldFollowTail = followsVisibleTail
        let installInterval = logSignposter.beginInterval(
            PerformanceSignpostCatalog.logTextInstall,
            "logical_output_bytes=\(result.rendered.outputUTF8Bytes) display_output_bytes=\(result.rendered.displayOutputUTF8Bytes) rendered_records=\(result.rendered.renderedRecords) truncated_lines=\(result.rendered.displayTruncatedLines) removed_utf16=\(result.install.removePrefixUTF16Length) appended_utf8=\(result.install.appendText.utf8.count)"
        )
        tailTrackingSuppressionDepth += 1
        defer { tailTrackingSuppressionDepth -= 1 }
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
                with: result.rendered.displayText
            )
            if storage.length > 0, let font = textView.font {
                storage.addAttribute(
                    .font,
                    value: font,
                    range: NSRange(location: 0, length: storage.length)
                )
            }
        }
        renderedChunks = result.rendered.displayChunks
        renderedExportChunks = result.rendered.chunks
        renderedDisplayUTF16Length = result.install.resultUTF16Length
        cancelLayoutMetricsReconciliation()
        textLayoutMetrics = result.layoutMetrics
        latestRenderOmissions = result.rendered.omittedRecords
        latestDisplayContinuationBreaks = result.rendered.displayContinuationBreaks
        latestDisplayTruncatedLines = result.rendered.displayTruncatedLines
        updateStatusLabel()
        textView.setSelectedRange(result.install.remapSelection(selectedRange))
        updateTextDocumentGeometry(followingTail: shouldFollowTail)
        if shouldFollowTail { scrollToTail() }
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
        let wasFollowingTail = followsVisibleTail
        let enabled = wrapButton.state == .on
        scrollView.hasHorizontalScroller = !enabled
        updateTextDocumentGeometry(followingTail: wasFollowingTail)
        if wasFollowingTail { scrollToTail() }
        scheduleLayoutMetricsReconciliation(preservingTail: wasFollowingTail)
    }

    private func updateTextDocumentGeometry(followingTail: Bool = false) {
        withTailTrackingSuppressed {
            TextDocumentGeometry.updateStreamingLog(
                textView,
                in: scrollView,
                wrapsToViewport: wrapButton.state == .on,
                metrics: textLayoutMetrics,
                followingTail: followingTail
            )
        }
    }

    /// Resizes and Wrap can arrive in rapid bursts. Re-measure immutable
    /// rendered chunks after a short debounce on a detached executor, then
    /// install only the content-free arithmetic result on MainActor.
    private func scheduleLayoutMetricsReconciliation(preservingTail: Bool) {
        layoutMetricsRevision &+= 1
        let revision = layoutMetricsRevision
        layoutMetricsTask?.cancel()
        let chunks = renderedChunks
        let capacity = TextDocumentGeometry.streamingLogWrappingColumnCapacity(
            textView,
            in: scrollView
        )
        layoutMetricsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let metrics = await Task.detached(priority: .utility) {
                LogTextLayoutMetrics(
                    chunks: chunks,
                    wrappingColumnCapacity: capacity
                )
            }.value
            guard let self, !Task.isCancelled,
                revision == layoutMetricsRevision,
                !isClosing
            else { return }
            layoutMetricsTask = nil
            // A resize may have been scheduled while Follow was at the end,
            // but an intervening user scroll revokes that stale intent.
            let shouldPreserveTail = LogTailReconciliationPolicy.shouldPreserveTail(
                requestedAtScheduleTime: preservingTail,
                currentlyAtTail: followsVisibleTail
            )
            textLayoutMetrics = metrics
            updateTextDocumentGeometry(followingTail: shouldPreserveTail)
            if shouldPreserveTail { scrollToTail() }
        }
    }

    private func scrollToTail() {
        // Reflecting the first scroll can itself make TextKit publish a more
        // accurate noncontiguous document height. Re-evaluate the arithmetic
        // tail against that new frame before returning; later asynchronous
        // corrections are handled by `logDocumentFrameDidChange`.
        for _ in 0..<4 {
            withTailTrackingSuppressed {
                TextDocumentGeometry.scrollStreamingLogToTail(textView, in: scrollView)
            }
            if isAtTail { break }
        }
        followsVisibleTail = true
    }

    private func withTailTrackingSuppressed<T>(_ operation: () throws -> T) rethrows -> T {
        tailTrackingSuppressionDepth += 1
        defer { tailTrackingSuppressionDepth -= 1 }
        return try operation()
    }

    private func cancelLayoutMetricsReconciliation() {
        layoutMetricsRevision &+= 1
        layoutMetricsTask?.cancel()
        layoutMetricsTask = nil
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
            latestDisplayContinuationBreaks = 0
            latestDisplayTruncatedLines = 0
            updateStatusLabel()
        }
        textView.string = ""
        renderedChunks.removeAll(keepingCapacity: true)
        renderedExportChunks.removeAll(keepingCapacity: true)
        renderedDisplayUTF16Length = 0
        textLayoutMetrics = .empty
        followsVisibleTail = true
        updateFollowButtonPresentation()
        cancelLayoutMetricsReconciliation()
        updateTextDocumentGeometry()
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

    /// NSTextView is AppKit-owned, so a defensive direct-text snapshot is taken
    /// on MainActor. Normal rendered logs instead capture their immutable chunk
    /// array; joining, UTF-8 encoding, and file I/O all stay off MainActor even
    /// for a multi-megabyte logical line.
    func saveVisibleBufferSnapshot(to url: URL) {
        // Tests and defensive callers can mutate NSTextStorage directly. Use
        // the lossless logical projection only while it still describes the
        // installed display; otherwise snapshot the AppKit value as before.
        let hasCurrentProjection = !renderedChunks.isEmpty
            && textView.textStorage?.length == renderedDisplayUTF16Length
        let exportChunks = hasCurrentProjection ? renderedExportChunks : nil
        let fallbackValue = hasCurrentProjection ? nil : textView.string
        let writer = fileWriter
        statusLabel.stringValue = "Saving \(url.lastPathComponent)…"
        statusLabel.toolTip = nil
        statusLabel.textColor = .secondaryLabelColor
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    let value = exportChunks?.joined() ?? fallbackValue ?? ""
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

/// Intercepts only log accelerators before the focused read-only text view
/// receives them. Every unrecognized key continues through AppKit unchanged.
private final class LogShortcutWindow: NSWindow {
    var keyDownHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyDownHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
