import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Delete resources window", .serialized)
struct DeleteResourcesWindowControllerTests {
    @Test("confirmation rows identify each exact target hidden by the current filter")
    func hiddenTargetsAreMarkedInTheirRows() throws {
        let visible = deleteIdentity(name: "api", uid: "api-uid")
        let hidden = deleteIdentity(name: "worker", uid: "worker-uid")
        let controller = DeleteResourcesWindowController(
            session: OpenedClusterSession(
                sessionID: "session",
                contextName: "production",
                clusterName: "cluster-a",
                serverHostname: "api.example.invalid",
                defaultNamespace: "default"
            ),
            targets: [
                ResourceDeleteTarget(identity: visible),
                ResourceDeleteTarget(identity: hidden, hiddenByFilter: true),
            ],
            provider: NoopDeleteResourcesProvider()
        )
        let root = try #require(controller.window?.contentView)
        let table = try #require(deleteDescendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Resources awaiting deletion" })
        let columnIndex = try #require(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "visibility"
        })

        #expect(table.tableColumns[columnIndex].title == "Filter Status")
        let visibleCell = try #require(table.view(
            atColumn: columnIndex,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        let hiddenCell = try #require(table.view(
            atColumn: columnIndex,
            row: 1,
            makeIfNecessary: true
        ) as? NSTableCellView)

        #expect(visibleCell.textField?.stringValue == "Visible")
        #expect(hiddenCell.textField?.stringValue == "Hidden by filter")
        #expect(hiddenCell.textField?.textColor == .systemOrange)
        #expect(hiddenCell.textField?.toolTip?.contains("not visible") == true)
        #expect(hiddenCell.accessibilityValue() as? String == "Hidden by filter")
    }
}
}

private func deleteIdentity(name: String, uid: String) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "team-a",
        name: name,
        uid: ResourceUID(uid)
    )
}

@MainActor
private func deleteDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(deleteDescendants(of:))
}

private struct NoopDeleteResourcesProvider: ResourceOperationProviding {
    func deleteResources(
        targets: [ResourceDeleteTarget],
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func scaleResource(
        identity: ResourceIdentity,
        replicas: Int32,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func rolloutRestart(
        identity: ResourceIdentity,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateMetadata(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws {}
}
