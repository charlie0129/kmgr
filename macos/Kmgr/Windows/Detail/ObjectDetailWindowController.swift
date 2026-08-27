import AppKit
import KmgrCore

/// Utility-window host for the object Summary view.
///
/// The host owns only window lifetime and routing. The Summary controller is
/// the same UID-pinned implementation used by every Details utility window,
/// so reopening an object reuses its existing controller and live watch.
@MainActor
final class ObjectDetailWindowController: NSWindowController, NSWindowDelegate,
    ContextualShortcutProviding
{
    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession
    private let summaryController: ObjectSummaryViewController
    private var hasPresented = false
    private var isClosing = false

    var onClose: (() -> Void)?
    var onOpenEvents: ((ResourceIdentity) -> Void)?
    var onEditMetadata: ((ResourceIdentity, ResourceMetadataKind, String?) -> Void)?
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        summaryController.contextualShortcutSnapshot
    }

    init(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        tableLayoutStore: TableLayoutStore,
        eventsController: (any ObjectDetailEventsControlling)? = nil
    ) {
        self.session = session
        self.identity = identity
        self.summaryController = ObjectSummaryViewController(
            identity: identity,
            provider: provider,
            session: session,
            tableLayoutStore: tableLayoutStore,
            eventsController: eventsController
        )

        let cluster = ClusterIdentityPresentation(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(cluster.titlePrefix) — Details"
        window.subtitle = identity.name
        window.minSize = NSSize(width: 720, height: 520)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = summaryController

        summaryController.onOpenEvents = { [weak self] identity in
            self?.onOpenEvents?(identity)
        }
        summaryController.onEditMetadata = { [weak self] identity, kind, key in
            self?.onEditMetadata?(identity, kind, key)
        }
        summaryController.onContextualShortcutsChanged = { [weak self] in
            self?.contextualShortcutsDidChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func showWindow(_ sender: Any?) {
        let firstPresentation = !hasPresented
        hasPresented = true
        super.showWindow(sender)
        if firstPresentation { window?.center() }
        window?.makeKeyAndOrderFront(sender)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isClosing
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        summaryController.stop()
        onClose?()
    }

    func engineDidDisconnect() {
        summaryController.engineDidDisconnect()
    }

    func stop() {
        summaryController.stop()
    }

    func recover(with recoveredSession: OpenedClusterSession) {
        session = recoveredSession
        identity.clusterSessionID = recoveredSession.sessionID
        let cluster = ClusterIdentityPresentation(session: recoveredSession)
        window?.title = "\(cluster.titlePrefix) — Details"
        window?.subtitle = identity.name
        summaryController.recover(session: recoveredSession) { _ in }
    }

    func refreshAfterMetadataMutation(_ identity: ResourceIdentity) {
        summaryController.refreshAfterMetadataMutation(identity)
    }
}
