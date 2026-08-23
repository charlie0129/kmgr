import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource mutation window", .serialized)
struct ResourceMutationWindowControllerTests {
    @Test("rollout restart presents the detailed confirmation without a preliminary sheet")
    func rolloutRestartUsesOneConfirmation() async throws {
        let controller = mutationController(
            mutation: .rolloutRestart,
            operationProvider: CapturingMutationOperationProvider()
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.makeKeyAndOrderFront(nil)
        controller.beginSheet(for: parent)
        defer {
            controller.window?.orderOut(nil)
            parent.orderOut(nil)
        }

        let confirmation = try #require(parent.attachedSheet)
        #expect(confirmation !== controller.window)
        #expect(controller.window?.sheetParent == nil)
        let confirmationRoot = try #require(confirmation.contentView)
        let text = mutationDescendants(of: confirmationRoot)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: "\n")
        #expect(text.contains("Restart api?"))
        #expect(text.contains("Cluster: cluster-a"))
        #expect(text.contains("Context: production"))
        #expect(text.contains("Target: apps/v1/deployments · team-a/api"))
        let cancel = try #require(mutationDescendants(of: confirmationRoot)
            .compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        cancel.performClick(nil)
        await Task.yield()
        #expect(parent.attachedSheet == nil)
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("scale sheet keeps the replica form and footer compact")
    func scaleSheetIsCompact() throws {
        let controller = mutationController(
            mutation: .scale,
            operationProvider: CapturingMutationOperationProvider()
        )
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let views = mutationDescendants(of: root)
        let replicas = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Replica count" })
        let cancel = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Cancel" })
        let replicaFrame = root.convert(replicas.bounds, from: replicas)
        let cancelFrame = root.convert(cancel.bounds, from: cancel)
        let formToFooterGap = replicaFrame.minY - cancelFrame.maxY

        #expect(root.bounds.height <= 245)
        #expect(formToFooterGap >= 0)
        #expect(formToFooterGap <= 70)
        #expect(!replicaFrame.intersects(cancelFrame))
    }
}
}

@MainActor
private func mutationController(
    mutation: ResourceMutationWindowController.Mutation,
    operationProvider: any ResourceOperationProviding
) -> ResourceMutationWindowController {
    let identity = ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "team-a",
        name: "api",
        uid: ResourceUID("deployment-uid")
    )
    return ResourceMutationWindowController(
        session: OpenedClusterSession(
            sessionID: "session",
            contextName: "production",
            clusterName: "cluster-a",
            serverHostname: "api.example.invalid",
            defaultNamespace: "default"
        ),
        identity: identity,
        mutation: mutation,
        confirmationPreferences: ConfirmationPreferences(),
        detailProvider: LoadedMutationDetailProvider(detail: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1"
        )),
        operationProvider: operationProvider
    )
}

@MainActor
private func mutationDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(mutationDescendants(of:))
}

private struct LoadedMutationDetailProvider: ObjectDetailProviding {
    var detail: ObjectDetail

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}

private actor CapturingMutationOperationProvider: ResourceOperationProviding {
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
