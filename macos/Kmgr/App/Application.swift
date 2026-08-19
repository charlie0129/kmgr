import AppKit
import KmgrCore
import KmgrIPC
import OSLog

@main
@MainActor
final class Application: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: Product.bundleIdentifier, category: "application")
    private var chooserControllers: [ObjectIdentifier: ClusterManagerWindowController] = [:]
    private var workspaceControllers: [ObjectIdentifier: ClusterWorkspaceWindowController] = [:]
    private var columnsManagerControllers: [ObjectIdentifier: ColumnsManagerWindowController] = [:]
    private let clusterContextProvider: any ClusterContextProviding
    private let workspaceResourceProvider: any WorkspaceResourceProviding
    private let clusterConnectionActivityProvider: any ClusterConnectionActivityProviding
    private let optionalResourceCatalogProvider: any OptionalResourceCatalogProviding
    private let columnPreviewProvider: any ColumnPreviewProviding
    private let objectSearchProvider: any ObjectSearchProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let logProvider: any LogStreamProviding
    private let execProvider: any ExecSessionProviding
    private let preferencesStore: AppPreferencesStore
    /// One process-wide store keeps fixed-table layouts synchronized across
    /// every window. Resource-list layouts remain scoped by exact GVR in the
    /// separate columns configuration path.
    private let tableLayoutStore: TableLayoutStore
    private let engineColumnsConfigurationPath: String
    private let columnConfigurationCoordinator: ColumnConfigurationCoordinator
    private let restorationStore: WorkspaceRestorationStore
    private var pendingRestorationNotice: ClusterManagerInitialNotice?
    private let settingsWindowController: SettingsWindowController
    private let portForwardCoordinator: PortForwardCoordinator
    private let portForwardsWindowController: PortForwardsWindowController
    private let contextualShortcutsCoordinator: ContextualShortcutsCoordinator
    private let engineSupervisor: EngineSupervisor
    private var engineStateObserver: UUID?
    private var readyEngineInstanceID: String?
    private var helperRecoveryRequired = false
    private var workspaceRecoveryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var restoredWorkspaceAttempts: [
        ObjectIdentifier: RestoredWorkspaceConnectionAttempt
    ] = [:]
    private var logWindowControllers: [ObjectIdentifier: LogWindowController] = [:]
    private var terminalWindowControllers: [ObjectIdentifier: TerminalWindowController] = [:]
    private var isTerminating = false
    private var terminationTask: Task<Void, Never>?

    override init() {
        let preferences = AppPreferencesStore()
        self.preferencesStore = preferences
        self.tableLayoutStore = TableLayoutStore()
        self.engineColumnsConfigurationPath = preferences.current.columnsConfigurationPath
        self.columnConfigurationCoordinator = ColumnConfigurationCoordinator(
            path: preferences.current.columnsConfigurationPath
        )
        var engineConfiguration = EngineSupervisor.Configuration.bundled()
        engineConfiguration.columnsConfigurationPath = preferences.current.columnsConfigurationPath
        engineConfiguration.metricsRefreshSeconds = preferences.current.metricsRefreshSeconds
        engineConfiguration.advancedPerformance = preferences.current.advancedPerformance
        let supervisor = EngineSupervisor(configuration: engineConfiguration)
        self.engineSupervisor = supervisor
        let restorationStore = WorkspaceRestorationStore()
        self.restorationStore = restorationStore
        self.pendingRestorationNotice = restorationStore.loadIssue.map {
            ClusterManagerInitialNotice(
                title: "Workspace restoration skipped",
                message: $0.message
            )
        }
        let settings = SettingsWindowController(preferencesStore: preferences)
        self.settingsWindowController = settings
        self.clusterContextProvider = EngineClusterContextProvider(
            supervisor: supervisor
        )
        self.workspaceResourceProvider = EngineWorkspaceResourceProvider(
            connection: supervisor.connection
        )
        self.clusterConnectionActivityProvider = EngineClusterConnectionActivityProvider(
            connection: supervisor.connection
        )
        self.optionalResourceCatalogProvider = EngineOptionalResourceCatalogProvider(
            connection: supervisor.connection
        )
        self.columnPreviewProvider = EngineColumnPreviewProvider(
            connection: supervisor.connection
        )
        self.objectSearchProvider = EngineObjectSearchProvider(
            connection: supervisor.connection
        )
        self.objectDetailProvider = EngineObjectDetailProvider(
            connection: supervisor.connection
        )
        self.operationProvider = EngineOperationProvider(connection: supervisor.connection)
        self.logProvider = EngineLogStreamProvider(connection: supervisor.connection)
        self.execProvider = EngineExecSessionProvider(connection: supervisor.connection)
        let portForwards = PortForwardCoordinator(
            provider: EnginePortForwardProvider(connection: supervisor.connection)
        )
        self.portForwardCoordinator = portForwards
        self.portForwardsWindowController = PortForwardsWindowController(
            coordinator: portForwards,
            tableLayoutStore: tableLayoutStore
        )
        self.contextualShortcutsCoordinator = ContextualShortcutsCoordinator(
            application: .shared
        )
        super.init()
        settings.onPreferencesChanged = { [weak self] preferences, delta in
            guard let self else { return }
            if delta.contains(.appearance) {
                applyAppearance(preferences.appearance)
            }
            if delta.contains(.logDisplay) {
                let configuration = LogDisplayConfiguration(preferences: preferences.logs)
                for controller in logWindowControllers.values {
                    controller.applyDisplayConfiguration(configuration)
                }
            }
        }
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = Application()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        applyAppearance(preferencesStore.current.appearance)
        engineStateObserver = engineSupervisor.observeState { [weak self] state in
            self?.engineStateChanged(state)
        }
        engineSupervisor.start()
        restoreWorkspacesOrShowChooser()
        contextualShortcutsCoordinator.start()
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Kmgr application launched")
    }

    private func engineStateChanged(_ state: EngineConnectionState) {
        switch state {
        case .ready(let information):
            let isNewGeneration = readyEngineInstanceID.map {
                $0 != information.instanceID
            } ?? false
            readyEngineInstanceID = information.instanceID
            guard helperRecoveryRequired || isNewGeneration else { return }
            helperRecoveryRequired = false
            recoverWorkspacesAfterHelperRestart()
        case .disconnected(let message):
            guard readyEngineInstanceID != nil, !isTerminating else { return }
            beginHelperRecovery(message: message)
        case .failed(let message):
            guard readyEngineInstanceID != nil, !isTerminating else { return }
            beginHelperRecovery(message: message)
            for controller in workspaceControllers.values {
                controller.engineRecoveryFailed(ClusterManagerIssue(
                    category: .unavailable,
                    reason: "EngineRestartFailed",
                    message: message,
                    retryable: true,
                    contextName: controller.session.contextName,
                    operation: "restart Kubernetes engine"
                ))
            }
        case .stopped, .starting, .restarting, .stopping:
            break
        }
    }

    private func beginHelperRecovery(message: String) {
        if !helperRecoveryRequired {
            helperRecoveryRequired = true
            for task in workspaceRecoveryTasks.values { task.cancel() }
            workspaceRecoveryTasks.removeAll()
            portForwardCoordinator.engineDidDisconnect(message: message)
        }
        for controller in workspaceControllers.values {
            controller.engineDidDisconnect(message: message)
        }
    }

    private func recoverWorkspacesAfterHelperRestart() {
        for task in workspaceRecoveryTasks.values { task.cancel() }
        workspaceRecoveryTasks.removeAll()
        for (identifier, controller) in workspaceControllers {
            guard controller.isAuthenticated else { continue }
            let contextReference = controller.session.contextReference
            let task = Task { [weak self, weak controller, clusterContextProvider] in
                guard let self, let controller else { return }
                do {
                    let session = try await clusterContextProvider.openContext(
                        reference: contextReference
                    )
                    guard !Task.isCancelled,
                        self.workspaceControllers[identifier] === controller
                    else { return }
                    controller.recover(with: session)
                    portForwardCoordinator.register(session: session)
                } catch {
                    guard !Task.isCancelled,
                        self.workspaceControllers[identifier] === controller
                    else { return }
                    controller.engineRecoveryFailed(error)
                }
                workspaceRecoveryTasks.removeValue(forKey: identifier)
            }
            workspaceRecoveryTasks[identifier] = task
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !portForwardCoordinator.hasActiveForwards
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        if portForwardCoordinator.hasActiveForwards {
            let forwards = portForwardCoordinator.activeRecords
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Stop active port-forwards and quit?"
            let descriptions = forwards.prefix(8).map { record in
                let context = ClusterIdentityPresentation(
                    clusterName: record.clusterName,
                    contextName: record.contextName
                ).titlePrefix
                let namespace = record.target.namespace.isEmpty ? "cluster" : record.target.namespace
                return "• \(context) · \(namespace)/\(record.target.name) · \(record.address ?? "allocating") → \(record.remotePort)"
            }
            let remainder = max(0, forwards.count - descriptions.count)
            alert.informativeText = descriptions.joined(separator: "\n")
                + (remainder > 0 ? "\n…and \(remainder) more" : "")
                + "\n\nQuitting stops these listeners. They will not be restored automatically."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return .terminateCancel
            }
        }
        isTerminating = true
        // Column resize/move writes are intentionally coalesced. Flush before
        // beginning asynchronous engine shutdown so the final presentation is
        // durable even when termination happens inside the debounce window.
        _ = tableLayoutStore.flushPendingSave()
        contextualShortcutsCoordinator.stop()
        if let engineStateObserver {
            engineSupervisor.removeStateObserver(engineStateObserver)
            self.engineStateObserver = nil
        }
        for task in workspaceRecoveryTasks.values { task.cancel() }
        workspaceRecoveryTasks.removeAll()
        for attempt in restoredWorkspaceAttempts.values { attempt.cancel() }
        restoredWorkspaceAttempts.removeAll()
        terminationTask = Task {
            [engineSupervisor, portForwardCoordinator, columnConfigurationCoordinator] in
            await columnConfigurationCoordinator.flushPendingLayoutSaves()
            await portForwardCoordinator.stopAllActive()
            portForwardCoordinator.stopWatching()
            await engineSupervisor.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = tableLayoutStore.flushPendingSave()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        let destination = ApplicationReopenPresentationPolicy(
            appKitHasVisibleWindows: flag,
            hasVisibleReopenTarget: hasVisibleReopenTarget,
            hasActivePortForward: portForwardCoordinator.hasActiveForwards
        ).destination
        switch destination {
        case .none:
            break
        case .portForwards:
            showPortForwards(nil)
        case .clusterManager:
            showClusterManager()
        }
        return true
    }

    @objc private func showClusterManager() {
        // Every Command-N starts a fresh chooser so the user can open several
        // independent workspaces, including the same context more than once.
        let initialNotice = pendingRestorationNotice
        pendingRestorationNotice = nil
        let controller = ClusterManagerWindowController(
            provider: clusterContextProvider,
            initialNotice: initialNotice,
            tableLayoutStore: tableLayoutStore
        )
        let identifier = ObjectIdentifier(controller)
        chooserControllers[identifier] = controller
        controller.onOpenSession = { [weak self] session in
            guard let self else { return }
            let initialNamespace = preferencesStore.current.defaultNamespace
                .initialSelection(contextDefaultNamespace: session.defaultNamespace)
            let bookmark = restorationStore.bookmark(
                for: session.contextReference
            )
            var initialState = bookmark?.state ?? ClusterWindowRestorationState(
                contextName: session.contextName,
                contextReference: session.contextReference,
                namespaceScope: NamespaceScope(initialNamespace)
            )
            // The opaque reference is the identity. The display name may have
            // changed in the kubeconfig since this bookmark was recorded.
            initialState.contextName = session.contextName
            initialState.contextReference = session.contextReference
            _ = openWorkspace(
                for: session,
                restoration: ClusterWindowRestorationRecord(
                    state: initialState
                ),
                seedFrameAutosaveName: bookmark?.frameAutosaveName
            )
        }
        controller.onClose = { [weak self] in
            self?.chooserControllers.removeValue(forKey: identifier)
        }
        controller.showWindow(nil)
    }

    private func openWorkspace(
        for session: OpenedClusterSession,
        restoration: ClusterWindowRestorationRecord,
        seedFrameAutosaveName: String? = nil,
        activatesContextBookmarkOnOpen: Bool = true,
        startsAuthenticated: Bool = true
    ) -> ClusterWorkspaceWindowController {
        let controller = ClusterWorkspaceWindowController(
            session: session,
            provider: workspaceResourceProvider,
            connectionActivityProvider: clusterConnectionActivityProvider,
            optionalResourceCatalogProvider: optionalResourceCatalogProvider,
            objectSearchProvider: objectSearchProvider,
            objectDetailProvider: objectDetailProvider,
            operationProvider: operationProvider,
            logProvider: logProvider,
            execProvider: execProvider,
            portForwards: portForwardCoordinator,
            tableLayoutStore: tableLayoutStore,
            columnsConfigurationPath: engineColumnsConfigurationPath,
            columnConfigurationCoordinator: columnConfigurationCoordinator,
            logDisplayConfiguration: LogDisplayConfiguration(
                preferences: preferencesStore.current.logs
            ),
            confirmationPreferences: { [weak self] in
                self?.preferencesStore.current.confirmations ?? ConfirmationPreferences()
            },
            restoration: restoration,
            seedFrameAutosaveName: seedFrameAutosaveName,
            startsAuthenticated: startsAuthenticated,
            onShowPortForwards: { [weak self] in
                self?.showPortForwards(nil)
            }
        )
        let identifier = ObjectIdentifier(controller)
        workspaceControllers[identifier] = controller
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            if !isTerminating {
                controller?.window?.setFrameAutosaveName("")
                try? restorationStore.remove(id: restoration.id)
                NSWindow.removeFrame(usingName: restoration.frameAutosaveName)
            }
            columnsManagerControllers.removeValue(forKey: identifier)?.close()
            workspaceRecoveryTasks.removeValue(forKey: identifier)?.cancel()
            restoredWorkspaceAttempts.removeValue(forKey: identifier)?.cancel()
            workspaceControllers.removeValue(forKey: identifier)

            let policy = ClusterManagerPresentationPolicy(
                isTerminating: isTerminating,
                remainingWorkspaceCount: workspaceControllers.count,
                hasClusterManager: !chooserControllers.isEmpty,
                hasVisibleIndependentWindow: hasVisibleIndependentWindow,
                hasActivePortForward: portForwardCoordinator.hasActiveForwards
            )
            if policy.shouldPresentAfterWorkspaceClose {
                showClusterManager()
            }
        }
        controller.onStartPortForward = { [weak controller] identity in
            controller?.showPortForwardConfiguration(identity)
        }
        controller.onOpenLogWindow = { [weak self] logController in
            self?.retainAndShow(logController)
        }
        controller.onOpenTerminalWindow = { [weak self] terminalController in
            self?.retainAndShow(terminalController)
        }
        controller.onShowColumns = { [weak self, weak controller] request in
            guard let self, let controller else { return }
            self.showColumns(request, for: controller)
        }
        controller.onRestorationCheckpoint = { [weak self] record in
            try? self?.restorationStore.upsert(record)
        }
        try? restorationStore.upsert(restoration)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // Initial AppKit activation can precede asynchronous resource
        // restoration. Publish the known opening state explicitly, then
        // observe only later user-driven activations.
        if activatesContextBookmarkOnOpen,
            let bookmark = try? restorationStore.activate(restoration)
        {
            controller.window?.saveFrame(usingName: bookmark.frameAutosaveName)
        }
        controller.onActivationCheckpoint = { [weak self, weak controller] record in
            guard let self, !isTerminating, let controller,
                let bookmark = try? restorationStore.activate(record)
            else { return }
            controller.window?.saveFrame(usingName: bookmark.frameAutosaveName)
        }
        controller.onFrameCheckpoint = { [weak self, weak controller] record in
            guard let self, let controller,
                let bookmark = restorationStore.bookmark(
                    for: record.state.contextReference
                ),
                bookmark.sourceWindowID == record.id
            else { return }
            controller.window?.saveFrame(usingName: bookmark.frameAutosaveName)
        }
        return controller
    }

    private func restoreWorkspacesOrShowChooser() {
        guard preferencesStore.current.restoreOpenClusterWindows else {
            // A skipped document describes windows from a process that no
            // longer exists. Consume it now so re-enabling restoration later
            // cannot resurrect an older launch's workspace set.
            try? restorationStore.removeAllOpenWindows()
            showClusterManager()
            return
        }
        let records = restorationStore.windows
        guard !records.isEmpty else { showClusterManager(); return }
        for record in records {
            let shell = RestoredWorkspaceShell(record: record)
            let controller = openWorkspace(
                for: shell.session,
                restoration: record,
                activatesContextBookmarkOnOpen: false,
                startsAuthenticated: false
            )
            let identifier = ObjectIdentifier(controller)
            let attempt = RestoredWorkspaceConnectionAttempt(
                provider: clusterContextProvider,
                contextReference: record.state.contextReference
            )
            attempt.onOpened = { [weak self, weak controller] session in
                guard let self, let controller,
                    self.workspaceControllers[identifier] === controller
                else { return }
                controller.recover(with: session)
            }
            attempt.onFailure = { [weak self, weak controller] error in
                guard let self, let controller,
                    self.workspaceControllers[identifier] === controller
                else { return }
                self.logger.error(
                    "Workspace restore failed for context \(record.state.contextName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                controller.engineRecoveryFailed(error)
            }
            attempt.onFinish = { [weak self, weak attempt] in
                guard let self,
                    self.restoredWorkspaceAttempts[identifier] === attempt
                else { return }
                self.restoredWorkspaceAttempts.removeValue(forKey: identifier)
            }
            restoredWorkspaceAttempts[identifier] = attempt
            attempt.start()
        }
    }

    private func retainAndShow(_ controller: LogWindowController) {
        // A workspace may predate the latest preferences. Correct the newly
        // created controller before its stream begins, then retain it for live
        // updates from subsequent Settings saves.
        controller.applyDisplayConfiguration(LogDisplayConfiguration(
            preferences: preferencesStore.current.logs
        ))
        let identifier = ObjectIdentifier(controller)
        logWindowControllers[identifier] = controller
        controller.onClose = { [weak self, weak controller] in
            guard self?.logWindowControllers[identifier] === controller else { return }
            self?.logWindowControllers.removeValue(forKey: identifier)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func retainAndShow(_ controller: TerminalWindowController) {
        let identifier = ObjectIdentifier(controller)
        terminalWindowControllers[identifier] = controller
        controller.onClose = { [weak self, weak controller] in
            guard self?.terminalWindowControllers[identifier] === controller else { return }
            self?.terminalWindowControllers.removeValue(forKey: identifier)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private var hasVisibleIndependentWindow: Bool {
        if settingsWindowController.window?.isVisible == true
            || portForwardsWindowController.window?.isVisible == true
        {
            return true
        }
        if logWindowControllers.values.contains(where: { $0.window?.isVisible == true }) {
            return true
        }
        return terminalWindowControllers.values.contains {
            $0.window?.isVisible == true
        }
    }

    private var hasVisibleReopenTarget: Bool {
        chooserControllers.values.contains { $0.window?.isVisible == true }
            || workspaceControllers.values.contains { $0.window?.isVisible == true }
            || hasVisibleIndependentWindow
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindowController.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showColumns(
        _ request: ResourceColumnsRequest,
        for workspace: ClusterWorkspaceWindowController
    ) {
        let identifier = ObjectIdentifier(workspace)
        if let current = columnsManagerControllers[identifier] {
            current.window?.makeKeyAndOrderFront(nil)
            NSSound.beep()
            return
        }
        guard let parent = workspace.window else { return }

        let configurationPath = engineColumnsConfigurationPath
        let controller = ColumnsManagerWindowController(
            resourceTitle: request.resourceTitle,
            match: request.match,
            defaultColumns: request.defaultColumns,
            discoveredColumns: request.discoveredColumns,
            previewProvider: columnPreviewProvider,
            previewContext: request.previewContext,
            configurationPath: configurationPath,
            configurationCoordinator: columnConfigurationCoordinator,
            tableLayoutStore: tableLayoutStore
        )
        controller.onDraftChanged = request.apply
        controller.onClose = { [weak self, weak controller] in
            guard self?.columnsManagerControllers[identifier] === controller else { return }
            self?.columnsManagerControllers.removeValue(forKey: identifier)
        }
        columnsManagerControllers[identifier] = controller

        // The manager loads and parses the external file away from the main
        // actor, then publishes the matching definitions through this callback.
        controller.beginSheet(for: parent)
    }

    @objc func showPortForwards(_ sender: Any?) {
        portForwardsWindowController.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showCommandPalette(_ sender: Any?) {
        let keyWindow = NSApp.keyWindow
        let workspace = workspaceControllers.values.first { controller in
            controller.window === keyWindow || keyWindow?.parent === controller.window
        }
        workspace?.showCommandPalette(sender)
    }

    @objc private func cycleWindowsForward(_ sender: Any?) {
        cycleKeyWindow(backward: false, sender: sender)
    }

    @objc private func cycleWindowsBackward(_ sender: Any?) {
        cycleKeyWindow(backward: true, sender: sender)
    }

    private func cycleKeyWindow(backward: Bool, sender: Any?) {
        let candidates = NSApp.orderedWindows.filter {
            $0.isVisible && $0.canBecomeKey && $0.parent == nil
                && !$0.collectionBehavior.contains(.ignoresCycle)
        }
        guard candidates.count > 1 else { return }

        if backward {
            candidates.last?.makeKeyAndOrderFront(sender)
        } else {
            let current = NSApp.keyWindow
            let next = candidates.first { $0 !== current }
            current?.orderBack(sender)
            next?.makeKeyAndOrderFront(sender)
        }
    }

    private func applyAppearance(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func installMainMenu() {
        let actions = NativeMainMenuActions(
            target: self,
            showSettings: #selector(showSettings(_:)),
            newClusterWindow: #selector(showClusterManager),
            showCommandPalette: #selector(showCommandPalette(_:)),
            showPortForwards: #selector(showPortForwards(_:)),
            cycleWindowsForward: #selector(cycleWindowsForward(_:)),
            cycleWindowsBackward: #selector(cycleWindowsBackward(_:))
        )
        let menu = NativeMainMenuBuilder.make(actions: actions)
        NSApp.windowsMenu = menu.window
        NSApp.mainMenu = menu.main
    }
}
