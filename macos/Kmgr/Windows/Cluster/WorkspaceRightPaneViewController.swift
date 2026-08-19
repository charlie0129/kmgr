import AppKit

@MainActor
final class WorkspaceRightPaneViewController: NSViewController {
    private let contentContainer = NSView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progressIndicator = NSProgressIndicator()
    private let connectionActivityView: ClusterConnectionActivityView
    private var board = WorkspaceStatusBoard()
    private(set) weak var activeContentController: NSViewController?

    init(connectionActivityView: ClusterConnectionActivityView) {
        self.connectionActivityView = connectionActivityView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func loadView() {
        let root = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.identifier = .init("workspace-status-line")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityLabel("Workspace status")

        progressIndicator.identifier = .init("workspace-status-progress")
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.setAccessibilityLabel("Workspace operation in progress")
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [
            progressIndicator, statusLabel, NSView(), connectionActivityView,
        ])
        footer.identifier = .init("workspace-status-bar")
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 3, right: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(contentContainer)
        root.addSubview(separator)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 24),
            progressIndicator.widthAnchor.constraint(equalToConstant: 14),
            progressIndicator.heightAnchor.constraint(equalToConstant: 14),
        ])
        view = root
        renderStatus()
    }

    func setContent(
        _ controller: NSViewController,
        initialStatus: WorkspaceStatus
    ) {
        loadViewIfNeeded()
        board.set(initialStatus, for: .content)
        board.set(nil, for: .workspaceOperation)
        renderStatus()
        if activeContentController !== controller {
            activeContentController?.view.removeFromSuperview()
            activeContentController?.removeFromParent()
            addChild(controller)
            activeContentController = controller
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }
    }

    func updateContentStatus(
        _ status: WorkspaceStatus,
        from controller: NSViewController
    ) {
        guard activeContentController === controller else { return }
        board.set(status, for: .content)
        renderStatus()
    }

    func setSupplementalStatus(
        _ status: WorkspaceStatus?,
        for source: WorkspaceStatusSource
    ) {
        precondition(source != .content)
        guard board.status(for: source) != status else { return }
        board.set(status, for: source)
        renderStatus()
    }

    func clearSupplementalStatus(
        _ expectedStatus: WorkspaceStatus,
        for source: WorkspaceStatusSource
    ) {
        guard board.status(for: source) == expectedStatus else { return }
        setSupplementalStatus(nil, for: source)
    }

    private func renderStatus() {
        guard isViewLoaded else { return }
        let status = board.presented
        statusLabel.stringValue = status.text
        statusLabel.toolTip = status.toolTip
        statusLabel.textColor = switch status.severity {
        case .informational: .secondaryLabelColor
        case .warning: .systemOrange
        case .error: .systemRed
        }
        statusLabel.setAccessibilityValue(status.text)
        if status.busy {
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
        }
    }
}
