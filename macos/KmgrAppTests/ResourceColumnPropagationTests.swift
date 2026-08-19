import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Shared resource columns", .serialized)
struct ResourceColumnPropagationTests {
    @Test("reopening Columns preserves presentation and the third sort click clears it")
    func podColumnRebuildRetainsThreeStateSort() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let provider = ColumnPropagationWorkspaceProvider(resource: pods)
        let workspace = makeWorkspace(
            suffix: "pod-sort-cycle",
            provider: provider,
            optionalResourceCatalogProvider: ExactResourceCatalogProvider(
                resourceName: "nvidia.com/gpu",
                category: .accelerator,
                displayName: "NVIDIA GPU"
            ),
            configurationPath: fixture.path
        )
        start([workspace])
        defer { workspace.close() }

        let acceleratorID = "resource:nvidia.com/gpu"
        try await waitUntil {
            provider.streamRequests.count >= 2
                && self.resourceTable(in: workspace)?.tableColumns.contains {
                    $0.identifier.rawValue == acceleratorID
                } == true
        }
        let table = try #require(resourceTable(in: workspace))

        let noSort = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource?.tableView?(table, sortDescriptorsDidChange: noSort)
        try await waitUntil {
            provider.streamRequests.last?.sort == [ResourceSortDescriptor(
                columnID: "name",
                direction: .ascending
            )]
        }

        // A native click on another header retains the old descriptor as a
        // secondary key. Resource tables intentionally expose one-column
        // sorting, so the header cycle must discard that retained key.
        let nameAscending = table.sortDescriptors
        table.sortDescriptors = [
            NSSortDescriptor(key: acceleratorID, ascending: true),
            NSSortDescriptor(key: "name", ascending: true),
        ]
        table.dataSource?.tableView?(table, sortDescriptorsDidChange: nameAscending)
        try await waitUntil {
            table.sortDescriptors.count == 1
                && provider.streamRequests.last?.sort == [ResourceSortDescriptor(
                    columnID: acceleratorID,
                    direction: .ascending
                )]
        }

        let acceleratorAscending = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: acceleratorID, ascending: false)]
        table.dataSource?.tableView?(
            table,
            sortDescriptorsDidChange: acceleratorAscending
        )
        try await waitUntil {
            provider.streamRequests.last?.sort == [ResourceSortDescriptor(
                columnID: acceleratorID,
                direction: .descending
            )]
        }

        // Reinstall the same effective Pod columns through the Columns… seam.
        // AppKit clears descriptors when a sorted NSTableColumn is removed, so
        // this pins the optional-resource rebuild regression seen only on Pods
        // and Nodes.
        let acceleratorColumn = try #require(table.tableColumns.first(where: {
            $0.identifier.rawValue == acceleratorID
        }))
        acceleratorColumn.width = 347
        try moveColumn(acceleratorColumn, to: 0, in: table)
        let customizedOrder = table.tableColumns.map { $0.identifier.rawValue }
        let columnsRequest = try #require(resourceColumnsRequest(in: workspace))
        columnsRequest.apply(
            columnsRequest.defaultColumns + columnsRequest.discoveredColumns
        )
        try await waitUntil {
            table.sortDescriptors.first?.key == acceleratorID
                && table.sortDescriptors.first?.ascending == false
        }
        #expect(table.tableColumns.map { $0.identifier.rawValue } == customizedOrder)
        #expect(table.tableColumns.first { $0.identifier.rawValue == acceleratorID }?.width == 347)

        // AppKit's next native proposal wraps descending back to ascending.
        // The resource table interprets that third click as no sort.
        let descending = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: acceleratorID, ascending: true)]
        table.dataSource?.tableView?(table, sortDescriptorsDidChange: descending)
        try await waitUntil {
            table.sortDescriptors.isEmpty
                && provider.streamRequests.last?.sort.isEmpty == true
        }
    }

    @Test("pending column moves remain bounded for valid restoration")
    func pendingColumnMoveHistoryIsBounded() {
        var presentation = DeferredColumnPresentationState(columns: [], sort: [])
        for index in 0...DeferredColumnPresentationState.maximumMoveCount {
            presentation.recordColumnMove(ColumnMoveState(
                columnID: "name",
                targetIndex: index % 2
            ))
        }

        #expect(presentation.columnMoves.count == DeferredColumnPresentationState.maximumMoveCount)
        #expect(presentation.columnMoves.first?.targetIndex == 1)
        #expect(presentation.columnMoves.last?.targetIndex == 0)

        var oversizedTarget = DeferredColumnPresentationState(columns: [], sort: [])
        oversizedTarget.recordColumnMove(ColumnMoveState(columnID: "name", targetIndex: 999))
        #expect(
            oversizedTarget.columnMoves == [ColumnMoveState(
                columnID: "name",
                targetIndex: DeferredColumnPresentationState.maximumMoveCount - 1
            )]
        )
    }

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
        let appliedCount = applySavedColumns(
            definitions,
            matching: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            to: workspaces
        )

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

    @Test("an exact-GVR save preserves sibling caches without a file reload")
    func savedEditPreservesOtherGVRCaches() async throws {
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
        let podsProvider = ColumnPropagationWorkspaceProvider(resource: pods)
        let nodesProvider = ColumnPropagationWorkspaceProvider(resource: nodes)
        let podsWorkspace = makeWorkspace(
            suffix: "saved-pods",
            provider: podsProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path
        )
        let nodesWorkspace = makeWorkspace(
            suffix: "reloaded-nodes",
            provider: nodesProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path
        )
        let workspaces = [podsWorkspace, nodesWorkspace]
        start(workspaces)
        defer { workspaces.forEach { $0.close() } }

        try await waitUntil {
            guard let podsTable = self.resourceTable(in: podsWorkspace),
                let nodesTable = self.resourceTable(in: nodesWorkspace)
            else { return false }
            return podsProvider.streamRequests.last?.columnIDs
                    == podsTable.tableColumns.map { $0.identifier.rawValue }
                && nodesProvider.streamRequests.last?.columnIDs
                    == nodesTable.tableColumns.map { $0.identifier.rawValue }
        }
        let nodesTable = try #require(resourceTable(in: nodesWorkspace))
        let originalNodeIDs = nodesTable.tableColumns.map { $0.identifier.rawValue }
        let originalNodeTitles = nodesTable.tableColumns.map(\.title)
        let originalNodeRequestCount = nodesProvider.streamRequests.count
        let savedPods = sharedSavedColumnDefinitions()

        let appliedCount = applySavedColumns(
            savedPods,
            matching: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            to: workspaces
        )

        #expect(appliedCount == 1)
        try await waitUntil {
            self.resourceTable(in: podsWorkspace)?.tableColumns.map {
                $0.identifier.rawValue
            } == savedPods.map(\.id)
        }
        #expect(nodesTable.tableColumns.map { $0.identifier.rawValue } == originalNodeIDs)
        #expect(nodesTable.tableColumns.map(\.title) == originalNodeTitles)
        #expect(nodesProvider.streamRequests.count == originalNodeRequestCount)
    }

    @Test("resource-table drag layout persists and synchronizes by exact GVR")
    func tableLayoutPersistsAndSynchronizesByExactGVR() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let match = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
        let definitions = [
            ColumnDefinition(
                id: "name", title: "Name", source: .builtin,
                value: "name", type: .string, width: 160
            ),
            ColumnDefinition(
                id: "status", title: "Status", source: .builtin,
                value: "status", type: .string, width: 120
            ),
        ]
        try ColumnConfigurationFileStore(path: fixture.path).save(
            ColumnsConfigurationDocument(views: [ResourceColumnConfiguration(
                match: match,
                columns: definitions
            )])
        )
        let coordinator = ColumnConfigurationCoordinator(
            path: fixture.path,
            layoutPersistenceDelay: .milliseconds(20)
        )
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let firstProvider = ColumnPropagationWorkspaceProvider(resource: pods)
        let secondProvider = ColumnPropagationWorkspaceProvider(resource: pods)
        let first = makeWorkspace(
            suffix: "layout-first",
            provider: firstProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationCoordinator: coordinator
        )
        let second = makeWorkspace(
            suffix: "layout-second",
            provider: secondProvider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationCoordinator: coordinator
        )
        start([first, second])
        defer { first.close(); second.close() }

        try await waitUntil {
            self.resourceTable(in: first)?.tableColumns.map {
                $0.identifier.rawValue
            } == ["name", "status"]
                && self.resourceTable(in: second)?.tableColumns.map {
                    $0.identifier.rawValue
                } == ["name", "status"]
                && firstProvider.streamRequests.last?.columnIDs == ["name", "status"]
                && secondProvider.streamRequests.last?.columnIDs == ["name", "status"]
        }
        let firstTable = try #require(resourceTable(in: first))
        let secondTable = try #require(resourceTable(in: second))
        let initialFirstRequests = firstProvider.streamRequests.count
        let initialSecondRequests = secondProvider.streamRequests.count
        let status = try #require(firstTable.tableColumns.first {
            $0.identifier.rawValue == "status"
        })
        try moveColumn(status, to: 0, in: firstTable)
        let oldWidth = status.width
        status.width = 333
        firstTable.delegate?.tableViewColumnDidResize?(Notification(
            name: NSTableView.columnDidResizeNotification,
            object: firstTable,
            userInfo: ["NSTableColumn": status, "NSOldWidth": oldWidth]
        ))

        try await waitUntil {
            guard let saved = try? ColumnConfigurationFileStore(path: fixture.path)
                .load().views.first(where: { $0.match == match })?.columns
            else { return false }
            return saved.map(\.id) == ["status", "name"]
                && saved.first?.width == 333
                && secondTable.tableColumns.map { $0.identifier.rawValue }
                    == ["status", "name"]
                && secondTable.tableColumns.first?.width == 333
        }
        // Order and preferred width are presentation-only; retaining the same
        // extractor set must not reopen either LIST/WATCH stream.
        #expect(firstProvider.streamRequests.count == initialFirstRequests)
        #expect(secondProvider.streamRequests.count == initialSecondRequests)
        #expect(firstTable.columnAutoresizingStyle == .noColumnAutoresizing)
        #expect(secondTable.columnAutoresizingStyle == .noColumnAutoresizing)
    }

    @Test("exact-GVR file layout wins over stale per-window restoration")
    func persistedLayoutWinsOverRestoredPresentation() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let definitions = [
            ColumnDefinition(
                id: "name",
                title: "Name From File",
                source: .builtin,
                value: "name",
                type: .string,
                width: 140
            ),
            ColumnDefinition(
                id: "restored-custom",
                title: "Custom From File",
                source: .cel,
                expression: "object.metadata.name",
                type: .string,
                width: 150
            ),
        ]
        try await ColumnConfigurationFileStore(path: fixture.path).saveOffMain(
            ColumnsConfigurationDocument(views: [ResourceColumnConfiguration(
                match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
                columns: definitions
            )])
        )
        let restoration = ClusterWindowRestorationState(
            contextName: "restored-columns",
            gvr: GVR(group: "", version: "v1", resource: "pods"),
            sort: [SortDescriptorState(columnID: "restored-custom", ascending: false)]
        )
        let provider = ColumnPropagationWorkspaceProvider(resource: pods)
        let workspace = makeWorkspace(
            suffix: "restored-custom",
            provider: provider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            restorationState: restoration
        )
        start([workspace])
        defer { workspace.close() }

        try await waitUntil {
            guard let table = self.resourceTable(in: workspace) else { return false }
            return table.tableColumns.map { $0.identifier.rawValue }
                == ["name", "restored-custom"]
                && table.sortDescriptors.first?.key == "restored-custom"
                && table.sortDescriptors.first?.ascending == false
                && provider.streamRequests.last?.sort.first?.columnID == "restored-custom"
                && provider.streamRequests.last?.sort.first?.direction == .descending
        }
        let table = try #require(resourceTable(in: workspace))
        #expect(table.tableColumns[0].width == 140)
        #expect(table.tableColumns[1].width == 150)
        #expect(table.tableColumns.map(\.title) == ["Name From File", "Custom From File"])
    }

    @Test("presentation changes made during a late load win over saved restoration")
    func presentationChangesWinDuringLateConfigurationLoad() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let loader = StagedColumnConfigurationDocumentLoader()
        defer { loader.cancelPendingLoads() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let definitions = restoredColumnDefinitions()
        let restoration = restoredColumnPresentationState()
        let provider = ColumnPropagationWorkspaceProvider(resource: pods)
        let workspace = makeWorkspace(
            suffix: "restored-user-change",
            provider: provider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationLoader: loader.loader,
            restorationState: restoration
        )
        var checkpoint: ClusterWindowRestorationRecord?
        workspace.onRestorationCheckpoint = { checkpoint = $0 }
        start([workspace])
        defer { workspace.close() }

        try await waitUntil {
            loader.requestIsPending(1)
                && self.resourceTable(in: workspace)?.tableColumns.contains(where: {
                    $0.identifier.rawValue == "name"
                }) == true
        }
        let table = try #require(resourceTable(in: workspace))
        let name = try #require(table.tableColumns.first(where: {
            $0.identifier.rawValue == "name"
        }))
        try moveColumn(name, to: 0, in: table)
        let oldWidth = name.width
        name.width = 900
        table.delegate?.tableViewColumnDidResize?(Notification(
            name: NSTableView.columnDidResizeNotification,
            object: table,
            userInfo: ["NSTableColumn": name, "NSOldWidth": oldWidth]
        ))
        let oldSort = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        table.dataSource?.tableView?(table, sortDescriptorsDidChange: oldSort)

        try await waitUntil {
            checkpoint?.state.sort.first
                == SortDescriptorState(columnID: "name", ascending: false)
        }
        loader.complete(
            attempt: 1,
            with: ColumnsConfigurationDocument(views: [ResourceColumnConfiguration(
                match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
                columns: definitions
            )])
        )

        try await waitUntil {
            table.tableColumns.map { $0.identifier.rawValue } == ["name", "restored-custom"]
                && table.sortDescriptors.first?.key == "name"
                && table.sortDescriptors.first?.ascending == false
                && provider.streamRequests.last?.sort.first?.columnID == "name"
                && provider.streamRequests.last?.sort.first?.direction == .descending
        }
        #expect(table.tableColumns[0].width == 900)
        #expect(table.tableColumns[1].width == 150)
    }

    @Test("fresh navigation changes win without replacing untouched file presentation")
    func freshPresentationChangesWinDuringLateConfigurationLoad() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let loader = StagedColumnConfigurationDocumentLoader()
        defer { loader.cancelPendingLoads() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let saved = restoredColumnDefinitions()
        var custom = saved[1]
        custom.width = 777
        let status = ColumnDefinition(
            id: "status",
            title: "Status From File",
            source: .builtin,
            value: "status",
            type: .string,
            width: 600
        )
        let definitions = [custom, saved[0], status]
        let provider = ColumnPropagationWorkspaceProvider(resource: pods)
        let workspace = makeWorkspace(
            suffix: "fresh-user-change",
            provider: provider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationLoader: loader.loader
        )
        var checkpoint: ClusterWindowRestorationRecord?
        workspace.onRestorationCheckpoint = { checkpoint = $0 }
        start([workspace])
        defer { workspace.close() }

        try await waitUntil {
            loader.requestIsPending(1)
                && provider.streamRequests.last?.resource.resource == "pods"
        }
        let table = try #require(resourceTable(in: workspace))
        let name = try #require(table.tableColumns.first(where: {
            $0.identifier.rawValue == "name"
        }))
        let statusColumn = try #require(table.tableColumns.first(where: {
            $0.identifier.rawValue == "status"
        }))
        try moveColumn(statusColumn, to: 0, in: table)
        try moveColumn(statusColumn, to: 2, in: table)
        try moveColumn(statusColumn, to: 0, in: table)
        let oldWidth = name.width
        name.width = 900
        table.delegate?.tableViewColumnDidResize?(Notification(
            name: NSTableView.columnDidResizeNotification,
            object: table,
            userInfo: ["NSTableColumn": name, "NSOldWidth": oldWidth]
        ))
        let oldSort = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        table.dataSource?.tableView?(table, sortDescriptorsDidChange: oldSort)
        try await waitUntil {
            checkpoint?.state.sort.first
                == SortDescriptorState(columnID: "name", ascending: false)
        }

        loader.complete(
            attempt: 1,
            with: ColumnsConfigurationDocument(views: [ResourceColumnConfiguration(
                match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
                columns: definitions
            )])
        )
        try await waitUntil {
            table.tableColumns.map { $0.identifier.rawValue }
                == ["status", "restored-custom", "name"]
                && table.sortDescriptors.first?.key == "name"
                && table.sortDescriptors.first?.ascending == false
                && provider.streamRequests.last?.sort.first?.columnID == "name"
        }
        #expect(table.tableColumns[0].width == 600)
        #expect(table.tableColumns[1].width == 777)
        #expect(table.tableColumns[2].width == 900)
    }

    @Test("a saved definition reconciles one in-flight configuration load")
    func savedDefinitionReconcilesInFlightLoad() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let loader = StagedColumnConfigurationDocumentLoader()
        defer { loader.cancelPendingLoads() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let definitions = restoredColumnDefinitions()
        let provider = ColumnPropagationWorkspaceProvider(resource: pods)
        let workspace = makeWorkspace(
            suffix: "restored-save-race",
            provider: provider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationLoader: loader.loader,
            restorationState: restoredColumnPresentationState()
        )
        start([workspace])
        defer { workspace.close() }

        try await waitUntil { loader.requestIsPending(1) }
        #expect(applySavedColumns(
            definitions,
            matching: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            to: [workspace]
        ) == 1)

        let table = try #require(resourceTable(in: workspace))
        try await waitUntil {
            table.tableColumns.map { $0.identifier.rawValue } == ["name", "restored-custom"]
                && table.sortDescriptors.first?.key == "restored-custom"
                && table.sortDescriptors.first?.ascending == false
                && provider.streamRequests.last?.sort.first?.columnID == "restored-custom"
        }
        #expect(table.tableColumns[0].width == 140)
        #expect(table.tableColumns[1].width == 150)

        let document = ColumnsConfigurationDocument(views: [ResourceColumnConfiguration(
            match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            columns: definitions
        )])
        loader.complete(attempt: 1, with: document)
        try await waitUntil { loader.pendingRequestCount == 0 }
        #expect(table.tableColumns.map { $0.identifier.rawValue } == ["name", "restored-custom"])
        #expect(table.sortDescriptors.first?.key == "restored-custom")
    }

    @Test("fresh navigation before load preserves persisted order without gestures")
    func freshNavigationPreservesPersistedPresentation() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let loader = StagedColumnConfigurationDocumentLoader()
        defer { loader.cancelPendingLoads() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let nodes = DiscoveredResource(
            group: "", version: "v1", resource: "nodes", kind: "Node",
            namespaced: false, verbs: ["list", "watch"]
        )
        var custom = restoredColumnDefinitions()[1]
        custom.width = 777
        var name = restoredColumnDefinitions()[0]
        name.width = 666
        let provider = ColumnPropagationWorkspaceProvider(resources: [pods, nodes])
        let workspace = makeWorkspace(
            suffix: "fresh-navigation-race",
            provider: provider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationLoader: loader.loader
        )
        var checkpoint: ClusterWindowRestorationRecord?
        workspace.onRestorationCheckpoint = { checkpoint = $0 }
        start([workspace])
        defer { workspace.close() }

        try await waitUntil {
            loader.requestIsPending(1)
                && provider.streamRequests.last?.resource.resource == "pods"
                && checkpoint?.state.gvr?.resource == "pods"
        }
        let encodedCheckpoint = try JSONEncoder().encode(checkpoint?.state)
        #expect(!String(decoding: encodedCheckpoint, as: UTF8.self).contains("columns"))

        let outline = try #require(resourceOutline(in: workspace))
        let nodesRow = try #require((0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? DiscoveredResource)?.resource == "nodes"
        }))
        outline.selectRowIndexes(IndexSet(integer: nodesRow), byExtendingSelection: false)
        try await waitUntil { provider.streamRequests.last?.resource.resource == "nodes" }

        loader.complete(
            attempt: 1,
            with: ColumnsConfigurationDocument(views: [
                ResourceColumnConfiguration(
                    match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
                    columns: [custom, name]
                ),
                ResourceColumnConfiguration(
                    match: ColumnResourceMatch(group: "", version: "v1", resource: "nodes"),
                    columns: [ColumnDefinition(
                        id: "name",
                        title: "Node From File",
                        source: .builtin,
                        value: "name",
                        type: .string,
                        width: 260
                    )]
                ),
            ])
        )
        try await waitUntil {
            self.resourceTable(in: workspace)?.tableColumns.map(\.title) == ["Node From File"]
        }

        workspace.navigateBack(nil)
        try await waitUntil {
            guard let table = self.resourceTable(in: workspace) else { return false }
            return provider.streamRequests.last?.resource.resource == "pods"
                && table.tableColumns.map { $0.identifier.rawValue }
                    == ["restored-custom", "name"]
                && table.sortDescriptors.isEmpty
        }
        let table = try #require(resourceTable(in: workspace))
        #expect(table.tableColumns[0].width == 777)
        #expect(table.tableColumns[1].width == 666)
    }

    @Test("navigation preserves pending custom presentation until definitions load")
    func navigationPreservesDeferredRestoration() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let loader = StagedColumnConfigurationDocumentLoader()
        defer { loader.cancelPendingLoads() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let nodes = DiscoveredResource(
            group: "", version: "v1", resource: "nodes", kind: "Node",
            namespaced: false, verbs: ["list", "watch"]
        )
        let provider = ColumnPropagationWorkspaceProvider(resources: [pods, nodes])
        let workspace = makeWorkspace(
            suffix: "restored-navigation-race",
            provider: provider,
            optionalResourceCatalogProvider: NoOptionalResourceCatalogProvider(),
            configurationPath: fixture.path,
            configurationLoader: loader.loader,
            restorationState: restoredColumnPresentationState()
        )
        start([workspace])
        defer { workspace.close() }

        try await waitUntil {
            loader.requestIsPending(1)
                && provider.streamRequests.last?.resource.resource == "pods"
        }
        let outline = try #require(resourceOutline(in: workspace))
        let nodesRow = try #require((0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? DiscoveredResource)?.resource == "nodes"
        }))
        outline.selectRowIndexes(IndexSet(integer: nodesRow), byExtendingSelection: false)
        try await waitUntil { provider.streamRequests.last?.resource.resource == "nodes" }

        loader.complete(
            attempt: 1,
            with: ColumnsConfigurationDocument(views: [
                ResourceColumnConfiguration(
                    match: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
                    columns: restoredColumnDefinitions()
                ),
                ResourceColumnConfiguration(
                    match: ColumnResourceMatch(group: "", version: "v1", resource: "nodes"),
                    columns: [ColumnDefinition(
                        id: "name",
                        title: "Node From File",
                        source: .builtin,
                        value: "name",
                        type: .string,
                        width: 260
                    )]
                ),
            ])
        )
        try await waitUntil {
            self.resourceTable(in: workspace)?.tableColumns.map(\.title) == ["Node From File"]
        }

        workspace.navigateBack(nil)
        try await waitUntil {
            guard let table = self.resourceTable(in: workspace) else { return false }
            return provider.streamRequests.last?.resource.resource == "pods"
                && table.tableColumns.map { $0.identifier.rawValue }
                    == ["name", "restored-custom"]
                && table.sortDescriptors.first?.key == "restored-custom"
                && table.sortDescriptors.first?.ascending == false
        }
        let table = try #require(resourceTable(in: workspace))
        #expect(table.tableColumns[0].width == 140)
        #expect(table.tableColumns[1].width == 150)
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
            guard let firstRequest = resourceColumnsRequest(in: first),
                let secondRequest = resourceColumnsRequest(in: second)
            else { return false }
            return firstRequest.discoveredColumns.contains {
                $0.id == hugePagesID && !$0.isEnabled
            } && secondRequest.discoveredColumns.contains {
                $0.id == acceleratorID && $0.isEnabled
            } && resourceTable(in: second)?.tableColumns.contains {
                $0.identifier.rawValue == acceleratorID
            } == true
        }
        let definitions = sharedSavedColumnDefinitions()
        let appliedCount = applySavedColumns(
            definitions,
            matching: ColumnResourceMatch(group: "", version: "v1", resource: "pods"),
            to: workspaces
        )

        #expect(appliedCount == 2)
        let firstIDs = try #require(resourceTable(in: first)).tableColumns.map {
            $0.identifier.rawValue
        }
        let secondIDs = try #require(resourceTable(in: second)).tableColumns.map {
            $0.identifier.rawValue
        }
        #expect(firstIDs == definitions.map(\.id))
        #expect(secondIDs == definitions.map(\.id) + [acceleratorID])
        let firstDiscovered = try #require(resourceColumnsRequest(in: first))
            .discoveredColumns
        let secondDiscovered = try #require(resourceColumnsRequest(in: second))
            .discoveredColumns
        #expect(firstDiscovered.map(\.id) == [hugePagesID])
        #expect(firstDiscovered.allSatisfy { !$0.isEnabled })
        #expect(secondDiscovered.map(\.id) == [acceleratorID])
        #expect(secondDiscovered.allSatisfy { $0.isEnabled })
        #expect(!firstIDs.contains(acceleratorID))
        #expect(!secondIDs.contains(hugePagesID))
    }

    @Test("cold empty snapshot refreshes when a live exact resource appears")
    func coldEmptySnapshotThenLiveHugePages() async throws {
        let fixture = try ColumnPropagationFixture()
        defer { fixture.remove() }
        let pods = DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )
        let streamProvider = ColdOptionalResourceWorkspaceProvider(resource: pods)
        let catalogProvider = StagedOptionalResourceCatalogProvider()
        defer { catalogProvider.cancelPendingCatalogs() }
        let workspace = makeWorkspace(
            suffix: "cold-optional-resource",
            provider: streamProvider,
            optionalResourceCatalogProvider: catalogProvider,
            configurationPath: fixture.path
        )
        start([workspace])
        defer { workspace.close() }

        let hugePagesID = "resource:hugepages-2Mi"
        let acceleratorID = "resource:nvidia.com/gpu"
        try await waitUntil {
            catalogProvider.requestCount == 1
                && catalogProvider.firstRequestIsPending
                && self.resourceTable(in: workspace)?.numberOfRows == 0
        }
        let table = try #require(resourceTable(in: workspace))
        #expect(!table.tableColumns.contains { $0.identifier.rawValue == hugePagesID })
        #expect(streamProvider.streamRequests.count == 1)

        streamProvider.emitLivePod()
        try await waitUntil {
            table.numberOfRows == 1
                && catalogProvider.requestCount == 1
                && catalogProvider.firstRequestIsPending
        }

        // Repeated and truncated hints consumed during the same request still
        // coalesce into one authoritative follow-up.
        streamProvider.emitOptionalResourceHintOnly()
        streamProvider.emitOptionalResourceHintOnly(truncated: true)
        streamProvider.emitLivePod(observedOptionalResourceKeys: [])
        try await waitUntil {
            table.numberOfRows == 2
                && catalogProvider.requestCount == 1
                && catalogProvider.firstRequestIsPending
        }
        catalogProvider.completeColdCatalog()

        try await waitUntil {
            catalogProvider.requestCount == 2
                && catalogProvider.secondRequestIsPending
                && streamProvider.streamRequests.count == 1
        }

        // A different exact key arrives during request 2. Its pending hint
        // must survive the column reproject caused when that response confirms
        // only huge pages; the gen-2 warm snapshot does not repeat this key.
        streamProvider.emitOptionalResourceHintOnly(["nvidia.com/gpu"])
        streamProvider.emitLivePod(observedOptionalResourceKeys: [])
        try await waitUntil {
            table.numberOfRows == 3
                && catalogProvider.requestCount == 2
                && catalogProvider.secondRequestIsPending
        }
        catalogProvider.completeHugePageCatalog()

        try await waitUntil {
            catalogProvider.requestCount == 3
                && table.tableColumns.contains {
                    $0.identifier.rawValue == acceleratorID
                }
                && !table.tableColumns.contains {
                    $0.identifier.rawValue == hugePagesID
                }
                && streamProvider.streamRequests.last?.columnIDs
                    .contains(acceleratorID) == true
                && streamProvider.streamRequests.last?.columnIDs
                    .contains(hugePagesID) == false
                && streamProvider.streamRequests.count == 2
                && table.numberOfRows == 3
                && resourceColumnsRequest(in: workspace)?.discoveredColumns
                    .contains(where: {
                        $0.id == hugePagesID && !$0.isEnabled
                    }) == true
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(catalogProvider.requestCount == 3)
        #expect(streamProvider.streamRequests.count == 2)
        #expect(table.numberOfRows == 3)

        // Huge-page sizes are discovered but intentionally start disabled.
        // Enabling the definition through the same request used by Columns…
        // must still project the exact resource alongside the accelerator.
        let columnsRequest = try #require(resourceColumnsRequest(in: workspace))
        var hugePages = try #require(columnsRequest.discoveredColumns.first {
            $0.id == hugePagesID
        })
        #expect(!hugePages.isEnabled)
        hugePages.enabled = true
        columnsRequest.apply(columnsRequest.defaultColumns + [hugePages])

        try await waitUntil {
            table.tableColumns.contains {
                $0.identifier.rawValue == hugePagesID
            } && table.tableColumns.contains {
                $0.identifier.rawValue == acceleratorID
            } && streamProvider.streamRequests.last?.columnIDs
                .contains(hugePagesID) == true
                && streamProvider.streamRequests.last?.columnIDs
                    .contains(acceleratorID) == true
                && streamProvider.streamRequests.count == 3
                && table.numberOfRows == 3
        }
    }

    private func makeWorkspace(
        suffix: String,
        provider: any WorkspaceResourceProviding,
        optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
        configurationPath: String,
        configurationCoordinator: ColumnConfigurationCoordinator? = nil,
        configurationLoader: ColumnConfigurationDocumentLoader = .fileSystem,
        restorationState: ClusterWindowRestorationState? = nil
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
            columnsConfigurationPath: configurationPath,
            columnConfigurationCoordinator: configurationCoordinator,
            columnsConfigurationLoader: configurationLoader,
            restorationState: restorationState
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

    private func resourceColumnsRequest(
        in controller: ClusterWorkspaceWindowController
    ) -> ResourceColumnsRequest? {
        guard let root = controller.window?.contentView,
            let button = descendants(of: root).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Columns…" })
        else { return nil }
        var request: ResourceColumnsRequest?
        controller.onShowColumns = { request = $0 }
        button.performClick(nil)
        return request
    }

    private func resourceOutline(
        in controller: ClusterWorkspaceWindowController
    ) -> NSOutlineView? {
        guard let root = controller.window?.contentView else { return nil }
        return descendants(of: root).compactMap { $0 as? NSOutlineView }
            .first { $0.accessibilityLabel() == "Kubernetes resource kinds" }
    }

    private func moveColumn(
        _ column: NSTableColumn,
        to targetIndex: Int,
        in table: NSTableView
    ) throws {
        let sourceIndex = try #require(table.tableColumns.firstIndex(of: column))
        let delegate = table.delegate
        table.delegate = nil
        table.moveColumn(sourceIndex, toColumn: targetIndex)
        table.delegate = delegate
        delegate?.tableViewColumnDidMove?(Notification(
            name: NSTableView.columnDidMoveNotification,
            object: table,
            userInfo: ["NSOldColumn": sourceIndex, "NSNewColumn": targetIndex]
        ))
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

private func restoredColumnDefinitions() -> [ColumnDefinition] {
    [
        ColumnDefinition(
            id: "name",
            title: "Name From File",
            source: .builtin,
            value: "name",
            type: .string,
            width: 140
        ),
        ColumnDefinition(
            id: "restored-custom",
            title: "Custom From File",
            source: .cel,
            expression: "object.metadata.name",
            type: .string,
            width: 150
        ),
    ]
}

private func restoredColumnPresentationState() -> ClusterWindowRestorationState {
    ClusterWindowRestorationState(
        contextName: "restored-columns",
        gvr: GVR(group: "", version: "v1", resource: "pods"),
        sort: [SortDescriptorState(columnID: "restored-custom", ascending: false)]
    )
}

@MainActor
private func applySavedColumns(
    _ definitions: [ColumnDefinition],
    matching match: ColumnResourceMatch,
    to workspaces: [ClusterWorkspaceWindowController]
) -> Int {
    workspaces.reduce(into: 0) { count, workspace in
        if workspace.applySavedColumns(definitions, matching: match) {
            count += 1
        }
    }
}

private final class StagedColumnConfigurationDocumentLoader: @unchecked Sendable {
    private typealias PendingLoad = CheckedContinuation<
        ColumnsConfigurationDocument,
        any Error
    >

    private let lock = NSLock()
    private var requestCount = 0
    private var pendingLoads: [Int: PendingLoad] = [:]

    var loader: ColumnConfigurationDocumentLoader {
        ColumnConfigurationDocumentLoader { [weak self] _ in
            guard let self else { throw CancellationError() }
            return try await self.load()
        }
    }

    var pendingRequestCount: Int { lock.withLock { pendingLoads.count } }

    func requestIsPending(_ attempt: Int) -> Bool {
        lock.withLock { pendingLoads[attempt] != nil }
    }

    func complete(attempt: Int, with document: ColumnsConfigurationDocument) {
        let continuation = lock.withLock { pendingLoads.removeValue(forKey: attempt) }
        continuation?.resume(returning: document)
    }

    func cancelPendingLoads() {
        let continuations = lock.withLock { () -> [PendingLoad] in
            let result = Array(pendingLoads.values)
            pendingLoads.removeAll(keepingCapacity: true)
            return result
        }
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func load() async throws -> ColumnsConfigurationDocument {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requestCount += 1
                pendingLoads[requestCount] = continuation
            }
        }
    }
}

private final class ColumnPropagationWorkspaceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    let resources: [DiscoveredResource]
    private let lock = NSLock()
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(resource: DiscoveredResource) {
        resources = [resource]
    }

    init(resources: [DiscoveredResource]) {
        self.resources = resources
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: resources)
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
            if request.stageUntilReconciled {
                continuation.yield(.reconciled(
                    cursor: StreamCursor(
                        generation: request.generation,
                        sequence: 2
                    ),
                    reconciliation: ResourceViewReconciliation(rowsVisible: 1)
                ))
            }
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

private final class ColdOptionalResourceWorkspaceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    let resource: DiscoveredResource
    private let lock = NSLock()
    private var storedStreamRequests: [ResourceViewRequest] = []
    private var continuations: [
        UInt64: AsyncThrowingStream<ResourceViewMessage, Error>.Continuation
    ] = [:]
    private var nextSequence: UInt64 = 2
    private var emittedUIDs: [ResourceUID] = []

    init(resource: DiscoveredResource) {
        self.resource = resource
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [resource])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { ["default"] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        let rows = lock.withLock { () -> [ResourceRow] in
            storedStreamRequests.append(request)
            return emittedUIDs.map { Self.row(request: request, uid: $0) }
        }
        return AsyncThrowingStream { [weak self] continuation in
            self?.lock.withLock {
                self?.continuations[request.generation] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.continuations.removeValue(forKey: request.generation)
                }
            }
            continuation.yield(.snapshot(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                chunk: ResourceSnapshotChunk(
                    rows: rows,
                    first: true,
                    last: true,
                    index: 0,
                    estimatedTotalRows: UInt64(rows.count),
                    observedOptionalResourceKeys:
                        rows.isEmpty ? [] : ["hugepages-2Mi"]
                )
            ))
            if request.stageUntilReconciled {
                continuation.yield(.reconciled(
                    cursor: StreamCursor(
                        generation: request.generation,
                        sequence: 2
                    ),
                    reconciliation: ResourceViewReconciliation(
                        rowsVisible: UInt64(rows.count)
                    )
                ))
            }
        }
    }

    func emitLivePod(
        observedOptionalResourceKeys: Set<String> = ["hugepages-2Mi"],
        truncated: Bool = false
    ) {
        let state = lock.withLock { () -> (
            ResourceViewRequest,
            AsyncThrowingStream<ResourceViewMessage, Error>.Continuation,
            UInt64,
            ResourceUID,
            [ResourceUID]
        )? in
            guard let request = storedStreamRequests.first,
                let continuation = continuations[request.generation]
            else { return nil }
            let sequence = nextSequence
            nextSequence += 1
            let uid = ResourceUID("uid-live-huge-page-\(sequence)")
            emittedUIDs.append(uid)
            return (request, continuation, sequence, uid, emittedUIDs)
        }
        guard let (request, continuation, sequence, uid, order) = state else { return }
        continuation.yield(.delta(
            cursor: StreamCursor(generation: request.generation, sequence: sequence),
            delta: ResourceRowDelta(
                upserts: [Self.row(request: request, uid: uid)],
                orderedUIDs: order,
                orderIsComplete: true,
                observedOptionalResourceKeys: observedOptionalResourceKeys,
                observedOptionalResourceKeysTruncated: truncated
            )
        ))
    }

    func emitOptionalResourceHintOnly(
        _ keys: Set<String> = ["hugepages-2Mi"],
        truncated: Bool = false
    ) {
        let state = lock.withLock { () -> (
            ResourceViewRequest,
            AsyncThrowingStream<ResourceViewMessage, Error>.Continuation,
            UInt64
        )? in
            guard let request = storedStreamRequests.first,
                let continuation = continuations[request.generation]
            else { return nil }
            let sequence = nextSequence
            nextSequence += 1
            return (request, continuation, sequence)
        }
        guard let (request, continuation, sequence) = state else { return }
        continuation.yield(.delta(
            cursor: StreamCursor(generation: request.generation, sequence: sequence),
            delta: ResourceRowDelta(
                observedOptionalResourceKeys: keys,
                observedOptionalResourceKeysTruncated: truncated
            )
        ))
    }

    private static func row(
        request: ResourceViewRequest,
        uid: ResourceUID
    ) -> ResourceRow {
        ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: request.sessionID,
                group: "",
                version: "v1",
                resource: "pods",
                namespace: "default",
                name: "live-pod-\(uid.rawValue)",
                uid: uid
            ),
            cells: request.columnIDs.map {
                Cell(columnID: $0, displayText: "value")
            }
        )
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private final class StagedOptionalResourceCatalogProvider: OptionalResourceCatalogProviding,
    @unchecked Sendable
{
    private typealias PendingRequest = (
        OptionalResourceCatalogRequest,
        CheckedContinuation<OptionalResourceCatalog, any Error>
    )

    private let lock = NSLock()
    private var storedRequestCount = 0
    private var pendingRequests: [Int: PendingRequest] = [:]

    var requestCount: Int { lock.withLock { storedRequestCount } }
    var firstRequestIsPending: Bool { requestIsPending(1) }
    var secondRequestIsPending: Bool { requestIsPending(2) }

    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog
    {
        let attempt = lock.withLock { () -> Int in
            storedRequestCount += 1
            return storedRequestCount
        }
        if attempt <= 2 {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    pendingRequests[attempt] = (request, continuation)
                }
            }
        }
        return Self.catalog(
            request: request,
            attempt: attempt,
            resources: [Self.hugePage(request), Self.accelerator(request)]
        )
    }

    func completeColdCatalog() {
        completeRequest(1, resources: { _ in [] })
    }

    func completeHugePageCatalog() {
        completeRequest(2, resources: { request in [Self.hugePage(request)] })
    }

    func cancelPendingCatalogs() {
        let continuations = lock.withLock { () -> [
            CheckedContinuation<OptionalResourceCatalog, any Error>
        ] in
            let result = pendingRequests.values.map { $0.1 }
            pendingRequests.removeAll(keepingCapacity: true)
            return result
        }
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func requestIsPending(_ attempt: Int) -> Bool {
        lock.withLock { pendingRequests[attempt] != nil }
    }

    private func completeRequest(
        _ attempt: Int,
        resources: (OptionalResourceCatalogRequest) -> [OptionalResourceCatalogEntry]
    ) {
        let pending = lock.withLock { pendingRequests.removeValue(forKey: attempt) }
        guard let (request, continuation) = pending else { return }
        continuation.resume(returning: Self.catalog(
            request: request,
            attempt: attempt,
            resources: resources(request)
        ))
    }

    private static func hugePage(
        _ request: OptionalResourceCatalogRequest
    ) -> OptionalResourceCatalogEntry {
        OptionalResourceCatalogEntry(
            exactKey: "hugepages-2Mi",
            category: .hugePage,
            isPresent: true,
            displayName: "Huge Pages (2Mi)",
            applicableResource: request.applicableResource
        )
    }

    private static func accelerator(
        _ request: OptionalResourceCatalogRequest
    ) -> OptionalResourceCatalogEntry {
        OptionalResourceCatalogEntry(
            exactKey: "nvidia.com/gpu",
            category: .accelerator,
            isPresent: true,
            displayName: "NVIDIA GPU",
            applicableResource: request.applicableResource
        )
    }

    private static func catalog(
        request: OptionalResourceCatalogRequest,
        attempt: Int,
        resources: [OptionalResourceCatalogEntry]
    ) -> OptionalResourceCatalog {
        OptionalResourceCatalog(
            requestID: "cold-catalog-\(attempt)",
            resources: resources,
            nodesCacheAvailable: false,
            podsCacheAvailable: true,
            nodesSnapshotComplete: false,
            podsSnapshotComplete: attempt > 2,
            potentiallyIncomplete: attempt <= 2
        )
    }
}
