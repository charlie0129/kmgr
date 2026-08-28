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
        let firstFrame = WorkspaceWindowFrame(
            x: -1_760, y: 140, width: 840, height: 620
        )
        let secondFrame = WorkspaceWindowFrame(
            x: 120, y: 220, width: 980, height: 700
        )
        let first = try store.activate(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-a",
            frame: firstFrame
        )
        let second = try store.activate(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-b",
            frame: secondFrame
        )
        let other = try store.activate(
            contextReference: "/configs/b.yaml#shared",
            sourceWindowID: "window-c"
        )

        #expect(first.id == second.id)
        #expect(second.sourceWindowID == "window-b")
        #expect(second.frame == secondFrame)
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

    @Test("passive frame updates cannot replace the active source")
    func passiveFrameUpdatesDoNotReplaceActiveSource() throws {
        let storage = try makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }

        let store = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        let activeFrame = WorkspaceWindowFrame(
            x: -1_920, y: 80, width: 900, height: 600
        )
        let passiveFrame = WorkspaceWindowFrame(
            x: 40, y: 90, width: 900, height: 600
        )
        _ = try store.activate(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-a",
            frame: activeFrame
        )

        #expect(try store.updateFrame(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-b",
            frame: passiveFrame
        ) == false)
        #expect(store.bookmark(for: "/configs/a.yaml#shared")?.frame == activeFrame)

        #expect(try store.updateFrame(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "window-a",
            frame: passiveFrame
        ) == true)
        #expect(store.bookmark(for: "/configs/a.yaml#shared")?.frame == passiveFrame)
    }

    @Test("ensure fills a missing frame without changing the source")
    func ensureFillsMissingFrameWithoutChangingSource() throws {
        let storage = try makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }

        let store = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        _ = try store.activate(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "historical-window"
        )
        let frame = WorkspaceWindowFrame(
            x: -1_920, y: 120, width: 840, height: 620
        )
        let filled = try store.ensure(
            contextReference: "/configs/a.yaml#shared",
            sourceWindowID: "new-window",
            frame: frame
        )

        #expect(filled.sourceWindowID == "historical-window")
        #expect(filled.frame == frame)
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

    @Test("bookmarks round-trip signed global coordinates")
    func bookmarksRoundTripSignedGlobalCoordinates() throws {
        let storage = try makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.suite) }

        let frame = WorkspaceWindowFrame(
            x: -1_920, y: -120, width: 1_024, height: 768
        )
        let store = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        _ = try store.activate(
            contextReference: "/configs/a.yaml#left",
            sourceWindowID: "window-left",
            frame: frame
        )

        let reloaded = WorkspaceFrameBookmarkStore(defaults: storage.defaults)
        #expect(reloaded.bookmark(for: "/configs/a.yaml#left")?.frame == frame)
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "kmgr-frame-bookmarks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
