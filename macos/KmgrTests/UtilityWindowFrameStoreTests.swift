import Foundation
import KmgrTestSupport
import Testing
@testable import KmgrCore

@MainActor
@Suite("Utility window frame store", .serialized)
struct UtilityWindowFrameStoreTests {
    @Test("round trips one bounded frame for every utility kind")
    func roundTripAllKinds() throws {
        let suite = "kmgr-utility-frames-round-trip-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        for (index, kind) in UtilityWindowKind.allCases.enumerated() {
            #expect(store.set(frame(index), for: kind))
        }
        #expect(store.successfulPersistenceCount == 0)
        #expect(store.flushPendingSave())
        #expect(store.successfulPersistenceCount == 1)

        let data = try #require(
            defaults.data(forKey: UtilityWindowFrameStore.storageKey)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["apiVersion"] as? String == UtilityWindowFrameStore.apiVersion)
        #expect((object["frames"] as? [String: Any])?.count
            == UtilityWindowKind.allCases.count)

        let reloaded = UtilityWindowFrameStore(defaults: defaults)
        #expect(reloaded.loadIssue == nil)
        for (index, kind) in UtilityWindowKind.allCases.enumerated() {
            #expect(reloaded.frame(for: kind) == frame(index))
        }
    }

    @Test("rejects invalid frames without changing memory or storage")
    func rejectsInvalidFrames() throws {
        let suite = "kmgr-utility-frames-reject-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )

        let invalidFrames = [
            WorkspaceWindowFrame(x: .nan, y: 0, width: 400, height: 300),
            WorkspaceWindowFrame(x: 0, y: 0, width: 0, height: 300),
            WorkspaceWindowFrame(x: 0, y: 0, width: 70_000, height: 300),
            WorkspaceWindowFrame(x: 0, y: 0, width: 400, height: .infinity),
        ]
        for invalid in invalidFrames {
            #expect(!store.set(invalid, for: .settings))
        }
        #expect(store.frames.isEmpty)
        #expect(defaults.data(forKey: UtilityWindowFrameStore.storageKey) == nil)
    }

    @Test("resets malformed, unsupported, unknown, and oversized documents")
    func resetsInvalidDocuments() throws {
        let suite = "kmgr-utility-frames-invalid-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let validFrame: [String: Any] = [
            "x": 10, "y": 20, "width": 400, "height": 300,
        ]
        let cases: [(Data, UtilityWindowFrameStoreLoadIssue.Reason)] = [
            (Data("not-json".utf8), .invalidData),
            (try JSONSerialization.data(withJSONObject: [
                "apiVersion": "kmgr.utility-window-frames/v99",
                "frames": ["settings": validFrame],
            ]), .unsupportedVersion),
            (try JSONSerialization.data(withJSONObject: [
                "apiVersion": UtilityWindowFrameStore.apiVersion,
                "frames": ["unknown": validFrame],
            ]), .invalidValues),
            (try JSONSerialization.data(withJSONObject: [
                "apiVersion": UtilityWindowFrameStore.apiVersion,
                "frames": ["settings": [
                    "x": 10, "y": 20, "width": 0, "height": 300,
                ]],
            ]), .invalidValues),
            (try JSONSerialization.data(withJSONObject: [
                "apiVersion": UtilityWindowFrameStore.apiVersion,
                "frames": Dictionary(uniqueKeysWithValues: (0...UtilityWindowKind.allCases.count)
                    .map { ("settings-\($0)" as String, validFrame) }),
            ]), .invalidValues),
        ]

        for (data, reason) in cases {
            defaults.set(data, forKey: UtilityWindowFrameStore.storageKey)
            let store = UtilityWindowFrameStore(defaults: defaults)
            #expect(store.frames.isEmpty)
            #expect(store.loadIssue?.reason == reason)
            #expect(defaults.data(forKey: UtilityWindowFrameStore.storageKey) == nil)
        }
    }

    @Test("coalesces rapid updates and flushes the latest frame")
    func coalescesAndFlushes() async throws {
        let suite = "kmgr-utility-frames-debounce-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .milliseconds(20)
        )

        #expect(store.set(frame(0), for: .logs))
        #expect(store.set(frame(1), for: .logs))
        await store.waitForPendingSave()
        #expect(store.successfulPersistenceCount == 1)
        #expect(UtilityWindowFrameStore(defaults: defaults).frame(for: .logs)
            == frame(1))

        #expect(store.set(frame(2), for: .logs))
        #expect(store.flushPendingSave())
        try await Task.sleep(for: .milliseconds(40))
        #expect(store.successfulPersistenceCount == 2)
        #expect(UtilityWindowFrameStore(defaults: defaults).frame(for: .logs)
            == frame(2))
    }

    @Test("reset cancels a pending write and removes all saved frames")
    func resetCancelsPendingWrite() async throws {
        let suite = "kmgr-utility-frames-reset-\(UUID().uuidString)"
        let defaults = try #require(InMemoryUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .milliseconds(30)
        )

        #expect(store.set(frame(0), for: .terminal))
        store.reset()
        try await Task.sleep(for: .milliseconds(60))
        #expect(store.frames.isEmpty)
        #expect(store.successfulPersistenceCount == 0)
        #expect(defaults.data(forKey: UtilityWindowFrameStore.storageKey) == nil)
    }

    private func frame(_ index: Int) -> WorkspaceWindowFrame {
        WorkspaceWindowFrame(
            x: Double(100 + index * 37),
            y: Double(200 - index * 19),
            width: Double(400 + index * 11),
            height: Double(300 + index * 7)
        )
    }
}
