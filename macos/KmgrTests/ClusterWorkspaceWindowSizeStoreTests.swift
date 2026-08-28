import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func clusterWorkspaceWindowSizeIsGlobalAndSurvivesStoreInstances() throws {
    let suite = "kmgr-workspace-size-tests-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ClusterWorkspaceWindowSizeStore(defaults: defaults)
    let firstClusterSize = ClusterWorkspaceWindowSize(width: 1_120, height: 740)
    let otherClusterSize = ClusterWorkspaceWindowSize(width: 1_360, height: 880)

    #expect(store.lastSize == nil)
    #expect(store.save(firstClusterSize))
    #expect(store.save(otherClusterSize))
    #expect(store.lastSize == otherClusterSize)
    #expect(ClusterWorkspaceWindowSizeStore(defaults: defaults).lastSize == otherClusterSize)
}

@MainActor
@Test func invalidClusterWorkspaceWindowSizeConfigurationResets() throws {
    let suite = "kmgr-workspace-size-invalid-tests-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not-json".utf8), forKey: ClusterWorkspaceWindowSizeStore.storageKey)

    let store = ClusterWorkspaceWindowSizeStore(defaults: defaults)

    #expect(store.lastSize == nil)
    #expect(defaults.object(forKey: ClusterWorkspaceWindowSizeStore.storageKey) == nil)
    #expect(!store.save(.init(width: .infinity, height: 700)))
    #expect(store.lastSize == nil)
}
