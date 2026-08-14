import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Contextual shortcuts window", .serialized)
struct ContextualShortcutsCoordinatorTests {
    @Test("panel is passive, floating, accessible, and outside window cycling")
    func passivePanelConfiguration() throws {
        let controller = ContextualShortcutsWindowController()
        defer { controller.close() }
        let panel = try #require(controller.window as? NSPanel)

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.hidesOnDeactivate)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(panel.isExcludedFromWindowsMenu)
        #expect(panel.accessibilityLabel() == "Contextual keyboard shortcuts")
    }

    @Test("active leaf provider wins and deactivation hides the panel")
    func activeLeafWins() throws {
        let parent = ShortcutProviderWindowController(
            snapshot: ContextualShortcutCatalog.resourceList(
                title: "Pods",
                availability: ResourceListShortcutAvailability(canOpenLogs: true)
            )
        )
        let leaf = ShortcutProviderWindowController(
            snapshot: ContextualShortcutCatalog.resourceFilter
        )
        let coordinator = ContextualShortcutsCoordinator(application: .shared)
        defer {
            coordinator.stop()
            parent.window?.removeChildWindow(leaf.window!)
            leaf.close()
            parent.close()
        }
        parent.window?.addChildWindow(leaf.window!, ordered: .above)

        coordinator.synchronize(isApplicationActive: true, keyWindow: leaf.window)

        #expect(coordinator.shortcutsWindowController.currentSnapshot?.contextID
            == "resource-filter")
        #expect(coordinator.shortcutsWindowController.window?.isVisible == true)
        #expect(shortcutKeys(in: coordinator.shortcutsWindowController.window) == [
            "Return", "Escape", "\u{21E7}\u{2318}N",
        ])

        // Reusing the one application-owned panel must replace the old rows
        // cleanly as the active leaf changes.
        coordinator.synchronize(isApplicationActive: true, keyWindow: parent.window)
        #expect(coordinator.shortcutsWindowController.currentSnapshot?.contextID
            == "resource-list")
        #expect(shortcutKeys(in: coordinator.shortcutsWindowController.window).contains("L"))

        coordinator.synchronize(isApplicationActive: false, keyWindow: leaf.window)
        #expect(coordinator.shortcutsWindowController.window?.isVisible == false)
    }

    @Test("unknown child windows get generic help rather than parent table letters")
    func unknownChildIsGeneric() throws {
        let parent = ShortcutProviderWindowController(
            snapshot: ContextualShortcutCatalog.resourceList(
                title: "Pods",
                availability: ResourceListShortcutAvailability(canOpenLogs: true)
            )
        )
        let child = UnknownShortcutChildController()
        let coordinator = ContextualShortcutsCoordinator(application: .shared)
        defer {
            coordinator.stop()
            parent.window?.removeChildWindow(child.window!)
            child.close()
            parent.close()
        }
        parent.window?.addChildWindow(child.window!, ordered: .above)

        coordinator.synchronize(isApplicationActive: true, keyWindow: child.window)

        #expect(coordinator.shortcutsWindowController.currentSnapshot
            == ContextualShortcutCatalog.genericDialog)
        #expect(!shortcutKeys(in: coordinator.shortcutsWindowController.window).contains("L"))
    }

    @Test("parent fallback requires an explicit eligible child")
    func explicitParentFallback() throws {
        let parentSnapshot = ContextualShortcutCatalog.resourceList(
            title: "Services",
            availability: ResourceListShortcutAvailability(canStartPortForward: true)
        )
        let parent = ShortcutProviderWindowController(snapshot: parentSnapshot)
        let child = EligibleShortcutChildController()
        let coordinator = ContextualShortcutsCoordinator(application: .shared)
        defer {
            coordinator.stop()
            parent.window?.removeChildWindow(child.window!)
            child.close()
            parent.close()
        }
        parent.window?.addChildWindow(child.window!, ordered: .above)

        coordinator.synchronize(isApplicationActive: true, keyWindow: child.window)
        #expect(coordinator.shortcutsWindowController.currentSnapshot == parentSnapshot)
    }
}
}

@MainActor
private final class ShortcutProviderWindowController: NSWindowController,
    ContextualShortcutProviding
{
    var snapshot: ContextualShortcutSnapshot
    var contextualShortcutsDidChange: (() -> Void)?
    var contextualShortcutSnapshot: ContextualShortcutSnapshot? { snapshot }

    init(snapshot: ContextualShortcutSnapshot) {
        self.snapshot = snapshot
        super.init(window: shortcutTestWindow())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }
}

@MainActor
private final class EligibleShortcutChildController: NSWindowController,
    ContextualShortcutParentFallbackEligible
{
    init() { super.init(window: shortcutTestWindow()) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }
}

@MainActor
private final class UnknownShortcutChildController: NSWindowController {
    init() { super.init(window: shortcutTestWindow()) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }
}

@MainActor
private func shortcutTestWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
private func shortcutKeys(in window: NSWindow?) -> [String] {
    guard let root = window?.contentView else { return [] }
    return contextualShortcutDescendants(of: root)
        .compactMap { $0 as? NSTextField }
        .filter { $0.accessibilityIdentifier().hasPrefix("contextual-shortcut.keys.") }
        .map(\.stringValue)
}

@MainActor
private func contextualShortcutDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(contextualShortcutDescendants(of:))
}
