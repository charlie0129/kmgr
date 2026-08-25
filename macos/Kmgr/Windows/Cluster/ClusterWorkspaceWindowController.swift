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

enum DeleteResourcesRequest {
    case explicit([ResourceDeleteTarget])
    case selection(
        reference: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision
    )
}

struct ColumnPresentationState: Hashable {
    var columnID: String
    var width: Double
    var isVisible: Bool

    init(columnID: String, width: Double, isVisible: Bool = true) {
        self.columnID = columnID
        self.width = width
        self.isVisible = isVisible
    }
}

struct ColumnMoveState: Hashable {
    var columnID: String
    var targetIndex: Int
}

struct DeferredColumnPresentationState {
    static let maximumMoveCount = 256

    var columns: [ColumnPresentationState]
    var sort: [SortDescriptorState]
    var columnMoves: [ColumnMoveState] = []
    var measurementOverrides: [ColumnPresentationState] = []

    mutating func recordColumnMove(_ move: ColumnMoveState) {
        var boundedMove = move
        boundedMove.targetIndex = min(
            max(move.targetIndex, 0),
            Self.maximumMoveCount - 1
        )
        columnMoves.append(boundedMove)
        let overflow = columnMoves.count - Self.maximumMoveCount
        if overflow > 0 {
            // A configuration load normally lasts milliseconds. If it remains
            // unavailable across hundreds of gestures, retain the newest
            // bounded operations instead of growing pending UI state forever.
            columnMoves.removeFirst(overflow)
        }
    }
}

/// Only fields that change backend extraction belong here. Titles, alignment,
/// preferred width, and presentation order are local table concerns and must
/// not reopen a LIST/WATCH stream when the same projected column set remains.
private struct ResourceColumnProjectionIdentity: Hashable {
    var id: String
    var source: ColumnSource
    var expression: String?
    var value: String?
    var type: ColumnResultType
    var missing: String?
    var listJoiner: String?

    init(_ definition: ColumnDefinition) {
        id = definition.id
        source = definition.source
        expression = definition.expression
        value = definition.value
        type = definition.type
        missing = definition.missing
        listJoiner = definition.listJoiner
    }
}

@MainActor
final class ClusterWorkspaceWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation, ContextualShortcutProviding
{
    private(set) var session: OpenedClusterSession
    private(set) var isAuthenticated: Bool
    var onClose: (() -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogWindow: ((LogWindowController) -> Void)?
    var onOpenTerminalWindow: ((TerminalWindowController) -> Void)?
    var onRestorationCheckpoint: ((ClusterWindowRestorationRecord) -> Void)?
    var onWindowSizeCheckpoint: ((ClusterWorkspaceWindowSize) -> Void)?
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
    private let tableLayoutStore: TableLayoutStore
    private let logDisplayConfiguration: LogDisplayConfiguration
    private let confirmationPreferences: @MainActor () -> ConfirmationPreferences
    private let resourceOperationPreferences: @MainActor () -> ResourceOperationPreferences
    private let nodeShellPreferences: @MainActor () -> NodeShellPreferences
    private let saveNodeShellPreferences: @MainActor (NodeShellPreferences) throws -> Void
    private let workspaceController: ClusterWorkspaceViewController
    private var restoration: ClusterWindowRestorationRecord
    private var portForwardConfigurationController: PortForwardConfigurationWindowController?
    private var logOpenTask: Task<Void, Never>?
    private var logOpenRevision: UInt64 = 0
    private var automaticExecOpenTask: Task<Void, Never>?
    private var automaticExecOpenRevision: UInt64 = 0
    private var execConfigurationController: ExecConfigurationWindowController?
    private var nodeShellConfigurationController: NodeShellConfigurationWindowController?
    private var deleteResourcesController: DeleteResourcesWindowController?
    private var resourceMutationController: ResourceMutationWindowController?
    private var metadataEditorController: ResourceMetadataEditorWindowController?
    private var yamlSnapshotWindowControllers: [ResourceUID: YAMLSnapshotWindowController] = [:]
    private var didStartWorkspace = false
    private var isClosing = false
    private var windowSizeCheckpointTask: Task<Void, Never>?
    private let resourceFilterFieldEditor = ResourceFilterFieldEditor(frame: .zero)

    var restorationIdentifier: String { restoration.id }
    var isOpenForRestoration: Bool { !isClosing }

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        connectionActivityProvider: any ClusterConnectionActivityProviding,
        operationHistoryProvider: (any ClusterOperationHistoryProviding)? = nil,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        objectSearchProvider: any ObjectSearchProviding,
        objectDetailProvider: any ObjectDetailProviding,
        recentObjectStore: RecentObjectStore = .shared,
        operationProvider: any ResourceOperationProviding,
        logProvider: any LogStreamProviding,
        execProvider: any ExecSessionProviding,
        portForwards: PortForwardCoordinator,
        tableLayoutStore: TableLayoutStore? = nil,
        columnsConfigurationPath: String,
        columnConfigurationCoordinator: ColumnConfigurationCoordinator? = nil,
        columnsConfigurationLoader: ColumnConfigurationDocumentLoader = .fileSystem,
        resourceViewportTiming: ResourceViewportTiming = .production,
        resourceCellHighlightTiming: ResourceCellHighlightTiming = .production,
        tableColumnMutationAllowed: @escaping @MainActor () -> Bool = {
            NSEvent.pressedMouseButtons == 0
        },
        logDisplayConfiguration: LogDisplayConfiguration,
        operationHistoryCompletedLimit: Int = 2_000,
        confirmationPreferences: @escaping @MainActor () -> ConfirmationPreferences,
        resourceOperationPreferences: @escaping @MainActor () -> ResourceOperationPreferences = {
            ResourceOperationPreferences()
        },
        nodeShellPreferences: @escaping @MainActor () -> NodeShellPreferences = {
            NodeShellPreferences()
        },
        saveNodeShellPreferences: @escaping @MainActor (NodeShellPreferences) throws -> Void = {
            _ in
        },
        namespacePickerPresenter: @escaping NamespacePickerPresenter = { control, sender in
            control.performClick(sender)
        },
        namespacePickerKeyWindowCheck: @escaping NamespacePickerKeyWindowCheck = {
            $0.isKeyWindow
        },
        restoration: ClusterWindowRestorationRecord,
        initialWindowFrameSize: ClusterWorkspaceWindowSize? = nil,
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
        self.tableLayoutStore = tableLayoutStore ?? TableLayoutStore()
        self.logDisplayConfiguration = logDisplayConfiguration
        self.confirmationPreferences = confirmationPreferences
        self.resourceOperationPreferences = resourceOperationPreferences
        self.nodeShellPreferences = nodeShellPreferences
        self.saveNodeShellPreferences = saveNodeShellPreferences

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

        workspaceController = ClusterWorkspaceViewController(
            session: session,
            isAuthenticated: startsAuthenticated,
            provider: provider,
            connectionActivityProvider: connectionActivityProvider,
            operationHistoryProvider: operationHistoryProvider,
            optionalResourceCatalogProvider: optionalResourceCatalogProvider,
            objectSearchProvider: objectSearchProvider,
            objectDetailProvider: objectDetailProvider,
            recentObjectStore: recentObjectStore,
            portForwards: portForwards,
            tableLayoutStore: self.tableLayoutStore,
            operationHistoryCompletedLimit: operationHistoryCompletedLimit,
            columnsConfigurationPath: columnsConfigurationPath,
            columnConfigurationCoordinator: columnConfigurationCoordinator
                ?? ColumnConfigurationCoordinator(path: columnsConfigurationPath),
            columnsConfigurationLoader: columnsConfigurationLoader,
            resourceViewportTiming: resourceViewportTiming,
            resourceCellHighlightTiming: resourceCellHighlightTiming,
            tableColumnMutationAllowed: tableColumnMutationAllowed,
            namespacePickerPresenter: namespacePickerPresenter,
            namespacePickerKeyWindowCheck: namespacePickerKeyWindowCheck,
            onShowPortForwards: onShowPortForwards
        )
        super.init(window: window)
        installWorkspaceCallbacks()
        resourceFilterFieldEditor.commandHandler = { [weak self] selector in
            self?.workspaceController.handleResourceFilterCommand(selector) ?? false
        }
        window.delegate = self
        window.contentViewController = workspaceController
        window.toolbar = workspaceController.makeToolbar()
        if let initialWindowFrameSize, initialWindowFrameSize.isValid {
            var frame = window.frame
            let visibleSize = NSScreen.main?.visibleFrame.size
            let requestedWidth = CGFloat(initialWindowFrameSize.width)
            let requestedHeight = CGFloat(initialWindowFrameSize.height)
            frame.size.width = max(
                window.minSize.width,
                min(requestedWidth, visibleSize?.width ?? requestedWidth)
            )
            frame.size.height = max(
                window.minSize.height,
                min(requestedHeight, visibleSize?.height ?? requestedHeight)
            )
            window.setFrame(frame, display: false)
        }
        window.center()
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
        workspaceController.onOpenNodeShell = { [weak self] target in
            self?.openNodeShell(target)
        }
        workspaceController.onConfigureNodeShell = { [weak self] target in
            self?.showNodeShellConfiguration(target)
        }
        workspaceController.onDelete = { [weak self] request in
            self?.showDeleteResources(request)
        }
        workspaceController.onMutate = { [weak self] identity, mutation in
            self?.showResourceMutation(identity, mutation: mutation)
        }
        workspaceController.onEditMetadata = { [weak self] identity, kind, key in
            self?.showMetadataEditor(identity, kind: kind, initialKey: key)
        }
        workspaceController.onRestorationChanged = { [weak self] state in
            guard let self, !isClosing else { return }
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
        if !didStartWorkspace {
            // Install the restoration handoff before AppKit can make the
            // window key. `showWindow` may synchronously emit
            // `windowDidBecomeKey`; checkpointing before `start` would read
            // the resource controller's empty defaults and destroy the saved
            // resource, namespace, and filter before discovery can apply them.
            didStartWorkspace = true
            workspaceController.start(
                restoring: restoration.state,
                connectsImmediately: isAuthenticated
            )
        }
        super.showWindow(sender)
    }

    /// Keep the last rendered view visible while the shared helper is down.
    /// No operation is replayed from this transition.
    func engineDidDisconnect(message: String) {
        yamlSnapshotWindowControllers.values.forEach { $0.engineDidDisconnect() }
        workspaceController.engineDidDisconnect(message: message)
    }

    func engineDidRestart() {
        workspaceController.engineDidRestart()
    }

    func clearEngineRestartNotice() {
        workspaceController.clearEngineRestartNotice()
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

    func applyOperationHistoryLimit(_ limit: Int) {
        workspaceController.applyOperationHistoryLimit(limit)
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
        nodeShellConfigurationController?.close()
        deleteResourcesController?.close()
        resourceMutationController?.close()
        metadataEditorController?.dismissForEngineRecovery()
        portForwardConfigurationController = nil
        execConfigurationController = nil
        nodeShellConfigurationController = nil
        deleteResourcesController = nil
        resourceMutationController = nil
        metadataEditorController = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard didStartWorkspace, !isClosing else { return }
        _ = checkpointActiveWorkspace()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard didStartWorkspace, !isClosing else { return }
        _ = checkpointActiveWorkspace()
    }

    /// Snapshots editor text before its normal debounce has fired and publishes
    /// the complete active presentation for Command-N or application shutdown.
    @discardableResult
    func checkpointActiveWorkspace() -> ClusterWindowRestorationState {
        restoration.state = workspaceController.restorationState()
        let state = restoration.state
        checkpointWindowSize()
        onRestorationCheckpoint?(restoration)
        return state
    }

    func checkpointRestoration() {
        restoration.state = workspaceController.restorationState()
        onRestorationCheckpoint?(restoration)
    }

    func windowDidResize(_ notification: Notification) {
        scheduleWindowSizeCheckpoint()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleWindowSizeCheckpoint()
    }

    func windowWillReturnFieldEditor(
        _ sender: NSWindow,
        to client: Any?
    ) -> Any? {
        guard sender === window, workspaceController.isResourceFilter(client)
        else { return nil }
        return resourceFilterFieldEditor
    }

    private func scheduleWindowSizeCheckpoint() {
        windowSizeCheckpointTask?.cancel()
        windowSizeCheckpointTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            windowSizeCheckpointTask = nil
            checkpointWindowSize()
        }
    }

    private func checkpointWindowSize() {
        guard let size = window?.frame.size else { return }
        onWindowSizeCheckpoint?(ClusterWorkspaceWindowSize(
            width: size.width,
            height: size.height
        ))
    }

    /// Cancel helper-backed work without closing windows, changing restoration
    /// state, or issuing one CloseSession RPC per workspace. AppKit keeps the
    /// windows alive until asynchronous application termination is approved.
    func prepareForTermination() {
        // The final application snapshot has already been taken before this
        // method runs. AppKit may deliver window/model callbacks while the
        // asynchronous termination handshake is in flight; none of those
        // callbacks may write a new restore record after the snapshot prune.
        onRestorationCheckpoint = nil
        windowSizeCheckpointTask?.cancel()
        windowSizeCheckpointTask = nil
        logOpenRevision &+= 1
        logOpenTask?.cancel()
        logOpenTask = nil
        automaticExecOpenRevision &+= 1
        automaticExecOpenTask?.cancel()
        automaticExecOpenTask = nil
        for controller in yamlSnapshotWindowControllers.values {
            controller.stop()
        }
        workspaceController.stop()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        _ = checkpointActiveWorkspace()
        prepareForTermination()
        let yamlWindows = Array(yamlSnapshotWindowControllers.values)
        yamlSnapshotWindowControllers.removeAll()
        yamlWindows.forEach { $0.close() }
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
            provider: objectDetailProvider,
            tableLayoutStore: tableLayoutStore
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
            execConfigurationController == nil,
            nodeShellConfigurationController == nil
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
            execConfigurationController == nil,
            nodeShellConfigurationController == nil
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

    private func openNodeShell(_ target: NodeShellTarget) {
        guard automaticExecOpenTask == nil,
            execConfigurationController == nil,
            nodeShellConfigurationController == nil
        else { NSSound.beep(); return }
        do {
            let preferences = nodeShellPreferences()
            let plan = try NodeShellLaunchPlanner.plan(
                session: session,
                target: target,
                image: preferences.effectiveImage(
                    contextReference: session.contextReference
                ),
                namespace: NodeShellLaunchPlanner.defaultNamespace(for: session),
                execSessionID: UUID().uuidString.lowercased()
            )
            onOpenTerminalWindow?(TerminalWindowController(
                request: plan.request,
                provider: execProvider,
                fallbackShellCommand: plan.fallbackShellCommand
            ))
        } catch {
            presentExecOpenFailure(error)
        }
    }

    private func showNodeShellConfiguration(_ target: NodeShellTarget) {
        guard let window,
            automaticExecOpenTask == nil,
            execConfigurationController == nil,
            nodeShellConfigurationController == nil
        else { NSSound.beep(); return }
        let preferences = nodeShellPreferences()
        let contextReference = session.contextReference
        let controller = NodeShellConfigurationWindowController(
            session: session,
            target: target,
            image: preferences.effectiveImage(contextReference: contextReference),
            namespace: NodeShellLaunchPlanner.defaultNamespace(for: session),
            usesClusterImageOverride: preferences.clusterImagesByContextReference[
                contextReference
            ] != nil,
            execProvider: execProvider,
            saveClusterImage: { [weak self] image in
                guard let self else { return }
                var updated = nodeShellPreferences()
                updated.setClusterImage(image, contextReference: contextReference)
                try saveNodeShellPreferences(updated)
            }
        )
        controller.onOpenWindow = { [weak self] in self?.onOpenTerminalWindow?($0) }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.nodeShellConfigurationController === controller else { return }
            self?.nodeShellConfigurationController = nil
        }
        nodeShellConfigurationController = controller
        controller.beginSheet(for: window)
    }

    private func showDeleteResources(_ request: DeleteResourcesRequest) {
        guard let window, deleteResourcesController == nil else { NSSound.beep(); return }
        let controller = DeleteResourcesWindowController(
            session: session,
            request: request,
            provider: operationProvider,
            defaultConcurrency: UInt32(
                resourceOperationPreferences().defaultDeleteConcurrency
            ),
            tableLayoutStore: tableLayoutStore,
            currentSelectionRevision: { [weak workspaceController] reference, revision in
                workspaceController?.currentSelectionRevision(
                    reference,
                    capturedGeneration: revision.generation
                )
            }
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
        guard let window, resourceMutationController == nil,
            metadataEditorController == nil
        else { NSSound.beep(); return }
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

    private func showMetadataEditor(
        _ identity: ResourceIdentity,
        kind: ResourceMetadataKind,
        initialKey: String?
    ) {
        guard let window, isAuthenticated,
            identity.clusterSessionID == session.sessionID,
            metadataEditorController == nil,
            resourceMutationController == nil
        else { NSSound.beep(); return }
        let controller = ResourceMetadataEditorWindowController(
            session: session,
            identity: identity,
            kind: kind,
            initialKey: initialKey,
            detailProvider: objectDetailProvider,
            operationProvider: operationProvider,
            tableLayoutStore: tableLayoutStore
        )
        controller.onSaved = { [weak workspaceController] in
            workspaceController?.refreshDetailAfterMetadataMutation(identity)
        }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.metadataEditorController === controller else { return }
            self?.metadataEditorController = nil
        }
        metadataEditorController = controller
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
    @objc func refreshAPIResources(_ sender: Any?) {
        workspaceController.refreshAPIResources(sender)
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
    @objc func editResourceLabels(_ sender: Any?) { workspaceController.editResourceLabels(sender) }
    @objc func editResourceAnnotations(_ sender: Any?) {
        workspaceController.editResourceAnnotations(sender)
    }
    @objc func copyResourceCell(_ sender: Any?) { workspaceController.copyResourceCell(sender) }
    @objc func copyResourceName(_ sender: Any?) { workspaceController.copyResourceName(sender) }
    @objc func copyResourceNamespacedName(_ sender: Any?) {
        workspaceController.copyResourceNamespacedName(sender)
    }
    @objc func copyResourceReference(_ sender: Any?) { workspaceController.copyResourceReference(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(chooseNamespace(_:)) {
            return workspaceController.canChooseNamespace
        }
        if menuItem.action == #selector(refreshAPIResources(_:)) {
            return workspaceController.canRefreshAPIResources
        }
        if menuItem.action == #selector(copyResourceCell(_:)) {
            return workspaceController.canCopyResourceCell
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
        case #selector(editResourceLabels(_:)): command = .editLabels
        case #selector(editResourceAnnotations(_:)): command = .editAnnotations
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

private struct DisplayedWarmCacheUsage: Equatable {
    var authority: WarmCacheUsage
    var global: WarmCacheUsage
}

@MainActor
private final class ClusterWorkspaceViewController: NSSplitViewController,
    NSToolbarDelegate, NSSearchFieldDelegate
{
    private var session: OpenedClusterSession
    private var isAuthenticated: Bool
    private let provider: any WorkspaceResourceProviding
    private let connectionActivityProvider: any ClusterConnectionActivityProviding
    private let operationHistoryProvider: (any ClusterOperationHistoryProviding)?
    private let objectSearchProvider: any ObjectSearchProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let recentObjectStore: RecentObjectStore
    private let portForwards: PortForwardCoordinator
    private let tableLayoutStore: TableLayoutStore
    private let namespacePickerPresenter: NamespacePickerPresenter
    private let namespacePickerKeyWindowCheck: NamespacePickerKeyWindowCheck
    private let onShowPortForwards: @MainActor () -> Void
    private let sidebarController: ResourceSidebarViewController
    private let contentController: ResourceListViewController
    private let namespaceControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connectionActivityView: ClusterConnectionActivityView
    private let rightPaneController: WorkspaceRightPaneViewController
    private let connectionActivityStreamID = UUID().uuidString.lowercased()
    private let operationHistoryStreamID = UUID().uuidString.lowercased()
    private var connectionActivityTask: Task<Void, Never>?
    private var operationHistoryTask: Task<Void, Never>?
    private var connectionActivityGate = GenerationSequenceGate()
    private var operationHistoryGate = GenerationSequenceGate()
    private let operationHistoryStore: ClusterOperationHistoryStore
    private var operationHistoryWindowController: ClusterOperationHistoryWindowController?
    private var operationHistoryIsWatching = false
    private var operationHistoryStreamIssue: UserFacingErrorPresentation?
    private var operationHistoryConnectionState: ClusterConnectionState = .connecting
    private var operationHistoryConnectionErrorMessage: String?
    private var connectionRateTracker = ClusterConnectionRateTracker()
    private var displayedWarmCacheUsage: DisplayedWarmCacheUsage?
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
    private var sidebarFocusTask: Task<Void, Never>?
    private var detailController: ObjectDetailViewController?
    private var dataController: ObjectDataViewController?
    private var podContainerController: PodContainerListViewController?
    private var pendingRestorationState: ClusterWindowRestorationState?
    /// Namespace discovery races resource restoration. Keep the saved scope
    /// until the toolbar's menu is populated so its default item cannot
    /// overwrite the restored namespace.
    private var pendingNamespaceScope: NamespaceSelection?
    private struct ObjectEventsTarget {
        var resource: DiscoveredResource
        var scope: NamespaceSelection
        var filter: String
    }
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenYAMLSnapshot: ((ResourceIdentity) -> Void)?
    var onOpenLogs: ((LogOpenRequest) -> Void)?
    var onOpenExec: ((PodExecTarget) -> Void)?
    var onConfigureExec: ((PodExecTarget) -> Void)?
    var onOpenNodeShell: ((NodeShellTarget) -> Void)?
    var onConfigureNodeShell: ((NodeShellTarget) -> Void)?
    var onDelete: ((DeleteResourcesRequest) -> Void)?
    var onMutate: ((ResourceIdentity, ResourceMutationWindowController.Mutation) -> Void)?
    var onEditMetadata: ((ResourceIdentity, ResourceMetadataKind, String?) -> Void)?
    var onRestorationChanged: ((ClusterWindowRestorationState) -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?

    var contextualShortcutSnapshot: ContextualShortcutSnapshot? {
        if let dataController {
            return dataController.contextualShortcutSnapshot
        }
        if let podContainerController {
            return podContainerController.contextualShortcutSnapshot
        }
        if let detailController {
            return detailController.contextualShortcutSnapshot
        }
        return contentController.contextualShortcutSnapshot
    }

    init(
        session: OpenedClusterSession,
        isAuthenticated: Bool,
        provider: any WorkspaceResourceProviding,
        connectionActivityProvider: any ClusterConnectionActivityProviding,
        operationHistoryProvider: (any ClusterOperationHistoryProviding)?,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        objectSearchProvider: any ObjectSearchProviding,
        objectDetailProvider: any ObjectDetailProviding,
        recentObjectStore: RecentObjectStore,
        portForwards: PortForwardCoordinator,
        tableLayoutStore: TableLayoutStore,
        operationHistoryCompletedLimit: Int,
        columnsConfigurationPath: String,
        columnConfigurationCoordinator: ColumnConfigurationCoordinator,
        columnsConfigurationLoader: ColumnConfigurationDocumentLoader,
        resourceViewportTiming: ResourceViewportTiming,
        resourceCellHighlightTiming: ResourceCellHighlightTiming,
        tableColumnMutationAllowed: @escaping @MainActor () -> Bool,
        namespacePickerPresenter: @escaping NamespacePickerPresenter,
        namespacePickerKeyWindowCheck: @escaping NamespacePickerKeyWindowCheck,
        onShowPortForwards: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.isAuthenticated = isAuthenticated
        self.provider = provider
        self.connectionActivityProvider = connectionActivityProvider
        self.operationHistoryProvider = operationHistoryProvider
        self.objectSearchProvider = objectSearchProvider
        self.objectDetailProvider = objectDetailProvider
        self.recentObjectStore = recentObjectStore
        self.portForwards = portForwards
        self.tableLayoutStore = tableLayoutStore
        self.operationHistoryStore = ClusterOperationHistoryStore(
            completedLimit: operationHistoryCompletedLimit
        )
        self.namespacePickerPresenter = namespacePickerPresenter
        self.namespacePickerKeyWindowCheck = namespacePickerKeyWindowCheck
        self.onShowPortForwards = onShowPortForwards
        let connectionActivityView = ClusterConnectionActivityView()
        self.connectionActivityView = connectionActivityView
        let rightPaneController = WorkspaceRightPaneViewController(
            connectionActivityView: connectionActivityView
        )
        self.rightPaneController = rightPaneController
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
            columnConfigurationCoordinator: columnConfigurationCoordinator,
            columnsConfigurationLoader: columnsConfigurationLoader,
            viewportTiming: resourceViewportTiming,
            cellHighlightTiming: resourceCellHighlightTiming,
            tableColumnMutationAllowed: tableColumnMutationAllowed
        )
        super.init(nibName: nil, bundle: nil)

        bindStatusPublisher(contentController)
        rightPaneController.setContent(
            contentController,
            initialStatus: contentController.workspaceStatus
        )
        sidebarController.onWorkspaceStatusChanged = { [weak rightPaneController] status in
            rightPaneController?.setSupplementalStatus(status, for: .discovery)
        }
        rightPaneController.setSupplementalStatus(
            sidebarController.workspaceStatus,
            for: .discovery
        )

        sidebarController.onSelectResource = { [weak self] resource in
            guard let self else { return }
            guard pendingRestorationState == nil else { return }
            invalidateObjectOpenTask()
            showResourceList(resume: false)
            contentController.open(
                resource: resource,
                scope: selectedNamespaceScope(),
                reason: .sidebarSelection
            )
            checkpointRestoration()
            focusResourceTableAfterSidebarInteraction()
        }
        sidebarController.onResourceMouseSelectionFinished = { [weak self] in
            self?.focusResourceTableAfterSidebarInteraction()
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
        contentController.onOpenEvents = { [weak self] identity in
            self?.openEvents(for: identity)
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
        contentController.onOpenNodeShell = { [weak self] target in
            self?.onOpenNodeShell?(target)
        }
        contentController.onConfigureNodeShell = { [weak self] target in
            self?.onConfigureNodeShell?(target)
        }
        contentController.onDelete = { [weak self] request in
            self?.onDelete?(request)
        }
        contentController.onMutate = { [weak self] identity, mutation in
            self?.onMutate?(identity, mutation)
        }
        contentController.onEditMetadata = { [weak self] identity, kind in
            self?.onEditMetadata?(identity, kind, nil)
        }
        contentController.onRestorationChanged = { [weak self] in
            self?.checkpointRestoration()
        }
        contentController.onContextualShortcutsChanged = { [weak self] in
            self?.onContextualShortcutsChanged?()
        }
        addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebarController))
        addSplitViewItem(NSSplitViewItem(viewController: rightPaneController))
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
            pendingNamespaceScope = state?.namespaceScope.namespaceSelection
            installRestoredShell(state)
            return
        }
        pendingRestorationState = state
        pendingNamespaceScope = state?.namespaceScope.namespaceSelection
        connectionActivityView.setState(.connected)
        startConnectionActivityWatch()
        startOperationHistoryWatch()
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
        // Discovery applies a saved target asynchronously. Until that handoff
        // completes, checkpoint the known saved state instead of replacing it
        // with the still-empty resource controller presentation.
        if var pendingRestorationState {
            pendingRestorationState.contextName = session.contextName
            pendingRestorationState.contextReference = session.contextReference
            return pendingRestorationState
        }
        return contentController.restorationState(
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
        dataController?.engineDidDisconnect()
        podContainerController?.setNetworkActionsEnabled(false)
        contentController.engineDidDisconnect()
        connectionActivityTask?.cancel()
        connectionActivityTask = nil
        operationHistoryTask?.cancel()
        operationHistoryTask = nil
        resetWarmCacheStatus()
        connectionActivityView.setState(.reconnecting, detail: message)
        setOperationHistoryConnectionState(
            .reconnecting,
            errorMessage: message
        )
        setOperationHistoryStreamState(watching: false, error: ClusterManagerIssue(
            category: .unavailable,
            reason: "EngineDisconnected",
            message: message,
            retryable: true,
            operation: "watch Kubernetes API operations"
        ))
    }

    func engineDidRestart() {
        rightPaneController.setSupplementalStatus(
            EngineWorkspaceStatus.restarted,
            for: .engine
        )
    }

    func clearEngineRestartNotice() {
        rightPaneController.setSupplementalStatus(nil, for: .engine)
    }

    func engineRecoveryFailed(_ error: Error) {
        let presentation = UserFacingErrorPresentation(error)
        connectionActivityView.setState(.failed, detail: presentation.detailedText)
        publishWorkspaceOperation(WorkspaceStatus(
            presentation.inlineText,
            severity: .error,
            toolTip: presentation.detailedText
        ))
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
        if let restoredShellState {
            pendingNamespaceScope = restoredShellState.namespaceScope.namespaceSelection
        }
        let previousSessionID = session.sessionID
        session = recoveredSession
        isAuthenticated = true
        startConnectionActivityWatch()
        startOperationHistoryWatch(reset: true)
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
        if dataController == nil,
            case .subresource(let identity, let returnState) = contentController.currentDestination
        {
            restoreSubresource(identity, returnState: returnState)
        }
        let savedTargetStatus = WorkspaceStatus(
            "Loading the saved resource target…",
            busy: true
        )
        let isLoadingSavedTarget = dataController == nil
            && detailController == nil
            && !resumesCurrentResource
        if isLoadingSavedTarget {
            publishWorkspaceOperation(savedTargetStatus)
        }
        sidebarController.recover(session: recoveredSession) { [weak self] result in
            guard let self else { return }
            if isLoadingSavedTarget {
                rightPaneController.clearSupplementalStatus(
                    savedTargetStatus,
                    for: .workspaceOperation
                )
            }
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
            case .failure(let error):
                // Existing authenticated workspaces keep their warm/current
                // resource behavior when rediscovery fails. Only an initial
                // shell still needs its synthetic target revoked.
                guard restoredShellState != nil else { return }
                sidebarController.discardRestoredResource()
                contentController.rejectRestoredResourceValidation(error)
            }
        }
        loadNamespaces()
        startPortForwardObservation()
        if let dataController {
            dataController.recover(session: recoveredSession) { _ in }
        } else if let detailController {
            detailController.recover(session: recoveredSession) { _ in }
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
        resetWarmCacheStatus()
        connectionActivityView.update(rate: ClusterConnectionRate())
        setOperationHistoryConnectionState(.connecting)
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
                        detail: sample.errorMessage
                    )
                    setOperationHistoryConnectionState(
                        sample.state,
                        errorMessage: sample.errorMessage
                    )
                    if let rate = connectionRateTracker.receive(sample) {
                        connectionActivityView.update(rate: rate)
                    }
                    updateWarmCacheStatus(from: sample)
                }
            } catch {
                guard !Task.isCancelled, self?.session.sessionID == sessionID else { return }
                let errorMessage = (error as? ClusterManagerIssue)?.message
                    ?? error.localizedDescription
                self?.resetWarmCacheStatus()
                self?.connectionActivityView.setState(
                    .reconnecting,
                    detail: errorMessage
                )
                self?.setOperationHistoryConnectionState(
                    .reconnecting,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func startOperationHistoryWatch(reset: Bool = false) {
        operationHistoryTask?.cancel()
        operationHistoryGate.reset()
        guard let operationHistoryProvider else {
            setOperationHistoryStreamState(watching: false, error: ClusterManagerIssue(
                category: .unavailable,
                reason: "OperationHistoryUnavailable",
                message: "Kubernetes API operation history is unavailable.",
                operation: "watch Kubernetes API operations"
            ))
            return
        }
        setOperationHistoryStreamState(watching: true)
        let sessionID = session.sessionID
        let streamID = operationHistoryStreamID
        let store = operationHistoryStore
        operationHistoryTask = Task { [weak self, operationHistoryProvider] in
            if reset {
                await store.reset()
                guard !Task.isCancelled, let self,
                    self.session.sessionID == sessionID
                else { return }
                operationHistoryWindowController?.clearForNewSession()
                operationHistoryWindowController?.updateSession(session)
            }
            do {
                for try await batch in operationHistoryProvider.watchOperations(
                    sessionID: sessionID,
                    streamID: streamID
                ) {
                    guard !Task.isCancelled, let self,
                        self.session.sessionID == sessionID
                    else { return }
                    let disposition = operationHistoryGate.accept(batch.cursor)
                    guard disposition == .acceptedNewGeneration
                        || disposition == .acceptedNextSequence
                    else { continue }
                    let change = await store.apply(batch)
                    guard !Task.isCancelled, self.session.sessionID == sessionID else { return }
                    setOperationHistoryStreamState(watching: true)
                    operationHistoryWindowController?.apply(change)
                }
                guard !Task.isCancelled, let self,
                    self.session.sessionID == sessionID
                else { return }
                setOperationHistoryStreamState(watching: false, error: ClusterManagerIssue(
                    category: .unavailable,
                    reason: "OperationHistoryWatchStopped",
                    message: "The Kubernetes API operation-history watch stopped.",
                    retryable: true,
                    operation: "watch Kubernetes API operations"
                ))
            } catch {
                guard !Task.isCancelled, let self,
                    self.session.sessionID == sessionID
                else { return }
                setOperationHistoryStreamState(watching: false, error: error)
            }
        }
    }

    @objc private func showOperationHistory(_ sender: Any?) {
        let controller: ClusterOperationHistoryWindowController
        if let existing = operationHistoryWindowController {
            controller = existing
            controller.updateSession(session)
        } else {
            controller = ClusterOperationHistoryWindowController(
                session: session,
                tableLayoutStore: tableLayoutStore
            )
            operationHistoryWindowController = controller
        }
        controller.showWindow(nil)
        controller.setStreamState(
            watching: operationHistoryIsWatching,
            issue: operationHistoryStreamIssue
        )
        controller.setConnectionState(
            operationHistoryConnectionState,
            errorMessage: operationHistoryConnectionErrorMessage
        )
        let sessionID = session.sessionID
        Task { [weak self, weak controller, operationHistoryStore] in
            let snapshot = await operationHistoryStore.snapshot()
            guard !Task.isCancelled, let self, let controller,
                self.session.sessionID == sessionID,
                self.operationHistoryWindowController === controller
            else { return }
            controller.install(snapshot)
        }
    }

    func applyOperationHistoryLimit(_ limit: Int) {
        Task { [weak self, operationHistoryStore] in
            let change = await operationHistoryStore.setCompletedLimit(limit)
            guard !Task.isCancelled, let self else { return }
            operationHistoryWindowController?.apply(change)
        }
    }

    private func setOperationHistoryStreamState(
        watching: Bool,
        error: Error? = nil
    ) {
        operationHistoryIsWatching = watching
        operationHistoryStreamIssue = error.map(UserFacingErrorPresentation.init)
        operationHistoryWindowController?.setStreamState(
            watching: watching,
            issue: operationHistoryStreamIssue
        )
    }

    private func setOperationHistoryConnectionState(
        _ state: ClusterConnectionState,
        errorMessage: String? = nil
    ) {
        operationHistoryConnectionState = state
        operationHistoryConnectionErrorMessage = errorMessage
        operationHistoryWindowController?.setConnectionState(
            state,
            errorMessage: errorMessage
        )
    }

    func stop() {
        connectionActivityTask?.cancel()
        connectionActivityTask = nil
        operationHistoryTask?.cancel()
        operationHistoryTask = nil
        operationHistoryWindowController?.close()
        operationHistoryWindowController = nil
        resetWarmCacheStatus()
        namespaceTask?.cancel()
        palettePresentationTask?.cancel()
        palettePresentationTask = nil
        sidebarFocusTask?.cancel()
        sidebarFocusTask = nil
        paletteController?.close()
        paletteController = nil
        invalidateObjectOpenTask()
        detailController?.stop()
        detailController = nil
        dataController?.stop()
        dataController = nil
        if let portForwardObserver {
            portForwards.removeObserver(portForwardObserver)
            self.portForwardObserver = nil
        }
        sidebarController.stop()
        contentController.stop()
    }

    /// AppKit makes the outline the first responder while it tracks a mouse
    /// click. Defer the handoff until that tracking loop has finished so a
    /// click on an already-selected row cannot leave keyboard commands in the
    /// sidebar.
    private func focusResourceTableAfterSidebarInteraction() {
        sidebarFocusTask?.cancel()
        sidebarFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            defer { self.sidebarFocusTask = nil }
            guard self.pendingRestorationState == nil,
                let window = self.viewIfLoaded?.window
            else { return }
            _ = window.makeFirstResponder(self.contentController.tableResponder)
        }
    }

    private func updateWarmCacheStatus(from sample: ClusterConnectionActivitySample) {
        let usage = DisplayedWarmCacheUsage(
            authority: sample.authorityWarmCache,
            global: sample.globalWarmCache
        )
        guard usage != displayedWarmCacheUsage else { return }
        displayedWarmCacheUsage = usage
        rightPaneController.setSupplementalStatus(
            WarmCacheWorkspaceStatus.make(
                authority: usage.authority,
                global: usage.global
            ),
            for: .warmCache
        )
    }

    private func resetWarmCacheStatus() {
        displayedWarmCacheUsage = nil
        rightPaneController.setSupplementalStatus(nil, for: .warmCache)
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "cluster-workspace")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebar, .back, .forward, .namespace, .flexibleSpace,
            .palette, .operations, .forwards, .actions,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebar, .back, .forward, .namespace, .flexibleSpace,
            .palette, .operations, .forwards, .actions,
        ]
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
        case .operations:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Operations"
            item.paletteLabel = "Kubernetes API Operations"
            item.toolTip = "Show Kubernetes API Operations"
            item.image = NSImage(
                systemSymbolName: "list.bullet.rectangle",
                accessibilityDescription: "Kubernetes API Operations"
            )
            item.target = self
            item.action = #selector(showOperationHistory(_:))
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
        // A user choice made while namespace discovery is still running is
        // authoritative. Do not let the saved startup scope overwrite it when
        // the asynchronous menu population finishes.
        pendingNamespaceScope = nil
        let wasShowingDetail = detailController != nil || dataController != nil
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
        if detailController != nil || dataController != nil || podContainerController != nil,
            let previousResponder,
            window.makeFirstResponder(previousResponder)
        {
            return
        }
        window.makeFirstResponder(contentController.tableResponder)
    }

    var canRefreshAPIResources: Bool {
        sidebarController.canRefreshAPIResources
    }

    @objc func refreshAPIResources(_ sender: Any?) {
        guard sidebarController.refreshAPIResources(
            preserving: contentController.currentResourceID
        ) else {
            NSSound.beep()
            return
        }
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
        if detailController != nil || dataController != nil {
            showResourceList()
            checkpointRestoration()
            return
        }
        if contentController.handleEscape() { return }
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    @objc func focusResourceFilter(_ sender: Any?) { contentController.performCommand(.focusFilter) }
    func isResourceFilter(_ client: Any?) -> Bool {
        (client as AnyObject?) === contentController.resourceFilterControl
    }
    func handleResourceFilterCommand(_ selector: Selector) -> Bool {
        contentController.handleResourceFilterCommand(selector)
    }
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
    @objc func editResourceLabels(_ sender: Any?) { contentController.performCommand(.editLabels) }
    @objc func editResourceAnnotations(_ sender: Any?) {
        contentController.performCommand(.editAnnotations)
    }
    @objc func copyResourceCell(_ sender: Any?) {
        guard canCopyResourceCell else {
            NSSound.beep()
            return
        }
        contentController.copyCapturedCell(sender)
    }
    @objc func copyResourceName(_ sender: Any?) { contentController.performCommand(.copyName) }
    @objc func copyResourceNamespacedName(_ sender: Any?) {
        contentController.performCommand(.copyNamespacedName)
    }
    @objc func copyResourceReference(_ sender: Any?) { contentController.performCommand(.copyReference) }

    var canCopyResourceCell: Bool {
        detailController == nil
            && dataController == nil
            && podContainerController == nil
            && contentController.canCopyCapturedCell
    }

    func canPerformCommand(_ command: ResourceTableCommand) -> Bool {
        if let action = command.subresourceNetworkAction,
            let podContainerController
        {
            return podContainerController.canPerform(action)
        }
        return contentController.canPerformCommand(command)
    }

    func isCommandCompatible(_ command: ResourceTableCommand) -> Bool {
        if command.subresourceNetworkAction != nil, podContainerController != nil {
            return true
        }
        return contentController.isCommandCompatible(command)
    }

    func selectionScopeIsValid(
        _ reference: ResourceSelectionDeleteReference,
        capturedGeneration: UInt64
    ) -> Bool {
        contentController.selectionScopeIsValid(
            reference,
            capturedGeneration: capturedGeneration
        )
    }

    func currentSelectionRevision(
        _ reference: ResourceSelectionDeleteReference,
        capturedGeneration: UInt64
    ) -> ResourceSelectionRevision? {
        contentController.currentSelectionRevision(
            reference,
            capturedGeneration: capturedGeneration
        )
    }

    private func performNetworkCommand(_ command: ResourceTableCommand) {
        if let action = command.subresourceNetworkAction,
            let podContainerController
        {
            if !podContainerController.perform(action) { NSSound.beep() }
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

        // Capture responder, scope, discovery snapshot, and immutable selection
        // metadata synchronously at the Command-K event. Fetching recents is
        // asynchronous, so reading any of these values afterward could target
        // a different selection or responder. Complete identities remain in the
        // engine unless the activated command intrinsically needs them.
        let capturedSession = session
        let capturedResources = resources
        let capturedNamespaces = namespaces
        let capturedScope = selectedNamespaceScope()
        let capturedCommandContext = contentController.captureCommandContext()
        let capturedContentController = contentController
        palettePresentationTask = Task { [weak self, recentObjectStore] in
            async let recentObjects = recentObjectStore.recent(
                sessionID: capturedSession.sessionID
            )
            do {
                let commandContext = try await capturedContentController
                    .materializeCommandContext(capturedCommandContext)
                let recentObjects = await recentObjects
                guard !Task.isCancelled, let self else { return }
                palettePresentationTask = nil
                guard paletteController == nil,
                    session.sessionID == capturedSession.sessionID
                else { return }
                installCommandPalette(
                    session: capturedSession,
                    resources: capturedResources,
                    namespaces: capturedNamespaces,
                    namespaceScope: capturedScope,
                    commandContext: commandContext,
                    recentObjects: recentObjects
                )
            } catch {
                guard !Task.isCancelled, let self else { return }
                palettePresentationTask = nil
                contentController.showCommandContextError(error)
            }
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
            contentController.open(
                resource: resource,
                scope: selectedNamespaceScope(),
                reason: .commandPaletteSelection
            )
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
        guard capturedContext.selectionReference?.sessionID == session.sessionID
                || (capturedContext.selectionReference == nil
                    && capturedContext.selectedIdentities.allSatisfy({
                        $0.clusterSessionID == session.sessionID
                    }))
        else {
            // A helper generation change invalidates the session portion of
            // every captured identity. Never rebind and replay an operation.
            NSSound.beep()
            return
        }
        contentController.performCapturedCommand(
            operation.resourceTableCommand,
            context: capturedContext
        )
    }

    private func freshOpen(_ identity: ResourceIdentity) {
        // The Details controller performs the one UID-pinned authoritative GET
        // it needs. A palette preflight used to fetch the same object first,
        // adding latency without changing the identity passed to Details.
        invalidateObjectOpenTask()
        publishWorkspaceOperation(nil)
        showObject(identity, initialTab: .automatic)
    }

    private func enterObject(_ identity: ResourceIdentity) {
        guard let returnState = contentController.captureNavigationState()
        else { return }

        // ConfigMap/Secret Data is selected entirely by exact GVR. Its own
        // UID-validating GetData is the one authoritative GET; fetching Details
        // first would add latency and duplicate API-server work.
        if ObjectDataViewController.supports(identity) {
            showDataSubresource(identity, returnState: returnState)
            return
        }
        guard ResourceDrillDownPlanner.hasPotentialTarget(identity) else { return }
        guard let sourceSelectionTicket = contentController
            .captureSelectionOperationTicket(for: identity)
        else { return }

        let revision = beginObjectOpenTask()
        publishWorkspaceOperation(WorkspaceStatus(
            "Loading \(identity.name) subresource…",
            busy: true
        ))
        objectOpenTask = Task { [weak self, objectDetailProvider] in
            guard let self else { return }
            defer {
                if objectOpenRevision == revision { objectOpenTask = nil }
            }
            do {
                let detail = try await drillDownDetail(
                    identity,
                    provider: objectDetailProvider
                )
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                publishWorkspaceOperation(nil)
                guard detail.identity == identity,
                    drillDownSourceIsCurrent(
                        returnState: returnState,
                        selectionTicket: sourceSelectionTicket
                    ),
                    let plan = ResourceDrillDownPlanner.plan(for: detail)
                else { return }

                switch plan {
                case .resource(let query):
                    openDrillDownResource(query)
                case .containers(let pod, let values):
                    showPodContainers(
                        pod: pod,
                        containers: values,
                        returnState: returnState
                    )
                }
            } catch is CancellationError {
                if objectOpenRevision == revision {
                    publishWorkspaceOperation(nil)
                }
            } catch {
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                let presentation = UserFacingErrorPresentation(error)
                publishWorkspaceOperation(WorkspaceStatus(
                    presentation.inlineText,
                    severity: .error,
                    toolTip: presentation.detailedText
                ))
            }
        }
    }

    private func drillDownSourceIsCurrent(
        returnState: ResourceNavigationState,
        selectionTicket: ResourceSelectionOperationTicket
    ) -> Bool {
        guard case .resource = contentController.currentDestination,
            let current = contentController.captureNavigationState()
        else { return false }
        return current.group == returnState.group
            && current.version == returnState.version
            && current.resource == returnState.resource
            && current.namespaceSelection == returnState.namespaceSelection
            && current.filter == returnState.filter
            && contentController.selectionOperationTicketIsCurrent(
                selectionTicket
            )
    }

    private func drillDownDetail(
        _ identity: ResourceIdentity,
        provider: any ObjectDetailProviding
    ) async throws -> ObjectDetail {
        if identity.group.isEmpty,
            identity.version == "v1",
            identity.resource == "pods"
        {
            return try await provider.getPodContainerDetail(identity: identity)
        }
        return try await provider.getObject(identity: identity)
    }

    private func openDrillDownResource(_ query: ResourceDrillDownQuery) {
        publishWorkspaceOperation(nil)
        guard let target = resources.first(where: {
            $0.group == query.group && $0.version == query.version
                && $0.resource == query.resource && $0.verbs.contains("list")
        }) else { return }
        showResourceList(resume: false)
        applyNamespaceScopeSelection(query.namespaceScope)
        contentController.open(
            resource: target,
            scope: query.namespaceScope,
            initialFilter: query.filterExpression,
            reason: .resourceDrillDown
        )
        sidebarController.selectResource(matchingCurrent: target.id)
        checkpointRestoration()
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    private func openEvents(for identity: ResourceIdentity) {
        guard let target = objectEventsTarget(for: identity) else {
            NSSound.beep()
            return
        }
        invalidateObjectOpenTask()
        showResourceList(resume: false)
        applyNamespaceScopeSelection(target.scope)
        contentController.open(
            resource: target.resource,
            scope: target.scope,
            initialFilter: target.filter,
            reason: .resourceDrillDown
        )
        sidebarController.selectResource(matchingCurrent: target.resource.id)
        checkpointRestoration()
        view.window?.makeFirstResponder(contentController.tableResponder)
    }

    private func objectEventsTarget(
        for identity: ResourceIdentity
    ) -> ObjectEventsTarget? {
        guard let resource = resources.first(where: {
            $0.group.isEmpty && $0.version == "v1" && $0.resource == "events"
                && $0.verbs.contains("list")
        }) else { return nil }
        return ObjectEventsTarget(
            resource: resource,
            scope: identity.namespace.isEmpty
                ? NamespaceSelection() : .namespace(identity.namespace),
            filter: ResourceQueryExpression.nativeFieldSelector(
                path: "involvedObject.uid",
                equals: identity.uid.rawValue
            )
        )
    }

    private func showPodContainers(
        pod: ResourceIdentity,
        containers: [PodContainerDetail],
        returnState: ResourceNavigationState
    ) {
        contentController.navigateToSubresource(pod, returnState: returnState)
        displayPodContainers(pod: pod, containers: containers)
        checkpointRestoration()
    }

    private func displayPodContainers(
        pod: ResourceIdentity,
        containers: [PodContainerDetail]
    ) {
        detailController?.stop()
        detailController = nil
        dataController?.stop()
        dataController = nil
        contentController.suspend()
        let controller = PodContainerListViewController(
            pod: pod,
            containers: containers,
            tableLayoutStore: tableLayoutStore
        )
        controller.onBack = { [weak self] in self?.goBack() }
        controller.onOpenLogs = { [weak self] request in self?.onOpenLogs?(request) }
        controller.onOpenExec = { [weak self] target in self?.onOpenExec?(target) }
        controller.onConfigureExec = { [weak self] target in
            self?.onConfigureExec?(target)
        }
        controller.onStartPortForward = { [weak self] identity in
            self?.onStartPortForward?(identity)
        }
        controller.onContextualShortcutsChanged = { [weak self] in
            self?.onContextualShortcutsChanged?()
        }
        podContainerController = controller
        replaceMainContent(with: controller)
        view.window?.makeFirstResponder(controller.view)
        onContextualShortcutsChanged?()
    }

    private func showDataSubresource(
        _ identity: ResourceIdentity,
        returnState: ResourceNavigationState
    ) {
        contentController.navigateToSubresource(identity, returnState: returnState)
        displayData(identity)
        checkpointRestoration()
    }

    private func displayData(_ identity: ResourceIdentity) {
        invalidateObjectOpenTask()
        detailController?.stop()
        detailController = nil
        podContainerController = nil
        dataController?.stop()
        contentController.suspend()
        let controller = ObjectDataViewController(
            identity: identity,
            provider: objectDetailProvider,
            session: session,
            tableLayoutStore: tableLayoutStore
        )
        controller.onBack = { [weak self] in self?.goBack() }
        dataController = controller
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
        dataController?.stop()
        dataController = nil
        podContainerController = nil
        contentController.suspend()
        let eventsController = objectEventsTarget(for: identity).map { target in
            ObjectDetailRecentEventsController(
                session: session,
                provider: provider,
                resource: target.resource,
                scope: target.scope,
                filter: target.filter
            )
        }
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: objectDetailProvider,
            initialTab: initialTab,
            session: session,
            tableLayoutStore: tableLayoutStore,
            eventsController: eventsController
        )
        controller.onBack = { [weak self] in self?.goBack() }
        controller.onEditMetadata = { [weak self] identity, kind, key in
            self?.onEditMetadata?(identity, kind, key)
        }
        controller.onOpenEvents = { [weak self] identity in
            self?.openEvents(for: identity)
        }
        controller.onContextualShortcutsChanged = { [weak self] in
            self?.onContextualShortcutsChanged?()
        }
        detailController = controller
        replaceMainContent(with: controller)
        view.window?.makeFirstResponder(controller.view)
        onContextualShortcutsChanged?()
    }

    func refreshDetailAfterMetadataMutation(_ identity: ResourceIdentity) {
        detailController?.refreshAfterMetadataMutation(identity)
    }

    private func showResourceList(resume: Bool = true) {
        publishWorkspaceOperation(nil)
        guard detailController != nil || dataController != nil || podContainerController != nil else {
            return
        }
        detailController?.stop()
        dataController?.stop()
        replaceMainContent(with: contentController)
        detailController = nil
        dataController = nil
        podContainerController = nil
        if resume { contentController.resume() }
        view.window?.makeFirstResponder(contentController.tableResponder)
        onContextualShortcutsChanged?()
    }

    private func replaceMainContent(with controller: NSViewController) {
        guard let publisher = controller as? any WorkspaceStatusPublishing else {
            assertionFailure("Workspace content must publish semantic status")
            return
        }
        bindStatusPublisher(publisher, controller: controller)
        rightPaneController.setContent(controller, initialStatus: publisher.workspaceStatus)
    }

    private func bindStatusPublisher<T>(_ controller: T)
    where T: NSViewController, T: WorkspaceStatusPublishing {
        bindStatusPublisher(controller, controller: controller)
    }

    private func bindStatusPublisher(
        _ publisher: any WorkspaceStatusPublishing,
        controller: NSViewController
    ) {
        publisher.onWorkspaceStatusChanged = { [weak self, weak controller] status in
            guard let self, let controller else { return }
            rightPaneController.updateContentStatus(status, from: controller)
        }
    }

    @objc private func goBack() {
        guard let destination = contentController.goBack() else { return }
        restore(destination)
        checkpointRestoration()
    }

    func navigateBack() {
        if let dataController {
            dataController.requestBack()
        } else {
            goBack()
        }
    }

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
        if ObjectDataViewController.supports(identity) {
            displayData(identity)
            return
        }
        let revision = beginObjectOpenTask()
        publishWorkspaceOperation(WorkspaceStatus(
            "Restoring \(identity.name) subresource…",
            busy: true
        ))
        objectOpenTask = Task { [weak self, objectDetailProvider] in
            guard let self else { return }
            defer {
                if objectOpenRevision == revision { objectOpenTask = nil }
            }
            do {
                let detail = try await drillDownDetail(
                    identity,
                    provider: objectDetailProvider
                )
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                publishWorkspaceOperation(nil)
                guard detail.identity == identity,
                    subresourceDestinationIsCurrent(identity),
                    let plan = ResourceDrillDownPlanner.plan(for: detail)
                else { return }
                switch plan {
                case .containers(let pod, let values):
                    displayPodContainers(pod: pod, containers: values)
                case .resource:
                    // Resource-to-resource drill-downs have their own resource
                    // history entry and are never encoded as a local child.
                    showResourceList(resume: false)
                    applyNamespaceScopeSelection(returnState.namespaceSelection)
                    contentController.restoreResource(returnState)
                }
            } catch is CancellationError {
                if objectOpenRevision == revision {
                    publishWorkspaceOperation(nil)
                }
            } catch {
                guard !Task.isCancelled, objectOpenRevision == revision else { return }
                let presentation = UserFacingErrorPresentation(error)
                publishWorkspaceOperation(WorkspaceStatus(
                    presentation.inlineText,
                    severity: .error,
                    toolTip: presentation.detailedText
                ))
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
        publishWorkspaceOperation(nil)
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
                if let pendingNamespaceScope {
                    applyNamespaceScopeSelection(pendingNamespaceScope)
                    self.pendingNamespaceScope = nil
                } else if let previous,
                    let index = namespaceControl.itemTitles.firstIndex(of: previous)
                {
                    namespaceControl.selectItem(at: index)
                } else if !session.defaultNamespace.isEmpty,
                    let index = namespaceControl.itemTitles.firstIndex(of: session.defaultNamespace)
                {
                    namespaceControl.selectItem(at: index)
                }
                rightPaneController.setSupplementalStatus(nil, for: .namespace)
            } catch {
                let presentation = UserFacingErrorPresentation(error)
                rightPaneController.setSupplementalStatus(
                    WorkspaceStatus(
                        "Namespace list unavailable",
                        severity: .warning,
                        toolTip: presentation.detailedText
                    ),
                    for: .namespace
                )
            }
        }
    }

    private func publishWorkspaceOperation(_ status: WorkspaceStatus?) {
        rightPaneController.setSupplementalStatus(status, for: .workspaceOperation)
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
    static let operations = Self("workspace.operations")
    static let forwards = Self("workspace.forwards")
    static let actions = Self("workspace.actions")
}

@MainActor
private final class ResourceSidebarOutlineView: NSOutlineView {
    /// Called after AppKit finishes tracking a resource-row mouse click. The
    /// selection delegate is not called when the clicked row is already
    /// selected, so this seam also covers that otherwise-silent interaction.
    var onResourceMouseSelectionFinished: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedResource = clickedRow >= 0
            && item(atRow: clickedRow) is DiscoveredResource

        super.mouseDown(with: event)

        if clickedResource { onResourceMouseSelectionFinished?() }
    }
}

@MainActor
private final class SidebarResourceRowView: NSTableRowView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    /// Keep the sidebar's selected resource gray even while AppKit marks the
    /// row emphasized during mouse tracking or while the sidebar owns focus.
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
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
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    WorkspaceStatusPublishing
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
    private let outlineView = ResourceSidebarOutlineView()
    private let searchField = NSSearchField()
    private var sections: [Section] = []
    private var allResources: [DiscoveredResource] = []
    private var task: Task<Void, Never>?
    private var taskRevision: UInt64 = 0
    private var pinObserver: UUID?
    private var didChooseInitialResource = false
    private var suppressSelectionCallbacks = false
    var onSelectResource: ((DiscoveredResource) -> Void)?
    var onResourceMouseSelectionFinished: (() -> Void)?
    var onResourcesChanged: (([DiscoveredResource]) -> Void)?
    private(set) var workspaceStatus = WorkspaceStatus(
        "Discovering resource kinds…",
        busy: true
    )
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)?

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
        // A sidebar split-view item otherwise promotes this outline to
        // AppKit's source-list style. That style paints its blue pressed
        // emphasis after row drawing, so use the regular full-width style
        // where our stable gray selection rendering is honored throughout
        // mouse tracking.
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .small
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.autoresizesOutlineColumn = true
        outlineView.onResourceMouseSelectionFinished = { [weak self] in
            self?.onResourceMouseSelectionFinished?()
        }
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

        root.addSubview(searchField)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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
        beginDiscovery(
            refresh: false,
            preserving: nil,
            onComplete: onComplete
        )
    }

    var canRefreshAPIResources: Bool {
        isAuthenticated && task == nil
    }

    @discardableResult
    func refreshAPIResources(preserving resourceID: String?) -> Bool {
        guard canRefreshAPIResources else { return false }
        beginDiscovery(refresh: true, preserving: resourceID, onComplete: nil)
        return true
    }

    private func beginDiscovery(
        refresh: Bool,
        preserving resourceID: String?,
        onComplete: ((Result<[DiscoveredResource], Error>) -> Void)?
    ) {
        guard task == nil else { return }
        publishStatus(WorkspaceStatus(
            refresh ? "Refreshing API resources…" : "Discovering resource kinds…",
            busy: true
        ))
        taskRevision &+= 1
        let revision = taskRevision
        let sessionID = session.sessionID
        task = Task { [weak self, provider] in
            do {
                let discovery = try await provider.discoverResources(
                    sessionID: sessionID,
                    refresh: refresh
                )
                guard !Task.isCancelled, let self, taskRevision == revision else { return }
                task = nil
                let selectedID = resourceID ?? selectedResource()?.id
                allResources = discovery.resources.filter { $0.verbs.contains("list") }
                onResourcesChanged?(allResources)
                rebuildSections(preservingSelectionID: selectedID)
                if discovery.potentiallyIncomplete {
                    publishStatus(WorkspaceStatus(
                        "\(allResources.count.formatted()) resource kinds · discovery incomplete",
                        severity: .warning,
                        toolTip: discovery.warning?.userFacingPresentation.detailedText
                            ?? "Some Kubernetes API groups could not be discovered.",
                        shortText: "discovery incomplete"
                    ))
                } else if let issue = pinStore.loadIssue {
                    publishStatus(WorkspaceStatus(
                        "\(allResources.count.formatted()) kinds · built-in pins in use",
                        severity: .warning,
                        toolTip: issue.localizedDescription,
                        shortText: "built-in pins in use"
                    ))
                } else {
                    publishStatus(WorkspaceStatus(
                        "\(allResources.count.formatted()) resource kinds"
                    ))
                }
                onComplete?(.success(allResources))
            } catch {
                guard !Task.isCancelled, let self, taskRevision == revision else { return }
                task = nil
                let presentation = UserFacingErrorPresentation(error)
                if refresh, !allResources.isEmpty {
                    publishStatus(WorkspaceStatus(
                        "Refresh failed · keeping \(allResources.count.formatted()) resource kinds",
                        severity: .error,
                        toolTip: presentation.detailedText,
                        shortText: "Refresh failed"
                    ))
                } else {
                    publishStatus(WorkspaceStatus(
                        presentation.inlineText,
                        severity: .error,
                        toolTip: presentation.detailedText
                    ))
                }
                onComplete?(.failure(error))
            }
        }
    }

    func stop() {
        taskRevision &+= 1
        task?.cancel()
        task = nil
        isAuthenticated = false
        if let pinObserver {
            pinStore.removeObserver(pinObserver)
            self.pinObserver = nil
        }
    }

    func recover(
        session: OpenedClusterSession,
        onComplete: ((Result<[DiscoveredResource], Error>) -> Void)? = nil
    ) {
        taskRevision &+= 1
        task?.cancel()
        task = nil
        self.session = session
        isAuthenticated = true
        publishStatus(WorkspaceStatus("Reloading discovery…", busy: true))
        start(onComplete: onComplete)
    }

    func installRestoredResource(_ resource: DiscoveredResource) {
        taskRevision &+= 1
        task?.cancel()
        task = nil
        allResources = [resource]
        onResourcesChanged?(allResources)
        publishStatus(WorkspaceStatus(
            "Saved target · waiting for context",
            severity: .warning,
            busy: true
        ))
        rebuildSections()
    }

    func discardRestoredResource() {
        allResources = []
        onResourcesChanged?(allResources)
        rebuildSections()
    }

    @objc private func searchChanged() { rebuildSections() }

    private func publishStatus(_ status: WorkspaceStatus) {
        workspaceStatus = status
        onWorkspaceStatusChanged?(status)
    }

    private func rebuildSections(preservingSelectionID requestedSelectionID: String? = nil) {
        let selectedID = requestedSelectionID ?? selectedResource()?.id
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
        let wasSuppressingSelectionCallbacks = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        outlineView.reloadData()
        outlineView.deselectAll(nil)
        for index in sections.indices
            where sections[index].title != "Custom Resources"
                || !query.isEmpty
                || sections[index].resources.contains(where: { $0.id == selectedID })
        {
            outlineView.expandItem(sections[index])
        }
        if let selectedID, let resource = allResources.first(where: { $0.id == selectedID }) {
            select(resource: resource, notify: false)
        }
        suppressSelectionCallbacks = wasSuppressingSelectionCallbacks
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
        if item is Section {
            let identifier = NSUserInterfaceItemIdentifier("sidebar-section-row")
            return outlineView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? SidebarSectionRowView ?? SidebarSectionRowView(identifier: identifier)
        }
        guard item is DiscoveredResource else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar-resource-row")
        return outlineView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? SidebarResourceRowView ?? SidebarResourceRowView(identifier: identifier)
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
        if !sections.contains(where: {
            $0.resources.contains(where: { $0.id == resource.id })
                && outlineView.isItemExpanded($0)
        }), let section = sections.first(where: {
            $0.resources.contains(where: { $0.id == resource.id })
        }) {
            outlineView.expandItem(section)
        }
        for row in 0..<outlineView.numberOfRows where (outlineView.item(atRow: row) as? DiscoveredResource)?.id == resource.id {
            let wasSuppressingSelectionCallbacks = suppressSelectionCallbacks
            suppressSelectionCallbacks = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressSelectionCallbacks = wasSuppressingSelectionCallbacks
            if notify { onSelectResource?(resource) }
            break
        }
    }
}

private enum ResourceStreamOpenReason: String {
    case sidebarSelection = "sidebar-selection"
    case commandPaletteSelection = "command-palette-selection"
    case resourceDrillDown = "resource-drill-down"
    case namespaceChange = "namespace-change"
    case engineRecovery = "engine-recovery"
    case resumeAfterDetail = "resume-after-detail"
    case programmaticFilter = "programmatic-filter"
    case debouncedFilter = "debounced-filter"
    case committedFilter = "committed-filter"
    case optionalResourceColumns = "optional-resource-columns"
    case loadedColumnConfiguration = "loaded-column-configuration"
    case appliedColumns = "applied-columns"
    case restoration = "restoration"
    case historyRestore = "history-restore"
    case sortChange = "sort-change"
}

private struct PendingResourceStreamOpen {
    var reason: ResourceStreamOpenReason
    var preservingOptionalResourceDiscoveryState: Bool
}

struct ResourceViewportTiming: Sendable {
    static let production = production(metricsRefreshSeconds: 15, overscanScreensPerSide: 10)

    static func production(
        metricsRefreshSeconds: Int,
        overscanScreensPerSide: Int = ResourceViewViewportPlanner.defaultOverscanScreensPerSide
    ) -> ResourceViewportTiming {
        precondition(metricsRefreshSeconds > 0)
        precondition(overscanScreensPerSide >= 0)
        return ResourceViewportTiming(
            scrollDebounce: .milliseconds(80),
            metricInterestRefresh: .seconds(metricsRefreshSeconds),
            overscanScreensPerSide: overscanScreensPerSide
        )
    }

    var scrollDebounce: Duration
    var metricInterestRefresh: Duration
    var overscanScreensPerSide: Int

    init(
        scrollDebounce: Duration,
        metricInterestRefresh: Duration,
        overscanScreensPerSide: Int = ResourceViewViewportPlanner.defaultOverscanScreensPerSide
    ) {
        precondition(scrollDebounce > .zero)
        precondition(metricInterestRefresh > .zero)
        precondition(overscanScreensPerSide >= 0)
        self.scrollDebounce = scrollDebounce
        self.metricInterestRefresh = metricInterestRefresh
        self.overscanScreensPerSide = overscanScreensPerSide
    }
}

struct ResourceCellHighlightTiming: Sendable {
    static let production = ResourceCellHighlightTiming(
        now: { ContinuousClock.now },
        sleep: { delay in
            try await Task.sleep(for: delay)
        }
    )

    var now: @Sendable () -> ContinuousClock.Instant
    var sleep: @Sendable (Duration) async throws -> Void
}

private struct PendingResourceSelectionGesture: Sendable {
    var sequence: UInt64
    var revision: ResourceSelectionRevision
    var gesture: ResourceSelectionGesture
    /// The last absolute row targeted by a numeric gesture. This is separate
    /// from the backend anchor: it identifies the moving edge for Shift-arrow.
    var activeEndpoint: UInt64?
    /// True when this gesture was captured by UID from warm rows and should
    /// keep its local placeholder until the fresh token projection arrives.
    var preservesUIDPlaceholder: Bool
}

private struct DeferredUIDSelectionGesture: Sendable {
    var gesture: ResourceSelectionGesture
}

@MainActor
private final class ResourceSelectionGestureFence {
    private var result: Result<ResourceSelectionState, Error>?
    private var continuations: [CheckedContinuation<ResourceSelectionState, Error>] = []

    func value() async throws -> ResourceSelectionState {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resolve(_ result: Result<ResourceSelectionState, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = self.continuations
        self.continuations.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}

private struct ResourceSelectionProjectionTicket: Hashable, Sendable {
    var token: String
    var revision: ResourceSelectionRevision
    var startIndex: UInt64
    var length: Int
}

private struct ResourceCommandContextCapture {
    var firstResponder: ResponderContext
    var selectionState: ResourceSelectionState?
    var selectionFence: ResourceSelectionGestureFence?
    var fallbackIdentities: [ResourceIdentity]
    var sessionID: String
    var viewID: String
    var gvr: GVR?
    var resourceIsNamespaced: Bool
    var currentRevision: ResourceSelectionRevision?
    var networkActionsAllowed: Bool
}

private struct ResourceSelectionOperationTicket: Equatable, Sendable {
    enum Authority: Equatable, Sendable {
        case token(String)
        case loadedUID(ResourceUID)
    }

    var sessionID: String
    var authority: Authority
}

@MainActor
private final class ResourceListViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate,
    WorkspaceStatusPublishing
{
    private static let autoWidthPolicy = TableColumnAutoWidthPolicy()
    private static let maxPendingOptionalResourceKeys = 256
    private static let maxPendingSelectionGestures = 256
    /// Selector-bearing filters can change the physical LIST/WATCH key. Wait
    /// for typing to stabilize so intermediate tokens do not create a series
    /// of short-lived Kubernetes streams; Return still commits immediately.
    private static let filterStabilityDelay: Duration = .milliseconds(650)
    private static let resourceCacheDiagnosticsEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment[
            "KMGR_RESOURCE_CACHE_DIAGNOSTICS"
        ] else { return false }
        return ["1", "true", "yes"].contains(raw.lowercased())
    }()

    private var session: OpenedClusterSession
    private var isAuthenticated: Bool
    private let provider: any WorkspaceResourceProviding
    private let optionalResourceCatalogProvider: any OptionalResourceCatalogProviding
    private let columnsConfigurationPath: String
    private let columnConfigurationCoordinator: ColumnConfigurationCoordinator
    private let columnsConfigurationLoader: ColumnConfigurationDocumentLoader
    private let viewportTiming: ResourceViewportTiming
    private let cellHighlightTiming: ResourceCellHighlightTiming
    private let tableColumnMutationAllowed: @MainActor () -> Bool
    private let titleLabel = NSTextField(labelWithString: "Resources")
    private let scopeLabel = NSTextField(labelWithString: "All namespaces")
    private let sortLabel = NSTextField(labelWithString: "Unsorted")
    private let filterField = NSSearchField()
    private let filterCompletionPopup = ResourceFilterCompletionPopup()
    private let tableView = ResourceTableView()
    private let scrollView = NSScrollView()
    private struct InlineIssuePresentation: Hashable {
        var toolTip: String?
        var severity: WorkspaceStatus.Severity
    }
    private var inlineIssueState = ResourceListInlineIssueState()
    private var inlineIssuePresentations: [
        ResourceListInlineIssueScope: InlineIssuePresentation
    ] = [:]
    private var freshnessText = "Idle"
    private var freshnessBusy = false
    private var freshnessSeverity: WorkspaceStatus.Severity = .informational
    private(set) var workspaceStatus = WorkspaceStatus("0 objects · 0 selected · Idle")
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)?
    private var model = ResourceTableModel()
    private var rowChangeDetector = ResourceRowChangeDetector(columnDefinitions: [])
    private var cellHighlightStore = ResourceCellHighlightStore()
    private let cellEffectsPolicy = ResourceTableCellEffectsPolicy.systemDefault
    private var cellHighlightRefreshTask: Task<Void, Never>?
    private var cellHighlightRefreshRevision: UInt64 = 0
    private var isChangeDetectionArmed = false
    private var requestedFilterHighlights: [ResourceFilterHighlight] = []
    private var activeFilterHighlights: [ResourceFilterHighlight] = []
    private var generationGate = GenerationSequenceGate()
    private var resource: DiscoveredResource?
    var currentResource: DiscoveredResource? { resource }
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
    private var pendingColumnInstallation: (
        definitions: [ColumnDefinition], preservingCurrentPresentation: Bool
    )?
    private var columnInstallRetryTask: Task<Void, Never>?
    private var pendingStreamOpenAfterColumnInstallation: PendingResourceStreamOpen?
    private var pendingColumnStreamOpenTask: Task<Void, Never>?
    private var serverSchemaByResourceID: [String: ResourceViewSchema] = [:]
    private var provisionalDefaultColumnResourceIDs: Set<String> = []
    private var columnsConfigurationCache = ColumnConfigurationCacheState()
    private var columnsConfigurationLoadTask: Task<Void, Never>?
    private var columnsConfigurationLoadGeneration: UInt64 = 0
    private var columnsConfigurationObserver: UUID?
    private var deferredColumnPresentationByResourceID: [
        String: DeferredColumnPresentationState
    ] = [:]
    var resourceFilterControl: NSControl { filterField }
    private var suppressSortChanges = false
    private var lastStreamContext: ResourceWarmRowContext?
    private var rangeCache: ResourceViewRangeCache?
    private var rangeFetchTask: Task<Void, Never>?
    private var rangeFetchRequests: Set<ResourceViewRangeRequest> = []
    private var rangeFetchTicket: UInt64 = 0
    private var viewportUpdateTask: Task<Void, Never>?
    private var metricInterestUpdateTask: Task<Void, Never>?
    private var metricInterestRefreshTask: Task<Void, Never>?
    private var lastMetricInterest: ResourceMetricInterestRequest?
    private var metricInterestSendTicket: UInt64 = 0
    /// Full backend cardinality exposed to AppKit. Only `presentedTableRange`
    /// has materialized UID/cell rows in `model`.
    private var tableRowsVisible: UInt64 = 0
    private var presentedTableRange: Range<UInt64>?
    private var pendingSelectionTableIndexes: IndexSet?
    /// Authoritative local presentation while UID gestures wait for the first
    /// fresh range and for their resulting token projection.
    private var pendingUIDSelectionTableIndexes: IndexSet?
    private var pendingCommandForLoadingSelection: ResourceTableCommand?
    /// The immutable backend token is the authority for cardinality and
    /// command targets. `model.selectedUIDs` is only its loaded-range
    /// projection for AppKit.
    private var displayedSelectionState: ResourceSelectionState?
    /// A token may continue numeric gestures only while its generation and
    /// index revision still match the current backend ordering.
    private var selectionContinuationToken: String?
    private var selectionContinuationRevision: ResourceSelectionRevision?
    private var committedSelectionEndpoint: UInt64?
    private var committedSelectionEndpointRevision: ResourceSelectionRevision?
    private var activeSelectionEndpoint: UInt64?
    private var activeSelectionEndpointRevision: ResourceSelectionRevision?
    private var pendingSelectionGestures: [PendingResourceSelectionGesture] = []
    private var pendingSelectionGestureHead = 0
    private var nextSelectionGestureSequence: UInt64 = 0
    private var lastEnqueuedSelectionGestureSequence: UInt64?
    private var selectionGestureFences: [UInt64: [ResourceSelectionGestureFence]] = [:]
    private var deferredUIDSelectionGestures: [DeferredUIDSelectionGesture] = []
    private var pendingUIDSelectionGestureSequences: Set<UInt64> = []
    /// Last selection explicitly installed by this controller. AppKit changes
    /// its indexes before the delegate fallback observes accessibility-driven
    /// selection, so a rejected overflow gesture needs this bounded snapshot
    /// to restore the preceding optimistic state exactly.
    private var lastAcceptedAppKitSelection = IndexSet()
    private var selectionGestureTask: Task<Void, Never>?
    private var selectionProjectionTask: Task<Void, Never>?
    private var selectionProjectionTicket: ResourceSelectionProjectionTicket?
    private var selectionCommandTask: Task<Void, Never>?
    private var selectionExpiryTask: Task<Void, Never>?
    private var columnsSelectionTask: Task<Void, Never>?
    /// Selected identities proven to belong to the current complete backend
    /// index. This stays valid while only the retained viewport moves, so an
    /// offscreen selected row is not mislabeled as hidden by the filter.
    private var selectedUIDsKnownInPresentedIndex: Set<ResourceUID> = []
    private var pendingInitialRange: ResourceViewRange?
    private var reconciledRevision: ResourceViewRevision?
    /// Once an exact reconciliation has crossed the retained warm view, later
    /// revisions are ordinary live invalidations and do not need another
    /// reconciliation merely because an earlier range fetch lost a race.
    private var hasReachedInitialReconciliation = false
    /// Revision of the bounded range currently projected into the table.
    /// Keeping this separate from the transport cache lets a presentation-only
    /// invalidation compare rows against the last rendered range and retain
    /// UID-pinned cell effects, while an index/generation change establishes a
    /// fresh baseline.
    private var presentedRangeRevision: ResourceViewRevision?
    private var isRetainingWarmRowsForCurrentStream = false
    private var backendResourceViewStatus: ResourceViewStatus?
    private var retainedRowsLastSynchronizedAt: Date?
    private var pendingScrollAnchor: ScrollAnchor?
    private var pendingSelectionUIDs: Set<ResourceUID>?
    private var restorationCheckpointTask: Task<Void, Never>?
    private var freshnessAgeTask: Task<Void, Never>?
    private var resourceViewStatus: ResourceViewStatus?
    /// Last structured freshness governing warm-row eligibility. Transient
    /// local text such as "Filtering…" must not erase a synchronized row's
    /// provenance; opening its replacement immediately changes this to
    /// `loading` or `resuming`, making an interrupted replacement ineligible.
    private var warmRowRetentionFreshness: ResourceViewStatus.Freshness?
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
    private let resourceCacheLogger = Logger(
        subsystem: Product.bundleIdentifier,
        category: "resource-cache"
    )
    private let tableSignposter = OSSignposter(
        subsystem: PerformanceSignpostCatalog.subsystem,
        category: PerformanceSignpostCatalog.resourceTableCategory
    )
    private var projectionRequestInterval: OSSignpostIntervalState?
    private var projectionRequestGeneration: UInt64?
    var onShowCommandPalette: (() -> Void)?
    var onEnterObject: ((ResourceIdentity) -> Void)?
    var onOpenObject: ((ResourceIdentity, ObjectDetailInitialTab) -> Void)?
    var onOpenEvents: ((ResourceIdentity) -> Void)?
    var onOpenYAMLSnapshot: ((ResourceIdentity) -> Void)?
    var onStartPortForward: ((ResourceIdentity) -> Void)?
    var onShowColumns: ((ResourceColumnsRequest) -> Void)?
    var onOpenLogs: ((LogOpenRequest) -> Void)?
    var onOpenExec: ((PodExecTarget) -> Void)?
    var onConfigureExec: ((PodExecTarget) -> Void)?
    var onOpenNodeShell: ((NodeShellTarget) -> Void)?
    var onConfigureNodeShell: ((NodeShellTarget) -> Void)?
    var onDelete: ((DeleteResourcesRequest) -> Void)?
    var onMutate: ((ResourceIdentity, ResourceMutationWindowController.Mutation) -> Void)?
    var onEditMetadata: ((ResourceIdentity, ResourceMetadataKind) -> Void)?
    var onRestorationChanged: (() -> Void)?
    var onContextualShortcutsChanged: (() -> Void)?

    private func traceResourceCache(
        _ event: @autoclosure () -> String,
        generation loggedGeneration: UInt64? = nil
    ) {
        guard Self.resourceCacheDiagnosticsEnabled else { return }
        let traceViewID = String(viewID.prefix(8))
        let generation = loggedGeneration ?? self.generation
        let message = event()
        resourceCacheLogger.notice(
            "view=\(traceViewID, privacy: .public) generation=\(generation, privacy: .public) \(message, privacy: .public)"
        )
    }

    private func resourceCacheContextDescription(
        _ context: ResourceWarmRowContext?
    ) -> String {
        guard let context else { return "none" }
        return "session:\(resourceCacheSessionTag(context.sessionID)),"
            + "gvr:\(resourceCacheGVRDescription(context.gvr)),"
            + "scope:\(resourceCacheScopeDescription(context.namespaceSelection))"
    }

    private func resourceCacheSessionTag(_ sessionID: String) -> String {
        sessionID.isEmpty ? "none" : String(sessionID.prefix(12))
    }

    private func resourceCacheGVRDescription(_ gvr: GVR) -> String {
        let group = gvr.group.isEmpty ? "core" : gvr.group
        return "\(group)/\(gvr.version)/\(gvr.resource)"
    }

    private func resourceCacheScopeDescription(_ selection: NamespaceSelection) -> String {
        if selection.allNamespaces { return "*" }
        return selection.namespaces.isEmpty
            ? "none" : selection.namespaces.joined(separator: ",")
    }

    private func resourceCacheIdentityDescription(_ identity: ResourceIdentity?) -> String {
        guard let identity else { return "none" }
        let namespace = identity.namespace.isEmpty ? "_cluster" : identity.namespace
        let gvr = GVR(
            group: identity.group,
            version: identity.version,
            resource: identity.resource
        )
        return "\(resourceCacheGVRDescription(gvr)):\(namespace)/\(identity.name)"
    }

    private func resourceCacheDestinationDescription(
        _ destination: WorkspaceDestination?
    ) -> String {
        guard let destination else { return "none" }
        switch destination {
        case .resource(let state):
            return "resource:"
                + resourceCacheGVRDescription(GVR(
                    group: state.group,
                    version: state.version,
                    resource: state.resource
                ))
                + ":scope:\(resourceCacheScopeDescription(state.namespaceSelection))"
        case .object(let identity, _):
            return "object:\(resourceCacheIdentityDescription(identity))"
        case .subresource(let identity, _):
            return "subresource:\(resourceCacheIdentityDescription(identity))"
        }
    }

    private func resourceCacheRejectionDescription(
        _ decision: ResourceWarmRowDecision
    ) -> String {
        var reasons: [String] = []
        if !decision.hasExistingRows { reasons.append("no-visible-rows") }
        if !decision.previousRowsWereSynchronized {
            reasons.append("previous-rows-not-synchronized")
        }
        if !decision.hasPreviousContext { reasons.append("no-previous-context") }
        if decision.hasPreviousContext, !decision.sameSession {
            reasons.append("session-changed")
        }
        if decision.hasPreviousContext, !decision.sameResource {
            reasons.append("resource-changed")
        }
        if decision.hasPreviousContext, !decision.sameNamespaceSelection {
            reasons.append("namespace-scope-changed")
        }
        return reasons.isEmpty ? "none" : reasons.joined(separator: ",")
    }

    private func resourceCacheMessageKind(_ message: ResourceViewMessage) -> String {
        switch message {
        case .schema: "schema"
        case .status: "status"
        case .invalidation: "invalidation"
        case .reconciled: "reconciled"
        case .failure: "failure"
        }
    }

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
        let networkActionsAllowed = displayedSelectionState != nil
            ? (isAuthenticated && resourceCatalogValidated)
            : recoveredResourceTrust.permitsNetworkActions(for: selected)
        func canUse(_ command: ResourceTableCommand) -> Bool {
            guard networkActionsAllowed else { return false }
            if let state = displayedSelectionState {
                return isCommandCompatible(
                    command,
                    selectedCount: state.selectedCount,
                    resource: resource
                )
            }
            return isCommandCompatible(command, with: selected)
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
                canRestart: canUse(.restart),
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
        columnConfigurationCoordinator: ColumnConfigurationCoordinator,
        columnsConfigurationLoader: ColumnConfigurationDocumentLoader,
        viewportTiming: ResourceViewportTiming,
        cellHighlightTiming: ResourceCellHighlightTiming,
        tableColumnMutationAllowed: @escaping @MainActor () -> Bool
    ) {
        self.session = session
        self.isAuthenticated = isAuthenticated
        self.resourceCatalogValidated = isAuthenticated
        self.provider = provider
        self.optionalResourceCatalogProvider = optionalResourceCatalogProvider
        self.columnsConfigurationPath = columnsConfigurationPath
        self.columnConfigurationCoordinator = columnConfigurationCoordinator
        self.columnsConfigurationLoader = columnsConfigurationLoader
        self.viewportTiming = viewportTiming
        self.cellHighlightTiming = cellHighlightTiming
        self.tableColumnMutationAllowed = tableColumnMutationAllowed
        super.init(nibName: nil, bundle: nil)
        columnsConfigurationObserver = columnConfigurationCoordinator.observe {
            [weak self] match, definitions in
            _ = self?.applySavedColumns(definitions, matching: match)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    deinit {
        columnInstallRetryTask?.cancel()
        pendingColumnStreamOpenTask?.cancel()
        let coordinator = columnConfigurationCoordinator
        if let columnsConfigurationObserver {
            Task { @MainActor in
                coordinator.removeObserver(columnsConfigurationObserver)
            }
        }
    }

    override func loadView() {
        let root = NSView()
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        scopeLabel.textColor = .secondaryLabelColor
        sortLabel.textColor = .secondaryLabelColor
        filterField.placeholderString = "Filter resources  /"
        filterField.setAccessibilityLabel("Filter Kubernetes resources")
        filterField.setAccessibilityHelp(
            "Type keywords or structured filters. Use labelSelector or fieldSelector "
                + "for explicit Kubernetes selectors, or column:<id>:<value> for a "
                + "projected column. Tab completes a query prefix or active column ID; "
                + "Return applies the query."
        )
        filterField.delegate = self
        filterCompletionTrigger.setPresenter { [weak self] editor in
            self?.presentFilterCompletions(in: editor)
        }
        filterCompletionPopup.onAccept = { [weak self] index in
            self?.acceptFilterCompletion(at: index)
        }
        filterField.sendsSearchStringImmediately = true
        // The query is structured technical input. Disable language-driven
        // completion/checking; the bounded query catalog below is invoked
        // explicitly and still supports manual Tab/arrow completion.
        filterField.isAutomaticTextCompletionEnabled = false
        // Let the filter use roughly half of the resource surface for long
        // selectors, while yielding first when the status labels need room.
        filterField.setContentHuggingPriority(.init(200), for: .horizontal)
        filterField.setContentCompressionResistancePriority(.init(499), for: .horizontal)

        let columnsButton = NSButton(title: "Columns…", target: self, action: #selector(showColumns))
        columnsButton.bezelStyle = .texturedRounded
        let header = NSStackView(views: [
            titleLabel, scopeLabel, sortLabel, NSView(), filterField, columnsButton,
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
        // Preferred widths are global per exact GVR. Adaptive AppKit widths
        // depend on one window's viewport and must never feed back into that
        // shared layout, so resource tables scroll horizontally instead.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.doubleAction = #selector(enterSelectedObjectFromTable)
        tableView.target = self
        tableView.rowSizeStyle = .medium
        tableView.setAccessibilityLabel("Kubernetes resources")
        tableView.onCommand = { [weak self] command in
            self?.performCommand(command)
        }
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

        root.addSubview(scrollView)
        root.addSubview(filterCompletionPopup)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            filterCompletionPopup.leadingAnchor.constraint(equalTo: filterField.leadingAnchor),
            filterCompletionPopup.trailingAnchor.constraint(equalTo: filterField.trailingAnchor),
            filterCompletionPopup.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 3),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func open(
        resource: DiscoveredResource,
        scope: NamespaceSelection,
        initialFilter: String? = nil,
        reason: ResourceStreamOpenReason
    ) {
        traceResourceCache(
            "event=open_resource reason=\(reason.rawValue) target_gvr="
                + resourceCacheGVRDescription(resourceGVR(for: resource))
                + " target_scope=\(resourceCacheScopeDescription(scope))"
                + " rows=\(model.orderedVisibleUIDs.count)"
                + " previous_destination="
                + resourceCacheDestinationDescription(history.current)
        )
        if case .resource = history.current, var current = navigationState() {
            // A drill-down is a temporary child of the selected object, so
            // Back restores that UID. Explicit sidebar/palette navigation is
            // a new list scope and deliberately leaves no saved selection.
            if reason != .resourceDrillDown {
                current.selectedUIDs = []
            }
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
        openStream(reason: reason)
        publishContextualShortcutsIfChanged()
    }

    func changeNamespaceScope(_ scope: NamespaceSelection) {
        guard self.scope != scope else { return }
        traceResourceCache(
            "event=namespace_change from=\(resourceCacheScopeDescription(self.scope))"
                + " to=\(resourceCacheScopeDescription(scope))"
                + " rows=\(model.orderedVisibleUIDs.count)"
        )
        if case .resource = history.current, var current = navigationState() {
            current.selectedUIDs = []
            history.replaceCurrent(with: .resource(current))
        }
        self.scope = scope
        pendingScrollAnchor = nil
        if var state = navigationState() {
            state.namespaceSelection = scope
            state.selectedUIDs = []
            history.navigate(to: .resource(state))
        }
        if let resource {
            installEffectiveColumns(for: resource)
        }
        openStream(reason: .namespaceChange)
    }

    func stop() {
        restorationCheckpointTask?.cancel()
        restorationCheckpointTask = nil
        columnsConfigurationLoadGeneration &+= 1
        columnsConfigurationLoadTask?.cancel()
        columnsConfigurationLoadTask = nil
        stopFreshnessAgeUpdates()
        suspend()
        // `suspend()` is also used for same-list Details navigation and must
        // retain selection there. `stop()` is terminal and owns cancellation
        // of every token, gesture, projection, command, expiry, and Columns task.
        resetSelectionAuthority()
        clearOptionalResourceOverlay()
    }

    /// Preserve the last compact rows as an explicitly disconnected snapshot.
    /// A new helper generation receives a fresh session and opens a new view;
    /// the stale session is never reused for mutations.
    func engineDidDisconnect() {
        traceResourceCache(
            "event=engine_disconnected rows=\(model.orderedVisibleUIDs.count)"
                + " destination=\(resourceCacheDestinationDescription(history.current))"
        )
        endProjectionRequest(outcome: "engine-disconnected")
        clearTransientCellPresentation()
        filterTask?.cancel()
        filterTask = nil
        discardPendingColumnStreamOpen()
        streamTask?.cancel()
        streamTask = nil
        stopViewportWork()
        resetSelectionAuthority()
        rangeCache = nil
        pendingInitialRange = nil
        reconciledRevision = nil
        hasReachedInitialReconciliation = false
        presentedRangeRevision = nil
        isRetainingWarmRowsForCurrentStream = false
        cancelOptionalResourceDiscovery(selecting: nil)
        generationGate.reset()
        recoveredResourceTrust.requireValidation()
        installFreshnessText("Disconnected", severity: .warning)
        showInlineIssue(
            "The Kubernetes engine restarted. Rows shown here are from the last connected generation.",
            scope: .stream,
            severity: .warning
        )
        updateStatusLine()
    }

    func showDisconnected(_ message: String, toolTip: String? = nil) {
        traceResourceCache(
            "event=rows_cleared cause=show_disconnected"
                + " rows_before=\(model.orderedVisibleUIDs.count)"
        )
        endProjectionRequest(outcome: "disconnected")
        clearTransientCellPresentation()
        discardPendingColumnStreamOpen()
        streamTask?.cancel()
        streamTask = nil
        stopViewportWork()
        resetSelectionAuthority()
        rangeCache = nil
        pendingInitialRange = nil
        reconciledRevision = nil
        hasReachedInitialReconciliation = false
        presentedRangeRevision = nil
        isRetainingWarmRowsForCurrentStream = false
        cancelOptionalResourceDiscovery(selecting: nil)
        model = ResourceTableModel()
        clearSparseTableProjection()
        tableView.reloadData()
        installFreshnessText("Disconnected", severity: .warning)
        showInlineIssue(
            message,
            scope: .stream,
            severity: .warning,
            toolTip: toolTip
        )
        updateStatusLine()
        publishContextualShortcutsIfChanged()
    }

    func recover(
        session: OpenedClusterSession,
        opensCurrentResource: Bool = true
    ) {
        clearTransientCellPresentation()
        let sessionChanged = self.session.sessionID != session.sessionID
        traceResourceCache(
            "event=engine_recovery old_session="
                + resourceCacheSessionTag(self.session.sessionID)
                + " new_session=\(resourceCacheSessionTag(session.sessionID))"
                + " session_changed=\(sessionChanged)"
                + " opens_current=\(opensCurrentResource)"
                + " rows=\(model.orderedVisibleUIDs.count)"
                + " destination=\(resourceCacheDestinationDescription(history.current))"
        )
        self.session = session
        isAuthenticated = true
        resourceCatalogValidated = opensCurrentResource
        history.rebindClusterSessionID(session.sessionID)
        model.rebindClusterSessionID(session.sessionID)
        recoveredResourceTrust.requireValidation()
        publishContextualShortcutsIfChanged()
        if sessionChanged {
            resetSelectionAuthority()
            cancelOptionalResourceDiscovery(selecting: nil)
            clearOptionalResourceOverlay()
            if let resource { installEffectiveColumns(for: resource) }
        }
        if opensCurrentResource, resource != nil {
            openStream(reason: .engineRecovery)
        }
    }

    func suspend() {
        traceResourceCache(
            "event=suspend rows=\(model.orderedVisibleUIDs.count)"
                + " destination=\(resourceCacheDestinationDescription(history.current))"
                + " context=\(resourceCacheContextDescription(lastStreamContext))"
        )
        endProjectionRequest(outcome: "cancelled")
        clearTransientCellPresentation()
        stopFreshnessAgeUpdates()
        filterTask?.cancel()
        filterTask = nil
        discardPendingColumnStreamOpen()
        cancelCurrentStream(reason: "suspend")
        stopViewportWork()
        rangeCache = nil
        pendingInitialRange = nil
        reconciledRevision = nil
        hasReachedInitialReconciliation = false
        presentedRangeRevision = nil
        isRetainingWarmRowsForCurrentStream = false
        cancelOptionalResourceDiscovery(selecting: nil)
    }

    func resume() {
        traceResourceCache(
            "event=resume rows=\(model.orderedVisibleUIDs.count)"
                + " destination=\(resourceCacheDestinationDescription(history.current))"
                + " context=\(resourceCacheContextDescription(lastStreamContext))"
        )
        openStream(reason: .resumeAfterDetail)
    }

    var tableResponder: NSResponder { tableView }

    var currentResourceID: String? { resource?.id }

    var selectedIdentities: [ResourceIdentity] { model.selectedIdentities }

    var currentDestination: WorkspaceDestination? { history.current }

    func captureCommandContext() -> ResourceCommandContextCapture {
        let fallbackIdentities = model.selectedIdentities
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
        let selectionFence: ResourceSelectionGestureFence?
        if selectionGestureTask != nil || hasPendingSelectionGestures,
            let sequence = lastEnqueuedSelectionGestureSequence
        {
            let fence = ResourceSelectionGestureFence()
            selectionGestureFences[sequence, default: []].append(fence)
            selectionFence = fence
        } else {
            selectionFence = nil
        }
        return ResourceCommandContextCapture(
            firstResponder: responder,
            selectionState: selectionFence == nil ? displayedSelectionState : nil,
            selectionFence: selectionFence,
            fallbackIdentities: fallbackIdentities,
            sessionID: session.sessionID,
            viewID: viewID,
            gvr: resource.map {
                GVR(group: $0.group, version: $0.version, resource: $0.resource)
            },
            resourceIsNamespaced: resource?.namespaced ?? false,
            currentRevision: currentSelectionRevision,
            networkActionsAllowed: (displayedSelectionState != nil
                || selectionGestureTask != nil)
                ? (isAuthenticated && resourceCatalogValidated)
                : recoveredResourceTrust.permitsNetworkActions(
                    for: fallbackIdentities
                )
        )
    }

    func materializeCommandContext(
        _ capture: ResourceCommandContextCapture
    ) async throws -> CommandContext {
        let selectionState = try await capture.selectionFence?.value()
            ?? capture.selectionState
        if let selectionState,
            !selectionState.token.isEmpty,
            let gvr = capture.gvr,
            let currentRevision = capture.currentRevision
        {
            guard selectionState.expiresAt.map({ $0 > Date() }) ?? true else {
                throw selectionExpiredIssue()
            }
            return .capturingTokenSelection(
                firstResponder: capture.firstResponder,
                selectionReference: ResourceSelectionDeleteReference(
                    sessionID: capture.sessionID,
                    viewID: capture.viewID,
                    token: selectionState.token,
                    selectedCount: selectionState.selectedCount,
                    gvr: gvr
                ),
                selectionRevision: currentRevision,
                selectionIsNamespaced: capture.resourceIsNamespaced,
                networkActionsAllowed: capture.networkActionsAllowed
            )
        }
        return .capturingResourceSelection(
            firstResponder: capture.firstResponder,
            selectedIdentities: capture.fallbackIdentities,
            hiddenSelectionUIDs: [],
            networkActionsAllowed: capture.networkActionsAllowed
        )
    }

    private func selectionExpiredIssue() -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .validation,
            reason: "SelectionExpired",
            message: "The captured selection expired. Reselect the resources and try again.",
            retryable: false,
            operation: "use captured resource selection"
        )
    }

    func showCommandContextError(_ error: Error) {
        show(error: error, scope: .selection)
    }

    @discardableResult
    func handleEscape() -> Bool {
        resetFilterCompletion()
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
        if (displayedSelectionState?.selectedCount ?? UInt64(model.selectedUIDs.count)) > 0 {
            if let revision = currentSelectionRevision {
                enqueueSelectionGesture(
                    ResourceSelectionGesture(kind: .clear),
                    revision: revision,
                    activeEndpoint: nil
                )
            } else {
                model.clearSelection()
                selectedUIDsKnownInPresentedIndex.removeAll(keepingCapacity: true)
                suppressSelectionCallbacks = true
                tableView.deselectAll(nil)
                lastAcceptedAppKitSelection = []
                suppressSelectionCallbacks = false
                updateStatusLine()
                publishContextualShortcutsIfChanged()
            }
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

    var canCopyCapturedCell: Bool { tableView.canCopyCapturedCell }

    @objc func copyCapturedCell(_ sender: Any?) {
        tableView.copy(sender)
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
            ("Edit Labels…", .editLabels),
            ("Edit Annotations…", .editAnnotations),
        ])
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let copyCellItem = NSMenuItem(
            title: "Copy Cell",
            action: #selector(copyCapturedCell(_:)),
            keyEquivalent: ""
        )
        copyCellItem.target = self
        copyCellItem.isEnabled = canCopyCapturedCell
        menu.addItem(copyCellItem)
        for (title, command) in [
            ("Copy Name", ResourceTableCommand.copyName),
            ("Copy Namespace/Name", .copyNamespacedName),
            ("Copy kubectl Reference", .copyReference),
        ].filter({ isCommandCompatible($0.1) }) {
            add(title, command)
        }
        addGroup([("Delete…", .delete)])
    }

    @objc private func performContextMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ResourceTableCommandBox else { return }
        guard canPerformCommand(box.command, requiringTableFocus: false) else { NSSound.beep(); return }
        performCommand(box.command, requiringTableFocus: false)
    }

    func setFilter(_ value: String) {
        resetFilterCompletion()
        filterRevision &+= 1
        filterTask?.cancel()
        filterField.stringValue = value
        rememberCurrentFilter()
        openStream(reason: .programmaticFilter)
        onRestorationChanged?()
        setFilterShortcutContextActive(true)
        view.window?.makeFirstResponder(filterField)
    }

    func captureNavigationState() -> ResourceNavigationState? {
        navigationState()
    }

    func captureSelectionOperationTicket(
        for identity: ResourceIdentity
    ) -> ResourceSelectionOperationTicket? {
        guard identity.clusterSessionID == session.sessionID else { return nil }
        if let state = displayedSelectionState {
            guard state.selectedCount == 1, !state.token.isEmpty else { return nil }
            return ResourceSelectionOperationTicket(
                sessionID: session.sessionID,
                authority: .token(state.token)
            )
        }
        guard model.selectedIdentities.only?.uid == identity.uid else { return nil }
        return ResourceSelectionOperationTicket(
            sessionID: session.sessionID,
            authority: .loadedUID(identity.uid)
        )
    }

    func selectionOperationTicketIsCurrent(
        _ ticket: ResourceSelectionOperationTicket
    ) -> Bool {
        guard ticket.sessionID == session.sessionID else { return false }
        switch ticket.authority {
        case .token(let token):
            return displayedSelectionState?.token == token
                && displayedSelectionState?.selectedCount == 1
        case .loadedUID(let uid):
            return displayedSelectionState == nil
                && model.selectedIdentities.only?.uid == uid
        }
    }

    func navigateToObject(_ identity: ResourceIdentity, returnState: ResourceNavigationState) {
        traceResourceCache(
            "event=navigate_to_object target="
                + resourceCacheIdentityDescription(identity)
                + " rows=\(model.orderedVisibleUIDs.count)"
        )
        if case .resource = history.current {
            history.replaceCurrent(with: .resource(returnState))
        }
        history.navigate(to: .object(identity, returnState: returnState))
    }

    func navigateToSubresource(
        _ identity: ResourceIdentity,
        returnState: ResourceNavigationState
    ) {
        traceResourceCache(
            "event=navigate_to_subresource target="
                + resourceCacheIdentityDescription(identity)
                + " rows=\(model.orderedVisibleUIDs.count)"
        )
        if case .resource = history.current {
            history.replaceCurrent(with: .resource(returnState))
        }
        history.navigate(to: .subresource(identity, returnState: returnState))
    }

    func goBack() -> WorkspaceDestination? {
        let previous = history.current
        if case .resource = history.current, let current = navigationState() {
            history.replaceCurrent(with: .resource(current))
        }
        let destination = history.goBack()
        traceResourceCache(
            "event=history_back from=\(resourceCacheDestinationDescription(previous))"
                + " to=\(resourceCacheDestinationDescription(destination))"
                + " rows=\(model.orderedVisibleUIDs.count)"
        )
        return destination
    }

    func goForward() -> WorkspaceDestination? {
        let previous = history.current
        if case .resource = history.current, let current = navigationState() {
            history.replaceCurrent(with: .resource(current))
        }
        let destination = history.goForward()
        traceResourceCache(
            "event=history_forward from=\(resourceCacheDestinationDescription(previous))"
                + " to=\(resourceCacheDestinationDescription(destination))"
                + " rows=\(model.orderedVisibleUIDs.count)"
        )
        return destination
    }

    @objc func showCommandPalette() {
        onShowCommandPalette?()
    }

    @objc private func showColumns() {
        guard isAuthenticated, resourceCatalogValidated else { NSSound.beep(); return }
        guard let resource else { return }
        if selectionGestureTask != nil || hasPendingSelectionGestures {
            showColumnsAfterPendingSelection()
            return
        }
        if let selection = displayedSelectionState {
            guard selection.selectedCount == 1 else {
                presentColumns(resource: resource, selectedObject: nil)
                return
            }
            fetchSelectedObjectForColumns(
                resource: resource,
                selection: selection
            )
            return
        }
        presentColumns(
            resource: resource,
            selectedObject: model.selectedIdentities.only
        )
    }

    private func showColumnsAfterPendingSelection() {
        guard columnsSelectionTask == nil else { NSSound.beep(); return }
        let gestureTask = selectionGestureTask
        columnsSelectionTask = Task { @MainActor [weak self] in
            await gestureTask?.value
            guard !Task.isCancelled, let self else { return }
            columnsSelectionTask = nil
            showColumns()
        }
    }

    private func fetchSelectedObjectForColumns(
        resource: DiscoveredResource,
        selection: ResourceSelectionState
    ) {
        guard columnsSelectionTask == nil else { NSSound.beep(); return }
        let provider = self.provider
        let sessionID = session.sessionID
        let viewID = self.viewID
        let resourceID = resource.id
        columnsSelectionTask = Task { @MainActor [weak self, provider] in
            do {
                let page = try await provider.fetchSelectionPage(
                    sessionID: sessionID,
                    viewID: viewID,
                    token: selection.token,
                    offset: 0,
                    limit: 1
                )
                guard !Task.isCancelled, let self else { return }
                columnsSelectionTask = nil
                guard self.session.sessionID == sessionID,
                    self.viewID == viewID,
                    self.resource?.id == resourceID,
                    displayedSelectionState == selection
                else { return }
                guard page.state == selection,
                    page.offset == 0,
                    page.items.count == 1,
                    page.nextOffset == 1,
                    page.done,
                    page.items[0].identity.clusterSessionID == sessionID,
                    page.items[0].identity.group == resource.group,
                    page.items[0].identity.version == resource.version,
                    page.items[0].identity.resource == resource.resource
                else {
                    show(error: selectionPageIssue(
                        reason: "InvalidColumnsSelection",
                        message: "The engine returned an inconsistent single-object selection for the Columns preview."
                    ))
                    return
                }
                clearInlineIssue(scope: .selection)
                presentColumns(
                    resource: resource,
                    selectedObject: page.items[0].identity
                )
            } catch {
                guard !Task.isCancelled, let self else { return }
                columnsSelectionTask = nil
                clearDisplayedSelectionIfExpired(
                    error: error,
                    token: selection.token
                )
                show(error: error, scope: .selection)
            }
        }
    }

    private func presentColumns(
        resource: DiscoveredResource,
        selectedObject: ResourceIdentity?
    ) {
        guard self.resource?.id == resource.id else { return }
        let resourceID = resource.id
        let resourceGVR = resourceGVR(for: resource)
        let optionalColumns = optionalResourceOverlayState.applies(
            sessionID: session.sessionID,
            gvr: resourceGVR
        ) ? optionalResourceOverlayState.overlay.definitions : []
        let discoveredColumns = optionalColumns
            + (serverSchemaByResourceID[resource.id]?.columns ?? [])
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
                selectedObject: selectedObject
            ),
            apply: { [weak self] definitions in
                self?.applyColumns(definitions, forResourceID: resourceID)
            }
        ))
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSControl === filterField else { return }
        (filterField.currentEditor() as? NSTextView)?.configureAsTechnicalTextInput()
        resetFilterCompletion()
        setFilterShortcutContextActive(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSControl === filterField else { return }
        resetFilterCompletion()
        setFilterShortcutContextActive(false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSControl === filterField else { return }
        clearTransientCellPresentation()
        filterRevision &+= 1
        filterTask?.cancel()
        endProjectionRequest(outcome: "filter-revision")
        cancelCurrentStream(reason: "filter-revision")
        hideInlineIssue()
        installFreshnessText(
            model.orderedVisibleUIDs.isEmpty
                ? "Filtering…" : "Filtering… · last good rows",
            busy: true
        )
        rememberCurrentFilter()
        let revision = filterRevision
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: Self.filterStabilityDelay)
            guard !Task.isCancelled, self?.filterRevision == revision else { return }
            self?.openStream(reason: .debouncedFilter)
            self?.onRestorationChanged?()
        }
        let filterEditor = filterField.currentEditor() as? NSTextView
        if let filterEditor {
            if filterCompletionCandidates(in: filterEditor).isEmpty {
                filterCompletionPopup.dismiss()
            }
        } else {
            filterCompletionPopup.dismiss()
        }
        filterCompletionTrigger.textDidChange(
            editor: filterEditor,
            isCurrentEditor: { [weak self] editor in
                self?.filterField.currentEditor() === editor
            },
            hasCandidates: { [weak self] editor in
                guard let self else { return false }
                return !self.filterCompletionCandidates(in: editor).isEmpty
            }
        )
    }

    func handleResourceFilterCommand(_ commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            return filterCompletionPopup.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            return filterCompletionPopup.moveSelection(by: 1)
        case #selector(NSResponder.insertTab(_:)):
            return filterCompletionPopup.acceptSelectedOrFirst()
        case #selector(NSResponder.cancelOperation(_:)):
            guard filterCompletionPopup.isPresented else { return false }
            resetFilterCompletion()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Do not make an explicit Return wait for the typing debounce.
            // It always commits the literal visible query, never a popup row.
            resetFilterCompletion()
            filterTask?.cancel()
            filterTask = nil
            rememberCurrentFilter()
            openStream(reason: .committedFilter)
            onRestorationChanged?()
            setFilterShortcutContextActive(false)
            view.window?.makeFirstResponder(tableView)
            return true
        default:
            return false
        }
    }

    private func presentFilterCompletions(in textView: NSTextView) {
        guard filterField.currentEditor() === textView else { return }
        filterCompletionPopup.present(values: filterCompletionCandidates(in: textView))
    }

    private func acceptFilterCompletion(at index: Int) {
        guard let textView = filterField.currentEditor() as? NSTextView,
            filterField.currentEditor() === textView
        else { return }
        let partialWordRange = textView.rangeForUserCompletion
        let candidates = filterCompletionCandidates(in: textView)
        guard candidates.indices.contains(index) else {
            resetFilterCompletion()
            return
        }
        filterCompletionTrigger.reset()
        filterCompletionPopup.dismiss()
        let candidate = candidates[index]
        guard let acceptance = ResourceFilterCompletionCatalog.acceptedCompletion(
            candidate,
            in: textView.string,
            partialWordRange: partialWordRange
        ) else { return }
        let replacement = NSAttributedString(
            string: acceptance.replacement,
            attributes: textView.typingAttributes
        )
        guard textView.performValidatedReplacement(
            in: partialWordRange,
            with: replacement
        ) else { return }
        textView.setSelectedRange(NSRange(
            location: partialWordRange.location + acceptance.caretUTF16Offset,
            length: 0
        ))
    }

    private func filterCompletionCandidates(in textView: NSTextView) -> [String] {
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound,
            selection.length == 0,
            selection.location > 0,
            !textView.hasMarkedText()
        else { return [] }
        return ResourceFilterCompletionCatalog.completions(
            in: textView.string,
            partialWordRange: textView.rangeForUserCompletion,
            columnIDs: columnIDs
        )
    }

    private func resetFilterCompletion() {
        filterCompletionTrigger.reset()
        filterCompletionPopup.dismiss()
    }

    @objc private func scrollBoundsChanged(_ notification: Notification) {
        scheduleRestorationCheckpoint()
        scheduleViewportUpdate()
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

    private func cancelRangeFetches() {
        rangeFetchTicket &+= 1
        rangeFetchTask?.cancel()
        rangeFetchTask = nil
        if var cache = rangeCache {
            for request in rangeFetchRequests { cache.release(request) }
            rangeCache = cache
        }
        rangeFetchRequests.removeAll(keepingCapacity: true)
    }

    private func stopViewportWork() {
        viewportUpdateTask?.cancel()
        viewportUpdateTask = nil
        cancelRangeFetches()
        stopMetricInterestWork()
        selectionProjectionTask?.cancel()
        selectionProjectionTask = nil
        selectionProjectionTicket = nil
        pendingCommandForLoadingSelection = nil
    }

    private func stopMetricInterestWork() {
        metricInterestSendTicket &+= 1
        metricInterestUpdateTask?.cancel()
        metricInterestUpdateTask = nil
        metricInterestRefreshTask?.cancel()
        metricInterestRefreshTask = nil
        lastMetricInterest = nil
    }

    private func sendMetricInterestIfNeeded(force: Bool = false) {
        guard let request = rangeCache?.metricInterest,
            request.generation == generation
        else {
            stopMetricInterestWork()
            return
        }
        startMetricInterestRefreshLoopIfNeeded()
        if force, metricInterestUpdateTask != nil { return }
        guard force || request != lastMetricInterest else { return }

        lastMetricInterest = request
        metricInterestSendTicket &+= 1
        let ticket = metricInterestSendTicket
        metricInterestUpdateTask?.cancel()
        let provider = self.provider
        metricInterestUpdateTask = Task { @MainActor [weak self, provider] in
            do {
                try await provider.updateMetricInterest(request: request)
            } catch {
                guard !Task.isCancelled else { return }
                self?.traceResourceCache(
                    "event=metric_interest_failed"
                        + " start=\(request.startIndex) length=\(request.length)"
                        + " error=\(String(describing: type(of: error)))"
                )
            }
            guard !Task.isCancelled, let self,
                ticket == metricInterestSendTicket
            else { return }
            metricInterestUpdateTask = nil
        }
    }

    private func startMetricInterestRefreshLoopIfNeeded() {
        guard metricInterestRefreshTask == nil else { return }
        let interval = viewportTiming.metricInterestRefresh
        metricInterestRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                sendMetricInterestIfNeeded(force: true)
            }
        }
    }

    private func clearSparseTableProjection() {
        tableRowsVisible = 0
        presentedTableRange = nil
        pendingSelectionTableIndexes = nil
        pendingCommandForLoadingSelection = nil
        selectedUIDsKnownInPresentedIndex.removeAll(keepingCapacity: true)
    }

    private func deferStreamOpenUntilColumnsAreInstalled(
        reason: ResourceStreamOpenReason,
        preservingOptionalResourceDiscoveryState: Bool
    ) -> Bool {
        guard pendingColumnInstallation != nil else { return false }
        pendingColumnStreamOpenTask?.cancel()
        pendingColumnStreamOpenTask = nil
        pendingStreamOpenAfterColumnInstallation = PendingResourceStreamOpen(
            reason: reason,
            preservingOptionalResourceDiscoveryState:
                preservingOptionalResourceDiscoveryState
        )
        traceResourceCache(
            "event=open_stream_deferred reason=\(reason.rawValue)"
                + " cause=table-column-mutation"
        )
        return true
    }

    private func discardPendingColumnStreamOpen() {
        pendingColumnStreamOpenTask?.cancel()
        pendingColumnStreamOpenTask = nil
        pendingStreamOpenAfterColumnInstallation = nil
    }

    private func schedulePendingColumnStreamOpen() {
        guard pendingStreamOpenAfterColumnInstallation != nil,
            pendingColumnStreamOpenTask == nil
        else { return }
        pendingColumnStreamOpenTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            pendingColumnStreamOpenTask = nil
            guard pendingColumnInstallation == nil,
                let pending = pendingStreamOpenAfterColumnInstallation
            else { return }
            pendingStreamOpenAfterColumnInstallation = nil
            openStream(
                reason: pending.reason,
                preservingOptionalResourceDiscoveryState:
                    pending.preservingOptionalResourceDiscoveryState
            )
        }
    }

    private func openStream(
        reason: ResourceStreamOpenReason,
        preservingOptionalResourceDiscoveryState: Bool = false
    ) {
        guard isAuthenticated, resourceCatalogValidated else {
            traceResourceCache(
                "event=open_stream_blocked reason=\(reason.rawValue)"
                    + " authenticated=\(isAuthenticated)"
                    + " catalog_validated=\(resourceCatalogValidated)"
                    + " rows=\(model.orderedVisibleUIDs.count)"
            )
            return
        }
        guard let resource else {
            traceResourceCache(
                "event=open_stream_blocked reason=\(reason.rawValue)"
                    + " cause=no-resource rows=\(model.orderedVisibleUIDs.count)"
            )
            return
        }
        if deferStreamOpenUntilColumnsAreInstalled(
            reason: reason,
            preservingOptionalResourceDiscoveryState:
                preservingOptionalResourceDiscoveryState
        ) {
            return
        }
        // A direct open after an immediate replacement supersedes any open
        // queued by an earlier deferred replacement in the same run-loop turn.
        discardPendingColumnStreamOpen()
        endProjectionRequest(outcome: "superseded")
        cancelCurrentStream(reason: "open-stream:\(reason.rawValue)")
        clearTransientCellPresentation()
        requestedFilterHighlights = ResourceFilterHighlightParser.parse(
            filterField.stringValue,
            columnIDs: columnIDs
        )
        let nextStreamContext = ResourceWarmRowContext(
            sessionID: session.sessionID,
            gvr: resourceGVR(for: resource),
            namespaceSelection: scope
        )
        let previousStreamContext = lastStreamContext
        // History restoration carries UID truth rather than numeric row
        // positions. A cross-GVR open must invalidate the old selection token,
        // but that reset must not discard the UIDs captured in the destination
        // we are restoring.
        let historySelectionUIDs = reason == .historyRestore
            ? pendingSelectionUIDs : nil
        generation &+= 1
        if previousStreamContext == nextStreamContext {
            // A new generation has a new numeric ordering even when warm rows
            // are retained. Keep the immutable displayed token for UID
            // projection, but require the next modifying gesture to start
            // fresh.
            sealSelectionContinuation()
        } else {
            // Tokens and restored UID projections belong to one exact
            // session/GVR/namespace list. Never carry them into another list,
            // including through history restoration.
            resetSelectionAuthority()
        }
        if reason == .historyRestore {
            pendingSelectionUIDs = historySelectionUIDs
        }
        prepareOptionalResourceDiscovery(
            for: resource,
            preservingOptionalResourceDiscoveryState:
                preservingOptionalResourceDiscoveryState
        )
        if deferStreamOpenUntilColumnsAreInstalled(
            reason: reason,
            preservingOptionalResourceDiscoveryState:
                preservingOptionalResourceDiscoveryState
        ) {
            return
        }
        beginProjectionRequest()
        generationGate.reset()
        let rowsBeforeOpen = model.orderedVisibleUIDs.count
        let previousFreshness = warmRowRetentionFreshness
        let retentionDecision = ResourceWarmRowPolicy.decision(
            existingRowCount: rowsBeforeOpen,
            previousContext: previousStreamContext,
            previousFreshness: previousFreshness,
            nextContext: nextStreamContext
        )
        let sameDataContext = lastStreamContext == nextStreamContext
        let canKeepWarmRows = retentionDecision.canRetain
        traceResourceCache(
            "event=open_stream reason=\(reason.rawValue)"
                + " previous=\(resourceCacheContextDescription(previousStreamContext))"
                + " next=\(resourceCacheContextDescription(nextStreamContext))"
                + " destination=\(resourceCacheDestinationDescription(history.current))"
                + " rows_before=\(rowsBeforeOpen)"
                + " previous_freshness="
                + "\(previousFreshness.map(String.init(describing:)) ?? "none")"
                + " previous_synchronized="
                + "\(retentionDecision.previousRowsWereSynchronized)"
                + " has_previous=\(retentionDecision.hasPreviousContext)"
                + " same_session=\(retentionDecision.sameSession)"
                + " same_resource=\(retentionDecision.sameResource)"
                + " same_scope=\(retentionDecision.sameNamespaceSelection)"
                + " retain=\(canKeepWarmRows)"
                + " rejection=\(resourceCacheRejectionDescription(retentionDecision))"
                + " filter_revision=\(filterRevision)"
                + " filter_length=\(filterField.stringValue.count)"
                + " columns=\(columnIDs.count)"
                + " sorts=\(tableView.sortDescriptors.count)"
        )
        if !sameDataContext {
            hasLastUsableResourceViewStatus = false
        }
        if !canKeepWarmRows {
            traceResourceCache(
                "event=rows_cleared cause=open-stream-retention-rejected"
                    + " reason=\(reason.rawValue)"
                    + " rows_before=\(rowsBeforeOpen)"
                    + " rejection=\(resourceCacheRejectionDescription(retentionDecision))"
            )
            model = ResourceTableModel()
            clearSparseTableProjection()
            tableView.reloadData()
        }
        lastStreamContext = nextStreamContext
        stopViewportWork()
        rangeCache = ResourceViewRangeCache(
            sessionID: session.sessionID,
            viewID: viewID,
            generation: generation
        )
        pendingInitialRange = nil
        reconciledRevision = nil
        hasReachedInitialReconciliation = false
        presentedRangeRevision = nil
        isRetainingWarmRowsForCurrentStream = canKeepWarmRows
        backendResourceViewStatus = nil
        retainedRowsLastSynchronizedAt = canKeepWarmRows
            ? resourceViewStatus?.lastSynchronizedAt : nil
        hideInlineIssue()
        titleLabel.stringValue = resource.kind.isEmpty ? resource.resource : resource.kind
        scopeLabel.stringValue = scope.presentation
        if canKeepWarmRows {
            installResourceViewStatus(ResourceWarmRowPolicy.refreshingStatus(
                backendStatus: nil,
                retainedRowCount: Int(clamping:
                    resourceViewStatus?.rowsVisible
                        ?? UInt64(model.orderedVisibleUIDs.count)
                ),
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
            columnConfigurationVersion: columnsConfigurationCache.persistedVersion ?? "",
            sort: tableView.sortDescriptors.compactMap { descriptor in
                guard let columnID = descriptor.key else { return nil }
                return ResourceSortDescriptor(
                    columnID: columnID,
                    direction: descriptor.ascending ? .ascending : .descending
                )
            },
            stageUntilReconciled: canKeepWarmRows && reason != .resumeAfterDetail
        )
        streamTask = Task { [weak self, provider] in
            do {
                for try await message in provider.streamView(request: request) {
                    guard !Task.isCancelled else { return }
                    self?.receive(message)
                }
                guard !Task.isCancelled else { return }
                self?.traceResourceCache(
                    "event=stream_finished request_generation=\(request.generation)"
                        + " current_generation=\(self?.generation ?? 0)"
                        + " rows=\(self?.model.orderedVisibleUIDs.count ?? 0)",
                    generation: request.generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.traceResourceCache(
                    "event=stream_error request_generation=\(request.generation)"
                        + " error=\(String(describing: type(of: error)))"
                        + " detail=\(error.localizedDescription)",
                    generation: request.generation
                )
                self?.endProjectionRequest(outcome: "failed")
                self?.show(error: error, scope: .stream)
            }
        }
    }

    /// A typed filter revision invalidates projection work immediately; the
    /// debounce delays only creation of its replacement. Duplicate cancellation
    /// calls for the same generation are suppressed because `openStream()` also
    /// crosses this boundary after the debounce.
    private func cancelCurrentStream(reason: String) {
        streamTask?.cancel()
        streamTask = nil
        stopViewportWork()
        let generation = generation
        guard generation > 0, generation != lastCancelledGeneration else {
            traceResourceCache(
                "event=cancel_stream_skipped reason=\(reason)"
                    + " last_cancelled=\(lastCancelledGeneration)",
                generation: generation
            )
            return
        }
        traceResourceCache(
            "event=cancel_stream reason=\(reason) rows=\(model.orderedVisibleUIDs.count)",
            generation: generation
        )
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
        guard cursor.generation == generation else {
            traceResourceCache(
                "event=message_ignored cause=generation-mismatch"
                    + " kind=\(resourceCacheMessageKind(message))"
                    + " message_generation=\(cursor.generation)"
                    + " current_generation=\(generation)"
                    + " sequence=\(cursor.sequence)",
                generation: cursor.generation
            )
            return
        }
        let disposition = generationGate.accept(cursor)
        guard disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence else {
            traceResourceCache(
                "event=message_ignored cause=sequence-gate"
                    + " kind=\(resourceCacheMessageKind(message))"
                    + " sequence=\(cursor.sequence)"
                    + " disposition=\(String(describing: disposition))"
            )
            return
        }
        var shouldPublishContextualShortcuts = false

        switch message {
        case .schema(_, let schema):
            installServerSchema(schema)
        case .status(_, let status):
            traceResourceCache(
                "event=status sequence=\(cursor.sequence)"
                    + " freshness=\(String(describing: status.freshness))"
                    + " backend_rows=\(status.rowsVisible)"
                    + " local_rows=\(model.orderedVisibleUIDs.count)"
                    + " retaining=\(isRetainingWarmRowsForCurrentStream)"
                    + " from_warm_cache=\(status.fromWarmCache)"
                    + " cached_rows=\(rangeCache?.cachedRowCount ?? 0)"
            )
            backendResourceViewStatus = status
            if isRetainingWarmRowsForCurrentStream {
                installResourceViewStatus(ResourceWarmRowPolicy.refreshingStatus(
                    backendStatus: status,
                    retainedRowCount: Int(clamping:
                        resourceViewStatus?.rowsVisible
                            ?? UInt64(model.orderedVisibleUIDs.count)
                    ),
                    lastSynchronizedAt: retainedRowsLastSynchronizedAt
                ))
            } else {
                installResourceViewStatus(status)
            }
            if status.freshness == .watching || status.freshness == .complete {
                clearInlineIssue(scope: .stream)
            }
        case .invalidation(_, let invalidation):
            observeOptionalResourceKeys(
                invalidation.observedOptionalResourceKeys,
                truncated: invalidation.observedOptionalResourceKeysTruncated
            )
            guard var cache = rangeCache else { break }
            let disposition = cache.receive(
                cursor: cursor,
                invalidation: invalidation
            )
            rangeCache = cache
            if disposition != .rejectedStale, disposition != .rejectedInvalid {
                clearInlineIssue(scope: .stream)
            }
            guard disposition != .rejectedStale,
                disposition != .rejectedInvalid,
                disposition != .hintsOnly
            else { break }
            if case .advanced(indexChanged: true) = disposition {
                sealSelectionContinuation()
            }
            cancelRangeFetches()
            pendingInitialRange = nil
            reconciledRevision = nil
            if !isRetainingWarmRowsForCurrentStream {
                setTableRowsVisible(invalidation.rowsVisible)
            }
            if invalidation.rowsVisible == 0 {
                _ = cache.retain(0..<0)
                rangeCache = cache
                let emptyRange = ResourceViewRange(
                    viewID: viewID,
                    revision: invalidation.revision(generation: generation),
                    startIndex: 0,
                    rowsVisible: 0,
                    rows: []
                )
                if isRetainingWarmRowsForCurrentStream {
                    pendingInitialRange = emptyRange
                } else {
                    installFetchedRange(emptyRange, request: nil)
                    endProjectionRequest(outcome: "range-fetched")
                }
                sendMetricInterestIfNeeded()
                break
            }
            rangeCache = cache
            scheduleViewportUpdate(immediate: true)
        case .reconciled(_, let reconciliation):
            let revision = reconciliation.revision(generation: generation)
            let matchesCurrentRevision = rangeCache?.matches(
                cursor: cursor,
                reconciliation: reconciliation
            ) == true
            if matchesCurrentRevision {
                reconciledRevision = revision
                hasReachedInitialReconciliation = true
            }
            if let pendingInitialRange,
                pendingInitialRange.revision == revision,
                matchesCurrentRevision
            {
                self.pendingInitialRange = nil
                installFetchedRange(pendingInitialRange, request: nil)
                isRetainingWarmRowsForCurrentStream = false
                endProjectionRequest(outcome: "reconciled")
                installReconciledStatus(rowCount: reconciliation.rowsVisible)
                shouldPublishContextualShortcuts = true
            } else if reconciliation.rowsVisible == 0,
                matchesCurrentRevision
            {
                isRetainingWarmRowsForCurrentStream = false
                endProjectionRequest(outcome: "reconciled")
                installReconciledStatus(rowCount: reconciliation.rowsVisible)
                shouldPublishContextualShortcuts = true
            }
        case .failure(_, let issue):
            traceResourceCache(
                "event=stream_failure sequence=\(cursor.sequence)"
                    + " category=\(String(describing: issue.category))"
                    + " reason=\(issue.reason)"
                    + " operation=\(issue.operation)"
                    + " local_rows=\(model.orderedVisibleUIDs.count)"
                    + " retaining=\(isRetainingWarmRowsForCurrentStream)"
            )
            endProjectionRequest(outcome: "failed")
            show(error: issue, scope: .stream)
        }
        updateStatusLine()
        if shouldPublishContextualShortcuts {
            publishContextualShortcutsIfChanged()
        }
    }

    private func setTableRowsVisible(_ rowsVisible: UInt64) {
        guard tableRowsVisible != rowsVisible else { return }
        tableRowsVisible = rowsVisible
        if let pendingSelectionTableIndexes {
            let valid = pendingSelectionTableIndexes.filter {
                $0 >= 0 && $0 < tableRowCount
            }
            self.pendingSelectionTableIndexes = valid.isEmpty
                ? nil : IndexSet(valid)
        }
        if let pendingUIDSelectionTableIndexes {
            let valid = pendingUIDSelectionTableIndexes.filter {
                $0 >= 0 && $0 < tableRowCount
            }
            self.pendingUIDSelectionTableIndexes = IndexSet(valid)
        }
        let wasSuppressingSelectionCallbacks = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        tableView.noteNumberOfRowsChanged()
        suppressSelectionCallbacks = wasSuppressingSelectionCallbacks
        if let anchor = pendingScrollAnchor, rowsVisible > 0 {
            let row = min(
                max(0, anchor.priorRowIndex),
                max(0, tableRowCount - 1)
            )
            tableView.scrollRowToVisible(row)
        }
    }

    private var tableRowCount: Int { Int(clamping: tableRowsVisible) }

    private var presentedModelRowOffset: Int {
        Int(clamping: presentedTableRange?.lowerBound ?? 0)
    }

    private func modelIndex(forTableRow tableRow: Int) -> Int? {
        guard tableRow >= 0, let presentedTableRange else { return nil }
        let absoluteIndex = UInt64(tableRow)
        guard presentedTableRange.contains(absoluteIndex) else { return nil }
        let modelIndex = Int(clamping:
            absoluteIndex - presentedTableRange.lowerBound
        )
        return model.orderedVisibleUIDs.indices.contains(modelIndex)
            ? modelIndex : nil
    }

    private func tableRow(forModelIndex modelIndex: Int) -> Int? {
        guard model.orderedVisibleUIDs.indices.contains(modelIndex) else {
            return nil
        }
        let (tableRow, overflow) = presentedModelRowOffset
            .addingReportingOverflow(modelIndex)
        guard !overflow, tableRow >= 0, tableRow < tableRowCount else {
            return nil
        }
        return tableRow
    }

    private func resourceRow(atTableRow tableRow: Int) -> ResourceRow? {
        guard let modelIndex = modelIndex(forTableRow: tableRow) else {
            return nil
        }
        let uid = model.orderedVisibleUIDs[modelIndex]
        return model.rowByUID[uid]
    }

    private func selectedTableRowIndexes() -> IndexSet {
        IndexSet(model.orderedVisibleUIDs.enumerated().compactMap {
            guard model.selectedUIDs.contains($0.element) else { return nil }
            return tableRow(forModelIndex: $0.offset)
        })
    }

    private var currentSelectionRevision: ResourceSelectionRevision? {
        guard let revision = rangeCache?.revision else { return nil }
        let selectionRevision = ResourceSelectionRevision(
            generation: revision.generation,
            indexRevision: revision.index
        )
        return selectionRevision.isValid ? selectionRevision : nil
    }

    /// Numeric input is safe only when the row the user can see belongs to the
    /// same membership/order revision the backend will resolve. Presentation-
    /// only cell refreshes deliberately do not block selection continuation.
    private var interactiveSelectionRevision: ResourceSelectionRevision? {
        guard let revision = currentSelectionRevision,
            presentedRangeRevision?.generation == revision.generation,
            presentedRangeRevision?.index == revision.indexRevision
        else { return nil }
        return revision
    }

    /// Numeric selection state is meaningful only for one exact ordering.
    /// The displayed token deliberately survives so its UID membership can be
    /// projected onto the replacement ordering, but no later gesture may
    /// extend or toggle its old numeric intervals.
    private func sealSelectionContinuation() {
        failSelectionGestureFences(error: selectionScopeChangedIssue())
        selectionContinuationToken = nil
        selectionContinuationRevision = nil
        committedSelectionEndpoint = nil
        committedSelectionEndpointRevision = nil
        activeSelectionEndpoint = nil
        activeSelectionEndpointRevision = nil
        clearPendingSelectionGestures()
        pendingSelectionTableIndexes = nil
        clearDeferredUIDSelection()
        pendingCommandForLoadingSelection = nil
        selectionProjectionTask?.cancel()
        selectionProjectionTask = nil
        selectionProjectionTicket = nil
        restoreAppKitSelectionFromLoadedModel()
    }

    private func resetSelectionAuthority() {
        clearInlineIssue(scope: .selection)
        failSelectionGestureFences(error: selectionScopeChangedIssue())
        selectionGestureTask?.cancel()
        selectionGestureTask = nil
        selectionProjectionTask?.cancel()
        selectionProjectionTask = nil
        selectionCommandTask?.cancel()
        selectionCommandTask = nil
        columnsSelectionTask?.cancel()
        columnsSelectionTask = nil
        selectionExpiryTask?.cancel()
        selectionExpiryTask = nil
        displayedSelectionState = nil
        selectionContinuationToken = nil
        selectionContinuationRevision = nil
        committedSelectionEndpoint = nil
        committedSelectionEndpointRevision = nil
        activeSelectionEndpoint = nil
        activeSelectionEndpointRevision = nil
        clearPendingSelectionGestures()
        selectionProjectionTicket = nil
        pendingSelectionTableIndexes = nil
        clearDeferredUIDSelection()
        pendingCommandForLoadingSelection = nil
        pendingSelectionUIDs = nil
        model.clearSelection()
        selectedUIDsKnownInPresentedIndex.removeAll(keepingCapacity: true)
        let wasSuppressing = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        tableView.deselectAll(nil)
        lastAcceptedAppKitSelection = []
        suppressSelectionCallbacks = wasSuppressing
    }

    private func clearDisplayedSelectionIfExpired(
        error: Error,
        token: String
    ) {
        guard displayedSelectionState?.token == token,
            let issue = error as? ClusterManagerIssue,
            issue.category == .validation,
            (issue.message.localizedCaseInsensitiveContains("selection token expired")
                || issue.message.localizedCaseInsensitiveContains("selection token has expired"))
        else { return }
        clearDisplayedSelection(token: token)
    }

    private func clearDisplayedSelection(token: String) {
        guard displayedSelectionState?.token == token else { return }
        clearInlineIssue(scope: .selection)
        selectionExpiryTask?.cancel()
        selectionExpiryTask = nil
        displayedSelectionState = nil
        selectionContinuationToken = nil
        selectionContinuationRevision = nil
        committedSelectionEndpoint = nil
        committedSelectionEndpointRevision = nil
        activeSelectionEndpoint = nil
        activeSelectionEndpointRevision = nil
        pendingSelectionTableIndexes = nil
        clearDeferredUIDSelection()
        model.clearSelection()
        selectedUIDsKnownInPresentedIndex.removeAll(keepingCapacity: true)
        let wasSuppressing = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        tableView.deselectAll(nil)
        lastAcceptedAppKitSelection = []
        suppressSelectionCallbacks = wasSuppressing
        updateStatusLine()
        publishContextualShortcutsIfChanged()
    }

    private func clearDeferredUIDSelection() {
        deferredUIDSelectionGestures.removeAll(keepingCapacity: true)
        pendingUIDSelectionGestureSequences.removeAll(keepingCapacity: true)
        pendingUIDSelectionTableIndexes = nil
    }

    private func scheduleSelectionExpiry(for state: ResourceSelectionState) {
        selectionExpiryTask?.cancel()
        selectionExpiryTask = nil
        guard let expiresAt = state.expiresAt else { return }
        let token = state.token
        let delaySeconds = max(0, expiresAt.timeIntervalSinceNow)
        let delayNanoseconds = Int64(min(
            delaySeconds * 1_000_000_000,
            Double(Int64.max)
        ))
        selectionExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(delayNanoseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.clearDisplayedSelection(token: token)
        }
    }

    private func scheduleSelectionProjection() {
        selectionProjectionTask?.cancel()
        selectionProjectionTask = nil
        selectionProjectionTicket = nil
        guard let state = displayedSelectionState,
            !state.token.isEmpty,
            let revision = currentSelectionRevision,
            let presentedRangeRevision,
            presentedRangeRevision.generation == revision.generation,
            presentedRangeRevision.index == revision.indexRevision,
            let range = presentedTableRange,
            range.count == model.orderedVisibleUIDs.count
        else { return }

        guard !range.isEmpty else {
            applyLoadedSelectionProjection(
                selected: [],
                anchorOffset: nil,
                projectedRange: range
            )
            return
        }
        let ticket = ResourceSelectionProjectionTicket(
            token: state.token,
            revision: revision,
            startIndex: range.lowerBound,
            length: range.count
        )
        selectionProjectionTicket = ticket
        let provider = self.provider
        let sessionID = session.sessionID
        let viewID = self.viewID
        selectionProjectionTask = Task { @MainActor [weak self, provider] in
            do {
                let projection = try await provider.projectSelectionRange(
                    sessionID: sessionID,
                    viewID: viewID,
                    generation: ticket.revision.generation,
                    indexRevision: ticket.revision.indexRevision,
                    startIndex: ticket.startIndex,
                    length: ticket.length,
                    token: ticket.token
                )
                guard !Task.isCancelled else { return }
                self?.receiveSelectionProjection(projection, ticket: ticket)
            } catch {
                guard !Task.isCancelled else { return }
                self?.receiveSelectionProjectionFailure(error, ticket: ticket)
            }
        }
    }

    private func receiveSelectionProjection(
        _ projection: ResourceSelectionProjection,
        ticket: ResourceSelectionProjectionTicket
    ) {
        guard selectionProjectionTicket == ticket,
            let displayedState = displayedSelectionState,
            displayedState.token == ticket.token,
            currentSelectionRevision == ticket.revision,
            presentedRangeRevision.map({
                $0.generation == ticket.revision.generation
                    && $0.index == ticket.revision.indexRevision
            }) == true,
            presentedTableRange == ticket.startIndex..<(
                ticket.startIndex + UInt64(ticket.length)
            ),
            projection.viewID == viewID,
            projection.revision == ticket.revision,
            projection.startIndex == ticket.startIndex,
            projection.rowsVisible == tableRowsVisible,
            projection.state == displayedState,
            projection.selected.count == ticket.length
        else { return }
        selectionProjectionTask = nil
        selectionProjectionTicket = nil
        // The store returns the token's fixed origin metadata on every
        // projection. It can differ from the newer ordering in `ticket`, but
        // must remain byte-for-byte stable for this immutable token.
        applyLoadedSelectionProjection(
            selected: projection.selected,
            anchorOffset: projection.anchorOffset,
            projectedRange: ticket.startIndex..<(
                ticket.startIndex + UInt64(ticket.length)
            )
        )
        clearInlineIssue(scope: .selection)
        updateStatusLine()
        publishContextualShortcutsIfChanged()
    }

    private func receiveSelectionProjectionFailure(
        _ error: Error,
        ticket: ResourceSelectionProjectionTicket
    ) {
        guard selectionProjectionTicket == ticket else { return }
        selectionProjectionTask = nil
        selectionProjectionTicket = nil
        guard currentSelectionRevision == ticket.revision,
            displayedSelectionState?.token == ticket.token
        else { return }
        if let issue = error as? ClusterManagerIssue,
            issue.isStaleResourceViewRequest
        {
            traceResourceCache(
                "event=selection_projection_ignored cause=revision-race"
                    + " index=\(ticket.revision.indexRevision)"
            )
            return
        }
        clearDisplayedSelectionIfExpired(error: error, token: ticket.token)
        show(error: error, scope: .selection)
    }

    private func applyLoadedSelectionProjection(
        selected: [Bool],
        anchorOffset: Int?,
        projectedRange: Range<UInt64>
    ) {
        guard selected.count == model.orderedVisibleUIDs.count else { return }
        let selectedUIDs = Set(zip(model.orderedVisibleUIDs, selected).compactMap {
            $0.1 ? $0.0 : nil
        })
        let anchorUID = anchorOffset.flatMap {
            model.orderedVisibleUIDs.indices.contains($0)
                ? model.orderedVisibleUIDs[$0] : nil
        }
        model.restoreSelection(uids: selectedUIDs, anchorUID: anchorUID)
        selectedUIDsKnownInPresentedIndex = selectedUIDs

        if pendingUIDSelectionGestureSequences.isEmpty,
            deferredUIDSelectionGestures.isEmpty
        {
            pendingUIDSelectionTableIndexes = nil
        }

        if let pending = pendingSelectionTableIndexes {
            let unresolved = pending.filter {
                guard $0 >= 0 else { return false }
                return !projectedRange.contains(UInt64($0))
            }
            pendingSelectionTableIndexes = unresolved.isEmpty
                ? nil : IndexSet(unresolved)
        }
        var tableSelection = pendingUIDSelectionTableIndexes
            ?? selectedTableRowIndexes()
        if pendingUIDSelectionTableIndexes == nil,
            let pendingSelectionTableIndexes
        {
            tableSelection.formUnion(pendingSelectionTableIndexes)
        }
        let wasSuppressing = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        tableView.selectRowIndexes(tableSelection, byExtendingSelection: false)
        lastAcceptedAppKitSelection = tableView.selectedRowIndexes
        suppressSelectionCallbacks = wasSuppressing
    }

    private func scheduleViewportUpdate(immediate: Bool = false) {
        viewportUpdateTask?.cancel()
        let debounce = viewportTiming.scrollDebounce
        viewportUpdateTask = Task { @MainActor [weak self] in
            do {
                if immediate {
                    await Task.yield()
                } else {
                    try await Task.sleep(for: debounce)
                }
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            viewportUpdateTask = nil
            tableView.layoutSubtreeIfNeeded()
            updateViewportRetention()
        }
    }

    private func updateViewportRetention() {
        guard var cache = rangeCache,
            cache.revision != nil,
            cache.rowsVisible > 0
        else { return }
        let target = ResourceViewViewportPlanner.retainedRange(
            visibleRows: visibleAbsoluteTableRange(),
            rowsVisible: cache.rowsVisible,
            maximumRows: cache.maximumCachedRows,
            overscanScreensPerSide: viewportTiming.overscanScreensPerSide
        )
        guard !target.isEmpty else { return }

        if cache.retainedRange != target {
            cancelRangeFetches()
            guard let refreshed = rangeCache else { return }
            cache = refreshed
        }
        let requests = cache.retain(target)
        rangeCache = cache
        sendMetricInterestIfNeeded()

        if let rows = cache.rows(in: target), let revision = cache.revision {
            acceptCompleteRange(ResourceViewRange(
                viewID: viewID,
                revision: revision,
                startIndex: target.lowerBound,
                rowsVisible: cache.rowsVisible,
                rows: rows
            ), request: nil)
        }
        guard !requests.isEmpty else { return }
        startRangeFetches(requests)
    }

    private func visibleAbsoluteTableRange() -> Range<UInt64> {
        let visible = tableView.rows(in: tableView.visibleRect)
        if visible.location != NSNotFound, visible.length > 0 {
            let lower = min(max(0, visible.location), tableRowCount)
            let upper = min(
                tableRowCount,
                max(lower + 1, visible.location + visible.length)
            )
            return UInt64(lower)..<UInt64(upper)
        }

        let stride = max(1, tableView.rowHeight + tableView.intercellSpacing.height)
        let estimatedRows = max(
            1,
            Int(ceil(scrollView.contentView.bounds.height / stride)) + 1
        )
        let preferred = pendingScrollAnchor?.priorRowIndex ?? 0
        let lower = min(max(0, preferred), max(0, tableRowCount - 1))
        let upper = min(tableRowCount, lower + estimatedRows)
        return UInt64(lower)..<UInt64(max(lower + 1, upper))
    }

    private func startRangeFetches(_ requests: [ResourceViewRangeRequest]) {
        guard !requests.isEmpty else { return }
        cancelRangeFetches()
        rangeFetchTicket &+= 1
        let ticket = rangeFetchTicket
        rangeFetchRequests = Set(requests)
        let provider = self.provider
        rangeFetchTask = Task { @MainActor [weak self, provider] in
            for request in requests {
                guard !Task.isCancelled else { return }
                do {
                    let range = try await provider.fetchViewRange(request: request)
                    guard !Task.isCancelled else { return }
                    self?.receiveFetchedRange(
                        range,
                        request: request,
                        ticket: ticket
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.receiveRangeFetchFailure(
                        error,
                        request: request,
                        ticket: ticket
                    )
                }
            }
            self?.finishRangeFetches(ticket: ticket)
        }
    }

    private func finishRangeFetches(ticket: UInt64) {
        guard ticket == rangeFetchTicket else { return }
        rangeFetchTask = nil
        rangeFetchRequests.removeAll(keepingCapacity: true)
    }

    private func receiveFetchedRange(
        _ range: ResourceViewRange,
        request: ResourceViewRangeRequest,
        ticket: UInt64
    ) {
        guard ticket == rangeFetchTicket, var cache = rangeCache else { return }
        let reception = cache.receive(range, for: request)
        rangeFetchRequests.remove(request)
        guard reception != .rejectedRace else {
            rangeCache = cache
            return
        }
        if reception == .rejectedInvalid {
            rangeCache = cache
            show(
                error: ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "InvalidResourceViewRangeResponse",
                    message: "The engine returned an invalid resource-view range.",
                    operation: "fetch resource view range"
                ),
                scope: .range
            )
            return
        }
        rangeCache = cache
        guard let retained = cache.retainedRange,
            let rows = cache.rows(in: retained),
            let revision = cache.revision
        else { return }
        acceptCompleteRange(ResourceViewRange(
            viewID: viewID,
            revision: revision,
            startIndex: retained.lowerBound,
            rowsVisible: cache.rowsVisible,
            rows: rows
        ), request: request)
    }

    private func acceptCompleteRange(
        _ range: ResourceViewRange,
        request: ResourceViewRangeRequest?
    ) {
        if presentedTableRange == range.startIndex..<(
            range.startIndex + UInt64(range.rows.count)
        ), presentedRangeRevision == range.revision {
            clearInlineIssue(scope: .range)
            return
        }
        if isRetainingWarmRowsForCurrentStream,
            !hasReachedInitialReconciliation,
            reconciledRevision != range.revision
        {
            pendingInitialRange = range
            return
        }
        installFetchedRange(range, request: request)
        if isRetainingWarmRowsForCurrentStream {
            isRetainingWarmRowsForCurrentStream = false
            endProjectionRequest(outcome: "reconciled")
            installReconciledStatus(rowCount: range.rowsVisible)
        } else {
            endProjectionRequest(outcome: "range-fetched")
        }
    }

    private func receiveRangeFetchFailure(
        _ error: Error,
        request: ResourceViewRangeRequest,
        ticket: UInt64
    ) {
        guard ticket == rangeFetchTicket, var cache = rangeCache else { return }
        let requestWasCurrent = cache.containsPendingRequest(request)
        cache.release(request)
        rangeFetchRequests.remove(request)
        rangeCache = cache
        guard requestWasCurrent else { return }
        if let issue = error as? ClusterManagerIssue,
            issue.isStaleResourceViewRequest
        {
            // A pinned range is expected to lose a race when the backing view
            // advances before the control invalidation is delivered. The next
            // invalidation requests the new revision; surfacing this transient
            // transport rejection would leave a stale inline error after the
            // replacement range succeeds.
            traceResourceCache(
                "event=range_fetch_ignored cause=revision-race"
                    + " presentation=\(request.revision.presentation)"
                    + " index=\(request.revision.index)"
            )
            return
        }
        show(error: error, scope: .range)
    }

    private func installFetchedRange(
        _ range: ResourceViewRange,
        request: ResourceViewRangeRequest?
    ) {
        let previousUIDs = Set(model.rowByUID.keys)
        let nextUIDs = Set(range.rows.lazy.map { $0.identity.uid })
        let removedUIDs = previousUIDs.subtracting(nextUIDs)
        let continuesPresentedIndex = presentedRangeRevision.map {
            $0.generation == range.revision.generation
                && $0.index == range.revision.index
        } ?? false
        let canDetectChanges = continuesPresentedIndex
            && isChangeDetectionArmed
        let detectedChanges: [ResourceCellChange] = canDetectChanges
            ? range.rows.flatMap { row in
                rowChangeDetector.changes(
                    from: model.rowByUID[row.identity.uid],
                    to: row
                )
            }
            : []
        var affectedCellAddresses: Set<ResourceCellAddress> = []
        if !continuesPresentedIndex {
            clearTransientCellPresentation(
                keepingRequestedFilterHighlight: true
            )
        } else {
            affectedCellAddresses = cellHighlightStore.removeAll(
                forUIDs: removedUIDs
            )
        }
        var capture = captureUpdate()
        let order = range.rows.map { $0.identity.uid }
        if let pendingScrollAnchor,
            order.contains(pendingScrollAnchor.uid)
        {
            capture.scrollAnchor = ScrollAnchor(
                uid: pendingScrollAnchor.uid,
                pixelOffsetFromTop: pendingScrollAnchor.pixelOffsetFromTop,
                priorRowIndex: 0
            )
        }
        // Backend selection tokens retain offscreen identities. The bounded
        // frontend model must not keep evicted rows alive merely because they
        // were selected in a previous viewport.
        let confirmedRemovals = removedUIDs
        let plan = model.apply(
            ResourceRowBatch(
                upserts: range.rows,
                removedUIDs: confirmedRemovals,
                visibleOrder: .replace(order)
            ),
            capture: capture
        )
        presentedTableRange = range.startIndex..<(
            range.startIndex + UInt64(range.rows.count)
        )
        setTableRowsVisible(range.rowsVisible)
        presentedRangeRevision = range.revision
        let restoredPlan = restoringPendingSelection(
            in: plan,
            chunkIsComplete: true
        )
        if !continuesPresentedIndex {
            selectedUIDsKnownInPresentedIndex.removeAll(keepingCapacity: true)
        } else {
            selectedUIDsKnownInPresentedIndex.formIntersection(
                model.selectedUIDs
            )
        }
        selectedUIDsKnownInPresentedIndex.formUnion(
            order.lazy.filter { self.model.selectedUIDs.contains($0) }
        )
        replayDeferredUIDSelectionGestures(in: range)
        applyTablePlan(restoredPlan)
        pendingScrollAnchor = nil
        if !detectedChanges.isEmpty {
            affectedCellAddresses.formUnion(cellHighlightStore.record(
                detectedChanges,
                at: cellHighlightTiming.now(),
                visibleUIDs: visibleResourceUIDsInViewport()
            ))
        }
        recoveredResourceTrust.receiveSnapshot(
            uids: order,
            first: true,
            // The projected table contains only exact rows returned by this
            // authenticated, revision-pinned range. Rows outside the bounded
            // projection do not need to be materialized to trust these UIDs.
            last: true
        )
        isChangeDetectionArmed = true
        activateRequestedFilterHighlight()
        reloadVisibleCellPresentation(at: affectedCellAddresses)
        scheduleCellHighlightRefresh()
        markBaseViewUsableForOptionalResourceDiscovery()
        clearInlineIssue(scope: .range)
        retainedRowsLastSynchronizedAt = nil
        if !isRetainingWarmRowsForCurrentStream {
            installRangeStatus(rowCount: range.rowsVisible)
        }
        traceResourceCache(
            "event=range_applied start=\(range.startIndex)"
                + " rows=\(range.rows.count) total=\(range.rowsVisible)"
                + " presentation=\(range.revision.presentation)"
                + " index=\(range.revision.index)"
        )
        scheduleSelectionProjection()
        if request != nil { updateStatusLine() }
        runPendingSelectionCommandIfReady()
    }

    private func replayDeferredUIDSelectionGestures(
        in range: ResourceViewRange
    ) {
        guard !deferredUIDSelectionGestures.isEmpty,
            let revision = interactiveSelectionRevision
        else { return }

        var tableRowByUID: [ResourceUID: Int] = [:]
        tableRowByUID.reserveCapacity(range.rows.count)
        for (offset, row) in range.rows.enumerated() {
            let absolute = range.startIndex + UInt64(offset)
            guard absolute <= UInt64(Int.max) else { continue }
            tableRowByUID[row.identity.uid] = Int(absolute)
        }

        // Rebuild the optimistic presentation from UID truth in the fresh
        // bounded range. A moved offscreen target remains selected by the
        // backend but cannot be painted at a guessed numeric position.
        pendingUIDSelectionTableIndexes = selectedTableRowIndexes()
        let deferred = deferredUIDSelectionGestures
        deferredUIDSelectionGestures.removeAll(keepingCapacity: true)
        for item in deferred {
            let targetTableRow = item.gesture.targetUID.flatMap {
                tableRowByUID[$0]
            }
            installDeferredUIDSelectionPlaceholder(
                gesture: item.gesture,
                targetTableRow: targetTableRow
            )
            let accepted = enqueueSelectionGesture(
                item.gesture,
                revision: revision,
                activeEndpoint: targetTableRow.map(UInt64.init),
                preservesUIDPlaceholder: true
            )
            if !accepted {
                clearDeferredUIDSelection()
                restoreAppKitSelectionFromLoadedModel()
                break
            }
        }
    }

    private func runPendingSelectionCommandIfReady() {
        guard selectionGestureTask == nil,
            !hasPendingSelectionGestures,
            let command = pendingCommandForLoadingSelection
        else { return }
        pendingCommandForLoadingSelection = nil
        Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            performCommand(command)
        }
    }

    private func installRangeStatus(rowCount: UInt64) {
        var status = backendResourceViewStatus
            ?? resourceViewStatus
            ?? ResourceViewStatus(freshness: .complete)
        status.rowsVisible = rowCount
        installResourceViewStatus(status)
    }

    private func installReconciledStatus(rowCount: UInt64) {
        installRangeStatus(rowCount: rowCount)
    }

    private func restoringPendingSelection(
        in plan: ResourceTableUpdatePlan,
        chunkIsComplete: Bool
    ) -> ResourceTableUpdatePlan {
        var restoredSelection = false
        if let pendingSelectionUIDs {
            model.restoreSelection(uids: pendingSelectionUIDs)
            if chunkIsComplete { self.pendingSelectionUIDs = nil }
            restoredSelection = true
        }
        guard restoredSelection else { return plan }
        return ResourceTableUpdatePlan(
            selectedRowIndexes: model.orderedVisibleUIDs.enumerated().compactMap {
                model.selectedUIDs.contains($0.element) ? $0.offset : nil
            },
            scrollRestoration: plan.scrollRestoration,
            contentUpdate: plan.contentUpdate
        )
    }

    private func captureUpdate() -> ResourceTableUpdateCapture {
        ResourceTableAppKitProjection.capture(
            model: model,
            from: tableView,
            modelRowOffset: presentedModelRowOffset
        )
    }

    private func globalScrollAnchor() -> ScrollAnchor? {
        guard var anchor = captureUpdate().scrollAnchor else {
            return pendingScrollAnchor
        }
        let (absoluteIndex, overflow) = anchor.priorRowIndex
            .addingReportingOverflow(presentedModelRowOffset)
        guard !overflow else { return nil }
        anchor.priorRowIndex = absoluteIndex
        return anchor
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
            visibleRowCount: tableRowCount,
            to: tableView,
            modelRowOffset: presentedModelRowOffset,
            updateVisibleCell: { [self] view, column, row in
                configureResourceTableCell(
                    in: tableView,
                    tableColumn: column,
                    row: row,
                    reusing: view
                ) === view
            }
        )
        if let pendingUIDSelectionTableIndexes {
            tableView.selectRowIndexes(
                pendingUIDSelectionTableIndexes,
                byExtendingSelection: false
            )
        } else if let pendingSelectionTableIndexes,
            !pendingSelectionTableIndexes.isEmpty
        {
            tableView.selectRowIndexes(
                tableView.selectedRowIndexes.union(
                    pendingSelectionTableIndexes
                ),
                byExtendingSelection: false
            )
        }
        lastAcceptedAppKitSelection = tableView.selectedRowIndexes
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
        let removedFilterEmphasis = !activeFilterHighlights.isEmpty
        isChangeDetectionArmed = false
        activeFilterHighlights = []
        if !keepingRequestedFilterHighlight {
            requestedFilterHighlights = []
        }
        cancelCellHighlightRefresh()
        reloadVisibleCellPresentation(
            at: removedAddresses,
            reloadAllVisibleCells: removedFilterEmphasis
        )
    }

    private func activateRequestedFilterHighlight() {
        guard activeFilterHighlights != requestedFilterHighlights else { return }
        activeFilterHighlights = requestedFilterHighlights
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
        let now = cellHighlightTiming.now()
        for columnIndex in tableView.tableColumns.indices {
            let column = tableView.tableColumns[columnIndex]
            let columnID = tableView.tableColumns[columnIndex].identifier.rawValue
            for rowIndex in visibleRows {
                guard let row = resourceRow(atTableRow: rowIndex) else {
                    continue
                }
                let uid = row.identity.uid
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
            tableRowCount,
            visibleRange.location + visibleRange.length
        )
        guard lowerBound < upperBound else { return [] }
        return IndexSet(integersIn: lowerBound..<upperBound)
    }

    private func visibleResourceUIDsInViewport() -> Set<ResourceUID> {
        Set(visibleTableRowIndexes().compactMap {
            resourceRow(atTableRow: $0)?.identity.uid
        })
    }

    private func scheduleCellHighlightRefresh() {
        cancelCellHighlightRefresh()
        let now = cellHighlightTiming.now()
        let delay = cellEffectsPolicy.usesContinuousFade
            ? cellHighlightStore.nextRefreshDelay(at: now)
            : cellHighlightStore.nextExpiryDelay(at: now)
        guard let delay else { return }

        let revision = cellHighlightRefreshRevision
        let sleep = cellHighlightTiming.sleep
        cellHighlightRefreshTask = Task { @MainActor [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard let self,
                cellHighlightRefreshRevision == revision,
                !Task.isCancelled
            else { return }
            cellHighlightRefreshTask = nil
            let now = cellHighlightTiming.now()
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

    private func show(
        error: Error,
        scope explicitScope: ResourceListInlineIssueScope? = nil
    ) {
        let scope = explicitScope ?? issueScope(for: error)
        if let issue = error as? ClusterManagerIssue,
            issue.isStaleResourceViewRequest
        {
            traceResourceCache(
                "event=issue_ignored cause=revision-race"
                    + " operation=\(issue.operation)"
            )
            return
        }
        let presentation = UserFacingErrorPresentation(error)
        showInlineIssue(
            presentation.inlineText,
            scope: scope,
            toolTip: presentation.detailedText
        )
        guard scope == .stream else { return }
        if let issue = error as? ClusterManagerIssue,
            issue.category == .validation
        {
            let localState = filterField.stringValue.isEmpty
                ? "View configuration error" : "Invalid filter"
            if hasLastUsableResourceViewStatus {
                // The prior projection was cancelled before this replacement
                // was rejected. Its rows remain useful, but they are no longer
                // being watched and must not retain a "Watching" claim.
                installFreshnessText(
                    "\(localState) · last good rows",
                    severity: .error
                )
            } else {
                installFreshnessText(localState, severity: .error)
            }
            return
        }
        installFreshnessText("Disconnected", severity: .error)
    }

    private func issueScope(for error: Error) -> ResourceListInlineIssueScope {
        guard let issue = error as? ClusterManagerIssue else { return .general }
        let operation = issue.operation.lowercased()
        if operation.contains("selection") || issue.reason.contains("Selection") {
            return .selection
        }
        if operation.contains("range")
            || operation.contains("viewport")
            || operation.contains("metric interest")
        {
            return .range
        }
        if operation.contains("column") || operation.contains("filter") {
            return .configuration
        }
        if operation.contains("stream")
            || operation.contains("watch")
            || operation.contains("resource view")
        {
            return .stream
        }
        return .general
    }

    private func installResourceViewStatus(
        _ status: ResourceViewStatus,
        now: Date = Date()
    ) {
        resourceViewStatus = status
        warmRowRetentionFreshness = status.freshness
        if status.freshness != .loading {
            hasLastUsableResourceViewStatus = true
        }
        freshnessText = status.presentation(now: now)
        freshnessBusy = status.showsProgress
        freshnessSeverity = switch status.freshness {
        case .stale, .resuming, .relisting, .reconnecting: .warning
        case .failed: .error
        case .loading, .watching, .complete: .informational
        }
        restartFreshnessAgeUpdatesIfNeeded()
        updateStatusLine()
    }

    private func installFreshnessText(
        _ text: String,
        severity: WorkspaceStatus.Severity = .informational,
        busy: Bool = false
    ) {
        resourceViewStatus = nil
        stopFreshnessAgeUpdates()
        freshnessText = text
        freshnessSeverity = severity
        freshnessBusy = busy
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
                self.freshnessText = status.presentation
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
        scope: ResourceListInlineIssueScope = .general,
        severity: WorkspaceStatus.Severity = .error,
        toolTip: String? = nil
    ) {
        inlineIssueState.show(message, scope: scope)
        inlineIssuePresentations[scope] = InlineIssuePresentation(
            toolTip: toolTip,
            severity: severity
        )
        updateStatusLine()
    }

    private func clearInlineIssue(scope: ResourceListInlineIssueScope) {
        inlineIssueState.hide(scope: scope)
        inlineIssuePresentations.removeValue(forKey: scope)
        updateStatusLine()
    }

    private func hideInlineIssue() {
        inlineIssueState.hide()
        inlineIssuePresentations.removeAll(keepingCapacity: true)
        updateStatusLine()
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
            openStream(
                reason: .optionalResourceColumns,
                preservingOptionalResourceDiscoveryState: true
            )
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
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            let title = tableView.tableColumns.first(where: { $0.identifier.rawValue == key })?.title
                ?? key
            sortLabel.stringValue = "Sorted by \(title) \(descriptor.ascending ? "↑" : "↓")"
        } else {
            sortLabel.stringValue = "Unsorted"
        }
        let selectedCount = displayedSelectionState?.selectedCount
            ?? UInt64(model.selectedUIDs.count)
        let selection = "\(selectedCount.formatted()) selected"
        let authoritativeRowCount = resourceViewStatus?.rowsVisible
            ?? UInt64(model.orderedVisibleUIDs.count)
        var statusParts = [
            "\(authoritativeRowCount.formatted()) objects",
            selection,
        ]
        statusParts.append(freshnessText)
        let text = statusParts.joined(separator: " · ")
        let toolTipParts = [text]
        if let issue = inlineIssueState.message {
            let presentation = inlineIssueState.scope.flatMap {
                inlineIssuePresentations[$0]
            }
            workspaceStatus = WorkspaceStatus(
                "\(issue) · \(freshnessText)",
                severity: presentation?.severity ?? .error,
                toolTip: presentation?.toolTip
            )
        } else {
            workspaceStatus = WorkspaceStatus(
                text,
                severity: freshnessSeverity,
                busy: freshnessBusy,
                toolTip: toolTipParts.joined(separator: "\n")
            )
        }
        onWorkspaceStatusChanged?(workspaceStatus)
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
            let previousProjection = projectionIdentity(
                for: installedColumnDefinitions
            )
            let nextEffective = effectiveColumnDefinitions(
                persistedDefinitions: definitions,
                resource: resource
            )
            let nextProjection = projectionIdentity(
                for: enabledColumnDefinitions(in: nextEffective)
            )
            let previousSort = currentSortPresentation
            provisionalDefaultColumnResourceIDs.remove(resource.id)
            columnDefinitionsByResourceID[resource.id] = definitions
            installColumns(nextEffective)
            if let deferredPresentation {
                applyDeferredColumnPresentation(deferredPresentation)
                if !deferredPresentation.columnMoves.isEmpty
                    || !deferredPresentation.measurementOverrides.isEmpty
                {
                    scheduleCurrentColumnLayoutPersistence()
                }
            }
            if nextProjection != previousProjection
                || currentSortPresentation != previousSort
            {
                openStream(reason: .loadedColumnConfiguration)
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
        let previousProjection = projectionIdentity(for: previousEffective)
        let nextProjection = projectionIdentity(
            for: enabledColumnDefinitions(in: nextEffective)
        )
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
        if nextProjection != previousProjection
            || currentSortPresentation != previousSort
        {
            openStream(reason: .appliedColumns)
        }
        updateStatusLine()
        onRestorationChanged?()
    }

    @discardableResult
    func applySavedColumns(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch
    ) -> Bool {
        columnsConfigurationCache.recordSaved(definitions, matching: match)
        columnDefinitionsByResourceID[match.key] = definitions
        provisionalDefaultColumnResourceIDs.remove(match.key)
        defer {
            if columnsConfigurationCache.document == nil {
                beginColumnsConfigurationLoadIfNeeded()
            }
        }
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
        // AppKit's header view keeps an internal pointer to the column being
        // resized. Removing/recreating NSTableColumn objects during that
        // mouse event can leave the header with a dangling pointer (the crash
        // report shows _resizeCursorForTableColumn: sending `minWidth` to the
        // freed column). Keep logical definitions current, but defer the
        // structural mutation until the event has fully unwound.
        if !tableColumnMutationAllowed() {
            pendingColumnInstallation = (
                definitions: definitions,
                preservingCurrentPresentation: preservingCurrentPresentation
            )
            scheduleDeferredColumnInstallation()
            return
        }
        pendingColumnInstallation = nil
        columnInstallRetryTask?.cancel()
        columnInstallRetryTask = nil
        installColumnsImmediately(
            definitions,
            preservingCurrentPresentation: preservingCurrentPresentation
        )
        schedulePendingColumnStreamOpen()
    }

    private func scheduleDeferredColumnInstallation() {
        guard columnInstallRetryTask == nil else { return }
        columnInstallRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self else { return }
                guard self.tableColumnMutationAllowed() else { continue }
                let pending = self.pendingColumnInstallation
                self.pendingColumnInstallation = nil
                self.columnInstallRetryTask = nil
                if let pending {
                    self.installColumnsImmediately(
                        pending.definitions,
                        preservingCurrentPresentation:
                            pending.preservingCurrentPresentation
                    )
                    self.schedulePendingColumnStreamOpen()
                }
                return
            }
        }
    }

    private func installColumnsImmediately(
        _ definitions: [ColumnDefinition],
        preservingCurrentPresentation: Bool
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
        let selectedRowIndexes = selectedTableRowIndexes()
        columnDefinitionsByID.removeAll(keepingCapacity: true)
        for definition in definitions {
            columnDefinitionsByID[definition.id] = definition
        }
        columnIDs = enabled.map(\.id)

        suppressSortChanges = true
        let wasSuppressingSelectionCallbacks = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        // Removing the final NSTableColumn resets only the clip view's
        // horizontal origin. Preserve it across the structural rebuild.
        let retainedHorizontalScrollOffset = tableView.visibleRect.minX
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
        var projectedSelection = selectedRowIndexes
        if let pendingSelectionTableIndexes {
            projectedSelection.formUnion(pendingSelectionTableIndexes)
        }
        tableView.selectRowIndexes(
            projectedSelection,
            byExtendingSelection: false
        )
        lastAcceptedAppKitSelection = tableView.selectedRowIndexes
        let currentOrigin = tableView.visibleRect.origin
        if abs(currentOrigin.x - retainedHorizontalScrollOffset) >= 0.5 {
            tableView.scroll(NSPoint(
                x: retainedHorizontalScrollOffset,
                y: currentOrigin.y
            ))
            if let scrollView = tableView.enclosingScrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
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
        var definitions = optionalResourceOverlayState.applying(
            to: persistedDefinitions,
            sessionID: session.sessionID,
            gvr: resourceGVR(for: resource)
        )
        if resource.namespaced && !scope.allNamespaces && scope.namespaces.count == 1 {
            for index in definitions.indices where definitions[index].value == "namespace" {
                definitions[index].enabled = false
            }
        }
        return definitions
    }

    private func enabledColumnDefinitions(
        in definitions: [ColumnDefinition]
    ) -> [ColumnDefinition] {
        definitions.filter(\.isEnabled)
    }

    private func projectionIdentity(
        for definitions: [ColumnDefinition]
    ) -> Set<ResourceColumnProjectionIdentity> {
        Set(definitions.lazy.filter(\.isEnabled).map(ResourceColumnProjectionIdentity.init))
    }

    /// Builds the one persisted exact-GVR layout from the current table while
    /// leaving locally hidden definitions (for example Namespace in a
    /// single-namespace scope) in their existing slots. Dragging visible
    /// columns therefore never changes enabled state or silently pushes a
    /// temporarily hidden column to the end.
    private func currentPersistableColumnLayout() -> (
        match: ColumnResourceMatch,
        definitions: [ColumnDefinition]
    )? {
        guard !suppressPresentationCheckpoint,
            columnsConfigurationCache.document != nil,
            let resource
        else { return nil }

        let gvr = resourceGVR(for: resource)
        let persisted = persistedColumnDefinitions(for: resource)
        var definitions = optionalResourceOverlayState.applying(
            to: persisted,
            sessionID: session.sessionID,
            gvr: gvr
        )
        let visibleIDs = tableView.tableColumns.map { $0.identifier.rawValue }
        let visibleIDSet = Set(visibleIDs)
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map {
            ($0.id, $0)
        })
        guard visibleIDs.allSatisfy({ definitionsByID[$0] != nil }) else {
            return nil
        }

        // Reorder only slots occupied by currently visible definitions. This
        // preserves the relative placement of disabled and scope-hidden rows.
        let visibleSlots = definitions.indices.filter {
            visibleIDSet.contains(definitions[$0].id)
        }
        guard visibleSlots.count == visibleIDs.count else { return nil }
        for (slot, id) in zip(visibleSlots, visibleIDs) {
            guard var definition = definitionsByID[id],
                let column = tableView.tableColumns.first(where: {
                    $0.identifier.rawValue == id
                })
            else { return nil }
            definition.width = Double(column.width)
            definitions[slot] = definition
        }

        return (
            ColumnResourceMatch(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            ),
            definitions
        )
    }

    private func scheduleCurrentColumnLayoutPersistence() {
        guard let layout = currentPersistableColumnLayout() else { return }
        columnConfigurationCoordinator.scheduleLayoutSave(
            layout.definitions,
            matching: layout.match
        ) { [weak self] error in
            self?.showInlineIssue(
                "Could not save the shared column layout. \(error.localizedDescription)",
                scope: .configuration,
                severity: .error
            )
        }
    }

    private func installEffectiveColumns(for resource: DiscoveredResource) {
        installColumns(effectiveColumnDefinitions(
            persistedDefinitions: persistedColumnDefinitions(for: resource),
            resource: resource
        ))
    }

    private func defaultColumnDefinitions(for resource: DiscoveredResource) -> [ColumnDefinition] {
        var definitions = NativeColumnCatalog.defaultDefinitions(
            group: resource.group,
            version: resource.version,
            resource: resource.resource,
            namespaced: resource.namespaced,
            showNamespace: scope.allNamespaces || scope.namespaces.count != 1
        )
        guard !NativeColumnCatalog.hasCuratedDefinitions(
            group: resource.group,
            version: resource.version,
            resource: resource.resource
        ), let schema = serverSchemaByResourceID[resource.id], schema.serverTable
        else { return definitions }

        let insertion = definitions.firstIndex(where: { $0.value == "age" })
            ?? definitions.count
        definitions.insert(contentsOf: schema.columns, at: insertion)
        return definitions
    }

    private func installServerSchema(_ schema: ResourceViewSchema) {
        guard let resource else { return }
        if schema.serverTable {
            guard serverSchemaByResourceID[resource.id]?.revision != schema.revision else {
                return
            }
            serverSchemaByResourceID[resource.id] = schema
        } else {
            serverSchemaByResourceID.removeValue(forKey: resource.id)
        }

        let match = ColumnResourceMatch(
            group: resource.group,
            version: resource.version,
            resource: resource.resource
        )
        let configured = columnsConfigurationCache.document?.views.first {
            $0.match == match
        }?.columns
        if let configured {
            columnDefinitionsByResourceID[resource.id] = configured
            installColumns(effectiveColumnDefinitions(
                persistedDefinitions: configured,
                resource: resource
            ), preservingCurrentPresentation: true)
            return
        }

        let defaults = defaultColumnDefinitions(for: resource)
        columnDefinitionsByResourceID[resource.id] = defaults
        installColumns(effectiveColumnDefinitions(
            persistedDefinitions: defaults,
            resource: resource
        ), preservingCurrentPresentation: true)
    }

    private func navigationState() -> ResourceNavigationState? {
        guard let resource else { return nil }
        let deferredPresentation = deferredColumnPresentationByResourceID[resource.id]
        let sort = deferredPresentation?.sort ?? currentSortPresentation
        return ResourceNavigationState(
            group: resource.group, version: resource.version, resource: resource.resource,
            kind: resource.kind, namespaced: resource.namespaced, namespaceSelection: scope,
            filter: filterField.stringValue,
            sortColumnID: sort.first?.columnID,
            sortDescending: !(sort.first?.ascending ?? true),
            selectedUIDs: model.selectedUIDs,
            scrollAnchor: globalScrollAnchor()
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
        let sorts = deferredPresentation?.sort ?? currentSortPresentation
        return ClusterWindowRestorationState(
            contextName: contextName,
            contextReference: contextReference,
            gvr: state.map { GVR(group: $0.group, version: $0.version, resource: $0.resource) },
            namespaceScope: NamespaceScope(scope),
            filter: filterField.stringValue,
            sort: sorts,
            isSidebarVisible: isSidebarVisible,
            scrollAnchor: globalScrollAnchor()
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
        resetFilterCompletion()
        filterField.stringValue = restoration.filter
        filterMemory.remember(restoration.filter, for: resourceGVR(for: restored))
        suppressPresentationCheckpoint = true
        defer { suppressPresentationCheckpoint = false }
        let deferredPresentation = DeferredColumnPresentationState(
            columns: [],
            sort: restoration.sort
        )
        deferColumnPresentationIfNeeded(for: restored, presentation: deferredPresentation)
        configureColumns(for: restored)
        applyDeferredColumnPresentation(deferredPresentation)
        let nav = ResourceNavigationState(
            group: restored.group, version: restored.version, resource: restored.resource,
            kind: restored.kind, namespaced: restored.namespaced,
            namespaceSelection: scope,
            filter: restoration.filter,
            sortColumnID: restoration.sort.first?.columnID,
            sortDescending: !(restoration.sort.first?.ascending ?? true),
            scrollAnchor: restoration.scrollAnchor
        )
        history = WorkspaceNavigationHistory(initial: .resource(nav))
        openStream(reason: .restoration)
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
        stopViewportWork()
        rangeCache = nil
        pendingInitialRange = nil
        reconciledRevision = nil
        hasReachedInitialReconciliation = false
        presentedRangeRevision = nil
        isRetainingWarmRowsForCurrentStream = false
        clearTransientCellPresentation()
        traceResourceCache(
            "event=rows_cleared cause=restored-resource-validation-rejected"
                + " rows_before=\(model.orderedVisibleUIDs.count)"
        )
        model = ResourceTableModel()
        clearSparseTableProjection()
        tableView.reloadData()
        titleLabel.stringValue = "Resources"
        installFreshnessText("Ready")
        if restoration.gvr != nil, discoveredResources.isEmpty {
            showInlineIssue(
                "The saved resource target is not present in authenticated discovery.",
                scope: .configuration,
                severity: .warning
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
        resetFilterCompletion()
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
        traceResourceCache(
            "event=restore_resource target_gvr="
                + resourceCacheGVRDescription(GVR(
                    group: state.group,
                    version: state.version,
                    resource: state.resource
                ))
                + " target_scope="
                + resourceCacheScopeDescription(state.namespaceSelection)
                + " rows=\(model.orderedVisibleUIDs.count)"
                + " current_context="
                + resourceCacheContextDescription(lastStreamContext)
                + " selected_uids=\(state.selectedUIDs.count)"
                + " filter_length=\(state.filter.count)"
        )
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
            columns: [],
            sort: restoredSort
        )
        deferColumnPresentationIfNeeded(for: resource!, presentation: deferredPresentation)
        configureColumns(for: resource!)
        applyDeferredColumnPresentation(deferredPresentation)
        suppressPresentationCheckpoint = false
        openStream(reason: .historyRestore)
    }

    private func installFilterForNavigation(_ filter: String, resourceGVR: GVR) {
        resetFilterCompletion()
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

    func numberOfRows(in tableView: NSTableView) -> Int { tableRowCount }

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
        guard row >= 0, row < tableRowCount else { return nil }
        let columnID = tableColumn.identifier.rawValue
        let alignment = columnDefinitionsByID[columnID]?.alignment ?? .leading
        guard let resourceRow = resourceRow(atTableRow: row) else {
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
                cell: nil,
                placeholder: tableView.column(withIdentifier: tableColumn.identifier) == 0
                    ? "Loading…" : "",
                alignment: textAlignment(alignment)
            )
            return cell
        }
        let uid = resourceRow.identity.uid
        let value = resourceRow[columnID]
        let emphasizedTerms = activeFilterHighlights.compactMap {
            $0.applies(to: columnID) ? $0.term : nil
        }
        let changeHighlight = cellHighlightStore.presentation(
            for: ResourceCellAddress(uid: uid, columnID: columnID),
            at: cellHighlightTiming.now()
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
                emphasizedTerms: emphasizedTerms,
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
            emphasizedTerms: emphasizedTerms,
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
        case .terminating: .systemPurple
        default: .labelColor
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallbacks else { return }
        // Mouse and keyboard gestures normally arrive through
        // ResourceTableView before AppKit mutates its local indexes. Keep this
        // delegate as an accessibility/programmatic fallback, translating the
        // resulting cursor to one backend replace/clear gesture instead of
        // treating AppKit's loaded rows as selection authority.
        let row = tableView.selectedRow
        _ = performSelectionGesture(ResourceTableSelectionGesture(
            row: row >= 0 ? row : nil,
            modifiers: [],
            keyboardDirection: nil
        ))
    }

    private func performSelectionGesture(_ gesture: ResourceTableSelectionGesture) -> Bool {
        let targetIndex: UInt64?
        if let direction = gesture.keyboardDirection {
            let endpoint = interactiveSelectionRevision.flatMap { revision in
                activeSelectionEndpointRevision == revision
                ? activeSelectionEndpoint
                : nil
            }
            let fallback = tableView.selectedRow >= 0
                ? UInt64(tableView.selectedRow) : nil
            guard let current = endpoint ?? fallback, tableRowsVisible > 0 else {
                return false
            }
            if direction == .down {
                targetIndex = min(current + 1, tableRowsVisible - 1)
            } else {
                targetIndex = current > 0 ? current - 1 : 0
            }
        } else {
            targetIndex = gesture.row.flatMap { row in
                guard row >= 0, UInt64(row) < tableRowsVisible else { return nil }
                return UInt64(row)
            }
        }

        guard let revision = interactiveSelectionRevision else {
            // The visible row belongs to the old ordering, but its UID remains
            // trustworthy. Capture that identity and replay it only after the
            // first fresh range makes numeric interaction safe again.
            guard presentedTableRange != nil || tableRowsVisible > 0 else {
                return false
            }
            return deferUIDSelectionGesture(
                gesture,
                targetIndex: targetIndex
            )
        }

        let backendGesture: ResourceSelectionGesture
        if let targetIndex {
            if gesture.modifiers.contains(.shift) {
                backendGesture = ResourceSelectionGesture(
                    kind: .shiftExtend,
                    index: targetIndex,
                    additive: gesture.modifiers.contains(.command)
                )
            } else if gesture.modifiers.contains(.command) {
                backendGesture = ResourceSelectionGesture(
                    kind: .commandToggle,
                    index: targetIndex
                )
            } else {
                backendGesture = ResourceSelectionGesture(
                    kind: .replace,
                    index: targetIndex
                )
            }
        } else {
            backendGesture = ResourceSelectionGesture(kind: .clear)
        }
        _ = enqueueSelectionGesture(
            backendGesture,
            revision: revision,
            activeEndpoint: targetIndex
        )
        return true
    }

    private func deferUIDSelectionGesture(
        _ gesture: ResourceTableSelectionGesture,
        targetIndex: UInt64?
    ) -> Bool {
        guard deferredUIDSelectionGestures.count < Self.maxPendingSelectionGestures else {
            NSSound.beep()
            restoreAppKitSelectionFromLoadedModel()
            return true
        }

        let backendGesture: ResourceSelectionGesture
        if let targetIndex {
            guard targetIndex <= UInt64(Int.max),
                let row = resourceRow(atTableRow: Int(targetIndex))
            else {
                // An unloaded virtual row has no locally authenticated UID, so
                // retaining its stale number would be unsafe.
                NSSound.beep()
                restoreAppKitSelectionFromLoadedModel()
                return true
            }
            let kind: ResourceSelectionGesture.Kind
            if gesture.modifiers.contains(.shift) {
                kind = .shiftExtend
            } else if gesture.modifiers.contains(.command) {
                kind = .commandToggle
            } else {
                kind = .replace
            }
            let anchorUID = kind == .shiftExtend
                ? (displayedSelectionState?.anchor?.uid ?? model.selectionAnchorUID)
                : nil
            backendGesture = ResourceSelectionGesture(
                kind: kind,
                additive: gesture.modifiers.contains([.shift, .command]),
                targetUID: row.identity.uid,
                anchorUID: anchorUID
            )
        } else {
            backendGesture = ResourceSelectionGesture(kind: .clear)
        }

        deferredUIDSelectionGestures.append(DeferredUIDSelectionGesture(
            gesture: backendGesture
        ))
        installDeferredUIDSelectionPlaceholder(
            gesture: backendGesture,
            targetTableRow: targetIndex.flatMap {
                $0 <= UInt64(Int.max) ? Int($0) : nil
            }
        )
        pendingCommandForLoadingSelection = nil
        updateStatusLine()
        return true
    }

    private func installDeferredUIDSelectionPlaceholder(
        gesture: ResourceSelectionGesture,
        targetTableRow: Int?
    ) {
        var indexes = pendingUIDSelectionTableIndexes
            ?? tableView.selectedRowIndexes
        switch gesture.kind {
        case .clear:
            indexes = []
        case .commandAll:
            break
        case .replace:
            indexes = targetTableRow.map(IndexSet.init(integer:)) ?? []
        case .commandToggle:
            if let targetTableRow {
                if indexes.contains(targetTableRow) {
                    indexes.remove(targetTableRow)
                } else {
                    indexes.insert(targetTableRow)
                }
            }
        case .shiftExtend:
            guard let targetTableRow else { break }
            let anchorTableRow = gesture.anchorUID.flatMap { anchorUID in
                model.visibleIndex(for: anchorUID).flatMap(tableRow(forModelIndex:))
            }
            let extensionIndexes: IndexSet
            if let anchorTableRow {
                extensionIndexes = IndexSet(integersIn:
                    min(anchorTableRow, targetTableRow)...max(anchorTableRow, targetTableRow)
                )
            } else {
                extensionIndexes = IndexSet(integer: targetTableRow)
            }
            if gesture.additive {
                indexes.formUnion(extensionIndexes)
            } else {
                indexes = extensionIndexes
            }
        }
        pendingUIDSelectionTableIndexes = indexes
        let wasSuppressing = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        lastAcceptedAppKitSelection = indexes
        suppressSelectionCallbacks = wasSuppressing
        if let targetTableRow { tableView.scrollRowToVisible(targetTableRow) }
    }

    @discardableResult
    private func enqueueSelectionGesture(
        _ gesture: ResourceSelectionGesture,
        revision: ResourceSelectionRevision,
        activeEndpoint: UInt64?,
        preservesUIDPlaceholder: Bool = false
    ) -> Bool {
        guard pendingSelectionGestureCount < Self.maxPendingSelectionGestures else {
            // Consume overflow without allowing AppKit's delegate-first
            // accessibility fallback to publish a selection the backend will
            // never serialize. The active endpoint and token remain untouched.
            NSSound.beep()
            let wasSuppressing = suppressSelectionCallbacks
            suppressSelectionCallbacks = true
            tableView.selectRowIndexes(
                lastAcceptedAppKitSelection,
                byExtendingSelection: false
            )
            suppressSelectionCallbacks = wasSuppressing
            return false
        }
        pendingCommandForLoadingSelection = nil
        nextSelectionGestureSequence &+= 1
        if nextSelectionGestureSequence == 0 { nextSelectionGestureSequence = 1 }
        let sequence = nextSelectionGestureSequence
        lastEnqueuedSelectionGestureSequence = sequence
        pendingSelectionGestures.append(PendingResourceSelectionGesture(
            sequence: sequence,
            revision: revision,
            gesture: gesture,
            activeEndpoint: activeEndpoint,
            preservesUIDPlaceholder: preservesUIDPlaceholder
        ))
        if preservesUIDPlaceholder {
            pendingUIDSelectionGestureSequences.insert(sequence)
        }
        if let activeEndpoint {
            activeSelectionEndpoint = activeEndpoint
            activeSelectionEndpointRevision = revision
        } else if gesture.kind == .clear || gesture.kind == .commandAll {
            activeSelectionEndpoint = nil
            activeSelectionEndpointRevision = nil
        }
        if !preservesUIDPlaceholder {
            installPendingSelectionPlaceholder(
                gesture: gesture,
                targetIndex: activeEndpoint
            )
        }
        startSelectionGestureQueueIfNeeded()
        updateStatusLine()
        return true
    }

    private func installPendingSelectionPlaceholder(
        gesture: ResourceSelectionGesture,
        targetIndex: UInt64?
    ) {
        let wasSuppressing = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        defer { suppressSelectionCallbacks = wasSuppressing }
        switch gesture.kind {
        case .clear:
            pendingSelectionTableIndexes = nil
            tableView.deselectAll(nil)
            lastAcceptedAppKitSelection = []
        case .commandAll:
            // Never materialize an IndexSet for the complete backend table.
            // Loaded membership is installed by the bounded projection RPC.
            break
        case .replace, .commandToggle, .shiftExtend:
            guard let targetIndex, targetIndex <= UInt64(Int.max) else { return }
            let row = Int(targetIndex)
            if gesture.kind == .replace {
                pendingSelectionTableIndexes = nil
            }
            if modelIndex(forTableRow: row) == nil {
                pendingSelectionTableIndexes = IndexSet(integer: row)
            }
            var indexes = tableView.selectedRowIndexes
            switch gesture.kind {
            case .replace:
                indexes = IndexSet(integer: row)
            case .commandToggle:
                if indexes.contains(row) { indexes.remove(row) } else { indexes.insert(row) }
            case .shiftExtend:
                // The backend anchor owns the true (potentially enormous)
                // range. Highlight only the moving edge until projection.
                indexes.insert(row)
            case .commandAll, .clear:
                break
            }
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            lastAcceptedAppKitSelection = tableView.selectedRowIndexes
            tableView.scrollRowToVisible(row)
            if modelIndex(forTableRow: row) == nil {
                scheduleViewportUpdate(immediate: true)
            }
        }
    }

    private func startSelectionGestureQueueIfNeeded() {
        guard selectionGestureTask == nil, hasPendingSelectionGestures else {
            return
        }
        let provider = self.provider
        selectionGestureTask = Task { @MainActor [weak self, provider] in
            guard let self else { return }
            while !Task.isCancelled,
                let pending = popPendingSelectionGesture()
            {
                guard currentSelectionRevision == pending.revision else {
                    discardSelectionPlaceholder(for: pending)
                    pendingUIDSelectionGestureSequences.remove(pending.sequence)
                    resolveSelectionGestureFences(
                        sequence: pending.sequence,
                        result: .failure(selectionScopeChangedIssue())
                    )
                    continue
                }
                var previousToken = usableSelectionContinuationToken(
                    for: pending.revision
                )
                if previousToken.isEmpty,
                    pending.preservesUIDPlaceholder,
                    pending.gesture.targetUID != nil,
                    let displayed = displayedSelectionState,
                    displayed.expiresAt.map({ $0 > Date() }) ?? true
                {
                    // The engine accepts this predecessor only because the
                    // queued gesture carries stable UIDs; it rebases selected
                    // membership and the anchor without reusing old numbers.
                    previousToken = displayed.token
                }
                do {
                    let state = try await provider.applySelectionGesture(
                        sessionID: session.sessionID,
                        viewID: viewID,
                        generation: pending.revision.generation,
                        indexRevision: pending.revision.indexRevision,
                        previousToken: previousToken,
                        gesture: pending.gesture
                    )
                    guard !Task.isCancelled else { return }
                    receiveSelectionGesture(state, pending: pending)
                    resolveSelectionGestureFences(
                        sequence: pending.sequence,
                        result: .success(state)
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    receiveSelectionGestureFailure(error, pending: pending)
                    failSelectionGestureFences(
                        fromSequence: pending.sequence,
                        error: error
                    )
                }
            }
            guard !Task.isCancelled else { return }
            selectionGestureTask = nil
            runPendingSelectionCommandIfReady()
        }
    }

    private func receiveSelectionGesture(
        _ state: ResourceSelectionState,
        pending: PendingResourceSelectionGesture
    ) {
        guard !state.token.isEmpty, state.revision == pending.revision else {
            discardSelectionPlaceholder(for: pending)
            pendingUIDSelectionGestureSequences.remove(pending.sequence)
            return
        }
        pendingUIDSelectionGestureSequences.remove(pending.sequence)
        clearInlineIssue(scope: .selection)
        displayedSelectionState = state
        scheduleSelectionExpiry(for: state)
        if currentSelectionRevision == pending.revision {
            selectionContinuationToken = state.token
            selectionContinuationRevision = pending.revision
            committedSelectionEndpoint = pending.activeEndpoint
            committedSelectionEndpointRevision = pending.activeEndpoint == nil
                ? nil : pending.revision
        } else {
            selectionContinuationToken = nil
            selectionContinuationRevision = nil
        }
        scheduleSelectionProjection()
        updateStatusLine()
        publishContextualShortcutsIfChanged()
    }

    private func receiveSelectionGestureFailure(
        _ error: Error,
        pending: PendingResourceSelectionGesture
    ) {
        discardSelectionPlaceholder(for: pending)
        clearPendingSelectionGestures()
        pendingSelectionTableIndexes = nil
        clearDeferredUIDSelection()
        pendingCommandForLoadingSelection = nil
        if committedSelectionEndpointRevision == pending.revision {
            activeSelectionEndpoint = committedSelectionEndpoint
            activeSelectionEndpointRevision = committedSelectionEndpointRevision
        } else {
            activeSelectionEndpoint = nil
            activeSelectionEndpointRevision = nil
        }
        restoreAppKitSelectionFromLoadedModel()
        scheduleSelectionProjection()
        guard currentSelectionRevision == pending.revision else { return }
        if pending.preservesUIDPlaceholder,
            let issue = error as? ClusterManagerIssue,
            issue.category == .notFound
        {
            // The UID (or Shift anchor) disappeared in the fresh ordering.
            // Clearing the optimistic selection is the requested outcome, not
            // an actionable backend error.
            return
        }
        if let issue = error as? ClusterManagerIssue,
            issue.isStaleResourceViewRequest
        {
            traceResourceCache(
                "event=selection_gesture_ignored cause=revision-race"
                    + " index=\(pending.revision.indexRevision)"
            )
            return
        }
        show(error: error, scope: .selection)
    }

    private func discardSelectionPlaceholder(
        for pending: PendingResourceSelectionGesture
    ) {
        if pending.preservesUIDPlaceholder { return }
        guard let target = pending.activeEndpoint,
            target <= UInt64(Int.max),
            var placeholders = pendingSelectionTableIndexes
        else { return }
        placeholders.remove(Int(target))
        pendingSelectionTableIndexes = placeholders.isEmpty ? nil : placeholders
    }

    private var hasPendingSelectionGestures: Bool {
        pendingSelectionGestureHead < pendingSelectionGestures.count
    }

    private var pendingSelectionGestureCount: Int {
        pendingSelectionGestures.count - pendingSelectionGestureHead
    }

    private func popPendingSelectionGesture() -> PendingResourceSelectionGesture? {
        guard hasPendingSelectionGestures else {
            clearPendingSelectionGestures()
            return nil
        }
        let gesture = pendingSelectionGestures[pendingSelectionGestureHead]
        pendingSelectionGestureHead += 1
        if pendingSelectionGestureHead == pendingSelectionGestures.count {
            clearPendingSelectionGestures()
        } else if pendingSelectionGestureHead >= 64,
            pendingSelectionGestureHead * 2 >= pendingSelectionGestures.count
        {
            pendingSelectionGestures.removeFirst(pendingSelectionGestureHead)
            pendingSelectionGestureHead = 0
        }
        return gesture
    }

    private func clearPendingSelectionGestures() {
        pendingSelectionGestures.removeAll(keepingCapacity: true)
        pendingSelectionGestureHead = 0
    }

    private func resolveSelectionGestureFences(
        sequence: UInt64,
        result: Result<ResourceSelectionState, Error>
    ) {
        let fences = selectionGestureFences.removeValue(forKey: sequence) ?? []
        for fence in fences { fence.resolve(result) }
    }

    private func failSelectionGestureFences(
        fromSequence: UInt64 = 0,
        error: Error
    ) {
        let sequences = selectionGestureFences.keys.filter { $0 >= fromSequence }
        for sequence in sequences {
            resolveSelectionGestureFences(
                sequence: sequence,
                result: .failure(error)
            )
        }
    }

    private func selectionScopeChangedIssue() -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .validation,
            reason: "SelectionScopeChanged",
            message: "The resource view changed before the selection was captured. Reselect the resources and try again.",
            retryable: false,
            operation: "capture resource selection"
        )
    }

    private func usableSelectionContinuationToken(
        for revision: ResourceSelectionRevision
    ) -> String {
        guard selectionContinuationRevision == revision,
            let token = selectionContinuationToken,
            displayedSelectionState?.token == token,
            displayedSelectionState?.expiresAt.map({ $0 > Date() }) ?? true
        else {
            selectionContinuationToken = nil
            selectionContinuationRevision = nil
            return ""
        }
        return token
    }

    private func restoreAppKitSelectionFromLoadedModel() {
        var indexes = pendingUIDSelectionTableIndexes
            ?? selectedTableRowIndexes()
        if pendingUIDSelectionTableIndexes == nil,
            let pendingSelectionTableIndexes
        {
            indexes.formUnion(pendingSelectionTableIndexes)
        }
        let wasSuppressing = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        lastAcceptedAppKitSelection = tableView.selectedRowIndexes
        suppressSelectionCallbacks = wasSuppressing
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
        openStream(reason: .sortChange)
        onRestorationChanged?()
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        updateDeferredColumnOrderFromMove(notification)
        scheduleCurrentColumnLayoutPersistence()
        scheduleRestorationCheckpoint()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        updateDeferredColumnMeasurementsFromCurrentTable(notification)
        scheduleCurrentColumnLayoutPersistence()
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
        let visibleModelRows = visibleTableRowIndexes().compactMap {
            modelIndex(forTableRow: $0)
        }
        let visibleRange: Range<Int>? = visibleModelRows.isEmpty
            ? nil
            : visibleModelRows.first!..<(visibleModelRows.last! + 1)

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
        performCommand(.open, requiringTableFocus: false)
    }

    @objc private func enterSelectedObjectFromTable() {
        performCommand(.enter, requiringTableFocus: false)
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
            guard let identity = selected.only else { return }
            onOpenEvents?(identity)
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
                identity.group.isEmpty, identity.version == "v1"
            else { NSSound.beep(); return }
            switch identity.resource {
            case "pods": onOpenExec?(PodExecTarget(pod: identity))
            case "nodes": onOpenNodeShell?(NodeShellTarget(node: identity))
            default: NSSound.beep()
            }
        case .configureExec:
            guard let identity = selected.only,
                identity.group.isEmpty, identity.version == "v1"
            else { NSSound.beep(); return }
            switch identity.resource {
            case "pods": onConfigureExec?(PodExecTarget(pod: identity))
            case "nodes": onConfigureNodeShell?(NodeShellTarget(node: identity))
            default: NSSound.beep()
            }
        case .selectAll:
            guard let revision = interactiveSelectionRevision else { return }
            enqueueSelectionGesture(
                ResourceSelectionGesture(kind: .commandAll),
                revision: revision,
                activeEndpoint: nil
            )
        case .delete:
            let hidden = hiddenSelectionUIDs ?? Set(
                selected.lazy.map(\.uid).filter {
                    !self.selectedUIDsKnownInPresentedIndex.contains($0)
                }
            )
            let targets = selected.map { identity in
                ResourceDeleteTarget(
                    identity: identity,
                    hiddenByFilter: hidden.contains(identity.uid)
                )
            }
            guard !targets.isEmpty else { NSSound.beep(); return }
            onDelete?(.explicit(targets))
        case .scale:
            guard let identity = selected.only else { return }
            onMutate?(identity, .scale)
        case .restart:
            guard let identity = selected.only else { return }
            onMutate?(identity, .rolloutRestart)
        case .editLabels:
            guard let identity = selected.only else { return }
            onEditMetadata?(identity, .labels)
        case .editAnnotations:
            guard let identity = selected.only else { return }
            onEditMetadata?(identity, .annotations)
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
            let current = activeSelectionEndpointRevision == currentSelectionRevision
                ? activeSelectionEndpoint.map(Int.init)
                : (tableView.selectedRow >= 0 ? tableView.selectedRow : nil)
            let next = min(
                max((current ?? (delta > 0 ? -1 : 1)) + delta, 0),
                max(0, tableView.numberOfRows - 1)
            )
            _ = performSelectionGesture(ResourceTableSelectionGesture(
                row: next,
                modifiers: [],
                keyboardDirection: nil
            ))
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
        performCommand(command, requiringTableFocus: true)
    }

    private func performCommand(
        _ command: ResourceTableCommand,
        requiringTableFocus: Bool
    ) {
        if command.requiresMaterializedSelection,
            (selectionGestureTask != nil || hasPendingSelectionGestures)
        {
            pendingCommandForLoadingSelection = command
            return
        }
        guard canPerformCommand(command, requiringTableFocus: requiringTableFocus)
        else { NSSound.beep(); return }
        guard command.requiresMaterializedSelection else {
            handle(command, identities: [])
            return
        }
        guard let selection = displayedSelectionState,
            !selection.token.isEmpty
        else {
            let identities = model.selectedIdentities
            guard isCommandCompatible(command, with: identities) else {
                NSSound.beep()
                return
            }
            let hidden = Set(identities.lazy.map(\.uid).filter {
                !self.selectedUIDsKnownInPresentedIndex.contains($0)
            })
            handle(
                command,
                identities: identities,
                hiddenSelectionUIDs: hidden
            )
            return
        }
        if command == .delete {
            guard let request = tokenDeleteRequest(for: selection) else {
                show(error: selectionExpiredIssue())
                return
            }
            onDelete?(request)
            return
        }
        materializeSelection(for: command, token: selection.token)
    }

    private func tokenDeleteRequest(
        for selection: ResourceSelectionState
    ) -> DeleteResourcesRequest? {
        guard let resource,
            let currentRevision = currentSelectionRevision,
            !selection.token.isEmpty,
            selection.expiresAt.map({ $0 > Date() }) ?? true
        else { return nil }
        return .selection(
            reference: ResourceSelectionDeleteReference(
                sessionID: session.sessionID,
                viewID: viewID,
                token: selection.token,
                selectedCount: selection.selectedCount,
                gvr: GVR(
                    group: resource.group,
                    version: resource.version,
                    resource: resource.resource
                )
            ),
            currentRevision: currentRevision
        )
    }

    private func materializeSelection(
        for command: ResourceTableCommand,
        token: String
    ) {
        guard selectionCommandTask == nil else { NSSound.beep(); return }
        let provider = self.provider
        let sessionID = session.sessionID
        let viewID = self.viewID
        selectionCommandTask = Task { @MainActor [weak self, provider] in
            guard let self else { return }
            do {
                let identities = try await fetchSelectionIdentities(
                    token: token,
                    sessionID: sessionID,
                    viewID: viewID,
                    provider: provider
                )
                guard !Task.isCancelled else { return }
                selectionCommandTask = nil
                guard identities.allSatisfy({
                    $0.clusterSessionID == sessionID
                }), isCommandCompatible(command, with: identities) else {
                    NSSound.beep()
                    return
                }
                clearInlineIssue(scope: .selection)
                handle(command, identities: identities, hiddenSelectionUIDs: [])
            } catch {
                guard !Task.isCancelled else { return }
                selectionCommandTask = nil
                clearDisplayedSelectionIfExpired(error: error, token: token)
                show(error: error, scope: .selection)
            }
        }
    }

    private func fetchSelectionIdentities(
        token: String,
        sessionID: String? = nil,
        viewID: String? = nil,
        provider suppliedProvider: (any WorkspaceResourceProviding)? = nil
    ) async throws -> [ResourceIdentity] {
        let provider = suppliedProvider ?? self.provider
        let sessionID = sessionID ?? session.sessionID
        let viewID = viewID ?? self.viewID
        var identities: [ResourceIdentity] = []
        var offset: UInt64 = 0
        var expectedState: ResourceSelectionState?
        var previousPinnedIndex: UInt64?
        var seenUIDs: Set<ResourceUID> = []
        while !Task.isCancelled {
            let page = try await provider.fetchSelectionPage(
                sessionID: sessionID,
                viewID: viewID,
                token: token,
                offset: offset,
                limit: ResourceSelectionPage.protocolMaximumPageSize
            )
            let (expectedNextOffset, overflow) = offset.addingReportingOverflow(
                UInt64(page.items.count)
            )
            guard page.state.token == token,
                page.offset == offset,
                !overflow,
                page.nextOffset == expectedNextOffset
            else {
                throw selectionPageIssue(
                    reason: "InvalidSelectionPage",
                    message: "The engine returned an inconsistent selection page."
                )
            }
            if let expectedState {
                guard page.state == expectedState else {
                    throw selectionPageIssue(
                        reason: "SelectionChangedWhilePaging",
                        message: "The immutable selection metadata changed while it was being read."
                    )
                }
            } else {
                expectedState = page.state
                // This path intentionally still materializes targets for the
                // existing command handlers. Bound speculative reservation so
                // corrupt metadata cannot request an enormous allocation.
                identities.reserveCapacity(Int(min(
                    page.state.selectedCount,
                    1_000_000
                )))
            }
            for item in page.items {
                guard previousPinnedIndex.map({ item.pinnedIndex > $0 }) ?? true,
                    item.identity.clusterSessionID == sessionID,
                    seenUIDs.insert(item.identity.uid).inserted
                else {
                    throw selectionPageIssue(
                        reason: "InvalidSelectionIdentity",
                        message: "The engine returned a duplicate, out-of-order, or cross-session selection identity."
                    )
                }
                previousPinnedIndex = item.pinnedIndex
                identities.append(item.identity)
            }
            offset = page.nextOffset
            if page.done {
                guard offset == page.state.selectedCount,
                    UInt64(identities.count) == page.state.selectedCount
                else {
                    throw selectionPageIssue(
                        reason: "IncompleteSelectionPage",
                        message: "The engine ended selection paging before every identity was returned."
                    )
                }
                return identities
            }
            guard !page.items.isEmpty else {
                throw selectionPageIssue(
                    reason: "EmptySelectionPage",
                    message: "The engine returned an empty non-final selection page."
                )
            }
        }
        throw CancellationError()
    }

    private func selectionPageIssue(
        reason: String,
        message: String
    ) -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .validation,
            reason: reason,
            message: message,
            retryable: false,
            operation: "fetch resource selection page"
        )
    }

    /// Executes against the immutable Command-K snapshot. Token-backed delete
    /// stays aggregate; only actions that intrinsically consume identities
    /// page the captured token, and do so after activation.
    func performCapturedCommand(
        _ command: ResourceTableCommand,
        context: CommandContext
    ) {
        guard let reference = context.selectionReference else {
            handle(
                command,
                identities: context.selectedIdentities,
                hiddenSelectionUIDs: context.hiddenSelectionUIDs
            )
            return
        }
        guard let capturedRevision = context.selectionRevision else {
            show(error: selectionScopeChangedIssue())
            return
        }
        if command == .delete {
            guard let revision = currentSelectionRevision(
                reference,
                capturedGeneration: capturedRevision.generation
            ) else {
                show(error: selectionScopeChangedIssue())
                return
            }
            onDelete?(.selection(
                reference: reference,
                currentRevision: revision
            ))
            return
        }
        guard selectionScopeIsValid(
            reference,
            capturedGeneration: capturedRevision.generation
        ) else {
            show(error: selectionScopeChangedIssue())
            return
        }
        materializeCapturedSelection(
            for: command,
            reference: reference,
            capturedGeneration: capturedRevision.generation
        )
    }

    func selectionScopeIsValid(
        _ reference: ResourceSelectionDeleteReference,
        capturedGeneration: UInt64
    ) -> Bool {
        guard isAuthenticated,
            resourceCatalogValidated,
            reference.sessionID == session.sessionID,
            reference.viewID == viewID,
            currentSelectionRevision?.generation == capturedGeneration,
            let resource
        else { return false }
        return reference.gvr == GVR(
            group: resource.group,
            version: resource.version,
            resource: resource.resource
        )
    }

    func currentSelectionRevision(
        _ reference: ResourceSelectionDeleteReference,
        capturedGeneration _: UInt64
    ) -> ResourceSelectionRevision? {
        guard isAuthenticated,
            resourceCatalogValidated,
            reference.sessionID == session.sessionID,
            reference.viewID == viewID,
            let revision = currentSelectionRevision,
            let resource,
            reference.gvr == GVR(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            )
        else { return nil }
        return revision
    }

    private func materializeCapturedSelection(
        for command: ResourceTableCommand,
        reference: ResourceSelectionDeleteReference,
        capturedGeneration: UInt64
    ) {
        guard selectionCommandTask == nil else { NSSound.beep(); return }
        let provider = self.provider
        selectionCommandTask = Task { @MainActor [weak self, provider] in
            guard let self else { return }
            do {
                let identities = try await fetchSelectionIdentities(
                    token: reference.token,
                    sessionID: reference.sessionID,
                    viewID: reference.viewID,
                    provider: provider
                )
                guard !Task.isCancelled else { return }
                selectionCommandTask = nil
                guard selectionScopeIsValid(
                    reference,
                    capturedGeneration: capturedGeneration
                ),
                    identities.allSatisfy({
                    $0.clusterSessionID == reference.sessionID
                }), isCommandCompatible(command, with: identities) else {
                    show(error: selectionScopeChangedIssue())
                    return
                }
                clearInlineIssue(scope: .selection)
                handle(command, identities: identities, hiddenSelectionUIDs: [])
            } catch {
                guard !Task.isCancelled else { return }
                selectionCommandTask = nil
                clearDisplayedSelectionIfExpired(
                    error: error,
                    token: reference.token
                )
                show(error: error, scope: .selection)
            }
        }
    }

    /// Test-only/legacy hook for explicit UID snapshots.
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
        if let state = displayedSelectionState {
            return isCommandCompatible(
                command,
                selectedCount: state.selectedCount,
                resource: resource
            )
        }
        return isCommandCompatible(command, with: model.selectedIdentities)
    }

    private func canPerformCommand(
        _ command: ResourceTableCommand,
        requiringTableFocus: Bool
    ) -> Bool {
        if requiringTableFocus, view.window?.firstResponder !== tableView { return false }
        if let state = displayedSelectionState {
            let compatible = isCommandCompatible(
                command,
                selectedCount: state.selectedCount,
                resource: resource
            )
            guard compatible else { return false }
            switch command {
            case .focusFilter, .selectAll, .moveDown, .moveUp,
                .extendDown, .extendUp:
                return true
            default:
                // The token was issued only by the authenticated engine for
                // this session/view. Final identity and command compatibility
                // are checked again after every immutable page is fetched.
                return isAuthenticated && resourceCatalogValidated
            }
        }
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
        selectedCount: UInt64,
        resource: DiscoveredResource?
    ) -> Bool {
        let exactlyOne = selectedCount == 1
        let nonempty = selectedCount > 0
        let group = resource?.group ?? ""
        let version = resource?.version ?? ""
        let name = resource?.resource ?? ""
        switch command {
        case .enter:
            guard exactlyOne, let resource else { return false }
            let identity = ResourceIdentity(
                clusterSessionID: session.sessionID,
                group: resource.group,
                version: resource.version,
                resource: resource.resource,
                namespace: resource.namespaced ? "_" : "",
                name: "_",
                uid: "_"
            )
            return ResourceDrillDownPlanner.hasPotentialTarget(identity)
        case .open, .openYAML, .openYAMLSnapshot, .openEvents:
            return exactlyOne
        case .openLogs, .openPreviousLogs:
            guard nonempty, selectedCount <= 128 else { return false }
            if group.isEmpty, version == "v1", name == "pods" { return true }
            if group == "apps", version == "v1" {
                return ["deployments", "statefulsets", "daemonsets", "replicasets"]
                    .contains(name)
            }
            return group == "batch" && version == "v1"
                && ["jobs", "cronjobs"].contains(name)
        case .openExec, .configureExec:
            return exactlyOne && group.isEmpty && version == "v1"
                && (name == "pods" || name == "nodes")
        case .startPortForward:
            return exactlyOne && group.isEmpty && version == "v1"
                && (name == "pods" || name == "services")
        case .delete:
            return nonempty
        case .scale:
            return exactlyOne && resource?.namespaced == true
                && ["deployments", "statefulsets", "replicasets"].contains(name)
        case .restart:
            return exactlyOne && group == "apps" && version == "v1"
                && ["deployments", "statefulsets", "daemonsets"].contains(name)
        case .editLabels, .editAnnotations:
            return exactlyOne
        case .copyName, .copyNamespacedName, .copyReference:
            return nonempty
        case .focusFilter, .selectAll, .moveDown, .moveUp,
            .extendDown, .extendUp:
            return true
        }
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
                && selected[0].version == "v1"
                && (selected[0].resource == "pods" || selected[0].resource == "nodes")
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
        case .editLabels, .editAnnotations:
            return selected.count == 1
        case .copyName, .copyNamespacedName, .copyReference:
            return !selected.isEmpty
        case .focusFilter, .selectAll, .moveDown, .moveUp, .extendDown, .extendUp:
            return true
        }
    }
}

@MainActor
private final class ObjectDetailRecentEventsController: ObjectDetailEventsControlling {
    static let maximumEvents = ObjectDetailSummaryPresentation.maximumRecentEvents
    private static let columnIDs = [
        "last-seen", "first-seen", "event-type", "reason", "message",
        "event-count", "event-name",
    ]

    private var session: OpenedClusterSession
    private let provider: any WorkspaceResourceProviding
    private let resource: DiscoveredResource
    private let scope: NamespaceSelection
    private let filter: String
    private let viewID = UUID().uuidString.lowercased()
    private var generation: UInt64 = 0
    private var lastCancelledGeneration: UInt64 = 0
    private var isActive = false
    private var streamTask: Task<Void, Never>?
    private var rangeTask: Task<Void, Never>?
    private var rangeFetchTicket: UInt64 = 0
    private var rangeCache: ResourceViewRangeCache?
    private var sequenceGate = GenerationSequenceGate()
    private var lastSnapshot: ObjectDetailEventsSnapshot?

    init(
        session: OpenedClusterSession,
        provider: any WorkspaceResourceProviding,
        resource: DiscoveredResource,
        scope: NamespaceSelection,
        filter: String
    ) {
        self.session = session
        self.provider = provider
        self.resource = resource
        self.scope = scope
        self.filter = filter
    }

    var onSnapshotChanged: ((ObjectDetailEventsSnapshot) -> Void)?

    func activate() {
        guard !isActive else { return }
        isActive = true
        publish(.loading)
        openStream()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        cancelCurrentView()
    }

    func stop() {
        deactivate()
    }

    func engineDidDisconnect() {
        deactivate()
        publish(.failed(
            message: "Events unavailable while the engine reconnects",
            toolTip: "The Kubernetes engine disconnected. Recent Events will reload after this object's Summary reconnects."
        ))
    }

    func recover(session recoveredSession: OpenedClusterSession) {
        let shouldReactivate = isActive
        deactivate()
        session = recoveredSession
        if shouldReactivate { activate() }
    }

    private func openStream() {
        generation &+= 1
        sequenceGate.reset()
        cancelRangeFetches()
        rangeCache = ResourceViewRangeCache(
            sessionID: session.sessionID,
            viewID: viewID,
            generation: generation,
            maximumCachedRows: Self.maximumEvents
        )
        let request = ResourceViewRequest(
            sessionID: session.sessionID,
            viewID: viewID,
            generation: generation,
            resource: resource,
            allNamespaces: scope.allNamespaces,
            namespaces: scope.namespaces,
            filterExpression: filter,
            columnIDs: Self.columnIDs,
            sort: [
                ResourceSortDescriptor(
                    columnID: "last-seen",
                    direction: .descending
                ),
                ResourceSortDescriptor(
                    columnID: "first-seen",
                    direction: .descending
                ),
                ResourceSortDescriptor(
                    columnID: "event-name",
                    direction: .ascending
                ),
            ]
        )
        let provider = self.provider
        streamTask = Task { @MainActor [weak self, provider] in
            do {
                for try await message in provider.streamView(request: request) {
                    guard !Task.isCancelled else { return }
                    self?.receive(message, request: request)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(error: error, generation: request.generation)
            }
        }
    }

    private func receive(
        _ message: ResourceViewMessage,
        request: ResourceViewRequest
    ) {
        guard isActive,
            request.generation == generation,
            message.cursor.generation == generation
        else { return }
        let disposition = sequenceGate.accept(message.cursor)
        guard disposition == .acceptedNewGeneration
            || disposition == .acceptedNextSequence
        else { return }

        switch message {
        case .invalidation(let cursor, let invalidation):
            receive(cursor: cursor, invalidation: invalidation)
        case .reconciled(let cursor, let reconciliation)
            where reconciliation.rowsVisible == 0
                && rangeCache?.matches(
                    cursor: cursor,
                    reconciliation: reconciliation
                ) == true:
            publish(.loaded(events: [], totalCount: 0))
        case .failure(_, let issue):
            let presentation = issue.userFacingPresentation
            publish(.failed(
                message: presentation.inlineText,
                toolTip: presentation.detailedText
            ))
        case .schema, .status, .reconciled:
            break
        }
    }

    private func receive(
        cursor: StreamCursor,
        invalidation: ResourceViewInvalidation
    ) {
        guard var cache = rangeCache else { return }
        let disposition = cache.receive(cursor: cursor, invalidation: invalidation)
        guard disposition != .rejectedStale else { return }
        guard disposition != .rejectedInvalid else {
            publishInvalidRangeContract()
            return
        }
        if disposition != .hintsOnly {
            cancelRangeFetches()
        }
        let length = min(Self.maximumEvents, Int(clamping: cache.rowsVisible))
        guard length > 0 else {
            _ = cache.retain(0..<0)
            rangeCache = cache
            publish(.loaded(events: [], totalCount: cache.rowsVisible))
            return
        }
        let target = UInt64(0)..<UInt64(length)
        let requests = cache.retain(target)
        rangeCache = cache
        if let rows = cache.rows(in: target) {
            publish(rows: rows, totalCount: cache.rowsVisible)
            return
        }
        guard !requests.isEmpty else { return }
        startRangeFetches(requests)
    }

    private func startRangeFetches(
        _ requests: [ResourceViewRangeRequest]
    ) {
        guard rangeTask == nil else { return }
        rangeFetchTicket &+= 1
        let ticket = rangeFetchTicket
        let provider = self.provider
        rangeTask = Task { @MainActor [weak self, provider] in
            defer { self?.finishRangeFetches(ticket: ticket) }
            for request in requests {
                guard !Task.isCancelled else { return }
                do {
                    let range = try await provider.fetchViewRange(request: request)
                    guard !Task.isCancelled else { return }
                    self?.receive(range: range, for: request)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.receiveRangeError(error, for: request)
                }
            }
        }
    }

    private func finishRangeFetches(ticket: UInt64) {
        guard ticket == rangeFetchTicket else { return }
        rangeTask = nil
    }

    private func cancelRangeFetches() {
        rangeFetchTicket &+= 1
        rangeTask?.cancel()
        rangeTask = nil
    }

    private func receiveRangeError(
        _ error: Error,
        for request: ResourceViewRangeRequest
    ) {
        guard request.revision.generation == generation else { return }
        if var cache = rangeCache {
            cache.release(request)
            rangeCache = cache
        }
        if let issue = error as? ClusterManagerIssue,
            issue.isStaleResourceViewRequest
        {
            return
        }
        show(error: error, generation: request.revision.generation)
    }

    private func receive(
        range: ResourceViewRange,
        for request: ResourceViewRangeRequest
    ) {
        guard isActive, request.revision.generation == generation,
            var cache = rangeCache
        else { return }
        let reception = cache.receive(range, for: request)
        rangeCache = cache
        guard reception != .rejectedRace else { return }
        guard reception != .rejectedInvalid else {
            publishInvalidRangeContract()
            return
        }
        let length = min(Self.maximumEvents, Int(clamping: cache.rowsVisible))
        let target = UInt64(0)..<UInt64(length)
        guard let rows = cache.rows(in: target) else { return }
        publish(rows: rows, totalCount: cache.rowsVisible)
    }

    private func publish(rows: [ResourceRow], totalCount: UInt64) {
        let events = rows.map { row in
            let count: Int64
            if case .integer(let value)? = row["event-count"]?.typedValue {
                count = value
            } else {
                count = Int64(row["event-count"]?.displayText ?? "") ?? 0
            }
            let typeCell = row["event-type"]
            return ObjectDetailEventSummary(
                uid: row.identity.uid,
                type: typeCell?.displayText ?? "",
                reason: row["reason"]?.displayText ?? "",
                message: row["message"]?.displayText ?? "",
                lastSeen: row["last-seen"]?.displayText ?? "",
                count: count,
                severity: typeCell?.severity ?? .normal
            )
        }
        publish(.loaded(events: events, totalCount: totalCount))
    }

    private func publishInvalidRangeContract() {
        let issue = ClusterManagerIssue(
            category: .internalFailure,
            reason: "InvalidRecentEventsRange",
            message: "The engine returned an invalid recent Events range.",
            operation: "load recent object Events"
        )
        let presentation = issue.userFacingPresentation
        publish(.failed(
            message: presentation.inlineText,
            toolTip: presentation.detailedText
        ))
    }

    private func show(error: Error, generation: UInt64) {
        guard isActive, generation == self.generation else { return }
        let presentation = UserFacingErrorPresentation(error)
        publish(.failed(
            message: presentation.inlineText,
            toolTip: presentation.detailedText
        ))
    }

    private func publish(_ snapshot: ObjectDetailEventsSnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshotChanged?(snapshot)
    }

    private func cancelCurrentView() {
        streamTask?.cancel()
        streamTask = nil
        cancelRangeFetches()
        rangeCache = nil
        let cancelledGeneration = generation
        guard cancelledGeneration > 0,
            cancelledGeneration != lastCancelledGeneration
        else { return }
        lastCancelledGeneration = cancelledGeneration
        let provider = self.provider
        let sessionID = session.sessionID
        let viewID = self.viewID
        Task {
            await provider.cancelView(
                sessionID: sessionID,
                viewID: viewID,
                generation: cancelledGeneration
            )
        }
    }
}

private enum ResourceTableCommand: Equatable {
    case focusFilter, enter, open, openYAML, openYAMLSnapshot, openEvents
    case openLogs, openPreviousLogs
    case openExec, configureExec
    case startPortForward, selectAll, delete, scale, restart, editLabels, editAnnotations
    case copyName, copyNamespacedName, copyReference, moveUp, moveDown, extendUp, extendDown
}

private extension ResourceTableCommand {
    var requiresMaterializedSelection: Bool {
        switch self {
        case .focusFilter, .selectAll, .moveUp, .moveDown, .extendUp, .extendDown:
            false
        default:
            true
        }
    }

    var subresourceNetworkAction: PodContainerNetworkAction? {
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
        case .editLabels: .editLabels
        case .editAnnotations: .editAnnotations
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
private final class ResourceTableView: CapturedCellTableView {
    var onCommand: ((ResourceTableCommand) -> Void)?
    var onSelectionGesture: ((ResourceTableSelectionGesture) -> Bool)?

    /// A nil-targeted Edit > Select All command resolves to NSTableView before
    /// `keyDown(with:)` gets a chance to translate Command-A. Route that
    /// responder action through the backend token authority so Command-A covers
    /// unloaded rows without constructing a full AppKit IndexSet. Projection
    /// uses the explicit `super` seam below to avoid recursive dispatch.
    override func selectAll(_ sender: Any?) {
        guard currentEditor() == nil, let onCommand else {
            super.selectAll(sender)
            return
        }
        onCommand(.selectAll)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        captureCellValue(at: point)
        let row = self.row(at: point)
        let gesture = ResourceTableSelectionGesture(
            row: row >= 0 ? row : nil,
            modifiers: Self.selectionModifiers(from: event.modifierFlags),
            keyboardDirection: nil
        )
        if onSelectionGesture?(gesture) == true {
            window?.makeFirstResponder(self)
            if row >= 0, event.clickCount == 2 {
                onCommand?(.enter)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard currentEditor() == nil else { super.keyDown(with: event); return }
        let command = event.modifierFlags.contains(.command)
        let unmodified = event.modifierFlags.intersection([
            .shift, .command, .control, .option,
        ]).isEmpty
        switch (event.charactersIgnoringModifiers?.lowercased(), event.keyCode, command) {
        case ("/", _, false): onCommand?(.focusFilter)
        case ("j", _, false): onCommand?(.moveDown)
        case ("k", _, false): onCommand?(.moveUp)
        case ("d", _, false) where unmodified: onCommand?(.open)
        case (_, 36, false): onCommand?(.enter)
        case ("y", _, false):
            guard event.modifierFlags.intersection([.control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            onCommand?(event.modifierFlags.contains(.shift)
                ? .openYAMLSnapshot : .openYAML)
        case ("e", _, false): onCommand?(.openEvents)
        case ("l", _, false):
            guard event.modifierFlags.intersection([.control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            onCommand?(event.modifierFlags.contains(.shift) ? .openPreviousLogs : .openLogs)
        case ("s", _, false):
            guard event.modifierFlags.intersection([.control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            onCommand?(event.modifierFlags.contains(.shift) ? .configureExec : .openExec)
        case ("p", _, false): onCommand?(.startPortForward)
        case ("r", _, false) where unmodified: onCommand?(.restart)
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
