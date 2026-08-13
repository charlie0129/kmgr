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
    private let engineSupervisor: EngineSupervisor
    private var isTerminating = false

    override init() {
        let supervisor = EngineSupervisor()
        self.engineSupervisor = supervisor
        self.clusterContextProvider = EngineClusterContextProvider(
            supervisor: supervisor
        )
        self.workspaceResourceProvider = EngineWorkspaceResourceProvider(
            connection: supervisor.connection
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
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { [engineSupervisor] in
            await engineSupervisor.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
            provider: workspaceResourceProvider
        )
        let identifier = ObjectIdentifier(controller)
        workspaceControllers[identifier] = controller
        controller.onClose = { [weak self] in
            self?.workspaceControllers.removeValue(forKey: identifier)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
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
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
