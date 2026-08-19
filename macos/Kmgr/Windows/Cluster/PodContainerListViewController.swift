import AppKit
import KmgrCore

enum PodContainerNetworkAction: Equatable {
    case openLogs
    case openPreviousLogs
    case openAutomaticExec
    case configureExec
    case startPortForward
}

@MainActor
final class PodContainerListViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, WorkspaceStatusPublishing
{
    var onBack: (() -> Void)?
    var onOpenLogs: ((LogOpenRequest) -> Void)?
    var onOpenExec: ((PodExecTarget) -> Void)?
    var onConfigureExec: ((PodExecTarget) -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?
    private(set) var workspaceStatus: WorkspaceStatus
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot {
        let hasSelectedContainer = tableView.selectedRow >= 0
        return ContextualShortcutCatalog.containerList(
            canOpenLogs: networkActionsEnabled && hasSelectedContainer,
            canOpenTerminal: networkActionsEnabled && hasSelectedContainer,
            canStartPortForward: networkActionsEnabled
        )
    }

    private let pod: ResourceIdentity
    private let containers: [PodContainerDetail]
    private let tableLayoutStore: TableLayoutStore
    private let tableView = PodContainerTableView()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var networkActionsEnabled = true
    private var tableLayoutBinding: TableLayoutBinding?

    init(
        pod: ResourceIdentity,
        containers: [PodContainerDetail],
        tableLayoutStore: TableLayoutStore? = nil
    ) {
        self.pod = pod
        self.containers = containers
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.workspaceStatus = WorkspaceStatus(Self.countText(containers.count))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func loadView() {
        let root = NSView()
        let backButton = NSButton(
            image: NSImage(
                systemSymbolName: "chevron.left",
                accessibilityDescription: "Back to resource list"
            )!,
            target: self,
            action: #selector(back)
        )
        backButton.bezelStyle = .texturedRounded

        let parentName = pod.namespace.isEmpty
            ? pod.name : "\(pod.namespace)/\(pod.name)"
        let breadcrumb = NSTextField(
            labelWithString: "\(pod.resource)/\(parentName) · Containers"
        )
        breadcrumb.font = .systemFont(ofSize: 15, weight: .semibold)
        breadcrumb.lineBreakMode = .byTruncatingMiddle

        let header = NSStackView(views: [backButton, breadcrumb, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        tableLayoutBinding = TableLayoutBinding(
            tableView: tableView,
            surface: .podContainers,
            store: tableLayoutStore
        )
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        actionButton.target = self
        actionButton.action = #selector(performPrimaryAction)
        actionButton.bezelStyle = .rounded
        actionButton.title = "Open Selected Container Logs"
        actionButton.setAccessibilityLabel("Open logs for selected container")
        let hint = NSTextField(labelWithString: shortcutHint)
        hint.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [hint, NSView(), actionButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        updateSelectionControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !containers.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(tableView)
        updateSelectionControls()
        onContextualShortcutsChanged?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { containers.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        if containers.indices.contains(row),
            ["cpu", "memory"].contains(tableColumn.identifier.rawValue)
        {
            return resourceUsageCell(
                in: tableView,
                columnID: tableColumn.identifier.rawValue,
                container: containers[row]
            )
        }
        let identifier = NSUserInterfaceItemIdentifier("object-subresource-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
        {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let value: String
        var toolTip: String?
        var textColor = NSColor.labelColor
        var alignment = NSTextAlignment.left
        guard containers.indices.contains(row) else { return nil }
        switch tableColumn.identifier.rawValue {
            case "name": value = containers[row].name
            case "type": value = containerType(containers[row].kind)
            case "status":
                value = containers[row].status.isEmpty ? "Unknown" : containers[row].status
                toolTip = containers[row].statusTooltip.isEmpty
                    ? value : containers[row].statusTooltip
                textColor = statusTextColor(for: containers[row].statusSeverity)
            case "ready":
                value = containers[row].ready ? "Yes" : "No"
                textColor = containers[row].ready ? .labelColor : .systemOrange
                alignment = .center
            case "restarts":
                value = String(containers[row].restartCount)
                alignment = .right
            case "ports":
                value = containers[row].ports.isEmpty
                    ? "—" : containers[row].ports.joined(separator: ", ")
                toolTip = containers[row].ports.isEmpty
                    ? "No declared container ports" : containers[row].ports.joined(separator: "\n")
                if containers[row].ports.isEmpty { textColor = .secondaryLabelColor }
            default: value = ""
        }
        cell.textField?.stringValue = value
        cell.textField?.toolTip = toolTip ?? value
        cell.textField?.textColor = textColor
        cell.textField?.alignment = alignment
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionControls()
        onContextualShortcutsChanged?()
    }

    func setNetworkActionsEnabled(_ enabled: Bool) {
        networkActionsEnabled = enabled
        updateSelectionControls()
        onContextualShortcutsChanged?()
    }

    private func configureTable() {
        let columns: [(String, String, CGFloat)] = [
            ("name", "Container", 240),
            ("type", "Type", 100),
            ("status", "Status", 190),
            ("ready", "Ready", 70),
            ("restarts", "Restarts", 80),
            ("cpu", "CPU", 210),
            ("memory", "Memory", 230),
            ("ports", "Ports", 220),
        ]
        tableView.setAccessibilityLabel("Pod containers")
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = 70
            if identifier == "cpu" || identifier == "memory" {
                column.headerToolTip = "Actual usage / request / limit"
            }
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 26
        tableView.onPrimaryAction = { [weak self] in self?.performPrimaryAction() }
        tableView.onNetworkAction = { [weak self] action in
            _ = self?.perform(action)
        }
        tableView.onBack = { [weak self] in self?.onBack?() }
    }

    private var shortcutHint: String {
        "L/Return: logs · \u{21E7}L: previous logs · S: terminal · \u{21E7}S: configure · P: port-forward · Escape: back"
    }

    private func containerType(_ kind: ExecContainerKind) -> String {
        switch kind {
        case .regular: "Regular"
        case .ephemeral: "Ephemeral"
        case .initContainer: "Init"
        }
    }

    private func resourceUsageCell(
        in tableView: NSTableView,
        columnID: String,
        container: PodContainerDetail
    ) -> NSView {
        let resourceName = columnID
        let unit = resourceName == "cpu" ? "cores" : "bytes"
        let value = container.metric(named: resourceName) ?? ResourceUsageValue(
            unit: unit,
            resourceName: resourceName,
            measurementScope: "container \(container.name)"
        )
        let displayText = [value.usage, value.request, value.limit]
            .map { quantity in
                quantity.map {
                    KubernetesResourceQuantityFormatter.compact($0, unit: value.unit)
                } ?? "—"
            }
            .joined(separator: " / ")
        let severity: CellSeverity = value.usage == nil ? .muted : .normal
        let cellValue = Cell(
            columnID: columnID,
            displayText: displayText,
            typedValue: .usage(value),
            tooltip: resourceUsageTooltip(value),
            severity: severity
        )
        let presentation = ResourceUsageCellPresentation(cell: cellValue)!
        let identifier = NSUserInterfaceItemIdentifier("container-usage-cell.\(columnID)")
        let cell = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ResourceUsageTableCellView ?? ResourceUsageTableCellView()
        cell.identifier = identifier
        cell.configure(
            presentation: presentation,
            toolTip: cellValue.tooltip,
            alignment: .right,
            textColor: severity == .muted ? .secondaryLabelColor : .labelColor
        )
        return cell
    }

    private func resourceUsageTooltip(_ value: ResourceUsageValue) -> String {
        let title = value.resourceName == "cpu" ? "CPU" : "Memory"
        let formatted: (Double?) -> String = { quantity in
            quantity.map {
                KubernetesResourceQuantityFormatter.compact($0, unit: value.unit)
            } ?? "unavailable"
        }
        var lines = [
            "Resource: \(title)",
            "Actual usage: \(formatted(value.usage))",
            "Request: \(formatted(value.request))",
            "Limit: \(formatted(value.limit))",
        ]
        if !value.provider.isEmpty { lines.append("Provider: \(value.provider)") }
        if !value.measurementScope.isEmpty {
            lines.append("Scope: \(value.measurementScope)")
        }
        return lines.joined(separator: "\n")
    }

    private func statusTextColor(for severity: CellSeverity) -> NSColor {
        switch severity {
        case .warning: .systemOrange
        case .critical: .systemRed
        case .muted: .secondaryLabelColor
        default: .labelColor
        }
    }

    @objc private func performPrimaryAction() {
        guard actionButton.isEnabled else { return }
        guard containers.indices.contains(tableView.selectedRow) else { return }
        onOpenLogs?(.namedContainer(containers[tableView.selectedRow].name, in: pod))
    }

    func canPerform(_ action: PodContainerNetworkAction) -> Bool {
        guard networkActionsEnabled else { return false }
        if action == .startPortForward { return true }
        return selectedContainerTarget() != nil
    }

    @discardableResult
    func perform(_ action: PodContainerNetworkAction) -> Bool {
        guard canPerform(action) else { return false }
        switch action {
        case .openLogs, .openPreviousLogs:
            guard let target = selectedContainerTarget(),
                let container = target.preferredContainer
            else { return false }
            onOpenLogs?(.namedContainer(
                container,
                in: pod,
                previous: action == .openPreviousLogs
            ))
        case .openAutomaticExec:
            guard let target = selectedContainerTarget() else { return false }
            onOpenExec?(target)
        case .configureExec:
            guard let target = selectedContainerTarget() else { return false }
            onConfigureExec?(target)
        case .startPortForward:
            onStartPortForward?(pod)
        }
        return true
    }

    private func selectedContainerTarget() -> PodExecTarget? {
        guard containers.indices.contains(tableView.selectedRow) else { return nil }
        return PodExecTarget(
            pod: pod,
            preferredContainer: containers[tableView.selectedRow].name
        )
    }

    @objc private func back() { onBack?() }

    private func updateSelectionControls() {
        actionButton.isEnabled = networkActionsEnabled && tableView.selectedRow >= 0
        publishContainerStatus()
    }

    private func publishContainerStatus() {
        let count = Self.countText(containers.count)
        let selection = containers.indices.contains(tableView.selectedRow)
            ? " · \(containers[tableView.selectedRow].name) selected" : ""
        let unavailable = networkActionsEnabled ? "" : " · network actions unavailable"
        workspaceStatus = WorkspaceStatus(
            count + selection + unavailable,
            severity: networkActionsEnabled ? .informational : .warning
        )
        onWorkspaceStatusChanged?(workspaceStatus)
    }

    private static func countText(_ count: Int) -> String {
        count == 1 ? "1 container" : "\(count.formatted()) containers"
    }
}

@MainActor
private final class PodContainerTableView: NSTableView {
    var onPrimaryAction: (() -> Void)?
    var onNetworkAction: ((PodContainerNetworkAction) -> Void)?
    var onBack: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ])
        let hasUnsupportedModifier = !modifiers.intersection([
            .command, .control, .option,
        ]).isEmpty
        let shifted = modifiers.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased(), event.keyCode) {
        case ("l", _) where !hasUnsupportedModifier && !shifted,
            (_, 36) where modifiers.isEmpty:
            onPrimaryAction?()
        case ("l", _) where !hasUnsupportedModifier && shifted:
            onNetworkAction?(.openPreviousLogs)
        case ("s", _) where !hasUnsupportedModifier:
            onNetworkAction?(shifted ? .configureExec : .openAutomaticExec)
        case ("p", _) where !hasUnsupportedModifier && !shifted:
            onNetworkAction?(.startPortForward)
        case (_, 53) where modifiers.isEmpty:
            onBack?()
        default: super.keyDown(with: event)
        }
    }
}
