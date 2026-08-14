import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Resource mutation window", .serialized)
struct ResourceMutationWindowControllerTests {
    @Test("metadata inputs are accessible scrollable multiline editors")
    func metadataEditorsAreMultilineAndNamed() throws {
        let controller = mutationController(
            mutation: .metadata,
            operationProvider: CapturingMutationOperationProvider()
        )
        #expect(controller.window?.title ==
            "cluster-a — production — Edit Labels / Annotations")
        let root = try #require(controller.window?.contentView)
        let views = mutationDescendants(of: root)
        let identityText = views.compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: "\n")
        #expect(identityText.contains("Cluster: cluster-a"))
        #expect(identityText.contains("Context: production"))
        #expect(identityText.contains("Namespace: team-a"))
        #expect(identityText.contains("Target: apps/v1/deployments · team-a/api"))
        #expect(identityText.contains("UID: deployment-uid"))
        let expectedLabels = [
            "Labels to set",
            "Annotations to set",
            "Label keys to remove",
            "Annotation keys to remove",
        ]

        for label in expectedLabels {
            let editor = try #require(views.compactMap { $0 as? NSTextView }
                .first { $0.accessibilityLabel() == label })
            let scrollView = try #require(editor.enclosingScrollView)
            #expect(!editor.isRichText)
            #expect(editor.isVerticallyResizable)
            #expect(!editor.isHorizontallyResizable)
            #expect(editor.textContainer?.widthTracksTextView == true)
            #expect(scrollView.hasVerticalScroller)
            #expect(scrollView.borderType == .bezelBorder)
            #expect(editor.accessibilityHelp()?.contains("per line") == true)
        }
        let labelsEditor = try metadataEditor("Labels to set", in: views)
        labelsEditor.string = "team=platform"
        labelsEditor.setSelectedRange(NSRange(location: labelsEditor.string.count, length: 0))
        labelsEditor.insertNewline(nil)
        labelsEditor.insertText("app=api", replacementRange: labelsEditor.selectedRange())
        #expect(labelsEditor.string == "team=platform\napp=api")
        #expect(views.contains {
            $0.accessibilityLabel() == "Resource mutation in progress"
        })
        #expect(views.contains {
            $0.accessibilityLabel() == "Resource mutation status"
        })

        let scaleController = mutationController(
            mutation: .scale,
            operationProvider: CapturingMutationOperationProvider()
        )
        let scaleRoot = try #require(scaleController.window?.contentView)
        #expect(mutationDescendants(of: scaleRoot).contains {
            $0.accessibilityLabel() == "Replica count"
        })
    }

    @Test("multiple metadata lines reach one optimistic mutation without flattening")
    func multilineMetadataSubmission() async throws {
        let provider = CapturingMutationOperationProvider()
        let controller = mutationController(
            mutation: .metadata,
            operationProvider: provider
        )
        let root = try #require(controller.window?.contentView)
        let views = mutationDescendants(of: root)
        let labels = try metadataEditor("Labels to set", in: views)
        let annotations = try metadataEditor("Annotations to set", in: views)
        let removeLabels = try metadataEditor("Label keys to remove", in: views)
        let removeAnnotations = try metadataEditor("Annotation keys to remove", in: views)
        labels.string = "team=platform\napp=api"
        annotations.string = "example.com/query=a=b,c=d\nnote=hello world"
        removeLabels.string = "legacy\nold.example.com/name"
        removeAnnotations.string = "old.example.com/note\nstale"

        let apply = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Apply" })
        apply.performClick(nil)
        let changes = try await waitForMetadataChanges(provider)

        #expect(changes.labels == ["team": "platform", "app": "api"])
        #expect(changes.annotations == [
            "example.com/query": "a=b,c=d",
            "note": "hello world",
        ])
        #expect(changes.removeLabelKeys == ["legacy", "old.example.com/name"])
        #expect(changes.removeAnnotationKeys == ["old.example.com/note", "stale"])
        let status = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Resource mutation status" })
        try await waitForMutationStatus(status, value: "Succeeded")
    }

    @Test("structured API errors retain operation and causes in the status surface")
    func structuredIssuePresentation() async throws {
        let controller = mutationController(
            mutation: .metadata,
            operationProvider: RetryingMutationOperationProvider()
        )
        let root = try #require(controller.window?.contentView)
        let views = mutationDescendants(of: root)
        let labels = try metadataEditor("Labels to set", in: views)
        labels.string = "team=platform"
        let status = try #require(views.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Resource mutation status" })
        let apply = try #require(views.compactMap { $0 as? NSButton }
            .first { $0.title == "Apply" })

        apply.performClick(nil)
        try await waitForMutationStatus(status, containing: "HTTP 422")

        #expect(status.stringValue.contains("Operation: update metadata"))
        #expect(status.stringValue.contains("Context: production"))
        #expect(status.stringValue.contains("Retryable"))
        #expect(status.stringValue.contains("Causes: Field metadata.labels.team"))
        #expect(status.toolTip?.contains("FieldValueInvalid") == true)

        try await Task.sleep(for: .milliseconds(20))
        apply.performClick(nil)
        try await waitForMutationStatus(status, value: "Succeeded")
        #expect(status.toolTip == nil)
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

@MainActor
private func metadataEditor(_ label: String, in views: [NSView]) throws -> NSTextView {
    try #require(views.compactMap { $0 as? NSTextView }
        .first { $0.accessibilityLabel() == label })
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

    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent]
    {
        []
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
    private var metadataChanges: ResourceMetadataChanges?

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
        metadataChanges = changes
        return AsyncThrowingStream { continuation in
            continuation.yield(OperationProgress(
                cursor: StreamCursor(generation: 1, sequence: 1),
                operationID: "metadata-update",
                state: .succeeded,
                completedItems: 1,
                totalItems: 1,
                itemResults: []
            ))
            continuation.finish()
        }
    }

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws {}

    func capturedMetadataChanges() -> ResourceMetadataChanges? { metadataChanges }
}

private actor RetryingMutationOperationProvider: ResourceOperationProviding {
    private var updateAttempts = 0

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
        updateAttempts += 1
        if updateAttempts == 1 {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "Invalid",
                message: "The API server rejected the label.",
                httpStatusCode: 422,
                retryable: true,
                contextName: "production",
                operation: "update metadata",
                kubernetesStatus: .init(causes: [
                    .init(
                        reason: "FieldValueInvalid",
                        message: "unsupported label value",
                        field: "metadata.labels.team"
                    )
                ])
            )
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(OperationProgress(
                cursor: StreamCursor(generation: 1, sequence: 1),
                operationID: "metadata-retry",
                state: .succeeded,
                completedItems: 1,
                totalItems: 1,
                itemResults: []
            ))
            continuation.finish()
        }
    }

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws {}
}

@MainActor
private func waitForMetadataChanges(
    _ provider: CapturingMutationOperationProvider
) async throws -> ResourceMetadataChanges {
    for _ in 0..<300 {
        if let changes = await provider.capturedMetadataChanges() { return changes }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ResourceMutationWindowTestError.timedOut
}

@MainActor
private func waitForMutationStatus(
    _ status: NSTextField,
    value: String
) async throws {
    for _ in 0..<300 {
        if status.stringValue == value { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ResourceMutationWindowTestError.timedOut
}

@MainActor
private func waitForMutationStatus(
    _ status: NSTextField,
    containing value: String
) async throws {
    for _ in 0..<300 {
        if status.stringValue.contains(value) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ResourceMutationWindowTestError.timedOut
}

private enum ResourceMutationWindowTestError: Error {
    case timedOut
}
