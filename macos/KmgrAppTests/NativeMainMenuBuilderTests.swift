import AppKit
import Testing
@testable import Kmgr

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

    @Test("window cycling is discoverable without replacing navigation commands")
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

        let cycle = try #require(window.item(withTitle: "Cycle Through Windows"))
        #expect(cycle.target === target)
        #expect(cycle.action == #selector(MenuTarget.cycleForward(_:)))
        #expect(cycle.keyEquivalent == "`")
        #expect(cycle.keyEquivalentModifierMask == .command)

        let cycleBack = try #require(window.item(withTitle: "Cycle Back Through Windows"))
        #expect(cycleBack.target === target)
        #expect(cycleBack.action == #selector(MenuTarget.cycleBackward(_:)))
        #expect(cycleBack.keyEquivalent == "`")
        #expect(cycleBack.keyEquivalentModifierMask == [.command, .shift])

        #expect(submenu("Resource", in: built.main) != nil)
        #expect(window.item(withTitle: "Command Palette…") != nil)
        #expect(window.item(withTitle: "Port Forwards") != nil)
    }

    private func makeMenu(target: MenuTarget = MenuTarget()) -> NativeMainMenu {
        NativeMainMenuBuilder.make(actions: NativeMainMenuActions(
            target: target,
            showSettings: #selector(MenuTarget.settings(_:)),
            newClusterWindow: #selector(MenuTarget.newWindow(_:)),
            showCommandPalette: #selector(MenuTarget.palette(_:)),
            showPortForwards: #selector(MenuTarget.forwards(_:)),
            cycleWindowsForward: #selector(MenuTarget.cycleForward(_:)),
            cycleWindowsBackward: #selector(MenuTarget.cycleBackward(_:))
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

@MainActor
private final class MenuTarget: NSObject {
    @objc func settings(_ sender: Any?) {}
    @objc func newWindow(_ sender: Any?) {}
    @objc func palette(_ sender: Any?) {}
    @objc func forwards(_ sender: Any?) {}
    @objc func cycleForward(_ sender: Any?) {}
    @objc func cycleBackward(_ sender: Any?) {}
}
