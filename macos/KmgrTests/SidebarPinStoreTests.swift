import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func sidebarPinStoreStartsWithExactlyTheBuiltInPins() throws {
    let (defaults, suite) = try sidebarPinDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SidebarPinStore(defaults: defaults)
    #expect(store.pins == DefaultSidebarPins.values)
    #expect(store.loadIssue == nil)
}

@MainActor
@Test func sidebarPinsRoundTripAsOrderedGVRs() throws {
    let (defaults, suite) = try sidebarPinDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SidebarPinStore(defaults: defaults)
    let cronJobs = SidebarPin(group: "batch", version: "v1", resource: "cronjobs")
    let pods = try #require(DefaultSidebarPins.values.first)

    #expect(store.pin(cronJobs))
    #expect(store.move(pinID: cronJobs.id, beforePinID: pods.id))
    #expect(store.unpin(id: "apps/v1/daemonsets"))

    let reloaded = SidebarPinStore(defaults: defaults)
    #expect(reloaded.pins.first == cronJobs)
    #expect(!reloaded.contains(id: "apps/v1/daemonsets"))
    #expect(reloaded.pins.allSatisfy { !$0.version.isEmpty && !$0.resource.isEmpty })

    let data = try #require(defaults.data(forKey: SidebarPinStore.storageKey))
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(encoded.contains("\"group\":\"batch\""))
    #expect(encoded.contains("\"version\":\"v1\""))
    #expect(encoded.contains("\"resource\":\"cronjobs\""))
    #expect(!encoded.lowercased().contains("displayname"))
    #expect(!encoded.lowercased().contains("kind"))
}

@MainActor
@Test func emptySidebarPinSelectionAndMovesPersist() throws {
    let (defaults, suite) = try sidebarPinDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SidebarPinStore(defaults: defaults)

    for pin in DefaultSidebarPins.values {
        #expect(store.unpin(id: pin.id))
    }
    #expect(store.pins.isEmpty)
    #expect(SidebarPinStore(defaults: defaults).pins.isEmpty)

    let first = SidebarPin(group: "example.io", version: "v1", resource: "widgets")
    let second = SidebarPin(group: "example.io", version: "v1beta1", resource: "gadgets")
    #expect(store.pin(first))
    #expect(store.pin(second))
    #expect(store.move(pinID: second.id, beforePinID: first.id))
    #expect(store.pins == [second, first])
    #expect(!store.move(pinID: second.id, beforePinID: second.id))
}

@MainActor
@Test func invalidSidebarPinDocumentsFallBackExplicitly() throws {
    let (defaults, suite) = try sidebarPinDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(Data("not-json".utf8), forKey: SidebarPinStore.storageKey)
    var store = SidebarPinStore(defaults: defaults)
    #expect(store.pins == DefaultSidebarPins.values)
    #expect(store.loadIssue?.reason == .invalidData)

    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kmgr.sidebar-pins/v99",
            "pins": [],
        ]),
        forKey: SidebarPinStore.storageKey
    )
    store = SidebarPinStore(defaults: defaults)
    #expect(store.pins == DefaultSidebarPins.values)
    #expect(store.loadIssue?.reason == .unsupportedVersion)
}

private func sidebarPinDefaults() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "kmgr-sidebar-pin-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}
