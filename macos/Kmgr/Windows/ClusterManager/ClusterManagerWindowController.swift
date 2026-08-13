import AppKit
import KmgrCore

final class ClusterManagerWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cluster Manager"
        window.minSize = NSSize(width: 560, height: 320)
        window.center()

        self.init(window: window)
        window.contentViewController = ClusterManagerViewController()
    }
}

private final class ClusterManagerViewController: NSViewController {
    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: Product.applicationName)
        title.font = .systemFont(ofSize: 28, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString: "Open a kubeconfig context in an independent workspace window."
        )
        subtitle.textColor = .secondaryLabelColor

        let status = NSTextField(labelWithString: "Starting Kubernetes engine…")
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.identifier = NSUserInterfaceItemIdentifier("engine-status")

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)

        let statusRow = NSStackView(views: [progress, status])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY

        let content = NSStackView(views: [title, subtitle, statusRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28)
        ])

        view = root
    }
}
