import Darwin.Mach
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
        let budgetsEnabled =
            ProcessInfo.processInfo.environment["KMGR_PERF_BUDGETS"] == "1"

        // Opt-in Release diagnostics, intentionally disabled in the normal
        // deterministic suite. These are generous enough for a busy modern
        // Apple Silicon developer machine and catch order-of-magnitude model
        // regressions without pretending to be UI frame-latency evidence.
        let phaseBudgets: [String: TimeInterval] = [
            "progressive 100,000-row snapshot": 15,
            "4,000 row updates across 8 reorder batches": 5,
            "identity and bounded-state verification": 2,
        ]

        var phaseStartedAt = Date()
        var phaseTimings: [(String, TimeInterval)] = []
        func recordTiming(_ name: String) {
            let now = Date()
            let elapsed = now.timeIntervalSince(phaseStartedAt)
            if diagnosticsEnabled || budgetsEnabled {
                phaseTimings.append((name, elapsed))
            }
            phaseStartedAt = now
        }

        let initialMemory: ProcessMemorySnapshot?
        if diagnosticsEnabled || budgetsEnabled {
            initialMemory = try ProcessMemorySnapshot.capture()
        } else {
            initialMemory = nil
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
        let finalMemory: ProcessMemorySnapshot?
        if diagnosticsEnabled || budgetsEnabled {
            finalMemory = try ProcessMemorySnapshot.capture()
        } else {
            finalMemory = nil
        }

        if diagnosticsEnabled || budgetsEnabled {
            for (phase, elapsed) in phaseTimings {
                let budget = phaseBudgets[phase]
                let suffix = budget.map { String(format: " (budget %.3fs)", $0) } ?? ""
                print(String(format: "kmgr large-view diagnostic: %.3fs — %@%@", elapsed, phase, suffix))
                if budgetsEnabled, let budget {
                    #expect(
                        elapsed <= budget,
                        "Release diagnostic phase '\(phase)' exceeded its opt-in \(budget)s budget."
                    )
                }
            }
            if let initialMemory, let finalMemory {
                let physicalGrowth = finalMemory.physicalFootprintBytes
                    .subtractingWithoutUnderflow(initialMemory.physicalFootprintBytes)
                let peakPhysicalGrowth = finalMemory.peakPhysicalFootprintBytes
                    .subtractingWithoutUnderflow(initialMemory.peakPhysicalFootprintBytes)
                print(String(format:
                    "kmgr large-view memory: resident %.1f MiB; physical footprint %.1f MiB (delta %.1f MiB); peak physical footprint %.1f MiB (delta %.1f MiB)",
                    finalMemory.residentBytes.mebibytes,
                    finalMemory.physicalFootprintBytes.mebibytes,
                    physicalGrowth.mebibytes,
                    finalMemory.peakPhysicalFootprintBytes.mebibytes,
                    peakPhysicalGrowth.mebibytes
                ))
                if budgetsEnabled {
                    let maximumPeakPhysicalGrowth = UInt64(384 * 1_024 * 1_024)
                    #expect(
                        peakPhysicalGrowth <= maximumPeakPhysicalGrowth,
                        "The 100,000-row model increased peak physical footprint by more than 384 MiB."
                    )
                }
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

private struct ProcessMemorySnapshot {
    var residentBytes: UInt64
    var physicalFootprintBytes: UInt64
    var peakPhysicalFootprintBytes: UInt64

    static func capture() throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw ProcessMemorySnapshotError.taskInfo(result)
        }
        return Self(
            residentBytes: UInt64(info.resident_size),
            physicalFootprintBytes: UInt64(info.phys_footprint),
            peakPhysicalFootprintBytes: UInt64(max(0, info.ledger_phys_footprint_peak))
        )
    }
}

private enum ProcessMemorySnapshotError: Error {
    case taskInfo(kern_return_t)
}

private extension UInt64 {
    var mebibytes: Double { Double(self) / Double(1_024 * 1_024) }

    func subtractingWithoutUnderflow(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
