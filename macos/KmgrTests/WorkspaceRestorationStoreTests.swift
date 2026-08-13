import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func workspaceRestorationRoundTripsIndependentSameContextWindows() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    let first = ClusterWindowRestorationRecord(
        id: "window-a",
        state: ClusterWindowRestorationState(
            contextName: "production",
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceScope: .namespaces(["api", "workers"]),
            filter: "status == 'Ready'",
            sort: [SortDescriptorState(columnID: "restarts", ascending: false)],
            columns: [
                ColumnPresentationState(columnID: "name", width: 280),
                ColumnPresentationState(columnID: "restarts", width: 90, isVisible: false),
            ],
            isSidebarVisible: false,
            scrollAnchor: ScrollAnchor(
                uid: "deployment-uid", pixelOffsetFromTop: 7.5, priorRowIndex: 9_000
            )
        )
    )
    let second = ClusterWindowRestorationRecord(
        id: "window-b",
        state: ClusterWindowRestorationState(
            contextName: "production",
            gvr: GVR(group: "", version: "v1", resource: "pods"),
            namespaceScope: .namespace("api")
        )
    )

    let store = WorkspaceRestorationStore(defaults: storage.defaults)
    try store.replaceAll(with: [first, second])
    let reloaded = WorkspaceRestorationStore(defaults: storage.defaults)

    #expect(reloaded.windows == [first, second])
    #expect(reloaded.windows.map(\.state.contextName) == ["production", "production"])
    #expect(first.frameAutosaveName != second.frameAutosaveName)
    #expect(reloaded.loadIssue == nil)
}

@MainActor
@Test func workspaceRestorationUpsertAndExplicitCloseAreAtomic() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    let store = WorkspaceRestorationStore(defaults: storage.defaults)
    var record = ClusterWindowRestorationRecord(id: "window", contextName: "local")

    try store.upsert(record)
    record.state.filter = "name contains 'api'"
    try store.upsert(record)
    #expect(store.windows == [record])

    try store.remove(id: "window")
    #expect(store.windows.isEmpty)
    #expect(WorkspaceRestorationStore(defaults: storage.defaults).windows.isEmpty)
}

@MainActor
@Test func corruptUnsupportedAndInvalidRestorationFailClosed() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    storage.defaults.set(Data("not-json".utf8), forKey: WorkspaceRestorationStore.storageKey)
    var store = WorkspaceRestorationStore(defaults: storage.defaults)
    #expect(store.windows.isEmpty)
    #expect(store.loadIssue?.reason == .invalidData)

    storage.defaults.set(try JSONSerialization.data(withJSONObject: [
        "apiVersion": "kmgr.workspace-restoration/v99",
        "windows": [],
    ]), forKey: WorkspaceRestorationStore.storageKey)
    store = WorkspaceRestorationStore(defaults: storage.defaults)
    #expect(store.windows.isEmpty)
    #expect(store.loadIssue?.reason == .unsupportedVersion)

    let invalidState = ClusterWindowRestorationState(
        contextName: "local",
        columns: [ColumnPresentationState(columnID: "name", width: .infinity)]
    )
    #expect(throws: RestorationValidationError.self) {
        try store.replaceAll(with: [
            ClusterWindowRestorationRecord(id: "window", state: invalidState),
        ])
    }
}

@MainActor
@Test func restorationDocumentCannotContainRowsSecretsLogsOrTerminalData() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    let sensitiveSentinels = [
        "secret-plaintext-sentinel",
        "terminal-buffer-sentinel",
        "log-content-sentinel",
        "raw-row-json-sentinel",
    ]
    let store = WorkspaceRestorationStore(defaults: storage.defaults)
    try store.upsert(ClusterWindowRestorationRecord(
        id: "window",
        state: ClusterWindowRestorationState(
            contextName: "production",
            filter: "metadata.name == 'safe-name'"
        )
    ))

    let encoded = try #require(
        storage.defaults.data(forKey: WorkspaceRestorationStore.storageKey)
    )
    let json = String(decoding: encoded, as: UTF8.self)
    for sentinel in sensitiveSentinels {
        #expect(!json.contains(sentinel))
    }
    for forbiddenKey in ["rows", "secret", "terminal", "logs", "yamlUTF8"] {
        #expect(!json.contains("\"\(forbiddenKey)\""))
    }
}

@Test func namespaceScopeBridgesNavigationWithoutLosingMultiScope() {
    let values: [NamespaceSelection] = [
        NamespaceSelection(),
        .namespace("default"),
        NamespaceSelection(allNamespaces: false, namespaces: ["one", "two"]),
    ]
    for value in values {
        #expect(NamespaceScope(value).namespaceSelection == value)
    }
}

private func restorationDefaults() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "kmgr-restoration-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}
