import AppKit
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Native main menu")
struct NativeMainMenuBuilderTests {
    @Test("standard document and editing commands use the responder chain")
    func responderChainCommands() throws {
        let built = makeMenu()
        let file = try #require(submenu("File", in: built.main))
        let edit = try #require(submenu("Edit", in: built.main))

        let close = try #require(file.item(withTitle: "Close Window"))
        expectResponderItem(
            close,
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let addKubeconfig = try #require(file.item(withTitle: "Add Kubeconfig Files…"))
        expectResponderItem(
            addKubeconfig,
            action: #selector(ClusterManagerWindowController.addKubeconfigFiles(_:)),
            keyEquivalent: "o"
        )
        let save = try #require(file.item(withTitle: "Save"))
        expectResponderItem(
            save,
            action: #selector(NSDocument.save(_:)),
            keyEquivalent: "s"
        )

        for (title, selector, key) in [
            ("Undo", NSSelectorFromString("undo:"), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSResponder.selectAll(_:)), "a"),
        ] {
            let item = try #require(edit.item(withTitle: title))
            expectResponderItem(item, action: selector, keyEquivalent: key)
        }
        let redo = try #require(edit.item(withTitle: "Redo"))
        expectResponderItem(
            redo,
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        )
    }

    @Test("find commands carry native panel actions and key equivalents")
    func findCommands() throws {
        let built = makeMenu()
        let edit = try #require(submenu("Edit", in: built.main))
        let find = try #require(edit.item(withTitle: "Find")?.submenu)

        for (title, action, modifiers) in [
            ("Find…", NSFindPanelAction.showFindPanel, NSEvent.ModifierFlags.command),
            ("Find Next", .next, .command),
            ("Find Previous", .previous, [.command, .shift]),
        ] {
            let item = try #require(find.item(withTitle: title))
            #expect(item.target == nil)
            #expect(item.action == #selector(NSTextView.performFindPanelAction(_:)))
            #expect(item.tag == Int(action.rawValue))
            #expect(item.keyEquivalentModifierMask == modifiers)
        }
        #expect(find.item(withTitle: "Find…")?.keyEquivalent == "f")
        #expect(find.item(withTitle: "Find Next")?.keyEquivalent == "g")
        #expect(find.item(withTitle: "Find Previous")?.keyEquivalent == "g")
    }

    @Test("window navigation remains discoverable")
    func windowCommands() throws {
        let target = MenuTarget()
        let built = makeMenu(target: target)
        let window = built.window

        let back = try #require(window.item(withTitle: "Back"))
        expectResponderItem(
            back,
            action: #selector(ClusterWorkspaceWindowController.navigateBack(_:)),
            keyEquivalent: "["
        )
        let forward = try #require(window.item(withTitle: "Forward"))
        expectResponderItem(
            forward,
            action: #selector(ClusterWorkspaceWindowController.navigateForward(_:)),
            keyEquivalent: "]"
        )

        #expect(submenu("Resource", in: built.main) != nil)
        #expect(window.item(withTitle: "Command Palette…") != nil)
        let diagnostics = try #require(window.item(withTitle: "Engine Diagnostics…"))
        #expect(diagnostics.target === target)
        #expect(diagnostics.action == #selector(MenuTarget.diagnostics(_:)))
        #expect(diagnostics.keyEquivalent == "e")
        #expect(diagnostics.keyEquivalentModifierMask == [.command, .shift])
        #expect(window.item(withTitle: "Port Forwards") != nil)
        let shortcuts = try #require(window.item(withTitle: "Show Shortcuts"))
        #expect(shortcuts.target === target)
        #expect(shortcuts.action == #selector(MenuTarget.shortcuts(_:)))
    }

    @Test("resource table navigation is discoverable through responder-chain commands")
    func resourceTableNavigationCommands() throws {
        let built = makeMenu()
        let resource = try #require(submenu("Resource", in: built.main))

        for (title, selector, key, modifiers) in [
            (
                "Enter Subresource",
                #selector(ClusterWorkspaceWindowController.enterResource(_:)),
                "\r",
                NSEvent.ModifierFlags()
            ),
            (
                "Show Node",
                #selector(ClusterWorkspaceWindowController.showPodNode(_:)),
                "o",
                NSEvent.ModifierFlags()
            ),
            (
                "Describe",
                #selector(ClusterWorkspaceWindowController.openResourceDetails(_:)),
                "d",
                NSEvent.ModifierFlags()
            ),
            (
                "Focus Resource Filter",
                #selector(ClusterWorkspaceWindowController.focusResourceFilter(_:)),
                "/",
                NSEvent.ModifierFlags()
            ),
            (
                "Choose Namespace…",
                #selector(ClusterWorkspaceWindowController.chooseNamespace(_:)),
                "n",
                NSEvent.ModifierFlags([.command, .shift])
            ),
            (
                "Refresh API Resources",
                #selector(ClusterWorkspaceWindowController.refreshAPIResources(_:)),
                "",
                NSEvent.ModifierFlags.command
            ),
            (
                "Move Selection Up",
                #selector(ClusterWorkspaceWindowController.moveResourceSelectionUp(_:)),
                "k",
                NSEvent.ModifierFlags()
            ),
            (
                "Move Selection Down",
                #selector(ClusterWorkspaceWindowController.moveResourceSelectionDown(_:)),
                "j",
                NSEvent.ModifierFlags()
            ),
            (
                "Extend Selection Up",
                #selector(ClusterWorkspaceWindowController.extendResourceSelectionUp(_:)),
                String(UnicodeScalar(NSUpArrowFunctionKey)!),
                NSEvent.ModifierFlags.shift
            ),
            (
                "Extend Selection Down",
                #selector(ClusterWorkspaceWindowController.extendResourceSelectionDown(_:)),
                String(UnicodeScalar(NSDownArrowFunctionKey)!),
                NSEvent.ModifierFlags.shift
            ),
            (
                "Open YAML in Details",
                #selector(ClusterWorkspaceWindowController.openResourceYAML(_:)),
                "y",
                NSEvent.ModifierFlags()
            ),
            (
                "Open YAML in New Window",
                #selector(ClusterWorkspaceWindowController.openResourceYAMLSnapshot(_:)),
                "y",
                NSEvent.ModifierFlags.shift
            ),
            (
                "Rollout Restart…",
                #selector(ClusterWorkspaceWindowController.restartResourceSelection(_:)),
                "r",
                NSEvent.ModifierFlags()
            ),
        ] {
            let item = try #require(resource.item(withTitle: title))
            expectResponderItem(
                item,
                action: selector,
                keyEquivalent: key,
                modifiers: modifiers
            )
        }
    }

    @Test("Copy Cell is discoverable in the Resource menu with Command-C")
    func copyCellCommand() throws {
        let resource = try #require(submenu("Resource", in: makeMenu().main))
        let copyCell = try #require(resource.item(withTitle: "Copy Cell"))
        expectResponderItem(
            copyCell,
            action: #selector(ClusterWorkspaceWindowController.copyResourceCell(_:)),
            keyEquivalent: "c"
        )
    }

    @Test("labels and annotations have separate responder-chain commands")
    func metadataCommands() throws {
        let resource = try #require(submenu("Resource", in: makeMenu().main))
        let labels = try #require(resource.item(withTitle: "Edit Labels…"))
        expectResponderItem(
            labels,
            action: #selector(ClusterWorkspaceWindowController.editResourceLabels(_:)),
            keyEquivalent: ""
        )
        let annotations = try #require(resource.item(withTitle: "Edit Annotations…"))
        expectResponderItem(
            annotations,
            action: #selector(ClusterWorkspaceWindowController.editResourceAnnotations(_:)),
            keyEquivalent: ""
        )
    }

    @Test("terminal defaults and configuration have distinct responder shortcuts")
    func terminalCommands() throws {
        let resource = try #require(submenu("Resource", in: makeMenu().main))
        let direct = try #require(resource.item(withTitle: "Open Terminal"))
        expectResponderItem(
            direct,
            action: #selector(ClusterWorkspaceWindowController.openResourceExec(_:)),
            keyEquivalent: "s",
            modifiers: []
        )

        let configured = try #require(resource.item(withTitle: "Configure Terminal…"))
        expectResponderItem(
            configured,
            action: #selector(ClusterWorkspaceWindowController.configureResourceExec(_:)),
            keyEquivalent: "s",
            modifiers: [.shift]
        )
    }

    private func makeMenu(target: MenuTarget = MenuTarget()) -> NativeMainMenu {
        NativeMainMenuBuilder.make(actions: NativeMainMenuActions(
            target: target,
            showSettings: #selector(MenuTarget.settings(_:)),
            newClusterWindow: #selector(MenuTarget.newWindow(_:)),
            showCommandPalette: #selector(MenuTarget.palette(_:)),
            showEngineDiagnostics: #selector(MenuTarget.diagnostics(_:)),
            showPortForwards: #selector(MenuTarget.forwards(_:)),
            toggleShortcuts: #selector(MenuTarget.shortcuts(_:))
        ))
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu? {
        menu.items.lazy.compactMap(\.submenu).first { $0.title == title }
    }

    private func expectResponderItem(
        _ item: NSMenuItem,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) {
        #expect(item.target == nil)
        #expect(item.action == action)
        #expect(item.keyEquivalent == keyEquivalent)
        #expect(item.keyEquivalentModifierMask == modifiers)
    }
}
}

@MainActor
private final class MenuTarget: NSObject {
    @objc func settings(_ sender: Any?) {}
    @objc func newWindow(_ sender: Any?) {}
    @objc func palette(_ sender: Any?) {}
    @objc func diagnostics(_ sender: Any?) {}
    @objc func forwards(_ sender: Any?) {}
    @objc func shortcuts(_ sender: Any?) {}
}
