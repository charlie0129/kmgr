import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource metadata editor", .serialized)
struct ResourceMetadataEditorWindowControllerTests {
    @Test("labels use the shared split editor and submit one sparse mutation")
    func labelsEditorWorkflow() async throws {
        let identity = metadataIdentity()
        let operations = MetadataEditorOperationProvider()
        let controller = ResourceMetadataEditorWindowController(
            session: metadataSession(),
            identity: identity,
            kind: .labels,
            initialKey: "team",
            detailProvider: MetadataEditorDetailProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-7",
                labels: ["legacy": "true", "team": "platform"],
                annotations: ["team": "Platform Team"]
            )),
            operationProvider: operations
        )
        let parent = metadataParentWindow()
        parent.makeKeyAndOrderFront(nil)
        controller.beginSheet(for: parent)
        defer {
            controller.close()
            parent.orderOut(nil)
        }

        let root = try #require(controller.window?.contentView)
        let table = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Labels keys and values" })
        try await metadataWaitUntil { table.numberOfRows == 2 }
        #expect(controller.window?.title == "cluster-a — production — Edit Labels")
        #expect(controller.contextualShortcutSnapshot?.contextID == "resource-metadata-labels")
        #expect(metadataDescendants(of: root).contains {
            $0.identifier?.rawValue == "resource-metadata-editor-split"
        })
        #expect(table.tableColumns.map(\.title) == ["Key", "Value", "State"])

        let valueEditor = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Selected label value" })
        let selectedKey = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Selected label key" })
        try await metadataWaitUntil { selectedKey.stringValue == "team" }
        #expect(valueEditor.string == "platform")
        expectPreciseScrollingLayout(valueEditor)

        valueEditor.string = "runtime"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: valueEditor))
        selectedKey.stringValue = "owner"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: selectedKey
        ))
        try metadataButton("Rename", in: root).performClick(nil)
        try await metadataWaitUntil { selectedKey.stringValue == "owner" }

        try selectMetadataRow("legacy", in: table, controller: controller)
        try metadataButton("Delete", in: root).performClick(nil)

        let newKey = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "New label key" })
        newKey.stringValue = "temporary"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: newKey
        ))
        try metadataButton("Add", in: root).performClick(nil)
        try metadataButton("Revert", in: root).performClick(nil)
        newKey.stringValue = "app.kubernetes.io/name"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: newKey
        ))
        try metadataButton("Add", in: root).performClick(nil)
        valueEditor.string = "api"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: valueEditor))

        try metadataButton("Save", in: root).performClick(nil)
        let call = try await metadataWaitForCall(operations)
        #expect(call.identity == identity)
        #expect(call.expectedResourceVersion == "rv-7")
        #expect(call.changes.labels == [
            "app.kubernetes.io/name": "api",
            "owner": "runtime",
        ])
        #expect(call.changes.removeLabelKeys == ["legacy", "team"])
        #expect(call.changes.annotations.isEmpty)
        #expect(call.changes.removeAnnotationKeys.isEmpty)
        try await metadataWaitUntil { parent.attachedSheet == nil }
    }

    @Test("annotation conflicts retain multiline local edits for retry")
    func annotationsPreserveDraftAfterError() async throws {
        let identity = metadataIdentity()
        let operations = MetadataEditorOperationProvider(failsFirstUpdate: true)
        let controller = ResourceMetadataEditorWindowController(
            session: metadataSession(),
            identity: identity,
            kind: .annotations,
            initialKey: "example.com/note",
            detailProvider: MetadataEditorDetailProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-9",
                annotations: ["example.com/note": "before"]
            )),
            operationProvider: operations
        )
        let parent = metadataParentWindow()
        parent.makeKeyAndOrderFront(nil)
        controller.beginSheet(for: parent)
        defer {
            controller.close()
            parent.orderOut(nil)
        }
        let root = try #require(controller.window?.contentView)
        let editor = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Selected annotation value" })
        let status = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Metadata editor status" })
        try await metadataWaitUntil { editor.string == "before" && editor.isEditable }

        let local = "line one\nline two = a,b"
        editor.string = local
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        let save = try metadataButton("Save", in: root)
        save.performClick(nil)
        try await metadataWaitUntil { status.stringValue.contains("HTTP 409") }
        #expect(editor.string == local)
        #expect(editor.isEditable)
        #expect(save.isEnabled)
        #expect(parent.attachedSheet === controller.window)

        save.performClick(nil)
        try await metadataWaitUntil { await operations.updateAttemptCount() == 2 }
        let call = try #require(await operations.latestCall())
        #expect(call.changes.annotations == ["example.com/note": local])
        #expect(call.changes.labels.isEmpty)
        try await metadataWaitUntil { parent.attachedSheet == nil }
    }

    @Test("a mutation stream without a terminal result retains the local draft")
    func missingTerminalResultPreservesDraft() async throws {
        let identity = metadataIdentity()
        let operations = MetadataEditorOperationProvider(endsWithoutTerminal: true)
        let controller = ResourceMetadataEditorWindowController(
            session: metadataSession(),
            identity: identity,
            kind: .labels,
            initialKey: "team",
            detailProvider: MetadataEditorDetailProvider(detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-10",
                labels: ["team": "platform"]
            )),
            operationProvider: operations
        )
        let parent = metadataParentWindow()
        parent.makeKeyAndOrderFront(nil)
        controller.beginSheet(for: parent)
        defer {
            controller.close()
            parent.orderOut(nil)
        }
        let root = try #require(controller.window?.contentView)
        let editor = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Selected label value" })
        let status = try #require(metadataDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Metadata editor status" })
        try await metadataWaitUntil { editor.string == "platform" && editor.isEditable }

        editor.string = "runtime"
        controller.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        try metadataButton("Save", in: root).performClick(nil)

        try await metadataWaitUntil { status.stringValue.contains("without a final result") }
        #expect(editor.string == "runtime")
        #expect(editor.isEditable)
        #expect(parent.attachedSheet === controller.window)
    }
}
}

private struct MetadataEditorCall: Sendable {
    var identity: ResourceIdentity
    var expectedResourceVersion: String
    var changes: ResourceMetadataChanges
}

private actor MetadataEditorOperationProvider: ResourceOperationProviding {
    private let failsFirstUpdate: Bool
    private let endsWithoutTerminal: Bool
    private var attempts = 0
    private var call: MetadataEditorCall?

    init(failsFirstUpdate: Bool = false, endsWithoutTerminal: Bool = false) {
        self.failsFirstUpdate = failsFirstUpdate
        self.endsWithoutTerminal = endsWithoutTerminal
    }

    func deleteResources(
        targets: [ResourceDeleteTarget],
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func scaleResource(
        identity: ResourceIdentity,
        replicas: Int32,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func rolloutRestart(
        identity: ResourceIdentity,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateMetadata(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        attempts += 1
        call = MetadataEditorCall(
            identity: identity,
            expectedResourceVersion: expectedResourceVersion,
            changes: changes
        )
        if failsFirstUpdate, attempts == 1 {
            throw ClusterManagerIssue(
                category: .conflict,
                reason: "Conflict",
                message: "The object changed while its annotations were being edited.",
                httpStatusCode: 409,
                retryable: true,
                contextName: "production",
                operation: "edit annotations"
            )
        }
        if endsWithoutTerminal {
            return AsyncThrowingStream { $0.finish() }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(OperationProgress(
                cursor: StreamCursor(generation: 1, sequence: 1),
                operationID: "metadata-update",
                state: .succeeded,
                completedItems: 1,
                totalItems: 1,
                itemResults: []
            ))
            continuation.finish()
        }
    }

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws {}

    func latestCall() -> MetadataEditorCall? { call }
    func updateAttemptCount() -> Int { attempts }
}

private struct MetadataEditorDetailProvider: ObjectDetailProviding {
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

@MainActor
private func metadataParentWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
}

private func metadataIdentity() -> ResourceIdentity {
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

private func metadataSession() -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: "session",
        contextName: "production",
        clusterName: "cluster-a",
        serverHostname: "api.example.invalid",
        defaultNamespace: "default"
    )
}

@MainActor
private func metadataDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(metadataDescendants(of:))
}

@MainActor
private func metadataButton(_ title: String, in root: NSView) throws -> NSButton {
    try #require(metadataDescendants(of: root).compactMap { $0 as? NSButton }
        .first { $0.title == title })
}

@MainActor
private func selectMetadataRow(
    _ key: String,
    in table: NSTableView,
    controller: ResourceMetadataEditorWindowController
) throws {
    let row = try #require((0..<table.numberOfRows).first { row in
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
            .textField?.stringValue == key
    })
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    controller.tableViewSelectionDidChange(Notification(
        name: NSTableView.selectionDidChangeNotification,
        object: table
    ))
}

private func metadataWaitForCall(
    _ provider: MetadataEditorOperationProvider
) async throws -> MetadataEditorCall {
    for _ in 0..<300 {
        if let call = await provider.latestCall() { return call }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MetadataEditorTestError.timedOut
}

private func metadataWaitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw MetadataEditorTestError.timedOut
}

private enum MetadataEditorTestError: Error {
    case timedOut
}
