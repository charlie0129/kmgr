import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Suite("Workspace frame bookmarks", .serialized)
struct WorkspaceFrameBookmarkStoreTests {
    @Test("activation keeps a context bookmark stable while changing its source")
    func activationKeepsStableBookmarkIdentity() throws {
        let storage = try makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }

        let store = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        let first = try store.activate(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-a"
        )
        let second = try store.activate(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-b"
        )
        let other = try store.activate(
            contextReference: "/configs/b.yaml#shared",
            sourceWindowID: "window-c"
        )

        #expect(first.id == second.id)
        #expect(second.sourceWindowID == "window-b")
        #expect(first.frameAutosaveName == second.frameAutosaveName)
        #expect(other.id != first.id)
        #expect(store.bookmarks.count == 2)

        // Explicitly closing window-b must not erase the context history. A
        // later window can still use the same exact-reference bookmark.
        let reloaded = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        #expect(reloaded.bookmark(for: "/configs/a.yaml#shared") == second)
        let ensured = try reloaded.ensure(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-d"
        )
        #expect(ensured == second)
    }

    @Test("frame bookmark persistence resets malformed documents")
    func malformedDocumentResets() throws {
        let storage = try makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }
        storage.defaults.set(
            Data("not-json".utf8),
            forKey: WorkspaceFrameBookmarkStore.storageKey
        )

        let store = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        #expect(store.bookmarks.isEmpty)
        #expect(store.loadIssue?.reason == .invalidData)
        #expect(storage.defaults.object(forKey: WorkspaceFrameBookmarkStore.storageKey) == nil)
    }

    @Test("record frame names are independent of exact context names")
    func recordFrameNamesAreIndependent() {
        let first = ClusterWindowRestorationRecord(
            id: "window-a",
            contextName: "shared",
            contextReference: "/configs/a.yaml#shared"
        )
        let second = ClusterWindowRestorationRecord(
            id: "window-b",
            contextName: "shared",
            contextReference: "/configs/a.yaml#shared"
        )
        #expect(first.frameAutosaveName != second.frameAutosaveName)
        #expect(first.frameAutosaveName.contains(first.id))
        #expect(second.frameAutosaveName.contains(second.id))
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "kmgr-frame-bookmarks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
