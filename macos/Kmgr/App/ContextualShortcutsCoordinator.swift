import AppKit
import KmgrCore

/// Window-level opt-in for the passive shortcuts panel. Providers expose a
/// current snapshot and invalidate it only when command facts or focus context
/// change; the application remains responsible for presentation and lifetime.
@MainActor
protocol ContextualShortcutProviding: AnyObject {
    var contextualShortcutSnapshot: ContextualShortcutSnapshot? { get }
    var contextualShortcutsDidChange: (() -> Void)? { get set }
}

/// Child windows must explicitly opt in before the coordinator may reuse their
/// parent's context. Unknown sheets and panels receive generic help instead of
/// inheriting dangerous single-letter resource commands.
@MainActor
protocol ContextualShortcutParentFallbackEligible: AnyObject {}

@MainActor
final class ContextualShortcutsCoordinator: NSObject {
    static let isEnabledStorageKey = "kmgr.contextual-shortcuts.enabled"

    let shortcutsWindowController: ContextualShortcutsWindowController

    private weak var application: NSApplication?
    private weak var observedProviderObject: AnyObject?
    private let defaults: UserDefaults
    private var isStarted = false
    private(set) var isEnabled: Bool
    private var refreshTask: Task<Void, Never>?

    init(
        application: NSApplication,
        defaults: UserDefaults = .standard,
        shortcutsWindowController: ContextualShortcutsWindowController =
            ContextualShortcutsWindowController()
    ) {
        self.application = application
        self.defaults = defaults
        self.isEnabled = Self.loadIsEnabled(from: defaults)
        self.shortcutsWindowController = shortcutsWindowController
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(lifecycleDidChange(_:)),
                name: name,
                object: nil
            )
        }
        scheduleRefresh()
    }

    func stop() {
        guard isStarted else {
            hideAndUnbind()
            return
        }
        isStarted = false
        refreshTask?.cancel()
        refreshTask = nil
        NotificationCenter.default.removeObserver(self)
        hideAndUnbind()
    }

    /// Deterministic entry point used by lifecycle notifications and focused
    /// AppKit tests. The production path supplies `NSApplication.isActive` and
    /// its current key window.
    func synchronize(isApplicationActive: Bool, keyWindow: NSWindow?) {
        guard isEnabled else {
            hideAndUnbind()
            return
        }
        guard isApplicationActive,
            let keyWindow,
            keyWindow !== shortcutsWindowController.window
        else {
            hideAndUnbind()
            return
        }

        let resolution = resolve(keyWindow: keyWindow)
        bind(to: resolution.provider)
        guard let snapshot = resolution.snapshot, !snapshot.items.isEmpty else {
            shortcutsWindowController.hide()
            return
        }
        shortcutsWindowController.present(snapshot, relativeTo: keyWindow)
    }

    func toggle() {
        setEnabled(!isEnabled)
    }

    func closeFromUser() {
        setEnabled(false)
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.isEnabledStorageKey)
        if !enabled {
            hideAndUnbind()
        } else {
            scheduleRefresh()
        }
    }

    private static func loadIsEnabled(from defaults: UserDefaults) -> Bool {
        guard let savedValue = defaults.object(forKey: isEnabledStorageKey) else {
            return true
        }
        guard CFGetTypeID(savedValue as CFTypeRef) == CFBooleanGetTypeID(),
            let isEnabled = savedValue as? Bool
        else {
            defaults.removeObject(forKey: isEnabledStorageKey)
            return true
        }
        return isEnabled
    }

    private func refresh() {
        guard let application else {
            hideAndUnbind()
            return
        }
        synchronize(
            isApplicationActive: application.isActive,
            keyWindow: application.keyWindow
        )
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Window handoffs send resign-key before become-key. Coalescing one
            // main-actor turn avoids hiding and immediately flashing the panel.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
            self?.refresh()
        }
    }

    @objc private func lifecycleDidChange(_ notification: Notification) {
        if notification.name == NSApplication.didResignActiveNotification {
            refreshTask?.cancel()
            refreshTask = nil
            synchronize(isApplicationActive: false, keyWindow: nil)
        } else if notification.name == NSWindow.willCloseNotification,
            notification.object as? NSWindow === application?.keyWindow
        {
            // Remove the passive panel before AppKit evaluates whether the last
            // user window closed. It must never keep the process alive itself.
            hideAndUnbind()
            if isEnabled { scheduleRefresh() }
        } else {
            scheduleRefresh()
        }
    }

    private func bind(to provider: (any ContextualShortcutProviding)?) {
        let nextObject = provider.map { $0 as AnyObject }
        guard observedProviderObject !== nextObject else { return }
        if let current = observedProviderObject as? any ContextualShortcutProviding {
            current.contextualShortcutsDidChange = nil
        }
        observedProviderObject = nextObject
        provider?.contextualShortcutsDidChange = { [weak self, weak nextObject] in
            guard let self, self.observedProviderObject === nextObject else { return }
            self.scheduleRefresh()
        }
    }

    private func hideAndUnbind() {
        bind(to: nil)
        shortcutsWindowController.hide()
    }

    private func resolve(keyWindow: NSWindow) -> (
        provider: (any ContextualShortcutProviding)?,
        snapshot: ContextualShortcutSnapshot?
    ) {
        if let provider = provider(for: keyWindow) {
            return (provider, provider.contextualShortcutSnapshot)
        }

        if keyWindow.windowController is any ContextualShortcutParentFallbackEligible,
            let parent = keyWindow.parent,
            let provider = provider(for: parent)
        {
            return (provider, provider.contextualShortcutSnapshot)
        }

        if keyWindow.sheetParent != nil || keyWindow.parent != nil {
            return (nil, ContextualShortcutCatalog.genericDialog)
        }
        return (nil, nil)
    }

    private func provider(for window: NSWindow) -> (any ContextualShortcutProviding)? {
        if let provider = window.windowController as? any ContextualShortcutProviding {
            return provider
        }
        return window.contentViewController as? any ContextualShortcutProviding
    }
}

@MainActor
final class ContextualShortcutsWindowController: NSWindowController {
    private let contentController = ContextualShortcutsContentViewController()
    private(set) var currentSnapshot: ContextualShortcutSnapshot?
    private var positionedHostWindowNumber: Int?
    var onUserClose: (() -> Void)?

    init() {
        let panel = PassiveContextualShortcutsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shortcuts"
        panel.titleVisibility = .visible
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.worksWhenModal = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.animationBehavior = .utilityWindow
        panel.standardWindowButton(.closeButton)?.isHidden = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setAccessibilityLabel("Contextual keyboard shortcuts")
        panel.contentViewController = contentController
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    func present(_ snapshot: ContextualShortcutSnapshot, relativeTo hostWindow: NSWindow) {
        if currentSnapshot != snapshot {
            currentSnapshot = snapshot
            contentController.apply(snapshot)
            window?.setContentSize(contentController.desiredContentSize)
        }
        guard let panel = window else { return }
        if !panel.isVisible || positionedHostWindowNumber != hostWindow.windowNumber {
            position(panel, relativeTo: hostWindow)
            positionedHostWindowNumber = hostWindow.windowNumber
        }
        // This is intentionally not `orderFrontRegardless`: the panel follows
        // normal application activation and never raises Kmgr over another app.
        panel.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        positionedHostWindowNumber = nil
    }

    private func position(_ panel: NSWindow, relativeTo hostWindow: NSWindow) {
        let visibleFrame = hostWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? hostWindow.frame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frame.width - 16,
            y: visibleFrame.maxY - frame.height - 16
        ))
    }
}

extension ContextualShortcutsWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onUserClose?()
        return true
    }
}

@MainActor
private final class ContextualShortcutsContentViewController: NSViewController {
    private let contextLabel = NSTextField(labelWithString: "")
    private let rows = NSStackView()
    private(set) var desiredContentSize = NSSize(width: 360, height: 180)

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState

        contextLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setAccessibilityIdentifier("contextual-shortcuts.context")

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 7
        rows.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [contextLabel, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = effect
    }

    func apply(_ snapshot: ContextualShortcutSnapshot) {
        loadViewIfNeeded()
        contextLabel.stringValue = snapshot.title
        contextLabel.setAccessibilityLabel("Shortcuts for \(snapshot.title)")
        view.setAccessibilityLabel("Keyboard shortcuts for \(snapshot.title)")
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for item in snapshot.items {
            let keys = NSTextField(labelWithString: item.keys)
            keys.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            keys.textColor = .controlAccentColor
            keys.alignment = .right
            keys.lineBreakMode = .byTruncatingTail
            keys.setAccessibilityLabel("Keyboard shortcut \(item.keys)")
            keys.setAccessibilityIdentifier("contextual-shortcut.keys.\(item.id)")
            keys.widthAnchor.constraint(equalToConstant: 94).isActive = true

            let action = NSTextField(wrappingLabelWithString: item.action)
            action.font = .systemFont(ofSize: 12)
            action.maximumNumberOfLines = 2
            action.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            action.setAccessibilityIdentifier("contextual-shortcut.action.\(item.id)")

            let row = NSStackView(views: [keys, action])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.group)
            row.setAccessibilityLabel("\(item.keys), \(item.action)")
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        let height = CGFloat(48 + snapshot.items.count * 27)
        desiredContentSize = NSSize(width: 360, height: min(max(height, 100), 500))
    }
}

private final class PassiveContextualShortcutsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
