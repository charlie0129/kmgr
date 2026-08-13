import AppKit
import KmgrCore
import Testing
@testable import Kmgr

@MainActor
@Suite("Cluster workspace toolbar", .serialized)
struct ClusterWorkspaceToolbarTests {
    @Test("navigation items stay in the leading toolbar group")
    func navigationItemsAreLeading() throws {
        let controller = makeWorkspace()
        let window = try #require(controller.window)
        let items = try #require(window.toolbar?.items)

        #expect(window.toolbarStyle == .unified)
        #expect(items.prefix(5).map(\.itemIdentifier.rawValue) == [
            "workspace.sidebar", "workspace.back", "workspace.forward",
            "workspace.cluster", "workspace.namespace",
        ])
        for identifier in items.prefix(5).map(\.itemIdentifier.rawValue) {
            #expect(try #require(items.first {
                $0.itemIdentifier.rawValue == identifier
            }).isNavigational)
        }
        #expect(items.firstIndex { $0.itemIdentifier == .flexibleSpace }
            == items.firstIndex {
                $0.itemIdentifier.rawValue == "workspace.namespace"
            }.map { $0 + 1 })
    }

    @Test("Port Forwards button gives its title and arrows separate geometry")
    func portForwardsButtonGeometry() throws {
        let controller = makeWorkspace()
        let item = try #require(controller.window?.toolbar?.items.first {
            $0.label == "Port Forwards"
        })
        let button = try #require(item.view as? NSButton)

        #expect(button.title == "Forwards 0")
        #expect(button.image != nil)
        #expect(button.imagePosition == .imageLeading)
        #expect(button.imageHugsTitle)
        button.sizeToFit()
        #expect(button.frame.width >= button.intrinsicContentSize.width)
    }

    @Test("resource freshness header shows cached age and background progress")
    func resourceFreshnessHeader() async throws {
        let synchronizedAt = Date(timeIntervalSinceNow: -18)
        let provider = HeaderStatusWorkspaceResourceProvider(
            statuses: [
                ResourceViewStatus(
                    freshness: .stale,
                    rowsVisible: 7,
                    lastSynchronizedAt: synchronizedAt,
                    fromWarmCache: true
                ),
                ResourceViewStatus(
                    freshness: .reconnecting,
                    rowsVisible: 7,
                    lastSynchronizedAt: synchronizedAt,
                    fromWarmCache: true
                ),
            ]
        )
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let label = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Resource freshness" })
        let progress = try #require(descendants(of: root)
            .compactMap { $0 as? NSProgressIndicator }
            .first { $0.accessibilityLabel() == "Resource view update in progress" })

        try await waitUntil { label.stringValue.hasPrefix("Reconnecting…") }
        #expect(label.stringValue.contains("last synchronized"))
        #expect(label.stringValue.contains("old"))
        #expect(!progress.isHidden)
        #expect(!progress.isDisplayedWhenStopped)
        #expect(label.accessibilityValue() == label.stringValue)
    }
}

@MainActor
private func makeWorkspace(
    provider: any WorkspaceResourceProviding = NoopWorkspaceResourceProvider()
) -> ClusterWorkspaceWindowController {
    let portForwards = PortForwardCoordinator(provider: NoopPortForwardProvider())
    return ClusterWorkspaceWindowController(
        session: OpenedClusterSession(
            sessionID: "test-session",
            contextName: "test-context",
            clusterName: "test-cluster",
            serverHostname: "example.invalid",
            defaultNamespace: "default"
        ),
        provider: provider,
        connectionActivityProvider: NoopConnectionActivityProvider(),
        optionalResourceCatalogProvider: NoopOptionalResourceCatalogProvider(),
        objectSearchProvider: NoopObjectSearchProvider(),
        objectDetailProvider: NoopToolbarObjectDetailProvider(),
        operationProvider: NoopOperationProvider(),
        logProvider: NoopLogProvider(),
        execProvider: NoopExecProvider(),
        portForwards: portForwards,
        columnsConfigurationPath: "/tmp/kmgr-toolbar-test-columns.yaml",
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
        restoration: ClusterWindowRestorationRecord(
            id: "toolbar-test",
            contextName: "test-context"
        ),
        onShowPortForwards: {}
    )
}

private struct HeaderStatusWorkspaceResourceProvider: WorkspaceResourceProviding {
    let statuses: [ResourceViewStatus]

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: [DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { continuation in
            for (index, status) in statuses.enumerated() {
                continuation.yield(.status(
                    cursor: StreamCursor(
                        generation: request.generation,
                        sequence: UInt64(index + 1)
                    ),
                    status: status
                ))
            }
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants(of:))
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for the resource freshness header.",
                operation: "test resource freshness header"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct NoopWorkspaceResourceProvider: WorkspaceResourceProviding {
    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult { .init(resources: []) }
    func listNamespaces(sessionID: String) async throws -> [String] { [] }
    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private struct NoopConnectionActivityProvider: ClusterConnectionActivityProviding {
    func watchConnectionActivity(sessionID: String, streamID: String)
        -> AsyncThrowingStream<ClusterConnectionActivitySample, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct NoopOptionalResourceCatalogProvider: OptionalResourceCatalogProviding {
    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog { throw CancellationError() }
}

private struct NoopObjectSearchProvider: ObjectSearchProviding {
    func searchCachedObjects(request: CachedObjectSearchRequest) async throws
        -> CachedObjectSearchResponse { throw CancellationError() }
    func searchObjects(request: ObjectSearchRequest)
        -> AsyncThrowingStream<ObjectSearchMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelSearch(
        sessionID: String, searchID: String, generation: UInt64, queryRevision: UInt64
    ) async {}
}

private struct NoopToolbarObjectDetailProvider: ObjectDetailProviding {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        throw CancellationError()
    }
    func watchObject(identity: ResourceIdentity, resourceVersion: String)
        -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent] { [] }
    func getRelationships(identity: ResourceIdentity, includeChildren: Bool) async throws
        -> ObjectRelationships { .init(values: [], childrenPotentiallyIncomplete: true) }
    func scanRelationships(identity: ResourceIdentity)
        -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelRelationshipScan(
        sessionID: String, scanID: String, generation: UInt64
    ) async {}
    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
    }
    func prepareYAML(
        identity: ResourceIdentity, yamlUTF8: Data,
        expectedResourceVersion: String, forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit { throw CancellationError() }
    func applyYAML(
        identity: ResourceIdentity, yamlUTF8: Data,
        expectedResourceVersion: String, forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
    func updateData(
        identity: ResourceIdentity, expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}

private struct NoopOperationProvider: ResourceOperationProviding {
    func deleteResources(targets: [ResourceDeleteTarget], options: ResourceDeleteOptions)
        async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func scaleResource(identity: ResourceIdentity, replicas: Int32, expectedResourceVersion: String)
        async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func rolloutRestart(identity: ResourceIdentity, expectedResourceVersion: String)
        async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func updateMetadata(
        identity: ResourceIdentity, expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func cancelOperation(
        sessionID: String, operationID: String, cancelNotStartedOnly: Bool
    ) async throws {}
}

private struct NoopLogProvider: LogStreamProviding {
    func streamLogs(request: LogStreamRequest)
        -> AsyncThrowingStream<LogStreamMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async {}
}

private struct NoopExecProvider: ExecSessionProviding {
    func startExec(request: ExecSessionRequest) async throws -> any ExecSession {
        throw CancellationError()
    }
}

private struct NoopPortForwardProvider: PortForwardProviding {
    func listPortForwards(sessionID: String, includeStopped: Bool) async throws
        -> [PortForwardRecord] { [] }
    func watchPortForwards(request: PortForwardWatchRequest)
        -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        throw CancellationError()
    }
    func stopPortForward(id: String, sessionID: String) async throws {}
    func restartPortForward(id: String, sessionID: String) async throws {}
}
