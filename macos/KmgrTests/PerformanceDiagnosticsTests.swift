import Testing
@testable import KmgrCore

@Suite("Performance diagnostics")
struct PerformanceDiagnosticsTests {
    @Test("signpost vocabulary remains stable across Release recordings")
    func stableVocabulary() {
        #expect(PerformanceSignpostCatalog.subsystem == Product.bundleIdentifier)
        #expect(PerformanceSignpostCatalog.workspaceStreamCategory == "workspace-stream")
        #expect(PerformanceSignpostCatalog.resourceTableCategory == "resource-table")
        #expect(PerformanceSignpostCatalog.logsCategory == "logs")
        #expect(PerformanceSignpostCatalog.viewEventDecode.description == "ViewEventDecode")
        #expect(PerformanceSignpostCatalog.resourceProjectionRequest.description == "ResourceProjectionRequest")
        #expect(PerformanceSignpostCatalog.resourceModelApply.description == "ResourceModelApply")
        #expect(PerformanceSignpostCatalog.resourceTableReload.description == "ResourceTableReload")
        #expect(PerformanceSignpostCatalog.logStoreAppend.description == "LogStoreAppend")
        #expect(PerformanceSignpostCatalog.logTextFormat.description == "LogTextFormat")
        #expect(PerformanceSignpostCatalog.logTextInstall.description == "LogTextInstall")
    }

    @Test("resource metadata exposes counts and revisions but no object content")
    func resourceBatchMetadata() throws {
        let row = ResourceRow(identity: ResourceIdentity(
            clusterSessionID: "session-secret",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "private-namespace",
            name: "private-name",
            uid: "private-uid"
        ), cells: [])
        let snapshot = ResourceViewMessage.snapshot(
            cursor: StreamCursor(generation: 4, sequence: 7),
            chunk: ResourceSnapshotChunk(
                rows: [row], first: true, last: false, index: 0,
                estimatedTotalRows: 20
            )
        )
        let snapshotMetadata = try #require(snapshot.resourceBatchSignpostMetadata)
        #expect(snapshotMetadata == ResourceBatchSignpostMetadata(
            kind: .snapshot,
            generation: 4,
            sequence: 7,
            upsertCount: 1,
            removalCount: 0,
            orderCount: 1,
            replacesOrder: false
        ))

        let delta = ResourceViewMessage.delta(
            cursor: StreamCursor(generation: 4, sequence: 8),
            delta: ResourceRowDelta(
                upserts: [row],
                removedUIDs: ["another-private-uid"],
                orderedUIDs: ["private-uid"],
                orderIsComplete: true
            )
        )
        let deltaMetadata = try #require(delta.resourceBatchSignpostMetadata)
        #expect(deltaMetadata.upsertCount == 1)
        #expect(deltaMetadata.removalCount == 1)
        #expect(deltaMetadata.orderCount == 1)
        #expect(deltaMetadata.replacesOrder)

        #expect(ResourceViewMessage.status(
            cursor: StreamCursor(generation: 4, sequence: 9),
            status: ResourceViewStatus(freshness: .watching)
        ).resourceBatchSignpostMetadata == nil)
    }
}
