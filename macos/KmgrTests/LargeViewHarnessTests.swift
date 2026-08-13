import Foundation
import Testing
@testable import KmgrCore

@Suite("LargeViewHarness")
struct LargeViewHarnessTests {
    @Test func progressiveSnapshotAndReordersPreserveIdentityState() throws {
        let rowCount = 100_000
        let snapshotChunkSize = 500
        let updateBatchSize = 500
        let updateBatchCount = 8
        let diagnosticsEnabled =
            ProcessInfo.processInfo.environment["KMGR_PERF_DIAGNOSTICS"] == "1"

        var phaseStartedAt = Date()
        var phaseTimings: [(String, TimeInterval)] = []
        func recordTiming(_ name: String) {
            guard diagnosticsEnabled else { return }
            let now = Date()
            phaseTimings.append((name, now.timeIntervalSince(phaseStartedAt)))
            phaseStartedAt = now
        }

        let allUIDs = (0..<rowCount).map { ResourceUID("large-view-\($0)") }
        var model = ResourceTableModel()

        for chunkStart in stride(from: 0, to: rowCount, by: snapshotChunkSize) {
            let chunkEnd = min(chunkStart + snapshotChunkSize, rowCount)
            let chunkUIDs = Array(allUIDs[chunkStart..<chunkEnd])
            let chunkRows = chunkUIDs.map { compactRow($0) }
            model.apply(ResourceRowBatch(
                upserts: chunkRows,
                visibleOrder: .append(chunkUIDs)
            ))
        }
        recordTiming("progressive 100,000-row snapshot")

        #expect(model.rowByUID.count == rowCount)
        #expect(model.orderedVisibleUIDs.count == rowCount)
        #expect(Set(model.orderedVisibleUIDs).count == rowCount)
        #expect(Set(model.orderedVisibleUIDs) == Set(allUIDs))

        let selectedUIDs = [
            allUIDs[7],
            allUIDs[25_003],
            allUIDs[50_009],
            allUIDs[99_991],
        ]
        model.selectExclusively(selectedUIDs[0])
        for uid in selectedUIDs.dropFirst() {
            model.toggleSelection(of: uid)
        }
        let expectedSelection = Set(selectedUIDs)
        let expectedSelectionAnchor = selectedUIDs.last

        let scrollUID = allUIDs[54_321]
        let scrollOffset = 13.25
        let updateCapture = model.captureUpdate(
            topVisibleUID: scrollUID,
            pixelOffsetFromTop: scrollOffset
        )

        var expectedStatuses: [ResourceUID: String] = [:]
        var currentOrder = model.orderedVisibleUIDs
        var finalPlan: ResourceTableUpdatePlan?

        for batchIndex in 0..<updateBatchCount {
            let updateRange =
                (batchIndex * updateBatchSize)..<((batchIndex + 1) * updateBatchSize)
            let batchUIDs = updateRange.map { updateNumber in
                // 7,919 is coprime with 100,000, so all 4,000 updates address
                // distinct identities while remaining deterministic.
                allUIDs[(updateNumber * 7_919) % rowCount]
            }
            let batchRows = batchUIDs.enumerated().map { offset, uid in
                let status = "Updated-\(batchIndex)-\(offset)"
                expectedStatuses[uid] = status
                return compactRow(uid, status: status)
            }

            // Model a backend sort projection in which every changed row moves.
            // Replacing the order once per batch exercises thousands of
            // reorder-producing updates without making the harness quadratic.
            let movedUIDs = Set(batchUIDs)
            currentOrder = batchUIDs.reversed() + currentOrder.filter {
                !movedUIDs.contains($0)
            }
            finalPlan = model.apply(
                ResourceRowBatch(
                    upserts: batchRows,
                    visibleOrder: .replace(currentOrder)
                ),
                capture: updateCapture
            )
        }
        recordTiming("4,000 row updates across 8 reorder batches")

        let plan = try #require(finalPlan)
        let restoration = try #require(plan.scrollRestoration)
        let finalIndexByUID = Dictionary(
            uniqueKeysWithValues: model.orderedVisibleUIDs.enumerated().map { ($1, $0) }
        )

        #expect(expectedStatuses.count == updateBatchSize * updateBatchCount)
        #expect(model.selectedUIDs == expectedSelection)
        #expect(model.selectionAnchorUID == expectedSelectionAnchor)
        #expect(Set(plan.selectedRowIndexes.map { model.orderedVisibleUIDs[$0] }) == expectedSelection)
        #expect(restoration.uid == scrollUID)
        #expect(restoration.rowIndex == finalIndexByUID[scrollUID])
        #expect(restoration.pixelOffsetFromTop == scrollOffset)
        #expect(restoration.precision == .exactIdentity)
        #expect(expectedStatuses.allSatisfy { uid, status in
            model.rowByUID[uid]?["status"]?.displayText == status
        })

        // Upserts and repeated order projections must not accumulate duplicate
        // row or ordering state as the large view changes.
        #expect(model.rowByUID.count == rowCount)
        #expect(model.orderedVisibleUIDs.count == rowCount)
        #expect(Set(model.orderedVisibleUIDs).count == rowCount)
        #expect(model.rowByUID.values.allSatisfy { $0.cells.count == 2 })
        recordTiming("identity and bounded-state verification")

        if diagnosticsEnabled {
            for (phase, elapsed) in phaseTimings {
                print(String(format: "kmgr large-view diagnostic: %.3fs — %@", elapsed, phase))
            }
        }
    }

    private func compactRow(
        _ uid: ResourceUID,
        status: String = "Running"
    ) -> ResourceRow {
        ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: "large-view-session",
                group: "",
                version: "v1",
                resource: "pods",
                namespace: "default",
                name: uid.rawValue,
                uid: uid
            ),
            cells: [
                Cell(
                    columnID: "name",
                    displayText: uid.rawValue,
                    typedValue: .string(uid.rawValue)
                ),
                Cell(
                    columnID: "status",
                    displayText: status,
                    typedValue: .string(status)
                ),
            ]
        )
    }
}
