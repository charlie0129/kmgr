import AppKit
import KmgrCore

/// Binds one fully configured fixed `NSTableView` to the process-wide layout
/// store. Install only after every table column has been added.
@MainActor
final class TableLayoutBinding: NSObject {
    private weak var tableView: NSTableView?
    private let store: TableLayoutStore
    private let surface: TableSurfaceID
    private let defaultLayout: TableLayout
    private var storeObserver: UUID?
    private var preferredLayout: TableLayout
    private var renderedWidths: [String: Double] = [:]
    private var adaptiveLastColumnAvailableWidth: Double?
    private var isApplyingStoreLayout = false
    private var isInvalidated = false

    init(
        tableView: NSTableView,
        surface: TableSurfaceID,
        store: TableLayoutStore
    ) {
        self.tableView = tableView
        self.surface = surface
        self.store = store
        let defaultLayout = Self.capture(tableView)
        self.defaultLayout = defaultLayout
        self.preferredLayout = defaultLayout
        super.init()

        let initial = preferredLayout
        precondition(
            TableLayoutStore.isValid(initial),
            "Fixed table columns require unique stable identifiers and bounded widths"
        )
        tableView.allowsColumnReordering = true
        // AppKit column autoresizing is local window geometry, not a user
        // preference. Leaving it enabled would make two differently sized
        // windows repeatedly overwrite one another's shared saved widths.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        renderedWidths = Dictionary(uniqueKeysWithValues: initial.columns.map {
            ($0.id, $0.width)
        })
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tablePresentationChanged(_:)),
            name: NSTableView.columnDidMoveNotification,
            object: tableView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tablePresentationChanged(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: tableView
        )
        storeObserver = store.observe(surface) { [weak self] layout in
            self?.install(layout)
        }
    }

    deinit {
        let observer = storeObserver
        let store = store
        NotificationCenter.default.removeObserver(self)
        if let observer {
            Task { @MainActor in
                store.removeObserver(observer)
            }
        }
    }

    /// Explicit invalidation is useful for controller `stop`/close paths and
    /// removes observers immediately rather than waiting for deallocation.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        NotificationCenter.default.removeObserver(self)
        if let storeObserver {
            store.removeObserver(storeObserver)
            self.storeObserver = nil
        }
    }

    /// Fits the final column to one local viewport without changing the
    /// persisted preferred widths. Summary uses this to keep its two-column
    /// table flush with the viewport while differently sized windows continue
    /// to share one stable user layout without synchronization feedback.
    func fitLastColumn(to availableWidth: CGFloat) {
        let width = Double(availableWidth)
        guard width.isFinite, width > 0 else { return }
        adaptiveLastColumnAvailableWidth = width
        renderPreferredLayout()
    }

    @objc private func tablePresentationChanged(_ notification: Notification) {
        guard !isApplyingStoreLayout, !isInvalidated,
            let tableView, notification.object as? NSTableView === tableView
        else { return }
        let actual = Self.capture(tableView)
        let preferredWidths = Dictionary(uniqueKeysWithValues:
            preferredLayout.columns.map { ($0.id, $0.width) }
        )
        let columns: [TableColumnLayout]
        if notification.name == NSTableView.columnDidMoveNotification {
            // A move changes only order. Preserve preferred widths rather than
            // accidentally saving a locally fitted adaptive final column.
            columns = actual.columns.map { column in
                .init(id: column.id, width: preferredWidths[column.id] ?? column.width)
            }
        } else {
            // Column autoresizing is disabled, so widths that differ from our
            // last render are explicit external/user changes. Preserve any
            // adaptive columns that were not part of this resize gesture.
            columns = actual.columns.map { column in
                let rendered = renderedWidths[column.id]
                let changed = rendered.map { abs($0 - column.width) > 0.5 } ?? true
                return .init(
                    id: column.id,
                    width: changed
                        ? column.width
                        : (preferredWidths[column.id] ?? column.width)
                )
            }
        }
        _ = store.set(TableLayout(columns: columns), for: surface)
    }

    private func install(_ saved: TableLayout?) {
        guard !isInvalidated, let tableView else { return }
        guard let saved else {
            preferredLayout = defaultLayout
            renderPreferredLayout()
            return
        }
        let currentIDs = tableView.tableColumns.map { $0.identifier.rawValue }
        let savedIDs = saved.columns.map(\.id)
        guard Set(currentIDs) == Set(savedIDs), currentIDs.count == savedIDs.count else {
            // Fixed table schemas are strict. A code update that adds, removes,
            // or renames a column resets only this surface to its new defaults.
            _ = store.removeLayout(for: surface)
            return
        }

        var normalizedColumns: [TableColumnLayout] = []
        normalizedColumns.reserveCapacity(saved.columns.count)
        for savedColumn in saved.columns {
            guard let tableColumn = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == savedColumn.id
            }) else { return }
            let minimum = max(
                TableLayoutStore.minimumColumnWidth,
                Double(tableColumn.minWidth)
            )
            let maximum = min(
                TableLayoutStore.maximumColumnWidth,
                Double(tableColumn.maxWidth)
            )
            let width = min(max(savedColumn.width, minimum), max(minimum, maximum))
            normalizedColumns.append(.init(id: savedColumn.id, width: width))
        }
        let normalized = TableLayout(columns: normalizedColumns)
        preferredLayout = normalized
        renderPreferredLayout()

        // Persist min/max normalization once, not on every subsequent restore.
        if normalized != saved {
            _ = store.set(normalized, for: surface)
        }
    }

    private func renderPreferredLayout() {
        guard !isInvalidated, let tableView else { return }
        isApplyingStoreLayout = true
        defer { isApplyingStoreLayout = false }

        for (destination, column) in preferredLayout.columns.enumerated() {
            let source = tableView.column(withIdentifier: .init(column.id))
            if source >= 0, source != destination {
                tableView.moveColumn(source, toColumn: destination)
            }
        }
        for column in preferredLayout.columns {
            if let tableColumn = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == column.id
            }) {
                tableColumn.width = CGFloat(column.width)
            }
        }
        if let available = adaptiveLastColumnAvailableWidth,
            let last = tableView.tableColumns.last
        {
            let preceding = tableView.tableColumns.dropLast().reduce(0.0) {
                $0 + Double($1.width)
            }
            let spacing = Double(tableView.intercellSpacing.width)
                * Double(max(0, tableView.tableColumns.count - 1))
            let minimum = max(
                TableLayoutStore.minimumColumnWidth,
                Double(last.minWidth)
            )
            let maximum = min(
                TableLayoutStore.maximumColumnWidth,
                Double(last.maxWidth)
            )
            last.width = CGFloat(min(
                max(available - preceding - spacing, minimum),
                max(minimum, maximum)
            ))
        }
        renderedWidths = Dictionary(uniqueKeysWithValues:
            Self.capture(tableView).columns.map { ($0.id, $0.width) }
        )
    }

    private static func capture(_ tableView: NSTableView) -> TableLayout {
        TableLayout(columns: tableView.tableColumns.map { column in
            let rawWidth = Double(column.width)
            let width = rawWidth.isFinite
                ? min(
                    max(rawWidth, TableLayoutStore.minimumColumnWidth),
                    TableLayoutStore.maximumColumnWidth
                )
                : max(TableLayoutStore.minimumColumnWidth, 100)
            return TableColumnLayout(id: column.identifier.rawValue, width: width)
        })
    }
}
