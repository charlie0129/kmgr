import AppKit
import KmgrCore

/// Window host for the existing object-centric Details view.
///
/// Details deliberately remains one implementation: the workspace and this
/// auxiliary window share `ObjectDetailViewController`, its UID-pinned GET,
/// watch, YAML editor, relationships, and metadata actions. The host only
/// supplies window lifetime and routing, which keeps the auxiliary destination
/// small and avoids a second Details data model.
@MainActor
final class ObjectDetailWindowController: NSWindowController, NSWindowDelegate,
    ContextualShortcutProviding
{
    private(set) var identity: ResourceIdentity
    private var session: OpenedClusterSession
    private let detailController: ObjectDetailViewController
    private var hasPresented = false
    private var isClosing = false

    var onClose: (() -> Void)?
    var onOpenEvents: ((ResourceIdentity) -> Void)?
    var onEditMetadata: ((ResourceIdentity, ResourceMetadataKind, String?) -> Void)?
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        detailController.contextualShortcutSnapshot
    }

    init(
        session: OpenedClusterSession,
        identity: ResourceIdentity,
        provider: any ObjectDetailProviding,
        tableLayoutStore: TableLayoutStore,
        eventsController: (any ObjectDetailEventsControlling)? = nil,
        initialTab: ObjectDetailInitialTab = .automatic
    ) {
        self.session = session
        self.identity = identity
        self.detailController = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: initialTab,
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
        window.contentViewController = detailController

        detailController.onBack = { [weak self] in
            self?.close()
        }
        detailController.onOpenEvents = { [weak self] identity in
            self?.onOpenEvents?(identity)
        }
        detailController.onEditMetadata = { [weak self] identity, kind, key in
            self?.onEditMetadata?(identity, kind, key)
        }
        detailController.onContextualShortcutsChanged = { [weak self] in
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
        detailController.stop()
        onClose?()
    }

    func engineDidDisconnect() {
        detailController.engineDidDisconnect()
    }

    func stop() {
        detailController.stop()
    }

    func recover(with recoveredSession: OpenedClusterSession) {
        session = recoveredSession
        identity.clusterSessionID = recoveredSession.sessionID
        let cluster = ClusterIdentityPresentation(session: recoveredSession)
        window?.title = "\(cluster.titlePrefix) — Details"
        window?.subtitle = identity.name
        detailController.recover(session: recoveredSession) { _ in }
    }

    func refreshAfterMetadataMutation(_ identity: ResourceIdentity) {
        detailController.refreshAfterMetadataMutation(identity)
    }
}
