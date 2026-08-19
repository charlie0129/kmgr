import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@MainActor
@Suite("Column configuration coordinator", .serialized)
struct ColumnConfigurationCoordinatorTests {
    @Test("serialized exact-GVR saves merge instead of losing a sibling view")
    func serializedSavesMergeViews() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = ColumnConfigurationCoordinator(path: fixture.path)
        let pods = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
        let nodes = ColumnResourceMatch(group: "", version: "v1", resource: "nodes")
        let podColumns = [definition(id: "pod-name", width: 180)]
        let nodeColumns = [definition(id: "node-name", width: 220)]

        async let podSave = coordinator.save(podColumns, matching: pods)
        async let nodeSave = coordinator.save(nodeColumns, matching: nodes)
        _ = try await (podSave, nodeSave)

        let loaded = try ColumnConfigurationFileStore(path: fixture.path).load()
        #expect(loaded.views.first { $0.match == pods }?.columns == podColumns)
        #expect(loaded.views.first { $0.match == nodes }?.columns == nodeColumns)
    }

    @Test("external edits fail closed without being overwritten")
    func externalEditConflict() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let match = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
        let original = [definition(id: "name", width: 140)]
        try ColumnConfigurationFileStore(path: fixture.path).save(
            document(match: match, definitions: original)
        )
        let coordinator = ColumnConfigurationCoordinator(path: fixture.path)
        _ = try await coordinator.load()

        let external = [definition(id: "external", width: 260)]
        try ColumnConfigurationFileStore(path: fixture.path).save(
            document(match: match, definitions: external)
        )
        do {
            _ = try await coordinator.save(
                [definition(id: "local", width: 300)],
                matching: match
            )
            Issue.record("Expected an external-file conflict")
        } catch {
            #expect(error.localizedDescription.contains("changed outside this application"))
        }
        do {
            _ = try await coordinator.save(
                [definition(id: "second-local", width: 320)],
                matching: match
            )
            Issue.record("Expected the conflict to remain blocked until reload")
        } catch {
            #expect(error.localizedDescription.contains("changed outside this application"))
        }
        #expect(try ColumnConfigurationFileStore(path: fixture.path).load()
            .views.first?.columns == external)

        coordinator.scheduleLayoutSave(
            [definition(id: "stale-layout", width: 330)],
            matching: match
        )
        _ = try await coordinator.load(reload: true)
        await coordinator.flushPendingLayoutSaves()
        #expect(try ColumnConfigurationFileStore(path: fixture.path).load()
            .views.first?.columns == external)
        let reloadedLocal = [definition(id: "reloaded-local", width: 340)]
        _ = try await coordinator.save(reloadedLocal, matching: match)
        #expect(try ColumnConfigurationFileStore(path: fixture.path).load()
            .views.first?.columns == reloadedLocal)
    }

    @Test("debounced layouts remain independent by GVR and flush notifies observers")
    func debouncedLayoutFlush() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = ColumnConfigurationCoordinator(
            path: fixture.path,
            layoutPersistenceDelay: .seconds(30)
        )
        let pods = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
        let nodes = ColumnResourceMatch(group: "", version: "v1", resource: "nodes")
        let latestPods = [definition(id: "status", width: 333)]
        let nodeColumns = [definition(id: "node", width: 444)]
        var observed: [(ColumnResourceMatch, [ColumnDefinition])] = []
        let observer = coordinator.observe { observed.append(($0, $1)) }
        defer { coordinator.removeObserver(observer) }

        coordinator.scheduleLayoutSave(
            [definition(id: "stale", width: 100)],
            matching: pods
        )
        coordinator.scheduleLayoutSave(latestPods, matching: pods)
        coordinator.scheduleLayoutSave(nodeColumns, matching: nodes)
        await coordinator.flushPendingLayoutSaves()

        let loaded = try ColumnConfigurationFileStore(path: fixture.path).load()
        #expect(loaded.views.first { $0.match == pods }?.columns == latestPods)
        #expect(loaded.views.first { $0.match == nodes }?.columns == nodeColumns)
        #expect(observed.count == 2)
        #expect(Set(observed.map(\.0)) == [pods, nodes])
    }

    @Test("layout saves preserve newer definitions and cancel older snapshots")
    func layoutsRebaseOntoNewestDefinitions() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = ColumnConfigurationCoordinator(
            path: fixture.path,
            layoutPersistenceDelay: .seconds(30)
        )
        let match = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
        let name = definition(id: "name", width: 140)
        let status = definition(id: "status", width: 160)
        _ = try await coordinator.save([name, status], matching: match)

        // This older table snapshot must be canceled by the direct definition
        // edit that follows it.
        coordinator.scheduleLayoutSave(
            [definition(id: "status", width: 300), name],
            matching: match
        )
        let custom = definition(id: "custom", width: 180)
        _ = try await coordinator.save([name, custom, status], matching: match)
        await coordinator.flushPendingLayoutSaves()
        #expect(try ColumnConfigurationFileStore(path: fixture.path).load()
            .views.first?.columns == [name, custom, status])

        // A later table move/resize wins for the IDs it presents, but it does
        // not resurrect or overwrite the newer custom definition.
        coordinator.scheduleLayoutSave(
            [definition(id: "status", width: 333), name],
            matching: match
        )
        await coordinator.flushPendingLayoutSaves()
        let persisted = try #require(
            ColumnConfigurationFileStore(path: fixture.path).load().views.first?.columns
        )
        #expect(persisted.map(\.id) == ["status", "custom", "name"])
        #expect(persisted[0].width == 333)
        #expect(persisted[1] == custom)
        #expect(persisted[2].width == name.width)
    }

    private func definition(id: String, width: Double) -> ColumnDefinition {
        ColumnDefinition(
            id: id,
            title: id,
            source: .builtin,
            value: "name",
            type: .string,
            width: width
        )
    }

    private func document(
        match: ColumnResourceMatch,
        definitions: [ColumnDefinition]
    ) -> ColumnsConfigurationDocument {
        ColumnsConfigurationDocument(views: [ResourceColumnConfiguration(
            match: match,
            columns: definitions
        )])
    }
}

private struct CoordinatorFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-column-coordinator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    var path: String { directory.appendingPathComponent("columns.yaml").path }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
