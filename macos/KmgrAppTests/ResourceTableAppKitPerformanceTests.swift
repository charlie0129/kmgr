import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource table AppKit harness")
struct ResourceTableAppKitPerformanceTests {
    @Test("targeted updates preserve changed and sibling cell identities")
    func targetedUpdatesStayInPlace() throws {
        let uid: ResourceUID = "node-a"
        let dataSource = SyntheticResourceTableDataSource(
            model: ResourceTableModel(rows: [syntheticRow(
                uid,
                status: "Pending"
            )])
        )
        let tableView = NSTableView()
        for columnID in ["name", "status"] {
            let column = NSTableColumn(identifier: .init(columnID))
            column.width = 180
            tableView.addTableColumn(column)
        }
        tableView.delegate = dataSource
        tableView.dataSource = dataSource

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 120)
        )
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            tableView.delegate = nil
            tableView.dataSource = nil
            window.contentView = NSView()
            window.close()
        }

        tableView.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        let nameView = try #require(tableView.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        let statusView = try #require(tableView.view(
            atColumn: 1,
            row: 0,
            makeIfNecessary: true
        ))
        let requestCountBeforeUpdate = dataSource.requestedCellCount

        let plan = dataSource.model.apply(ResourceRowBatch(upserts: [
            syntheticRow(uid, status: "Ready"),
        ]))
        #expect(plan.contentUpdate == .refreshCells([
            ResourceTableCellUpdate(rowIndex: 0, columnID: "status"),
        ]))

        var refreshedColumnIDs: [String] = []
        ResourceTableAppKitProjection.apply(
            plan,
            visibleRowCount: 1,
            to: tableView,
            updateVisibleCell: { view, column, row in
                refreshedColumnIDs.append(column.identifier.rawValue)
                guard let cell = view as? NSTableCellView else { return false }
                let uid = dataSource.model.orderedVisibleUIDs[row]
                cell.textField?.stringValue = dataSource.model.rowByUID[uid]?[
                    column.identifier.rawValue
                ]?.displayText ?? "—"
                return true
            }
        )

        #expect(refreshedColumnIDs == ["status"])
        #expect(dataSource.requestedCellCount == requestCountBeforeUpdate)
        #expect(tableView.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: false
        ) === nameView)
        #expect(tableView.view(
            atColumn: 1,
            row: 0,
            makeIfNecessary: false
        ) === statusView)
        #expect((statusView as? NSTableCellView)?.textField?.stringValue == "Ready")
    }

    @Test("compact model offsets project onto absolute AppKit rows")
    func compactModelOffsetProjection() throws {
        let rows = (5_000..<5_003).map {
            syntheticRow(ResourceUID("appkit-row-\($0)"))
        }
        let dataSource = SyntheticResourceTableDataSource(
            model: ResourceTableModel(rows: rows),
            tableRowCount: 10_000,
            modelRowOffset: 5_000
        )
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 300
        tableView.addTableColumn(column)
        tableView.delegate = dataSource
        tableView.dataSource = dataSource
        tableView.allowsMultipleSelection = true

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 100)
        )
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            tableView.delegate = nil
            tableView.dataSource = nil
            window.contentView = NSView()
            window.close()
        }

        tableView.reloadData()
        tableView.scroll(NSPoint(
            x: 0,
            y: tableView.rect(ofRow: 5_001).minY + 4
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tableView.layoutSubtreeIfNeeded()

        let capture = ResourceTableAppKitProjection.capture(
            model: dataSource.model,
            from: tableView,
            modelRowOffset: 5_000
        )
        #expect(capture.scrollAnchor?.uid == "appkit-row-5001")
        #expect(capture.scrollAnchor?.priorRowIndex == 1)

        ResourceTableAppKitProjection.apply(
            ResourceTableUpdatePlan(
                selectedRowIndexes: [2],
                scrollRestoration: nil,
                contentUpdate: .refreshCells([])
            ),
            visibleRowCount: 10_000,
            to: tableView,
            modelRowOffset: 5_000
        )
        #expect(tableView.numberOfRows == 10_000)
        #expect(tableView.selectedRowIndexes == IndexSet(integer: 5_002))
    }

    @Test("100,000 rows keep UID selection and scroll while AppKit stays virtualized")
    func largeTableProjection() throws {
        let rowCount = 100_000
        let updateBatchSize = 500
        let updateBatchCount = 8
        let diagnosticsEnabled =
            ProcessInfo.processInfo.environment["KMGR_PERF_DIAGNOSTICS"] == "1"
        let budgetsEnabled =
            ProcessInfo.processInfo.environment["KMGR_PERF_BUDGETS"] == "1"
        let clock = ContinuousClock()

        let allUIDs = (0..<rowCount).map { ResourceUID("appkit-row-\($0)") }
        let rows = allUIDs.map { syntheticRow($0) }
        let dataSource = SyntheticResourceTableDataSource(
            model: ResourceTableModel(rows: rows)
        )
        let tableView = NSTableView()
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.width = 700
        tableView.addTableColumn(nameColumn)
        tableView.delegate = dataSource
        tableView.dataSource = dataSource
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel("Synthetic Kubernetes resources")

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 820, height: 480)
        )
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer {
            tableView.delegate = nil
            tableView.dataSource = nil
            window.contentView = NSView()
            window.close()
        }

        let initialReloadStarted = clock.now
        tableView.reloadData()
        window.contentView?.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        let initialReloadDuration = durationSeconds(clock.now - initialReloadStarted)

        #expect(tableView.numberOfRows == rowCount)
        #expect(tableView.accessibilityRole() == .table)
        #expect(tableView.accessibilityLabel() == "Synthetic Kubernetes resources")

        let selectedUIDs: Set<ResourceUID> = [
            allUIDs[7], allUIDs[25_003], allUIDs[50_009], allUIDs[99_991],
        ]
        dataSource.model.restoreSelection(
            uids: selectedUIDs,
            anchorUID: allUIDs[99_991]
        )
        let selectedIndexes = dataSource.model.orderedVisibleUIDs.enumerated().compactMap {
            selectedUIDs.contains($0.element) ? $0.offset : nil
        }
        let selectionStarted = clock.now
        ResourceTableAppKitProjection.apply(
            ResourceTableUpdatePlan(
                selectedRowIndexes: selectedIndexes,
                scrollRestoration: nil,
                contentUpdate: .refreshCells([])
            ),
            visibleRowCount: rowCount,
            to: tableView
        )
        tableView.layoutSubtreeIfNeeded()
        let selectionDuration = durationSeconds(clock.now - selectionStarted)

        let scrollUID = allUIDs[54_321]
        let scrollRow = try #require(
            dataSource.model.orderedVisibleUIDs.firstIndex(of: scrollUID)
        )
        let intendedClipOffset: CGFloat = 7
        tableView.scroll(NSPoint(
            x: 0,
            y: tableView.rect(ofRow: scrollRow).minY + intendedClipOffset
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tableView.layoutSubtreeIfNeeded()
        let initialCapture = ResourceTableAppKitProjection.capture(
            model: dataSource.model,
            from: tableView
        )
        let capturedScroll = try #require(initialCapture.scrollAnchor)
        #expect(capturedScroll.uid == scrollUID)

        var currentOrder = dataSource.model.orderedVisibleUIDs
        var modelDurations: [TimeInterval] = []
        var appKitDurations: [TimeInterval] = []
        var maximumLiveRowViews = tableView.subviews.count
        for batchIndex in 0..<updateBatchCount {
            let batchUIDs = (0..<updateBatchSize).map { offset in
                let updateNumber = batchIndex * updateBatchSize + offset
                return allUIDs[(updateNumber * 7_919) % rowCount]
            }
            let movedUIDs = Set(batchUIDs)
            currentOrder = Array(batchUIDs.reversed()) + currentOrder.filter {
                !movedUIDs.contains($0)
            }
            let capture = ResourceTableAppKitProjection.capture(
                model: dataSource.model,
                from: tableView
            )
            let updatedRows = batchUIDs.enumerated().map { offset, uid in
                syntheticRow(uid, status: "Updated-\(batchIndex)-\(offset)")
            }

            let modelStarted = clock.now
            let plan = dataSource.model.apply(
                ResourceRowBatch(
                    upserts: updatedRows,
                    visibleOrder: .replace(currentOrder)
                ),
                capture: capture
            )
            modelDurations.append(durationSeconds(clock.now - modelStarted))

            let appKitStarted = clock.now
            ResourceTableAppKitProjection.apply(
                plan,
                visibleRowCount: dataSource.model.orderedVisibleUIDs.count,
                to: tableView
            )
            tableView.layoutSubtreeIfNeeded()
            appKitDurations.append(durationSeconds(clock.now - appKitStarted))
            maximumLiveRowViews = max(maximumLiveRowViews, tableView.subviews.count)
        }

        let projectedSelection = Set(tableView.selectedRowIndexes.compactMap { row in
            dataSource.model.orderedVisibleUIDs.indices.contains(row)
                ? dataSource.model.orderedVisibleUIDs[row] : nil
        })
        let finalCapture = ResourceTableAppKitProjection.capture(
            model: dataSource.model,
            from: tableView
        )
        let finalScroll = try #require(finalCapture.scrollAnchor)
        #expect(projectedSelection == selectedUIDs)
        #expect(finalScroll.uid == scrollUID)
        #expect(abs(finalScroll.pixelOffsetFromTop - capturedScroll.pixelOffsetFromTop) < 0.5)
        #expect(tableView.numberOfRows == rowCount)

        // A view-based NSTableView should ask only for the viewport-sized set
        // of reusable cells, never one view for every compact model row.
        #expect(dataSource.requestedCellCount > 0)
        #expect(dataSource.requestedCellCount < 2_000)
        #expect(maximumLiveRowViews < 200)

        if diagnosticsEnabled || budgetsEnabled {
            let typicalModelDuration = median(modelDurations)
            let maximumModelDuration = modelDurations.max() ?? 0
            let typicalAppKitDuration = median(appKitDurations)
            let maximumAppKitDuration = appKitDurations.max() ?? 0
            print(String(format:
                "kmgr AppKit diagnostic: initial reload %.3f ms; selection %.3f ms; typical model apply %.3f ms; maximum model apply %.3f ms; typical reorder reload %.3f ms; maximum reorder reload %.3f ms; %d cell requests; %d live row views",
                initialReloadDuration * 1_000,
                selectionDuration * 1_000,
                typicalModelDuration * 1_000,
                maximumModelDuration * 1_000,
                typicalAppKitDuration * 1_000,
                maximumAppKitDuration * 1_000,
                dataSource.requestedCellCount,
                maximumLiveRowViews
            ))
            if budgetsEnabled {
                let displayFrame = 1.0 / 60.0
                #expect(
                    selectionDuration <= displayFrame,
                    "Synthetic table selection exceeded one 60 Hz display frame."
                )
                #expect(
                    typicalModelDuration <= displayFrame,
                    "Typical compact-model reorder exceeded one 60 Hz display frame."
                )
                #expect(
                    maximumModelDuration <= displayFrame * 3,
                    "A compact-model reorder exceeded three 60 Hz display frames."
                )
                #expect(
                    typicalAppKitDuration <= displayFrame,
                    "Typical synthetic AppKit reorder exceeded one 60 Hz display frame."
                )
                #expect(
                    maximumAppKitDuration <= displayFrame * 3,
                    "A synthetic AppKit reorder exceeded three 60 Hz display frames."
                )
            }
        }
    }

    private func syntheticRow(
        _ uid: ResourceUID,
        status: String = "Running"
    ) -> ResourceRow {
        ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: "appkit-large-view-session",
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

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
}

@MainActor
private final class SyntheticResourceTableDataSource: NSObject,
    NSTableViewDataSource, NSTableViewDelegate
{
    var model: ResourceTableModel
    private let tableRowCount: Int
    private let modelRowOffset: Int
    private(set) var requestedCellCount = 0

    init(
        model: ResourceTableModel,
        tableRowCount: Int? = nil,
        modelRowOffset: Int = 0
    ) {
        self.model = model
        self.tableRowCount = tableRowCount ?? model.orderedVisibleUIDs.count
        self.modelRowOffset = modelRowOffset
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableRowCount
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let modelRow = row - modelRowOffset
        guard model.orderedVisibleUIDs.indices.contains(modelRow), let tableColumn else {
            return nil
        }
        requestedCellCount += 1
        let columnID = tableColumn.identifier.rawValue
        let identifier = NSUserInterfaceItemIdentifier("synthetic-\(columnID)-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 4, y: 0, width: tableColumn.width - 8, height: 22)
            label.autoresizingMask = [.width, .height]
            cell.addSubview(label)
            cell.textField = label
        }
        let uid = model.orderedVisibleUIDs[modelRow]
        cell.textField?.stringValue = model.rowByUID[uid]?[columnID]?.displayText ?? "—"
        return cell
    }
}
