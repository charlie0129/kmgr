import Testing
@testable import KmgrCore

@Suite("Contextual shortcut catalog")
struct ContextualShortcutModelsTests {
    @Test("resource help includes only compatible object operations")
    func resourceCompatibility() {
        let snapshot = ContextualShortcutCatalog.resourceList(
            title: "Pods",
            availability: ResourceListShortcutAvailability(
                canEnterSubresource: true,
                canOpenDetails: true,
                canOpenYAML: true,
                canOpenEvents: true,
                canOpenLogs: true,
                canOpenTerminal: true,
                canStartPortForward: true,
                canDelete: true
            )
        )

        #expect(snapshot.title == "Pods")
        #expect(snapshot.items.map(\.keys).contains("Return"))
        #expect(snapshot.items.map(\.keys).contains("L"))
        #expect(snapshot.items.map(\.keys).contains("S"))
        #expect(snapshot.items.map(\.keys).contains("P"))
        #expect(snapshot.items.map(\.keys).contains("\u{2318}\u{232B}"))
        #expect(snapshot.items.map(\.keys).contains("\u{21E7}\u{2318}N"))

        let incompatible = ContextualShortcutCatalog.resourceList(
            title: "ConfigMaps",
            availability: ResourceListShortcutAvailability(
                canOpenDetails: true,
                canOpenYAML: true,
                canOpenEvents: true
            )
        )
        #expect(!incompatible.items.map(\.keys).contains("L"))
        #expect(!incompatible.items.map(\.keys).contains("S"))
        #expect(!incompatible.items.map(\.keys).contains("P"))
        #expect(!incompatible.items.map(\.keys).contains("\u{2318}\u{232B}"))
    }

    @Test("focused filter help replaces table letters")
    func filterContext() {
        #expect(ContextualShortcutCatalog.resourceFilter.items.map(\.keys) == [
            "Return", "Escape", "\u{21E7}\u{2318}N",
        ])
    }

    @Test("subresource help follows its exact action availability")
    func subresources() {
        #expect(ContextualShortcutCatalog.containerList(canOpenLogs: true)
            .items.map(\.keys) == ["L / Return", "\u{21E7}\u{2318}N", "Escape"])
        #expect(ContextualShortcutCatalog.containerList(canOpenLogs: false)
            .items.map(\.keys) == ["\u{21E7}\u{2318}N", "Escape"])
        #expect(ContextualShortcutCatalog.dataList(canOpenEditor: true)
            .items.map(\.keys) == ["Return", "\u{21E7}\u{2318}N", "Escape"])
    }

    @Test("unknown dialogs never advertise resource table letters")
    func genericDialog() {
        let keys = ContextualShortcutCatalog.genericDialog.items.map(\.keys)
        #expect(keys == ["\u{2318}W", "\u{2318}Q"])
        #expect(!keys.contains("L"))
        #expect(!keys.contains("Y"))
    }
}
