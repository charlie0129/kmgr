import AppKit
import Foundation
import Testing
@testable import Kmgr
@testable import KmgrCore

extension AppKitTestHarness {
@MainActor
@Suite("Fixed table layout binding", .serialized)
struct TableLayoutBindingTests {
    @Test("saved order and widths restore after all columns are configured")
    func restoresSavedLayout() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let saved = TableLayout(columns: [
            .init(id: "state", width: 92),
            .init(id: "name", width: 310),
        ])
        #expect(fixture.store.set(saved, for: .podContainers))
        let table = fixedTable([("name", 180), ("state", 120)])

        let binding = TableLayoutBinding(
            tableView: table,
            surface: .podContainers,
            store: fixture.store
        )
        defer { binding.invalidate() }

        #expect(table.tableColumns.map { $0.identifier.rawValue } == ["state", "name"])
        #expect(table.tableColumns.map(\.width) == [92, 310])
    }

    @Test("column moves and resizes update memory before the shared debounce")
    func capturesUserPresentation() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let table = fixedTable([("key", 180), ("type", 90), ("value", 320)])
        let binding = TableLayoutBinding(
            tableView: table,
            surface: .objectDataKeys,
            store: fixture.store
        )
        defer { binding.invalidate() }

        table.moveColumn(2, toColumn: 0)
        table.tableColumns[1].width = 245
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: table
        )

        #expect(fixture.store.layout(for: .objectDataKeys) == TableLayout(columns: [
            .init(id: "value", width: 320),
            .init(id: "key", width: 245),
            .init(id: "type", width: 90),
        ]))
        #expect(fixture.defaults.data(forKey: TableLayoutStore.storageKey) == nil)
    }

    @Test("one store synchronizes two open tables without notification feedback")
    func synchronizesOpenTables() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let first = fixedTable([("field", 180), ("value", 360)])
        let second = fixedTable([("field", 180), ("value", 360)])
        let firstBinding = TableLayoutBinding(
            tableView: first, surface: .objectSummary, store: fixture.store
        )
        let secondBinding = TableLayoutBinding(
            tableView: second, surface: .objectSummary, store: fixture.store
        )
        defer {
            firstBinding.invalidate()
            secondBinding.invalidate()
        }

        first.moveColumn(1, toColumn: 0)
        first.tableColumns[0].width = 410
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: first
        )

        #expect(second.tableColumns.map { $0.identifier.rawValue } == ["value", "field"])
        #expect(second.tableColumns.map(\.width) == [410, 180])
        #expect(fixture.store.successfulPersistenceCount == 0)
        #expect(fixture.store.flushPendingSave())
        #expect(fixture.store.successfulPersistenceCount == 1)
    }

    @Test("adaptive final-column sizing stays local to each window")
    func adaptiveSizingDoesNotOverwriteSharedPreference() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let first = fixedTable([("field", 180), ("value", 360)])
        let second = fixedTable([("field", 180), ("value", 360)])
        let firstBinding = TableLayoutBinding(
            tableView: first, surface: .objectSummary, store: fixture.store
        )
        let secondBinding = TableLayoutBinding(
            tableView: second, surface: .objectSummary, store: fixture.store
        )
        defer {
            firstBinding.invalidate()
            secondBinding.invalidate()
        }

        firstBinding.fitLastColumn(to: 800)
        secondBinding.fitLastColumn(to: 500)
        #expect(first.tableColumns[1].width > second.tableColumns[1].width)
        #expect(fixture.store.layout(for: .objectSummary) == nil)

        first.tableColumns[0].width = 260
        NotificationCenter.default.post(
            name: NSTableView.columnDidResizeNotification,
            object: first
        )

        #expect(fixture.store.layout(for: .objectSummary) == TableLayout(columns: [
            .init(id: "field", width: 260),
            .init(id: "value", width: 360),
        ]))
        #expect(first.tableColumns[0].width == 260)
        #expect(second.tableColumns[0].width == 260)
        #expect(first.tableColumns[1].width > second.tableColumns[1].width)
    }

    @Test("fixed table schema mismatch resets only that saved surface")
    func resetsSchemaMismatch() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        #expect(fixture.store.set(
            TableLayout(columns: [.init(id: "old-column", width: 200)]),
            for: .portForwards
        ))
        let other = TableLayout(columns: [.init(id: "name", width: 180)])
        #expect(fixture.store.set(other, for: .deleteConfirmation))
        let table = fixedTable([("local", 100), ("target", 280)])

        let binding = TableLayoutBinding(
            tableView: table,
            surface: .portForwards,
            store: fixture.store
        )
        defer { binding.invalidate() }

        #expect(fixture.store.layout(for: .portForwards) == nil)
        #expect(fixture.store.layout(for: .deleteConfirmation) == other)
        #expect(table.tableColumns.map { $0.identifier.rawValue } == ["local", "target"])
    }

    @Test("removing a saved surface restores its code-defined defaults")
    func removingLayoutRestoresDefaults() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let table = fixedTable([("namespace", 150), ("name", 240)])
        let binding = TableLayoutBinding(
            tableView: table,
            surface: .deleteConfirmation,
            store: fixture.store
        )
        defer { binding.invalidate() }
        #expect(fixture.store.set(
            TableLayout(columns: [
                .init(id: "name", width: 310),
                .init(id: "namespace", width: 175),
            ]),
            for: .deleteConfirmation
        ))
        #expect(table.tableColumns.map { $0.identifier.rawValue }
            == ["name", "namespace"])

        #expect(fixture.store.removeLayout(for: .deleteConfirmation))

        #expect(table.tableColumns.map { $0.identifier.rawValue }
            == ["namespace", "name"])
        #expect(table.tableColumns.map(\.width) == [150, 240])
    }

    @Test("invalidated binding stops observing table and store changes")
    func invalidationStopsBinding() throws {
        let fixture = try tableLayoutBindingFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let table = fixedTable([("namespace", 150), ("name", 240)])
        let binding = TableLayoutBinding(
            tableView: table,
            surface: .deleteConfirmation,
            store: fixture.store
        )
        binding.invalidate()
        table.moveColumn(1, toColumn: 0)
        NotificationCenter.default.post(
            name: NSTableView.columnDidMoveNotification,
            object: table
        )
        #expect(fixture.store.layout(for: .deleteConfirmation) == nil)

        #expect(fixture.store.set(
            TableLayout(columns: [
                .init(id: "name", width: 300),
                .init(id: "namespace", width: 170),
            ]),
            for: .deleteConfirmation
        ))
        #expect(table.tableColumns.map { $0.identifier.rawValue } == ["name", "namespace"])
        #expect(table.tableColumns.map(\.width) == [240, 150])
    }
}
}

@MainActor
private func fixedTable(_ columns: [(String, CGFloat)]) -> NSTableView {
    let table = NSTableView()
    for (identifier, width) in columns {
        let column = NSTableColumn(identifier: .init(identifier))
        column.width = width
        column.minWidth = CGFloat(TableLayoutStore.minimumColumnWidth)
        column.maxWidth = CGFloat(TableLayoutStore.maximumColumnWidth)
        table.addTableColumn(column)
    }
    return table
}

@MainActor
private func tableLayoutBindingFixture() throws -> (
    defaults: UserDefaults,
    suite: String,
    store: TableLayoutStore
) {
    let suite = "kmgr-table-layout-binding-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite, TableLayoutStore(
        defaults: defaults,
        persistenceDelay: .seconds(60)
    ))
}
