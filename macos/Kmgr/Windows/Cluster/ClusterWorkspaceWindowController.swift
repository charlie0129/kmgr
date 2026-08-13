import AppKit
import KmgrCore
import OSLog

struct ResourceColumnsRequest {
    var resourceTitle: String
    var match: ColumnResourceMatch
    var defaultColumns: [ColumnDefinition]
    var apply: @MainActor ([ColumnDefinition]) -> Void
}

@MainActor
final class ClusterWorkspaceWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation
{
    let session: OpenedClusterSession
    var onClose: (() -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogWindow: ((LogWindowController) -> Void)?
    var onOpenTerminalWindow: ((TerminalWindowController) -> Void)?
    var onRestorationCheckpoint: ((ClusterWindowRestorationRecord) -> Void)?

    private let provider: any WorkspaceResourceProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let logProvider: any LogStreamProviding
    private let execProvider: any ExecSessionProviding
    private let portForwards: PortForwardCoordinator
    private let columnsConfigurationPath: String
    private let logDisplayConfiguration: LogDisplayConfiguration
    private let workspaceController: ClusterWorkspaceViewController
    private var restoration: ClusterWindowRestorationRecord
    private var portForwardConfigurationController: PortForwardConfigurationWindowController?
    private var logConfigurationController: LogConfigurationWindowController?
    private var execConfigurationController: ExecConfigurationWindowController?
    private var deleteResourcesController: DeleteResourcesWindowController?
    private var resourceMutationController: ResourceMutationWindowController?

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        objectSearchProvider: any ObjectSearchProviding,
        objectDetailProvider: any ObjectDetailProviding,
        operationProvider: any ResourceOperationProviding,
        logProvider: any LogStreamProviding,
        execProvider: any ExecSessionProviding,
        portForwards: PortForwardCoordinator,
        columnsConfigurationPath: String,
        logDisplayConfiguration: LogDisplayConfiguration,
        restoration: ClusterWindowRestorationRecord,
        onShowPortForwards: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.provider = provider
        self.objectDetailProvider = objectDetailProvider
        self.operationProvider = operationProvider
        self.logProvider = logProvider
        self.execProvider = execProvider
        self.restoration = restoration
        self.portForwards = portForwards
        self.columnsConfigurationPath = columnsConfigurationPath
        self.logDisplayConfiguration = logDisplayConfiguration

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(session.contextName) — \(Product.applicationName)"
        window.subtitle = session.serverHostname
        window.minSize = NSSize(width: 820, height: 520)
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName(restoration.frameAutosaveName)

        workspaceController = ClusterWorkspaceViewController(
            session: session,
            provider: provider,
            objectSearchProvider: objectSearchProvider,
            objectDetailProvider: objectDetailProvider,
            portForwards: portForwards,
            columnsConfigurationPath: columnsConfigurationPath,
            onShowPortForwards: onShowPortForwards
        )
        super.init(window: window)
        workspaceController.onStartPortForward = { [weak self] identity in
            self?.onStartPortForward?(identity)
        }
        workspaceController.onShowColumns = { [weak self] request in
            self?.onShowColumns?(request)
        }
        workspaceController.onOpenLogs = { [weak self] identities in
            self?.showLogConfiguration(identities)
        }
        workspaceController.onOpenExec = { [weak self] identity in
            self?.showExecConfiguration(identity)
        }
        workspaceController.onDelete = { [weak self] targets in
            self?.showDeleteResources(targets)
        }
        workspaceController.onMutate = { [weak self] identity, mutation in
            self?.showResourceMutation(identity, mutation: mutation)
        }
        workspaceController.onRestorationChanged = { [weak self] state in
            guard let self else { return }
            self.restoration.state = state
            self.onRestorationCheckpoint?(self.restoration)
        }
        window.delegate = self
        window.contentViewController = workspaceController
        window.toolbar = workspaceController.makeToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterWorkspaceWindowController is programmatic")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        workspaceController.start(restoring: restoration.state)
    }

    func windowWillClose(_ notification: Notification) {
        workspaceController.stop()
        restoration.state = workspaceController.restorationState()
        onRestorationCheckpoint?(restoration)
        Task { [provider, session] in
            await provider.closeSession(sessionID: session.sessionID)
        }
        onClose?()
    }

    func showPortForwardConfiguration(_ identity: ResourceIdentity) {
        guard let window else { return }
        if let current = portForwardConfigurationController {
            current.window?.makeKeyAndOrderFront(nil)
            NSSound.beep()
            return
        }
        let controller = PortForwardConfigurationWindowController(
            session: session,
            targetIdentity: identity,
            objectDetailProvider: objectDetailProvider,
            coordinator: portForwards
        )
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.portForwardConfigurationController === controller else { return }
            self?.portForwardConfigurationController = nil
        }
        portForwardConfigurationController = controller
        controller.beginSheet(for: window)
    }

    private func showLogConfiguration(_ identities: [ResourceIdentity]) {
        guard let window, logConfigurationController == nil else { NSSound.beep(); return }
        let controller = LogConfigurationWindowController(
            session: session,
            pods: identities,
            detailProvider: objectDetailProvider,
            logProvider: logProvider,
            displayConfiguration: logDisplayConfiguration
        )
        controller.onOpenWindow = { [weak self] in self?.onOpenLogWindow?($0) }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.logConfigurationController === controller else { return }
            self?.logConfigurationController = nil
        }
        logConfigurationController = controller
        controller.beginSheet(for: window)
    }

    private func showExecConfiguration(_ identity: ResourceIdentity) {
        guard let window, execConfigurationController == nil else { NSSound.beep(); return }
        let controller = ExecConfigurationWindowController(
            session: session,
            podIdentity: identity,
            objectDetailProvider: objectDetailProvider,
            execProvider: execProvider
        )
        controller.onOpenWindow = { [weak self] in self?.onOpenTerminalWindow?($0) }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.execConfigurationController === controller else { return }
            self?.execConfigurationController = nil
        }
        execConfigurationController = controller
        controller.beginSheet(for: window)
    }

    private func showDeleteResources(_ targets: [ResourceDeleteTarget]) {
        guard let window, deleteResourcesController == nil else { NSSound.beep(); return }
        let controller = DeleteResourcesWindowController(
            session: session,
            targets: targets,
            provider: operationProvider
        )
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.deleteResourcesController === controller else { return }
            self?.deleteResourcesController = nil
        }
        deleteResourcesController = controller
        controller.beginSheet(for: window)
    }

    private func showResourceMutation(
        _ identity: ResourceIdentity,
        mutation: ResourceMutationWindowController.Mutation
    ) {
        guard let window, resourceMutationController == nil else { NSSound.beep(); return }
        let controller = ResourceMutationWindowController(
            session: session,
            identity: identity,
            mutation: mutation,
            detailProvider: objectDetailProvider,
            operationProvider: operationProvider
        )
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.resourceMutationController === controller else { return }
            self?.resourceMutationController = nil
        }
        resourceMutationController = controller
        controller.beginSheet(for: window)
    }

    @objc func showCommandPalette(_ sender: Any?) {
        workspaceController.presentCommandPalette()
    }

    @objc func openResourceDetails(_ sender: Any?) { workspaceController.openResourceDetails(sender) }
    @objc func openResourceYAML(_ sender: Any?) { workspaceController.openResourceYAML(sender) }
    @objc func openResourceEvents(_ sender: Any?) { workspaceController.openResourceEvents(sender) }
    @objc func openResourceLogs(_ sender: Any?) { workspaceController.openResourceLogs(sender) }
    @objc func openResourceExec(_ sender: Any?) { workspaceController.openResourceExec(sender) }
    @objc func startResourcePortForward(_ sender: Any?) { workspaceController.startResourcePortForward(sender) }
    @objc func deleteResourceSelection(_ sender: Any?) { workspaceController.deleteResourceSelection(sender) }
    @objc func scaleResourceSelection(_ sender: Any?) { workspaceController.scaleResourceSelection(sender) }
    @objc func restartResourceSelection(_ sender: Any?) { workspaceController.restartResourceSelection(sender) }
    @objc func editResourceMetadata(_ sender: Any?) { workspaceController.editResourceMetadata(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let command: ResourceTableCommand?
        switch menuItem.action {
        case #selector(openResourceDetails(_:)): command = .open
        case #selector(openResourceYAML(_:)): command = .openYAML
        case #selector(openResourceEvents(_:)): command = .openEvents
        case #selector(openResourceLogs(_:)): command = .openLogs
        case #selector(openResourceExec(_:)): command = .openExec
        case #selector(startResourcePortForward(_:)): command = .startPortForward
        case #selector(deleteResourceSelection(_:)): command = .delete
        case #selector(scaleResourceSelection(_:)): command = .scale
        case #selector(restartResourceSelection(_:)): command = .restart
        case #selector(editResourceMetadata(_:)): command = .editMetadata
        default: command = nil
        }
        return command.map(workspaceController.canPerformCommand) ?? true
    }
}

@MainActor
private final class ClusterWorkspaceViewController: NSSplitViewController,
    NSToolbarDelegate, NSSearchFieldDelegate
{
    private let session: OpenedClusterSession
    private let provider: any WorkspaceResourceProviding
    private let objectSearchProvider: any ObjectSearchProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let portForwards: PortForwardCoordinator
    private let columnsConfigurationPath: String
    private let onShowPortForwards: @MainActor () -> Void
    private let sidebarController: ResourceSidebarViewController
    private let contentController: ResourceListViewController
    private let namespaceControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectionLabel = NSTextField(labelWithString: "Connected")
    private let forwardsButton = NSButton(title: "Forwards 0", target: nil, action: nil)
    private var namespaceTask: Task<Void, Never>?
    private var portForwardObserver: UUID?
    private var resources: [DiscoveredResource] = []
    private var namespaces: [String] = []
    private var paletteController: CommandPaletteWindowController?
    private var objectOpenTask: Task<Void, Never>?
    private var detailController: ObjectDetailViewController?
    private var pendingRestorationState: ClusterWindowRestorationState?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogs: (([ResourceIdentity]) -> Void)?
    var onOpenExec: ((ResourceIdentity) -> Void)?
    var onDelete: (([ResourceDeleteTarget]) -> Void)?
    var onMutate: ((ResourceIdentity, ResourceMutationWindowController.Mutation) -> Void)?
    var onRestorationChanged: ((ClusterWindowRestorationState) -> Void)?

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        objectSearchProvider: any ObjectSearchProviding,
        objectDetailProvider: any ObjectDetailProviding,
        portForwards: PortForwardCoordinator,
        columnsConfigurationPath: String,
        onShowPortForwards: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.provider = provider
        self.objectSearchProvider = objectSearchProvider
        self.objectDetailProvider = objectDetailProvider
        self.portForwards = portForwards
        self.columnsConfigurationPath = columnsConfigurationPath
        self.onShowPortForwards = onShowPortForwards
        sidebarController = ResourceSidebarViewController(session: session, provider: provider)
        contentController = ResourceListViewController(
            session: session,
            provider: provider,
            columnsConfigurationPath: columnsConfigurationPath
        )
        super.init(nibName: nil, bundle: nil)

        sidebarController.onSelectResource = { [weak self] resource in
            guard let self else { return }
            guard pendingRestorationState == nil else { return }
            let wasShowingDetail = detailController != nil
            showResourceList(resume: false)
            contentController.open(resource: resource, scope: selectedNamespaceScope())
            checkpointRestoration()
            if wasShowingDetail {
                view.window?.makeFirstResponder(contentController.tableResponder)
            }
        }
        sidebarController.onResourcesChanged = { [weak self] resources in
            self?.resources = resources
        }
        contentController.onShowCommandPalette = { [weak self] in
            self?.showCommandPalette()
        }
        contentController.onOpenObject = { [weak self] identity, tab in
            self?.showObject(identity, initialTab: tab)
        }
        contentController.onStartPortForward = { [weak self] identity in
            self?.onStartPortForward?(identity)
        }
        contentController.onShowColumns = { [weak self] request in
            self?.onShowColumns?(request)
        }
        contentController.onOpenLogs = { [weak self] identities in
            self?.onOpenLogs?(identities)
        }
        contentController.onOpenExec = { [weak self] identity in
            self?.onOpenExec?(identity)
        }
        contentController.onDelete = { [weak self] targets in
            self?.onDelete?(targets)
        }
        contentController.onMutate = { [weak self] identity, mutation in
            self?.onMutate?(identity, mutation)
        }
        contentController.onRestorationChanged = { [weak self] in
            self?.checkpointRestoration()
        }
        addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebarController))
        addSplitViewItem(NSSplitViewItem(viewController: contentController))
        splitViewItems[0].minimumThickness = 180
        splitViewItems[0].maximumThickness = 340
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterWorkspaceViewController is programmatic")
    }

    func start(restoring state: ClusterWindowRestorationState? = nil) {
        pendingRestorationState = state
        sidebarController.start { [weak self] resources in
            guard let self else { return }
            let restored = pendingRestorationState.flatMap {
                contentController.applyRestoration($0, discoveredResources: resources)
            } ?? false
            if let state = pendingRestorationState {
                applyNamespaceScopeSelection(state.namespaceScope.namespaceSelection)
                splitViewItems[0].isCollapsed = !state.isSidebarVisible
            }
            pendingRestorationState = nil
            if restored {
                sidebarController.selectResource(matching: contentController.currentResourceID)
            } else {
                sidebarController.selectDefaultResource()
            }
        }
        loadNamespaces()
        portForwards.register(sessionID: session.sessionID)
        if portForwardObserver == nil {
            portForwardObserver = portForwards.observe { [weak self] snapshot in
                self?.updatePortForwardButton(snapshot)
            }
        }
    }

    func restorationState() -> ClusterWindowRestorationState {
        contentController.restorationState(
            contextName: session.contextName,
            isSidebarVisible: !splitViewItems[0].isCollapsed
        )
    }

    private func checkpointRestoration() {
        onRestorationChanged?(restorationState())
    }

    func stop() {
        namespaceTask?.cancel()
        paletteController?.close()
        paletteController = nil
        objectOpenTask?.cancel()
        detailController?.stop()
        detailController = nil
        if let portForwardObserver {
            portForwards.removeObserver(portForwardObserver)
            self.portForwardObserver = nil
        }
        sidebarController.stop()
        contentController.stop()
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "cluster-workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .back, .forward, .cluster, .namespace, .flexibleSpace, .palette, .connection, .forwards]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .back, .forward, .cluster, .namespace, .flexibleSpace, .palette, .connection, .forwards]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.target = self
            item.action = #selector(toggleWorkspaceSidebar)
            return item
        case .back, .forward:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = itemIdentifier == .back ? "Back" : "Forward"
            item.image = NSImage(
                systemSymbolName: itemIdentifier == .back ? "chevron.left" : "chevron.right",
                accessibilityDescription: item.label
            )
            item.target = self
            item.action = itemIdentifier == .back ? #selector(goBack) : #selector(goForward)
            return item
        case .cluster:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = session.contextName
            let button = NSButton(title: session.contextName, target: nil, action: nil)
            button.bezelStyle = .texturedRounded
            button.toolTip = "\(session.clusterName) · \(session.serverHostname)"
            item.view = button
            return item
        case .namespace:
            namespaceControl.addItem(withTitle: "All namespaces")
            namespaceControl.target = self
            namespaceControl.action = #selector(namespaceChanged)
            namespaceControl.toolTip = "Namespace scope"
            namespaceControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Namespace"
            item.view = namespaceControl
            return item
        case .palette:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Commands"
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")
            item.target = self
            item.action = #selector(showCommandPalette)
            return item
        case .connection:
            connectionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            connectionLabel.textColor = .secondaryLabelColor
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Connection"
            item.view = connectionLabel
            return item
        case .forwards:
            forwardsButton.bezelStyle = .texturedRounded
            forwardsButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
            forwardsButton.target = self
            forwardsButton.action = #selector(showPortForwards)
            forwardsButton.setAccessibilityLabel("Open app-wide Port Forwards")
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Port Forwards"
            item.view = forwardsButton
            return item
        default:
            return nil
        }
    }

    @objc private func toggleWorkspaceSidebar() {
        splitViewItems[0].animator().isCollapsed.toggle()
        checkpointRestoration()
    }

    @objc private func namespaceChanged() {
        let wasShowingDetail = detailController != nil
        showResourceList(resume: false)
        contentController.changeNamespaceScope(selectedNamespaceScope())
        if wasShowingDetail {
            view.window?.makeFirstResponder(contentController.tableResponder)
        }
        checkpointRestoration()
    }

    @objc private func showPortForwards() {
        onShowPortForwards()
    }

    @objc private func showCommandPalette() {
        presentCommandPalette()
    }

    @objc func openResourceDetails(_ sender: Any?) { contentController.performCommand(.open) }
    @objc func openResourceYAML(_ sender: Any?) { contentController.performCommand(.openYAML) }
    @objc func openResourceEvents(_ sender: Any?) { contentController.performCommand(.openEvents) }
    @objc func openResourceLogs(_ sender: Any?) { contentController.performCommand(.openLogs) }
    @objc func openResourceExec(_ sender: Any?) { contentController.performCommand(.openExec) }
    @objc func startResourcePortForward(_ sender: Any?) { contentController.performCommand(.startPortForward) }
    @objc func deleteResourceSelection(_ sender: Any?) { contentController.performCommand(.delete) }
    @objc func scaleResourceSelection(_ sender: Any?) { contentController.performCommand(.scale) }
    @objc func restartResourceSelection(_ sender: Any?) { contentController.performCommand(.restart) }
    @objc func editResourceMetadata(_ sender: Any?) { contentController.performCommand(.editMetadata) }

    func canPerformCommand(_ command: ResourceTableCommand) -> Bool {
        contentController.canPerformCommand(command)
    }

    func presentCommandPalette() {
        if let paletteController {
            paletteController.showWindow(nil)
            return
        }
        let controller = CommandPaletteWindowController(
            context: .init(
                session: session,
                resources: resources,
                namespaces: namespaces,
                namespaceScope: selectedNamespaceScope(),
                selectedIdentities: contentController.selectedIdentities
            ),
            objectSearchProvider: objectSearchProvider
        )
        controller.onOpenResource = { [weak self] resource in
            guard let self else { return }
            let wasShowingDetail = detailController != nil
            showResourceList(resume: false)
            contentController.open(resource: resource, scope: selectedNamespaceScope())
            checkpointRestoration()
            if wasShowingDetail {
                view.window?.makeFirstResponder(contentController.tableResponder)
            }
        }
        controller.onChangeNamespace = { [weak self] namespace in
            self?.selectNamespace(namespace)
        }
        controller.onOpenObject = { [weak self] identity in
            self?.freshOpen(identity)
        }
        controller.onOperation = { [weak self] operation in
            guard case .startPortForward(let identity) = operation else { return }
            self?.onStartPortForward?(identity)
        }
        controller.onClose = { [weak self, weak controller] in
            guard self?.paletteController === controller else { return }
            self?.paletteController = nil
        }
        paletteController = controller
        view.window?.addChildWindow(controller.window!, ordered: .above)
        controller.showWindow(nil)
    }

    private func freshOpen(_ identity: ResourceIdentity) {
        objectOpenTask?.cancel()
        connectionLabel.stringValue = "Refreshing \(identity.name)…"
        connectionLabel.textColor = .secondaryLabelColor
        objectOpenTask = Task { [weak self, objectDetailProvider] in
            guard let self else { return }
            do {
                let detail = try await objectDetailProvider.getObject(identity: identity)
                guard !Task.isCancelled else { return }
                connectionLabel.stringValue = "Connected"
                connectionLabel.textColor = .secondaryLabelColor
                showObject(detail.identity, initialTab: .automatic)
            } catch {
                guard !Task.isCancelled else { return }
                connectionLabel.stringValue = error.localizedDescription
                connectionLabel.textColor = .systemRed
            }
        }
    }

    private func showObject(
        _ identity: ResourceIdentity,
        initialTab: ObjectDetailInitialTab
    ) {
        detailController?.stop()
        contentController.suspend()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: objectDetailProvider,
            initialTab: initialTab
        )
        controller.onBack = { [weak self] in self?.showResourceList() }
        detailController = controller
        replaceMainContent(with: controller)
        view.window?.makeFirstResponder(controller.view)
    }

    private func showResourceList(resume: Bool = true) {
        guard detailController != nil else { return }
        detailController?.stop()
        replaceMainContent(with: contentController)
        detailController = nil
        if resume { contentController.resume() }
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    private func replaceMainContent(with controller: NSViewController) {
        if splitViewItems.count > 1 {
            removeSplitViewItem(splitViewItems[1])
        }
        insertSplitViewItem(NSSplitViewItem(viewController: controller), at: 1)
    }

    @objc private func goBack() {
        if detailController != nil {
            showResourceList()
        } else {
            contentController.goBack()
        }
        checkpointRestoration()
    }

    @objc private func goForward() {
        guard detailController == nil else { return }
        contentController.goForward()
        checkpointRestoration()
    }

    private func selectNamespace(_ namespace: String) {
        if let index = namespaceControl.itemTitles.firstIndex(of: namespace) {
            namespaceControl.selectItem(at: index)
        } else {
            namespaceControl.addItem(withTitle: namespace)
            namespaceControl.selectItem(withTitle: namespace)
        }
        namespaceChanged()
    }

    private func applyNamespaceScopeSelection(_ scope: NamespaceSelection) {
        guard !scope.allNamespaces, let namespace = scope.namespaces.first else {
            namespaceControl.selectItem(at: 0)
            return
        }
        if let index = namespaceControl.itemTitles.firstIndex(of: namespace) {
            namespaceControl.selectItem(at: index)
        } else {
            namespaceControl.addItem(withTitle: namespace)
            namespaceControl.selectItem(withTitle: namespace)
        }
    }

    private func selectedNamespaceScope() -> NamespaceSelection {
        if namespaceControl.indexOfSelectedItem <= 0 { return NamespaceSelection() }
        return .namespace(namespaceControl.titleOfSelectedItem ?? session.defaultNamespace)
    }

    private func loadNamespaces() {
        namespaceTask?.cancel()
        namespaceTask = Task { [weak self, provider, session] in
            guard let self else { return }
            do {
                let namespaces = try await provider.listNamespaces(sessionID: session.sessionID)
                guard !Task.isCancelled else { return }
                let previous = namespaceControl.titleOfSelectedItem
                self.namespaces = namespaces
                namespaceControl.removeAllItems()
                namespaceControl.addItem(withTitle: "All namespaces")
                namespaceControl.addItems(withTitles: namespaces)
                if let previous,
                    let index = namespaceControl.itemTitles.firstIndex(of: previous)
                {
                    namespaceControl.selectItem(at: index)
                } else if !session.defaultNamespace.isEmpty,
                    let index = namespaceControl.itemTitles.firstIndex(of: session.defaultNamespace)
                {
                    namespaceControl.selectItem(at: index)
                }
            } catch {
                connectionLabel.stringValue = "Namespace list unavailable"
                connectionLabel.textColor = .systemOrange
            }
        }
    }

    private func updatePortForwardButton(_ snapshot: PortForwardCoordinator.Snapshot) {
        forwardsButton.title = "Forwards \(snapshot.activeCount.formatted())"
        if snapshot.hasFailure {
            forwardsButton.contentTintColor = .systemRed
            forwardsButton.toolTip = "One or more port-forwards failed. Open Port Forwards."
            forwardsButton.setAccessibilityValue("\(snapshot.activeCount) active, failures present")
        } else if snapshot.connectionIssue != nil {
            forwardsButton.contentTintColor = .systemOrange
            forwardsButton.toolTip = "Port-forward status is reconnecting."
            forwardsButton.setAccessibilityValue("\(snapshot.activeCount) active, status unavailable")
        } else {
            forwardsButton.contentTintColor = nil
            forwardsButton.toolTip = "\(snapshot.activeCount.formatted()) app-wide active port-forward(s)"
            forwardsButton.setAccessibilityValue("\(snapshot.activeCount) active")
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let back = Self("workspace.back")
    static let forward = Self("workspace.forward")
    static let cluster = Self("workspace.cluster")
    static let namespace = Self("workspace.namespace")
    static let palette = Self("workspace.palette")
    static let connection = Self("workspace.connection")
    static let forwards = Self("workspace.forwards")
}

@MainActor
private final class ResourceSidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate
{
    private static let pinnedSectionTitle = "Pinned"
    private static let pinPasteboardType = NSPasteboard.PasteboardType("com.kmgr.sidebar-pin-gvr")

    private struct Section: Hashable {
        var title: String
        var resources: [DiscoveredResource]
    }

    private let session: OpenedClusterSession
    private let provider: any WorkspaceResourceProviding
    private let pinStore: SidebarPinStore
    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "Loading discovery…")
    private var sections: [Section] = []
    private var allResources: [DiscoveredResource] = []
    private var task: Task<Void, Never>?
    private var pinObserver: UUID?
    private var didChooseInitialResource = false
    private var suppressSelectionCallbacks = false
    var onSelectResource: ((DiscoveredResource) -> Void)?
    var onResourcesChanged: (([DiscoveredResource]) -> Void)?

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        pinStore: SidebarPinStore = .shared
    ) {
        self.session = session
        self.provider = provider
        self.pinStore = pinStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func loadView() {
        let root = NSView()
        searchField.placeholderString = "Filter resources"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("resource"))
        column.title = "Resources"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .small
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.autoresizesOutlineColumn = true
        outlineView.setAccessibilityLabel("Kubernetes resource kinds")
        outlineView.registerForDraggedTypes([Self.pinPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask([], forLocal: false)
        let resourceMenu = NSMenu(title: "Resource Kind")
        resourceMenu.delegate = self
        outlineView.menu = resourceMenu

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
    }

    func start(onLoaded: (([DiscoveredResource]) -> Void)? = nil) {
        if pinObserver == nil {
            pinObserver = pinStore.observe { [weak self] _ in
                self?.rebuildSections()
            }
        }
        guard task == nil else { return }
        task = Task { [weak self, provider, session] in
            guard let self else { return }
            do {
                let resources = try await provider.discoverResources(sessionID: session.sessionID, refresh: false)
                guard !Task.isCancelled else { return }
                allResources = resources.filter { $0.verbs.contains("list") }
                onResourcesChanged?(allResources)
                rebuildSections()
                if let issue = pinStore.loadIssue {
                    statusLabel.stringValue = "\(allResources.count.formatted()) kinds • built-in pins in use"
                    statusLabel.toolTip = issue.localizedDescription
                    statusLabel.textColor = .systemOrange
                } else {
                    statusLabel.stringValue = "\(allResources.count.formatted()) resource kinds"
                    statusLabel.toolTip = nil
                    statusLabel.textColor = .secondaryLabelColor
                }
                onLoaded?(allResources)
            } catch {
                statusLabel.stringValue = error.localizedDescription
                statusLabel.textColor = .systemRed
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let pinObserver {
            pinStore.removeObserver(pinObserver)
            self.pinObserver = nil
        }
    }

    @objc private func searchChanged() { rebuildSections() }

    private func rebuildSections() {
        let selectedID = selectedResource()?.id
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = query.isEmpty ? allResources : allResources.filter {
            ([$0.kind, $0.resource] + $0.shortNames)
                .contains { $0.lowercased().contains(query) }
        }
        let pinIndexes = Dictionary(uniqueKeysWithValues: pinStore.pins.enumerated().map { ($1.id, $0) })
        let pinnedIDs = Set(pinIndexes.keys)
        let pinned = visible.filter { pinnedIDs.contains($0.id) }.sorted {
            pinIndexes[$0.id, default: .max] < pinIndexes[$1.id, default: .max]
        }
        var grouped: [String: [DiscoveredResource]] = [:]
        for resource in visible where !pinnedIDs.contains(resource.id) {
            grouped[sectionName(for: resource), default: []].append(resource)
        }
        sections = []
        if !pinned.isEmpty { sections.append(Section(title: Self.pinnedSectionTitle, resources: pinned)) }
        for title in ["Workloads", "Network", "Config", "Storage", "RBAC", "Cluster", "Custom Resources"] {
            if let resources = grouped[title], !resources.isEmpty {
                sections.append(Section(title: title, resources: resources.sorted { $0.kind < $1.kind }))
            }
        }
        outlineView.reloadData()
        for index in sections.indices { outlineView.expandItem(sections[index]) }
        if let selectedID, let resource = allResources.first(where: { $0.id == selectedID }) {
            select(resource: resource, notify: false)
        }
    }

    private func sectionName(for resource: DiscoveredResource) -> String {
        if !resource.group.isEmpty && !["apps", "batch", "networking.k8s.io", "storage.k8s.io", "rbac.authorization.k8s.io", "policy"].contains(resource.group) {
            return "Custom Resources"
        }
        if ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"].contains(resource.kind) { return "Workloads" }
        if ["Service", "Ingress", "Endpoint", "EndpointSlice", "NetworkPolicy"].contains(resource.kind) { return "Network" }
        if ["ConfigMap", "Secret", "ResourceQuota", "LimitRange"].contains(resource.kind) { return "Config" }
        if resource.group == "storage.k8s.io" || resource.kind.contains("Volume") || resource.kind == "StorageClass" { return "Storage" }
        if resource.group == "rbac.authorization.k8s.io" || resource.kind.contains("Role") || resource.kind.contains("Binding") { return "RBAC" }
        return "Cluster"
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return sections.count }
        return (item as? Section)?.resources.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let section = item as? Section { return section.resources[index] }
        return sections[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let resource = item as? DiscoveredResource, pinStore.contains(id: resource.id) else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(resource.id, forType: Self.pinPasteboardType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outlineView,
            let pinID = info.draggingPasteboard.string(forType: Self.pinPasteboardType),
            pinStore.contains(id: pinID),
            let section = item as? Section,
            section.title == Self.pinnedSectionTitle,
            index != NSOutlineViewDropOnItemIndex
        else { return [] }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let section = item as? Section,
            section.title == Self.pinnedSectionTitle,
            section.resources.indices.contains(index) || index == section.resources.endIndex,
            let pinID = info.draggingPasteboard.string(forType: Self.pinPasteboardType)
        else { return false }
        let targetID = index < section.resources.count ? section.resources[index].id : nil
        return pinStore.move(pinID: pinID, beforePinID: targetID)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        if let section = item as? Section {
            cell.textField?.stringValue = section.title
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        } else if let resource = item as? DiscoveredResource {
            cell.textField?.stringValue = resource.kind.isEmpty ? resource.resource : resource.kind
            cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallbacks else { return }
        guard outlineView.selectedRow >= 0,
            let resource = outlineView.item(atRow: outlineView.selectedRow) as? DiscoveredResource
        else { return }
        onSelectResource?(resource)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let resource = contextMenuResource() else { return }
        let isPinned = pinStore.contains(id: resource.id)
        let verb = isPinned ? "Unpin" : "Pin"
        let title = resource.kind.isEmpty ? resource.resource : resource.kind
        let item = NSMenuItem(
            title: "\(verb) \(title)",
            action: #selector(togglePin(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = resource.id
        menu.addItem(item)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let resourceID = sender.representedObject as? String,
            let resource = allResources.first(where: { $0.id == resourceID })
        else { return }
        let changed: Bool
        if pinStore.contains(id: resource.id) {
            changed = pinStore.unpin(id: resource.id)
        } else {
            changed = pinStore.pin(SidebarPin(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            ))
        }
        if !changed { NSSound.beep() }
    }

    private func contextMenuResource() -> DiscoveredResource? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? DiscoveredResource
    }

    private func selectedResource() -> DiscoveredResource? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.selectedRow) as? DiscoveredResource
    }

    func selectResource(matching resourceID: String?) {
        guard !didChooseInitialResource, let resourceID,
            let resource = allResources.first(where: { $0.id == resourceID })
        else { return }
        didChooseInitialResource = true
        select(resource: resource, notify: false)
    }

    func selectDefaultResource() {
        guard !didChooseInitialResource else { return }
        didChooseInitialResource = true
        if let pods = allResources.first(where: { $0.group.isEmpty && $0.resource == "pods" }) {
            select(resource: pods, notify: true)
        } else if let first = allResources.first {
            select(resource: first, notify: true)
        }
    }

    private func select(resource: DiscoveredResource, notify: Bool) {
        for row in 0..<outlineView.numberOfRows where (outlineView.item(atRow: row) as? DiscoveredResource)?.id == resource.id {
            suppressSelectionCallbacks = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelectionCallbacks = false
            if notify { onSelectResource?(resource) }
            break
        }
    }
}

@MainActor
private final class ResourceListViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    private let session: OpenedClusterSession
    private let provider: any WorkspaceResourceProviding
    private let columnsConfigurationPath: String
    private let titleLabel = NSTextField(labelWithString: "Resources")
    private let scopeLabel = NSTextField(labelWithString: "All namespaces")
    private let freshnessLabel = NSTextField(labelWithString: "Idle")
    private let countLabel = NSTextField(labelWithString: "0 objects")
    private let filterField = NSSearchField()
    private let tableView = ResourceTableView()
    private let scrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var model = ResourceTableModel()
    private var generationGate = GenerationSequenceGate()
    private var resource: DiscoveredResource?
    private var scope = NamespaceSelection()
    private var viewID = UUID().uuidString.lowercased()
    private var generation: UInt64 = 0
    private var filterRevision: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var suppressSelectionCallbacks = false
    private var history = WorkspaceNavigationHistory()
    private var columnIDs: [String] = []
    private var columnDefinitionsByID: [String: ColumnDefinition] = [:]
    private var columnDefinitionsByResourceID: [String: [ColumnDefinition]] = [:]
    private var suppressSortChanges = false
    private var snapshotUIDs: [ResourceUID] = []
    private var lastStreamResourceID: String?
    private var lastStreamScope: NamespaceSelection?
    private var pendingScrollAnchor: ScrollAnchor?
    private var restorationCheckpointTask: Task<Void, Never>?
    private var suppressPresentationCheckpoint = false
    private let logger = Logger(subsystem: Product.bundleIdentifier, category: "resource-table")
    var onShowCommandPalette: (() -> Void)?
    var onOpenObject: ((ResourceIdentity, ObjectDetailInitialTab) -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogs: (([ResourceIdentity]) -> Void)?
    var onOpenExec: ((ResourceIdentity) -> Void)?
    var onDelete: (([ResourceDeleteTarget]) -> Void)?
    var onMutate: ((ResourceIdentity, ResourceMutationWindowController.Mutation) -> Void)?
    var onRestorationChanged: (() -> Void)?

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        columnsConfigurationPath: String
    ) {
        self.session = session
        self.provider = provider
        self.columnsConfigurationPath = columnsConfigurationPath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        scopeLabel.textColor = .secondaryLabelColor
        freshnessLabel.textColor = .secondaryLabelColor
        countLabel.textColor = .secondaryLabelColor
        filterField.placeholderString = "Filter resources  /"
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true

        let columnsButton = NSButton(title: "Columns…", target: self, action: #selector(showColumns))
        columnsButton.bezelStyle = .texturedRounded
        let header = NSStackView(views: [titleLabel, countLabel, scopeLabel, freshnessLabel, NSView(), filterField, columnsButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        header.translatesAutoresizingMaskIntoConstraints = false
        filterField.widthAnchor.constraint(equalToConstant: 230).isActive = true

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.doubleAction = #selector(openSelectedObjectFromTable)
        tableView.target = self
        tableView.rowSizeStyle = .medium
        tableView.setAccessibilityLabel("Kubernetes resources")
        tableView.onCommand = { [weak self] command in self?.handle(command) }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        errorLabel.isHidden = true
        errorLabel.textColor = .systemRed
        errorLabel.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08)
        errorLabel.drawsBackground = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSTextField(labelWithString: "0 objects · 0 selected · Idle")
        statusLine.identifier = .init("resource-status-line")
        statusLine.textColor = .secondaryLabelColor
        statusLine.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLine.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(errorLabel)
        root.addSubview(scrollView)
        root.addSubview(statusLine)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            errorLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: statusLine.topAnchor, constant: -2),
            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusLine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
    }

    func open(resource: DiscoveredResource, scope: NamespaceSelection) {
        if let current = navigationState() { history.replaceCurrent(with: .resource(current)) }
        self.resource = resource
        self.scope = scope
        pendingScrollAnchor = nil
        let state = ResourceNavigationState(
            group: resource.group, version: resource.version, resource: resource.resource,
            kind: resource.kind, namespaced: resource.namespaced, namespaceSelection: scope
        )
        history.navigate(to: .resource(state))
        configureColumns(for: resource)
        openStream()
    }

    func changeNamespaceScope(_ scope: NamespaceSelection) {
        guard self.scope != scope else { return }
        if let current = navigationState() { history.replaceCurrent(with: .resource(current)) }
        self.scope = scope
        pendingScrollAnchor = nil
        if var state = navigationState() {
            state.namespaceSelection = scope
            history.navigate(to: .resource(state))
        }
        openStream()
    }

    func stop() {
        restorationCheckpointTask?.cancel()
        restorationCheckpointTask = nil
        suspend()
    }

    func suspend() {
        filterTask?.cancel()
        filterTask = nil
        streamTask?.cancel()
        streamTask = nil
        let generation = generation
        guard generation > 0 else { return }
        Task { [provider, session, viewID] in
            await provider.cancelView(sessionID: session.sessionID, viewID: viewID, generation: generation)
        }
    }

    func resume() {
        openStream()
    }

    var tableResponder: NSResponder { tableView }

    var currentResourceID: String? { resource?.id }

    var selectedIdentities: [ResourceIdentity] { model.selectedIdentities }

    func setFilter(_ value: String) {
        filterRevision &+= 1
        filterTask?.cancel()
        filterField.stringValue = value
        openStream()
        onRestorationChanged?()
        view.window?.makeFirstResponder(filterField)
    }

    @objc func goBack() {
        if let current = navigationState() { history.replaceCurrent(with: .resource(current)) }
        guard let destination = history.goBack() else { return }
        restore(destination)
    }

    @objc func goForward() {
        if let current = navigationState() { history.replaceCurrent(with: .resource(current)) }
        guard let destination = history.goForward() else { return }
        restore(destination)
    }

    @objc func showCommandPalette() {
        onShowCommandPalette?()
    }

    @objc private func showColumns() {
        guard let resource else { return }
        let resourceID = resource.id
        onShowColumns?(ResourceColumnsRequest(
            resourceTitle: resource.kind.isEmpty ? resource.resource : resource.kind,
            match: ColumnResourceMatch(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            ),
            defaultColumns: defaultColumnDefinitions(for: resource),
            apply: { [weak self] definitions in
                self?.applyColumns(definitions, forResourceID: resourceID)
            }
        ))
    }

    func controlTextDidChange(_ obj: Notification) {
        filterRevision &+= 1
        filterTask?.cancel()
        let revision = filterRevision
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, self?.filterRevision == revision else { return }
            self?.openStream()
            self?.onRestorationChanged?()
        }
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        scheduleRestorationCheckpoint()
    }

    private func scheduleRestorationCheckpoint() {
        guard !suppressPresentationCheckpoint else { return }
        restorationCheckpointTask?.cancel()
        restorationCheckpointTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.onRestorationChanged?()
        }
    }

    private func openStream() {
        guard let resource else { return }
        let previousGeneration = generation
        streamTask?.cancel()
        if previousGeneration > 0 {
            Task { [provider, session, viewID] in
                await provider.cancelView(sessionID: session.sessionID, viewID: viewID, generation: previousGeneration)
            }
        }
        generation &+= 1
        generationGate.reset()
        let canKeepWarmRows = lastStreamResourceID == resource.id
            && lastStreamScope == scope
            && !model.orderedVisibleUIDs.isEmpty
        if !canKeepWarmRows {
            model = ResourceTableModel()
            tableView.reloadData()
        }
        lastStreamResourceID = resource.id
        lastStreamScope = scope
        snapshotUIDs.removeAll(keepingCapacity: true)
        errorLabel.isHidden = true
        titleLabel.stringValue = resource.kind.isEmpty ? resource.resource : resource.kind
        scopeLabel.stringValue = scope.presentation
        freshnessLabel.stringValue = "Loading…"
        let request = ResourceViewRequest(
            sessionID: session.sessionID,
            viewID: viewID,
            generation: generation,
            resource: resource,
            allNamespaces: scope.allNamespaces,
            namespaces: scope.namespaces,
            filterExpression: filterField.stringValue,
            filterRevision: filterRevision,
            columnIDs: columnIDs,
            sort: tableView.sortDescriptors.compactMap { descriptor in
                guard let columnID = descriptor.key else { return nil }
                return ResourceSortDescriptor(
                    columnID: columnID,
                    direction: descriptor.ascending ? .ascending : .descending
                )
            }
        )
        streamTask = Task { [weak self, provider] in
            do {
                for try await message in provider.streamView(request: request) {
                    guard !Task.isCancelled else { return }
                    self?.receive(message)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error: error)
            }
        }
    }

    private func receive(_ message: ResourceViewMessage) {
        let cursor = message.cursor
        guard cursor.generation == generation else { return }
        let disposition = generationGate.accept(cursor)
        guard disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence else { return }

        switch message {
        case .status(_, let status):
            freshnessLabel.stringValue = status.presentation
            countLabel.stringValue = "\(status.rowsVisible.formatted()) objects"
        case .snapshot(_, let chunk):
            var capture = captureUpdate()
            if chunk.first {
                snapshotUIDs.removeAll(keepingCapacity: true)
            }
            snapshotUIDs.append(contentsOf: chunk.rows.map { $0.identity.uid })
            if let pendingScrollAnchor,
                chunk.last || chunk.rows.contains(where: { $0.identity.uid == pendingScrollAnchor.uid })
            {
                capture = ResourceTableUpdateCapture(
                    selectedUIDs: capture.selectedUIDs,
                    selectionAnchorUID: capture.selectionAnchorUID,
                    previousOrder: capture.previousOrder,
                    scrollAnchor: pendingScrollAnchor
                )
                self.pendingScrollAnchor = nil
            }
            let order: VisibleOrderUpdate = chunk.last
                ? .replace(snapshotUIDs)
                : .append(chunk.rows.map { $0.identity.uid })
            let plan = model.apply(
                ResourceRowBatch(
                    upserts: chunk.rows,
                    visibleOrder: order
                ),
                capture: capture
            )
            applyTablePlan(plan)
        case .delta(_, let delta):
            let capture = captureUpdate()
            let order: VisibleOrderUpdate = delta.orderIsComplete
                ? .replace(delta.orderedUIDs)
                : .unchanged
            let plan = model.apply(ResourceRowBatch(
                upserts: delta.upserts,
                removedUIDs: delta.removedUIDs,
                visibleOrder: order
            ), capture: capture)
            applyTablePlan(plan)
        case .failure(_, let issue):
            show(error: issue)
        }
        updateStatusLine()
    }

    private func captureUpdate() -> ResourceTableUpdateCapture {
        let firstRow = tableView.rows(in: tableView.visibleRect).location
        let uid = model.orderedVisibleUIDs.indices.contains(firstRow)
            ? model.orderedVisibleUIDs[firstRow] : nil
        let pixelOffset = uid.map { _ in
            Double(tableView.rect(ofRow: firstRow).minY - tableView.visibleRect.minY)
        } ?? 0
        return model.captureUpdate(topVisibleUID: uid, pixelOffsetFromTop: pixelOffset)
    }

    private func applyTablePlan(_ plan: ResourceTableUpdatePlan) {
        suppressSelectionCallbacks = true
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(plan.selectedRowIndexes), byExtendingSelection: false)
        suppressSelectionCallbacks = false
        if let restoration = plan.scrollRestoration,
            model.orderedVisibleUIDs.indices.contains(restoration.rowIndex)
        {
            let rowRect = tableView.rect(ofRow: restoration.rowIndex)
            let targetY = max(0, rowRect.minY - CGFloat(restoration.pixelOffsetFromTop))
            tableView.scroll(NSPoint(x: tableView.visibleRect.minX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func show(error: Error) {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
        freshnessLabel.stringValue = "Disconnected"
    }

    private func updateStatusLine() {
        countLabel.stringValue = "\(model.orderedVisibleUIDs.count.formatted()) objects"
        if let status = view.viewWithTag(0)?.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "resource-status-line" }) {
            status.stringValue = "\(model.orderedVisibleUIDs.count.formatted()) objects · \(model.selectionCounts.selected) selected · \(freshnessLabel.stringValue)"
        }
    }

    private func configureColumns(for resource: DiscoveredResource) {
        if let existing = columnDefinitionsByResourceID[resource.id] {
            installColumns(existing)
            return
        }
        let defaults = defaultColumnDefinitions(for: resource)
        let match = ColumnResourceMatch(
            group: resource.group,
            version: resource.version,
            resource: resource.resource
        )
        let definitions = (try? ColumnConfigurationFileStore(
            path: columnsConfigurationPath
        ).load().views.first(where: { $0.match == match })?.columns) ?? defaults
        columnDefinitionsByResourceID[resource.id] = definitions
        installColumns(definitions)
    }

    private func applyColumns(_ definitions: [ColumnDefinition], forResourceID resourceID: String) {
        guard resource?.id == resourceID else { return }
        columnDefinitionsByResourceID[resourceID] = definitions
        installColumns(definitions)
        openStream()
        onRestorationChanged?()
    }

    private func installColumns(_ definitions: [ColumnDefinition]) {
        columnDefinitionsByID.removeAll(keepingCapacity: true)
        for definition in definitions {
            columnDefinitionsByID[definition.id] = definition
        }
        let enabled = definitions.filter(\.isEnabled)
        columnIDs = enabled.map(\.id)

        suppressSortChanges = true
        defer { suppressSortChanges = false }
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        for definition in enabled {
            let column = NSTableColumn(identifier: .init(definition.id))
            column.title = definition.title
            column.width = definition.width.map { CGFloat($0) } ?? columnWidth(definition.id)
            column.minWidth = 55
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.id, ascending: true)
            tableView.addTableColumn(column)
        }
        let enabledIDs = Set(columnIDs)
        tableView.sortDescriptors = tableView.sortDescriptors.filter { descriptor in
            descriptor.key.map(enabledIDs.contains) ?? false
        }
        tableView.reloadData()
    }

    private func defaultColumnDefinitions(for resource: DiscoveredResource) -> [ColumnDefinition] {
        var ids = resource.namespaced ? ["namespace", "name"] : ["name"]
        if resource.resource == "pods" {
            ids += [
                "ready", "status", "restarts", "node",
                "cpu", "memory", "ephemeral-storage", "age",
            ]
        } else if resource.group.isEmpty && resource.version == "v1"
            && resource.resource == "nodes"
        {
            ids += ["status", "cpu", "memory", "ephemeral-storage", "age"]
        } else {
            ids += ["status", "age"]
        }
        return ids.map { id in
            ColumnDefinition(
                id: id,
                title: columnTitle(id),
                source: ["cpu", "memory", "ephemeral-storage"].contains(id) ? .metric : .builtin,
                value: id,
                type: columnType(id),
                alignment: columnAlignment(id),
                width: Double(columnWidth(id)),
                enabled: true
            )
        }
    }

    private func columnType(_ id: String) -> ColumnResultType {
        switch id {
        case "ready": .number
        case "restarts": .integer
        case "cpu", "memory", "ephemeral-storage": .resourceUsage
        case "age": .timestamp
        default: .string
        }
    }

    private func columnAlignment(_ id: String) -> ColumnAlignment {
        switch id {
        case "ready": .center
        case "restarts", "cpu", "memory", "ephemeral-storage", "age": .trailing
        default: .leading
        }
    }

    private func columnTitle(_ id: String) -> String {
        [
            "namespace": "Namespace", "name": "Name", "ready": "Ready",
            "status": "Status", "restarts": "Restarts", "node": "Node",
            "cpu": "CPU", "memory": "Memory",
            "ephemeral-storage": "Ephemeral Storage", "age": "Age",
        ][id] ?? id
    }

    private func columnWidth(_ id: String) -> CGFloat {
        [
            "namespace": 150, "name": 280, "ready": 70, "status": 130,
            "restarts": 75, "node": 180, "cpu": 190, "memory": 210,
            "ephemeral-storage": 230, "age": 75,
        ][id] ?? 120
    }

    private func navigationState() -> ResourceNavigationState? {
        guard let resource else { return nil }
        return ResourceNavigationState(
            group: resource.group, version: resource.version, resource: resource.resource,
            kind: resource.kind, namespaced: resource.namespaced, namespaceSelection: scope,
            filter: filterField.stringValue,
            sortColumnID: tableView.sortDescriptors.first?.key,
            sortDescending: !(tableView.sortDescriptors.first?.ascending ?? true),
            selectedUIDs: model.selectedUIDs,
            scrollAnchor: captureUpdate().scrollAnchor
        )
    }

    func restorationState(
        contextName: String,
        isSidebarVisible: Bool
    ) -> ClusterWindowRestorationState {
        let state = navigationState()
        let columns = tableView.tableColumns.map { column in
            ColumnPresentationState(
                columnID: column.identifier.rawValue,
                width: Double(column.width),
                isVisible: !column.isHidden
            )
        }
        let sorts = tableView.sortDescriptors.compactMap { descriptor -> SortDescriptorState? in
            guard let key = descriptor.key else { return nil }
            return SortDescriptorState(columnID: key, ascending: descriptor.ascending)
        }
        return ClusterWindowRestorationState(
            contextName: contextName,
            gvr: state.map { GVR(group: $0.group, version: $0.version, resource: $0.resource) },
            namespaceScope: NamespaceScope(scope),
            filter: filterField.stringValue,
            sort: sorts,
            columns: columns,
            isSidebarVisible: isSidebarVisible,
            scrollAnchor: captureUpdate().scrollAnchor
        )
    }

    @discardableResult
    func applyRestoration(
        _ restoration: ClusterWindowRestorationState,
        discoveredResources: [DiscoveredResource]
    ) -> Bool {
        guard let gvr = restoration.gvr,
            let restored = discoveredResources.first(where: {
                $0.group == gvr.group && $0.version == gvr.version && $0.resource == gvr.resource
            })
        else { return false }
        resource = restored
        scope = restoration.namespaceScope.namespaceSelection
        pendingScrollAnchor = restoration.scrollAnchor
        filterField.stringValue = restoration.filter
        suppressPresentationCheckpoint = true
        defer { suppressPresentationCheckpoint = false }
        configureColumns(for: restored)
        if !restoration.columns.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: restoration.columns.map { ($0.columnID, $0) })
            for column in tableView.tableColumns {
                if let state = byID[column.identifier.rawValue] {
                    column.width = CGFloat(state.width)
                    column.isHidden = !state.isVisible
                }
            }
            for (targetIndex, state) in restoration.columns.enumerated()
                where targetIndex < tableView.numberOfColumns
            {
                guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                    $0.identifier.rawValue == state.columnID
                }) else { continue }
                if currentIndex != targetIndex {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        }
        let availableColumnIDs = Set(tableView.tableColumns.map { $0.identifier.rawValue })
        tableView.sortDescriptors = restoration.sort.compactMap {
            guard availableColumnIDs.contains($0.columnID) else { return nil }
            return NSSortDescriptor(key: $0.columnID, ascending: $0.ascending)
        }
        let nav = ResourceNavigationState(
            group: restored.group, version: restored.version, resource: restored.resource,
            kind: restored.kind, namespaced: restored.namespaced,
            namespaceSelection: scope, filter: restoration.filter,
            sortColumnID: restoration.sort.first?.columnID,
            sortDescending: !(restoration.sort.first?.ascending ?? true),
            scrollAnchor: restoration.scrollAnchor
        )
        history = WorkspaceNavigationHistory(initial: .resource(nav))
        openStream()
        return true
    }

    private func restore(_ destination: WorkspaceDestination) {
        guard case .resource(let state) = destination else { return }
        resource = DiscoveredResource(
            group: state.group, version: state.version, resource: state.resource,
            kind: state.kind, namespaced: state.namespaced,
            verbs: ["list", "watch"]
        )
        scope = state.namespaceSelection
        pendingScrollAnchor = state.scrollAnchor
        filterField.stringValue = state.filter
        configureColumns(for: resource!)
        if let columnID = state.sortColumnID {
            tableView.sortDescriptors = [NSSortDescriptor(
                key: columnID,
                ascending: !state.sortDescending
            )]
        } else {
            tableView.sortDescriptors = []
        }
        openStream()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.orderedVisibleUIDs.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard model.orderedVisibleUIDs.indices.contains(row), let tableColumn else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell.\(tableColumn.identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let uid = model.orderedVisibleUIDs[row]
        let value = model.rowByUID[uid]?[tableColumn.identifier.rawValue]
        cell.textField?.stringValue = value?.displayText ?? "—"
        cell.textField?.toolTip = value?.tooltip
        switch columnDefinitionsByID[tableColumn.identifier.rawValue]?.alignment ?? .leading {
        case .leading: cell.textField?.alignment = .left
        case .center: cell.textField?.alignment = .center
        case .trailing: cell.textField?.alignment = .right
        }
        switch value?.severity {
        case .warning: cell.textField?.textColor = .systemOrange
        case .critical: cell.textField?.textColor = .systemRed
        case .informational: cell.textField?.textColor = .systemBlue
        case .muted: cell.textField?.textColor = .secondaryLabelColor
        default: cell.textField?.textColor = .labelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallbacks else { return }
        model.replaceSelectionFromVisibleRows(
            indexes: Array(tableView.selectedRowIndexes),
            anchorIndex: tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        )
        updateStatusLine()
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard !suppressSortChanges else { return }
        if let key = tableView.sortDescriptors.first?.key {
            logger.debug("Requested backend table sort for \(key, privacy: .public)")
        } else {
            logger.debug("Cleared backend table sort")
        }
        openStream()
        onRestorationChanged?()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        scheduleRestorationCheckpoint()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        scheduleRestorationCheckpoint()
    }

    @objc private func openSelectedObjectFromTable() {
        openSelectedObject(initialTab: .automatic)
    }

    private func openSelectedObject(initialTab: ObjectDetailInitialTab) {
        guard let identity = model.selectedIdentities.only else { return }
        onOpenObject?(identity, initialTab)
    }

    private func handle(_ command: ResourceTableCommand) {
        switch command {
        case .focusFilter:
            view.window?.makeFirstResponder(filterField)
        case .open:
            openSelectedObjectFromTable()
        case .openYAML:
            openSelectedObject(initialTab: .yaml)
        case .openEvents:
            openSelectedObject(initialTab: .events)
        case .startPortForward:
            guard let identity = model.selectedIdentities.only,
                identity.group.isEmpty,
                identity.version == "v1",
                identity.resource == "pods" || identity.resource == "services"
            else { return }
            onStartPortForward?(identity)
        case .openLogs:
            let identities = model.selectedIdentities
            guard !identities.isEmpty, identities.count <= 128,
                identities.allSatisfy({
                    $0.group.isEmpty && $0.version == "v1" && $0.resource == "pods"
                })
            else { NSSound.beep(); return }
            onOpenLogs?(identities)
        case .openExec:
            guard let identity = model.selectedIdentities.only,
                identity.group.isEmpty, identity.version == "v1", identity.resource == "pods"
            else { NSSound.beep(); return }
            onOpenExec?(identity)
        case .selectAll:
            model.selectAllVisible()
            suppressSelectionCallbacks = true
            tableView.selectAll(nil)
            suppressSelectionCallbacks = false
            updateStatusLine()
        case .delete:
            let visible = Set(model.orderedVisibleUIDs)
            let targets = model.selectedIdentities.map { identity in
                ResourceDeleteTarget(
                    identity: identity,
                    hiddenByFilter: !visible.contains(identity.uid)
                )
            }
            guard !targets.isEmpty else { NSSound.beep(); return }
            onDelete?(targets)
        case .scale:
            guard let identity = model.selectedIdentities.only else { return }
            onMutate?(identity, .scale)
        case .restart:
            guard let identity = model.selectedIdentities.only else { return }
            onMutate?(identity, .rolloutRestart)
        case .editMetadata:
            guard let identity = model.selectedIdentities.only else { return }
            onMutate?(identity, .metadata)
        case .moveDown, .moveUp:
            let delta = command == .moveDown ? 1 : -1
            let next = min(max(tableView.selectedRow + delta, 0), max(0, tableView.numberOfRows - 1))
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
        }
    }

    func performCommand(_ command: ResourceTableCommand) {
        guard canPerformCommand(command) else { NSSound.beep(); return }
        handle(command)
    }

    func canPerformCommand(_ command: ResourceTableCommand) -> Bool {
        guard view.window?.firstResponder === tableView else { return false }
        let selected = model.selectedIdentities
        switch command {
        case .open, .openYAML, .openEvents:
            return selected.count == 1
        case .openLogs:
            return !selected.isEmpty && selected.count <= 128 && selected.allSatisfy {
                $0.group.isEmpty && $0.version == "v1" && $0.resource == "pods"
            }
        case .openExec:
            return selected.count == 1 && selected[0].group.isEmpty
                && selected[0].version == "v1" && selected[0].resource == "pods"
        case .startPortForward:
            return selected.count == 1 && selected[0].group.isEmpty
                && selected[0].version == "v1"
                && (selected[0].resource == "pods" || selected[0].resource == "services")
        case .delete:
            return !selected.isEmpty
        case .scale:
            return selected.count == 1 && selected[0].namespace.isEmpty == false
                && ["deployments", "statefulsets", "replicasets"].contains(selected[0].resource)
        case .restart:
            return selected.count == 1 && selected[0].group == "apps"
                && selected[0].version == "v1"
                && ["deployments", "statefulsets", "daemonsets"].contains(selected[0].resource)
        case .editMetadata:
            return selected.count == 1
        case .focusFilter, .selectAll, .moveDown, .moveUp:
            return true
        }
    }
}

private enum ResourceTableCommand: Equatable {
    case focusFilter, open, openYAML, openEvents, openLogs, openExec
    case startPortForward, selectAll, delete, scale, restart, editMetadata, moveUp, moveDown
}

@MainActor
private final class ResourceTableView: NSTableView {
    var onCommand: ((ResourceTableCommand) -> Void)?

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else { super.keyDown(with: event); return }
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers, event.keyCode, command) {
        case ("/", _, false): onCommand?(.focusFilter)
        case ("j", _, false): onCommand?(.moveDown)
        case ("k", _, false): onCommand?(.moveUp)
        case (_, 36, false): onCommand?(.open)
        case ("y", _, false), ("Y", _, false): onCommand?(.openYAML)
        case ("e", _, false), ("E", _, false): onCommand?(.openEvents)
        case ("l", _, false), ("L", _, false): onCommand?(.openLogs)
        case ("s", _, false), ("S", _, false): onCommand?(.openExec)
        case ("p", _, false), ("P", _, false): onCommand?(.startPortForward)
        case ("a", _, true): onCommand?(.selectAll)
        case (_, 51, true): onCommand?(.delete)
        default: super.keyDown(with: event)
        }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
