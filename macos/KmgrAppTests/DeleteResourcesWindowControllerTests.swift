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
        #expect(controller.window?.title ==
            "cluster-a — production — Delete Resources")
        let identityText = deleteDescendants(of: root)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: "\n")
        #expect(identityText.contains("Cluster: cluster-a"))
        #expect(identityText.contains("Context: production"))
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

    @Test("token confirmation is bounded and displays exact destructive facts")
    func tokenConfirmationIsBounded() async throws {
        let reference = deleteSelectionReference(count: 250_000)
        let revision = ResourceSelectionRevision(generation: 7, indexRevision: 11)
        let expiry = Date().addingTimeInterval(300)
        let preview = (0..<64).map {
            ResourceDeleteTarget(
                identity: deleteIdentity(name: "workload-\($0)", uid: "uid-\($0)"),
                hiddenByFilter: $0 < 3
            )
        }
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: revision,
                hiddenCount: 42,
                expiresAt: expiry,
                preview: preview,
                previewTruncated: true
            )
        )
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(reference: reference, currentRevision: revision),
            provider: provider,
            currentSelectionRevision: { _, revision in revision }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }

        try await waitForDeleteWindow {
            deleteSummary(in: controller).contains("250,000")
                && deleteSummary(in: controller).contains("42 hidden")
        }
        let summary = deleteSummary(in: controller)
        #expect(summary.contains("apps/v1/deployments"))
        #expect(summary.contains("Expires:"))
        #expect(summary.contains("Showing 64 bounded UID previews"))
        let table = try deleteTable(in: controller)
        #expect(table.numberOfRows == 64)
        #expect(provider.preparationPreviewLimits == [64])
        #expect(provider.deleteSelections.isEmpty)
    }

    @Test("expired confirmation requires reselection and cannot submit")
    func tokenExpiryRequiresReselection() async throws {
        let reference = deleteSelectionReference(count: 250_000)
        let revision = ResourceSelectionRevision(generation: 1, indexRevision: 1)
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: revision,
                hiddenCount: 0,
                expiresAt: Date().addingTimeInterval(0.08),
                preview: [ResourceDeleteTarget(
                    identity: deleteIdentity(name: "api", uid: "api-uid")
                )],
                previewTruncated: true
            )
        )
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(reference: reference, currentRevision: revision),
            provider: provider,
            currentSelectionRevision: { _, revision in revision }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }

        try await waitForDeleteWindow {
            deleteStatus(in: controller).contains("expired")
        }
        let deleteButton = try #require(deleteButtons(in: controller).first {
            $0.title == "Delete"
        })
        #expect(!deleteButton.isEnabled || deleteButton.isHidden)
        #expect(deleteStatus(in: controller).contains("Reselect"))
        #expect(provider.deleteSelections.isEmpty)
    }

    @Test("aggregate progress retains bounded failures and reports exact totals")
    func aggregateProgressIsBounded() async throws {
        let reference = deleteSelectionReference(count: 250_000)
        let revision = ResourceSelectionRevision(generation: 3, indexRevision: 9)
        let failures = (0..<70).map { index in
            OperationItemResult(
                identity: deleteIdentity(
                    name: "failed-\(index)", uid: "failed-uid-\(index)"
                ),
                state: .failed
            )
        }
        let terminal = OperationProgress(
            cursor: StreamCursor(generation: 1, sequence: 1),
            operationID: "aggregate-delete",
            state: .partiallySucceeded,
            completedItems: 250_000,
            totalItems: 250_000,
            itemResults: failures,
            aggregateOnly: true,
            omittedItemResults: 5,
            issue: ClusterManagerIssue(
                category: .internalFailure,
                reason: "SelectionProducerStopped",
                message: "The selection producer stopped before all deletions were dispatched."
            )
        )
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: revision,
                hiddenCount: 100,
                expiresAt: Date().addingTimeInterval(300),
                preview: Array((0..<64).map {
                    ResourceDeleteTarget(identity: deleteIdentity(
                        name: "preview-\($0)", uid: "preview-uid-\($0)"
                    ))
                }),
                previewTruncated: true
            ),
            progress: [terminal]
        )
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(reference: reference, currentRevision: revision),
            provider: provider,
            currentSelectionRevision: { _, revision in revision }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }
        try await waitForDeleteWindow {
            deleteButtons(in: controller).contains {
                $0.title == "Delete" && $0.isEnabled
            }
        }
        let deleteButton = try #require(deleteButtons(in: controller).first {
            $0.title == "Delete"
        })
        deleteButton.performClick(nil)
        try await waitForDeleteWindow {
            deleteStatus(in: controller).contains("249,925 deleted")
        }

        #expect(provider.deleteSelections == [reference])
        let status = deleteStatus(in: controller)
        #expect(status.contains("75 failed, skipped, or cancelled"))
        #expect(status.contains(
            "selection producer stopped before all deletions were dispatched"
        ))
        // Six received failures exceed the UI's 64-row cap and five more were
        // omitted by the backend, so both bounded layers remain visible.
        #expect(status.contains("11 additional details omitted"))
        let table = try deleteTable(in: controller)
        #expect(table.numberOfRows == 64)
        let visibilityColumn = try #require(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "visibility"
        })
        let visibility = try #require(table.view(
            atColumn: visibilityColumn,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        #expect(visibility.textField?.stringValue == "Not tracked")
    }

    @Test("progress stream failures leave deletion terminal and closeable")
    func progressStreamFailureIsTerminal() async throws {
        let reference = deleteSelectionReference(count: 10)
        let revision = ResourceSelectionRevision(generation: 1, indexRevision: 1)
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: revision,
                hiddenCount: 0,
                expiresAt: Date().addingTimeInterval(300),
                preview: [],
                previewTruncated: true
            ),
            progressError: ClusterManagerIssue(
                category: .internalFailure,
                reason: "OperationProgressEndedBeforeTerminal",
                message: "The engine ended operation progress before a terminal event."
            )
        )
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(reference: reference, currentRevision: revision),
            provider: provider,
            currentSelectionRevision: { _, revision in revision }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }

        try await waitForDeleteWindow {
            deleteButtons(in: controller).contains {
                $0.title == "Delete" && $0.isEnabled
            }
        }
        let deleteButton = try #require(deleteButtons(in: controller).first {
            $0.title == "Delete"
        })
        deleteButton.performClick(nil)
        try await waitForDeleteWindow {
            deleteStatus(in: controller).contains("before a terminal event")
                && deleteButtons(in: controller).contains {
                    $0.title == "Close" && $0.isEnabled
                }
        }

        #expect(deleteButton.isHidden)
        #expect(provider.deleteSelections == [reference])
    }

    @Test("unrelated preparation failures do not demand reselection")
    func unrelatedPreparationFailurePreservesError() async throws {
        let reference = deleteSelectionReference(count: 10)
        let revision = ResourceSelectionRevision(generation: 1, indexRevision: 1)
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: revision,
                hiddenCount: 0,
                expiresAt: Date().addingTimeInterval(300),
                preview: [],
                previewTruncated: true
            ),
            preparationError: ClusterManagerIssue(
                category: .authentication,
                reason: "Unauthorized",
                message: "Authentication failed (401).",
                httpStatusCode: 401,
                operation: "prepare selection deletion"
            )
        )
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(reference: reference, currentRevision: revision),
            provider: provider,
            currentSelectionRevision: { _, revision in revision }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }

        try await waitForDeleteWindow {
            deleteStatus(in: controller).contains("Authentication failed")
        }
        #expect(!deleteStatus(in: controller).contains("Reselect"))
    }

    @Test("index races retry once and preserve the token for manual retry")
    func indexRaceKeepsSelectionUsable() async throws {
        let reference = deleteSelectionReference(count: 10)
        let firstRevision = ResourceSelectionRevision(
            generation: 1,
            indexRevision: 1
        )
        let latestRevision = ResourceSelectionRevision(
            generation: 1,
            indexRevision: 2
        )
        let stale = ClusterManagerIssue(
            category: .conflict,
            reason: "SelectionViewChanged",
            message: "The resource index advanced during confirmation."
        )
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: latestRevision,
                hiddenCount: 0,
                expiresAt: Date().addingTimeInterval(300),
                preview: [],
                previewTruncated: true
            ),
            progress: [OperationProgress(
                cursor: StreamCursor(generation: 1, sequence: 1),
                operationID: "retry-delete",
                state: .succeeded,
                completedItems: 10,
                totalItems: 10,
                itemResults: [],
                aggregateOnly: true
            )],
            preparationErrors: [stale, stale]
        )
        var revisionLookups = 0
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(
                reference: reference,
                currentRevision: firstRevision
            ),
            provider: provider,
            currentSelectionRevision: { _, _ in
                defer { revisionLookups += 1 }
                return revisionLookups == 0 ? firstRevision : latestRevision
            }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }

        try await waitForDeleteWindow {
            deleteButtons(in: controller).contains {
                $0.title == "Retry" && $0.isEnabled
            }
        }
        #expect(deleteStatus(in: controller).contains("selection remains valid"))
        #expect(!deleteStatus(in: controller).localizedCaseInsensitiveContains(
            "reselect"
        ))

        let retry = try #require(deleteButtons(in: controller).first {
            $0.title == "Retry"
        })
        retry.performClick(nil)
        try await waitForDeleteWindow {
            deleteButtons(in: controller).contains {
                $0.title == "Delete" && $0.isEnabled
            }
        }
        #expect(provider.preparationRevisions == [
            firstRevision,
            latestRevision,
            latestRevision,
        ])
        #expect(retry.title == "Delete")
        retry.performClick(nil)
        try await waitForDeleteWindow {
            deleteStatus(in: controller).contains("Deleted 10 resources")
        }
        #expect(provider.deleteSelections == [reference])
    }

    @Test("fully failed aggregate progress reports exact terminal totals")
    func failedAggregateReportsExactTotals() async throws {
        let reference = deleteSelectionReference(count: 10)
        let revision = ResourceSelectionRevision(generation: 1, indexRevision: 1)
        let provider = TokenDeleteResourcesProvider(
            preparation: ResourceSelectionDeletePreparation(
                selection: reference,
                currentRevision: revision,
                hiddenCount: 0,
                expiresAt: Date().addingTimeInterval(300),
                preview: [],
                previewTruncated: true
            ),
            progress: [OperationProgress(
                cursor: StreamCursor(generation: 1, sequence: 1),
                operationID: "failed-aggregate-delete",
                state: .failed,
                completedItems: 10,
                totalItems: 10,
                itemResults: [],
                aggregateOnly: true,
                omittedItemResults: 10,
                issue: ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "DeleteFailed",
                    message: "The API server rejected every deletion."
                )
            )]
        )
        let controller = DeleteResourcesWindowController(
            session: deleteSession(),
            request: .selection(reference: reference, currentRevision: revision),
            provider: provider,
            currentSelectionRevision: { _, revision in revision }
        )
        let parent = NSWindow()
        controller.beginSheet(for: parent)
        defer { controller.close() }

        try await waitForDeleteWindow {
            deleteButtons(in: controller).contains {
                $0.title == "Delete" && $0.isEnabled
            }
        }
        let deleteButton = try #require(deleteButtons(in: controller).first {
            $0.title == "Delete"
        })
        deleteButton.performClick(nil)
        try await waitForDeleteWindow {
            deleteStatus(in: controller).contains("0 deleted")
        }

        let status = deleteStatus(in: controller)
        #expect(status.contains("10 failed, skipped, or cancelled"))
        #expect(status.contains("10 additional details omitted"))
        #expect(status.contains("API server rejected every deletion"))
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

private func deleteSession() -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: "session",
        contextName: "production",
        clusterName: "cluster-a",
        serverHostname: "api.example.invalid",
        defaultNamespace: "default"
    )
}

private func deleteSelectionReference(count: UInt64) -> ResourceSelectionDeleteReference {
    ResourceSelectionDeleteReference(
        sessionID: "session",
        viewID: "view-a",
        token: "immutable-selection",
        selectedCount: count,
        gvr: GVR(group: "apps", version: "v1", resource: "deployments")
    )
}

@MainActor
private func deleteDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(deleteDescendants(of:))
}

@MainActor
private func deleteTable(
    in controller: DeleteResourcesWindowController
) throws -> NSTableView {
    let root = try #require(controller.window?.contentView)
    return try #require(deleteDescendants(of: root).compactMap {
        $0 as? NSTableView
    }.first {
        $0.accessibilityLabel() == "Resources awaiting deletion"
            || $0.accessibilityLabel() == "Bounded deletion non-success details"
    })
}

@MainActor
private func deleteSummary(in controller: DeleteResourcesWindowController) -> String {
    guard let root = controller.window?.contentView else { return "" }
    return deleteDescendants(of: root).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Deletion selection summary" }?
        .stringValue ?? ""
}

@MainActor
private func deleteStatus(in controller: DeleteResourcesWindowController) -> String {
    guard let root = controller.window?.contentView else { return "" }
    return deleteDescendants(of: root).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Deletion status" }?
        .stringValue ?? ""
}

@MainActor
private func deleteButtons(
    in controller: DeleteResourcesWindowController
) -> [NSButton] {
    guard let root = controller.window?.contentView else { return [] }
    return deleteDescendants(of: root).compactMap { $0 as? NSButton }
}

@MainActor
private func waitForDeleteWindow(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw DeleteWindowTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum DeleteWindowTestError: Error { case timedOut }

private final class TokenDeleteResourcesProvider: ResourceOperationProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let preparation: ResourceSelectionDeletePreparation
    private let progress: [OperationProgress]
    private let progressError: ClusterManagerIssue?
    private var preparationErrors: [ClusterManagerIssue]
    private var storedPreparationPreviewLimits: [Int] = []
    private var storedPreparationRevisions: [ResourceSelectionRevision] = []
    private var storedDeleteSelections: [ResourceSelectionDeleteReference] = []

    init(
        preparation: ResourceSelectionDeletePreparation,
        progress: [OperationProgress] = [],
        progressError: ClusterManagerIssue? = nil,
        preparationError: ClusterManagerIssue? = nil,
        preparationErrors: [ClusterManagerIssue] = []
    ) {
        self.preparation = preparation
        self.progress = progress
        self.progressError = progressError
        self.preparationErrors = preparationError.map { [$0] }
            ?? preparationErrors
    }

    var preparationPreviewLimits: [Int] {
        lock.withLock { storedPreparationPreviewLimits }
    }

    var preparationRevisions: [ResourceSelectionRevision] {
        lock.withLock { storedPreparationRevisions }
    }

    var deleteSelections: [ResourceSelectionDeleteReference] {
        lock.withLock { storedDeleteSelections }
    }

    func prepareDeleteSelection(
        selection: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision,
        previewLimit: Int
    ) async throws -> ResourceSelectionDeletePreparation {
        let error = lock.withLock {
            storedPreparationPreviewLimits.append(previewLimit)
            storedPreparationRevisions.append(currentRevision)
            return preparationErrors.isEmpty
                ? nil : preparationErrors.removeFirst()
        }
        if let error { throw error }
        return preparation
    }

    func deleteSelection(
        selection: ResourceSelectionDeleteReference,
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        lock.withLock { storedDeleteSelections.append(selection) }
        return AsyncThrowingStream { continuation in
            for value in progress { continuation.yield(value) }
            if let progressError {
                continuation.finish(throwing: progressError)
            } else {
                continuation.finish()
            }
        }
    }

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
