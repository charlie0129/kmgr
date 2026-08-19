import Testing
@testable import KmgrCore

@Suite("Sparse resource-view range cache")
struct ResourceViewRangeCacheTests {
    @Test("bounds retention and fetches only the current sparse window")
    func boundsSparseWindow() {
        var cache = makeCache(maximumCachedRows: 6)
        #expect(cache.receive(
            cursor: cursor(sequence: 1),
            invalidation: invalidation(rows: 1_000, maxRange: 4)
        ) == .installed)

        let requests = cache.retain(100..<900)
        #expect(requests.map(\.startIndex) == [100, 104])
        #expect(requests.map(\.length) == [4, 2])
        #expect(cache.retainedRange == 100..<106)
        #expect(cache.metricInterest == ResourceMetricInterestRequest(
            sessionID: "session",
            viewID: "view",
            generation: 7,
            indexRevision: 3,
            startIndex: 100,
            length: 6
        ))

        for request in requests {
            let rows = (0..<request.length).map {
                row(index: Int(request.startIndex) + $0, revision: 11)
            }
            #expect(cache.receive(
                ResourceViewRange(
                    viewID: "view",
                    revision: request.revision,
                    startIndex: request.startIndex,
                    rowsVisible: 1_000,
                    rows: rows
                ),
                for: request
            ) == .installed(
                request.startIndex..<(request.startIndex + UInt64(request.length))
            ))
        }
        #expect(cache.cachedRowCount == 6)
        #expect(cache.row(at: 100)?.identity.uid == "uid-100")
        #expect(cache.row(at: 106) == nil)
        #expect(cache.retain(100..<106).isEmpty)
    }

    @Test("hint-only invalidations preserve rows while revision changes reject races")
    func revisionsAndRaces() throws {
        var cache = makeCache(maximumCachedRows: 4)
        _ = cache.receive(
            cursor: cursor(sequence: 1),
            invalidation: invalidation(rows: 20, maxRange: 4)
        )
        let request = try #require(cache.retain(0..<4).first)
        let response = ResourceViewRange(
            viewID: "view",
            revision: request.revision,
            startIndex: 0,
            rowsVisible: 20,
            rows: (0..<4).map { row(index: $0, revision: 11) }
        )
        #expect(cache.receive(response, for: request) == .installed(0..<4))

        var hintsOnly = invalidation(rows: 20, maxRange: 4)
        hintsOnly.observedOptionalResourceKeys = ["vendor.example/gpu"]
        #expect(cache.receive(
            cursor: cursor(sequence: 2),
            invalidation: hintsOnly
        ) == .hintsOnly)
        #expect(cache.cachedRowCount == 4)

        let staleRequest = try #require(cache.retain(8..<12).first)
        #expect(cache.receive(
            cursor: cursor(sequence: 3),
            invalidation: invalidation(
                presentation: 12,
                index: 3,
                rows: 20,
                maxRange: 4
            )
        ) == .advanced(indexChanged: false))
        #expect(cache.cachedRowCount == 0)
        #expect(cache.receive(response, for: staleRequest) == .rejectedRace)

        #expect(cache.receive(
            cursor: cursor(sequence: 4),
            invalidation: invalidation(
                presentation: 13,
                index: 4,
                rows: 21,
                maxRange: 4
            )
        ) == .advanced(indexChanged: true))
        #expect(cache.receive(
            cursor: cursor(sequence: 5),
            invalidation: invalidation(
                presentation: 12,
                index: 3,
                rows: 20,
                maxRange: 4
            )
        ) == .rejectedStale)
    }

    @Test("reconciliation is pinned to the exact fetchable presentation")
    func reconciliationRace() {
        var cache = makeCache()
        _ = cache.receive(
            cursor: cursor(sequence: 1),
            invalidation: invalidation(rows: 0)
        )
        let reconciliation = ResourceViewReconciliation(
            rowsVisible: 0,
            presentationRevision: 11,
            indexRevision: 3
        )
        #expect(cache.matches(
            cursor: cursor(sequence: 2),
            reconciliation: reconciliation
        ))
        _ = cache.receive(
            cursor: cursor(sequence: 3),
            invalidation: invalidation(
                presentation: 12,
                index: 4,
                rows: 1
            )
        )
        #expect(!cache.matches(
            cursor: cursor(sequence: 2),
            reconciliation: reconciliation
        ))
        #expect(cache.retain(0..<0).isEmpty)
        #expect(cache.metricInterest == nil)
    }

    private func makeCache(maximumCachedRows: Int = 512) -> ResourceViewRangeCache {
        ResourceViewRangeCache(
            sessionID: "session",
            viewID: "view",
            generation: 7,
            maximumCachedRows: maximumCachedRows
        )
    }

    private func cursor(sequence: UInt64) -> StreamCursor {
        StreamCursor(generation: 7, sequence: sequence)
    }

    private func invalidation(
        presentation: UInt64 = 11,
        index: UInt64 = 3,
        rows: UInt64,
        maxRange: Int = 512
    ) -> ResourceViewInvalidation {
        ResourceViewInvalidation(
            presentationRevision: presentation,
            indexRevision: index,
            rowsVisible: rows,
            maxRangeLength: maxRange
        )
    }

    private func row(index: Int, revision: Int) -> ResourceRow {
        ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: "session",
                group: "",
                version: "v1",
                resource: "pods",
                namespace: "default",
                name: "pod-\(index)",
                uid: ResourceUID("uid-\(index)")
            ),
            cells: [
                Cell(
                    columnID: "name",
                    displayText: "pod-\(index)-r\(revision)"
                ),
            ]
        )
    }
}
