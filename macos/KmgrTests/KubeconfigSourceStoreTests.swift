import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func kubeconfigSourcePathsPersistInUserOrderWithoutFileContents() throws {
    let (defaults, suite) = try kubeconfigSourceDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = KubeconfigSourceStore(defaults: defaults)

    #expect(store.add(paths: ["/tmp/team/../team.yaml", "/tmp/staging.yaml"]))
    #expect(!store.add(paths: ["/tmp/team.yaml"]))
    #expect(store.paths == ["/tmp/team.yaml", "/tmp/staging.yaml"])

    let reloaded = KubeconfigSourceStore(defaults: defaults)
    #expect(reloaded.paths == store.paths)
    #expect(reloaded.loadIssue == nil)
    let data = try #require(defaults.data(forKey: KubeconfigSourceStore.storageKey))
    let document = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(document["apiVersion"] as? String == KubeconfigSourceStore.apiVersion)
    #expect(document["paths"] as? [String] == ["/tmp/team.yaml", "/tmp/staging.yaml"])
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(!encoded.lowercased().contains("token"))
    #expect(!encoded.lowercased().contains("credential"))
}

@MainActor
@Test func removingKubeconfigSourceForgetsPathWithoutDeletingFile() throws {
    let (defaults, suite) = try kubeconfigSourceDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-kubeconfig-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config")
    try Data("apiVersion: v1\nkind: Config\n".utf8).write(to: file)

    let store = KubeconfigSourceStore(defaults: defaults)
    var observed: [[String]] = []
    let observer = store.observe { observed.append($0) }
    defer { store.removeObserver(observer) }

    #expect(store.add(paths: [file.path]))
    #expect(store.remove(paths: [file.path]))
    #expect(store.paths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(observed == [[], [file.path], []])
}

@MainActor
@Test func invalidKubeconfigSourceDocumentsResetToNoCustomFiles() throws {
    let (defaults, suite) = try kubeconfigSourceDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(Data("not-json".utf8), forKey: KubeconfigSourceStore.storageKey)
    var store = KubeconfigSourceStore(defaults: defaults)
    #expect(store.paths.isEmpty)
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.object(forKey: KubeconfigSourceStore.storageKey) == nil)

    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kmgr.kubeconfig-sources/v99",
            "paths": ["/tmp/config"],
        ]),
        forKey: KubeconfigSourceStore.storageKey
    )
    store = KubeconfigSourceStore(defaults: defaults)
    #expect(store.paths.isEmpty)
    #expect(store.loadIssue?.reason == .unsupportedVersion)
    #expect(defaults.object(forKey: KubeconfigSourceStore.storageKey) == nil)
}

@MainActor
@Test func kubeconfigSourceStoreRejectsRelativeDuplicateAndOversizedSets() throws {
    let (defaults, suite) = try kubeconfigSourceDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = KubeconfigSourceStore(defaults: defaults)

    #expect(!store.add(paths: ["/tmp/valid", "relative/config"]))
    #expect(store.paths.isEmpty)
    #expect(!store.add(paths: (0...KubeconfigSourceStore.maximumSources).map {
        "/tmp/config-\($0)"
    }))
    #expect(store.paths.isEmpty)
}

private func kubeconfigSourceDefaults() throws -> (defaults: UserDefaults, suite: String) {
    let suite = "kmgr-kubeconfig-source-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}
