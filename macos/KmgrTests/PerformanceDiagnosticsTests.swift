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

    @Test("resource metadata exposes only bounded counts and revisions")
    func resourceInvalidationMetadata() throws {
        let invalidation = ResourceViewMessage.invalidation(
            cursor: StreamCursor(generation: 4, sequence: 7),
            invalidation: ResourceViewInvalidation(
                presentationRevision: 19,
                indexRevision: 8,
                rowsVisible: 2_000_000,
                maxRangeLength: 512,
                observedOptionalResourceKeys: ["private.example/key"]
            )
        )
        let metadata = try #require(
            invalidation.resourceInvalidationSignpostMetadata
        )
        #expect(metadata == ResourceInvalidationSignpostMetadata(
            generation: 4,
            sequence: 7,
            presentationRevision: 19,
            indexRevision: 8,
            rowsVisible: 2_000_000
        ))

        #expect(ResourceViewMessage.status(
            cursor: StreamCursor(generation: 4, sequence: 9),
            status: ResourceViewStatus(freshness: .watching)
        ).resourceInvalidationSignpostMetadata == nil)
    }
}
