import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Shared resource columns", .serialized)
struct ResourceColumnPropagationTests {
    @Test("a saved edit reaches every exact-GVR window without changing other window state")
    func savedEditPropagatesByExactGVR() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let nodes = DiscoveredResource(
            group: "", version: "v1", resource: "nodes", kind: "Node",
            namespaced: false, verbs: ["list", "watch"]
        )
        let firstProvider = ColumnPropagationWorkspaceProvider(resource: pods)
        let secondProvider = ColumnPropagationWorkspaceProvider(resource: pods)
        let otherProvider = ColumnPropagationWorkspaceProvider(resource: nodes)
        let first = makeWorkspace(
            suffix: "first",
            provider: firstProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path
        )
        let second = makeWorkspace(
            suffix: "second",
            provider: secondProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path
        )
        let other = makeWorkspace(
            suffix: "other",
            provider: otherProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path
        )
        let workspaces = [first, second, other]
        start(workspaces)
        defer { workspaces.forEach { $0.close() } }

        try await waitUntil {
            firstProvider.streamRequests.count == 1
                && secondProvider.streamRequests.count == 1
                && otherProvider.streamRequests.count == 1
                && resourceTable(in: first)?.numberOfRows == 1
                && resourceTable(in: second)?.numberOfRows == 1
        }
        let firstTable = try #require(resourceTable(in: first))
        let secondTable = try #require(resourceTable(in: second))
        let otherTable = try #require(resourceTable(in: other))
        let otherColumnIDs = otherTable.tableColumns.map { $0.identifier.rawValue }
        let otherRequestCount = otherProvider.streamRequests.count

        try setResourceFilter("namespace:payments", in: first)
        try setResourceFilter("status:Running", in: second)
        try await waitUntil {
            firstProvider.streamRequests.last?.filterExpression == "namespace:payments"
                && secondProvider.streamRequests.last?.filterExpression == "status:Running"
        }
        firstTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        firstTable.delegate?.tableViewSelectionDidChange?(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: firstTable
        ))
        #expect(firstTable.selectedRowIndexes == IndexSet(integer: 0))
        #expect(secondTable.selectedRowIndexes.isEmpty)

        let definitions = sharedSavedColumnDefinitions()
        let appliedCount = SavedResourceColumnsChange(
            match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            definitions: definitions
        ).apply(to: workspaces)

        #expect(appliedCount == 2)
        try await waitUntil {
            firstProvider.streamRequests.last?.columnIDs == definitions.map(\.id)
                && secondProvider.streamRequests.last?.columnIDs == definitions.map(\.id)
        }
        #expect(firstTable.tableColumns.map { $0.identifier.rawValue } == definitions.map(\.id))
        #expect(secondTable.tableColumns.map { $0.identifier.rawValue } == definitions.map(\.id))
        #expect(firstTable.tableColumns.map(\.title) == definitions.map(\.title))
        #expect(firstTable.tableColumns.first?.width == 177)
        #expect(otherTable.tableColumns.map { $0.identifier.rawValue } == otherColumnIDs)
        #expect(otherProvider.streamRequests.count == otherRequestCount)
        #expect(try resourceFilter(in: first).stringValue == "namespace:payments")
        #expect(try resourceFilter(in: second).stringValue == "status:Running")
        #expect(firstTable.selectedRowIndexes == IndexSet(integer: 0))
        #expect(secondTable.selectedRowIndexes.isEmpty)
    }

    @Test("each same-GVR window retains its exact optional-resource overlay")
    func savedEditPreservesPerWindowExactResources() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let hugePagesID = "resource:hugepages-2Mi"
        let acceleratorID = "resource:nvidia.com/gpu"
        let first = makeWorkspace(
            suffix: "huge-pages",
            provider: ColumnPropagationWorkspaceProvider(resource: pods),
            optionalResourceCatalogProvider: ExactResourceCatalogProvider(
                resourceName: "hugepages-2Mi",
                category: .hugePage,
                displayName: "Huge Pages 2Mi"
            ),
            configurationPath: fixture.path
        )
        let second = makeWorkspace(
            suffix: "accelerator",
            provider: ColumnPropagationWorkspaceProvider(resource: pods),
            optionalResourceCatalogProvider: ExactResourceCatalogProvider(
                resourceName: "nvidia.com/gpu",
                category: .accelerator,
                displayName: "NVIDIA GPU"
            ),
            configurationPath: fixture.path
        )
        let workspaces = [first, second]
        start(workspaces)
        defer { workspaces.forEach { $0.close() } }

        try await waitUntil {
            resourceTable(in: first)?.tableColumns.contains {
                $0.identifier.rawValue == hugePagesID
            } == true && resourceTable(in: second)?.tableColumns.contains {
                $0.identifier.rawValue == acceleratorID
            } == true
        }
        let definitions = sharedSavedColumnDefinitions()
        let appliedCount = SavedResourceColumnsChange(
            match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            definitions: definitions
        ).apply(to: workspaces)

        #expect(appliedCount == 2)
        let firstIDs = try #require(resourceTable(in: first)).tableColumns.map {
            $0.identifier.rawValue
        }
        let secondIDs = try #require(resourceTable(in: second)).tableColumns.map {
            $0.identifier.rawValue
        }
        #expect(firstIDs == definitions.map(\.id) + [hugePagesID])
        #expect(secondIDs == definitions.map(\.id) + [acceleratorID])
        #expect(!firstIDs.contains(acceleratorID))
        #expect(!secondIDs.contains(hugePagesID))
    }

    private func makeWorkspace(
        suffix: String,
        provider: any WorkspaceResourceProviding,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        configurationPath: String
    ) -> ClusterWorkspaceWindowController {
        makeColumnPropagationWorkspace(
            session: OpenedClusterSession(
                sessionID: "column-propagation-\(suffix)",
                contextName: suffix,
                clusterName: "cluster-\(suffix)",
                serverHostname: "\(suffix).example.invalid",
                defaultNamespace: "default"
            ),
            provider: provider,
            optionalResourceCatalogProvider: optionalResourceCatalogProvider,
            columnsConfigurationPath: configurationPath
        )
    }

    private func start(_ workspaces: [ClusterWorkspaceWindowController]) {
        for workspace in workspaces {
            workspace.showWindow(nil)
            // Starting discovery does not require a visible test window. Keep
            // these from stealing key-window state from concurrently running
            // AppKit suites.
            workspace.window?.orderOut(nil)
        }
    }

    private func resourceTable(
        in controller: ClusterWorkspaceWindowController
    ) -> NSTableView? {
        guard let root = controller.window?.contentView else { return nil }
        return descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" }
    }

    private func resourceFilter(
        in controller: ClusterWorkspaceWindowController
    ) throws -> NSSearchField {
        let root = try #require(controller.window?.contentView)
        return try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
    }

    private func setResourceFilter(
        _ value: String,
        in controller: ClusterWorkspaceWindowController
    ) throws {
        let field = try resourceFilter(in: controller)
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(
            name: NSControl.textDidChangeNotification,
            object: field
        ))
    }

    private func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "AppKitTestTimeout",
                    message: "Timed out waiting for shared columns to settle.",
                    operation: "test shared resource columns"
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
}

private struct ColumnPropagationFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-column-propagation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    var path: String {
        directory.appendingPathComponent("columns.yaml", isDirectory: false).path
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func sharedSavedColumnDefinitions() -> [ColumnDefinition] {
    [
        ColumnDefinition(
            id: "status",
            title: "Workload State",
            source: .builtin,
            value: "status",
            type: .string,
            alignment: .center,
            width: 177
        ),
        ColumnDefinition(
            id: "name",
            title: "Object",
            source: .builtin,
            value: "name",
            type: .string,
            width: 311
        ),
    ]
}

private final class ColumnPropagationWorkspaceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    let resource: DiscoveredResource
    private let lock = NSLock()
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(resource: DiscoveredResource) {
        self.resource = resource
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: [resource])
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        ["default", "payments"]
    }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        lock.withLock { storedStreamRequests.append(request) }
        let row = ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: request.sessionID,
                group: request.resource.group,
                version: request.resource.version,
                resource: request.resource.resource,
                namespace: request.resource.namespaced ? "default" : "",
                name: "sample",
                uid: ResourceUID("uid-\(request.sessionID)")
            ),
            cells: request.columnIDs.map { columnID in
                Cell(columnID: columnID, displayText: "\(columnID)-value")
            }
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.snapshot(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                chunk: ResourceSnapshotChunk(
                    rows: [row],
                    first: true,
                    last: true,
                    index: 0,
                    estimatedTotalRows: 1
                )
            ))
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private struct NoOptionalResourceCatalogProvider: OptionalResourceCatalogProviding {
    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog {
        throw CancellationError()
    }
}

private struct ExactResourceCatalogProvider: OptionalResourceCatalogProviding {
    var resourceName: String
    var category: OptionalResourceCategory
    var displayName: String

    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog {
        OptionalResourceCatalog(
            requestID: UUID().uuidString,
            resources: [OptionalResourceCatalogEntry(
                exactKey: resourceName,
                category: category,
                isPresent: true,
                displayName: displayName,
                applicableResource: request.applicableResource
            )],
            nodesCacheAvailable: true,
            podsCacheAvailable: true,
            nodesSnapshotComplete: true,
            podsSnapshotComplete: true,
            potentiallyIncomplete: false
        )
    }
}
