import AppKit
import KmgrCore

/// A deliberately small, independent YAML rendering path.
///
/// The object-detail editor has richer presentation and mutation behavior. This
/// window instead installs the server's UTF-8 bytes directly in AppKit's
/// factory-created plain document text view. It does not use Yams, a custom
/// ruler, or `TextDocumentGeometry`.
@MainActor
final class YAMLSnapshotWindowController: NSWindowController, NSWindowDelegate {
    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession
    private let provider: any ObjectDetailProviding
    private var refreshTask: Task<Void, Never>?
    private var refreshRevision: UInt64 = 0
    private var hasRequestedSnapshot = false
    private var displayedYAMLUTF8: Data?
    private var isConnected = true
    private var isClosing = false

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let targetLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let byteCountLabel = NSTextField(labelWithString: "No bytes received")
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let searchField = NSSearchField()

    var onClose: (() -> Void)?

    init(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding
    ) {
        self.session = session
        self.identity = identity
        self.provider = provider

        // This factory supplies AppKit's complete plain-document TextKit stack,
        // including the clip view, scrollers, and document sizing behavior.
        // Keep it intact instead of reconstructing or resizing its document.
        let scrollView = NSTextView.scrollablePlainDocumentContentTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("AppKit did not create a text view for its plain document")
        }
        self.scrollView = scrollView
        self.textView = textView

        let window = YAMLSnapshotWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 520, height: 320)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.readOnlyKeyDownHandler = { [weak self] event in
            self?.performReadOnlySearchShortcut(event) ?? false
        }
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit { refreshTask?.cancel() }

    override func showWindow(_ sender: Any?) {
        let firstPresentation = !hasRequestedSnapshot
        super.showWindow(sender)
        if firstPresentation {
            window?.center()
            refresh()
        }
        if firstPresentation || window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(textView)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        stop()
        onClose?()
    }

    func stop() {
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshButton.isEnabled = false
    }

    /// Invalidates every request made with the old helper session while
    /// retaining the last successfully rendered bytes as an offline snapshot.
    func engineDidDisconnect() {
        isConnected = false
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshButton.isEnabled = false
        statusLabel.stringValue = displayedYAMLUTF8 == nil
            ? "Engine disconnected · no YAML snapshot available"
            : "Engine disconnected · YAML snapshot preserved"
        statusLabel.textColor = .systemOrange
        statusLabel.toolTip = nil
    }

    /// Rebinds the same UID to a newly authenticated helper session and
    /// performs a fresh GET. No request from the previous generation can be
    /// accepted after this point.
    func recover(with recoveredSession: OpenedClusterSession) {
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        session = recoveredSession
        identity.clusterSessionID = recoveredSession.sessionID
        isConnected = true
        updateIdentityPresentation()
        refresh()
    }

    @objc private func refreshPressed(_ sender: Any?) { refresh() }

    private func refresh() {
        guard isConnected, refreshTask == nil, !isClosing else { return }
        guard identity.clusterSessionID == session.sessionID else {
            installFailure(ClusterManagerIssue(
                category: .conflict,
                reason: "StaleClusterSession",
                message: "The YAML window belongs to an expired cluster session.",
                contextName: session.contextName,
                operation: "load YAML snapshot"
            ))
            return
        }

        hasRequestedSnapshot = true
        refreshRevision &+= 1
        let revision = refreshRevision
        let requestedIdentity = identity
        let requestedSessionID = session.sessionID
        refreshButton.isEnabled = false
        statusLabel.stringValue = displayedYAMLUTF8 == nil ? "Loading YAML…" : "Refreshing YAML…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil

        refreshTask = Task { [weak self, provider] in
            guard let self else { return }
            defer {
                if refreshRevision == revision {
                    refreshTask = nil
                    refreshButton.isEnabled = isConnected && !isClosing
                }
            }
            do {
                let detail = try await provider.getObject(identity: requestedIdentity)
                guard !Task.isCancelled, refreshRevision == revision,
                    isConnected, session.sessionID == requestedSessionID
                else { return }
                guard detail.identity == requestedIdentity else {
                    throw ClusterManagerIssue(
                        category: .conflict,
                        reason: "ObjectRecreated",
                        message: "The YAML response did not match the requested UID-pinned object.",
                        contextName: session.contextName,
                        operation: "load YAML snapshot"
                    )
                }
                install(detail)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, refreshRevision == revision else { return }
                installFailure(error)
            }
        }
    }

    private func install(_ detail: ObjectDetail) {
        let yamlUTF8 = detail.yamlUTF8
        let receivedCount = yamlUTF8.count
        byteCountLabel.stringValue = Self.receivedByteText(receivedCount)
        byteCountLabel.toolTip = nil

        guard !yamlUTF8.isEmpty else {
            if let displayedYAMLUTF8, !displayedYAMLUTF8.isEmpty {
                byteCountLabel.stringValue += " · showing previous \(Self.byteText(displayedYAMLUTF8.count))"
                statusLabel.stringValue = "Empty YAML response · previous snapshot preserved"
                statusLabel.textColor = .systemOrange
                statusLabel.toolTip = "The refresh returned zero YAML bytes, so kmgr kept the last non-empty snapshot."
                emptyStateLabel.isHidden = true
            } else {
                displayedYAMLUTF8 = yamlUTF8
                textView.string = ""
                emptyStateLabel.stringValue = "No YAML content was returned (0 bytes)."
                emptyStateLabel.isHidden = false
                statusLabel.stringValue = "Empty YAML response"
                statusLabel.textColor = .systemOrange
                statusLabel.toolTip = "The object response succeeded but contained zero YAML bytes."
            }
            return
        }

        displayedYAMLUTF8 = yamlUTF8
        // Decode the received bytes directly. In particular, do not parse,
        // normalize, serialize, or remove managedFields before first display.
        textView.string = String(decoding: yamlUTF8, as: UTF8.self)
        emptyStateLabel.isHidden = true
        statusLabel.stringValue = detail.resourceVersion.isEmpty
            ? "YAML snapshot"
            : "YAML snapshot · resource version \(detail.resourceVersion)"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
    }

    private func installFailure(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        statusLabel.stringValue = presentation.inlineText
        statusLabel.toolTip = presentation.detailedText
        statusLabel.textColor = .systemRed
        refreshButton.isEnabled = isConnected && refreshTask == nil && !isClosing
        if displayedYAMLUTF8 == nil {
            emptyStateLabel.stringValue = "YAML could not be loaded."
            emptyStateLabel.isHidden = false
        }
    }

    private func configureWindow() {
        updateIdentityPresentation()

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.setAccessibilityLabel("Kubernetes YAML snapshot")

        scrollView.identifier = .init("yaml-snapshot-scroll")
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.identifier = .init("yaml-snapshot-target")
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.identifier = .init("yaml-snapshot-status")
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor
        byteCountLabel.identifier = .init("yaml-snapshot-byte-count")
        byteCountLabel.lineBreakMode = .byTruncatingTail
        byteCountLabel.textColor = .secondaryLabelColor
        byteCountLabel.alignment = .right

        emptyStateLabel.identifier = .init("yaml-snapshot-empty-state")
        emptyStateLabel.alignment = .center
        emptyStateLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed(_:))
        refreshButton.identifier = .init("yaml-snapshot-refresh")
        refreshButton.toolTip = "Fetch a fresh snapshot of this exact UID."

        searchField.identifier = .init("yaml-snapshot-search")
        searchField.placeholderString = "Find (/)"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchSubmitted(_:))
        searchField.toolTip = "Press / to focus search. Press Return, then use n and N for the next and previous match."
        searchField.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let spacer = NSView()
        let header = NSStackView(views: [targetLabel, spacer, searchField, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let statusSpacer = NSView()
        let footer = NSStackView(views: [statusLabel, statusSpacer, byteCountLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        byteCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let root = NSView()
        root.addSubview(header)
        root.addSubview(scrollView)
        root.addSubview(emptyStateLabel)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24
            ),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24
            ),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window?.contentView = root
    }

    private func updateIdentityPresentation() {
        let cluster = ClusterIdentityPresentation(session: session)
        let scope = identity.namespace.isEmpty ? identity.name : "\(identity.namespace)/\(identity.name)"
        let api = identity.group.isEmpty
            ? "\(identity.version)/\(identity.resource)"
            : "\(identity.group)/\(identity.version)/\(identity.resource)"
        window?.title = "\(cluster.titlePrefix) — YAML — \(scope)"
        window?.subtitle = "\(api) · UID \(identity.uid.rawValue)"
        targetLabel.stringValue = "\(api) · \(scope) · UID \(identity.uid.rawValue)"
        targetLabel.toolTip = cluster.targetDetails(identity)
    }

    /// Search accelerators are intentionally scoped to a read-only YAML text
    /// responder. The find field and any future editable mode receive ordinary
    /// key events, so entering a query (or YAML) never loses `n`, `N`, or `/`.
    @discardableResult
    func performReadOnlySearchShortcut(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === textView,
            let action = YAMLSnapshotSearchShortcut.action(
                characters: event.characters,
                modifiers: event.modifierFlags,
                textIsEditable: textView.isEditable
            )
        else { return false }
        switch action {
        case .focusSearch:
            window?.makeFirstResponder(searchField)
            searchField.selectText(nil)
        case .next:
            selectSearchMatch(forward: true)
        case .previous:
            selectSearchMatch(forward: false)
        }
        return true
    }

    @objc private func searchSubmitted(_ sender: Any?) {
        guard !textView.isEditable else { return }
        selectSearchMatch(forward: true)
        // Hand the responder back after Return so n/N navigate matches instead
        // of becoming additional query characters. Clicking the field allows
        // the operator to revise the query at any time.
        window?.makeFirstResponder(textView)
    }

    private func selectSearchMatch(forward: Bool) {
        let query = searchField.stringValue
        guard !query.isEmpty, !textView.string.isEmpty else {
            NSSound.beep()
            return
        }
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let options: NSString.CompareOptions = forward ? [] : [.backwards]
        let primaryRange: NSRange
        let wrappedRange: NSRange
        if forward {
            let start = min(NSMaxRange(selection), source.length)
            primaryRange = NSRange(location: start, length: source.length - start)
            wrappedRange = NSRange(location: 0, length: start)
        } else {
            let end = min(selection.location, source.length)
            primaryRange = NSRange(location: 0, length: end)
            wrappedRange = NSRange(location: end, length: source.length - end)
        }
        var match = source.range(of: query, options: options, range: primaryRange)
        if match.location == NSNotFound {
            match = source.range(of: query, options: options, range: wrappedRange)
        }
        guard match.location != NSNotFound else {
            NSSound.beep()
            return
        }
        textView.setSelectedRange(match)
        textView.scrollRangeToVisible(match)
        textView.showFindIndicator(for: match)
    }

    static func receivedByteText(_ count: Int) -> String {
        "Received \(byteText(count))"
    }

    private static func byteText(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "byte" : "bytes")"
    }
}

enum YAMLSnapshotSearchAction: Equatable {
    case focusSearch
    case next
    case previous
}

enum YAMLSnapshotSearchShortcut {
    static func action(
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        textIsEditable: Bool
    ) -> YAMLSnapshotSearchAction? {
        guard !textIsEditable, let characters else { return nil }
        let significantModifiers = modifiers.intersection([.command, .control, .option, .shift])
        switch (characters, significantModifiers) {
        case ("/", []):
            return .focusSearch
        case ("n", []):
            return .next
        case ("N", [.shift]):
            return .previous
        case ("\r", []), ("\n", []):
            return .next
        default:
            return nil
        }
    }
}

/// Intercepts only the handful of read-only YAML accelerators before AppKit
/// dispatches a key-down event to the plain text view. All other events follow
/// the normal responder chain unchanged.
private final class YAMLSnapshotWindow: NSWindow {
    var readOnlyKeyDownHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, readOnlyKeyDownHandler?(event) == true { return }
        super.sendEvent(event)
    }
}
