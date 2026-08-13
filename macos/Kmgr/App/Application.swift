import AppKit
import KmgrCore
import OSLog

@main
@MainActor
final class Application: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: Product.bundleIdentifier, category: "application")
    private var windowController: NSWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = Application()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        showClusterManager()
        NSApp.activate(ignoringOtherApps: true)
        logger.info("Kmgr application launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func showClusterManager() {
        if let windowController {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = ClusterManagerWindowController()
        windowController = controller
        controller.showWindow(nil)
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
