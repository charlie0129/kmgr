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
    private let objectSearchProvider: any ObjectSearchProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let operationProvider: any ResourceOperationProviding
    private let logProvider: any LogStreamProviding
    private let execProvider: any ExecSessionProviding
    private let preferencesStore: AppPreferencesStore
    private let engineColumnsConfigurationPath: String
    private let restorationStore: WorkspaceRestorationStore
    private let settingsWindowController: SettingsWindowController
    private let portForwardCoordinator: PortForwardCoordinator
    private let portForwardsWindowController: PortForwardsWindowController
    private let engineSupervisor: EngineSupervisor
    private var engineStateObserver: UUID?
    private var readyEngineInstanceID: String?
    private var helperRecoveryRequired = false
    private var workspaceRecoveryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var logWindowControllers: [ObjectIdentifier: LogWindowController] = [:]
    private var terminalWindowControllers: [ObjectIdentifier: TerminalWindowController] = [:]
    private var isTerminating = false
    private var terminationTask: Task<Void, Never>?
    private var restorationTasks: [Task<Void, Never>] = []
    private var restorationAttemptsRemaining = 0
    private var didRestoreWorkspace = false
    private var shouldShowChooserAfterRestore = false

    override init() {
        let preferences = AppPreferencesStore()
        self.preferencesStore = preferences
        self.engineColumnsConfigurationPath = preferences.current.columnsConfigurationPath
        var engineConfiguration = EngineSupervisor.Configuration.bundled()
        engineConfiguration.columnsConfigurationPath = preferences.current.columnsConfigurationPath
        engineConfiguration.metricsRefreshSeconds = preferences.current.metricsRefreshSeconds
        let supervisor = EngineSupervisor(configuration: engineConfiguration)
        self.engineSupervisor = supervisor
        self.restorationStore = WorkspaceRestorationStore()
        let settings = SettingsWindowController(preferencesStore: preferences)
        self.settingsWindowController = settings
        self.clusterContextProvider = EngineClusterContextProvider(
            supervisor: supervisor
        )
        self.workspaceResourceProvider = EngineWorkspaceResourceProvider(
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
            coordinator: portForwards
        )
        super.init()
        settings.onPreferencesChanged = { [weak self] preferences in
            self?.applyAppearance(preferences.appearance)
        }
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = Application()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        applyAppearance(preferencesStore.current.appearance)
        engineStateObserver = engineSupervisor.observeState { [weak self] state in
            self?.engineStateChanged(state)
        }
        engineSupervisor.start()
        restoreWorkspacesOrShowChooser()
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
                    portForwardCoordinator.register(sessionID: session.sessionID)
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
                let context = record.contextName.isEmpty ? "unknown context" : record.contextName
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
        if let engineStateObserver {
            engineSupervisor.removeStateObserver(engineStateObserver)
            self.engineStateObserver = nil
        }
        for task in workspaceRecoveryTasks.values { task.cancel() }
        workspaceRecoveryTasks.removeAll()
        terminationTask = Task { [engineSupervisor, portForwardCoordinator] in
            await portForwardCoordinator.stopAllActive()
            portForwardCoordinator.stopWatching()
            await engineSupervisor.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        if portForwardCoordinator.hasActiveForwards {
            showPortForwards(nil)
        } else {
            showClusterManager()
        }
        return true
    }

    @objc private func showClusterManager() {
        // Every Command-N starts a fresh chooser so the user can open several
        // independent workspaces, including the same context more than once.
        let controller = ClusterManagerWindowController(provider: clusterContextProvider)
        let identifier = ObjectIdentifier(controller)
        chooserControllers[identifier] = controller
        controller.onOpenSession = { [weak self] session in
            self?.openWorkspace(
                for: session,
                restoration: ClusterWindowRestorationRecord(
                    contextName: session.contextName,
                    contextReference: session.contextReference
                )
            )
        }
        controller.onClose = { [weak self] in
            self?.chooserControllers.removeValue(forKey: identifier)
        }
        controller.showWindow(nil)
    }

    private func openWorkspace(
        for session: OpenedClusterSession,
        restoration: ClusterWindowRestorationRecord
    ) {
        let controller = ClusterWorkspaceWindowController(
            session: session,
            provider: workspaceResourceProvider,
            objectSearchProvider: objectSearchProvider,
            objectDetailProvider: objectDetailProvider,
            operationProvider: operationProvider,
            logProvider: logProvider,
            execProvider: execProvider,
            portForwards: portForwardCoordinator,
            columnsConfigurationPath: engineColumnsConfigurationPath,
            logDisplayConfiguration: LogDisplayConfiguration(
                preferences: preferencesStore.current.logs
            ),
            restoration: restoration,
            onShowPortForwards: { [weak self] in
                self?.showPortForwards(nil)
            }
        )
        let identifier = ObjectIdentifier(controller)
        workspaceControllers[identifier] = controller
        controller.onClose = { [weak self] in
            if self?.isTerminating == false {
                try? self?.restorationStore.remove(id: restoration.id)
            }
            self?.columnsManagerControllers.removeValue(forKey: identifier)?.close()
            self?.workspaceRecoveryTasks.removeValue(forKey: identifier)?.cancel()
            self?.workspaceControllers.removeValue(forKey: identifier)
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
    }

    private func restoreWorkspacesOrShowChooser() {
        let records = restorationStore.windows
        guard !records.isEmpty else { showClusterManager(); return }
        restorationAttemptsRemaining = records.count
        didRestoreWorkspace = false
        shouldShowChooserAfterRestore = false
        for record in records {
            let task = Task { [weak self, clusterContextProvider] in
                guard let self else { return }
                defer { restorationAttemptFinished() }
                do {
                    let session = try await clusterContextProvider.openContext(
                        reference: record.state.contextReference
                    )
                    guard !Task.isCancelled else { return }
                    openWorkspace(for: session, restoration: record)
                    didRestoreWorkspace = true
                } catch {
                    logger.error(
                        "Workspace restore failed for context \(record.state.contextName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    shouldShowChooserAfterRestore = true
                }
            }
            restorationTasks.append(task)
        }
    }

    private func restorationAttemptFinished() {
        restorationAttemptsRemaining -= 1
        guard restorationAttemptsRemaining == 0 else { return }
        restorationTasks.removeAll()
        if shouldShowChooserAfterRestore || !didRestoreWorkspace {
            showClusterManager()
        }
    }

    private func retainAndShow(_ controller: LogWindowController) {
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
            configurationPath: configurationPath
        )
        controller.onDraftChanged = request.apply
        controller.onSaved = request.apply
        controller.onClose = { [weak self, weak controller] in
            guard self?.columnsManagerControllers[identifier] === controller else { return }
            self?.columnsManagerControllers.removeValue(forKey: identifier)
        }
        columnsManagerControllers[identifier] = controller

        // Keep the table and manager synchronized as soon as the sheet opens,
        // including definitions that were persisted outside this process.
        if let document = try? ColumnConfigurationFileStore(path: configurationPath).load() {
            let columns = document.views.first(where: { $0.match == request.match })?.columns
                ?? request.defaultColumns
            request.apply(columns)
        }
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

    private func applyAppearance(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(Product.applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = fileMenu.addItem(
            withTitle: "New Cluster Window…",
            action: #selector(showClusterManager),
            keyEquivalent: "n"
        )
        newWindowItem.target = self
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let resourceItem = NSMenuItem()
        let resourceMenu = NSMenu(title: "Resource")
        let detailsItem = resourceMenu.addItem(
            withTitle: "Open Details",
            action: #selector(ClusterWorkspaceWindowController.openResourceDetails(_:)),
            keyEquivalent: "\r"
        )
        detailsItem.keyEquivalentModifierMask = []
        resourceMenu.addItem(
            withTitle: "Open YAML",
            action: #selector(ClusterWorkspaceWindowController.openResourceYAML(_:)),
            keyEquivalent: "y"
        ).keyEquivalentModifierMask = []
        resourceMenu.addItem(
            withTitle: "Open Events",
            action: #selector(ClusterWorkspaceWindowController.openResourceEvents(_:)),
            keyEquivalent: "e"
        ).keyEquivalentModifierMask = []
        resourceMenu.addItem(.separator())
        resourceMenu.addItem(
            withTitle: "Open Logs…",
            action: #selector(ClusterWorkspaceWindowController.openResourceLogs(_:)),
            keyEquivalent: "l"
        ).keyEquivalentModifierMask = []
        resourceMenu.addItem(
            withTitle: "Open Terminal…",
            action: #selector(ClusterWorkspaceWindowController.openResourceExec(_:)),
            keyEquivalent: "s"
        ).keyEquivalentModifierMask = []
        resourceMenu.addItem(
            withTitle: "Start Port Forward…",
            action: #selector(ClusterWorkspaceWindowController.startResourcePortForward(_:)),
            keyEquivalent: "p"
        ).keyEquivalentModifierMask = []
        resourceMenu.addItem(.separator())
        resourceMenu.addItem(
            withTitle: "Scale…",
            action: #selector(ClusterWorkspaceWindowController.scaleResourceSelection(_:)),
            keyEquivalent: ""
        )
        resourceMenu.addItem(
            withTitle: "Rollout Restart…",
            action: #selector(ClusterWorkspaceWindowController.restartResourceSelection(_:)),
            keyEquivalent: ""
        )
        resourceMenu.addItem(
            withTitle: "Edit Labels / Annotations…",
            action: #selector(ClusterWorkspaceWindowController.editResourceMetadata(_:)),
            keyEquivalent: ""
        )
        resourceMenu.addItem(.separator())
        resourceMenu.addItem(
            withTitle: "Copy Name",
            action: #selector(ClusterWorkspaceWindowController.copyResourceName(_:)),
            keyEquivalent: ""
        )
        resourceMenu.addItem(
            withTitle: "Copy Namespace/Name",
            action: #selector(ClusterWorkspaceWindowController.copyResourceNamespacedName(_:)),
            keyEquivalent: ""
        )
        resourceMenu.addItem(
            withTitle: "Copy kubectl Reference",
            action: #selector(ClusterWorkspaceWindowController.copyResourceReference(_:)),
            keyEquivalent: ""
        )
        resourceMenu.addItem(.separator())
        let deleteItem = resourceMenu.addItem(
            withTitle: "Delete…",
            action: #selector(ClusterWorkspaceWindowController.deleteResourceSelection(_:)),
            keyEquivalent: "\u{8}"
        )
        deleteItem.keyEquivalentModifierMask = .command
        resourceItem.submenu = resourceMenu
        mainMenu.addItem(resourceItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(.separator())
        let backItem = windowMenu.addItem(
            withTitle: "Back",
            action: #selector(ClusterWorkspaceWindowController.navigateBack(_:)),
            keyEquivalent: "["
        )
        backItem.keyEquivalentModifierMask = .command
        let forwardItem = windowMenu.addItem(
            withTitle: "Forward",
            action: #selector(ClusterWorkspaceWindowController.navigateForward(_:)),
            keyEquivalent: "]"
        )
        forwardItem.keyEquivalentModifierMask = .command
        windowMenu.addItem(.separator())
        let paletteItem = windowMenu.addItem(
            withTitle: "Command Palette…",
            action: #selector(showCommandPalette(_:)),
            keyEquivalent: "k"
        )
        paletteItem.keyEquivalentModifierMask = .command
        paletteItem.target = self
        let portForwardsItem = windowMenu.addItem(
            withTitle: "Port Forwards",
            action: #selector(showPortForwards(_:)),
            keyEquivalent: ""
        )
        portForwardsItem.target = self
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
