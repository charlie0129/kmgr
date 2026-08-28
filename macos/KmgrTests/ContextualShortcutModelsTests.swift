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
                canShowParent: true,
                canShowNode: true,
                canOpenDetails: true,
                canOpenYAML: true,
                canOpenLogs: true,
                canOpenTerminal: true,
                canStartPortForward: true,
                canRestart: true,
                canDelete: true
            )
        )

        #expect(snapshot.title == "Pods")
        #expect(snapshot.items.map(\.keys).contains("Return"))
        #expect(snapshot.items.map(\.keys).contains("\u{2318}Return"))
        #expect(snapshot.items.map(\.keys).contains("O"))
        #expect(snapshot.items.map(\.keys).contains("\u{2318}O"))
        #expect(snapshot.items.map(\.keys).contains("D"))
        #expect(snapshot.items.map(\.keys).contains("Y"))
        #expect(snapshot.items.map(\.keys).contains("E"))
        #expect(snapshot.items.first { $0.id == "resource.yaml.edit" }?.action
            == "Edit selected object YAML")
        #expect(snapshot.items.map(\.keys).contains("L"))
        #expect(snapshot.items.map(\.keys).contains("\u{21E7}L"))
        #expect(snapshot.items.map(\.keys).contains("S"))
        #expect(snapshot.items.map(\.keys).contains("\u{21E7}S"))
        #expect(snapshot.items.map(\.keys).contains("P"))
        #expect(snapshot.items.map(\.keys).contains("\u{2318}P"))
        #expect(snapshot.items.map(\.keys).contains("F"))
        #expect(snapshot.items.map(\.keys).contains("\u{2318}F"))
        #expect(snapshot.items.first { $0.id == "resource.parent" }?.keys == "P")
        #expect(snapshot.items.first { $0.id == "resource.node.window" }?.action
            == "Show selected Pod's Node in a new workspace")
        #expect(snapshot.items.first { $0.id == "resource.port-forward" }?.keys == "F")
        #expect(snapshot.items.map(\.keys).contains("R"))
        #expect(snapshot.items.map(\.keys).contains("\u{2318}\u{232B}"))
        #expect(snapshot.items.map(\.keys).contains("\u{21E7}\u{2318}N"))

        let incompatible = ContextualShortcutCatalog.resourceList(
            title: "ConfigMaps",
            availability: ResourceListShortcutAvailability(
                canOpenDetails: true,
                canOpenYAML: true
            )
        )
        #expect(!incompatible.items.map(\.keys).contains("L"))
        #expect(!incompatible.items.map(\.keys).contains("O"))
        #expect(!incompatible.items.map(\.keys).contains("\u{2318}O"))
        #expect(!incompatible.items.map(\.keys).contains("\u{21E7}L"))
        #expect(!incompatible.items.map(\.keys).contains("S"))
        #expect(!incompatible.items.map(\.keys).contains("P"))
        #expect(!incompatible.items.map(\.keys).contains("R"))
        #expect(!incompatible.items.map(\.keys).contains("\u{2318}\u{232B}"))
        #expect(incompatible.items.map(\.keys).contains("E"))
    }

    @Test("focused filter help replaces table letters")
    func filterContext() {
        #expect(ContextualShortcutCatalog.resourceFilter.items.map(\.keys) == [
            "Return", "Escape", "\u{21E7}\u{2318}N",
        ])
    }

    @Test("subresource help follows its exact action availability")
    func subresources() {
        #expect(ContextualShortcutCatalog.containerList(
            canOpenLogs: true,
            canOpenTerminal: true,
            canStartPortForward: true
        ).items.map(\.keys) == [
            "L / Return", "\u{21E7}L", "S", "\u{21E7}S", "F", "\u{2318}F",
            "\u{21E7}\u{2318}N", "Escape",
        ])
        #expect(ContextualShortcutCatalog.containerList(
            canOpenLogs: false,
            canOpenTerminal: false,
            canStartPortForward: false
        )
            .items.map(\.keys) == ["\u{21E7}\u{2318}N", "Escape"])
        #expect(ContextualShortcutCatalog.dataEditor(secret: true)
            .items.map(\.keys) == [
                "/ or \u{2318}F", "Return", "D", "\u{2318}S",
                "\u{21E7}\u{2318}N", "Escape",
            ])
        #expect(ContextualShortcutCatalog.dataEditor(secret: false)
            .items.map(\.keys) == [
                "/ or \u{2318}F", "Return", "\u{2318}S",
                "\u{21E7}\u{2318}N", "Escape",
            ])
    }

    @Test("log help advertises its window-wide controls")
    func logs() {
        #expect(ContextualShortcutCatalog.logs.items.map(\.keys) == [
            "/", "F", "P", "W", "\u{2318}W",
        ])
    }

    @Test("metadata editor help exposes its shared key-value controls")
    func metadataEditor() {
        let snapshot = ContextualShortcutCatalog.metadataEditor(kind: .annotations)
        #expect(snapshot.contextID == "resource-metadata-annotations")
        #expect(snapshot.title == "Edit Annotations")
        #expect(snapshot.items.map(\.keys) == [
            "/ or \u{2318}F", "Return", "\u{2318}S", "Escape",
        ])
    }

    @Test("Details help advertises its available Summary actions")
    func objectDetails() {
        let item = ContextualShortcutCatalog.objectDetails(
            canEditSelectedMetadata: true,
            canOpenEvents: false
        ).items.first {
            $0.id == "details.edit-metadata"
        }
        #expect(item?.keys == "Return")
        #expect(item?.action == "Edit the selected label or annotation")
        #expect(ContextualShortcutCatalog.objectDetails(
            canEditSelectedMetadata: false,
            canOpenEvents: false
        ).items.contains { $0.id == "details.edit-metadata" } == false)
        let events = ContextualShortcutCatalog.objectDetails(
            canEditSelectedMetadata: false,
            canOpenEvents: true
        ).items.first { $0.id == "details.events" }
        #expect(events?.keys == "E")
        #expect(events?.action == "Open complete Events list in a new workspace")
    }

    @Test("unknown dialogs never advertise resource table letters")
    func genericDialog() {
        let keys = ContextualShortcutCatalog.genericDialog.items.map(\.keys)
        #expect(keys == ["\u{2318}W", "\u{2318}Q"])
        #expect(!keys.contains("L"))
        #expect(!keys.contains("Y"))
    }
}
