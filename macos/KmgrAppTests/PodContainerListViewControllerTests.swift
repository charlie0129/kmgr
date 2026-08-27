import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Pod container list")
struct PodContainerListViewControllerTests {
    @Test("container list opens logs for the exact selected Pod container")
    func containerLogs() throws {
        let pod = subresourceIdentity(resource: "pods")
        let controller = PodContainerListViewController(
            pod: pod,
            containers: [
                PodContainerDetail(
                    name: "api",
                    kind: .regular,
                    status: "Running",
                    statusTooltip: "State: Running",
                    ready: true,
                    restartCount: 2,
                    ports: ["http: 8080/TCP", "8443/TCP"],
                    metrics: [
                        ResourceUsageValue(
                            usage: 0.42, request: 0.5, limit: 1,
                            unit: "cores", resourceName: "cpu"
                        ),
                        ResourceUsageValue(
                            usage: 64 * 1_048_576,
                            request: 128 * 1_048_576,
                            limit: 256 * 1_048_576,
                            unit: "bytes", resourceName: "memory"
                        ),
                    ]
                ),
                PodContainerDetail(
                    name: "migrate",
                    kind: .initContainer,
                    status: "Terminated: Completed"
                ),
            ]
        )
        controller.loadView()
        var opened: LogOpenRequest?
        var automaticExec: PodExecTarget?
        var configuredExec: PodExecTarget?
        var forwarded: ResourceIdentity?
        var forwardedAndShown: ResourceIdentity?
        controller.onOpenLogs = { opened = $0 }
        controller.onOpenExec = { automaticExec = $0 }
        controller.onConfigureExec = { configuredExec = $0 }
        controller.onStartPortForward = { forwarded = $0 }
        controller.onStartPortForwardAndShow = { forwardedAndShown = $0 }
        let table = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Pod containers" })
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(controller.contextualShortcutSnapshot.items.map(\.keys)
            == [
                "L / Return", "\u{21E7}L", "S", "\u{21E7}S", "F", "\u{2318}F",
                "\u{21E7}\u{2318}N", "Escape",
            ])
        let button = try #require(subresourceDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Open Selected Container Logs" })
        button.performClick(nil)

        #expect(opened == .namedContainer("migrate", in: pod))
        #expect(table.tableColumns.map(\.title) == [
            "Container", "Type", "Status", "Ready", "Restarts", "CPU", "Memory", "Ports",
        ])
        let apiValues = try table.tableColumns.indices.map { column in
            try #require(table.view(
                atColumn: column, row: 0, makeIfNecessary: true
            ) as? NSTableCellView).textField?.stringValue
        }
        #expect(apiValues == [
            "api", "Regular", "Running", "Yes", "2",
            "420m / 500m / 1", "64Mi / 128Mi / 256Mi",
            "http: 8080/TCP, 8443/TCP",
        ])

        opened = nil
        table.keyDown(with: try subresourceKey("l", modifiers: [.shift]))
        #expect(opened == .namedContainer("migrate", in: pod, previous: true))

        table.keyDown(with: try subresourceKey("s"))
        table.keyDown(with: try subresourceKey("s", modifiers: [.shift]))
        table.keyDown(with: try subresourceKey("p"))
        #expect(forwarded == nil)
        table.keyDown(with: try subresourceKey("f"))
        table.keyDown(with: try subresourceKey("f", modifiers: [.command]))
        let expectedTarget = PodExecTarget(
            pod: pod,
            preferredContainer: "migrate"
        )
        #expect(automaticExec == expectedTarget)
        #expect(configuredExec == expectedTarget)
        #expect(forwarded == pod)
        #expect(forwardedAndShown == pod)

        opened = nil
        controller.setNetworkActionsEnabled(false)
        #expect(!button.isEnabled)
        #expect(controller.contextualShortcutSnapshot.items.map(\.keys)
            == ["\u{21E7}\u{2318}N", "Escape"])
        automaticExec = nil
        configuredExec = nil
        forwarded = nil
        forwardedAndShown = nil
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
        table.keyDown(with: try subresourceKey("f"))
        table.keyDown(with: try subresourceKey("f", modifiers: [.command]))
        table.keyDown(with: try subresourceKey("l", modifiers: [.shift]))
        #expect(automaticExec == nil)
        #expect(configuredExec == nil)
        #expect(forwarded == nil)
        #expect(forwardedAndShown == nil)
        #expect(opened == nil)
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
