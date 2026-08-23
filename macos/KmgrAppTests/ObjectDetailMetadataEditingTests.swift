import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Object Details metadata editing", .serialized)
struct ObjectDetailMetadataEditingTests {
    @Test("Summary exposes separate section actions and Return edits the selected kind")
    func sectionActionsAndReturn() async throws {
        let identity = detailMetadataIdentity()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: DetailMetadataProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                labels: ["team": "platform"],
                annotations: ["team": "Platform Team"]
            ))
        )
        var requests: [(ResourceMetadataKind, String?)] = []
        var shortcutRefreshCount = 0
        controller.onEditMetadata = { _, kind, key in requests.append((kind, key)) }
        controller.onContextualShortcutsChanged = { shortcutRefreshCount += 1 }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.stop()
            window.orderOut(nil)
        }

        let table = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "object-detail-summary-table" })
        try await detailMetadataWaitUntil { table.numberOfRows >= 4 }
        for row in 0..<table.numberOfRows {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        let labelsButton = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "object-detail-edit-labels" })
        let annotationsButton = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "object-detail-edit-annotations" })
        #expect(labelsButton.title == "Edit Labels…")
        #expect(annotationsButton.title == "Edit Annotations…")

        annotationsButton.performClick(nil)
        #expect(requests.count == 1)
        #expect(requests[0].0 == .annotations)
        #expect(requests[0].1 == nil)

        let labelRow = try detailMetadataRow(
            key: "team",
            value: "platform",
            in: table
        )
        table.selectRowIndexes(IndexSet(integer: labelRow), byExtendingSelection: false)
        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        table.keyDown(with: returnEvent)
        #expect(requests.count == 2)
        #expect(requests[1].0 == .labels)
        #expect(requests[1].1 == "team")

        #expect(controller.contextualShortcutSnapshot.items.contains {
            $0.id == "details.edit-metadata"
        })
        let segmented = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSSegmentedControl }.first)
        segmented.selectedSegment = ObjectDetailInitialTab.yaml.segment
        _ = segmented.sendAction(segmented.action, to: segmented.target)
        #expect(controller.contextualShortcutSnapshot.items.contains {
            $0.id == "details.edit-metadata"
        } == false)
        #expect(shortcutRefreshCount > 0)
    }

    @Test("empty metadata still exposes both kind-specific edit actions")
    func emptySectionsRemainEditable() async throws {
        let identity = detailMetadataIdentity()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: DetailMetadataProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-empty"
            ))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.stop()
            window.orderOut(nil)
        }
        let table = try #require(detailMetadataDescendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "object-detail-summary-table" })
        try await detailMetadataWaitUntil { table.numberOfRows == 2 }
        for row in 0..<table.numberOfRows {
            _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        let buttonIDs = Set(detailMetadataDescendants(of: controller.view)
            .compactMap { ($0 as? NSButton)?.identifier?.rawValue })
        #expect(buttonIDs.contains("object-detail-edit-labels"))
        #expect(buttonIDs.contains("object-detail-edit-annotations"))
    }
}
}

private struct DetailMetadataProvider: ObjectDetailProviding {
    var detail: ObjectDetail

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }
    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }
    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}
    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
    }
    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }
    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}

private func detailMetadataIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "team-a",
        name: "api",
        uid: "deployment-uid"
    )
}

@MainActor
private func detailMetadataDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(detailMetadataDescendants(of:))
}

@MainActor
private func detailMetadataRow(
    key: String,
    value: String,
    in table: NSTableView
) throws -> Int {
    try #require((0..<table.numberOfRows).first { row in
        let keyText = (table.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? NSTableCellView)?.textField?.stringValue
        let valueText = (table.view(atColumn: 1, row: row, makeIfNecessary: true)
            as? NSTableCellView)?.textField?.stringValue
        return keyText == key && valueText == value
    })
}

private func detailMetadataWaitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DetailMetadataTestError.timedOut
}

private enum DetailMetadataTestError: Error {
    case timedOut
}
