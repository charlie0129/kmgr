import AppKit
import KmgrCore
import KmgrIPC
import OSLog

@main
@MainActor
final class Application: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let logger = Logger(subsystem: Product.bundleIdentifier, category: "application")
    private var chooserControllers: [ObjectIdentifier: ClusterManagerWindowController] = [:]
    private var workspaceControllers: [ObjectIdentifier: ClusterWorkspaceWindowController] = [:]
    private var columnsManagerControllers: [ObjectIdentifier: ColumnsManagerWindowController] = [:]
    private let clusterContextProvider: any ClusterContextProviding
    private let kubeconfigSourceStore: KubeconfigSourceStore
    private let workspaceResourceProvider: any WorkspaceResourceProviding
    private let clusterConnectionActivityProvider: any ClusterConnectionActivityProviding
    private let clusterOperationHistoryProvider: any ClusterOperationHistoryProviding
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
    /// Helper-owned refresh settings are launch-scoped. Keep the Swift
    /// viewport-interest cadence on the same value until the next relaunch,
    /// even if Settings has already persisted a future value.
    private let engineMetricsRefreshSeconds: Int
    private let columnConfigurationCoordinator: ColumnConfigurationCoordinator
    private let restorationStore: WorkspaceRestorationStore
    private let workspaceFrameBookmarkStore: WorkspaceFrameBookmarkStore
    private let workspaceWindowSizeStore: ClusterWorkspaceWindowSizeStore
    private var pendingRestorationNotice: ClusterManagerInitialNotice?
    private let settingsWindowController: SettingsWindowController
    private let portForwardCoordinator: PortForwardCoordinator
    private let portForwardsWindowController: PortForwardsWindowController
    private let contextualShortcutsCoordinator: ContextualShortcutsCoordinator
    private let engineSupervisor: EngineSupervisor
    private var engineStateObserver: UUID?
    private var readyEngineInstanceID: String?
    private var didObserveApplicationActivation = false
    private var didPresentInitialWorkspaces = false
    private var initialPresentationFallbackTask: Task<Void, Never>?
    private var helperRecoveryRequired = false
    private var hasPresentedEngineFailureDiagnostics = false
    private var workspaceRecoveryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var restoredWorkspaceAttempts: [
        ObjectIdentifier: RestoredWorkspaceConnectionAttempt
    ] = [:]
    private var logWindowControllers: [ObjectIdentifier: LogWindowController] = [:]
    private var engineDiagnosticsWindowController: EngineDiagnosticsWindowController?
    private var terminalWindowControllers: [ObjectIdentifier: TerminalWindowController] = [:]
    private var isTerminating = false
    private var isAutoTerminatingAfterLastWindowClosed = false
    private var terminationTask: Task<Void, Never>?

    override init() {
        let preferences = AppPreferencesStore()
        self.preferencesStore = preferences
        self.tableLayoutStore = TableLayoutStore()
        self.kubeconfigSourceStore = KubeconfigSourceStore.shared
        self.engineColumnsConfigurationPath = preferences.current.columnsConfigurationPath
        self.engineMetricsRefreshSeconds = preferences.current.metricsRefreshSeconds
        self.columnConfigurationCoordinator = ColumnConfigurationCoordinator(
            path: preferences.current.columnsConfigurationPath
        )
        var engineConfiguration = EngineSupervisor.Configuration.bundled()
        engineConfiguration.columnsConfigurationPath = preferences.current.columnsConfigurationPath
        engineConfiguration.metricsRefreshSeconds = preferences.current.metricsRefreshSeconds
        engineConfiguration.nodeShellStartupTimeoutSeconds =
            preferences.current.nodeShell.startupTimeoutSeconds
        engineConfiguration.advancedPerformance = preferences.current.advancedPerformance
        let supervisor = EngineSupervisor(configuration: engineConfiguration)
        self.engineSupervisor = supervisor
        let restorationStore = WorkspaceRestorationStore()
        self.restorationStore = restorationStore
        self.workspaceFrameBookmarkStore = WorkspaceFrameBookmarkStore()
        self.workspaceWindowSizeStore = ClusterWorkspaceWindowSizeStore()
        self.pendingRestorationNotice = restorationStore.loadIssue.map {
            ClusterManagerInitialNotice(
                title: "Workspace restoration skipped",
                message: $0.message
            )
        }
        let settings = SettingsWindowController(preferencesStore: preferences)
        self.settingsWindowController = settings
        let clusterConnectionTimeout = Duration.seconds(Int64(
            preferences.current.advancedPerformance.clusterConnectionTimeoutSeconds
        ))
        let kubernetesRequestTimeout = Duration.seconds(Int64(
            preferences.current.advancedPerformance.kubernetesRequestTimeoutSeconds
        ))
        self.clusterContextProvider = EngineClusterContextProvider(
            supervisor: supervisor,
            listTimeout: kubernetesRequestTimeout,
            openTimeout: clusterConnectionTimeout
        )
        self.workspaceResourceProvider = EngineWorkspaceResourceProvider(
            connection: supervisor.connection,
            unaryTimeout: kubernetesRequestTimeout
        )
        self.clusterConnectionActivityProvider = EngineClusterConnectionActivityProvider(
            connection: supervisor.connection
        )
        self.clusterOperationHistoryProvider = EngineClusterOperationHistoryProvider(
            connection: supervisor.connection
        )
        self.optionalResourceCatalogProvider = EngineOptionalResourceCatalogProvider(
            connection: supervisor.connection,
            timeout: kubernetesRequestTimeout
        )
        self.columnPreviewProvider = EngineColumnPreviewProvider(
            connection: supervisor.connection,
            timeout: kubernetesRequestTimeout
        )
        self.objectSearchProvider = EngineObjectSearchProvider(
            connection: supervisor.connection,
            unaryTimeout: kubernetesRequestTimeout
        )
        self.objectDetailProvider = EngineObjectDetailProvider(
            connection: supervisor.connection,
            unaryTimeout: kubernetesRequestTimeout
        )
        self.operationProvider = EngineOperationProvider(
            connection: supervisor.connection,
            unaryTimeout: kubernetesRequestTimeout
        )
        self.logProvider = EngineLogStreamProvider(
            connection: supervisor.connection,
            resolutionTimeout: kubernetesRequestTimeout
        )
        self.execProvider = EngineExecSessionProvider(connection: supervisor.connection)
        let portForwards = PortForwardCoordinator(
            provider: EnginePortForwardProvider(
                connection: supervisor.connection,
                unaryTimeout: kubernetesRequestTimeout
            )
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
        self.contextualShortcutsCoordinator.shortcutsWindowController.onUserClose = {
            self.contextualShortcutsCoordinator.closeFromUser()
        }
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
                engineDiagnosticsWindowController?.applyDisplayConfiguration(configuration)
            }
            if delta.contains(.operationHistory) {
                for controller in workspaceControllers.values {
                    controller.applyOperationHistoryLimit(
                        preferences.diagnostics.completedOperationHistoryLimit
                    )
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
        contextualShortcutsCoordinator.start()
        NSApp.activate(ignoringOtherApps: true)
        // Finder/LaunchServices can invoke didFinishLaunching before its
        // activation notification, or while isActive is already true without
        // sending another notification. Prefer the notification boundary and
        // retain a short active-state fallback for the latter launch path.
        scheduleInitialPresentationFallback()
        logger.info("Kmgr application launched")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A bundle launch can present a window before AppKit has completed
        // activation. Reassert every pending raw frame at that boundary so
        // the launch Space cannot replace the saved display choice.
        initialPresentationFallbackTask?.cancel()
        initialPresentationFallbackTask = nil
        completeInitialApplicationActivation()
    }

    private func scheduleInitialPresentationFallback() {
        guard !didObserveApplicationActivation,
            !didPresentInitialWorkspaces,
            !isTerminating
        else { return }
        initialPresentationFallbackTask?.cancel()
        initialPresentationFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isTerminating
            else { return }
            self.initialPresentationFallbackTask = nil
            if NSApp.isActive {
                self.completeInitialApplicationActivation()
            } else {
                // Some direct executable launches do not receive a separate
                // activation callback. Still present after the bounded wait;
                // the controller keeps the raw frame protected and will
                // repair it if activation arrives later.
                self.presentInitialWorkspacesAsFallback()
            }
        }
    }

    private func completeInitialApplicationActivation() {
        guard !isTerminating else { return }
        didObserveApplicationActivation = true
        presentInitialWorkspacesIfPossible()
        repairInitialPlacements()
    }

    private func presentInitialWorkspacesAsFallback() {
        guard !didPresentInitialWorkspaces, !isTerminating else { return }
        didPresentInitialWorkspaces = true
        restoreWorkspacesOrShowChooser()
        repairInitialPlacements()
    }

    private func repairInitialPlacements() {
        for controller in workspaceControllers.values {
            controller.repairInitialPlacementAfterActivation()
        }
    }

    private func presentInitialWorkspacesIfPossible() {
        guard !didPresentInitialWorkspaces, !isTerminating, NSApp.isActive else {
            return
        }
        didPresentInitialWorkspaces = true
        restoreWorkspacesOrShowChooser()
    }

    private func engineStateChanged(_ state: EngineConnectionState) {
        switch state {
        case .ready(let information):
            let hadReadyGeneration = readyEngineInstanceID != nil
            let isNewGeneration = readyEngineInstanceID.map {
                $0 != information.instanceID
            } ?? false
            let recoveredAfterDisconnect = helperRecoveryRequired
            readyEngineInstanceID = information.instanceID
            if hadReadyGeneration && (isNewGeneration || recoveredAfterDisconnect) {
                for controller in workspaceControllers.values {
                    controller.engineDidRestart()
                }
            }
            guard recoveredAfterDisconnect || isNewGeneration else { return }
            helperRecoveryRequired = false
            hasPresentedEngineFailureDiagnostics = false
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
            guard !hasPresentedEngineFailureDiagnostics else { return }
            hasPresentedEngineFailureDiagnostics = true
            showEngineDiagnostics(nil)
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
                        reference: contextReference,
                        addedKubeconfigPaths: self.kubeconfigSourceStore.paths
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
        guard !portForwardCoordinator.hasActiveForwards else { return false }
        // AppKit may ask to terminate before the last window's
        // `windowWillClose` callback has removed its restoration record. Keep
        // this fact for the final snapshot so Cmd-W on every workspace means
        // an explicitly empty restore set.
        if !isTerminating {
            isAutoTerminatingAfterLastWindowClosed = true
            // The delegate can run on either side of the final
            // `windowWillClose` callback. Clear now so a late termination
            // snapshot cannot preserve controllers that are already gone.
            try? restorationStore.removeAllOpenWindows()
            workspaceControllers.values.forEach {
                $0.onRestorationCheckpoint = nil
                $0.onActivationCheckpoint = nil
                $0.onFrameCheckpoint = nil
                $0.onWindowSizeCheckpoint = nil
            }
        }
        return true
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
                isAutoTerminatingAfterLastWindowClosed = false
                return .terminateCancel
            }
        }
        isTerminating = true
        initialPresentationFallbackTask?.cancel()
        initialPresentationFallbackTask = nil
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
        checkpointWorkspaceStateForTermination()
        for controller in chooserControllers.values {
            controller.prepareForTermination()
        }
        for controller in workspaceControllers.values {
            controller.prepareForTermination()
        }
        for controller in logWindowControllers.values {
            controller.prepareForTermination()
        }
        engineDiagnosticsWindowController?.prepareForTermination()
        for controller in terminalWindowControllers.values {
            controller.prepareForTermination()
        }
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
        if !isTerminating {
            checkpointWorkspaceStateForTermination()
        }
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
        // Flush a live editor before opening the chooser. The restoration
        // store remains the single source used after the user picks a context.
        let sourceWorkspace = activeWorkspaceController
        let sourceWindowFrame = sourceWorkspace?.window?.frame
        _ = sourceWorkspace?.checkpointActiveWorkspace()
        let initialNotice = pendingRestorationNotice
        pendingRestorationNotice = nil
        let controller = ClusterManagerWindowController(
            provider: clusterContextProvider,
            sourceStore: kubeconfigSourceStore,
            initialNotice: initialNotice,
            tableLayoutStore: tableLayoutStore
        )
        let identifier = ObjectIdentifier(controller)
        chooserControllers[identifier] = controller
        controller.onOpenSession = { [weak self] session in
            guard let self else { return }
            let initialNamespace = preferencesStore.current.defaultNamespace
                .initialSelection(contextDefaultNamespace: session.defaultNamespace)
            var initialState = restorationStore.lastState(for: session.contextReference)
                ?? ClusterWindowRestorationState(
                    contextName: session.contextName,
                    contextReference: session.contextReference,
                    namespaceScope: NamespaceScope(initialNamespace)
                )
            // The opaque reference is the identity. The display name may have
            // changed in the kubeconfig since this state was recorded.
            initialState.contextName = session.contextName
            initialState.contextReference = session.contextReference
            let placement = workspaceFrameBookmarkStore.bookmark(
                for: session.contextReference
            ).map {
                WorkspaceWindowPlacementMode.contextBookmark(
                    frame: $0.frame
                )
            } ?? .fresh
            _ = openWorkspace(
                for: session,
                restoration: ClusterWindowRestorationRecord(
                    state: initialState
                ),
                initialWindowFrameSize: workspaceWindowSizeStore.lastSize,
                placement: placement,
                preferredWindowFrame: sourceWindowFrame
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
        initialWindowFrameSize: ClusterWorkspaceWindowSize? = nil,
        placement: WorkspaceWindowPlacementMode = .fresh,
        preferredWindowFrame: NSRect? = nil,
        suppressInitialActivation: Bool = false,
        startsAuthenticated: Bool = true
    ) -> ClusterWorkspaceWindowController {
        // A newly opened workspace supersedes any stale last-window-close
        // notification that may have been delivered before AppKit finished
        // its termination decision.
        isAutoTerminatingAfterLastWindowClosed = false
        let controller = ClusterWorkspaceWindowController(
            session: session,
            provider: workspaceResourceProvider,
            connectionActivityProvider: clusterConnectionActivityProvider,
            operationHistoryProvider: clusterOperationHistoryProvider,
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
            resourceViewportTiming: .production(
                metricsRefreshSeconds: engineMetricsRefreshSeconds,
                overscanScreensPerSide: preferencesStore.current
                    .advancedPerformance.viewportOverscanScreensPerSide
            ),
            logDisplayConfiguration: LogDisplayConfiguration(
                preferences: preferencesStore.current.logs
            ),
            operationHistoryCompletedLimit: preferencesStore.current.diagnostics
                .completedOperationHistoryLimit,
            confirmationPreferences: { [weak self] in
                self?.preferencesStore.current.confirmations ?? ConfirmationPreferences()
            },
            resourceOperationPreferences: { [weak self] in
                self?.preferencesStore.current.resourceOperations
                    ?? ResourceOperationPreferences()
            },
            nodeShellPreferences: { [weak self] in
                self?.preferencesStore.current.nodeShell ?? NodeShellPreferences()
            },
            terminalPreferences: { [weak self] in
                self?.preferencesStore.current.terminal ?? TerminalPreferences()
            },
            saveNodeShellPreferences: { [weak self] nodeShell in
                guard let self else { return }
                var preferences = preferencesStore.current
                preferences.nodeShell = nodeShell
                try preferencesStore.save(preferences)
            },
            restoration: restoration,
            initialWindowFrameSize: initialWindowFrameSize,
            placement: placement,
            suppressInitialActivation: suppressInitialActivation,
            preferredWindowFrame: preferredWindowFrame,
            startsAuthenticated: startsAuthenticated,
            onShowPortForwards: { [weak self] in
                self?.showPortForwards(nil)
            }
        )
        let identifier = ObjectIdentifier(controller)
        workspaceControllers[identifier] = controller
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            // A closed controller can still receive trailing AppKit or model
            // callbacks during teardown. Disarm persistence before removing
            // its record so those callbacks cannot resurrect the window.
            controller.onRestorationCheckpoint = nil
            controller.onActivationCheckpoint = nil
            controller.onFrameCheckpoint = nil
            controller.onWindowSizeCheckpoint = nil
            if !isTerminating {
                try? restorationStore.remove(id: restoration.id)
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
        controller.onStartPortForwardAndShow = { [weak controller] identity in
            controller?.showPortForwardConfiguration(
                identity,
                showPortForwardsAfterStart: true
            )
        }
        controller.onOpenNewWorkspace = { [weak self, weak controller] request in
            self?.openSiblingWorkspace(request, source: controller)
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
        controller.onRestorationCheckpoint = { [weak self, weak controller] record in
            guard let self, controller != nil else { return }
            try? restorationStore.upsert(record)
        }
        controller.onActivationCheckpoint = { [weak self] record in
            guard let self else { return }
            try? self.restorationStore.activate(record)
            _ = try? self.workspaceFrameBookmarkStore.activate(
                contextReference: record.state.contextReference,
                sourceWindowID: record.id,
                frame: record.frame
            )
        }
        controller.onFrameCheckpoint = { [weak self] record in
            guard let self else { return }
            guard let frame = record.frame else { return }
            _ = try? self.workspaceFrameBookmarkStore.updateFrame(
                contextReference: record.state.contextReference,
                sourceWindowID: record.id,
                frame: frame
            )
        }
        controller.onWindowSizeCheckpoint = { [weak self] size in
            _ = self?.workspaceWindowSizeStore.save(size)
        }
        try? restorationStore.upsert(controller.restorationRecord)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if didObserveApplicationActivation || (
            placement != .restored && NSApp.isActive
        ) {
            controller.repairInitialPlacementAfterActivation()
        }
        if placement != .restored {
            // A newly opened context is immediately a valid source, even if
            // AppKit has not yet emitted a user activation notification.
            let record = controller.restorationRecord
            try? restorationStore.activate(record)
            _ = try? workspaceFrameBookmarkStore.activate(
                contextReference: record.state.contextReference,
                sourceWindowID: record.id,
                frame: record.frame
            )
        }
        return controller
    }

    /// Opens a focused sibling workspace for a destination gesture. Session
    /// creation stays at the application boundary, so the backend receives a
    /// distinct session ID while its authority-scoped discovery, LIST/WATCH,
    /// and warm raw-object caches remain reusable.
    private func openSiblingWorkspace(
        _ request: ClusterWorkspaceOpenRequest,
        source: ClusterWorkspaceWindowController?
    ) {
        guard !request.contextReference.isEmpty else {
            NSSound.beep()
            return
        }

        // The source may have a pending editor/frame change that has not yet
        // reached its debounce. Capture it before choosing the context's
        // reusable starting frame.
        _ = source?.checkpointActiveWorkspace()
        let sourceWindowFrame = source?.window?.frame
        let placement = workspaceFrameBookmarkStore.bookmark(
            for: request.contextReference
        ).map {
            WorkspaceWindowPlacementMode.contextBookmark(
                frame: $0.frame
            )
        } ?? .fresh

        // Present a shell synchronously so a Command-click or Command-Return
        // changes focus immediately. The request is deliberately kept out of
        // the shell's restoration target: validating that synthetic target
        // would start its parent LIST/WATCH before the pending request is
        // consumed, causing duplicate work. Discovery applies the request
        // exactly once after the authenticated session is ready.
        let state = ClusterWindowRestorationState(
            // The request deliberately carries the opaque reference rather
            // than a display name. Reuse the source window's presentation for
            // the short-lived shell so a newly focused window does not flash
            // an implementation-only reference while authentication runs.
            contextName: source?.session.contextName ?? request.contextReference,
            contextReference: request.contextReference,
            namespaceScope: NamespaceScope(request.namespaceScope)
        )
        let record = ClusterWindowRestorationRecord(state: state)
        let shell = RestoredWorkspaceShell(record: record)
        let controller = openWorkspace(
            for: shell.session,
            restoration: record,
            initialWindowFrameSize: workspaceWindowSizeStore.lastSize,
            placement: placement,
            preferredWindowFrame: sourceWindowFrame,
            startsAuthenticated: false
        )
        let identifier = ObjectIdentifier(controller)
        let attempt = RestoredWorkspaceConnectionAttempt(
            provider: clusterContextProvider,
            contextReference: request.contextReference,
            addedKubeconfigPaths: kubeconfigSourceStore.paths
        )
        attempt.onOpened = { [weak self, weak controller] session in
            guard let self, let controller,
                self.workspaceControllers[identifier] === controller,
                !self.isTerminating
            else { return }
            controller.recover(with: session)
            self.portForwardCoordinator.register(session: session)
        }
        attempt.onFailure = { [weak self, weak controller] error in
            guard let self, let controller,
                self.workspaceControllers[identifier] === controller,
                !self.isTerminating
            else { return }
            self.presentSiblingWorkspaceFailure(error, source: source)
            controller.engineRecoveryFailed(error)
        }
        attempt.onFinish = { [weak self, weak attempt] in
            guard let self, self.restoredWorkspaceAttempts[identifier] === attempt else {
                return
            }
            self.restoredWorkspaceAttempts.removeValue(forKey: identifier)
        }
        restoredWorkspaceAttempts[identifier] = attempt
        controller.open(request)
        attempt.start()
    }

    private func presentSiblingWorkspaceFailure(
        _ error: Error,
        source: ClusterWorkspaceWindowController?
    ) {
        let presentation = UserFacingErrorPresentation(error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Open New Workspace"
        alert.informativeText = presentation.detailedText
        alert.addButton(withTitle: "OK")
        if let parent = source?.window, parent.isVisible, parent.attachedSheet == nil {
            alert.beginSheetModal(for: parent)
        } else {
            alert.runModal()
        }
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
        var lastRestoredByContext: [
            String: (record: ClusterWindowRestorationRecord, controller: ClusterWorkspaceWindowController)
        ] = [:]
        for record in records {
            let shell = RestoredWorkspaceShell(record: record)
            let controller = openWorkspace(
                for: shell.session,
                restoration: record,
                initialWindowFrameSize: workspaceWindowSizeStore.lastSize,
                placement: .restored,
                suppressInitialActivation: true,
                startsAuthenticated: false
            )
            lastRestoredByContext[record.state.contextReference] = (
                controller.restorationRecord,
                controller
            )
            let identifier = ObjectIdentifier(controller)
            let attempt = RestoredWorkspaceConnectionAttempt(
                provider: clusterContextProvider,
                contextReference: record.state.contextReference,
                addedKubeconfigPaths: kubeconfigSourceStore.paths
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

        // A restoration document may predate frame bookmarks. Seed only the
        // last record for each context (restore order puts the previously
        // active record last), and never replace an established frame.
        for (contextReference, value) in lastRestoredByContext {
            _ = try? workspaceFrameBookmarkStore.ensure(
                contextReference: contextReference,
                sourceWindowID: value.record.id,
                frame: value.record.frame
            )
        }
        lastRestoredByContext.values.forEach {
            $0.controller.completeInitialPresentation()
        }
    }

    private func checkpointWorkspaceStateForTermination() {
        let controllers = Array(workspaceControllers.values)
        let openControllers = isAutoTerminatingAfterLastWindowClosed
            ? []
            : controllers.filter(\.isOpenForRestoration)
        if !openControllers.isEmpty {
            let active = activeWorkspaceController
            for controller in openControllers {
                if controller === active {
                    _ = controller.checkpointActiveWorkspace()
                } else {
                    controller.checkpointRestoration()
                }
            }
        }
        // Per-window checkpoints update navigation state. This final prune is
        // the authoritative open-window snapshot and clears records left by
        // any delayed callback from a controller the user already closed.
        let openWindowIDs = Set(openControllers.map(\.restorationIdentifier))
        try? restorationStore.retainOpenWindows(withIDs: openWindowIDs)
        // `applicationWillTerminate` can be delivered without a preceding
        // asynchronous termination handshake (for example, during a direct
        // test or an AppKit shutdown path). Disarm callbacks here as well as
        // in each controller's normal termination preparation.
        controllers.forEach {
            $0.onRestorationCheckpoint = nil
            $0.onActivationCheckpoint = nil
            $0.onFrameCheckpoint = nil
            $0.onWindowSizeCheckpoint = nil
        }
    }

    private var activeWorkspaceController: ClusterWorkspaceWindowController? {
        // AppKit's front-to-back order remains authoritative when a chooser,
        // sheet, or auxiliary window temporarily owns key status. This avoids
        // maintaining a second, stale-prone notion of the active workspace.
        var orderedWindows: [NSWindow] = []
        if let keyWindow = NSApp.keyWindow { orderedWindows.append(keyWindow) }
        orderedWindows.append(contentsOf: NSApp.orderedWindows)
        for window in orderedWindows {
            if let controller = workspaceControllers.values.first(where: {
                $0.window === window || window.parent === $0.window
            }) {
                return controller
            }
        }
        return nil
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

    @objc private func showEngineDiagnostics(_ sender: Any?) {
        if let controller = engineDiagnosticsWindowController {
            controller.showWindow(sender)
            controller.window?.makeKeyAndOrderFront(sender)
        } else {
            let controller = EngineDiagnosticsWindowController(
                store: engineSupervisor.diagnosticsStore,
                displayConfiguration: LogDisplayConfiguration(
                    preferences: preferencesStore.current.logs
                )
            )
            engineDiagnosticsWindowController = controller
            controller.onClose = { [weak self, weak controller] in
                guard self?.engineDiagnosticsWindowController === controller else {
                    return
                }
                self?.engineDiagnosticsWindowController = nil
            }
            controller.showWindow(sender)
            controller.window?.makeKeyAndOrderFront(sender)
        }
        for controller in workspaceControllers.values {
            controller.clearEngineRestartNotice()
        }
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
        if engineDiagnosticsWindowController?.window?.isVisible == true {
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
            showEngineDiagnostics: #selector(showEngineDiagnostics(_:)),
            showPortForwards: #selector(showPortForwards(_:)),
            toggleShortcuts: #selector(toggleShortcuts(_:)),
            showHelp: #selector(showHelp(_:))
        )
        let menu = NativeMainMenuBuilder.make(actions: actions)
        NSApp.mainMenu = menu.main
        NSApp.servicesMenu = menu.services
        NSApp.windowsMenu = menu.window
        NSApp.helpMenu = menu.help
    }

    @objc private func toggleShortcuts(_ sender: Any?) {
        contextualShortcutsCoordinator.toggle()
    }

    @objc private func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/charlie0129/kmgr"),
            NSWorkspace.shared.open(url)
        else {
            NSSound.beep()
            return
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleShortcuts(_:)) {
            menuItem.title = contextualShortcutsCoordinator.isEnabled
                ? "Hide Shortcuts" : "Show Shortcuts"
            menuItem.state = contextualShortcutsCoordinator.isEnabled ? .on : .off
            return true
        }
        return true
    }
}
