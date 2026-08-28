import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Fixed table controller integration", .serialized)
struct FixedTableLayoutControllerTests {
    @Test("cluster chooser and Pod containers restore their stable surfaces")
    func chooserAndContainers() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let chooserLayout = TableLayout(columns: [
            .init(id: "source", width: 320),
            .init(id: "context", width: 210),
            .init(id: "server", width: 250),
            .init(id: "namespace", width: 105),
        ])
        let containerLayout = TableLayout(columns: [
            .init(id: "ports", width: 260),
            .init(id: "name", width: 275),
            .init(id: "type", width: 110),
            .init(id: "status", width: 205),
            .init(id: "ready", width: 75),
            .init(id: "restarts", width: 90),
            .init(id: "cpu", width: 225),
            .init(id: "memory", width: 245),
        ])
        #expect(fixture.store.set(chooserLayout, for: .clusterContexts))
        #expect(fixture.store.set(containerLayout, for: .podContainers))

        let chooser = ClusterManagerWindowController(
            provider: AnyClusterContextProvider(
                listContexts: { _ in [] },
                openContext: { _ in throw CancellationError() }
            ),
            tableLayoutStore: fixture.store
        )
        let chooserRoot = try #require(chooser.window?.contentViewController?.view)
        let chooserTable = try fixedControllerTable(
            labeled: "Kubeconfig contexts", beneath: chooserRoot
        )
        expectFixedControllerLayout(chooserLayout, in: chooserTable)

        let containers = PodContainerListViewController(
            pod: fixedControllerIdentity(resource: "pods"),
            containers: [],
            tableLayoutStore: fixture.store
        )
        let containerTable = try fixedControllerTable(
            labeled: "Pod containers", beneath: containers.view
        )
        expectFixedControllerLayout(containerLayout, in: containerTable)
    }

    @Test("Details Summary restores its fixed table layout")
    func detailsTables() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let summaryLayout = TableLayout(columns: [
            .init(id: "value", width: 560),
            .init(id: "field", width: 245),
        ])
        #expect(fixture.store.set(summaryLayout, for: .objectSummary))

        let controller = ObjectSummaryViewController(
            identity: fixedControllerIdentity(resource: "deployments", group: "apps"),
            provider: FixedControllerObjectProvider(),
            tableLayoutStore: fixture.store
        )
        let summary = try fixedControllerTable(
            labeled: "Kubernetes object summary", beneath: controller.view
        )
        expectFixedControllerLayout(summaryLayout, in: summary)
    }

    @Test("canonical Data editor restores its key table")
    func dataKeys() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let layout = TableLayout(columns: [
            .init(id: "state", width: 100),
            .init(id: "key", width: 210),
            .init(id: "value", width: 340),
            .init(id: "type", width: 82),
            .init(id: "size", width: 92),
        ])
        #expect(fixture.store.set(layout, for: .objectDataKeys))

        let controller = ObjectDataViewController(
            identity: fixedControllerIdentity(resource: "configmaps"),
            provider: FixedControllerObjectProvider(),
            tableLayoutStore: fixture.store
        )
        let table = try fixedControllerTable(
            labeled: "ConfigMap or Secret data keys and values",
            beneath: controller.view
        )
        expectFixedControllerLayout(layout, in: table)
    }

    @Test("metadata editor restores its shared key table")
    func metadataKeys() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let layout = TableLayout(columns: [
            .init(id: "state", width: 96),
            .init(id: "key", width: 255),
            .init(id: "value", width: 365),
        ])
        #expect(fixture.store.set(layout, for: .objectMetadataKeys))
        let identity = fixedControllerIdentity(resource: "deployments", group: "apps")
        let controller = ResourceMetadataEditorWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "context",
                clusterName: "cluster",
                serverHostname: "api.example.invalid",
                defaultNamespace: "default"
            ),
            identity: identity,
            kind: .labels,
            detailProvider: FixedControllerObjectProvider(),
            operationProvider: FixedControllerOperationProvider(),
            tableLayoutStore: fixture.store
        )
        let root = try #require(controller.window?.contentView)
        let table = try fixedControllerTable(
            labeled: "Labels keys and values",
            beneath: root
        )
        expectFixedControllerLayout(layout, in: table)
    }

    @Test("key-value review restores its changed-key table")
    func keyValueReviewChanges() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let layout = TableLayout(columns: [
            .init(id: "key", width: 330),
            .init(id: "change", width: 110),
            .init(id: "before", width: 150),
            .init(id: "after", width: 165),
        ])
        #expect(fixture.store.set(layout, for: .keyValueDiffChanges))
        let controller = KeyValueDiffConfirmationWindowController(
            editorTitle: "Annotations",
            targetDetails: "cluster · context · deployment/api",
            inputs: [KeyValueDiffInput(
                beforeKey: "example.com/note",
                afterKey: "example.com/note",
                beforeKind: .text,
                beforeValue: Data("before".utf8),
                afterKind: .text,
                afterValue: Data("after".utf8),
                sensitive: false
            )],
            tableLayoutStore: fixture.store
        )
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let table = try fixedControllerTable(
            labeled: "Staged key value changes",
            beneath: root
        )
        expectFixedControllerLayout(layout, in: table)
    }

    @Test("Columns manager and native picker use distinct fixed surfaces")
    func columnsSurfaces() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let managerLayout = TableLayout(columns: [
            .init(id: "column-value", width: 335),
            .init(id: "column-enabled", width: 32),
            .init(id: "column-title", width: 155),
            .init(id: "column-id", width: 140),
            .init(id: "column-source", width: 90),
            .init(id: "column-type", width: 115),
            .init(id: "column-width", width: 95),
        ])
        let pickerLayout = TableLayout(columns: [
            .init(id: "native-identity", width: 255),
            .init(id: "native-title", width: 165),
            .init(id: "native-source", width: 85),
            .init(id: "native-type", width: 135),
            .init(id: "native-availability", width: 115),
        ])
        #expect(fixture.store.set(managerLayout, for: .columnsManager))
        #expect(fixture.store.set(pickerLayout, for: .nativeColumnPicker))
        let match = ColumnResourceMatch(group: "", version: "v1", resource: "pods")

        let manager = ColumnsManagerWindowController(
            resourceTitle: "Pods",
            match: match,
            defaultColumns: [],
            previewProvider: FixedControllerColumnPreviewProvider(),
            previewContext: fixedControllerPreviewContext(),
            configurationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("columns.yaml").path,
            tableLayoutStore: fixture.store
        )
        let managerRoot = try #require(manager.window?.contentView)
        let managerTable = try fixedControllerTable(
            labeled: "Columns for Pods", beneath: managerRoot
        )
        expectFixedControllerLayout(managerLayout, in: managerTable)

        let picker = NativeColumnPickerWindowController(
            match: match,
            existingColumns: [],
            tableLayoutStore: fixture.store
        )
        let pickerRoot = try #require(picker.window?.contentView)
        let pickerTable = try fixedControllerTable(
            labeled: "Available built-in and metric columns", beneath: pickerRoot
        )
        expectFixedControllerLayout(pickerLayout, in: pickerTable)
    }

    @Test("port forwards and delete confirmation restore separate layouts")
    func independentWindowAndSheetTables() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let forwardsLayout = TableLayout(columns: [
            .init(id: "port-forward.address", width: 195),
            .init(id: "port-forward.status", width: 115),
            .init(id: "port-forward.context", width: 225),
            .init(id: "port-forward.target", width: 200),
            .init(id: "port-forward.resolved-pod", width: 205),
            .init(id: "port-forward.started", width: 145),
            .init(id: "port-forward.updated", width: 145),
            .init(id: "port-forward.last-error", width: 280),
        ])
        let deleteLayout = TableLayout(columns: [
            .init(id: "name", width: 265),
            .init(id: "gvr", width: 235),
            .init(id: "namespace", width: 145),
            .init(id: "uid", width: 205),
            .init(id: "visibility", width: 165),
            .init(id: "state", width: 145),
        ])
        #expect(fixture.store.set(forwardsLayout, for: .portForwards))
        #expect(fixture.store.set(deleteLayout, for: .deleteConfirmation))

        let coordinator = PortForwardCoordinator(
            provider: FixedControllerPortForwardProvider()
        )
        let forwards = PortForwardsWindowController(
            coordinator: coordinator,
            tableLayoutStore: fixture.store
        )
        let forwardsRoot = try #require(forwards.window?.contentView)
        let forwardsTable = try fixedControllerTable(
            labeled: "App-wide Kubernetes port-forwards", beneath: forwardsRoot
        )
        expectFixedControllerLayout(forwardsLayout, in: forwardsTable)

        let session = OpenedClusterSession(
            sessionID: "session",
            contextName: "context",
            clusterName: "cluster",
            serverHostname: "api.example.invalid",
            defaultNamespace: "default"
        )
        let delete = DeleteResourcesWindowController(
            session: session,
            targets: [ResourceDeleteTarget(identity: fixedControllerIdentity(
                resource: "deployments", group: "apps"
            ))],
            provider: FixedControllerOperationProvider(),
            tableLayoutStore: fixture.store
        )
        let deleteRoot = try #require(delete.window?.contentView)
        let deleteTable = try fixedControllerTable(
            labeled: "Resources awaiting deletion", beneath: deleteRoot
        )
        expectFixedControllerLayout(deleteLayout, in: deleteTable)
    }

    @Test("YAML diff changed paths restore their fixed table layout")
    func yamlDiffPaths() throws {
        let fixture = try fixedControllerLayoutFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let layout = TableLayout(columns: [
            .init(id: "after", width: 335),
            .init(id: "path", width: 285),
            .init(id: "before", width: 325),
        ])
        #expect(fixture.store.set(layout, for: .yamlDiffPaths))
        let prepared = PreparedYAMLEdit(
            normalizedYAMLUTF8: Data("kind: ConfigMap\n".utf8),
            currentResourceVersion: "rv-1",
            diff: [SemanticDiffEntry(
                path: "data.mode",
                beforeSummary: "safe",
                afterSummary: "fast"
            )]
        )
        let controller = YAMLDiffConfirmationWindowController(
            targetDetails: "UID uid-configmaps",
            prepared: prepared,
            tableLayoutStore: fixture.store
        )
        let root = try #require(controller.window?.contentView)
        let table = try #require(fixedControllerDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.identifier?.rawValue == "yaml-diff-paths" })
        expectFixedControllerLayout(layout, in: table)
    }
}
}

@MainActor
private func fixedControllerLayoutFixture() throws -> (
    defaults: UserDefaults,
    suite: String,
    store: TableLayoutStore
) {
    let suite = "kmgr-fixed-controller-layout-tests-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (
        defaults,
        suite,
        TableLayoutStore(defaults: defaults, persistenceDelay: .seconds(60))
    )
}

@MainActor
private func fixedControllerTable(
    labeled label: String,
    beneath root: NSView
) throws -> NSTableView {
    try #require(fixedControllerDescendants(of: root)
        .compactMap { $0 as? NSTableView }
        .first { $0.accessibilityLabel() == label })
}

@MainActor
private func fixedControllerDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(fixedControllerDescendants(of:))
}

@MainActor
private func expectFixedControllerLayout(
    _ expected: TableLayout,
    in table: NSTableView,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        table.tableColumns.map { $0.identifier.rawValue }
            == expected.columns.map(\.id),
        sourceLocation: sourceLocation
    )
    #expect(table.allowsColumnReordering, sourceLocation: sourceLocation)
    #expect(
        table.columnAutoresizingStyle == .noColumnAutoresizing,
        sourceLocation: sourceLocation
    )
    for (actual, saved) in zip(table.tableColumns, expected.columns) {
        #expect(
            abs(Double(actual.width) - saved.width) < 0.5,
            "\(saved.id) width \(actual.width) != \(saved.width)",
            sourceLocation: sourceLocation
        )
    }
}

private func fixedControllerIdentity(
    resource: String,
    group: String = ""
) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: group,
        version: "v1",
        resource: resource,
        namespace: "default",
        name: "example",
        uid: ResourceUID("uid-\(resource)")
    )
}

private func fixedControllerPreviewContext() -> ColumnPreviewContext {
    ColumnPreviewContext(
        sessionID: "session",
        resource: DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true
        ),
        namespaceScope: NamespaceSelection()
    )
}

private struct FixedControllerColumnPreviewProvider: ColumnPreviewProviding {
    func previewColumn(_ request: ColumnPreviewRequest) async throws -> ColumnPreviewResult {
        throw CancellationError()
    }
}

private struct FixedControllerObjectProvider: ObjectDetailProviding {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        throw CancellationError()
    }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

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

private struct FixedControllerPortForwardProvider: PortForwardProviding {
    func listPortForwards(
        sessionID: String,
        includeStopped: Bool
    ) async throws -> [PortForwardRecord] { [] }

    func watchPortForwards(
        request: PortForwardWatchRequest
    ) -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        request.id
    }

    func stopPortForward(id: String, sessionID: String) async throws {}
    func restartPortForward(id: String, sessionID: String) async throws {}
}

private struct FixedControllerOperationProvider: ResourceOperationProviding {
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
        throw CancellationError()
    }

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws {}
}
