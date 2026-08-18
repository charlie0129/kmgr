import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Object subresource lists")
struct ObjectSubresourceListViewControllerTests {
    @Test("container list opens logs for the exact selected Pod container")
    func containerLogs() throws {
        let pod = subresourceIdentity(resource: "pods")
        let controller = ObjectSubresourceListViewController(content: .containers(
            pod: pod,
            values: [
                ExecContainerCandidate(name: "api", kind: .regular),
                ExecContainerCandidate(name: "migrate", kind: .initContainer),
            ]
        ))
        controller.loadView()
        var opened: LogOpenRequest?
        var automaticExec: PodExecTarget?
        var configuredExec: PodExecTarget?
        var forwarded: ResourceIdentity?
        controller.onOpenLogs = { opened = $0 }
        controller.onOpenExec = { automaticExec = $0 }
        controller.onConfigureExec = { configuredExec = $0 }
        controller.onStartPortForward = { forwarded = $0 }
        let table = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Pod containers" })
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(controller.contextualShortcutSnapshot.items.map(\.keys)
            == [
                "L / Return", "\u{21E7}L", "S", "\u{21E7}S", "P",
                "\u{21E7}\u{2318}N", "Escape",
            ])
        let button = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Open Selected Container Logs" })
        button.performClick(nil)

        #expect(opened == .namedContainer("migrate", in: pod))
        #expect(table.tableColumns.map(\.title) == ["Container", "Type"])

        opened = nil
        table.keyDown(with: try subresourceKey("l", modifiers: [.shift]))
        #expect(opened == .namedContainer("migrate", in: pod, previous: true))

        table.keyDown(with: try subresourceKey("s"))
        table.keyDown(with: try subresourceKey("s", modifiers: [.shift]))
        table.keyDown(with: try subresourceKey("p"))
        let expectedTarget = PodExecTarget(
            pod: pod,
            preferredContainer: "migrate"
        )
        #expect(automaticExec == expectedTarget)
        #expect(configuredExec == expectedTarget)
        #expect(forwarded == pod)

        opened = nil
        controller.setNetworkActionsEnabled(false)
        #expect(!button.isEnabled)
        #expect(controller.contextualShortcutSnapshot.items.map(\.keys)
            == ["\u{21E7}\u{2318}N", "Escape"])
        automaticExec = nil
        configuredExec = nil
        forwarded = nil
        button.performClick(nil)
        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        table.keyDown(with: returnEvent)
        #expect(opened == nil)
        table.keyDown(with: try subresourceKey("s"))
        table.keyDown(with: try subresourceKey("s", modifiers: [.shift]))
        table.keyDown(with: try subresourceKey("p"))
        table.keyDown(with: try subresourceKey("l", modifiers: [.shift]))
        #expect(automaticExec == nil)
        #expect(configuredExec == nil)
        #expect(forwarded == nil)
        #expect(opened == nil)
    }

    @Test("data list exposes metadata without retaining or rendering values")
    func dataMetadataOnly() throws {
        let object = subresourceIdentity(resource: "secrets")
        let sentinel = "must-never-render"
        let entry = ObjectDataEntry(
            key: "token", kind: .text, value: Data(sentinel.utf8),
            byteSize: UInt64(sentinel.utf8.count),
            contentHash: Data(repeating: 4, count: 32)
        )
        let row = DataSubresourceRow(entry: entry)
        #expect(Mirror(reflecting: row).children.contains { $0.label == "value" } == false)

        let controller = ObjectSubresourceListViewController(content: .data(
            object: object, values: [row]
        ))
        controller.loadView()
        var edited: ResourceIdentity?
        controller.onOpenDataEditor = { edited = $0 }
        let table = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "ConfigMap or Secret data keys" })
        for column in table.tableColumns.indices {
            let cell = try #require(table.view(
                atColumn: column, row: 0, makeIfNecessary: true
            ) as? NSTableCellView)
            #expect(cell.textField?.stringValue.contains(sentinel) == false)
        }
        let button = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Open Data Editor" })
        #expect(controller.contextualShortcutSnapshot.items.map(\.keys)
            == ["Return", "\u{21E7}\u{2318}N", "Escape"])
        button.performClick(nil)
        #expect(edited == object)
    }

    @Test("empty Data remains an enterable list and can open its editor")
    func emptyData() throws {
        let object = subresourceIdentity(resource: "configmaps")
        let controller = ObjectSubresourceListViewController(content: .data(
            object: object,
            values: []
        ))
        controller.loadView()
        var edited: ResourceIdentity?
        controller.onOpenDataEditor = { edited = $0 }
        let table = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "ConfigMap or Secret data keys" })
        let button = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Open Data Editor" })

        #expect(table.numberOfRows == 0)
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(edited == object)
    }
}
}

private func subresourceKey(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: modifiers.contains(.shift)
            ? characters.uppercased() : characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 1
    ))
}

@MainActor
private func subresourceDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(subresourceDescendants(of:))
}

private func subresourceIdentity(resource: String) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session", group: "", version: "v1",
        resource: resource, namespace: "default", name: "selected",
        uid: ResourceUID("uid")
    )
}
