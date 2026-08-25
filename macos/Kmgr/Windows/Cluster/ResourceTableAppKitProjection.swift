import AppKit
import KmgrCore

/// The small main-actor boundary between UID-based table state and AppKit's
/// row-index projection. Keeping this seam independent of the workspace
/// controller lets the synthetic AppKit harness exercise the same reload,
/// selection, and scroll-restoration work used by the product.
@MainActor
enum ResourceTableAppKitProjection {
    static func capture(
        model: ResourceTableModel,
        from tableView: NSTableView,
        modelRowOffset: Int = 0
    ) -> ResourceTableUpdateCapture {
        let firstTableRow = tableView.rows(in: tableView.visibleRect).location
        // At the absolute beginning, the list boundary owns the viewport.
        // Following row zero's identity through a live reorder would move the
        // viewport to its new index and hide the new first row.
        let firstModelRow = firstTableRow == NSNotFound || firstTableRow == 0
            ? NSNotFound : firstTableRow - modelRowOffset
        let uid = model.orderedVisibleUIDs.indices.contains(firstModelRow)
            ? model.orderedVisibleUIDs[firstModelRow] : nil
        let pixelOffset = uid.map { _ in
            Double(
                tableView.rect(ofRow: firstTableRow).minY
                    - tableView.visibleRect.minY
            )
        } ?? 0
        return model.captureUpdate(
            topVisibleUID: uid,
            pixelOffsetFromTop: pixelOffset
        )
    }

    static func apply(
        _ plan: ResourceTableUpdatePlan,
        visibleRowCount: Int,
        to tableView: NSTableView,
        modelRowOffset: Int = 0,
        updateVisibleCell: ((NSView, NSTableColumn, Int) -> Bool)? = nil
    ) {
        let validRows = 0..<max(0, visibleRowCount)
        switch plan.contentUpdate {
        case .reloadAll:
            tableView.reloadData()
        case .refreshCells(let updates):
            var fallbackRowsByColumnIndex: [Int: IndexSet] = [:]
            for update in updates {
                let tableRow = modelRowOffset + update.rowIndex
                guard validRows.contains(tableRow) else { continue }
                let identifier = NSUserInterfaceItemIdentifier(update.columnID)
                let columnIndex = tableView.column(withIdentifier: identifier)
                guard tableView.tableColumns.indices.contains(columnIndex) else {
                    continue
                }
                let column = tableView.tableColumns[columnIndex]
                if let updateVisibleCell {
                    // Offscreen cells have no stale view to update. AppKit asks
                    // the data source for their current model value when they
                    // enter the viewport.
                    guard let view = tableView.view(
                        atColumn: columnIndex,
                        row: tableRow,
                        makeIfNecessary: false
                    ) else { continue }
                    if updateVisibleCell(view, column, tableRow) {
                        continue
                    }
                }
                fallbackRowsByColumnIndex[columnIndex, default: []]
                    .insert(tableRow)
            }
            for (columnIndex, rowIndexes) in fallbackRowsByColumnIndex {
                tableView.reloadData(
                    forRowIndexes: rowIndexes,
                    columnIndexes: IndexSet(integer: columnIndex)
                )
            }
        }

        let selectedRowIndexes = IndexSet(plan.selectedRowIndexes.map {
            modelRowOffset + $0
        }.filter(validRows.contains))
        if tableView.selectedRowIndexes != selectedRowIndexes {
            tableView.selectRowIndexes(
                selectedRowIndexes,
                byExtendingSelection: false
            )
        }
        if let restoration = plan.scrollRestoration {
            let tableRow = modelRowOffset + restoration.rowIndex
            guard validRows.contains(tableRow) else { return }
            let rowRect = tableView.rect(ofRow: tableRow)
            let targetY = max(
                0,
                rowRect.minY - CGFloat(restoration.pixelOffsetFromTop)
            )
            if abs(tableView.visibleRect.minY - targetY) >= 0.5 {
                tableView.scroll(NSPoint(
                    x: tableView.visibleRect.minX,
                    y: targetY
                ))
                if let scrollView = tableView.enclosingScrollView {
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }
}
