import AppKit
import KmgrCore

/// Application-owned actions used by the native menu bar. Standard editing,
/// document, and window actions deliberately remain nil-targeted so AppKit can
/// route them through the active responder chain.
@MainActor
struct NativeMainMenuActions {
    let target: AnyObject
    let showSettings: Selector
    let newClusterWindow: Selector
    let showCommandPalette: Selector
    let showPortForwards: Selector
    let cycleWindowsForward: Selector
    let cycleWindowsBackward: Selector
}

@MainActor
struct NativeMainMenu {
    let main: NSMenu
    let window: NSMenu
}

@MainActor
enum NativeMainMenuBuilder {
    static func make(actions: NativeMainMenuActions) -> NativeMainMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenu(actions: actions))
        mainMenu.addItem(fileMenu(actions: actions))
        mainMenu.addItem(editMenu())
        mainMenu.addItem(resourceMenu())

        let windowItem = NSMenuItem()
        let windowMenu = makeWindowMenu(actions: actions)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return NativeMainMenu(main: mainMenu, window: windowMenu)
    }

    private static func appMenu(actions: NativeMainMenuActions) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        addApplicationItem(
            to: menu,
            title: "Settings…",
            action: actions.showSettings,
            keyEquivalent: ",",
            actions: actions
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(Product.applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private static func fileMenu(actions: NativeMainMenuActions) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        addApplicationItem(
            to: menu,
            title: "New Cluster Window…",
            action: actions.newClusterWindow,
            keyEquivalent: "n",
            actions: actions
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        addResponderItem(
            to: menu,
            title: "Save",
            action: #selector(NSDocument.save(_:)),
            keyEquivalent: "s"
        )
        item.submenu = menu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        addResponderItem(
            to: menu,
            title: "Undo",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        )
        addResponderItem(
            to: menu,
            title: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        addResponderItem(
            to: menu,
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        addResponderItem(
            to: menu,
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(.separator())

        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        addFindItem(
            to: findMenu,
            title: "Find…",
            action: .showFindPanel,
            keyEquivalent: "f"
        )
        addFindItem(
            to: findMenu,
            title: "Find Next",
            action: .next,
            keyEquivalent: "g"
        )
        addFindItem(
            to: findMenu,
            title: "Find Previous",
            action: .previous,
            keyEquivalent: "g",
            modifiers: [.command, .shift]
        )
        findItem.submenu = findMenu
        menu.addItem(findItem)

        item.submenu = menu
        return item
    }

    private static func resourceMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Resource")
        addResponderItem(
            to: menu,
            title: "Focus Resource Filter",
            action: #selector(ClusterWorkspaceWindowController.focusResourceFilter(_:)),
            keyEquivalent: "/",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Choose Namespace…",
            action: #selector(ClusterWorkspaceWindowController.chooseNamespace(_:)),
            keyEquivalent: "n",
            modifiers: [.command, .shift]
        )
        addResponderItem(
            to: menu,
            title: "Refresh API Resources",
            action: #selector(ClusterWorkspaceWindowController.refreshAPIResources(_:))
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Move Selection Up",
            action: #selector(ClusterWorkspaceWindowController.moveResourceSelectionUp(_:)),
            keyEquivalent: "k",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Move Selection Down",
            action: #selector(ClusterWorkspaceWindowController.moveResourceSelectionDown(_:)),
            keyEquivalent: "j",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Extend Selection Up",
            action: #selector(ClusterWorkspaceWindowController.extendResourceSelectionUp(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.shift]
        )
        addResponderItem(
            to: menu,
            title: "Extend Selection Down",
            action: #selector(ClusterWorkspaceWindowController.extendResourceSelectionDown(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.shift]
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Enter Subresource",
            action: #selector(ClusterWorkspaceWindowController.enterResource(_:)),
            keyEquivalent: "\r",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Describe",
            action: #selector(ClusterWorkspaceWindowController.openResourceDetails(_:)),
            keyEquivalent: "d",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Open YAML in Details",
            action: #selector(ClusterWorkspaceWindowController.openResourceYAML(_:)),
            keyEquivalent: "y",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Open YAML in New Window",
            action: #selector(ClusterWorkspaceWindowController.openResourceYAMLSnapshot(_:)),
            keyEquivalent: "y",
            modifiers: [.shift]
        )
        addResponderItem(
            to: menu,
            title: "Open Events",
            action: #selector(ClusterWorkspaceWindowController.openResourceEvents(_:)),
            keyEquivalent: "e",
            modifiers: []
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Open Logs…",
            action: #selector(ClusterWorkspaceWindowController.openResourceLogs(_:)),
            keyEquivalent: "l",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Open Terminal",
            action: #selector(ClusterWorkspaceWindowController.openResourceExec(_:)),
            keyEquivalent: "s",
            modifiers: []
        )
        addResponderItem(
            to: menu,
            title: "Configure Terminal…",
            action: #selector(ClusterWorkspaceWindowController.configureResourceExec(_:)),
            keyEquivalent: "s",
            modifiers: [.shift]
        )
        addResponderItem(
            to: menu,
            title: "Start Port Forward…",
            action: #selector(ClusterWorkspaceWindowController.startResourcePortForward(_:)),
            keyEquivalent: "p",
            modifiers: []
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Scale…",
            action: #selector(ClusterWorkspaceWindowController.scaleResourceSelection(_:))
        )
        addResponderItem(
            to: menu,
            title: "Rollout Restart…",
            action: #selector(ClusterWorkspaceWindowController.restartResourceSelection(_:))
        )
        addResponderItem(
            to: menu,
            title: "Edit Labels / Annotations…",
            action: #selector(ClusterWorkspaceWindowController.editResourceMetadata(_:))
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Copy Name",
            action: #selector(ClusterWorkspaceWindowController.copyResourceName(_:))
        )
        addResponderItem(
            to: menu,
            title: "Copy Namespace/Name",
            action: #selector(ClusterWorkspaceWindowController.copyResourceNamespacedName(_:))
        )
        addResponderItem(
            to: menu,
            title: "Copy kubectl Reference",
            action: #selector(ClusterWorkspaceWindowController.copyResourceReference(_:))
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Delete…",
            action: #selector(ClusterWorkspaceWindowController.deleteResourceSelection(_:)),
            keyEquivalent: "\u{8}"
        )
        item.submenu = menu
        return item
    }

    private static func makeWindowMenu(actions: NativeMainMenuActions) -> NSMenu {
        let menu = NSMenu(title: "Window")
        addResponderItem(
            to: menu,
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(.separator())
        addResponderItem(
            to: menu,
            title: "Back",
            action: #selector(ClusterWorkspaceWindowController.navigateBack(_:)),
            keyEquivalent: "["
        )
        addResponderItem(
            to: menu,
            title: "Forward",
            action: #selector(ClusterWorkspaceWindowController.navigateForward(_:)),
            keyEquivalent: "]"
        )
        menu.addItem(.separator())
        addApplicationItem(
            to: menu,
            title: "Command Palette…",
            action: actions.showCommandPalette,
            keyEquivalent: "k",
            actions: actions
        )
        addApplicationItem(
            to: menu,
            title: "Port Forwards",
            action: actions.showPortForwards,
            keyEquivalent: "",
            actions: actions
        )
        menu.addItem(.separator())
        addApplicationItem(
            to: menu,
            title: "Cycle Through Windows",
            action: actions.cycleWindowsForward,
            keyEquivalent: "`",
            actions: actions
        )
        addApplicationItem(
            to: menu,
            title: "Cycle Back Through Windows",
            action: actions.cycleWindowsBackward,
            keyEquivalent: "`",
            modifiers: [.command, .shift],
            actions: actions
        )
        addResponderItem(
            to: menu,
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:))
        )
        return menu
    }

    @discardableResult
    private static func addResponderItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = menu.addItem(
            withTitle: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @discardableResult
    private static func addApplicationItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command,
        actions: NativeMainMenuActions
    ) -> NSMenuItem {
        let item = menu.addItem(
            withTitle: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = actions.target
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func addFindItem(
        to menu: NSMenu,
        title: String,
        action: NSFindPanelAction,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) {
        let item = addResponderItem(
            to: menu,
            title: title,
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: keyEquivalent,
            modifiers: modifiers
        )
        item.tag = Int(action.rawValue)
    }
}
