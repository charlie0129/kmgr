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
        from tableView: NSTableView
    ) -> ResourceTableUpdateCapture {
        let firstRow = tableView.rows(in: tableView.visibleRect).location
        let uid = model.orderedVisibleUIDs.indices.contains(firstRow)
            ? model.orderedVisibleUIDs[firstRow] : nil
        let pixelOffset = uid.map { _ in
            Double(tableView.rect(ofRow: firstRow).minY - tableView.visibleRect.minY)
        } ?? 0
        return model.captureUpdate(
            topVisibleUID: uid,
            pixelOffsetFromTop: pixelOffset
        )
    }

    static func apply(
        _ plan: ResourceTableUpdatePlan,
        visibleRowCount: Int,
        to tableView: NSTableView
    ) {
        let validRows = 0..<max(0, visibleRowCount)
        switch plan.contentUpdate {
        case .reloadAll:
            tableView.reloadData()
        case .reloadRows(let rows):
            let rowIndexes = IndexSet(rows.filter(validRows.contains))
            let columnIndexes = IndexSet(integersIn: tableView.tableColumns.indices)
            if !rowIndexes.isEmpty, !columnIndexes.isEmpty {
                tableView.reloadData(
                    forRowIndexes: rowIndexes,
                    columnIndexes: columnIndexes
                )
            }
        }

        tableView.selectRowIndexes(
            IndexSet(plan.selectedRowIndexes),
            byExtendingSelection: false
        )
        if let restoration = plan.scrollRestoration,
            validRows.contains(restoration.rowIndex)
        {
            let rowRect = tableView.rect(ofRow: restoration.rowIndex)
            let targetY = max(
                0,
                rowRect.minY - CGFloat(restoration.pixelOffsetFromTop)
            )
            tableView.scroll(NSPoint(x: tableView.visibleRect.minX, y: targetY))
            if let scrollView = tableView.enclosingScrollView {
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }
}
