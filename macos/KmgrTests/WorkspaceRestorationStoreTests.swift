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
    try store.upsert(first)
    try store.upsert(second)
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

@Test func restorationWithoutOpaqueContextReferenceIsRejected() throws {
    let legacyJSON = Data("""
    {
      "version": 1,
      "contextName": "production",
      "namespaceScope": {"all": {}},
      "filter": "",
      "sort": [],
      "columns": [],
      "isSidebarVisible": true
    }
    """.utf8)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ClusterWindowRestorationState.self, from: legacyJSON)
    }
}

@Test func restorationRoundTripsOpaqueContextReferenceSeparatelyFromName() throws {
    let state = ClusterWindowRestorationState(
        contextName: "default",
        contextReference: "context-source-stable-id",
        gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
        labelSelector: "app in (api,worker)",
        fieldSelector: "metadata.name=frontend"
    )
    let decoded = try JSONDecoder().decode(
        ClusterWindowRestorationState.self,
        from: JSONEncoder().encode(state)
    )

    #expect(decoded.contextName == "default")
    #expect(decoded.contextReference == "context-source-stable-id")
    #expect(decoded.labelSelector == "app in (api,worker)")
    #expect(decoded.fieldSelector == "metadata.name=frontend")
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
        "bookmarks": [],
    ]), forKey: WorkspaceRestorationStore.storageKey)
    store = WorkspaceRestorationStore(defaults: storage.defaults)
    #expect(store.windows.isEmpty)
    #expect(store.loadIssue?.reason == .unsupportedVersion)

    let invalidState = ClusterWindowRestorationState(
        contextName: "local",
        filter: String(repeating: "x", count: ClusterWindowRestorationState.maximumQueryBytes + 1)
    )
    #expect(throws: RestorationValidationError.self) {
        try store.upsert(ClusterWindowRestorationRecord(id: "window", state: invalidState))
    }

    let invalidSelector = ClusterWindowRestorationState(
        contextName: "local",
        labelSelector: String(
            repeating: "x",
            count: ClusterWindowRestorationState.maximumQueryBytes + 1
        )
    )
    #expect(invalidSelector.validationIssues().contains { $0.path == "labelSelector" })

    let invalidSort = ClusterWindowRestorationState(
        contextName: "local",
        sort: [
            SortDescriptorState(columnID: "name", ascending: true),
            SortDescriptorState(columnID: "name", ascending: false),
        ]
    )
    #expect(invalidSort.validationIssues().contains { $0.path == "sort" })
}

@MainActor
@Test func contextBookmarksUseExactOpaqueReferenceAndMostRecentActivation() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    let store = WorkspaceRestorationStore(defaults: storage.defaults)
    let referenceA = "/configs/a.yaml#shared"
    let referenceB = "/configs/b.yaml#shared"
    let firstA = ClusterWindowRestorationRecord(
        id: "window-a1",
        state: ClusterWindowRestorationState(
            contextName: "shared", contextReference: referenceA,
            filter: "name:first"
        )
    )
    let secondA = ClusterWindowRestorationRecord(
        id: "window-a2",
        state: ClusterWindowRestorationState(
            contextName: "shared", contextReference: referenceA,
            filter: "name:second"
        )
    )
    let onlyB = ClusterWindowRestorationRecord(
        id: "window-b",
        state: ClusterWindowRestorationState(
            contextName: "shared", contextReference: referenceB,
            filter: "name:other-file"
        )
    )

    let firstBookmark = try store.activate(firstA)
    try store.upsert(secondA)
    #expect(store.bookmark(for: referenceA)?.state.filter == "name:first")
    let secondBookmark = try store.activate(secondA)
    #expect(secondBookmark.id == firstBookmark.id)
    #expect(store.bookmark(for: referenceA)?.state.filter == "name:second")
    var updatedSecond = secondA
    updatedSecond.state.filter = "name:active-update"
    try store.upsert(updatedSecond)
    #expect(store.bookmark(for: referenceA)?.state.filter == "name:active-update")
    _ = try store.activate(onlyB)
    #expect(store.bookmark(for: referenceB)?.state.filter == "name:other-file")
    #expect(store.bookmarks.count == 2)
    #expect(store.bookmark(for: referenceA)?.id
        != store.bookmark(for: referenceB)?.id)

    var backgroundFirst = firstA
    backgroundFirst.state.filter = "background-update"
    try store.upsert(backgroundFirst)
    #expect(store.bookmark(for: referenceA)?.state.filter == "name:active-update")

    try store.remove(id: secondA.id)
    #expect(store.record(for: secondA.id) == nil)
    #expect(store.bookmark(for: referenceA)?.sourceWindowID == secondA.id)
    #expect(store.bookmark(for: referenceA)?.state.filter == "name:active-update")

    let reloaded = WorkspaceRestorationStore(defaults: storage.defaults)
    #expect(reloaded.bookmark(for: referenceA) == store.bookmark(for: referenceA))
    #expect(reloaded.bookmark(for: referenceB) == store.bookmark(for: referenceB))
}

@MainActor
@Test func disablingOpenWindowRestorationKeepsContextBookmarks() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    let store = WorkspaceRestorationStore(defaults: storage.defaults)
    let record = ClusterWindowRestorationRecord(id: "window", contextName: "local")
    _ = try store.activate(record)

    try store.removeAllOpenWindows()

    #expect(store.windows.isEmpty)
    #expect(store.bookmark(for: record.state.contextReference)?.state == record.state)
    #expect(WorkspaceRestorationStore(defaults: storage.defaults).bookmarks == store.bookmarks)
}

@MainActor
@Test func newSameContextWindowsInheritLatestResourceNamespaceAndFilter() throws {
    let storage = try restorationDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
    let store = WorkspaceRestorationStore(defaults: storage.defaults)
    var active = ClusterWindowRestorationRecord(
        id: "active-window",
        state: ClusterWindowRestorationState(
            contextName: "production",
            contextReference: "/configs/production.yaml#production",
            gvr: GVR(group: "", version: "v1", resource: "pods"),
            namespaceScope: .namespace("team-a"),
            filter: "status:Running"
        )
    )
    _ = try store.activate(active)

    active.state.gvr = GVR(group: "apps", version: "v1", resource: "deployments")
    active.state.namespaceScope = .namespace("team-b")
    active.state.filter = "name:api"
    try store.upsert(active)

    let inherited = try #require(store.bookmark(
        for: active.state.contextReference
    )?.state)
    #expect(inherited.gvr == active.state.gvr)
    #expect(inherited.namespaceScope == .namespace("team-b"))
    #expect(inherited.filter == "name:api")
    #expect(WorkspaceRestorationStore(defaults: storage.defaults).bookmark(
        for: active.state.contextReference
    )?.state == inherited)
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
    _ = try store.activate(ClusterWindowRestorationRecord(
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
