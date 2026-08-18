import AppKit
import KmgrCore
import OSLog

typealias NamespacePickerPresenter = (NSPopUpButton, Any?) -> Void
typealias NamespacePickerKeyWindowCheck = (NSWindow) -> Bool

struct ResourceColumnsRequest {
    var resourceTitle: String
    var match: ColumnResourceMatch
    var defaultColumns: [ColumnDefinition]
    var discoveredColumns: [ColumnDefinition]
    var previewContext: ColumnPreviewContext
    var apply: @MainActor ([ColumnDefinition]) -> Void
}

struct DeferredColumnPresentationState {
    var columns: [ColumnPresentationState]
    var sort: [SortDescriptorState]
    var columnMoves: [ColumnMoveState] = []
    var measurementOverrides: [ColumnPresentationState] = []

    mutating func recordColumnMove(_ move: ColumnMoveState) {
        var boundedMove = move
        boundedMove.targetIndex = min(
            max(move.targetIndex, 0),
            ClusterWindowRestorationState.maximumColumns - 1
        )
        columnMoves.append(boundedMove)
        let overflow = columnMoves.count - ClusterWindowRestorationState.maximumColumns
        if overflow > 0 {
            // A configuration load normally lasts milliseconds. If it remains
            // unavailable across hundreds of gestures, retain the newest
            // restoration-safe operations instead of invalidating checkpoints.
            columnMoves.removeFirst(overflow)
        }
    }
}

/// One successfully persisted GVR-scoped definition change. Keeping fan-out
/// explicit and main-actor-bound avoids process-global notification payloads
/// while allowing every currently open workspace to reconcile its own view.
@MainActor
struct SavedResourceColumnsChange {
    var match: ColumnResourceMatch
    var definitions: [ColumnDefinition]

    @discardableResult
    func apply<Workspaces: Sequence>(to workspaces: Workspaces) -> Int
    where Workspaces.Element == ClusterWorkspaceWindowController {
        workspaces.reduce(into: 0) { count, workspace in
            if workspace.applySavedColumns(definitions, matching: match) {
                count += 1
            }
        }
    }
}

@MainActor
final class ClusterWorkspaceWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation, ContextualShortcutProviding
{
    private(set) var session: OpenedClusterSession
    private(set) var isAuthenticated: Bool
    var restorationID: String { restoration.id }
    var onClose: (() -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogWindow: ((LogWindowController) -> Void)?
    var onOpenTerminalWindow: ((TerminalWindowController) -> Void)?
    var onRestorationCheckpoint: ((ClusterWindowRestorationRecord) -> Void)?
    var contextualShortcutsDidChange: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        workspaceController.contextualShortcutSnapshot
    }

    var openYAMLSnapshotWindows: [YAMLSnapshotWindowController] {
        Array(yamlSnapshotWindowControllers.values)
    }

    private let provider: any WorkspaceResourceProviding
    private let connectionActivityProvider: any ClusterConnectionActivityProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let recentObjectStore: RecentObjectStore
    private let operationProvider: any ResourceOperationProviding
    private let logProvider: any LogStreamProviding
    private let execProvider: any ExecSessionProviding
    private let portForwards: PortForwardCoordinator
    private let columnsConfigurationPath: String
    private let logDisplayConfiguration: LogDisplayConfiguration
    private let confirmationPreferences: @MainActor () -> ConfirmationPreferences
    private let workspaceController: ClusterWorkspaceViewController
    private var restoration: ClusterWindowRestorationRecord
    private var portForwardConfigurationController: PortForwardConfigurationWindowController?
    private var logOpenTask: Task<Void, Never>?
    private var logOpenRevision: UInt64 = 0
    private var automaticExecOpenTask: Task<Void, Never>?
    private var automaticExecOpenRevision: UInt64 = 0
    private var execConfigurationController: ExecConfigurationWindowController?
    private var deleteResourcesController: DeleteResourcesWindowController?
    private var resourceMutationController: ResourceMutationWindowController?
    private var yamlSnapshotWindowControllers: [ResourceUID: YAMLSnapshotWindowController] = [:]
    private var didStartWorkspace = false

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        connectionActivityProvider: any ClusterConnectionActivityProviding,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        objectSearchProvider: any ObjectSearchProviding,
        objectDetailProvider: any ObjectDetailProviding,
        recentObjectStore: RecentObjectStore = .shared,
        operationProvider: any ResourceOperationProviding,
        logProvider: any LogStreamProviding,
        execProvider: any ExecSessionProviding,
        portForwards: PortForwardCoordinator,
        columnsConfigurationPath: String,
        columnsConfigurationLoader: ColumnConfigurationDocumentLoader = .fileSystem,
        logDisplayConfiguration: LogDisplayConfiguration,
        confirmationPreferences: @escaping @MainActor () -> ConfirmationPreferences,
        namespacePickerPresenter: @escaping NamespacePickerPresenter = { control, sender in
            control.performClick(sender)
        },
        namespacePickerKeyWindowCheck: @escaping NamespacePickerKeyWindowCheck = {
            $0.isKeyWindow
        },
        restoration: ClusterWindowRestorationRecord,
        startsAuthenticated: Bool = true,
        onShowPortForwards: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.isAuthenticated = startsAuthenticated
        self.provider = provider
        self.connectionActivityProvider = connectionActivityProvider
        self.objectDetailProvider = objectDetailProvider
        self.recentObjectStore = recentObjectStore
        self.operationProvider = operationProvider
        self.logProvider = logProvider
        self.execProvider = execProvider
        self.restoration = restoration
        self.portForwards = portForwards
        self.columnsConfigurationPath = columnsConfigurationPath
        self.logDisplayConfiguration = logDisplayConfiguration
        self.confirmationPreferences = confirmationPreferences

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let clusterPresentation = ClusterIdentityPresentation(session: session)
        window.title = "\(clusterPresentation.titlePrefix) — \(Product.applicationName)"
        window.subtitle = session.serverHostname
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 520)
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName(restoration.frameAutosaveName)

        workspaceController = ClusterWorkspaceViewController(
            session: session,
            isAuthenticated: startsAuthenticated,
            provider: provider,
            connectionActivityProvider: connectionActivityProvider,
            optionalResourceCatalogProvider: optionalResourceCatalogProvider,
            objectSearchProvider: objectSearchProvider,
            objectDetailProvider: objectDetailProvider,
            recentObjectStore: recentObjectStore,
            portForwards: portForwards,
            columnsConfigurationPath: columnsConfigurationPath,
            columnsConfigurationLoader: columnsConfigurationLoader,
            namespacePickerPresenter: namespacePickerPresenter,
            namespacePickerKeyWindowCheck: namespacePickerKeyWindowCheck,
            onShowPortForwards: onShowPortForwards
        )
        super.init(window: window)
        installWorkspaceCallbacks()
        window.delegate = self
        window.contentViewController = workspaceController
        window.toolbar = workspaceController.makeToolbar()
    }

    private func installWorkspaceCallbacks() {
        workspaceController.onStartPortForward = { [weak self] identity in
            self?.onStartPortForward?(identity)
        }
        workspaceController.onShowColumns = { [weak self] request in
            self?.onShowColumns?(request)
        }
        workspaceController.onOpenLogs = { [weak self] request in
            self?.openLogs(request)
        }
        workspaceController.onOpenYAMLSnapshot = { [weak self] identity in
            self?.showYAMLSnapshot(identity)
        }
        workspaceController.onOpenExec = { [weak self] target in
            self?.openAutomaticExec(target)
        }
        workspaceController.onConfigureExec = { [weak self] target in
            self?.showExecConfiguration(target)
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
        workspaceController.onContextualShortcutsChanged = { [weak self] in
            self?.contextualShortcutsDidChange?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClusterWorkspaceWindowController is programmatic")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !didStartWorkspace else { return }
        didStartWorkspace = true
        workspaceController.start(
            restoring: restoration.state,
            connectsImmediately: isAuthenticated
        )
    }

    /// Keep the last rendered view visible while the shared helper is down.
    /// No operation is replayed from this transition.
    func engineDidDisconnect(message: String) {
        yamlSnapshotWindowControllers.values.forEach { $0.engineDidDisconnect() }
        workspaceController.engineDidDisconnect(message: message)
    }

    func engineRecoveryFailed(_ error: Error) {
        workspaceController.engineRecoveryFailed(error)
    }

    /// Rebind the visible workspace to a freshly authenticated session after
    /// a helper generation change. Compact rows and local editor buffers stay
    /// in place; network views are opened afresh. Mutation sheets are
    /// intentionally dismissed instead of replayed.
    func recover(with recoveredSession: OpenedClusterSession) {
        dismissTransientOperationsForEngineRecovery()
        session = recoveredSession
        isAuthenticated = true
        let clusterPresentation = ClusterIdentityPresentation(session: recoveredSession)
        window?.title = "\(clusterPresentation.titlePrefix) — \(Product.applicationName)"
        window?.subtitle = recoveredSession.serverHostname
        yamlSnapshotWindowControllers.values.forEach { $0.recover(with: recoveredSession) }
        workspaceController.recover(with: recoveredSession)
        restoration.state = workspaceController.restorationState()
        onRestorationCheckpoint?(restoration)
    }

    /// Applies a persisted definition change only when this window is
    /// currently presenting the exact resource target. Navigation, filters,
    /// selection, and the window's optional-resource overlay remain owned by
    /// the receiving workspace.
    @discardableResult
    func applySavedColumns(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch
    ) -> Bool {
        workspaceController.applySavedColumns(definitions, matching: match)
    }

    private func dismissTransientOperationsForEngineRecovery() {
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        portForwardConfigurationController?.close()
        logOpenRevision &+= 1
        logOpenTask?.cancel()
        logOpenTask = nil
        automaticExecOpenRevision &+= 1
        automaticExecOpenTask?.cancel()
        automaticExecOpenTask = nil
        execConfigurationController?.close()
        deleteResourcesController?.close()
        resourceMutationController?.close()
        portForwardConfigurationController = nil
        execConfigurationController = nil
        deleteResourcesController = nil
        resourceMutationController = nil
    }

    func windowWillClose(_ notification: Notification) {
        logOpenRevision &+= 1
        logOpenTask?.cancel()
        logOpenTask = nil
        automaticExecOpenRevision &+= 1
        automaticExecOpenTask?.cancel()
        automaticExecOpenTask = nil
        let yamlWindows = Array(yamlSnapshotWindowControllers.values)
        yamlSnapshotWindowControllers.removeAll()
        yamlWindows.forEach { $0.close() }
        workspaceController.stop()
        restoration.state = workspaceController.restorationState()
        onRestorationCheckpoint?(restoration)
        if isAuthenticated {
            Task { [provider, session] in
                await provider.closeSession(sessionID: session.sessionID)
            }
        }
        onClose?()
    }

    private func showYAMLSnapshot(_ identity: ResourceIdentity) {
        guard isAuthenticated, identity.clusterSessionID == session.sessionID else {
            NSSound.beep()
            return
        }
        if let current = yamlSnapshotWindowControllers[identity.uid] {
            current.showWindow(nil)
            current.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = YAMLSnapshotWindowController(
            session: session,
            identity: identity,
            provider: objectDetailProvider
        )
        controller.onClose = { [weak self, weak controller] in
            guard self?.yamlSnapshotWindowControllers[identity.uid] === controller else { return }
            self?.yamlSnapshotWindowControllers.removeValue(forKey: identity.uid)
        }
        yamlSnapshotWindowControllers[identity.uid] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
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

    /// Resolve a UID-pinned snapshot and open the live window directly. The
    /// window itself retains editable stream controls; a setup sheet would only
    /// delay the common all-container action.
    func openLogs(_ request: LogOpenRequest) {
        guard logOpenTask == nil else { NSSound.beep(); return }
        guard LogResourceCompatibility.supportsSelection(request.resources),
            request.resources.allSatisfy({ $0.clusterSessionID == session.sessionID })
        else {
            presentLogOpenFailure(ClusterManagerIssue(
                category: .validation,
                reason: "InvalidLogSourceSelection",
                message: "Select compatible, UID-pinned resources from this cluster session.",
                contextName: session.contextName,
                operation: "open Pod logs"
            ))
            return
        }

        logOpenRevision &+= 1
        let revision = logOpenRevision
        let sessionID = session.sessionID
        logOpenTask = Task { [weak self, logProvider, logDisplayConfiguration] in
            defer {
                if let self, self.logOpenRevision == revision {
                    self.logOpenTask = nil
                }
            }
            do {
                let resolution = try await logProvider.resolveLogSources(
                    resources: request.resources
                )
                guard !Task.isCancelled, let self,
                    logOpenRevision == revision,
                    session.sessionID == sessionID
                else { return }
                let plan = try LogOpenPlanner.plan(
                    request: request,
                    resolution: resolution
                )
                let controller = LogWindowController(
                    session: session,
                    sources: plan.sources,
                    availableSources: plan.availableSources,
                    provider: logProvider,
                    options: LogOptions(previous: request.previous),
                    displayConfiguration: logDisplayConfiguration,
                    staticWorkloadSnapshot: plan.staticWorkloadSnapshot
                )
                onOpenLogWindow?(controller)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self,
                    logOpenRevision == revision,
                    session.sessionID == sessionID
                else { return }
                presentLogOpenFailure(error)
            }
        }
    }

    private func presentLogOpenFailure(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Open Logs"
        alert.informativeText = presentation.detailedText
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func openAutomaticExec(_ target: PodExecTarget) {
        guard automaticExecOpenTask == nil,
            execConfigurationController == nil
        else { NSSound.beep(); return }
        automaticExecOpenRevision &+= 1
        let revision = automaticExecOpenRevision
        let sessionID = session.sessionID
        automaticExecOpenTask = Task {
            defer {
                if automaticExecOpenRevision == revision {
                    automaticExecOpenTask = nil
                }
            }
            do {
                let controller = try await AutomaticExecWindowFactory.makeWindow(
                    session: session,
                    target: target,
                    objectDetailProvider: objectDetailProvider,
                    execProvider: execProvider
                )
                guard !Task.isCancelled,
                    automaticExecOpenRevision == revision,
                    session.sessionID == sessionID
                else { return }
                onOpenTerminalWindow?(controller)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled,
                    automaticExecOpenRevision == revision,
                    session.sessionID == sessionID
                else { return }
                presentExecOpenFailure(error)
            }
        }
    }

    private func presentExecOpenFailure(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Open Terminal"
        alert.informativeText = presentation.detailedText
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showExecConfiguration(_ target: PodExecTarget) {
        guard let window,
            automaticExecOpenTask == nil,
            execConfigurationController == nil
        else { NSSound.beep(); return }
        let controller = ExecConfigurationWindowController(
            session: session,
            podIdentity: target.pod,
            preferredContainer: target.preferredContainer,
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
            confirmationPreferences: confirmationPreferences(),
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

    @objc func navigateBack(_ sender: Any?) { workspaceController.navigateBack() }
    @objc func navigateForward(_ sender: Any?) { workspaceController.navigateForward() }

    @objc func focusResourceFilter(_ sender: Any?) {
        workspaceController.focusResourceFilter(sender)
    }
    @objc func chooseNamespace(_ sender: Any?) {
        workspaceController.chooseNamespace(sender)
    }
    @objc func moveResourceSelectionUp(_ sender: Any?) {
        workspaceController.moveResourceSelectionUp(sender)
    }
    @objc func moveResourceSelectionDown(_ sender: Any?) {
        workspaceController.moveResourceSelectionDown(sender)
    }
    @objc func extendResourceSelectionUp(_ sender: Any?) {
        workspaceController.extendResourceSelectionUp(sender)
    }
    @objc func extendResourceSelectionDown(_ sender: Any?) {
        workspaceController.extendResourceSelectionDown(sender)
    }
    @objc func enterResource(_ sender: Any?) { workspaceController.enterResource(sender) }
    @objc func openResourceDetails(_ sender: Any?) { workspaceController.openResourceDetails(sender) }
    @objc func openResourceYAML(_ sender: Any?) { workspaceController.openResourceYAML(sender) }
    @objc func openResourceYAMLSnapshot(_ sender: Any?) {
        workspaceController.openResourceYAMLSnapshot(sender)
    }
    @objc func openResourceEvents(_ sender: Any?) { workspaceController.openResourceEvents(sender) }
    @objc func openResourceLogs(_ sender: Any?) { workspaceController.openResourceLogs(sender) }
    @objc func openResourceExec(_ sender: Any?) { workspaceController.openResourceExec(sender) }
    @objc func configureResourceExec(_ sender: Any?) {
        workspaceController.configureResourceExec(sender)
    }
    @objc func startResourcePortForward(_ sender: Any?) { workspaceController.startResourcePortForward(sender) }
    @objc func deleteResourceSelection(_ sender: Any?) { workspaceController.deleteResourceSelection(sender) }
    @objc func scaleResourceSelection(_ sender: Any?) { workspaceController.scaleResourceSelection(sender) }
    @objc func restartResourceSelection(_ sender: Any?) { workspaceController.restartResourceSelection(sender) }
    @objc func editResourceMetadata(_ sender: Any?) { workspaceController.editResourceMetadata(sender) }
    @objc func copyResourceName(_ sender: Any?) { workspaceController.copyResourceName(sender) }
    @objc func copyResourceNamespacedName(_ sender: Any?) {
        workspaceController.copyResourceNamespacedName(sender)
    }
    @objc func copyResourceReference(_ sender: Any?) { workspaceController.copyResourceReference(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseNamespace(_:)) {
            return workspaceController.canChooseNamespace
        }
        let command: ResourceTableCommand?
        switch menuItem.action {
        case #selector(focusResourceFilter(_:)): command = .focusFilter
        case #selector(moveResourceSelectionUp(_:)): command = .moveUp
        case #selector(moveResourceSelectionDown(_:)): command = .moveDown
        case #selector(extendResourceSelectionUp(_:)): command = .extendUp
        case #selector(extendResourceSelectionDown(_:)): command = .extendDown
        case #selector(enterResource(_:)): command = .enter
        case #selector(openResourceDetails(_:)): command = .open
        case #selector(openResourceYAML(_:)): command = .openYAML
        case #selector(openResourceYAMLSnapshot(_:)): command = .openYAMLSnapshot
        case #selector(openResourceEvents(_:)): command = .openEvents
        case #selector(openResourceLogs(_:)): command = .openLogs
        case #selector(openResourceExec(_:)): command = .openExec
        case #selector(configureResourceExec(_:)): command = .configureExec
        case #selector(startResourcePortForward(_:)): command = .startPortForward
        case #selector(deleteResourceSelection(_:)): command = .delete
        case #selector(scaleResourceSelection(_:)): command = .scale
        case #selector(restartResourceSelection(_:)): command = .restart
        case #selector(editResourceMetadata(_:)): command = .editMetadata
        case #selector(copyResourceName(_:)): command = .copyName
        case #selector(copyResourceNamespacedName(_:)): command = .copyNamespacedName
        case #selector(copyResourceReference(_:)): command = .copyReference
        default: command = nil
        }
        guard let command else { return true }
        let compatible = workspaceController.isCommandCompatible(command)
        menuItem.isHidden = !compatible
        return compatible && workspaceController.canPerformCommand(command)
    }
}

@MainActor
private final class ClusterWorkspaceViewController: NSSplitViewController,
    NSToolbarDelegate, NSSearchFieldDelegate
{
    private var session: OpenedClusterSession
    private var isAuthenticated: Bool
    private let provider: any WorkspaceResourceProviding
    private let connectionActivityProvider: any ClusterConnectionActivityProviding
    private let objectSearchProvider: any ObjectSearchProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let recentObjectStore: RecentObjectStore
    private let portForwards: PortForwardCoordinator
    private let columnsConfigurationPath: String
    private let namespacePickerPresenter: NamespacePickerPresenter
    private let namespacePickerKeyWindowCheck: NamespacePickerKeyWindowCheck
    private let onShowPortForwards: @MainActor () -> Void
    private let sidebarController: ResourceSidebarViewController
    private let contentController: ResourceListViewController
    private let namespaceControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectionActivityView: ClusterConnectionActivityView
    private let connectionActivityStreamID = UUID().uuidString.lowercased()
    private var connectionActivityTask: Task<Void, Never>?
    private var connectionActivityGate = GenerationSequenceGate()
    private var connectionRateTracker = ClusterConnectionRateTracker()
    private let forwardsButton = NSButton(title: "Forwards 0", target: nil, action: nil)
    private let actionsButton = NSMenuToolbarItem(itemIdentifier: .actions)
    private var namespaceTask: Task<Void, Never>?
    private var portForwardObserver: UUID?
    private var resources: [DiscoveredResource] = []
    private var namespaces: [String] = []
    private var paletteController: CommandPaletteWindowController?
    private var palettePresentationTask: Task<Void, Never>?
    private var objectOpenTask: Task<Void, Never>?
    private var objectOpenRevision: UInt64 = 0
    private var detailController: ObjectDetailViewController?
    private var subresourceController: ObjectSubresourceListViewController?
    private var pendingRestorationState: ClusterWindowRestorationState?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenYAMLSnapshot: ((ResourceIdentity) -> Void)?
    var onOpenLogs: ((LogOpenRequest) -> Void)?
    var onOpenExec: ((PodExecTarget) -> Void)?
    var onConfigureExec: ((PodExecTarget) -> Void)?
    var onDelete: (([ResourceDeleteTarget]) -> Void)?
    var onMutate: ((ResourceIdentity, ResourceMutationWindowController.Mutation) -> Void)?
    var onRestorationChanged: ((ClusterWindowRestorationState) -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        if let subresourceController {
            return subresourceController.contextualShortcutSnapshot
        }
        if detailController != nil {
            return ContextualShortcutCatalog.objectDetails
        }
        return contentController.contextualShortcutSnapshot
    }

    init(
        session: OpenedClusterSession,
        isAuthenticated: Bool,
        provider: any WorkspaceResourceProviding,
        connectionActivityProvider: any ClusterConnectionActivityProviding,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        objectSearchProvider: any ObjectSearchProviding,
        objectDetailProvider: any ObjectDetailProviding,
        recentObjectStore: RecentObjectStore,
        portForwards: PortForwardCoordinator,
        columnsConfigurationPath: String,
        columnsConfigurationLoader: ColumnConfigurationDocumentLoader,
        namespacePickerPresenter: @escaping NamespacePickerPresenter,
        namespacePickerKeyWindowCheck: @escaping NamespacePickerKeyWindowCheck,
        onShowPortForwards: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.isAuthenticated = isAuthenticated
        self.provider = provider
        self.connectionActivityProvider = connectionActivityProvider
        self.objectSearchProvider = objectSearchProvider
        self.objectDetailProvider = objectDetailProvider
        self.recentObjectStore = recentObjectStore
        self.portForwards = portForwards
        self.columnsConfigurationPath = columnsConfigurationPath
        self.namespacePickerPresenter = namespacePickerPresenter
        self.namespacePickerKeyWindowCheck = namespacePickerKeyWindowCheck
        self.onShowPortForwards = onShowPortForwards
        let connectionActivityView = ClusterConnectionActivityView()
        self.connectionActivityView = connectionActivityView
        sidebarController = ResourceSidebarViewController(
            session: session,
            isAuthenticated: isAuthenticated,
            provider: provider
        )
        contentController = ResourceListViewController(
            session: session,
            isAuthenticated: isAuthenticated,
            provider: provider,
            optionalResourceCatalogProvider: optionalResourceCatalogProvider,
            columnsConfigurationPath: columnsConfigurationPath,
            columnsConfigurationLoader: columnsConfigurationLoader,
            connectionActivityView: connectionActivityView
        )
        super.init(nibName: nil, bundle: nil)

        sidebarController.onSelectResource = { [weak self] resource in
            guard let self else { return }
            guard pendingRestorationState == nil else { return }
            invalidateObjectOpenTask()
            showResourceList(resume: false)
            contentController.open(resource: resource, scope: selectedNamespaceScope())
            checkpointRestoration()
            view.window?.makeFirstResponder(contentController.tableResponder)
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
        contentController.onOpenYAMLSnapshot = { [weak self] identity in
            guard let self else { return }
            invalidateObjectOpenTask()
            Task { [recentObjectStore] in await recentObjectStore.record(identity) }
            onOpenYAMLSnapshot?(identity)
        }
        contentController.onEnterObject = { [weak self] identity in
            self?.enterObject(identity)
        }
        contentController.onStartPortForward = { [weak self] identity in
            self?.onStartPortForward?(identity)
        }
        contentController.onShowColumns = { [weak self] request in
            self?.onShowColumns?(request)
        }
        contentController.onOpenLogs = { [weak self] request in
            self?.onOpenLogs?(request)
        }
        contentController.onOpenExec = { [weak self] target in
            self?.onOpenExec?(target)
        }
        contentController.onConfigureExec = { [weak self] target in
            self?.onConfigureExec?(target)
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
        contentController.onContextualShortcutsChanged = { [weak self] in
            self?.onContextualShortcutsChanged?()
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

    func start(
        restoring state: ClusterWindowRestorationState? = nil,
        connectsImmediately: Bool = true
    ) {
        guard connectsImmediately else {
            installRestoredShell(state)
            return
        }
        pendingRestorationState = state
        connectionActivityView.setState(.connected)
        startConnectionActivityWatch()
        sidebarController.start { [weak self] result in
            guard let self else { return }
            guard case .success(let resources) = result else { return }
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
        startPortForwardObservation()
    }

    func restorationState() -> ClusterWindowRestorationState {
        contentController.restorationState(
            contextName: session.contextName,
            contextReference: session.contextReference,
            isSidebarVisible: !splitViewItems[0].isCollapsed
        )
    }

    @discardableResult
    func applySavedColumns(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch
    ) -> Bool {
        contentController.applySavedColumns(definitions, matching: match)
    }

    func engineDidDisconnect(message: String) {
        namespaceTask?.cancel()
        invalidateObjectOpenTask()
        palettePresentationTask?.cancel()
        palettePresentationTask = nil
        paletteController?.close()
        paletteController = nil
        // Discovery is session-bound. In particular, a restored shell must not
        // accept an exact-GVR result from the helper generation that just died.
        sidebarController.stop()
        detailController?.engineDidDisconnect()
        subresourceController?.setNetworkActionsEnabled(false)
        contentController.engineDidDisconnect()
        connectionActivityTask?.cancel()
        connectionActivityTask = nil
        connectionActivityView.setState(.reconnecting, detail: message)
    }

    func engineRecoveryFailed(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        connectionActivityView.setState(.failed, detail: presentation.detailedText)
        if !isAuthenticated {
            contentController.showDisconnected(
                "Could not connect to this saved context. \(presentation.inlineText)",
                toolTip: presentation.detailedText
            )
        }
    }

    func recover(with recoveredSession: OpenedClusterSession) {
        // Authentication can complete before discovery has validated a saved
        // target. A helper restart in that interval must stay on the shell
        // path; treating authentication alone as resumable would authorize the
        // synthetic resource in the new helper generation.
        let resumesCurrentResource = isAuthenticated
            && contentController.resourceCatalogValidated
        let restoredShellState = resumesCurrentResource ? nil : restorationState()
        let previousSessionID = session.sessionID
        session = recoveredSession
        isAuthenticated = true
        startConnectionActivityWatch()
        Task { [recentObjectStore] in
            await recentObjectStore.rebind(
                from: previousSessionID,
                to: recoveredSession.sessionID
            )
        }
        contentController.recover(
            session: recoveredSession,
            opensCurrentResource: resumesCurrentResource
        )
        if case .subresource(let identity, let returnState) = contentController.currentDestination {
            restoreSubresource(identity, returnState: returnState)
        }
        sidebarController.recover(session: recoveredSession) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let resources):
                if restoredShellState != nil,
                    contentController.validateRestoredResource(
                        restorationState(),
                        discoveredResources: resources
                    )
                {
                    sidebarController.selectResource(
                        matchingCurrent: contentController.currentResourceID
                    )
                } else {
                    sidebarController.reconcileSelection(
                        matching: contentController.currentResourceID
                    )
                }
                connectionActivityView.setState(.connected)
            case .failure(let error):
                // Existing authenticated workspaces keep their warm/current
                // resource behavior when rediscovery fails. Only an initial
                // shell still needs its synthetic target revoked.
                guard restoredShellState != nil else { return }
                sidebarController.discardRestoredResource()
                contentController.rejectRestoredResourceValidation(error)
                connectionActivityView.setState(
                    .failed,
                    detail: UserFacingErrorPresentation(error).detailedText
                )
            }
        }
        loadNamespaces()
        startPortForwardObservation()
        if let detailController {
            connectionActivityView.setState(.connecting, detail: "Reopening view…")
            detailController.recover(session: recoveredSession) { [weak self] result in
                switch result {
                case .success:
                    self?.connectionActivityView.setState(.connected)
                case .failure(let error):
                    self?.engineRecoveryFailed(error)
                }
            }
        } else if resumesCurrentResource {
            connectionActivityView.setState(.connected)
        } else {
            connectionActivityView.setState(
                .connecting,
                detail: "Loading the saved resource target…"
            )
        }
    }

    private func checkpointRestoration() {
        onRestorationChanged?(restorationState())
    }

    private func installRestoredShell(_ state: ClusterWindowRestorationState?) {
        isAuthenticated = false
        connectionActivityView.setState(
            .reconnecting,
            detail: "Opening saved Kubernetes context…"
        )
        if let state {
            splitViewItems[0].isCollapsed = !state.isSidebarVisible
            applyNamespaceScopeSelection(state.namespaceScope.namespaceSelection)
            contentController.applyRestoredShell(state)
            if let resource = RestoredWorkspaceShell(
                record: ClusterWindowRestorationRecord(id: "shell", state: state)
            ).targetResource {
                resources = [resource]
                sidebarController.installRestoredResource(resource)
                sidebarController.selectResource(matching: resource.id)
            }
        } else {
            contentController.showDisconnected("Opening saved Kubernetes context…")
        }
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    private func startPortForwardObservation() {
        guard isAuthenticated else { return }
        portForwards.register(session: session)
        if portForwardObserver == nil {
            portForwardObserver = portForwards.observe { [weak self] snapshot in
                self?.updatePortForwardButton(snapshot)
            }
        }
    }

    private func startConnectionActivityWatch() {
        connectionActivityTask?.cancel()
        connectionActivityGate.reset()
        connectionRateTracker = ClusterConnectionRateTracker()
        connectionActivityView.update(rate: ClusterConnectionRate())
        let provider = connectionActivityProvider
        let sessionID = session.sessionID
        let streamID = connectionActivityStreamID
        connectionActivityTask = Task { [weak self, provider] in
            do {
                for try await sample in provider.watchConnectionActivity(
                    sessionID: sessionID,
                    streamID: streamID
                ) {
                    guard !Task.isCancelled, let self,
                        self.session.sessionID == sessionID
                    else { return }
                    let disposition = connectionActivityGate.accept(sample.cursor)
                    guard disposition == .acceptedNewGeneration
                        || disposition == .acceptedNextSequence
                    else { continue }
                    connectionActivityView.setState(
                        sample.state,
                        detail: sample.issue?.userFacingPresentation.detailedText
                    )
                    connectionActivityView.update(
                        rate: connectionRateTracker.receive(sample)
                    )
                }
            } catch {
                guard !Task.isCancelled, self?.session.sessionID == sessionID else { return }
                let presentation = UserFacingErrorPresentation(error)
                self?.connectionActivityView.setState(
                    .reconnecting,
                    detail: presentation.detailedText
                )
            }
        }
    }

    func stop() {
        connectionActivityTask?.cancel()
        connectionActivityTask = nil
        namespaceTask?.cancel()
        palettePresentationTask?.cancel()
        palettePresentationTask = nil
        paletteController?.close()
        paletteController = nil
        invalidateObjectOpenTask()
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
        [.sidebar, .back, .forward, .namespace, .flexibleSpace, .palette, .forwards, .actions]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebar, .back, .forward, .namespace, .flexibleSpace, .palette, .forwards, .actions]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.isNavigational = true
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
            item.isNavigational = true
            item.target = self
            item.action = itemIdentifier == .back ? #selector(goBack) : #selector(goForward)
            return item
        case .namespace:
            namespaceControl.addItem(withTitle: "All namespaces")
            namespaceControl.target = self
            namespaceControl.action = #selector(namespaceChanged)
            namespaceControl.toolTip = "Namespace scope (⇧⌘N)"
            namespaceControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Namespace"
            item.isNavigational = true
            item.view = namespaceControl
            return item
        case .palette:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Commands"
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command Palette")
            item.target = self
            item.action = #selector(showCommandPalette)
            return item
        case .forwards:
            forwardsButton.bezelStyle = .texturedRounded
            forwardsButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
            forwardsButton.imagePosition = .imageLeading
            forwardsButton.imageHugsTitle = true
            forwardsButton.target = self
            forwardsButton.action = #selector(showPortForwards)
            forwardsButton.setAccessibilityLabel("Open app-wide Port Forwards")
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Port Forwards"
            item.view = forwardsButton
            return item
        case .actions:
            actionsButton.label = "Actions"
            actionsButton.image = NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: "Actions for selected resources"
            )
            actionsButton.showsIndicator = true
            actionsButton.menu = contentController.makeResourceMenu()
            return actionsButton
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

    /// Opens the existing native popup rather than maintaining a second
    /// namespace picker. Once open, AppKit supplies type-to-select, arrows,
    /// Return, and Escape entirely from the keyboard.
    var canChooseNamespace: Bool {
        guard isViewLoaded, let window = view.window else { return false }
        return namespacePickerKeyWindowCheck(window)
            && window.attachedSheet == nil
            && namespaceControl.isEnabled
            && !namespaceControl.isHidden
            && namespaceControl.numberOfItems > 0
    }

    @objc func chooseNamespace(_ sender: Any?) {
        guard canChooseNamespace, let window = view.window else {
            NSSound.beep()
            return
        }
        let previousResponder = window.firstResponder
        window.makeFirstResponder(namespaceControl)
        namespacePickerPresenter(namespaceControl, sender)

        // NSPopUpButton leaves itself first responder when native menu
        // tracking ends. A namespace selection returns to the resource list;
        // a cancellation in a detail/subresource preserves that leaf's prior
        // responder. In the ordinary list, always make keyboard discovery
        // immediately usable again.
        if detailController != nil || subresourceController != nil,
            let previousResponder,
            window.makeFirstResponder(previousResponder)
        {
            return
        }
        window.makeFirstResponder(contentController.tableResponder)
    }

    @objc private func showPortForwards() {
        onShowPortForwards()
    }

    @objc private func showCommandPalette() {
        presentCommandPalette()
    }

    override func cancelOperation(_ sender: Any?) {
        if let paletteController {
            paletteController.close()
            self.paletteController = nil
            return
        }
        if detailController != nil {
            showResourceList()
            checkpointRestoration()
            return
        }
        if contentController.handleEscape() { return }
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    @objc func focusResourceFilter(_ sender: Any?) { contentController.performCommand(.focusFilter) }
    @objc func moveResourceSelectionUp(_ sender: Any?) { contentController.performCommand(.moveUp) }
    @objc func moveResourceSelectionDown(_ sender: Any?) { contentController.performCommand(.moveDown) }
    @objc func extendResourceSelectionUp(_ sender: Any?) { contentController.performCommand(.extendUp) }
    @objc func extendResourceSelectionDown(_ sender: Any?) { contentController.performCommand(.extendDown) }
    @objc func enterResource(_ sender: Any?) { contentController.performCommand(.enter) }
    @objc func openResourceDetails(_ sender: Any?) { contentController.performCommand(.open) }
    @objc func openResourceYAML(_ sender: Any?) { contentController.performCommand(.openYAML) }
    @objc func openResourceYAMLSnapshot(_ sender: Any?) {
        contentController.performCommand(.openYAMLSnapshot)
    }
    @objc func openResourceEvents(_ sender: Any?) { contentController.performCommand(.openEvents) }
    @objc func openResourceLogs(_ sender: Any?) { performNetworkCommand(.openLogs) }
    @objc func openResourceExec(_ sender: Any?) { performNetworkCommand(.openExec) }
    @objc func configureResourceExec(_ sender: Any?) {
        performNetworkCommand(.configureExec)
    }
    @objc func startResourcePortForward(_ sender: Any?) {
        performNetworkCommand(.startPortForward)
    }
    @objc func deleteResourceSelection(_ sender: Any?) { contentController.performCommand(.delete) }
    @objc func scaleResourceSelection(_ sender: Any?) { contentController.performCommand(.scale) }
    @objc func restartResourceSelection(_ sender: Any?) { contentController.performCommand(.restart) }
    @objc func editResourceMetadata(_ sender: Any?) { contentController.performCommand(.editMetadata) }
    @objc func copyResourceName(_ sender: Any?) { contentController.performCommand(.copyName) }
    @objc func copyResourceNamespacedName(_ sender: Any?) {
        contentController.performCommand(.copyNamespacedName)
    }
    @objc func copyResourceReference(_ sender: Any?) { contentController.performCommand(.copyReference) }

    func canPerformCommand(_ command: ResourceTableCommand) -> Bool {
        if let action = command.subresourceNetworkAction,
            let subresourceController,
            subresourceController.isCompatible(with: action)
        {
            return subresourceController.canPerform(action)
        }
        return contentController.canPerformCommand(command)
    }

    func isCommandCompatible(_ command: ResourceTableCommand) -> Bool {
        if let action = command.subresourceNetworkAction,
            let subresourceController
        {
            return subresourceController.isCompatible(with: action)
        }
        return contentController.isCommandCompatible(command)
    }

    private func performNetworkCommand(_ command: ResourceTableCommand) {
        if let action = command.subresourceNetworkAction,
            let subresourceController,
            subresourceController.isCompatible(with: action)
        {
            if !subresourceController.perform(action) { NSSound.beep() }
            return
        }
        contentController.performCommand(command)
    }

    func presentCommandPalette() {
        guard isAuthenticated, contentController.resourceCatalogValidated else {
            NSSound.beep()
            return
        }
        if let paletteController {
            paletteController.showWindow(nil)
            return
        }
        guard palettePresentationTask == nil else { return }

        // Capture responder, scope, discovery snapshot, and full UID-pinned
        // identities synchronously at the Command-K event. Fetching recents is
        // asynchronous, so reading any of these values afterward could target
        // a different selection or responder.
        let capturedSession = session
        let capturedResources = resources
        let capturedNamespaces = namespaces
        let capturedScope = selectedNamespaceScope()
        let capturedCommandContext = contentController.captureCommandContext()
        palettePresentationTask = Task { [weak self, recentObjectStore] in
            let recentObjects = await recentObjectStore.recent(
                sessionID: capturedSession.sessionID
            )
            guard !Task.isCancelled, let self else { return }
            palettePresentationTask = nil
            guard paletteController == nil, session.sessionID == capturedSession.sessionID else {
                return
            }
            installCommandPalette(
                session: capturedSession,
                resources: capturedResources,
                namespaces: capturedNamespaces,
                namespaceScope: capturedScope,
                commandContext: capturedCommandContext,
                recentObjects: recentObjects
            )
        }
    }

    private func installCommandPalette(
        session: OpenedClusterSession,
        resources: [DiscoveredResource],
        namespaces: [String],
        namespaceScope: NamespaceSelection,
        commandContext: CommandContext,
        recentObjects: [RecentObject]
    ) {
        let controller = CommandPaletteWindowController(
            context: .init(
                session: session,
                resources: resources,
                namespaces: namespaces,
                namespaceScope: namespaceScope,
                commandContext: commandContext,
                recentObjects: recentObjects
            ),
            objectSearchProvider: objectSearchProvider
        )
        controller.onOpenResource = { [weak self] resource in
            guard let self else { return }
            invalidateObjectOpenTask()
            showResourceList(resume: false)
            contentController.open(resource: resource, scope: selectedNamespaceScope())
            checkpointRestoration()
            view.window?.makeFirstResponder(contentController.tableResponder)
        }
        controller.onChangeNamespace = { [weak self] namespace in
            self?.selectNamespace(namespace)
        }
        controller.onOpenObject = { [weak self] identity in
            self?.freshOpen(identity)
        }
        controller.onOperation = { [weak self] operation, capturedContext in
            self?.performPaletteOperation(operation, capturedContext: capturedContext)
        }
        controller.onClose = { [weak self, weak controller] in
            guard self?.paletteController === controller else { return }
            self?.paletteController = nil
        }
        paletteController = controller
        view.window?.addChildWindow(controller.window!, ordered: .above)
        controller.showWindow(nil)
    }

    private func performPaletteOperation(
        _ operation: PaletteOperation,
        capturedContext: CommandContext
    ) {
        guard CommandValidator.isEnabled(operation.commandID, in: capturedContext) else {
            NSSound.beep()
            return
        }
        guard capturedContext.selectedIdentities.allSatisfy({
            $0.clusterSessionID == session.sessionID
        }) else {
            // A helper generation change invalidates the session portion of
            // every captured identity. Never rebind and replay an operation.
            NSSound.beep()
            return
        }
        contentController.performCapturedCommand(
            operation.resourceTableCommand,
            identities: capturedContext.selectedIdentities,
            hiddenSelectionUIDs: capturedContext.hiddenSelectionUIDs
        )
    }

    private func freshOpen(_ identity: ResourceIdentity) {
        let revision = beginObjectOpenTask()
        connectionActivityView.setState(.connecting, detail: "Refreshing \(identity.name)…")
        objectOpenTask = Task { [weak self, objectDetailProvider] in
            guard let self else { return }
            defer {
                if objectOpenRevision == revision { objectOpenTask = nil }
            }
            do {
                let detail = try await objectDetailProvider.getObject(identity: identity)
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                connectionActivityView.setState(.connected)
                objectOpenTask = nil
                showObject(detail.identity, initialTab: .automatic)
            } catch {
                guard !Task.isCancelled else { return }
                let presentation = UserFacingErrorPresentation(error)
                connectionActivityView.setState(.failed, detail: presentation.detailedText)
            }
        }
    }

    private func enterObject(_ identity: ResourceIdentity) {
        guard ResourceDrillDownPlanner.hasPotentialTarget(identity),
            let returnState = contentController.captureNavigationState(),
            returnState.selectedUIDs.contains(identity.uid)
        else { return }

        let revision = beginObjectOpenTask()
        objectOpenTask = Task { [weak self, objectDetailProvider] in
            guard let self else { return }
            defer {
                if objectOpenRevision == revision { objectOpenTask = nil }
            }
            do {
                let detail = try await objectDetailProvider.getObject(identity: identity)
                guard !Task.isCancelled, objectOpenRevision == revision,
                    detail.identity == identity,
                    drillDownSourceIsCurrent(identity, returnState: returnState),
                    let plan = ResourceDrillDownPlanner.plan(for: detail)
                else { return }

                switch plan {
                case .resource(let query):
                    openDrillDownResource(query)
                case .containers(let pod, let values):
                    showSubresource(
                        .containers(pod: pod, values: values),
                        returnState: returnState
                    )
                case .data(let object):
                    let data = try await objectDetailProvider.getData(identity: object)
                    guard !Task.isCancelled, objectOpenRevision == revision,
                        data.identity == object,
                        drillDownSourceIsCurrent(identity, returnState: returnState)
                    else { return }
                    showSubresource(
                        .data(
                            object: object,
                            values: data.entries.map(DataSubresourceRow.init(entry:))
                        ),
                        returnState: returnState
                    )
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                let presentation = UserFacingErrorPresentation(error)
                connectionActivityView.setState(.failed, detail: presentation.detailedText)
            }
        }
    }

    private func drillDownSourceIsCurrent(
        _ identity: ResourceIdentity,
        returnState: ResourceNavigationState
    ) -> Bool {
        guard case .resource = contentController.currentDestination,
            let current = contentController.captureNavigationState()
        else { return false }
        return current.group == returnState.group
            && current.version == returnState.version
            && current.resource == returnState.resource
            && current.namespaceSelection == returnState.namespaceSelection
            && current.filter == returnState.filter
            && current.selectedUIDs.contains(identity.uid)
    }

    private func openDrillDownResource(_ query: ResourceDrillDownQuery) {
        guard let target = resources.first(where: {
            $0.group == query.group && $0.version == query.version
                && $0.resource == query.resource && $0.verbs.contains("list")
        }) else { return }
        showResourceList(resume: false)
        applyNamespaceScopeSelection(query.namespaceScope)
        contentController.open(
            resource: target,
            scope: query.namespaceScope,
            initialFilter: query.filterExpression
        )
        sidebarController.selectResource(matching: target.id)
        checkpointRestoration()
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    private func showSubresource(
        _ content: ObjectSubresourceContent,
        returnState: ResourceNavigationState
    ) {
        contentController.navigateToSubresource(content.parent, returnState: returnState)
        displaySubresource(content)
        checkpointRestoration()
    }

    private func displaySubresource(_ content: ObjectSubresourceContent) {
        detailController?.stop()
        detailController = nil
        contentController.suspend()
        let controller = ObjectSubresourceListViewController(content: content)
        controller.onBack = { [weak self] in self?.goBack() }
        controller.onOpenLogs = { [weak self] request in self?.onOpenLogs?(request) }
        controller.onOpenExec = { [weak self] target in self?.onOpenExec?(target) }
        controller.onConfigureExec = { [weak self] target in
            self?.onConfigureExec?(target)
        }
        controller.onStartPortForward = { [weak self] identity in
            self?.onStartPortForward?(identity)
        }
        controller.onOpenDataEditor = { [weak self] identity in
            self?.showObject(identity, initialTab: .data)
        }
        controller.onContextualShortcutsChanged = { [weak self] in
            self?.onContextualShortcutsChanged?()
        }
        subresourceController = controller
        replaceMainContent(with: controller)
        view.window?.makeFirstResponder(controller.view)
        onContextualShortcutsChanged?()
    }

    private func showObject(
        _ identity: ResourceIdentity,
        initialTab: ObjectDetailInitialTab
    ) {
        guard let returnState = contentController.captureNavigationState() else { return }
        Task { [recentObjectStore] in await recentObjectStore.record(identity) }
        contentController.navigateToObject(identity, returnState: returnState)
        displayObject(identity, initialTab: initialTab)
        checkpointRestoration()
    }

    private func displayObject(
        _ identity: ResourceIdentity,
        initialTab: ObjectDetailInitialTab
    ) {
        invalidateObjectOpenTask()
        detailController?.stop()
        subresourceController = nil
        contentController.suspend()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: objectDetailProvider,
            initialTab: initialTab,
            session: session
        )
        controller.onBack = { [weak self] in self?.goBack() }
        detailController = controller
        replaceMainContent(with: controller)
        view.window?.makeFirstResponder(controller.view)
        onContextualShortcutsChanged?()
    }

    private func showResourceList(resume: Bool = true) {
        guard detailController != nil || subresourceController != nil else { return }
        detailController?.stop()
        replaceMainContent(with: contentController)
        detailController = nil
        subresourceController = nil
        if resume { contentController.resume() }
        view.window?.makeFirstResponder(contentController.tableResponder)
        onContextualShortcutsChanged?()
    }

    private func replaceMainContent(with controller: NSViewController) {
        if splitViewItems.count > 1 {
            removeSplitViewItem(splitViewItems[1])
        }
        insertSplitViewItem(NSSplitViewItem(viewController: controller), at: 1)
    }

    @objc private func goBack() {
        guard let destination = contentController.goBack() else { return }
        restore(destination)
        checkpointRestoration()
    }

    func navigateBack() { goBack() }

    @objc private func goForward() {
        guard let destination = contentController.goForward() else { return }
        restore(destination)
        checkpointRestoration()
    }

    func navigateForward() { goForward() }

    private func restore(_ destination: WorkspaceDestination) {
        switch destination {
        case .resource(let state):
            invalidateObjectOpenTask()
            showResourceList(resume: false)
            applyNamespaceScopeSelection(state.namespaceSelection)
            contentController.restoreResource(state)
            sidebarController.selectResource(matchingCurrent: contentController.currentResourceID)
            view.window?.makeFirstResponder(contentController.tableResponder)
        case .object(let identity, _):
            displayObject(identity, initialTab: .automatic)
        case .subresource(let identity, let returnState):
            restoreSubresource(identity, returnState: returnState)
        }
    }

    private func restoreSubresource(
        _ identity: ResourceIdentity,
        returnState: ResourceNavigationState
    ) {
        let revision = beginObjectOpenTask()
        objectOpenTask = Task { [weak self, objectDetailProvider] in
            guard let self else { return }
            defer {
                if objectOpenRevision == revision { objectOpenTask = nil }
            }
            do {
                let detail = try await objectDetailProvider.getObject(identity: identity)
                guard !Task.isCancelled, objectOpenRevision == revision,
                    detail.identity == identity,
                    subresourceDestinationIsCurrent(identity),
                    let plan = ResourceDrillDownPlanner.plan(for: detail)
                else { return }
                switch plan {
                case .containers(let pod, let values):
                    displaySubresource(.containers(pod: pod, values: values))
                case .data(let object):
                    let data = try await objectDetailProvider.getData(identity: object)
                    guard !Task.isCancelled, objectOpenRevision == revision,
                        data.identity == object,
                        subresourceDestinationIsCurrent(identity)
                    else { return }
                    displaySubresource(.data(
                        object: object,
                        values: data.entries.map(DataSubresourceRow.init(entry:))
                    ))
                case .resource:
                    // Resource-to-resource drill-downs have their own resource
                    // history entry and are never encoded as a local child.
                    showResourceList(resume: false)
                    applyNamespaceScopeSelection(returnState.namespaceSelection)
                    contentController.restoreResource(returnState)
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                let presentation = UserFacingErrorPresentation(error)
                connectionActivityView.setState(.failed, detail: presentation.detailedText)
            }
        }
    }

    private func subresourceDestinationIsCurrent(_ identity: ResourceIdentity) -> Bool {
        guard case .subresource(let current, _) = contentController.currentDestination else {
            return false
        }
        return current == identity
    }

    private func invalidateObjectOpenTask() {
        objectOpenRevision &+= 1
        objectOpenTask?.cancel()
        objectOpenTask = nil
    }

    private func beginObjectOpenTask() -> UInt64 {
        invalidateObjectOpenTask()
        return objectOpenRevision
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
                let presentation = UserFacingErrorPresentation(error)
                connectionActivityView.setState(
                    .reconnecting,
                    detail: "Namespace list unavailable\n\(presentation.detailedText)"
                )
            }
        }
    }

    private func updatePortForwardButton(_ snapshot: PortForwardCoordinator.Snapshot) {
        forwardsButton.title = "Forwards \(snapshot.activeCount.formatted())"
        if snapshot.hasFailure {
            forwardsButton.contentTintColor = .systemRed
            forwardsButton.toolTip = "One or more port-forwards failed. Open Port Forwards."
            forwardsButton.setAccessibilityValue("\(snapshot.activeCount) active, failures present")
        } else if let issue = snapshot.connectionIssue {
            forwardsButton.contentTintColor = .systemOrange
            forwardsButton.toolTip = issue.userFacingPresentation.detailedText
            forwardsButton.setAccessibilityValue("\(snapshot.activeCount) active, status unavailable")
        } else {
            forwardsButton.contentTintColor = nil
            forwardsButton.toolTip = "\(snapshot.activeCount.formatted()) app-wide active port-forward(s)"
            forwardsButton.setAccessibilityValue("\(snapshot.activeCount) active")
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("workspace.sidebar")
    static let back = Self("workspace.back")
    static let forward = Self("workspace.forward")
    static let namespace = Self("workspace.namespace")
    static let palette = Self("workspace.palette")
    static let forwards = Self("workspace.forwards")
    static let actions = Self("workspace.actions")
}

@MainActor
private final class SidebarSectionRowView: NSTableRowView {
    let materialView = NSVisualEffectView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        materialView.identifier = .init("sidebar-section-background")
        materialView.material = .sidebar
        materialView.blendingMode = .withinWindow
        materialView.state = .followsWindowActiveState
        materialView.frame = bounds
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView, positioned: .below, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }
}

@MainActor
private final class SidebarSectionCellView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .semibold
        )
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }
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

    private var session: OpenedClusterSession
    private var isAuthenticated: Bool
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
        isAuthenticated: Bool,
        provider: any WorkspaceResourceProviding,
        pinStore: SidebarPinStore = .shared
    ) {
        self.session = session
        self.isAuthenticated = isAuthenticated
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

    func start(
        onComplete: ((Result<[DiscoveredResource], Error>) -> Void)? = nil
    ) {
        guard isAuthenticated else { return }
        if pinObserver == nil {
            pinObserver = pinStore.observe { [weak self] _ in
                self?.rebuildSections()
            }
        }
        guard task == nil else { return }
        statusLabel.stringValue = "Discovering resource kinds…"
        statusLabel.toolTip = nil
        statusLabel.textColor = .secondaryLabelColor
        task = Task { [weak self, provider, session] in
            guard let self else { return }
            do {
                let discovery = try await provider.discoverResources(
                    sessionID: session.sessionID,
                    refresh: false
                )
                guard !Task.isCancelled else { return }
                allResources = discovery.resources.filter { $0.verbs.contains("list") }
                onResourcesChanged?(allResources)
                rebuildSections()
                if discovery.potentiallyIncomplete {
                    statusLabel.stringValue = "\(allResources.count.formatted()) resource kinds • discovery incomplete"
                    statusLabel.toolTip = discovery.warning?.userFacingPresentation.detailedText
                        ?? "Some Kubernetes API groups could not be discovered."
                    statusLabel.textColor = .systemOrange
                } else if let issue = pinStore.loadIssue {
                    statusLabel.stringValue = "\(allResources.count.formatted()) kinds • built-in pins in use"
                    statusLabel.toolTip = issue.localizedDescription
                    statusLabel.textColor = .systemOrange
                } else {
                    statusLabel.stringValue = "\(allResources.count.formatted()) resource kinds"
                    statusLabel.toolTip = nil
                    statusLabel.textColor = .secondaryLabelColor
                }
                onComplete?(.success(allResources))
            } catch {
                guard !Task.isCancelled else { return }
                let presentation = UserFacingErrorPresentation(error)
                statusLabel.stringValue = presentation.inlineText
                statusLabel.toolTip = presentation.detailedText
                statusLabel.textColor = .systemRed
                onComplete?(.failure(error))
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

    func recover(
        session: OpenedClusterSession,
        onComplete: ((Result<[DiscoveredResource], Error>) -> Void)? = nil
    ) {
        task?.cancel()
        task = nil
        self.session = session
        isAuthenticated = true
        statusLabel.stringValue = "Reloading discovery…"
        statusLabel.textColor = .secondaryLabelColor
        start(onComplete: onComplete)
    }

    func installRestoredResource(_ resource: DiscoveredResource) {
        task?.cancel()
        task = nil
        allResources = [resource]
        onResourcesChanged?(allResources)
        statusLabel.stringValue = "Saved target · waiting for context"
        statusLabel.textColor = .systemOrange
        rebuildSections()
    }

    func discardRestoredResource() {
        allResources = []
        onResourcesChanged?(allResources)
        rebuildSections()
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
        for index in sections.indices
            where sections[index].title != "Custom Resources" || !query.isEmpty
        {
            outlineView.expandItem(sections[index])
        }
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
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        guard item is Section else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar-section-row")
        return outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? SidebarSectionRowView ?? SidebarSectionRowView(identifier: identifier)
    }

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
        if let section = item as? Section {
            let identifier = NSUserInterfaceItemIdentifier("sidebar-section-cell")
            let view = outlineView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? SidebarSectionCellView ?? SidebarSectionCellView(identifier: identifier)
            view.titleLabel.stringValue = section.title
            return view
        }

        guard let resource = item as? DiscoveredResource else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar-resource-cell")
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
        cell.textField?.stringValue = resource.kind.isEmpty ? resource.resource : resource.kind
        cell.textField?.font = .systemFont(ofSize: NSFont.systemFontSize)
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

    func selectResource(matchingCurrent resourceID: String?) {
        guard let resourceID,
            let resource = allResources.first(where: { $0.id == resourceID })
        else { return }
        select(resource: resource, notify: false)
    }

    /// Keep the current GVR selected when it still exists after helper
    /// rediscovery. If it disappeared, move to a fresh default instead of
    /// leaving the workspace attached to a resource the new API catalog does
    /// not expose.
    func reconcileSelection(matching resourceID: String?) {
        if let resourceID,
            let resource = allResources.first(where: { $0.id == resourceID })
        {
            select(resource: resource, notify: false)
            return
        }
        let fallback = allResources.first {
            $0.group.isEmpty && $0.resource == "pods"
        } ?? allResources.first
        if let fallback { select(resource: fallback, notify: true) }
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
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate
{
    private static let autoWidthPolicy = TableColumnAutoWidthPolicy()
    private static let maxPendingOptionalResourceKeys = 256

    private var session: OpenedClusterSession
    private var isAuthenticated: Bool
    private let provider: any WorkspaceResourceProviding
    private let optionalResourceCatalogProvider: any OptionalResourceCatalogProviding
    private let columnsConfigurationPath: String
    private let columnsConfigurationLoader: ColumnConfigurationDocumentLoader
    private let connectionActivityView: ClusterConnectionActivityView
    private let titleLabel = NSTextField(labelWithString: "Resources")
    private let scopeLabel = NSTextField(labelWithString: "All namespaces")
    private let freshnessLabel = NSTextField(labelWithString: "Idle")
    private let freshnessProgressIndicator = NSProgressIndicator()
    private let countLabel = NSTextField(labelWithString: "0 objects")
    private let sortLabel = NSTextField(labelWithString: "Unsorted")
    private let filterField = NSSearchField()
    private let tableView = ResourceTableView()
    private let scrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLine = NSTextField(labelWithString: "0 objects · 0 selected · Idle")
    private var tableTopWithoutErrorConstraint: NSLayoutConstraint?
    private var tableTopWithErrorConstraint: NSLayoutConstraint?
    private var inlineIssueState = ResourceListInlineIssueState()
    private var inlineIssueToolTip: String?
    private var model = ResourceTableModel()
    private var rowChangeDetector = ResourceRowChangeDetector(columnDefinitions: [])
    private var cellHighlightStore = ResourceCellHighlightStore()
    private let cellEffectsPolicy = ResourceTableCellEffectsPolicy.systemDefault
    private var cellHighlightRefreshTask: Task<Void, Never>?
    private var cellHighlightRefreshRevision: UInt64 = 0
    private var isChangeDetectionArmed = false
    private var requestedFilterHighlight: ResourceFilterHighlight?
    private var activeFilterHighlight: ResourceFilterHighlight?
    private var generationGate = GenerationSequenceGate()
    private var resource: DiscoveredResource?
    private var scope = NamespaceSelection()
    private var viewID = UUID().uuidString.lowercased()
    private var generation: UInt64 = 0
    private var lastCancelledGeneration: UInt64 = 0
    private var filterRevision: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var optionalResourceCatalogTask: Task<Void, Never>?
    private var optionalResourceCatalogTaskTicket: OptionalResourceCatalogDiscoveryTicket?
    private var optionalResourceCatalogTaskRefreshKeys: Set<String> = []
    private var optionalResourceCatalogTaskHintRevision: UInt64 = 0
    private var pendingOptionalResourceKeys: Set<String> = []
    private var pendingOptionalResourceRefreshRequired = false
    private var optionalResourceHintRevision: UInt64 = 0
    private var optionalResourceDiscoveryGate = OptionalResourceCatalogDiscoveryGate()
    private var optionalResourceOverlayState = OptionalResourceOverlayLifetimeState()
    private var filterTask: Task<Void, Never>?
    private var filterMemory = ResourceFilterMemory()
    private let filterCompletionTrigger = ResourceFilterCompletionTrigger()
    private var isFilterShortcutContextActive = false
    private var lastPublishedShortcutSnapshot: ContextualShortcutSnapshot?
    private var suppressSelectionCallbacks = false
    private var history = WorkspaceNavigationHistory()
    private var columnIDs: [String] = []
    private var columnDefinitionsByID: [String: ColumnDefinition] = [:]
    private var columnDefinitionsByResourceID: [String: [ColumnDefinition]] = [:]
    private var provisionalDefaultColumnResourceIDs: Set<String> = []
    private var columnsConfigurationCache = ColumnConfigurationCacheState()
    private var columnsConfigurationLoadTask: Task<Void, Never>?
    private var columnsConfigurationLoadGeneration: UInt64 = 0
    private var deferredColumnPresentationByResourceID: [
        String: DeferredColumnPresentationState
    ] = [:]
    private var suppressSortChanges = false
    private var snapshotUIDs: [ResourceUID] = []
    private var lastStreamContext: ResourceWarmRowContext?
    private var isRetainingWarmRowsForCurrentStream = false
    private var hasReceivedResourcePayloadForCurrentStream = false
    private var hasReceivedWarmRowReconciliationPayload = false
    private var backendResourceViewStatus: ResourceViewStatus?
    private var retainedRowsLastSynchronizedAt: Date?
    private var pendingScrollAnchor: ScrollAnchor?
    private var pendingSelectionUIDs: Set<ResourceUID>?
    private var restorationCheckpointTask: Task<Void, Never>?
    private var freshnessAgeTask: Task<Void, Never>?
    private var resourceViewStatus: ResourceViewStatus?
    /// Records whether retained rows came from a usable projection. A rejected
    /// replacement may keep those rows, but must label them as no longer watched.
    private var hasLastUsableResourceViewStatus = false
    private var suppressPresentationCheckpoint = false
    private var recoveredResourceTrust = RecoveredResourceTrust()
    /// A restored shell's synthetic resource is presentation-only. A real
    /// session does not make it requestable until authenticated discovery has
    /// confirmed the catalog (and `applyRestoration` has matched the exact
    /// group/version/resource).
    private(set) var resourceCatalogValidated: Bool
    private let logger = Logger(subsystem: Product.bundleIdentifier, category: "resource-table")
    private let tableSignposter = OSSignposter(
        subsystem: PerformanceSignpostCatalog.subsystem,
        category: PerformanceSignpostCatalog.resourceTableCategory
    )
    private var projectionRequestInterval: OSSignpostIntervalState?
    private var projectionRequestGeneration: UInt64?
    var onShowCommandPalette: (() -> Void)?
    var onEnterObject: ((ResourceIdentity) -> Void)?
    var onOpenObject: ((ResourceIdentity, ObjectDetailInitialTab) -> Void)?
    var onOpenYAMLSnapshot: ((ResourceIdentity) -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogs: ((LogOpenRequest) -> Void)?
    var onOpenExec: ((PodExecTarget) -> Void)?
    var onConfigureExec: ((PodExecTarget) -> Void)?
    var onDelete: (([ResourceDeleteTarget]) -> Void)?
    var onMutate: ((ResourceIdentity, ResourceMutationWindowController.Mutation) -> Void)?
    var onRestorationChanged: (() -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot {
        if isFilterShortcutContextActive {
            return ContextualShortcutCatalog.resourceFilter
        }
        let title: String
        if let resource, !resource.kind.isEmpty {
            title = "\(resource.kind) List"
        } else {
            title = resource?.resource.capitalized ?? "Resources"
        }
        let selected = model.selectedIdentities
        let networkActionsAllowed = recoveredResourceTrust.permitsNetworkActions(
            for: selected
        )
        func canUse(_ command: ResourceTableCommand) -> Bool {
            networkActionsAllowed && isCommandCompatible(command, with: selected)
        }
        return ContextualShortcutCatalog.resourceList(
            title: title,
            availability: ResourceListShortcutAvailability(
                canEnterSubresource: canUse(.enter),
                canOpenDetails: canUse(.open),
                canOpenYAML: canUse(.openYAML),
                canOpenEvents: canUse(.openEvents),
                canOpenLogs: canUse(.openLogs),
                canOpenTerminal: canUse(.openExec),
                canStartPortForward: canUse(.startPortForward),
                canDelete: canUse(.delete)
            )
        )
    }

    init(
        session: OpenedClusterSession,
        isAuthenticated: Bool,
        provider: any WorkspaceResourceProviding,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        columnsConfigurationPath: String,
        columnsConfigurationLoader: ColumnConfigurationDocumentLoader,
        connectionActivityView: ClusterConnectionActivityView
    ) {
        self.session = session
        self.isAuthenticated = isAuthenticated
        self.resourceCatalogValidated = isAuthenticated
        self.provider = provider
        self.optionalResourceCatalogProvider = optionalResourceCatalogProvider
        self.columnsConfigurationPath = columnsConfigurationPath
        self.columnsConfigurationLoader = columnsConfigurationLoader
        self.connectionActivityView = connectionActivityView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        scopeLabel.textColor = .secondaryLabelColor
        freshnessLabel.textColor = .secondaryLabelColor
        freshnessLabel.setAccessibilityLabel("Resource freshness")
        freshnessProgressIndicator.style = .spinning
        freshnessProgressIndicator.controlSize = .small
        freshnessProgressIndicator.isDisplayedWhenStopped = false
        freshnessProgressIndicator.isHidden = true
        freshnessProgressIndicator.setAccessibilityLabel("Resource view update in progress")
        countLabel.textColor = .secondaryLabelColor
        sortLabel.textColor = .secondaryLabelColor
        filterField.placeholderString = "Filter resources  /"
        filterField.setAccessibilityLabel("Filter Kubernetes resources")
        filterField.setAccessibilityHelp(
            "Type a name or structured filter. Suggestions are best effort. "
                + "Return applies the filter and returns to the resource list."
        )
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true
        // Let the filter use roughly half of the resource surface for long
        // selectors, while yielding first when the status labels need room.
        filterField.setContentHuggingPriority(.init(200), for: .horizontal)
        filterField.setContentCompressionResistancePriority(.init(499), for: .horizontal)

        let columnsButton = NSButton(title: "Columns…", target: self, action: #selector(showColumns))
        columnsButton.bezelStyle = .texturedRounded
        let header = NSStackView(views: [
            titleLabel, countLabel, scopeLabel, freshnessProgressIndicator,
            freshnessLabel, sortLabel, NSView(), filterField, columnsButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        let preferredFilterWidth = filterField.widthAnchor.constraint(
            equalTo: root.widthAnchor,
            multiplier: 0.5,
            constant: -24
        )
        preferredFilterWidth.priority = .init(240)
        let minimumFilterWidth = filterField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 180
        )
        minimumFilterWidth.priority = .init(500)
        NSLayoutConstraint.activate([
            preferredFilterWidth,
            minimumFilterWidth,
            filterField.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            filterField.widthAnchor.constraint(
                lessThanOrEqualTo: root.widthAnchor,
                multiplier: 0.5
            ),
        ])

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.doubleAction = #selector(enterSelectedObjectFromTable)
        tableView.target = self
        tableView.rowSizeStyle = .medium
        tableView.setAccessibilityLabel("Kubernetes resources")
        tableView.onCommand = { [weak self] command in self?.handle(command) }
        tableView.onSelectionGesture = { [weak self] gesture in
            self?.performSelectionGesture(gesture) ?? false
        }
        tableView.menu = makeResourceMenu()

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

        statusLine.identifier = .init("resource-status-line")
        statusLine.textColor = .secondaryLabelColor
        statusLine.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLine.lineBreakMode = .byTruncatingTail
        statusLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        let statusBar = NSStackView(views: [statusLine, NSView(), connectionActivityView])
        statusBar.identifier = .init("resource-status-bar")
        statusBar.orientation = .horizontal
        statusBar.alignment = .centerY
        statusBar.spacing = 8
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(errorLabel)
        root.addSubview(scrollView)
        root.addSubview(statusBar)
        let tableTopWithoutError = scrollView.topAnchor.constraint(
            equalTo: header.bottomAnchor,
            constant: 5
        )
        let tableTopWithError = scrollView.topAnchor.constraint(
            equalTo: errorLabel.bottomAnchor,
            constant: 5
        )
        tableTopWithoutErrorConstraint = tableTopWithoutError
        tableTopWithErrorConstraint = tableTopWithError
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            errorLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -2),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        applyInlineIssueState()
        view = root
    }

    func open(
        resource: DiscoveredResource,
        scope: NamespaceSelection,
        initialFilter: String? = nil
    ) {
        if case .resource = history.current, let current = navigationState() {
            history.replaceCurrent(with: .resource(current))
        }
        let nextGVR = resourceGVR(for: resource)
        let rememberedFilter = filterMemory.switchResource(
            from: self.resource.map(resourceGVR(for:)),
            currentFilter: filterField.stringValue,
            to: nextGVR
        )
        let restoredFilter = initialFilter ?? rememberedFilter
        if initialFilter != nil {
            filterMemory.remember(restoredFilter, for: nextGVR)
        }
        installFilterForNavigation(restoredFilter, resourceGVR: nextGVR)
        self.resource = resource
        self.scope = scope
        pendingScrollAnchor = nil
        let state = ResourceNavigationState(
            group: resource.group, version: resource.version, resource: resource.resource,
            kind: resource.kind, namespaced: resource.namespaced, namespaceSelection: scope,
            filter: restoredFilter
        )
        history.navigate(to: .resource(state))
        configureColumns(for: resource)
        openStream()
        publishContextualShortcutsIfChanged()
    }

    func changeNamespaceScope(_ scope: NamespaceSelection) {
        guard self.scope != scope else { return }
        if case .resource = history.current, let current = navigationState() {
            history.replaceCurrent(with: .resource(current))
        }
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
        columnsConfigurationLoadGeneration &+= 1
        columnsConfigurationLoadTask?.cancel()
        columnsConfigurationLoadTask = nil
        stopFreshnessAgeUpdates()
        suspend()
        clearOptionalResourceOverlay()
    }

    /// Preserve the last compact rows as an explicitly disconnected snapshot.
    /// A new helper generation receives a fresh session and opens a new view;
    /// the stale session is never reused for mutations.
    func engineDidDisconnect() {
        endProjectionRequest(outcome: "engine-disconnected")
        clearTransientCellPresentation()
        filterTask?.cancel()
        filterTask = nil
        streamTask?.cancel()
        streamTask = nil
        cancelOptionalResourceDiscovery(selecting: nil)
        generationGate.reset()
        recoveredResourceTrust.requireValidation()
        installFreshnessText("Disconnected")
        showInlineIssue(
            "The Kubernetes engine restarted. Rows shown here are from the last connected generation.",
            color: .systemOrange
        )
        updateStatusLine()
    }

    func showDisconnected(_ message: String, toolTip: String? = nil) {
        endProjectionRequest(outcome: "disconnected")
        clearTransientCellPresentation()
        streamTask?.cancel()
        streamTask = nil
        cancelOptionalResourceDiscovery(selecting: nil)
        model = ResourceTableModel()
        tableView.reloadData()
        installFreshnessText("Disconnected")
        showInlineIssue(message, color: .systemOrange, toolTip: toolTip)
        updateStatusLine()
        publishContextualShortcutsIfChanged()
    }

    func recover(
        session: OpenedClusterSession,
        opensCurrentResource: Bool = true
    ) {
        clearTransientCellPresentation()
        let sessionChanged = self.session.sessionID != session.sessionID
        self.session = session
        isAuthenticated = true
        resourceCatalogValidated = opensCurrentResource
        history.rebindClusterSessionID(session.sessionID)
        model.rebindClusterSessionID(session.sessionID)
        recoveredResourceTrust.requireValidation()
        publishContextualShortcutsIfChanged()
        if sessionChanged {
            cancelOptionalResourceDiscovery(selecting: nil)
            clearOptionalResourceOverlay()
            if let resource { installEffectiveColumns(for: resource) }
        }
        if opensCurrentResource, resource != nil { openStream() }
    }

    func suspend() {
        endProjectionRequest(outcome: "cancelled")
        clearTransientCellPresentation()
        stopFreshnessAgeUpdates()
        freshnessProgressIndicator.stopAnimation(nil)
        freshnessProgressIndicator.isHidden = true
        filterTask?.cancel()
        filterTask = nil
        cancelCurrentStream()
        cancelOptionalResourceDiscovery(selecting: nil)
    }

    func resume() {
        openStream()
    }

    var tableResponder: NSResponder { tableView }

    var currentResourceID: String? { resource?.id }

    var selectedIdentities: [ResourceIdentity] { model.selectedIdentities }

    var currentDestination: WorkspaceDestination? { history.current }

    func captureCommandContext() -> CommandContext {
        let selected = model.selectedIdentities
        let visibleUIDs = Set(model.orderedVisibleUIDs)
        let window = view.window
        let firstResponder = window?.firstResponder
        let filterOwnsResponder = firstResponder === filterField
            || filterField.currentEditor() === firstResponder
            || (firstResponder as? NSView).map { $0.isDescendant(of: filterField) } == true
        let tableOwnsResponder = firstResponder === tableView
            || (firstResponder as? NSView).map { $0.isDescendant(of: tableView) } == true
        let responder = ResourceListResponderClassifier.classify(
            tableOwnsResponder: tableOwnsResponder,
            filterOwnsResponder: filterOwnsResponder,
            tableHasActiveEditor: tableView.currentEditor() != nil
        )
        return .capturingResourceSelection(
            firstResponder: responder,
            selectedIdentities: selected,
            hiddenSelectionUIDs: Set(selected.lazy.map(\.uid).filter {
                !visibleUIDs.contains($0)
            }),
            networkActionsAllowed: recoveredResourceTrust.permitsNetworkActions(
                for: selected
            )
        )
    }

    @discardableResult
    func handleEscape() -> Bool {
        filterCompletionTrigger.reset()
        let firstResponder = view.window?.firstResponder
        let filterOwnsResponder = firstResponder === filterField
            || filterField.currentEditor() === firstResponder
            || (firstResponder as? NSView).map { $0.isDescendant(of: filterField) } == true
        if filterOwnsResponder || isFilterShortcutContextActive {
            if !filterField.stringValue.isEmpty {
                setFilter("")
            }
            setFilterShortcutContextActive(false)
            view.window?.makeFirstResponder(tableView)
            return true
        }
        if !filterField.stringValue.isEmpty {
            setFilter("")
            view.window?.makeFirstResponder(tableView)
            return true
        }
        if !model.selectedUIDs.isEmpty {
            model.clearSelection()
            suppressSelectionCallbacks = true
            tableView.deselectAll(nil)
            suppressSelectionCallbacks = false
            updateStatusLine()
            publishContextualShortcutsIfChanged()
            return true
        }
        return false
    }

    func makeResourceMenu() -> NSMenu {
        let menu = NSMenu(title: "Resource Actions")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addResourceMenuItems(to: menu)
    }

    private func addResourceMenuItems(to menu: NSMenu) {
        func add(_ title: String, _ command: ResourceTableCommand) {
            let item = NSMenuItem(title: title, action: #selector(performContextMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ResourceTableCommandBox(command)
            item.isEnabled = canPerformCommand(command, requiringTableFocus: false)
            menu.addItem(item)
        }
        func addGroup(_ entries: [(String, ResourceTableCommand)]) {
            let compatible = entries.filter { isCommandCompatible($0.1) }
            guard !compatible.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for (title, command) in compatible { add(title, command) }
        }
        addGroup([
            ("Enter Subresource", .enter),
            ("Open Details", .open),
            ("Open YAML in Details", .openYAML),
            ("Open YAML in New Window", .openYAMLSnapshot),
            ("Open Events", .openEvents),
        ])
        addGroup([
            ("Open Logs…", .openLogs),
            ("Open Terminal", .openExec),
            ("Configure Terminal…", .configureExec),
            ("Start Port Forward…", .startPortForward),
        ])
        addGroup([
            ("Scale…", .scale),
            ("Rollout Restart…", .restart),
            ("Edit Labels / Annotations…", .editMetadata),
        ])
        addGroup([
            ("Copy Name", .copyName),
            ("Copy Namespace/Name", .copyNamespacedName),
            ("Copy kubectl Reference", .copyReference),
        ])
        addGroup([("Delete…", .delete)])
    }

    @objc private func performContextMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ResourceTableCommandBox else { return }
        guard canPerformCommand(box.command, requiringTableFocus: false) else { NSSound.beep(); return }
        handle(box.command)
    }

    func setFilter(_ value: String) {
        filterCompletionTrigger.reset()
        filterRevision &+= 1
        filterTask?.cancel()
        filterField.stringValue = value
        rememberCurrentFilter()
        openStream()
        onRestorationChanged?()
        setFilterShortcutContextActive(true)
        view.window?.makeFirstResponder(filterField)
    }

    func captureNavigationState() -> ResourceNavigationState? {
        navigationState()
    }

    func navigateToObject(_ identity: ResourceIdentity, returnState: ResourceNavigationState) {
        if case .resource = history.current {
            history.replaceCurrent(with: .resource(returnState))
        }
        history.navigate(to: .object(identity, returnState: returnState))
    }

    func navigateToSubresource(
        _ identity: ResourceIdentity,
        returnState: ResourceNavigationState
    ) {
        if case .resource = history.current {
            history.replaceCurrent(with: .resource(returnState))
        }
        history.navigate(to: .subresource(identity, returnState: returnState))
    }

    func goBack() -> WorkspaceDestination? {
        if case .resource = history.current, let current = navigationState() {
            history.replaceCurrent(with: .resource(current))
        }
        return history.goBack()
    }

    func goForward() -> WorkspaceDestination? {
        if case .resource = history.current, let current = navigationState() {
            history.replaceCurrent(with: .resource(current))
        }
        return history.goForward()
    }

    @objc func showCommandPalette() {
        onShowCommandPalette?()
    }

    @objc private func showColumns() {
        guard isAuthenticated, resourceCatalogValidated else { NSSound.beep(); return }
        guard let resource else { return }
        let resourceID = resource.id
        let resourceGVR = resourceGVR(for: resource)
        let discoveredColumns = optionalResourceOverlayState.applies(
            sessionID: session.sessionID,
            gvr: resourceGVR
        ) ? optionalResourceOverlayState.overlay.definitions : []
        onShowColumns?(ResourceColumnsRequest(
            resourceTitle: resource.kind.isEmpty ? resource.resource : resource.kind,
            match: ColumnResourceMatch(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            ),
            defaultColumns: defaultColumnDefinitions(for: resource),
            discoveredColumns: discoveredColumns,
            previewContext: ColumnPreviewContext(
                sessionID: session.sessionID,
                resource: resource,
                namespaceScope: scope,
                selectedObject: model.selectedIdentities.only
            ),
            apply: { [weak self] definitions in
                self?.applyColumns(definitions, forResourceID: resourceID)
            }
        ))
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSControl === filterField else { return }
        filterCompletionTrigger.reset()
        setFilterShortcutContextActive(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSControl === filterField else { return }
        filterCompletionTrigger.reset()
        setFilterShortcutContextActive(false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSControl === filterField else { return }
        clearTransientCellPresentation()
        filterRevision &+= 1
        filterTask?.cancel()
        endProjectionRequest(outcome: "filter-revision")
        cancelCurrentStream()
        hideInlineIssue()
        installFreshnessText(
            model.orderedVisibleUIDs.isEmpty
                ? "Filtering…" : "Filtering… · last good rows"
        )
        rememberCurrentFilter()
        let revision = filterRevision
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, self?.filterRevision == revision else { return }
            self?.openStream()
            self?.onRestorationChanged?()
        }
        filterCompletionTrigger.textDidChange(
            editor: filterField.currentEditor() as? NSTextView,
            isCurrentEditor: { [weak self] editor in
                self?.filterField.currentEditor() === editor
            },
            hasCandidates: { [weak self] editor in
                guard let self, let resource else { return false }
                return !ResourceFilterCompletionCatalog.completions(
                    in: editor.string,
                    partialWordRange: editor.rangeForUserCompletion,
                    context: ResourceFilterCompletionContext(resource: resource)
                ).isEmpty
            }
        )
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions _: [String],
        forPartialWordRange partialWordRange: NSRange,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>
    ) -> [String] {
        // Do not let AppKit preview a candidate by rewriting the live filter.
        // The user can explicitly choose one, while Return continues to apply
        // exactly the text they typed.
        selectedIndex.pointee = -1
        guard control === filterField, let resource else { return [] }
        return ResourceFilterCompletionCatalog.completions(
            in: textView.string,
            partialWordRange: partialWordRange,
            context: ResourceFilterCompletionContext(resource: resource)
        )
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === filterField,
            commandSelector == #selector(NSResponder.insertNewline(_:))
        else { return false }

        // Do not make an explicit Return wait for the typing debounce. This
        // also gives keyboard navigation back to the resource table.
        filterCompletionTrigger.reset()
        filterTask?.cancel()
        filterTask = nil
        rememberCurrentFilter()
        openStream()
        onRestorationChanged?()
        setFilterShortcutContextActive(false)
        view.window?.makeFirstResponder(tableView)
        return true
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

    private func openStream(
        preservingOptionalResourceDiscoveryState: Bool = false
    ) {
        guard isAuthenticated, resourceCatalogValidated else { return }
        guard let resource else { return }
        endProjectionRequest(outcome: "superseded")
        cancelCurrentStream()
        clearTransientCellPresentation()
        requestedFilterHighlight = ResourceFilterHighlightParser.parse(
            filterField.stringValue
        )
        generation &+= 1
        prepareOptionalResourceDiscovery(
            for: resource,
            preservingOptionalResourceDiscoveryState:
                preservingOptionalResourceDiscoveryState
        )
        beginProjectionRequest()
        generationGate.reset()
        let nextStreamContext = ResourceWarmRowContext(
            sessionID: session.sessionID,
            gvr: resourceGVR(for: resource),
            namespaceSelection: scope
        )
        let sameDataContext = lastStreamContext == nextStreamContext
        let canKeepWarmRows = ResourceWarmRowPolicy.canRetain(
            existingRowCount: model.orderedVisibleUIDs.count,
            previousContext: lastStreamContext,
            nextContext: nextStreamContext
        )
        if !sameDataContext {
            hasLastUsableResourceViewStatus = false
        }
        if !canKeepWarmRows {
            model = ResourceTableModel()
            tableView.reloadData()
        }
        lastStreamContext = nextStreamContext
        isRetainingWarmRowsForCurrentStream = canKeepWarmRows
        hasReceivedResourcePayloadForCurrentStream = false
        hasReceivedWarmRowReconciliationPayload = false
        backendResourceViewStatus = nil
        retainedRowsLastSynchronizedAt = canKeepWarmRows
            ? resourceViewStatus?.lastSynchronizedAt : nil
        snapshotUIDs.removeAll(keepingCapacity: true)
        hideInlineIssue()
        titleLabel.stringValue = resource.kind.isEmpty ? resource.resource : resource.kind
        scopeLabel.stringValue = scope.presentation
        if canKeepWarmRows {
            installResourceViewStatus(ResourceWarmRowPolicy.refreshingStatus(
                backendStatus: nil,
                retainedRowCount: model.orderedVisibleUIDs.count,
                lastSynchronizedAt: retainedRowsLastSynchronizedAt
            ))
        } else {
            installResourceViewStatus(ResourceViewStatus(freshness: .loading))
        }
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
                self?.endProjectionRequest(outcome: "failed")
                self?.show(error: error)
            }
        }
    }

    /// A typed filter revision invalidates projection work immediately; the
    /// debounce delays only creation of its replacement. Duplicate cancellation
    /// calls for the same generation are suppressed because `openStream()` also
    /// crosses this boundary after the debounce.
    private func cancelCurrentStream() {
        streamTask?.cancel()
        streamTask = nil
        let generation = generation
        guard generation > 0, generation != lastCancelledGeneration else { return }
        lastCancelledGeneration = generation
        Task { [provider, session, viewID] in
            await provider.cancelView(
                sessionID: session.sessionID,
                viewID: viewID,
                generation: generation
            )
        }
    }

    private func receive(_ message: ResourceViewMessage) {
        let cursor = message.cursor
        guard cursor.generation == generation else { return }
        let disposition = generationGate.accept(cursor)
        guard disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence else { return }
        var shouldPublishContextualShortcuts = false

        switch message {
        case .status(_, let status):
            backendResourceViewStatus = status
            if isRetainingWarmRowsForCurrentStream {
                if !finishWarmRowRetentionIfReconciled() {
                    installResourceViewStatus(ResourceWarmRowPolicy.refreshingStatus(
                        backendStatus: status,
                        retainedRowCount: model.orderedVisibleUIDs.count,
                        lastSynchronizedAt: retainedRowsLastSynchronizedAt
                    ))
                }
                countLabel.stringValue = "\(model.orderedVisibleUIDs.count.formatted()) objects"
            } else {
                installResourceViewStatus(status)
                countLabel.stringValue = "\(status.rowsVisible.formatted()) objects"
            }
        case .snapshot(_, let chunk):
            let isInitialSnapshot = !hasReceivedResourcePayloadForCurrentStream
            hasReceivedResourcePayloadForCurrentStream = true
            if ResourceWarmRowPolicy.preservesRetainedRows(
                for: chunk,
                backendStatus: backendResourceViewStatus,
                isRetainingWarmRows: isRetainingWarmRowsForCurrentStream,
                isFirstSnapshotInStream: isInitialSnapshot
            ) {
                snapshotUIDs.removeAll(keepingCapacity: true)
                break
            }
            let metadata = message.resourceBatchSignpostMetadata!
            let interval = tableSignposter.beginInterval(
                PerformanceSignpostCatalog.resourceModelApply,
                "kind=\(metadata.kind.rawValue, privacy: .public) generation=\(metadata.generation) sequence=\(metadata.sequence) upserts=\(metadata.upsertCount) removals=\(metadata.removalCount) order_count=\(metadata.orderCount) replaces_order=\(metadata.replacesOrder)"
            )
            var capture = captureUpdate()
            if chunk.first {
                clearTransientCellPresentation(
                    keepingRequestedFilterHighlight: true
                )
                snapshotUIDs.removeAll(keepingCapacity: true)
            }
            snapshotUIDs.append(contentsOf: chunk.rows.map { $0.identity.uid })
            recoveredResourceTrust.receiveSnapshot(
                uids: chunk.rows.map { $0.identity.uid },
                first: chunk.first,
                last: chunk.last
            )
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
            var plan = model.apply(
                ResourceRowBatch(
                    upserts: chunk.rows,
                    visibleOrder: order
                ),
                capture: capture
            )
            plan = restoringPendingSelection(in: plan, chunkIsComplete: chunk.last)
            tableSignposter.endInterval(
                PerformanceSignpostCatalog.resourceModelApply,
                interval,
                "visible_rows=\(self.model.orderedVisibleUIDs.count) stored_rows=\(self.model.rowByUID.count) selected_rows=\(plan.selectedRowIndexes.count)"
            )
            applyTablePlan(plan)
            if chunk.last {
                hasReceivedWarmRowReconciliationPayload = true
                finishWarmRowRetentionIfReconciled(force: true)
                isChangeDetectionArmed = true
                activateRequestedFilterHighlight()
            }
            observeOptionalResourceKeys(
                chunk.observedOptionalResourceKeys,
                truncated: chunk.observedOptionalResourceKeysTruncated
            )
            if !chunk.rows.isEmpty || chunk.last {
                markBaseViewUsableForOptionalResourceDiscovery()
            }
            if chunk.last {
                endProjectionRequest(outcome: "snapshot-complete")
                shouldPublishContextualShortcuts = true
            }
        case .delta(_, let delta):
            hasReceivedResourcePayloadForCurrentStream = true
            let detectedChanges: [ResourceCellChange] = isChangeDetectionArmed
                ? delta.upserts.flatMap { row -> [ResourceCellChange] in
                    guard !delta.removedUIDs.contains(row.identity.uid) else {
                        return []
                    }
                    return rowChangeDetector.changes(
                        from: model.rowByUID[row.identity.uid],
                        to: row
                    )
                }
                : []
            var affectedCellAddresses = cellHighlightStore.removeAll(
                forUIDs: delta.removedUIDs
            )
            let selectedUIDs = model.selectedUIDs
            shouldPublishContextualShortcuts = delta.removedUIDs.contains {
                selectedUIDs.contains($0)
            } || (recoveredResourceTrust.requiresValidation && delta.upserts.contains {
                selectedUIDs.contains($0.identity.uid)
            })
            let metadata = message.resourceBatchSignpostMetadata!
            let interval = tableSignposter.beginInterval(
                PerformanceSignpostCatalog.resourceModelApply,
                "kind=\(metadata.kind.rawValue, privacy: .public) generation=\(metadata.generation) sequence=\(metadata.sequence) upserts=\(metadata.upsertCount) removals=\(metadata.removalCount) order_count=\(metadata.orderCount) replaces_order=\(metadata.replacesOrder)"
            )
            let capture = captureUpdate()
            let order: VisibleOrderUpdate = delta.orderIsComplete
                ? .replace(delta.orderedUIDs)
                : .unchanged
            var plan = model.apply(ResourceRowBatch(
                upserts: delta.upserts,
                removedUIDs: delta.removedUIDs,
                visibleOrder: order
            ), capture: capture)
            plan = restoringPendingSelection(in: plan, chunkIsComplete: false)
            tableSignposter.endInterval(
                PerformanceSignpostCatalog.resourceModelApply,
                interval,
                "visible_rows=\(self.model.orderedVisibleUIDs.count) stored_rows=\(self.model.rowByUID.count) selected_rows=\(plan.selectedRowIndexes.count)"
            )
            if !detectedChanges.isEmpty {
                affectedCellAddresses.formUnion(cellHighlightStore.record(
                    detectedChanges,
                    at: ContinuousClock.now,
                    visibleUIDs: visibleResourceUIDsInViewport()
                ))
            }
            applyTablePlan(plan)
            hasReceivedWarmRowReconciliationPayload = true
            finishWarmRowRetentionIfReconciled()
            reloadVisibleCellPresentation(at: affectedCellAddresses)
            scheduleCellHighlightRefresh()
            recoveredResourceTrust.receiveDelta(
                upsertedUIDs: delta.upserts.map { $0.identity.uid },
                removedUIDs: delta.removedUIDs
            )
            observeOptionalResourceKeys(
                delta.observedOptionalResourceKeys,
                truncated: delta.observedOptionalResourceKeysTruncated
            )
        case .failure(_, let issue):
            endProjectionRequest(outcome: "failed")
            show(error: issue)
        }
        updateStatusLine()
        if shouldPublishContextualShortcuts {
            publishContextualShortcutsIfChanged()
        }
    }

    /// Ends the locally retained presentation only after a real replacement
    /// payload. `force` is reserved for a completed non-placeholder snapshot;
    /// delta reconciliation waits for WATCHING/COMPLETE and therefore works
    /// whether the status or delta arrives first.
    @discardableResult
    private func finishWarmRowRetentionIfReconciled(
        force: Bool = false
    ) -> Bool {
        guard isRetainingWarmRowsForCurrentStream,
            hasReceivedWarmRowReconciliationPayload,
            force || ResourceWarmRowPolicy.statusConfirmsAuthoritativeReconciliation(
                backendResourceViewStatus
            )
        else { return false }

        isRetainingWarmRowsForCurrentStream = false
        retainedRowsLastSynchronizedAt = nil
        var status = backendResourceViewStatus ?? ResourceViewStatus(
            freshness: .complete
        )
        status.rowsVisible = UInt64(model.orderedVisibleUIDs.count)
        installResourceViewStatus(status)
        return true
    }

    private func restoringPendingSelection(
        in plan: ResourceTableUpdatePlan,
        chunkIsComplete: Bool
    ) -> ResourceTableUpdatePlan {
        guard let pendingSelectionUIDs else { return plan }
        model.restoreSelection(uids: pendingSelectionUIDs)
        if chunkIsComplete { self.pendingSelectionUIDs = nil }
        return ResourceTableUpdatePlan(
            selectedRowIndexes: model.orderedVisibleUIDs.enumerated().compactMap {
                model.selectedUIDs.contains($0.element) ? $0.offset : nil
            },
            scrollRestoration: plan.scrollRestoration,
            contentUpdate: plan.contentUpdate
        )
    }

    private func captureUpdate() -> ResourceTableUpdateCapture {
        ResourceTableAppKitProjection.capture(model: model, from: tableView)
    }

    private func applyTablePlan(_ plan: ResourceTableUpdatePlan) {
        let interval = tableSignposter.beginInterval(
            PerformanceSignpostCatalog.resourceTableReload,
            "visible_rows=\(self.model.orderedVisibleUIDs.count) selected_rows=\(plan.selectedRowIndexes.count) restores_scroll=\(plan.scrollRestoration != nil)"
        )
        let wasSuppressingSelectionCallbacks = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        ResourceTableAppKitProjection.apply(
            plan,
            visibleRowCount: model.orderedVisibleUIDs.count,
            to: tableView,
            updateVisibleCell: { [self] view, column, row in
                configureResourceTableCell(
                    in: tableView,
                    tableColumn: column,
                    row: row,
                    reusing: view
                ) === view
            }
        )
        suppressSelectionCallbacks = wasSuppressingSelectionCallbacks
        tableSignposter.endInterval(
            PerformanceSignpostCatalog.resourceTableReload,
            interval
        )
    }

    private func clearTransientCellPresentation(
        keepingRequestedFilterHighlight: Bool = false
    ) {
        let removedAddresses = cellHighlightStore.removeAll()
        let removedFilterEmphasis = activeFilterHighlight != nil
        isChangeDetectionArmed = false
        activeFilterHighlight = nil
        if !keepingRequestedFilterHighlight {
            requestedFilterHighlight = nil
        }
        cancelCellHighlightRefresh()
        reloadVisibleCellPresentation(
            at: removedAddresses,
            reloadAllVisibleCells: removedFilterEmphasis
        )
    }

    private func activateRequestedFilterHighlight() {
        guard activeFilterHighlight != requestedFilterHighlight else { return }
        activeFilterHighlight = requestedFilterHighlight
        reloadVisibleCellPresentation(at: [], reloadAllVisibleCells: true)
    }

    /// Updates only existing reusable cells intersecting the current viewport.
    /// Highlight-only frames repaint the cell background directly; filter
    /// emphasis reconfigures the same view. Neither path replaces the native
    /// view or detaches an active tooltip.
    private func reloadVisibleCellPresentation(
        at addresses: Set<ResourceCellAddress>,
        reloadAllVisibleCells: Bool = false
    ) {
        guard isViewLoaded, !tableView.tableColumns.isEmpty else { return }
        let visibleRows = visibleTableRowIndexes()
        guard !visibleRows.isEmpty else { return }
        guard reloadAllVisibleCells || !addresses.isEmpty else { return }
        let now = ContinuousClock.now
        for columnIndex in tableView.tableColumns.indices {
            let column = tableView.tableColumns[columnIndex]
            let columnID = tableView.tableColumns[columnIndex].identifier.rawValue
            for rowIndex in visibleRows {
                let uid = model.orderedVisibleUIDs[rowIndex]
                let address = ResourceCellAddress(
                    uid: uid,
                    columnID: columnID
                )
                guard reloadAllVisibleCells || addresses.contains(address),
                    let view = tableView.view(
                        atColumn: columnIndex,
                        row: rowIndex,
                        makeIfNecessary: false
                    )
                else { continue }
                if reloadAllVisibleCells {
                    _ = configureResourceTableCell(
                        in: tableView,
                        tableColumn: column,
                        row: rowIndex,
                        reusing: view
                    )
                } else if let cell = view as? HighlightableResourceTableCellView {
                    cell.setChangeHighlight(cellHighlightStore.presentation(
                        for: address,
                        at: now
                    ))
                }
            }
        }
    }

    private func visibleTableRowIndexes() -> IndexSet {
        guard isViewLoaded else { return [] }
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else {
            return []
        }
        let lowerBound = max(0, visibleRange.location)
        let upperBound = min(
            model.orderedVisibleUIDs.count,
            visibleRange.location + visibleRange.length
        )
        guard lowerBound < upperBound else { return [] }
        return IndexSet(integersIn: lowerBound..<upperBound)
    }

    private func visibleResourceUIDsInViewport() -> Set<ResourceUID> {
        Set(visibleTableRowIndexes().map { model.orderedVisibleUIDs[$0] })
    }

    private func scheduleCellHighlightRefresh() {
        cancelCellHighlightRefresh()
        let now = ContinuousClock.now
        let delay = cellEffectsPolicy.usesContinuousFade
            ? cellHighlightStore.nextRefreshDelay(at: now)
            : cellHighlightStore.nextExpiryDelay(at: now)
        guard let delay else { return }

        let revision = cellHighlightRefreshRevision
        cellHighlightRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                cellHighlightRefreshRevision == revision,
                !Task.isCancelled
            else { return }
            cellHighlightRefreshTask = nil
            let now = ContinuousClock.now
            let affectedAddresses = cellHighlightStore.addresses
            cellHighlightStore.expire(at: now)
            reloadVisibleCellPresentation(at: affectedAddresses)
            scheduleCellHighlightRefresh()
        }
    }

    private func cancelCellHighlightRefresh() {
        cellHighlightRefreshRevision &+= 1
        cellHighlightRefreshTask?.cancel()
        cellHighlightRefreshTask = nil
    }

    private func beginProjectionRequest() {
        guard tableSignposter.isEnabled else { return }
        projectionRequestGeneration = generation
        projectionRequestInterval = tableSignposter.beginInterval(
            PerformanceSignpostCatalog.resourceProjectionRequest,
            "generation=\(self.generation) filter_revision=\(self.filterRevision) sort_count=\(self.tableView.sortDescriptors.count) column_count=\(self.columnIDs.count)"
        )
    }

    private func endProjectionRequest(outcome: String) {
        guard let interval = projectionRequestInterval else { return }
        tableSignposter.endInterval(
            PerformanceSignpostCatalog.resourceProjectionRequest,
            interval,
            "generation=\(self.projectionRequestGeneration ?? 0) outcome=\(outcome, privacy: .public) visible_rows=\(self.model.orderedVisibleUIDs.count)"
        )
        projectionRequestInterval = nil
        projectionRequestGeneration = nil
    }

    private func show(error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        showInlineIssue(
            presentation.inlineText,
            toolTip: presentation.detailedText
        )
        if let issue = error as? ClusterManagerIssue,
            issue.category == .validation
        {
            let localState = filterField.stringValue.isEmpty
                ? "View configuration error" : "Invalid filter"
            if hasLastUsableResourceViewStatus {
                // The prior projection was cancelled before this replacement
                // was rejected. Its rows remain useful, but they are no longer
                // being watched and must not retain a "Watching" claim.
                installFreshnessText("\(localState) · last good rows")
            } else {
                installFreshnessText(localState)
            }
            return
        }
        installFreshnessText("Disconnected")
    }

    private func installResourceViewStatus(
        _ status: ResourceViewStatus,
        now: Date = Date()
    ) {
        resourceViewStatus = status
        if status.freshness != .loading {
            hasLastUsableResourceViewStatus = true
        }
        freshnessLabel.stringValue = status.presentation(now: now)
        freshnessLabel.setAccessibilityValue(freshnessLabel.stringValue)
        if status.showsProgress {
            freshnessProgressIndicator.isHidden = false
            freshnessProgressIndicator.startAnimation(nil)
        } else {
            freshnessProgressIndicator.stopAnimation(nil)
            freshnessProgressIndicator.isHidden = true
        }
        restartFreshnessAgeUpdatesIfNeeded()
        updateStatusLine()
    }

    private func installFreshnessText(_ text: String) {
        resourceViewStatus = nil
        stopFreshnessAgeUpdates()
        freshnessProgressIndicator.stopAnimation(nil)
        freshnessProgressIndicator.isHidden = true
        freshnessLabel.stringValue = text
        freshnessLabel.setAccessibilityValue(text)
        updateStatusLine()
    }

    private func restartFreshnessAgeUpdatesIfNeeded() {
        stopFreshnessAgeUpdates()
        guard resourceViewStatus?.needsAgeRefresh == true else { return }
        freshnessAgeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let status = self?.resourceViewStatus,
                    let delay = status.nextAgeRefreshDelay()
                else { return }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                    let status = self.resourceViewStatus,
                    status.needsAgeRefresh
                else { return }
                self.freshnessLabel.stringValue = status.presentation
                self.freshnessLabel.setAccessibilityValue(self.freshnessLabel.stringValue)
                self.updateStatusLine()
            }
        }
    }

    private func stopFreshnessAgeUpdates() {
        freshnessAgeTask?.cancel()
        freshnessAgeTask = nil
    }

    private func showInlineIssue(
        _ message: String,
        color: NSColor = .systemRed,
        toolTip: String? = nil
    ) {
        inlineIssueState.show(message)
        inlineIssueToolTip = toolTip
        errorLabel.textColor = color
        applyInlineIssueState()
    }

    private func hideInlineIssue() {
        inlineIssueState.hide()
        inlineIssueToolTip = nil
        applyInlineIssueState()
    }

    private func applyInlineIssueState() {
        errorLabel.stringValue = inlineIssueState.message ?? ""
        errorLabel.toolTip = inlineIssueState.isHidden ? nil : inlineIssueToolTip
        errorLabel.isHidden = inlineIssueState.isHidden
        switch inlineIssueState.tableTopAnchor {
        case .header:
            tableTopWithErrorConstraint?.isActive = false
            tableTopWithoutErrorConstraint?.isActive = true
        case .issueRow:
            tableTopWithoutErrorConstraint?.isActive = false
            tableTopWithErrorConstraint?.isActive = true
        }
    }

    /// Gives each stream generation distinct completion authority. The
    /// catalog-driven column reproject may inherit only the completed automatic
    /// scan bit and bounded pending-hint mailbox. This avoids a redundant query
    /// without losing a hint that raced the response which caused the reopen.
    /// Changing session or GVR still clears the overlay and pending hints.
    private func prepareOptionalResourceDiscovery(
        for resource: DiscoveredResource,
        preservingOptionalResourceDiscoveryState: Bool
    ) {
        let overlayScopeChanged = optionalResourceOverlayState.clearIfScopeChanged(
            sessionID: session.sessionID,
            gvr: resourceGVR(for: resource)
        )
        if !preservingOptionalResourceDiscoveryState || overlayScopeChanged {
            pendingOptionalResourceKeys.removeAll(keepingCapacity: true)
            pendingOptionalResourceRefreshRequired = false
            optionalResourceHintRevision = 0
        }
        if overlayScopeChanged {
            installEffectiveColumns(for: resource)
        }
        cancelOptionalResourceDiscovery(
            selecting: OptionalResourceCatalogDiscoveryTarget(
                sessionID: session.sessionID,
                applicableResource: resource,
                viewGeneration: generation
            ),
            preservingOptionalResourceDiscoveryState:
                preservingOptionalResourceDiscoveryState
        )
    }

    private func cancelOptionalResourceDiscovery(
        selecting target: OptionalResourceCatalogDiscoveryTarget?,
        preservingOptionalResourceDiscoveryState: Bool = false
    ) {
        optionalResourceCatalogTask?.cancel()
        optionalResourceCatalogTask = nil
        optionalResourceCatalogTaskTicket = nil
        optionalResourceCatalogTaskRefreshKeys.removeAll(keepingCapacity: true)
        optionalResourceCatalogTaskHintRevision = 0
        optionalResourceDiscoveryGate.select(
            target,
            preservingAutomaticDiscoveryCompletion:
                preservingOptionalResourceDiscoveryState
        )
    }

    private func clearOptionalResourceOverlay() {
        optionalResourceOverlayState.clear()
        pendingOptionalResourceKeys.removeAll(keepingCapacity: true)
        pendingOptionalResourceRefreshRequired = false
        optionalResourceHintRevision = 0
    }

    private func markBaseViewUsableForOptionalResourceDiscovery() {
        optionalResourceDiscoveryGate.markBaseViewUsable()
        beginOptionalResourceDiscoveryIfAuthorized()
    }

    private func beginOptionalResourceDiscoveryIfAuthorized() {
        let refreshKeys = pendingOptionalResourceKeys
        let refreshRequired = pendingOptionalResourceRefreshRequired
        guard optionalResourceCatalogTask == nil,
            let ticket = optionalResourceDiscoveryGate.beginDiscovery(
                refresh: !refreshKeys.isEmpty || refreshRequired
            )
        else { return }
        let provider = optionalResourceCatalogProvider
        optionalResourceCatalogTaskTicket = ticket
        optionalResourceCatalogTaskRefreshKeys = refreshKeys
        optionalResourceCatalogTaskHintRevision = optionalResourceHintRevision
        optionalResourceCatalogTask = Task { [weak self, provider] in
            do {
                let catalog = try await provider.discoverOptionalResources(ticket.request)
                guard !Task.isCancelled else {
                    self?.finishOptionalResourceDiscoveryWithoutResult(ticket)
                    return
                }
                self?.finishOptionalResourceDiscovery(ticket, catalog: catalog)
            } catch {
                self?.finishOptionalResourceDiscoveryWithoutResult(ticket)
            }
        }
    }

    private func finishOptionalResourceDiscoveryWithoutResult(
        _ ticket: OptionalResourceCatalogDiscoveryTicket
    ) {
        let attemptedHintRevision = optionalResourceCatalogTaskTicket == ticket
            ? optionalResourceCatalogTaskHintRevision : optionalResourceHintRevision
        let resultIsCurrent = optionalResourceDiscoveryGate.finishWithoutResult(ticket)
        releaseOptionalResourceCatalogTask(ticket)
        if resultIsCurrent, optionalResourceHintRevision != attemptedHintRevision {
            beginOptionalResourceDiscoveryIfAuthorized()
        }
        // Catalog failures are deliberately silent and never alter the base
        // resource stream's freshness or inline error presentation.
    }

    private func releaseOptionalResourceCatalogTask(
        _ ticket: OptionalResourceCatalogDiscoveryTicket
    ) {
        guard optionalResourceCatalogTaskTicket == ticket else { return }
        optionalResourceCatalogTask = nil
        optionalResourceCatalogTaskTicket = nil
        optionalResourceCatalogTaskRefreshKeys.removeAll(keepingCapacity: true)
        optionalResourceCatalogTaskHintRevision = 0
    }

    private func finishOptionalResourceDiscovery(
        _ ticket: OptionalResourceCatalogDiscoveryTicket,
        catalog: OptionalResourceCatalog
    ) {
        let attemptedRefreshKeys = optionalResourceCatalogTaskTicket == ticket
            ? optionalResourceCatalogTaskRefreshKeys : []
        let attemptedHintRevision = optionalResourceCatalogTaskTicket == ticket
            ? optionalResourceCatalogTaskHintRevision : optionalResourceHintRevision
        let resultIsCurrent = optionalResourceDiscoveryGate.finishSuccess(ticket)
        releaseOptionalResourceCatalogTask(ticket)
        guard resultIsCurrent,
            let resource,
            ticket.targetKey == OptionalResourceCatalogDiscoveryTarget(
                sessionID: session.sessionID,
                applicableResource: resource,
                viewGeneration: generation
            ).key
        else {
            return
        }

        pendingOptionalResourceKeys.subtract(
            catalog.resources.lazy.filter(\.isPresent).map(\.exactKey)
        )
        // A successful catalog request consumed the hints visible when it
        // began. Hints arriving during that request remain pending and cause
        // exactly one follow-up refresh if the response did not include them.
        pendingOptionalResourceKeys.subtract(attemptedRefreshKeys)
        pendingOptionalResourceRefreshRequired =
            optionalResourceHintRevision != attemptedHintRevision

        let persisted = persistedColumnDefinitions(for: resource)
        let previousEnabled = enabledColumnDefinitions(in: effectiveColumnDefinitions(
            persistedDefinitions: persisted,
            resource: resource
        ))
        do {
            var reconciled = OptionalResourceColumnOverlay()
            try reconciled.reconcile(
                catalog,
                applicableResource: resource,
                persistedDefinitions: persisted
            )
            optionalResourceOverlayState.install(
                reconciled,
                sessionID: session.sessionID,
                gvr: resourceGVR(for: resource)
            )
        } catch {
            return
        }
        let effective = effectiveColumnDefinitions(
            persistedDefinitions: persisted,
            resource: resource
        )
        let enabled = enabledColumnDefinitions(in: effective)
        installColumns(effective)
        if enabled != previousEnabled {
            openStream(preservingOptionalResourceDiscoveryState: true)
            updateStatusLine()
            onRestorationChanged?()
        } else {
            beginOptionalResourceDiscoveryIfAuthorized()
        }
    }

    /// Stream hints carry only exact non-sensitive resource names observed in
    /// raw Pod/Node objects. They never install columns directly: the
    /// authenticated cache-only catalog must confirm presence and presentation
    /// metadata first. Keeping hints pending closes the cold-empty race where
    /// the one automatic query finishes just before the first live object.
    private func observeOptionalResourceKeys(
        _ observed: Set<String>,
        truncated: Bool
    ) {
        guard !observed.isEmpty || truncated else { return }
        let presentCatalogKeys = Set(
            (optionalResourceOverlayState.overlay.catalog?.resources ?? []).lazy
                .filter(\.isPresent)
                .map(\.exactKey)
        )
        var refreshRequired = truncated
        var observedUnconfirmedKey = false
        for key in observed.sorted() where key != "ephemeral-storage"
            && !presentCatalogKeys.contains(key)
        {
            observedUnconfirmedKey = true
            guard !pendingOptionalResourceKeys.contains(key) else { continue }
            if pendingOptionalResourceKeys.count < Self.maxPendingOptionalResourceKeys {
                pendingOptionalResourceKeys.insert(key)
            } else {
                refreshRequired = true
            }
        }
        guard observedUnconfirmedKey || refreshRequired else { return }
        optionalResourceHintRevision &+= 1
        pendingOptionalResourceRefreshRequired =
            pendingOptionalResourceRefreshRequired || refreshRequired
        guard !pendingOptionalResourceKeys.isEmpty
            || pendingOptionalResourceRefreshRequired
        else { return }
        beginOptionalResourceDiscoveryIfAuthorized()
    }

    private func updateStatusLine() {
        countLabel.stringValue = "\(model.orderedVisibleUIDs.count.formatted()) objects"
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            let title = tableView.tableColumns.first(where: { $0.identifier.rawValue == key })?.title
                ?? key
            sortLabel.stringValue = "Sorted by \(title) \(descriptor.ascending ? "↑" : "↓")"
        } else {
            sortLabel.stringValue = "Unsorted"
        }
        let counts = model.selectionCounts
        let selection = counts.hidden > 0
            ? "\(counts.selected) selected (\(counts.hidden) hidden by filter)"
            : "\(counts.selected) selected"
        statusLine.stringValue = "\(model.orderedVisibleUIDs.count.formatted()) objects · \(selection) · \(freshnessLabel.stringValue)"
        statusLine.toolTip = statusLine.stringValue
    }

    private func setFilterShortcutContextActive(_ active: Bool) {
        guard isFilterShortcutContextActive != active else { return }
        isFilterShortcutContextActive = active
        publishContextualShortcutsIfChanged()
    }

    private func publishContextualShortcutsIfChanged() {
        let snapshot = contextualShortcutSnapshot
        guard snapshot != lastPublishedShortcutSnapshot else { return }
        lastPublishedShortcutSnapshot = snapshot
        onContextualShortcutsChanged?()
    }

    private func configureColumns(for resource: DiscoveredResource) {
        if let existing = columnDefinitionsByResourceID[resource.id],
            !provisionalDefaultColumnResourceIDs.contains(resource.id)
        {
            installColumns(effectiveColumnDefinitions(
                persistedDefinitions: existing,
                resource: resource
            ))
            return
        }
        let defaults = defaultColumnDefinitions(for: resource)
        let match = ColumnResourceMatch(
            group: resource.group,
            version: resource.version,
            resource: resource.resource
        )
        if let document = columnsConfigurationCache.document {
            let definitions = document.views.first(where: { $0.match == match })?.columns
                ?? defaults
            provisionalDefaultColumnResourceIDs.remove(resource.id)
            columnDefinitionsByResourceID[resource.id] = definitions
            installColumns(effectiveColumnDefinitions(
                persistedDefinitions: definitions,
                resource: resource
            ))
            return
        }
        let definitions = columnDefinitionsByResourceID[resource.id] ?? defaults
        columnDefinitionsByResourceID[resource.id] = definitions
        provisionalDefaultColumnResourceIDs.insert(resource.id)
        installColumns(effectiveColumnDefinitions(
            persistedDefinitions: definitions,
            resource: resource
        ))
        if deferredColumnPresentationByResourceID[resource.id] == nil {
            deferredColumnPresentationByResourceID[resource.id] =
                DeferredColumnPresentationState(
                    columns: [],
                    sort: currentSortPresentation
                )
        }
        beginColumnsConfigurationLoadIfNeeded()
    }

    private func beginColumnsConfigurationLoadIfNeeded() {
        guard columnsConfigurationCache.document == nil,
            columnsConfigurationLoadTask == nil
        else { return }
        let loader = columnsConfigurationLoader
        let configurationPath = columnsConfigurationPath
        columnsConfigurationLoadGeneration &+= 1
        let loadGeneration = columnsConfigurationLoadGeneration
        columnsConfigurationLoadTask = Task { [weak self] in
            let loaded: ColumnsConfigurationDocument
            do {
                loaded = try await loader.load(configurationPath)
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                // Invalid external configuration already has a dedicated
                // Settings/Columns error surface. Resource navigation remains
                // usable with its typed defaults, and a later navigation may
                // retry after the external file has been repaired.
                guard let self,
                    columnsConfigurationLoadGeneration == loadGeneration
                else { return }
                columnsConfigurationLoadTask = nil
                return
            }
            guard let self,
                columnsConfigurationLoadGeneration == loadGeneration
            else { return }
            let reconciled = columnsConfigurationCache.installLoaded(loaded)
            columnsConfigurationLoadTask = nil
            let deferredPresentation = resource.flatMap {
                deferredColumnPresentationByResourceID[$0.id]
            }
            // Once the complete document is available, navigation history is
            // the source of truth for resources that are no longer visible.
            deferredColumnPresentationByResourceID.removeAll(keepingCapacity: true)
            guard let resource,
                provisionalDefaultColumnResourceIDs.contains(resource.id)
            else { return }
            let match = ColumnResourceMatch(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            )
            let definitions = reconciled.views.first(where: { $0.match == match })?.columns
                ?? defaultColumnDefinitions(for: resource)
            let previous = installedColumnDefinitions
            let previousSort = currentSortPresentation
            provisionalDefaultColumnResourceIDs.remove(resource.id)
            columnDefinitionsByResourceID[resource.id] = definitions
            installEffectiveColumns(for: resource)
            if let deferredPresentation {
                applyDeferredColumnPresentation(deferredPresentation)
            }
            if installedColumnDefinitions != previous
                || currentSortPresentation != previousSort
            {
                openStream()
            }
            updateStatusLine()
            onRestorationChanged?()
        }
    }

    private func applyColumns(_ definitions: [ColumnDefinition], forResourceID resourceID: String) {
        guard let resource, resource.id == resourceID else { return }
        provisionalDefaultColumnResourceIDs.remove(resourceID)
        let nextEffective = effectiveColumnDefinitions(
            persistedDefinitions: definitions,
            resource: resource
        )
        columnDefinitionsByResourceID[resourceID] = definitions
        let previousEffective = installedColumnDefinitions
        let previousSort = currentSortPresentation
        let deferredPresentation = deferredColumnPresentationByResourceID
            .removeValue(forKey: resourceID)
        // Opening Columns publishes its freshly loaded draft even when it is
        // byte-for-byte equivalent to the active layout. Rebuilding AppKit
        // columns in that case destroys the user's per-window widths and drag
        // order. Only rebuild when an enabled definition actually changed;
        // explicit manager reorders and width edits still differ here.
        if enabledColumnDefinitions(in: nextEffective) != previousEffective {
            installColumns(nextEffective, preservingCurrentPresentation: true)
        }
        if let deferredPresentation {
            applyDeferredColumnPresentation(deferredPresentation)
        }
        if installedColumnDefinitions != previousEffective
            || currentSortPresentation != previousSort
        {
            openStream()
        }
        updateStatusLine()
        onRestorationChanged?()
    }

    @discardableResult
    func applySavedColumns(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch
    ) -> Bool {
        columnsConfigurationLoadGeneration &+= 1
        columnsConfigurationLoadTask?.cancel()
        columnsConfigurationLoadTask = nil
        columnsConfigurationCache.recordSaved(definitions, matching: match)
        if let currentID = resource?.id {
            let currentDefinitions = columnDefinitionsByResourceID[currentID]
            columnDefinitionsByResourceID.removeAll(keepingCapacity: true)
            if let currentDefinitions {
                columnDefinitionsByResourceID[currentID] = currentDefinitions
            }
            provisionalDefaultColumnResourceIDs = [currentID]
        } else {
            columnDefinitionsByResourceID.removeAll(keepingCapacity: true)
            provisionalDefaultColumnResourceIDs.removeAll(keepingCapacity: true)
        }
        defer { beginColumnsConfigurationLoadIfNeeded() }
        guard let resource,
            match == ColumnResourceMatch(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            )
        else { return false }
        applyColumns(definitions, forResourceID: resource.id)
        return true
    }

    private func installColumns(
        _ definitions: [ColumnDefinition],
        preservingCurrentPresentation: Bool = false
    ) {
        let enabled = definitions.filter(\.isEnabled)
        // Removing an NSTableColumn makes AppKit immediately remove every
        // descriptor that references it. Capture the user's backend sort
        // before rebuilding presentation columns, then restore only IDs that
        // still exist. Pods and Nodes rebuild here after optional-resource
        // discovery; losing this state made those headers appear to undo a
        // click while resource kinds without exact-resource columns worked.
        let retainedSort = currentSortPresentation
        let retainedPresentation = currentColumnPresentation
        let retainedPresentationByID = Dictionary(uniqueKeysWithValues:
            retainedPresentation.map { ($0.columnID, $0) }
        )
        let previousDefinitionsByID = columnDefinitionsByID
        let definitionOrderUnchanged = columnIDs == enabled.map(\.id)
        if installedColumnDefinitions != enabled {
            clearTransientCellPresentation()
        }
        rowChangeDetector = ResourceRowChangeDetector(
            columnDefinitions: definitions
        )
        let selectedRowIndexes = model.orderedVisibleUIDs.enumerated().compactMap {
            model.selectedUIDs.contains($0.element) ? $0.offset : nil
        }
        columnDefinitionsByID.removeAll(keepingCapacity: true)
        for definition in definitions {
            columnDefinitionsByID[definition.id] = definition
        }
        columnIDs = enabled.map(\.id)

        suppressSortChanges = true
        let wasSuppressingSelectionCallbacks = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        defer {
            suppressSortChanges = false
            suppressSelectionCallbacks = wasSuppressingSelectionCallbacks
        }
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        for definition in enabled {
            let column = NSTableColumn(identifier: .init(definition.id))
            column.title = definition.title
            let configuredWidth = definition.width.map { CGFloat($0) }
                ?? NativeColumnCatalog.descriptor(
                    source: definition.source,
                    value: definition.value ?? definition.id
                ).map { CGFloat($0.width) }
                ?? 120
            if preservingCurrentPresentation,
                previousDefinitionsByID[definition.id]?.width == definition.width,
                let retained = retainedPresentationByID[definition.id]
            {
                column.width = CGFloat(retained.width)
                column.isHidden = !retained.isVisible
            } else {
                column.width = configuredWidth
            }
            column.minWidth = 55
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.id, ascending: true)
            tableView.addTableColumn(column)
        }
        if preservingCurrentPresentation, definitionOrderUnchanged {
            applyColumnOrder(retainedPresentation.map(\.columnID))
        }
        applySortPresentation(retainedSort)
        tableView.reloadData()
        tableView.selectRowIndexes(
            IndexSet(selectedRowIndexes),
            byExtendingSelection: false
        )
    }

    private var installedColumnDefinitions: [ColumnDefinition] {
        columnIDs.compactMap { columnDefinitionsByID[$0] }
    }

    private func persistedColumnDefinitions(for resource: DiscoveredResource) -> [ColumnDefinition] {
        columnDefinitionsByResourceID[resource.id] ?? defaultColumnDefinitions(for: resource)
    }

    private func effectiveColumnDefinitions(
        persistedDefinitions: [ColumnDefinition],
        resource: DiscoveredResource
    ) -> [ColumnDefinition] {
        optionalResourceOverlayState.applying(
            to: persistedDefinitions,
            sessionID: session.sessionID,
            gvr: resourceGVR(for: resource)
        )
    }

    private func enabledColumnDefinitions(
        in definitions: [ColumnDefinition]
    ) -> [ColumnDefinition] {
        definitions.filter(\.isEnabled)
    }

    private func installEffectiveColumns(for resource: DiscoveredResource) {
        installColumns(effectiveColumnDefinitions(
            persistedDefinitions: persistedColumnDefinitions(for: resource),
            resource: resource
        ))
    }

    private func defaultColumnDefinitions(for resource: DiscoveredResource) -> [ColumnDefinition] {
        NativeColumnCatalog.defaultDefinitions(
            group: resource.group,
            version: resource.version,
            resource: resource.resource,
            namespaced: resource.namespaced
        )
    }

    private func navigationState() -> ResourceNavigationState? {
        guard let resource else { return nil }
        let deferredPresentation = deferredColumnPresentationByResourceID[resource.id]
        let columns = deferredPresentation?.columns ?? currentColumnPresentation
        let sort = deferredPresentation?.sort ?? currentSortPresentation
        return ResourceNavigationState(
            group: resource.group, version: resource.version, resource: resource.resource,
            kind: resource.kind, namespaced: resource.namespaced, namespaceSelection: scope,
            filter: filterField.stringValue,
            sortColumnID: sort.first?.columnID,
            sortDescending: !(sort.first?.ascending ?? true),
            columns: columns,
            columnMoveOverrides: deferredPresentation.flatMap {
                $0.columnMoves.isEmpty ? nil : $0.columnMoves
            },
            columnMeasurementOverrides: deferredPresentation.flatMap {
                $0.measurementOverrides.isEmpty ? nil : $0.measurementOverrides
            },
            selectedUIDs: model.selectedUIDs,
            scrollAnchor: captureUpdate().scrollAnchor
        )
    }

    func restorationState(
        contextName: String,
        contextReference: String,
        isSidebarVisible: Bool
    ) -> ClusterWindowRestorationState {
        let state = navigationState()
        let deferredPresentation = resource.flatMap {
            deferredColumnPresentationByResourceID[$0.id]
        }
        let columns = deferredPresentation?.columns ?? currentColumnPresentation
        let sorts = deferredPresentation?.sort ?? currentSortPresentation
        return ClusterWindowRestorationState(
            contextName: contextName,
            contextReference: contextReference,
            gvr: state.map { GVR(group: $0.group, version: $0.version, resource: $0.resource) },
            namespaceScope: NamespaceScope(scope),
            filter: filterField.stringValue,
            sort: sorts,
            columns: columns,
            columnMoveOverrides: deferredPresentation.flatMap {
                $0.columnMoves.isEmpty ? nil : $0.columnMoves
            },
            columnMeasurementOverrides: deferredPresentation.flatMap {
                $0.measurementOverrides.isEmpty ? nil : $0.measurementOverrides
            },
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
        filterCompletionTrigger.reset()
        filterField.stringValue = restoration.filter
        filterMemory.remember(restoration.filter, for: resourceGVR(for: restored))
        suppressPresentationCheckpoint = true
        defer { suppressPresentationCheckpoint = false }
        let deferredPresentation = DeferredColumnPresentationState(
            columns: restoration.columns,
            sort: restoration.sort,
            columnMoves: restoration.columnMoveOverrides ?? [],
            measurementOverrides: restoration.columnMeasurementOverrides ?? []
        )
        deferColumnPresentationIfNeeded(for: restored, presentation: deferredPresentation)
        configureColumns(for: restored)
        applyDeferredColumnPresentation(deferredPresentation)
        let nav = ResourceNavigationState(
            group: restored.group, version: restored.version, resource: restored.resource,
            kind: restored.kind, namespaced: restored.namespaced,
            namespaceSelection: scope, filter: restoration.filter,
            sortColumnID: restoration.sort.first?.columnID,
            sortDescending: !(restoration.sort.first?.ascending ?? true),
            columns: restoration.columns,
            columnMoveOverrides: restoration.columnMoveOverrides,
            columnMeasurementOverrides: restoration.columnMeasurementOverrides,
            scrollAnchor: restoration.scrollAnchor
        )
        history = WorkspaceNavigationHistory(initial: .resource(nav))
        openStream()
        return true
    }

    /// Completes the one-time trust transition from a presentation-only saved
    /// target to the authenticated discovery catalog. If the exact saved GVR
    /// is absent, discard the synthetic resource before authorizing ordinary
    /// resource selection so no later UI event can stream it.
    @discardableResult
    func validateRestoredResource(
        _ restoration: ClusterWindowRestorationState,
        discoveredResources: [DiscoveredResource]
    ) -> Bool {
        guard isAuthenticated else { return false }
        resourceCatalogValidated = true
        if applyRestoration(restoration, discoveredResources: discoveredResources) {
            return true
        }

        resource = nil
        history = WorkspaceNavigationHistory()
        pendingScrollAnchor = nil
        pendingSelectionUIDs = nil
        clearTransientCellPresentation()
        model = ResourceTableModel()
        tableView.reloadData()
        titleLabel.stringValue = "Resources"
        installFreshnessText("Ready")
        if restoration.gvr != nil, discoveredResources.isEmpty {
            showInlineIssue(
                "The saved resource target is not present in authenticated discovery.",
                color: .systemOrange
            )
        }
        updateStatusLine()
        return false
    }

    func rejectRestoredResourceValidation(_ error: Error) {
        resourceCatalogValidated = false
        resource = nil
        history = WorkspaceNavigationHistory()
        pendingScrollAnchor = nil
        pendingSelectionUIDs = nil
        let presentation = UserFacingErrorPresentation(error)
        showDisconnected(
            "Authenticated discovery failed before the saved resource target could be validated. "
                + presentation.inlineText,
            toolTip: presentation.detailedText
        )
        titleLabel.stringValue = "Resources"
    }

    /// Installs only the allow-listed presentation state from a saved window.
    /// `openStream()` is authentication-gated, so this cannot use the shell's
    /// synthetic session ID for discovery or resource requests.
    func applyRestoredShell(_ restoration: ClusterWindowRestorationState) {
        isAuthenticated = false
        scope = restoration.namespaceScope.namespaceSelection
        filterCompletionTrigger.reset()
        filterField.stringValue = restoration.filter

        let shell = RestoredWorkspaceShell(record: ClusterWindowRestorationRecord(
            id: "shell",
            state: restoration
        ))
        if let resource = shell.targetResource {
            _ = applyRestoration(restoration, discoveredResources: [resource])
            titleLabel.stringValue = resource.kind.isEmpty ? resource.resource : resource.kind
            scopeLabel.stringValue = scope.presentation
        }
        showDisconnected("Opening saved Kubernetes context…")
    }

    func restoreResource(_ state: ResourceNavigationState) {
        rememberCurrentFilter()
        resource = DiscoveredResource(
            group: state.group, version: state.version, resource: state.resource,
            kind: state.kind, namespaced: state.namespaced,
            verbs: ["list", "watch"]
        )
        scope = state.namespaceSelection
        pendingScrollAnchor = state.scrollAnchor
        pendingSelectionUIDs = state.selectedUIDs
        installFilterForNavigation(
            state.filter,
            resourceGVR: GVR(group: state.group, version: state.version, resource: state.resource)
        )
        suppressPresentationCheckpoint = true
        let restoredSort = state.sortColumnID.map {
            [SortDescriptorState(columnID: $0, ascending: !state.sortDescending)]
        } ?? []
        let deferredPresentation = DeferredColumnPresentationState(
            columns: state.columns,
            sort: restoredSort,
            columnMoves: state.columnMoveOverrides ?? [],
            measurementOverrides: state.columnMeasurementOverrides ?? []
        )
        deferColumnPresentationIfNeeded(for: resource!, presentation: deferredPresentation)
        configureColumns(for: resource!)
        applyDeferredColumnPresentation(deferredPresentation)
        suppressPresentationCheckpoint = false
        openStream()
    }

    private func installFilterForNavigation(_ filter: String, resourceGVR: GVR) {
        filterCompletionTrigger.reset()
        filterTask?.cancel()
        filterTask = nil
        if filterField.stringValue != filter {
            filterRevision &+= 1
        }
        filterField.stringValue = filter
        filterMemory.remember(filter, for: resourceGVR)
    }

    private func rememberCurrentFilter() {
        guard let resource else { return }
        filterMemory.remember(filterField.stringValue, for: resourceGVR(for: resource))
    }

    private func resourceGVR(for resource: DiscoveredResource) -> GVR {
        GVR(group: resource.group, version: resource.version, resource: resource.resource)
    }

    private func applyColumnPresentation(_ states: [ColumnPresentationState]) {
        guard !states.isEmpty else { return }
        applyColumnMeasurements(states)
        applyColumnOrder(states.map(\.columnID))
    }

    private func applyColumnMeasurements(_ states: [ColumnPresentationState]) {
        let byID = Dictionary(uniqueKeysWithValues: states.map { ($0.columnID, $0) })
        for column in tableView.tableColumns {
            if let state = byID[column.identifier.rawValue] {
                column.width = CGFloat(state.width)
                column.isHidden = !state.isVisible
            }
        }
    }

    private func applyColumnOrder(_ columnIDs: [String]) {
        let availableIDs = Set(tableView.tableColumns.map { $0.identifier.rawValue })
        let availableOrder = columnIDs.filter(availableIDs.contains)
        for (targetIndex, columnID) in availableOrder.enumerated() {
            guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == columnID
            }), currentIndex != targetIndex else { continue }
            tableView.moveColumn(currentIndex, toColumn: targetIndex)
        }
    }

    private func applyColumnMoves(_ moves: [ColumnMoveState]) {
        guard tableView.numberOfColumns > 0 else { return }
        for move in moves {
            guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == move.columnID
            }) else { continue }
            let targetIndex = min(max(move.targetIndex, 0), tableView.numberOfColumns - 1)
            if currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }
    }

    private func applyDeferredColumnPresentation(
        _ presentation: DeferredColumnPresentationState
    ) {
        applyColumnPresentation(presentation.columns)
        applyColumnMoves(presentation.columnMoves)
        applyColumnMeasurements(presentation.measurementOverrides)
        applySortPresentation(presentation.sort)
    }

    private var currentColumnPresentation: [ColumnPresentationState] {
        tableView.tableColumns.map { column in
            ColumnPresentationState(
                columnID: column.identifier.rawValue,
                width: Double(column.width),
                isVisible: !column.isHidden
            )
        }
    }

    private func sortPresentation(
        _ descriptors: [NSSortDescriptor]
    ) -> [SortDescriptorState] {
        descriptors.compactMap { descriptor in
            guard let columnID = descriptor.key else { return nil }
            return SortDescriptorState(columnID: columnID, ascending: descriptor.ascending)
        }
    }

    private var currentSortPresentation: [SortDescriptorState] {
        sortPresentation(tableView.sortDescriptors)
    }

    private func applySortPresentation(_ states: [SortDescriptorState]) {
        let availableColumnIDs = Set(tableView.tableColumns.map { $0.identifier.rawValue })
        let descriptors = states.compactMap { state -> NSSortDescriptor? in
            guard availableColumnIDs.contains(state.columnID) else { return nil }
            return NSSortDescriptor(key: state.columnID, ascending: state.ascending)
        }
        let wasSuppressingSortChanges = suppressSortChanges
        suppressSortChanges = true
        tableView.sortDescriptors = descriptors
        suppressSortChanges = wasSuppressingSortChanges
    }

    private func deferColumnPresentationIfNeeded(
        for resource: DiscoveredResource,
        presentation: DeferredColumnPresentationState
    ) {
        guard columnsConfigurationCache.document == nil else {
            deferredColumnPresentationByResourceID.removeValue(forKey: resource.id)
            return
        }
        deferredColumnPresentationByResourceID[resource.id] = presentation
    }

    /// Fold measurement changes made while persisted definitions are loading
    /// into the pending restoration without disturbing unavailable columns.
    private func updateDeferredColumnMeasurementsFromCurrentTable(
        _ notification: Notification
    ) {
        guard !suppressPresentationCheckpoint,
            let resource,
            let resizedColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            let resized = currentColumnPresentation.first(where: {
                $0.columnID == resizedColumn.identifier.rawValue
            }),
            var deferred = deferredPresentationForUserChange(resource)
        else { return }
        if let index = deferred.measurementOverrides.firstIndex(where: {
            $0.columnID == resized.columnID
        }) {
            deferred.measurementOverrides[index] = resized
        } else {
            deferred.measurementOverrides.append(resized)
        }
        deferredColumnPresentationByResourceID[resource.id] = deferred
    }

    /// AppKit reports the destination index after a move. Applying that index
    /// to the pending saved order lets a visible column cross columns that are
    /// unavailable until the configuration document finishes loading.
    private func updateDeferredColumnOrderFromMove(_ notification: Notification) {
        guard !suppressPresentationCheckpoint,
            let resource,
            var deferred = deferredPresentationForUserChange(resource),
            let newIndex = (notification.userInfo?["NSNewColumn"] as? NSNumber)?.intValue,
            currentColumnPresentation.indices.contains(newIndex)
        else { return }
        let current = currentColumnPresentation
        let moved = current[newIndex]
        deferred.recordColumnMove(ColumnMoveState(
            columnID: moved.columnID,
            targetIndex: newIndex
        ))
        deferredColumnPresentationByResourceID[resource.id] = deferred
    }

    private func updateDeferredSortFromCurrentTable() {
        guard let resource,
            var deferred = deferredPresentationForUserChange(resource)
        else { return }
        deferred.sort = currentSortPresentation
        deferredColumnPresentationByResourceID[resource.id] = deferred
    }

    private func deferredPresentationForUserChange(
        _ resource: DiscoveredResource
    ) -> DeferredColumnPresentationState? {
        if let existing = deferredColumnPresentationByResourceID[resource.id] {
            return existing
        }
        guard columnsConfigurationCache.document == nil,
            provisionalDefaultColumnResourceIDs.contains(resource.id)
        else { return nil }
        return DeferredColumnPresentationState(
            columns: [],
            sort: currentSortPresentation
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.orderedVisibleUIDs.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        return configureResourceTableCell(
            in: tableView,
            tableColumn: tableColumn,
            row: row
        )
    }

    /// Configures either a newly dequeued cell or an existing visible cell.
    /// Returning nil for an incompatible existing view lets the AppKit seam
    /// fall back to a targeted reload when a column changes renderer type.
    private func configureResourceTableCell(
        in tableView: NSTableView,
        tableColumn: NSTableColumn,
        row: Int,
        reusing existingView: NSView? = nil
    ) -> NSView? {
        guard model.orderedVisibleUIDs.indices.contains(row) else { return nil }
        let columnID = tableColumn.identifier.rawValue
        let uid = model.orderedVisibleUIDs[row]
        let value = model.rowByUID[uid]?[columnID]
        let alignment = columnDefinitionsByID[columnID]?.alignment ?? .leading
        let emphasizedTerm = activeFilterHighlight.flatMap {
            $0.applies(to: columnID) ? $0.term : nil
        }
        let changeHighlight = cellHighlightStore.presentation(
            for: ResourceCellAddress(uid: uid, columnID: columnID),
            at: ContinuousClock.now
        )
        if let value, let presentation = ResourceUsageCellPresentation(cell: value) {
            let identifier = NSUserInterfaceItemIdentifier("usage-cell.\(columnID)")
            let cell: ResourceUsageTableCellView
            if let existingView {
                guard let existingCell = existingView as? ResourceUsageTableCellView
                else { return nil }
                cell = existingCell
            } else {
                cell = tableView.makeView(
                    withIdentifier: identifier,
                    owner: self
                ) as? ResourceUsageTableCellView ?? ResourceUsageTableCellView()
            }
            cell.identifier = identifier
            cell.effectsPolicy = cellEffectsPolicy
            cell.configure(
                presentation: presentation,
                toolTip: value.tooltip.isEmpty ? nil : value.tooltip,
                alignment: textAlignment(alignment),
                textColor: resourceUsageBaseTextColor(value.severity),
                emphasizedTerm: emphasizedTerm,
                changeHighlight: changeHighlight
            )
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("cell.\(columnID)")
        let cell: ResourceTextTableCellView
        if let existingView {
            guard let existingCell = existingView as? ResourceTextTableCellView
            else { return nil }
            cell = existingCell
        } else {
            cell = tableView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? ResourceTextTableCellView ?? ResourceTextTableCellView()
        }
        cell.identifier = identifier
        cell.effectsPolicy = cellEffectsPolicy
        cell.configure(
            cell: value,
            alignment: textAlignment(alignment),
            emphasizedTerm: emphasizedTerm,
            changeHighlight: changeHighlight
        )
        return cell
    }

    private func textAlignment(_ alignment: ColumnAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    private func resourceUsageBaseTextColor(_ severity: CellSeverity?) -> NSColor {
        switch severity {
        case .informational: .systemBlue
        case .muted: .secondaryLabelColor
        default: .labelColor
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallbacks else { return }
        model.replaceSelectionFromVisibleRows(
            indexes: Array(tableView.selectedRowIndexes),
            anchorIndex: tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        )
        updateStatusLine()
        publishContextualShortcutsIfChanged()
    }

    private func performSelectionGesture(_ gesture: ResourceTableSelectionGesture) -> Bool {
        let row = gesture.keyboardDirection.map {
            model.selectionExtensionDestinationIndex(movingDown: $0 == .down)
        } ?? gesture.row
        guard model.applySelectionGesture(
            clickedIndex: row,
            modifiers: gesture.modifiers
        ) else { return false }
        let selectedIndexes = model.orderedVisibleUIDs.enumerated().compactMap {
            model.selectedUIDs.contains($0.element) ? $0.offset : nil
        }
        suppressSelectionCallbacks = true
        tableView.selectRowIndexes(IndexSet(selectedIndexes), byExtendingSelection: false)
        suppressSelectionCallbacks = false
        if let row { tableView.scrollRowToVisible(row) }
        updateStatusLine()
        publishContextualShortcutsIfChanged()
        return true
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard !suppressSortChanges else { return }
        let proposed = currentSortPresentation
        let cycled = ResourceSortCyclePolicy.applyingHeaderClickCycle(
            previous: sortPresentation(oldDescriptors),
            proposed: proposed
        )
        if cycled != proposed {
            applySortPresentation(cycled)
        }
        updateDeferredSortFromCurrentTable()
        if let key = tableView.sortDescriptors.first?.key {
            logger.debug("Requested backend table sort for \(key, privacy: .public)")
        } else {
            logger.debug("Cleared backend table sort")
        }
        openStream()
        onRestorationChanged?()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        updateDeferredColumnOrderFromMove(notification)
        scheduleRestorationCheckpoint()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        updateDeferredColumnMeasurementsFromCurrentTable(notification)
        scheduleRestorationCheckpoint()
    }

    /// AppKit calls this delegate when the user double-clicks a column divider.
    /// Compact rows let us measure without constructing off-screen cell views;
    /// sampling bounds main-thread work for six-figure resource lists.
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn columnIndex: Int) -> CGFloat {
        guard tableView.tableColumns.indices.contains(columnIndex) else { return 0 }
        let column = tableView.tableColumns[columnIndex]
        let columnID = column.identifier.rawValue
        let rowCount = model.orderedVisibleUIDs.count
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var fittedWidth = column.headerCell.cellSize.width + 18
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let visibleRange: Range<Int>? = visibleRows.location == NSNotFound
            ? nil
            : visibleRows.location..<(visibleRows.location + visibleRows.length)

        for rowIndex in Self.autoWidthPolicy.sampleIndexes(
            rowCount: rowCount,
            visibleRows: visibleRange
        ) {
            let uid = model.orderedVisibleUIDs[rowIndex]
            let text = model.rowByUID[uid]?[columnID]?.displayText ?? "—"
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width + 12
            fittedWidth = max(fittedWidth, textWidth)
            if fittedWidth >= Self.autoWidthPolicy.maximumWidth { break }
        }

        return CGFloat(Self.autoWidthPolicy.fittedWidth(
            candidateWidth: Double(fittedWidth),
            minimumWidth: Double(column.minWidth),
            columnMaximumWidth: Double(column.maxWidth)
        ))
    }

    @objc private func openSelectedObjectFromTable() {
        guard canPerformCommand(.open, requiringTableFocus: false) else {
            NSSound.beep()
            return
        }
        openSelectedObject(initialTab: .automatic)
    }

    @objc private func enterSelectedObjectFromTable() {
        guard canPerformCommand(.enter, requiringTableFocus: false),
            let identity = model.selectedIdentities.only
        else { return }
        onEnterObject?(identity)
    }

    private func openSelectedObject(
        initialTab: ObjectDetailInitialTab,
        identities: [ResourceIdentity]? = nil
    ) {
        guard let identity = (identities ?? model.selectedIdentities).only else { return }
        onOpenObject?(identity, initialTab)
    }

    private func handle(
        _ command: ResourceTableCommand,
        identities capturedIdentities: [ResourceIdentity]? = nil,
        hiddenSelectionUIDs: Set<ResourceUID>? = nil
    ) {
        let selected = capturedIdentities ?? model.selectedIdentities
        switch command {
        case .focusFilter:
            setFilterShortcutContextActive(true)
            view.window?.makeFirstResponder(filterField)
        case .enter:
            guard let identity = selected.only else { return }
            onEnterObject?(identity)
        case .open:
            if capturedIdentities == nil {
                openSelectedObjectFromTable()
            } else {
                openSelectedObject(initialTab: .automatic, identities: selected)
            }
        case .openYAML:
            openSelectedObject(initialTab: .yaml, identities: selected)
        case .openYAMLSnapshot:
            guard let identity = selected.only else { return }
            onOpenYAMLSnapshot?(identity)
        case .openEvents:
            openSelectedObject(initialTab: .events, identities: selected)
        case .startPortForward:
            guard let identity = selected.only,
                identity.group.isEmpty,
                identity.version == "v1",
                identity.resource == "pods" || identity.resource == "services"
            else { return }
            onStartPortForward?(identity)
        case .openLogs, .openPreviousLogs:
            guard LogResourceCompatibility.supportsSelection(selected)
            else { NSSound.beep(); return }
            onOpenLogs?(.allContainers(
                for: selected,
                previous: command == .openPreviousLogs
            ))
        case .openExec:
            guard let identity = selected.only,
                identity.group.isEmpty, identity.version == "v1", identity.resource == "pods"
            else { NSSound.beep(); return }
            onOpenExec?(PodExecTarget(pod: identity))
        case .configureExec:
            guard let identity = selected.only,
                identity.group.isEmpty, identity.version == "v1", identity.resource == "pods"
            else { NSSound.beep(); return }
            onConfigureExec?(PodExecTarget(pod: identity))
        case .selectAll:
            model.selectAllVisible()
            suppressSelectionCallbacks = true
            tableView.installSelectAllProjection()
            suppressSelectionCallbacks = false
            updateStatusLine()
            publishContextualShortcutsIfChanged()
        case .delete:
            let currentVisibleUIDs = Set(model.orderedVisibleUIDs)
            let hidden = hiddenSelectionUIDs ?? Set(
                selected.lazy.map(\.uid).filter {
                    !currentVisibleUIDs.contains($0)
                }
            )
            let targets = selected.map { identity in
                ResourceDeleteTarget(
                    identity: identity,
                    hiddenByFilter: hidden.contains(identity.uid)
                )
            }
            guard !targets.isEmpty else { NSSound.beep(); return }
            onDelete?(targets)
        case .scale:
            guard let identity = selected.only else { return }
            onMutate?(identity, .scale)
        case .restart:
            guard let identity = selected.only else { return }
            onMutate?(identity, .rolloutRestart)
        case .editMetadata:
            guard let identity = selected.only else { return }
            onMutate?(identity, .metadata)
        case .copyName:
            copyIdentities(selected) { $0.name }
        case .copyNamespacedName:
            copyIdentities(selected) { identity in
                identity.namespace.isEmpty ? identity.name : "\(identity.namespace)/\(identity.name)"
            }
        case .copyReference:
            copyIdentities(selected) { identity in
                var reference = "\(identity.resource)/\(identity.name)"
                if !identity.namespace.isEmpty { reference += " -n \(identity.namespace)" }
                return reference
            }
        case .moveDown, .moveUp:
            let delta = command == .moveDown ? 1 : -1
            let next = min(max(tableView.selectedRow + delta, 0), max(0, tableView.numberOfRows - 1))
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
        case .extendDown, .extendUp:
            _ = performSelectionGesture(ResourceTableSelectionGesture(
                row: nil,
                modifiers: [.shift],
                keyboardDirection: command == .extendDown ? .down : .up
            ))
        }
    }

    private func copyIdentities(
        _ identities: [ResourceIdentity],
        transform: (ResourceIdentity) -> String
    ) {
        let values = identities.map(transform)
        guard !values.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
    }

    func performCommand(_ command: ResourceTableCommand) {
        guard canPerformCommand(command) else { NSSound.beep(); return }
        handle(command)
    }

    /// Executes a palette operation against the immutable identity snapshot
    /// captured when Command-K was pressed. This deliberately bypasses current
    /// responder/selection validation; the captured CommandContext has already
    /// been validated and the full identities remain the operation targets.
    func performCapturedCommand(
        _ command: ResourceTableCommand,
        identities: [ResourceIdentity],
        hiddenSelectionUIDs: Set<ResourceUID> = []
    ) {
        handle(
            command,
            identities: identities,
            hiddenSelectionUIDs: hiddenSelectionUIDs
        )
    }

    func canPerformCommand(_ command: ResourceTableCommand) -> Bool {
        canPerformCommand(command, requiringTableFocus: true)
    }

    func isCommandCompatible(_ command: ResourceTableCommand) -> Bool {
        isCommandCompatible(command, with: model.selectedIdentities)
    }

    private func canPerformCommand(
        _ command: ResourceTableCommand,
        requiringTableFocus: Bool
    ) -> Bool {
        if requiringTableFocus, view.window?.firstResponder !== tableView { return false }
        let selected = model.selectedIdentities
        let isLocalOnly: Bool
        switch command {
        case .copyName, .copyNamespacedName, .copyReference,
            .focusFilter, .selectAll, .moveDown, .moveUp, .extendDown, .extendUp:
            isLocalOnly = true
        default:
            isLocalOnly = false
        }
        if !isLocalOnly,
            !recoveredResourceTrust.permitsNetworkActions(for: selected)
        {
            return false
        }
        return isCommandCompatible(command, with: selected)
    }

    private func isCommandCompatible(
        _ command: ResourceTableCommand,
        with selected: [ResourceIdentity]
    ) -> Bool {
        switch command {
        case .enter:
            return selected.count == 1
                && ResourceDrillDownPlanner.hasPotentialTarget(selected[0])
        case .open, .openYAML, .openYAMLSnapshot, .openEvents:
            return selected.count == 1
        case .openLogs, .openPreviousLogs:
            return LogResourceCompatibility.supportsSelection(selected)
        case .openExec, .configureExec:
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
        case .copyName, .copyNamespacedName, .copyReference:
            return !selected.isEmpty
        case .focusFilter, .selectAll, .moveDown, .moveUp, .extendDown, .extendUp:
            return true
        }
    }
}

private enum ResourceTableCommand: Equatable {
    case focusFilter, enter, open, openYAML, openYAMLSnapshot, openEvents
    case openLogs, openPreviousLogs
    case openExec, configureExec
    case startPortForward, selectAll, delete, scale, restart, editMetadata
    case copyName, copyNamespacedName, copyReference, moveUp, moveDown, extendUp, extendDown
}

private extension ResourceTableCommand {
    var subresourceNetworkAction: ObjectSubresourceNetworkAction? {
        switch self {
        case .openLogs: .openLogs
        case .openPreviousLogs: .openPreviousLogs
        case .openExec: .openAutomaticExec
        case .configureExec: .configureExec
        case .startPortForward: .startPortForward
        default: nil
        }
    }
}

private extension PaletteOperation {
    var resourceTableCommand: ResourceTableCommand {
        switch self {
        case .openDetails: .open
        case .openYAML: .openYAML
        case .openEvents: .openEvents
        case .openLogs: .openLogs
        case .openExec: .openExec
        case .startPortForward: .startPortForward
        case .delete: .delete
        case .scale: .scale
        case .restart: .restart
        case .editMetadata: .editMetadata
        case .copyName: .copyName
        case .copyNamespacedName: .copyNamespacedName
        case .copyReference: .copyReference
        }
    }
}

private final class ResourceTableCommandBox {
    let command: ResourceTableCommand
    init(_ command: ResourceTableCommand) { self.command = command }
}

@MainActor
private final class ResourceTableView: NSTableView {
    var onCommand: ((ResourceTableCommand) -> Void)?
    var onSelectionGesture: ((ResourceTableSelectionGesture) -> Bool)?

    /// A nil-targeted Edit > Select All command resolves to NSTableView before
    /// `keyDown(with:)` gets a chance to translate Command-A. Route that
    /// responder action through the UID-owned model so selected rows hidden by
    /// the current filter are retained. Model-to-AppKit projection uses the
    /// explicit `super` seam below to avoid recursively dispatching the command.
    override func selectAll(_ sender: Any?) {
        guard currentEditor() == nil, let onCommand else {
            super.selectAll(sender)
            return
        }
        onCommand(.selectAll)
    }

    func installSelectAllProjection() {
        super.selectAll(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let gesture = ResourceTableSelectionGesture(
            row: row >= 0 ? row : nil,
            modifiers: Self.selectionModifiers(from: event.modifierFlags),
            keyboardDirection: nil
        )
        if !gesture.modifiers.isEmpty,
            onSelectionGesture?(gesture) == true
        {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else { super.keyDown(with: event); return }
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers, event.keyCode, command) {
        case ("/", _, false): onCommand?(.focusFilter)
        case ("j", _, false): onCommand?(.moveDown)
        case ("k", _, false): onCommand?(.moveUp)
        case (_, 36, false): onCommand?(.enter)
        case ("y", _, false), ("Y", _, false):
            guard event.modifierFlags.intersection([.control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            onCommand?(event.modifierFlags.contains(.shift)
                ? .openYAMLSnapshot : .openYAML)
        case ("e", _, false), ("E", _, false): onCommand?(.openEvents)
        case ("l", _, false), ("L", _, false):
            guard event.modifierFlags.intersection([.control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            onCommand?(event.modifierFlags.contains(.shift) ? .openPreviousLogs : .openLogs)
        case ("s", _, false), ("S", _, false):
            guard event.modifierFlags.intersection([.control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            onCommand?(event.modifierFlags.contains(.shift) ? .configureExec : .openExec)
        case ("p", _, false), ("P", _, false): onCommand?(.startPortForward)
        case ("a", _, true): onCommand?(.selectAll)
        case (_, 51, true): onCommand?(.delete)
        case ("[", _, true):
            _ = window?.windowController?.tryToPerform(
                #selector(ClusterWorkspaceWindowController.navigateBack(_:)),
                with: nil
            )
        case ("]", _, true):
            _ = window?.windowController?.tryToPerform(
                #selector(ClusterWorkspaceWindowController.navigateForward(_:)),
                with: nil
            )
        case (_, 53, false):
            _ = tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        default:
            if event.keyCode == 125 || event.keyCode == 126 {
                let gesture = ResourceTableSelectionGesture(
                    row: nil,
                    modifiers: Self.selectionModifiers(from: event.modifierFlags),
                    keyboardDirection: event.keyCode == 125 ? .down : .up
                )
                if gesture.modifiers.contains(.shift),
                    onSelectionGesture?(gesture) == true
                {
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    private static func selectionModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> ResourceTableSelectionModifiers {
        var result: ResourceTableSelectionModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

private struct ResourceTableSelectionGesture {
    let row: Int?
    let modifiers: ResourceTableSelectionModifiers
    let keyboardDirection: KeyboardSelectionDirection?
}

private enum KeyboardSelectionDirection {
    case up
    case down
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
