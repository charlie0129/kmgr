import AppKit
import KmgrCore

/// The first independent cluster workspace surface. Resource discovery and the
/// table-first split view will replace the centered loading state without
/// changing this window/session ownership boundary.
@MainActor
final class ClusterWorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let session: OpenedClusterSession
    var onClose: (() -> Void)?

    init(session: OpenedClusterSession) {
        self.session = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(session.contextName) — \(Product.applicationName)"
        window.subtitle = session.serverHostname
        window.minSize = NSSize(width: 760, height: 480)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("ClusterWorkspace-\(session.contextName)")
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentViewController = ClusterWorkspacePlaceholderViewController(session: session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterWorkspaceWindowController is programmatic")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

@MainActor
private final class ClusterWorkspacePlaceholderViewController: NSViewController {
    private let session: OpenedClusterSession

    init(session: OpenedClusterSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterWorkspacePlaceholderViewController is programmatic")
    }

    override func loadView() {
        let root = NSView()

        let contextLabel = NSTextField(labelWithString: session.contextName)
        contextLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        contextLabel.alignment = .center

        let clusterValue = session.clusterName.isEmpty ? "—" : session.clusterName
        let hostValue = session.serverHostname.isEmpty ? "—" : session.serverHostname
        let namespaceValue = session.defaultNamespace.isEmpty ? "default" : session.defaultNamespace
        let detailsLabel = NSTextField(
            wrappingLabelWithString:
                "Cluster: \(clusterValue)   ·   Server: \(hostValue)   ·   Namespace: \(namespaceValue)"
        )
        detailsLabel.textColor = .secondaryLabelColor
        detailsLabel.alignment = .center

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)

        let statusLabel = NSTextField(labelWithString: "Connected · Loading resource discovery…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let statusRow = NSStackView(views: [progress, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7

        let content = NSStackView(views: [contextLabel, detailsLabel, statusRow])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -32),
            detailsLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
        view = root
    }
}
