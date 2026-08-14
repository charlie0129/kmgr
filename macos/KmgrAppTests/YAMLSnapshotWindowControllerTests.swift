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

        let root = try #require(controller.window?.contentView)
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

    @Test("read-only search keys route only from the YAML responder")
    func searchShortcutRouting() throws {
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
        let refresh = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "yaml-snapshot-refresh" })
        let search = try #require(yamlSnapshotDescendants(of: root)
            .compactMap { $0 as? NSSearchField }
            .first { $0.identifier?.rawValue == "yaml-snapshot-search" })
        let window = try #require(controller.window)
        textView.string = "alpha beta alpha"
        #expect(window.makeFirstResponder(textView))

        let slash = try #require(yamlSnapshotKeyEvent(characters: "/"))
        #expect(controller.performReadOnlySearchShortcut(slash))
        #expect(window.firstResponder === search.currentEditor())

        search.stringValue = "alpha"
        search.performClick(nil)
        #expect(window.firstResponder === textView)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))

        let next = try #require(yamlSnapshotKeyEvent(characters: "n"))
        #expect(controller.performReadOnlySearchShortcut(next))
        #expect(textView.selectedRange() == NSRange(location: 11, length: 5))

        let previous = try #require(yamlSnapshotKeyEvent(
            characters: "N",
            modifiers: .shift
        ))
        #expect(controller.performReadOnlySearchShortcut(previous))
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))

        let returnKey = try #require(yamlSnapshotKeyEvent(characters: "\r"))
        #expect(controller.performReadOnlySearchShortcut(returnKey))
        #expect(textView.selectedRange() == NSRange(location: 11, length: 5))

        for character in ["f", "c", "v"] {
            let commandKey = try #require(yamlSnapshotKeyEvent(
                characters: character,
                modifiers: .command
            ))
            #expect(controller.performReadOnlySearchShortcut(commandKey) == false)
        }

        textView.isEditable = true
        let editableN = try #require(yamlSnapshotKeyEvent(characters: "n"))
        #expect(controller.performReadOnlySearchShortcut(editableN) == false)
        textView.isEditable = false

        #expect(window.makeFirstResponder(refresh))
        let unfocusedN = try #require(yamlSnapshotKeyEvent(characters: "n"))
        #expect(controller.performReadOnlySearchShortcut(unfocusedN) == false)
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
        #expect(merged.metrics == previous.metrics)

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

    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent]
    {
        []
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

private func yamlSnapshotKeyEvent(
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters.lowercased(),
        isARepeat: false,
        keyCode: characters == "\r" ? 36 : 0
    )
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
