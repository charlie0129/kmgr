import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func fixedTableLayoutsRoundTripInStableOrderAndStaySurfaceScoped() throws {
    let (defaults, suite) = try tableLayoutDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TableLayoutStore(defaults: defaults, persistenceDelay: .seconds(60))
    let contexts = TableLayout(columns: [
        .init(id: "context", width: 310),
        .init(id: "cluster", width: 180),
        .init(id: "source", width: 240),
    ])
    let containers = TableLayout(columns: [
        .init(id: "ready", width: 72),
        .init(id: "name", width: 260),
    ])

    #expect(store.set(contexts, for: .clusterContexts))
    #expect(store.set(containers, for: .podContainers))
    #expect(defaults.data(forKey: TableLayoutStore.storageKey) == nil)
    #expect(store.flushPendingSave())

    let reloaded = TableLayoutStore(defaults: defaults)
    #expect(reloaded.layout(for: .clusterContexts) == contexts)
    #expect(reloaded.layout(for: .podContainers) == containers)
    #expect(reloaded.layout(for: .objectSummary) == nil)
    #expect(reloaded.loadIssue == nil)

    let data = try #require(defaults.data(forKey: TableLayoutStore.storageKey))
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(encoded.contains(TableSurfaceID.clusterContexts.rawValue))
    #expect(encoded.contains("\"id\":\"context\""))
    #expect(!encoded.lowercased().contains("row"))
    #expect(!encoded.lowercased().contains("secret"))
}

@MainActor
@Test func fixedTableLayoutObserversSynchronizeMemoryBeforeDebouncedPersistence() throws {
    let (defaults, suite) = try tableLayoutDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TableLayoutStore(defaults: defaults, persistenceDelay: .seconds(60))
    var observed: [TableLayout?] = []
    let observer = store.observe(.objectDataKeys) { observed.append($0) }
    defer { store.removeObserver(observer) }
    let first = TableLayout(columns: [.init(id: "key", width: 220)])
    let second = TableLayout(columns: [.init(id: "key", width: 280)])

    #expect(store.set(first, for: .objectDataKeys))
    #expect(store.set(second, for: .objectDataKeys))
    #expect(observed == [nil, first, second])
    #expect(store.successfulPersistenceCount == 0)
    #expect(defaults.data(forKey: TableLayoutStore.storageKey) == nil)
    #expect(store.flushPendingSave())
    #expect(store.successfulPersistenceCount == 1)
}

@MainActor
@Test func fixedTableLayoutDebounceWritesOnlyTheLatestDocument() async throws {
    let (defaults, suite) = try tableLayoutDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TableLayoutStore(defaults: defaults, persistenceDelay: .milliseconds(20))

    for width in stride(from: 100.0, through: 220.0, by: 10.0) {
        #expect(store.set(
            TableLayout(columns: [.init(id: "name", width: width)]),
            for: .portForwards
        ))
    }
    await store.waitForPendingSave()

    #expect(store.successfulPersistenceCount == 1)
    #expect(TableLayoutStore(defaults: defaults).layout(for: .portForwards)
        == TableLayout(columns: [.init(id: "name", width: 220)]))
}

@MainActor
@Test func invalidFixedTableLayoutDocumentsResetTheirStoredState() throws {
    let (defaults, suite) = try tableLayoutDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(Data("not-json".utf8), forKey: TableLayoutStore.storageKey)
    var store = TableLayoutStore(defaults: defaults)
    #expect(store.layouts.isEmpty)
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.object(forKey: TableLayoutStore.storageKey) == nil)

    defaults.set(try JSONSerialization.data(withJSONObject: [
        "apiVersion": "kmgr.table-layouts/v99",
        "layouts": [:],
    ]), forKey: TableLayoutStore.storageKey)
    store = TableLayoutStore(defaults: defaults)
    #expect(store.layouts.isEmpty)
    #expect(store.loadIssue?.reason == .unsupportedVersion)
    #expect(defaults.object(forKey: TableLayoutStore.storageKey) == nil)

    defaults.set(try JSONSerialization.data(withJSONObject: [
        "apiVersion": TableLayoutStore.apiVersion,
        "layouts": [
            TableSurfaceID.objectSummary.rawValue: [
                "columns": [
                    ["id": "field", "width": 200],
                    ["id": "field", "width": 300],
                ],
            ],
        ],
    ]), forKey: TableLayoutStore.storageKey)
    store = TableLayoutStore(defaults: defaults)
    #expect(store.layouts.isEmpty)
    #expect(store.loadIssue?.reason == .invalidValues)
    #expect(defaults.object(forKey: TableLayoutStore.storageKey) == nil)

    defaults.set(try JSONSerialization.data(withJSONObject: [
        "apiVersion": TableLayoutStore.apiVersion,
        "layouts": [:],
        "legacy": true,
    ]), forKey: TableLayoutStore.storageKey)
    store = TableLayoutStore(defaults: defaults)
    #expect(store.layouts.isEmpty)
    #expect(store.loadIssue?.reason == .invalidValues)
    #expect(defaults.object(forKey: TableLayoutStore.storageKey) == nil)
}

@MainActor
@Test func fixedTableLayoutValidationBoundsColumnsIdentifiersAndWidths() throws {
    let (defaults, suite) = try tableLayoutDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TableLayoutStore(defaults: defaults, persistenceDelay: .seconds(60))
    let valid = TableLayout(columns: [
        .init(id: "min", width: TableLayoutStore.minimumColumnWidth),
        .init(id: "max", width: TableLayoutStore.maximumColumnWidth),
    ])
    #expect(store.set(valid, for: .deleteConfirmation))

    let invalid: [TableLayout] = [
        TableLayout(columns: []),
        TableLayout(columns: [.init(id: "", width: 100)]),
        TableLayout(columns: [.init(id: " padded ", width: 100)]),
        TableLayout(columns: [.init(id: "line\nbreak", width: 100)]),
        TableLayout(columns: [.init(id: String(repeating: "x", count: 129), width: 100)]),
        TableLayout(columns: [.init(id: "narrow", width: 23.9)]),
        TableLayout(columns: [.init(id: "wide", width: 4_096.1)]),
        TableLayout(columns: [.init(id: "nan", width: .nan)]),
        TableLayout(columns: Array(repeating: .init(id: "duplicate", width: 100), count: 65)),
    ]
    for layout in invalid {
        #expect(!store.set(layout, for: .deleteConfirmation))
        #expect(store.layout(for: .deleteConfirmation) == valid)
    }
}

@MainActor
@Test func removingAndResettingFixedTableLayoutsNotifyAndPersistDefaults() throws {
    let (defaults, suite) = try tableLayoutDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TableLayoutStore(defaults: defaults, persistenceDelay: .seconds(60))
    let layout = TableLayout(columns: [.init(id: "name", width: 200)])
    var observed: [TableLayout?] = []
    _ = store.observe(.columnsManager) { observed.append($0) }

    #expect(store.set(layout, for: .columnsManager))
    #expect(store.removeLayout(for: .columnsManager))
    #expect(store.set(layout, for: .columnsManager))
    #expect(store.flushPendingSave())
    store.reset()

    #expect(observed == [nil, layout, nil, layout, nil])
    #expect(store.layouts.isEmpty)
    #expect(defaults.object(forKey: TableLayoutStore.storageKey) == nil)
}

private func tableLayoutDefaults() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "kmgr-table-layout-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}
