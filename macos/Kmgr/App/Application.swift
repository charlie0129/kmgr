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
    private let clusterContextProvider: any ClusterContextProviding
    private let workspaceResourceProvider: any WorkspaceResourceProviding
    private let objectSearchProvider: any ObjectSearchProviding
    private let objectDetailProvider: any ObjectDetailProviding
    private let portForwardCoordinator: PortForwardCoordinator
    private let portForwardsWindowController: PortForwardsWindowController
    private let engineSupervisor: EngineSupervisor
    private var isTerminating = false
    private var terminationTask: Task<Void, Never>?

    override init() {
        let supervisor = EngineSupervisor()
        self.engineSupervisor = supervisor
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
        let portForwards = PortForwardCoordinator(
            provider: EnginePortForwardProvider(connection: supervisor.connection)
        )
        self.portForwardCoordinator = portForwards
        self.portForwardsWindowController = PortForwardsWindowController(
            coordinator: portForwards
        )
        super.init()
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
        engineSupervisor.start()
        showClusterManager()
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Kmgr application launched")
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
            self?.openWorkspace(for: session)
        }
        controller.onClose = { [weak self] in
            self?.chooserControllers.removeValue(forKey: identifier)
        }
        controller.showWindow(nil)
    }

    private func openWorkspace(for session: OpenedClusterSession) {
        let controller = ClusterWorkspaceWindowController(
            session: session,
            provider: workspaceResourceProvider,
            objectSearchProvider: objectSearchProvider,
            objectDetailProvider: objectDetailProvider,
            portForwards: portForwardCoordinator,
            onShowPortForwards: { [weak self] in
                self?.showPortForwards(nil)
            }
        )
        let identifier = ObjectIdentifier(controller)
        workspaceControllers[identifier] = controller
        controller.onClose = { [weak self] in
            self?.workspaceControllers.removeValue(forKey: identifier)
        }
        controller.onStartPortForward = { [weak controller] identity in
            controller?.showPortForwardConfiguration(identity)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
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

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
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

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
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
