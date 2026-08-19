import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("YAML snapshot windows", .serialized)
struct YAMLSnapshotWindowControllerTests {
    @Test("snapshot uses AppKit's plain document and installs raw bytes with an exact count")
    func plainDocumentRawSnapshot() async throws {
        let identity = yamlSnapshotIdentity()
        let source = "metadata:\n  managedFields: [\nimportant: keep-this-malformed-source\n"
        let provider = SnapshotObjectDetailProvider(details: [ObjectDetail(
            identity: identity,
            resourceVersion: "rv-7",
            yamlUTF8: Data(source.utf8)
        )])
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let scroll = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "yaml-snapshot-scroll" })
        let textView = try #require(scroll.documentView as? NSTextView)
        let bytes = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-byte-count" })

        try await yamlSnapshotWaitUntil { textView.string == source }

        #expect(textView.string == source)
        #expect(textView.isEditable == false)
        #expect(textView.isSelectable)
        #expect(textView.isRichText == false)
        #expect(textView.usesFindBar)
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.hasHorizontalScroller)
        #expect(scroll.hasVerticalRuler == false)
        #expect(scroll.verticalRulerView == nil)
        #expect(bytes.stringValue == YAMLSnapshotWindowController.receivedByteText(
            Data(source.utf8).count
        ))
    }

    @Test("a successful zero-byte GET has an explicit unavailable state")
    func zeroByteState() async throws {
        let identity = yamlSnapshotIdentity()
        let provider = SnapshotObjectDetailProvider(details: [ObjectDetail(
            identity: identity,
            resourceVersion: "rv-empty",
            yamlUTF8: Data()
        )])
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let values = yamlSnapshotDescendants(of: root)
        let empty = try #require(values.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-empty-state" })
        let bytes = try #require(values.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-byte-count" })
        let textView = try #require(values.compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes YAML snapshot" })

        try await yamlSnapshotWaitUntil { empty.isHidden == false }

        #expect(empty.stringValue == "No YAML content was returned (0 bytes).")
        #expect(bytes.stringValue == "Received 0 bytes")
        #expect(textView.string.isEmpty)
    }

    @Test("a zero-byte refresh preserves the last nonempty snapshot")
    func zeroByteRefreshPreservesSnapshot() async throws {
        let identity = yamlSnapshotIdentity()
        let source = "apiVersion: v1\nkind: ConfigMap\n"
        let provider = SnapshotObjectDetailProvider(details: [
            ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(source.utf8)
            ),
            ObjectDetail(
                identity: identity,
                resourceVersion: "rv-2",
                yamlUTF8: Data()
            ),
        ])
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let root = try #require(controller.window?.contentView)
        let values = yamlSnapshotDescendants(of: root)
        let textView = try #require(values.compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes YAML snapshot" })
        let refresh = try #require(values.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-snapshot-refresh" })
        let bytes = try #require(values.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-byte-count" })
        let status = try #require(values.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-status" })

        try await yamlSnapshotWaitUntil { textView.string == source && refresh.isEnabled }
        refresh.performClick(nil)
        try await yamlSnapshotWaitUntil { await provider.getObjectCallCount() == 2 }
        try await yamlSnapshotWaitUntil {
            status.stringValue == "Empty YAML response · previous snapshot preserved"
        }

        #expect(textView.string == source)
        #expect(bytes.stringValue.hasPrefix("Received 0 bytes · showing previous"))
    }

    @Test("disconnect preserves bytes and recovery rebinds the same UID to the new session")
    func sessionRecovery() async throws {
        let identity = yamlSnapshotIdentity()
        let first = "kind: ConfigMap\nmetadata:\n  generation: old\n"
        var reboundIdentity = identity
        reboundIdentity.clusterSessionID = "yaml-session-2"
        let second = "kind: ConfigMap\nmetadata:\n  generation: new\n"
        let provider = SnapshotObjectDetailProvider(details: [
            ObjectDetail(
                identity: identity,
                resourceVersion: "rv-old",
                yamlUTF8: Data(first.utf8)
            ),
            ObjectDetail(
                identity: reboundIdentity,
                resourceVersion: "rv-new",
                yamlUTF8: Data(second.utf8)
            ),
        ])
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let textView = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes YAML snapshot" })
        let refresh = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-snapshot-refresh" })
        let status = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-status" })
        try await yamlSnapshotWaitUntil { textView.string == first }

        controller.engineDidDisconnect()
        #expect(textView.string == first)
        #expect(refresh.isEnabled == false)
        #expect(status.stringValue == "Engine disconnected · YAML snapshot preserved")

        controller.recover(with: OpenedClusterSession(
            sessionID: "yaml-session-2",
            contextName: "yaml-context",
            clusterName: "yaml-cluster",
            serverHostname: "api.example.invalid",
            defaultNamespace: "dev"
        ))
        try await yamlSnapshotWaitUntil { textView.string == second }
        #expect(controller.identity.uid == identity.uid)
        #expect(controller.identity.clusterSessionID == "yaml-session-2")
    }

    @Test("a response for another UID is rejected without replacing the viewer")
    func responseIdentityMismatch() async throws {
        let identity = yamlSnapshotIdentity()
        var wrongIdentity = identity
        wrongIdentity.uid = ResourceUID("replacement-uid")
        let provider = SnapshotObjectDetailProvider(details: [ObjectDetail(
            identity: wrongIdentity,
            resourceVersion: "rv-wrong",
            yamlUTF8: Data("do-not-display: true\n".utf8)
        )])
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let values = yamlSnapshotDescendants(of: root)
        let textView = try #require(values.compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes YAML snapshot" })
        let status = try #require(values.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-status" })

        try await yamlSnapshotWaitUntil { status.textColor == .systemRed }
        #expect(textView.string.isEmpty)
        #expect(status.toolTip?.contains("UID-pinned") == true)
    }

    @Test("snapshot search uses AppKit's native Command-F find bar")
    func nativeFindBar() throws {
        let identity = yamlSnapshotIdentity()
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: SnapshotObjectDetailProvider(details: [])
        )
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let textView = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes YAML snapshot" })
        #expect(textView.usesFindBar)
        #expect(yamlSnapshotDescendants(of: root).contains { $0 is NSSearchField } == false)
    }

    @Test("dedicated YAML edits preserve drafts across failure and refresh after success")
    func yamlEditLifecycle() async throws {
        let identity = yamlSnapshotIdentity()
        let source = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\n"
        let edited = source + "data:\n  enabled: true\n"
        let provider = YAMLSnapshotEditProvider(detail: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            yamlUTF8: Data(source.utf8)
        ))
        let controller = YAMLSnapshotWindowController(
            session: yamlSnapshotSession(),
            identity: identity,
            provider: provider
        )
        controller.showWindow(nil)
        defer { controller.close() }

        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let views = yamlSnapshotDescendants(of: root)
        let editor = try #require(views.compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes YAML snapshot" })
        let edit = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-snapshot-edit" })
        let save = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-snapshot-save" })
        let cancel = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-snapshot-cancel" })
        let saveMenuItem = NSMenuItem(
            title: "Save",
            action: #selector(NSDocument.save(_:)),
            keyEquivalent: "s"
        )

        try await yamlSnapshotWaitUntil { editor.string == source && edit.isEnabled }
        #expect(!controller.validateMenuItem(saveMenuItem))
        edit.performClick(nil)
        #expect(editor.isEditable)
        #expect(edit.isHidden)
        #expect(!save.isHidden && !cancel.isHidden)
        #expect(controller.validateMenuItem(saveMenuItem))
        editor.string = edited
        cancel.performClick(nil)
        #expect(editor.string == source)
        #expect(!editor.isEditable)

        edit.performClick(nil)
        editor.string = edited
        #expect(window.tryToPerform(#selector(NSDocument.save(_:)), with: nil))
        try await yamlSnapshotWaitUntil { await provider.applyCallCount() == 1 }
        #expect(!editor.isEditable)
        #expect(!save.isEnabled)
        #expect(await provider.lastExpectedResourceVersion() == "rv-1")
        #expect(await provider.lastPreparedYAML() == Data(edited.utf8))

        await provider.failCurrentApply()
        try await yamlSnapshotWaitUntil { editor.isEditable && save.isEnabled }
        #expect(editor.string == edited)

        save.performClick(nil)
        try await yamlSnapshotWaitUntil { await provider.applyCallCount() == 2 }
        await provider.succeedCurrentApply()
        try await yamlSnapshotWaitUntil {
            let objectCalls = await provider.getObjectCallCount()
            return editor.string == edited && !editor.isEditable && edit.isEnabled
                && objectCalls == 2
        }
        #expect(save.isHidden)
        #expect(cancel.isHidden)
    }

    @Test("watch omissions retain YAML and Data failures do not blank the standard detail tab")
    func detailFallbacks() async throws {
        let identity = yamlSnapshotIdentity()
        let source = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\n"
        let previous = ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            yamlUTF8: Data(source.utf8),
            metrics: [ResourceUsageValue(usage: 1, unit: "core", resourceName: "cpu")]
        )
        let emptyUpdate = ObjectDetail(
            identity: identity,
            resourceVersion: "rv-2",
            yamlUTF8: Data()
        )
        let merged = ObjectDetailWatchPresentation.merging(emptyUpdate, previous: previous)
        #expect(merged.yamlUTF8 == previous.yamlUTF8)
        #expect(merged.metrics.isEmpty)

        let provider = SnapshotObjectDetailProvider(
            details: [previous],
            dataFailure: ClusterManagerIssue(
                category: .unavailable,
                reason: "DataUnavailable",
                message: "The Data request failed.",
                operation: "load data"
            )
        )
        let detail = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .yaml
        )
        detail.loadView()
        detail.viewDidAppear()
        defer { detail.stop() }

        let editor = try #require(yamlSnapshotDescendants(of: detail.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        try await yamlSnapshotWaitUntil { editor.string == source }
        try await yamlSnapshotWaitUntil {
            yamlSnapshotDescendants(of: detail.view).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "YAML loaded · key/value data unavailable" }
        }

        #expect(editor.string == source)
        let scroll = try #require(editor.enclosingScrollView)
        #expect(scroll.hasVerticalRuler == false)
        #expect(scroll.verticalRulerView == nil)
    }

    @Test("failed authoritative Data recovery leaves YAML visible and locks stale values")
    func failedDataRecoveryLocksEditor() async throws {
        let identity = yamlSnapshotIdentity()
        var reboundIdentity = identity
        reboundIdentity.clusterSessionID = "yaml-session-2"
        let source = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\n"
        let provider = SnapshotObjectDetailProvider(
            details: [
                ObjectDetail(
                    identity: identity,
                    resourceVersion: "rv-1",
                    yamlUTF8: Data(source.utf8)
                ),
                ObjectDetail(
                    identity: reboundIdentity,
                    resourceVersion: "rv-2",
                    yamlUTF8: Data(source.utf8)
                ),
            ],
            dataFailure: ClusterManagerIssue(
                category: .unavailable,
                reason: "DataUnavailable",
                message: "The Data request failed.",
                operation: "load data"
            ),
            successfulDataResponsesBeforeFailure: 1
        )
        let detail = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .data
        )
        detail.loadView()
        detail.viewDidAppear()
        defer { detail.stop() }
        let add = try #require(yamlSnapshotDescendants(of: detail.view)
            .compactMap { $0 as? NSButton }.first { $0.title == "Add Key" })
        let segmented = try #require(yamlSnapshotDescendants(of: detail.view)
            .compactMap { $0 as? NSSegmentedControl }.first)
        try await yamlSnapshotWaitUntil { add.isEnabled }

        detail.engineDidDisconnect()
        var recoveryCompleted = false
        detail.recover(session: OpenedClusterSession(
            sessionID: "yaml-session-2",
            contextName: "yaml-context",
            clusterName: "yaml-cluster",
            serverHostname: "api.example.invalid",
            defaultNamespace: "dev"
        )) { result in
            if case .success = result { recoveryCompleted = true }
        }
        try await yamlSnapshotWaitUntil { recoveryCompleted }

        segmented.selectedSegment = 1
        _ = segmented.sendAction(segmented.action, to: segmented.target)
        let yaml = try #require(yamlSnapshotDescendants(of: detail.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        #expect(yaml.string == source)
        #expect(add.isEnabled == false)
        #expect(yamlSnapshotDescendants(of: detail.view).compactMap { $0 as? NSTextField }
            .contains {
                $0.stringValue == "Reconnected · YAML refreshed · key/value data unavailable"
            })
    }
}
}

private actor SnapshotObjectDetailProvider: ObjectDetailProviding {
    private var details: [ObjectDetail]
    private var objectCalls = 0
    private var dataCalls = 0
    private let dataFailure: ClusterManagerIssue?
    private let successfulDataResponsesBeforeFailure: Int

    init(
        details: [ObjectDetail],
        dataFailure: ClusterManagerIssue? = nil,
        successfulDataResponsesBeforeFailure: Int = 0
    ) {
        self.details = details
        self.dataFailure = dataFailure
        self.successfulDataResponsesBeforeFailure = successfulDataResponsesBeforeFailure
    }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        objectCalls += 1
        guard !details.isEmpty else { throw CancellationError() }
        return details.removeFirst()
    }

    nonisolated func watchObject(
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

    nonisolated func scanRelationships(
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
        dataCalls += 1
        if let dataFailure, dataCalls > successfulDataResponsesBeforeFailure {
            throw dataFailure
        }
        return ObjectData(
            identity: identity,
            resourceVersion: "rv-data",
            entries: [],
            secret: false
        )
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

    func getObjectCallCount() -> Int { objectCalls }
}

private actor YAMLSnapshotEditProvider: ObjectDetailProviding {
    private var detail: ObjectDetail
    private var objectCalls = 0
    private var applyCalls = 0
    private var preparedYAML: Data?
    private var expectedResourceVersion: String?
    private var applyingYAML: Data?
    private var applyContinuation:
        AsyncThrowingStream<OperationProgress, Error>.Continuation?

    init(detail: ObjectDetail) { self.detail = detail }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        objectCalls += 1
        return detail
    }

    nonisolated func watchObject(
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

    nonisolated func scanRelationships(
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
        preparedYAML = yamlUTF8
        self.expectedResourceVersion = expectedResourceVersion
        return PreparedYAMLEdit(
            normalizedYAMLUTF8: yamlUTF8,
            currentResourceVersion: expectedResourceVersion,
            diff: []
        )
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let pair = AsyncThrowingStream<OperationProgress, Error>.makeStream()
        applyCalls += 1
        applyingYAML = yamlUTF8
        applyContinuation = pair.continuation
        return pair.stream
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func failCurrentApply() {
        applyContinuation?.yield(OperationProgress(
            cursor: StreamCursor(generation: UInt64(applyCalls), sequence: 1),
            operationID: "yaml-snapshot-save-\(applyCalls)",
            state: .failed,
            completedItems: 0,
            totalItems: 1,
            itemResults: [],
            issue: ClusterManagerIssue(
                category: .conflict,
                reason: "Conflict",
                message: "The object changed on the server.",
                operation: "apply YAML"
            )
        ))
        finishCurrentApply()
    }

    func succeedCurrentApply() {
        if let applyingYAML {
            detail.yamlUTF8 = applyingYAML
            detail.resourceVersion = "rv-2"
        }
        applyContinuation?.yield(OperationProgress(
            cursor: StreamCursor(generation: UInt64(applyCalls), sequence: 1),
            operationID: "yaml-snapshot-save-\(applyCalls)",
            state: .succeeded,
            completedItems: 1,
            totalItems: 1,
            itemResults: []
        ))
        finishCurrentApply()
    }

    private func finishCurrentApply() {
        applyContinuation?.finish()
        applyContinuation = nil
        applyingYAML = nil
    }

    func getObjectCallCount() -> Int { objectCalls }
    func applyCallCount() -> Int { applyCalls }
    func lastPreparedYAML() -> Data? { preparedYAML }
    func lastExpectedResourceVersion() -> String? { expectedResourceVersion }
}

private func yamlSnapshotSession() -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: "yaml-session",
        contextName: "yaml-context",
        clusterName: "yaml-cluster",
        serverHostname: "api.example.invalid",
        defaultNamespace: "dev"
    )
}

private func yamlSnapshotIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "yaml-session",
        group: "",
        version: "v1",
        resource: "configmaps",
        namespace: "dev",
        name: "settings",
        uid: ResourceUID("yaml-uid")
    )
}

@MainActor
private func yamlSnapshotDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(yamlSnapshotDescendants(of:))
}

@MainActor
private func yamlSnapshotWaitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline {
            throw ClusterManagerIssue(
                category: .timeout,
                reason: "TestTimeout",
                message: "Timed out waiting for YAML snapshot state.",
                operation: "run YAML snapshot test"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
