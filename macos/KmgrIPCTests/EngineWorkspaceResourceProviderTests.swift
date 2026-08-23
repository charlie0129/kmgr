import Foundation
import GRPCCore
import KmgrCore
import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine workspace resource provider")
struct EngineWorkspaceResourceProviderTests {
    @Test("maps discovery and namespace responses with session-bound deadlines")
    func mapsDiscoveryAndNamespaces() async throws {
        var deployments = Kmgr_V1_ApiResource()
        deployments.type.group = "apps"
        deployments.type.version = "v1"
        deployments.type.resource = "deployments"
        deployments.type.kind = "Deployment"
        deployments.type.namespaced = true
        deployments.verbs = ["get", "list", "watch"]
        deployments.shortNames = ["deploy"]
        deployments.categories = ["all"]
        deployments.preferredVersion = true

        let rpc = FakeWorkspaceRPC(
            resources: [deployments],
            namespaces: ["apps", "default", "kube-system"]
        )
        let provider = deterministicProvider(rpc: rpc)

        let discovery = try await provider.discoverResources(
            sessionID: "session-one",
            refresh: true
        )
        let namespaces = try await provider.listNamespaces(sessionID: "session-one")

        #expect(discovery.resources == [DiscoveredResource(
            group: "apps",
            version: "v1",
            resource: "deployments",
            kind: "Deployment",
            namespaced: true,
            verbs: ["get", "list", "watch"],
            shortNames: ["deploy"],
            categories: ["all"],
            preferredVersion: true
        )])
        #expect(discovery.revision == "discovery-test")
        #expect(discovery.potentiallyIncomplete == false)
        #expect(discovery.warning == nil)
        #expect(namespaces == ["apps", "default", "kube-system"])

        let discoverRequest = await rpc.capturedDiscoverRequest()
        #expect(discoverRequest?.refresh == true)
        #expect(discoverRequest?.context.requestID == "workspace-request")
        #expect(discoverRequest?.context.clusterSessionID == "session-one")
        #expect(discoverRequest?.context.deadlineUnixMs == 1_030_000)
        let namespaceRequest = await rpc.capturedNamespaceRequest()
        #expect(namespaceRequest?.context.clusterSessionID == "session-one")
        #expect(namespaceRequest?.context.deadlineUnixMs == 1_030_000)
    }

    @Test("keeps partial discovery resources and maps the structured warning")
    func mapsPartialDiscoveryWarning() async throws {
        var pods = Kmgr_V1_ApiResource()
        pods.type.version = "v1"
        pods.type.resource = "pods"
        pods.type.kind = "Pod"
        pods.type.namespaced = true
        pods.verbs = ["list", "watch"]

        var warning = Kmgr_V1_StructuredError()
        warning.category = .unavailable
        warning.reason = "DiscoveryPartiallyFailed"
        warning.message = "Some Kubernetes API groups could not be discovered. The available resource list may be incomplete."
        warning.retryable = true
        warning.operation = "discover-resources"
        warning.safeDetails = [
            "failed_group_versions": "metrics.k8s.io/v1beta1",
            "failed_group_version_count": "1",
        ]

        let provider = deterministicProvider(rpc: FakeWorkspaceRPC(
            resources: [pods],
            discoveryWarning: warning,
            discoveryPotentiallyIncomplete: true
        ))

        let discovery = try await provider.discoverResources(
            sessionID: "session-one",
            refresh: false
        )

        #expect(discovery.resources.map(\.resource) == ["pods"])
        #expect(discovery.potentiallyIncomplete)
        #expect(discovery.warning?.reason == "DiscoveryPartiallyFailed")
        #expect(discovery.warning?.safeDetails["failed_group_versions"] == "metrics.k8s.io/v1beta1")
        #expect(discovery.warning?.retryable == true)
    }

    @Test("maps control invalidations and revision-pinned range and metric RPCs")
    func mapsViewStream() async throws {
        let rpc = FakeWorkspaceRPC(
            streamEvents: Self.viewEvents(),
            rangeRows: [Self.resourceRow()]
        )
        let provider = deterministicProvider(rpc: rpc)
        let request = ResourceViewRequest(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 7,
            resource: DiscoveredResource(
                group: "",
                version: "v1",
                resource: "pods",
                kind: "Pod",
                namespaced: true
            ),
            allNamespaces: false,
            namespaces: ["apps"],
            filterExpression:
                "labelSelector:\"app in (api,worker)\" fieldSelector:\"spec.nodeName=worker-1\" status:Running",
            filterRevision: 4,
            columnIDs: ["name", "ready", "large", "memory", "cpu", "debug", "sort"],
            sort: [
                ResourceSortDescriptor(
                    columnID: "ready",
                    direction: .descending,
                    nullsFirst: true
                ),
            ],
            stageUntilReconciled: true
        )

        var messages: [ResourceViewMessage] = []
        for try await message in provider.streamView(request: request) {
            messages.append(message)
        }

        #expect(messages.count == 4)
        guard case .status(let statusCursor, let status) = messages[0] else {
            Issue.record("Expected status event")
            return
        }
        #expect(statusCursor == StreamCursor(generation: 7, sequence: 1))
        #expect(status.freshness == .watching)
        #expect(status.objectsExamined == 500)
        #expect(status.rowsVisible == 1)
        #expect(status.lastSynchronizedAt == Date(timeIntervalSince1970: 1_234))
        #expect(status.fromWarmCache == false)
        #expect(status.metricsReconciling)

        guard case .invalidation(let invalidationCursor, let invalidation) = messages[1]
        else {
            Issue.record("Expected invalidation event")
            return
        }
        #expect(invalidationCursor == StreamCursor(generation: 7, sequence: 2))
        #expect(invalidation.presentationRevision == 11)
        #expect(invalidation.indexRevision == 3)
        #expect(invalidation.rowsVisible == 1)
        #expect(invalidation.maxRangeLength == 512)
        #expect(invalidation.observedOptionalResourceKeys == ["hugepages-2Mi"])
        #expect(invalidation.observedOptionalResourceKeysTruncated)

        guard case .reconciled(let reconciledCursor, let reconciliation) = messages[2]
        else {
            Issue.record("Expected reconciliation event")
            return
        }
        #expect(reconciledCursor == StreamCursor(generation: 7, sequence: 3))
        #expect(reconciliation.rowsVisible == 1)
        #expect(reconciliation.presentationRevision == 11)
        #expect(reconciliation.indexRevision == 3)

        guard case .failure(_, let issue) = messages[3] else {
            Issue.record("Expected structured stream failure")
            return
        }
        #expect(issue.category == .authorization)
        #expect(issue.reason == "PodsForbidden")
        #expect(issue.httpStatusCode == 403)
        #expect(issue.operation == "watch pods")
        #expect(issue.safeDetails["resource"] == "pods")

        let revision = ResourceViewRevision(
            generation: 7,
            presentation: 11,
            index: 3
        )
        let range = try await provider.fetchViewRange(request: ResourceViewRangeRequest(
            sessionID: "session-one",
            viewID: "view-pods",
            revision: revision,
            startIndex: 0,
            length: 1
        ))
        #expect(range.viewID == "view-pods")
        #expect(range.revision == revision)
        #expect(range.startIndex == 0)
        #expect(range.rowsVisible == 1)
        let row = try #require(range.rows.first)
        #expect(row.identity == ResourceIdentity(
            clusterSessionID: "session-one",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "apps",
            name: "api-0",
            uid: "uid-api"
        ))
        #expect(row["name"]?.typedValue == .string("api-0"))
        #expect(row["ready"]?.typedValue == .number(1))
        #expect(row["large"]?.typedValue == .integer(9_007_199_254_740_993))
        #expect(row["memory"]?.typedValue == .quantity(KubernetesQuantityValue(
            exact: "9007199254740993m",
            display: "9007199254740993m",
            sortValue: 9_007_199_254_740.992
        )))
        #expect(row["created"]?.typedValue == .timestampUnixMilliseconds(1_234_000))
        #expect(row["debug"]?.typedValue == .boolean(true))
        #expect(row["sort"]?.typedValue == .opaqueSortValue(Data([0x01, 0x02])))
        #expect(row["sort"]?.severity == .muted)
        guard case .usage(let usage)? = row["cpu"]?.typedValue else {
            Issue.record("Expected typed usage cell")
            return
        }
        #expect(usage.usage == 0.42)
        #expect(usage.request == 0.5)
        #expect(usage.limit == 1)
        #expect(usage.capacity == 8)
        #expect(usage.sortValue == 0.42)
        #expect(usage.resourceName == "cpu")
        #expect(usage.measuredAtUnixMilliseconds == 1_234_000)
        #expect(usage.provider == "metrics.k8s.io")
        #expect(usage.measurementScope == "pod")

        try await provider.updateMetricInterest(request: ResourceMetricInterestRequest(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 7,
            indexRevision: 3,
            startIndex: 0,
            length: 1
        ))

        let captured = await rpc.capturedStreamRequest()
        #expect(captured?.context.clusterSessionID == "session-one")
        #expect(captured?.context.deadlineUnixMs == 87_400_000)
        #expect(captured?.viewID == "view-pods")
        #expect(captured?.generation == 7)
        #expect(captured?.stageUntilReconciled == true)
        #expect(captured?.spec.resource.resource == "pods")
        #expect(captured?.spec.namespaceScope.namespaces == ["apps"])
        #expect(captured?.spec.filterExpression ==
            "labelSelector:\"app in (api,worker)\" fieldSelector:\"spec.nodeName=worker-1\" status:Running")
        #expect(captured?.spec.filterRevision == 4)
        #expect(captured?.spec.columnIds == ["name", "ready", "large", "memory", "cpu", "debug", "sort"])
        #expect(captured?.spec.sort.first?.direction == .descending)
        #expect(captured?.spec.sort.first?.nullsFirst == true)

        let capturedRange = await rpc.capturedRangeRequest()
        #expect(capturedRange?.context.clusterSessionID == "session-one")
        #expect(capturedRange?.context.deadlineUnixMs == 1_030_000)
        #expect(capturedRange?.viewID == "view-pods")
        #expect(capturedRange?.generation == 7)
        #expect(capturedRange?.presentationRevision == 11)
        #expect(capturedRange?.indexRevision == 3)
        #expect(capturedRange?.startIndex == 0)
        #expect(capturedRange?.length == 1)

        let metricInterest = await rpc.capturedMetricInterestRequest()
        #expect(metricInterest?.context.deadlineUnixMs == 1_005_000)
        #expect(metricInterest?.generation == 7)
        #expect(metricInterest?.indexRevision == 3)
        #expect(metricInterest?.startIndex == 0)
        #expect(metricInterest?.length == 1)
    }

    @Test("cancel and close send exact identities and preserve independent streams")
    func mapsLifecycleControl() async {
        let rpc = FakeWorkspaceRPC()
        let provider = deterministicProvider(rpc: rpc)

        await provider.cancelView(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 17
        )
        await provider.closeSession(sessionID: "session-one")

        let cancel = await rpc.capturedCancelRequest()
        #expect(cancel?.context.requestID == "workspace-request")
        #expect(cancel?.context.clusterSessionID == "session-one")
        #expect(cancel?.context.deadlineUnixMs == 1_005_000)
        #expect(cancel?.viewID == "view-pods")
        #expect(cancel?.generation == 17)

        let close = await rpc.capturedCloseRequest()
        #expect(close?.context.clusterSessionID == "session-one")
        #expect(close?.context.deadlineUnixMs == 1_005_000)
        #expect(close?.keepIndependentStreams == true)
    }

    @Test("maps token-backed selection gestures, projections, and pages")
    func mapsSelectionTransport() async throws {
        let rpc = FakeWorkspaceRPC()
        let provider = deterministicProvider(rpc: rpc)

        let state = try await provider.applySelectionGesture(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 9,
            indexRevision: 11,
            previousToken: "previous-token",
            gesture: ResourceSelectionGesture(
                kind: .shiftExtend,
                index: 6,
                additive: true
            )
        )
        #expect(state.token == "selection-token")
        #expect(state.revision == ResourceSelectionRevision(
            generation: 9,
            indexRevision: 11
        ))
        #expect(state.selectedCount == 3)
        #expect(state.anchor == ResourceSelectionAnchor(index: 4, uid: "uid-anchor"))
        #expect(state.expiresAt == Date(timeIntervalSince1970: 1_300))

        let projection = try await provider.projectSelectionRange(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 9,
            indexRevision: 11,
            startIndex: 4,
            length: 3,
            token: state.token
        )
        #expect(projection.viewID == "view-pods")
        #expect(projection.revision == state.revision)
        #expect(projection.startIndex == 4)
        #expect(projection.rowsVisible == 7)
        #expect(projection.state == state)
        #expect(projection.selected == [true, false, true])
        #expect(projection.anchorOffset == 0)

        let page = try await provider.fetchSelectionPage(
            sessionID: "session-one",
            viewID: "view-pods",
            token: state.token,
            offset: 1,
            limit: 2
        )
        #expect(page.state == state)
        #expect(page.offset == 1)
        #expect(page.items.map(\.pinnedIndex) == [5, 6])
        #expect(page.items.map(\.identity.uid) == ["uid-worker", "uid-api"])
        #expect(page.items.allSatisfy {
            $0.identity.clusterSessionID == "session-one"
        })
        #expect(page.nextOffset == 3)
        #expect(page.done)

        let gesture = await rpc.capturedSelectionGestureRequest()
        #expect(gesture?.context.requestID == "workspace-request")
        #expect(gesture?.context.clusterSessionID == "session-one")
        #expect(gesture?.context.deadlineUnixMs == 1_030_000)
        #expect(gesture?.viewID == "view-pods")
        #expect(gesture?.generation == 9)
        #expect(gesture?.indexRevision == 11)
        #expect(gesture?.previousToken == "previous-token")
        #expect(gesture?.gesture.kind == .shiftExtend)
        #expect(gesture?.gesture.index == 6)
        #expect(gesture?.gesture.additive == true)

        _ = try await provider.applySelectionGesture(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 9,
            indexRevision: 11,
            previousToken: state.token,
            gesture: ResourceSelectionGesture(
                kind: .shiftExtend,
                additive: true,
                targetUID: "uid-target",
                anchorUID: "uid-anchor"
            )
        )
        let stableGesture = await rpc.capturedSelectionGestureRequest()
        #expect(stableGesture?.gesture.index == 0)
        #expect(stableGesture?.gesture.targetUid == "uid-target")
        #expect(stableGesture?.gesture.anchorUid == "uid-anchor")

        let range = await rpc.capturedSelectionRangeRequest()
        #expect(range?.generation == 9)
        #expect(range?.indexRevision == 11)
        #expect(range?.startIndex == 4)
        #expect(range?.length == 3)
        #expect(range?.token == "selection-token")

        let pageRequest = await rpc.capturedSelectionPageRequest()
        #expect(pageRequest?.viewID == "view-pods")
        #expect(pageRequest?.token == "selection-token")
        #expect(pageRequest?.offset == 1)
        #expect(pageRequest?.limit == 2)
    }

    @Test("accepts an old token projected onto a newer view revision")
    func acceptsOldSelectionProjection() async throws {
        let provider = deterministicProvider(rpc: FakeWorkspaceRPC(
            selectionFault: .projectionOldState
        ))

        let projection = try await provider.projectSelectionRange(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 9,
            indexRevision: 11,
            startIndex: 4,
            length: 3,
            token: "selection-token"
        )

        #expect(projection.revision == ResourceSelectionRevision(
            generation: 9,
            indexRevision: 11
        ))
        #expect(projection.state.revision == ResourceSelectionRevision(
            generation: 7,
            indexRevision: 8
        ))
    }

    @Test("rejects mismatched selection projection metadata and duplicate page identities")
    func rejectsMalformedSelectionResponses() async {
        let missingExpiry = deterministicProvider(rpc: FakeWorkspaceRPC(
            selectionFault: .missingExpiry
        ))
        do {
            _ = try await missingExpiry.applySelectionGesture(
                sessionID: "session-one",
                viewID: "view-pods",
                generation: 9,
                indexRevision: 11,
                previousToken: "",
                gesture: ResourceSelectionGesture(kind: .replace, index: 4)
            )
            Issue.record("Expected a selection without an expiry to fail")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
        } catch {
            Issue.record("Unexpected selection expiry error type: \(error)")
        }

        let mismatchedProjection = deterministicProvider(rpc: FakeWorkspaceRPC(
            selectionFault: .projectionToken
        ))
        do {
            _ = try await mismatchedProjection.projectSelectionRange(
                sessionID: "session-one",
                viewID: "view-pods",
                generation: 9,
                indexRevision: 11,
                startIndex: 4,
                length: 3,
                token: "selection-token"
            )
            Issue.record("Expected mismatched projection selection state to fail")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
        } catch {
            Issue.record("Unexpected projection error type: \(error)")
        }

        let duplicatePage = deterministicProvider(rpc: FakeWorkspaceRPC(
            selectionFault: .duplicatePageUID
        ))
        do {
            _ = try await duplicatePage.fetchSelectionPage(
                sessionID: "session-one",
                viewID: "view-pods",
                token: "selection-token",
                offset: 1,
                limit: 2
            )
            Issue.record("Expected duplicate selection identities to fail")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
        } catch {
            Issue.record("Unexpected selection page error type: \(error)")
        }
    }

    @Test("workspace stream fails safely instead of growing past its buffer")
    func boundsWorkspaceStreamBuffer() async throws {
        let eventCount = 20
        let bufferLimit = 4
        let rpc = FakeWorkspaceRPC(
            streamEvents: (1...eventCount).map { sequence in
                var event = Kmgr_V1_ViewEvent()
                event.cursor = Self.cursor(sequence: UInt64(sequence))
                event.status.freshness = .watching
                return event
            }
        )
        let provider = EngineWorkspaceResourceProvider(
            rpc: rpc,
            maximumBufferedMessages: bufferLimit
        )
        let request = ResourceViewRequest(
            sessionID: "session-one",
            viewID: "view-pods",
            generation: 7,
            resource: DiscoveredResource(
                group: "", version: "v1", resource: "pods",
                kind: "Pod", namespaced: true
            ),
            allNamespaces: true,
            namespaces: []
        )

        let stream = provider.streamView(request: request)
        // The fake producer completes synchronously on its detached bridge
        // before this consumer starts draining, deterministically exercising
        // the bufferingOldest overflow path.
        try await Task.sleep(for: .milliseconds(50))

        var delivered = 0
        do {
            for try await _ in stream { delivered += 1 }
            Issue.record("Expected the bounded workspace stream to fail on overflow")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .resourceExhausted)
            #expect(issue.reason == "WorkspaceStreamBufferExceeded")
            #expect(issue.retryable)
            #expect(issue.safeDetails["buffered_message_limit"] == String(bufferLimit))
        }
        #expect(delivered <= bufferLimit)
    }

    @Test("workspace response mismatches and structured discovery errors stay useful")
    func mapsDiscoveryFailures() async {
        var structured = Kmgr_V1_StructuredError()
        structured.category = .authorization
        structured.reason = "DiscoveryForbidden"
        structured.message = "API discovery is forbidden."
        structured.httpStatusCode = 403
        structured.operation = "discover-resources"
        structured.safeDetails = ["group": "example.io"]
        let rpc = FakeWorkspaceRPC(discoveryError: structured)
        let provider = deterministicProvider(rpc: rpc)

        do {
            _ = try await provider.discoverResources(
                sessionID: "session-one",
                refresh: false
            )
            Issue.record("Expected structured discovery error")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .authorization)
            #expect(issue.reason == "DiscoveryForbidden")
            #expect(issue.httpStatusCode == 403)
            #expect(issue.safeDetails["group"] == "example.io")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private func deterministicProvider(
        rpc: FakeWorkspaceRPC
    ) -> EngineWorkspaceResourceProvider {
        EngineWorkspaceResourceProvider(
            rpc: rpc,
            unaryTimeout: .seconds(30),
            streamTimeout: .seconds(86_400),
            controlTimeout: .seconds(5),
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "workspace-request" }
        )
    }

    private static func viewEvents() -> [Kmgr_V1_ViewEvent] {
        var status = Kmgr_V1_ViewEvent()
        status.cursor = cursor(sequence: 1)
        status.status.freshness = .watching
        status.status.objectsExamined = 500
        status.status.rowsVisible = 1
        status.status.lastSynchronizedUnixMs = 1_234_000
        status.status.metricsReconciling = true

        var invalidation = Kmgr_V1_ViewEvent()
        invalidation.cursor = cursor(sequence: 2)
        invalidation.invalidation.presentationRevision = 11
        invalidation.invalidation.indexRevision = 3
        invalidation.invalidation.rowsVisible = 1
        invalidation.invalidation.maxRangeLength = 512
        invalidation.invalidation.observedOptionalResourceKeys = ["hugepages-2Mi"]
        invalidation.invalidation.observedOptionalResourceKeysTruncated = true

        var reconciled = Kmgr_V1_ViewEvent()
        reconciled.cursor = cursor(sequence: 3)
        reconciled.reconciled.rowsVisible = 1
        reconciled.reconciled.presentationRevision = 11
        reconciled.reconciled.indexRevision = 3

        var failure = Kmgr_V1_ViewEvent()
        failure.cursor = cursor(sequence: 4)
        failure.error.category = .authorization
        failure.error.reason = "PodsForbidden"
        failure.error.message = "Watching Pods is forbidden."
        failure.error.httpStatusCode = 403
        failure.error.operation = "watch pods"
        failure.error.safeDetails = ["resource": "pods"]
        return [status, invalidation, reconciled, failure]
    }

    private static func cursor(sequence: UInt64) -> Kmgr_V1_StreamCursor {
        var cursor = Kmgr_V1_StreamCursor()
        cursor.streamID = "view-pods"
        cursor.generation = 7
        cursor.sequence = sequence
        return cursor
    }

    private static func resourceRow() -> Kmgr_V1_ResourceRow {
        var row = Kmgr_V1_ResourceRow()
        row.identity.clusterSessionID = "session-one"
        row.identity.version = "v1"
        row.identity.resource = "pods"
        row.identity.namespace = "apps"
        row.identity.name = "api-0"
        row.identity.uid = "uid-api"

        var name = Kmgr_V1_Cell()
        name.columnID = "name"
        name.displayText = "api-0"
        name.stringValue = "api-0"

        var ready = Kmgr_V1_Cell()
        ready.columnID = "ready"
        ready.displayText = "1/1"
        ready.numberValue = 1

        var created = Kmgr_V1_Cell()
        created.columnID = "created"
        created.displayText = "20m"
        created.timestampUnixMs = 1_234_000

        var large = Kmgr_V1_Cell()
        large.columnID = "large"
        large.displayText = "9007199254740993"
        large.integerValue = 9_007_199_254_740_993

        var quantityValue = Kmgr_V1_KubernetesQuantityValue()
        quantityValue.exact = "9007199254740993m"
        quantityValue.display = "9007199254740993m"
        quantityValue.sortValue = 9_007_199_254_740.992
        var memory = Kmgr_V1_Cell()
        memory.columnID = "memory"
        memory.displayText = quantityValue.display
        memory.quantityValue = quantityValue

        var usageValue = Kmgr_V1_ResourceUsageValue()
        usageValue.used = 0.42
        usageValue.requested = 0.5
        usageValue.limit = 1
        usageValue.capacity = 8
        usageValue.unit = "cores"
        usageValue.resourceName = "cpu"
        usageValue.measuredAtUnixMs = 1_234_000
        usageValue.provider = "metrics.k8s.io"
        usageValue.measurementScope = "pod"
        usageValue.usageAvailable = true
        usageValue.sortValue = 0.42
        var usage = Kmgr_V1_Cell()
        usage.columnID = "cpu"
        usage.displayText = "420m / 500m / 1"
        usage.usage = usageValue
        usage.severity = .info

        var debug = Kmgr_V1_Cell()
        debug.columnID = "debug"
        debug.displayText = "true"
        debug.boolValue = true

        var sort = Kmgr_V1_Cell()
        sort.columnID = "sort"
        sort.displayText = "—"
        sort.opaqueSortValue = Data([0x01, 0x02])
        sort.severity = .muted

        row.cells = [name, ready, large, memory, created, usage, debug, sort]
        return row
    }
}

private enum FakeSelectionFault: Sendable {
    case missingExpiry
    case projectionOldState
    case projectionToken
    case duplicatePageUID
}

private actor FakeWorkspaceRPC: WorkspaceRPC {
    private let resources: [Kmgr_V1_ApiResource]
    private let namespaces: [String]
    private let streamEvents: [Kmgr_V1_ViewEvent]
    private let rangeRows: [Kmgr_V1_ResourceRow]
    private let discoveryError: Kmgr_V1_StructuredError?
    private let discoveryWarning: Kmgr_V1_StructuredError?
    private let discoveryPotentiallyIncomplete: Bool
    private let selectionFault: FakeSelectionFault?

    private var discoverRequest: Kmgr_V1_DiscoverRequest?
    private var namespaceRequest: Kmgr_V1_ListNamespacesRequest?
    private var streamRequest: Kmgr_V1_OpenViewRequest?
    private var rangeRequest: Kmgr_V1_FetchViewRangeRequest?
    private var selectionGestureRequest: Kmgr_V1_ApplySelectionGestureRequest?
    private var selectionRangeRequest: Kmgr_V1_ProjectSelectionRangeRequest?
    private var selectionPageRequest: Kmgr_V1_FetchSelectionPageRequest?
    private var metricInterestRequest: Kmgr_V1_UpdateMetricInterestRequest?
    private var cancelRequest: Kmgr_V1_CancelViewRequest?
    private var closeRequest: Kmgr_V1_CloseSessionRequest?

    init(
        resources: [Kmgr_V1_ApiResource] = [],
        namespaces: [String] = [],
        streamEvents: [Kmgr_V1_ViewEvent] = [],
        rangeRows: [Kmgr_V1_ResourceRow] = [],
        discoveryError: Kmgr_V1_StructuredError? = nil,
        discoveryWarning: Kmgr_V1_StructuredError? = nil,
        discoveryPotentiallyIncomplete: Bool = false,
        selectionFault: FakeSelectionFault? = nil
    ) {
        self.resources = resources
        self.namespaces = namespaces
        self.streamEvents = streamEvents
        self.rangeRows = rangeRows
        self.discoveryError = discoveryError
        self.discoveryWarning = discoveryWarning
        self.discoveryPotentiallyIncomplete = discoveryPotentiallyIncomplete
        self.selectionFault = selectionFault
    }

    func capturedDiscoverRequest() -> Kmgr_V1_DiscoverRequest? { discoverRequest }
    func capturedNamespaceRequest() -> Kmgr_V1_ListNamespacesRequest? { namespaceRequest }
    func capturedStreamRequest() -> Kmgr_V1_OpenViewRequest? { streamRequest }
    func capturedRangeRequest() -> Kmgr_V1_FetchViewRangeRequest? { rangeRequest }
    func capturedSelectionGestureRequest() -> Kmgr_V1_ApplySelectionGestureRequest? {
        selectionGestureRequest
    }
    func capturedSelectionRangeRequest() -> Kmgr_V1_ProjectSelectionRangeRequest? {
        selectionRangeRequest
    }
    func capturedSelectionPageRequest() -> Kmgr_V1_FetchSelectionPageRequest? {
        selectionPageRequest
    }
    func capturedMetricInterestRequest() -> Kmgr_V1_UpdateMetricInterestRequest? {
        metricInterestRequest
    }
    func capturedCancelRequest() -> Kmgr_V1_CancelViewRequest? { cancelRequest }
    func capturedCloseRequest() -> Kmgr_V1_CloseSessionRequest? { closeRequest }

    func discover(
        request: Kmgr_V1_DiscoverRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_DiscoverResponse {
        discoverRequest = request
        var response = Kmgr_V1_DiscoverResponse()
        response.requestID = request.context.requestID
        response.resources = resources
        response.discoveryRevision = "discovery-test"
        if let discoveryError { response.error = discoveryError }
        if let discoveryWarning { response.warning = discoveryWarning }
        response.potentiallyIncomplete = discoveryPotentiallyIncomplete
        return response
    }

    func listNamespaces(
        request: Kmgr_V1_ListNamespacesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListNamespacesResponse {
        namespaceRequest = request
        var response = Kmgr_V1_ListNamespacesResponse()
        response.requestID = request.context.requestID
        response.namespaces = namespaces
        return response
    }

    func streamView(
        request: Kmgr_V1_OpenViewRequest,
        timeout: Duration,
        receive: @escaping @Sendable (Kmgr_V1_ViewEvent) throws -> Void
    ) async throws {
        streamRequest = request
        for event in streamEvents {
            try receive(event)
        }
    }

    func fetchViewRange(
        request: Kmgr_V1_FetchViewRangeRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_FetchViewRangeResponse {
        rangeRequest = request
        var response = Kmgr_V1_FetchViewRangeResponse()
        response.requestID = request.context.requestID
        response.viewID = request.viewID
        response.generation = request.generation
        response.presentationRevision = request.presentationRevision
        response.indexRevision = request.indexRevision
        response.startIndex = request.startIndex
        response.rowsVisible = UInt64(rangeRows.count)
        if request.startIndex <= response.rowsVisible {
            let start = Int(request.startIndex)
            let end = min(rangeRows.count, start + Int(request.length))
            response.rows = Array(rangeRows[start..<end])
        }
        return response
    }

    func updateMetricInterest(
        request: Kmgr_V1_UpdateMetricInterestRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        metricInterestRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = request.context.requestID
        response.accepted = true
        return response
    }

    func applySelectionGesture(
        request: Kmgr_V1_ApplySelectionGestureRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ApplySelectionGestureResponse {
        selectionGestureRequest = request
        var response = Kmgr_V1_ApplySelectionGestureResponse()
        response.requestID = request.context.requestID
        response.selection = Self.selectionState(
            generation: request.generation,
            indexRevision: request.indexRevision
        )
        if selectionFault == .missingExpiry {
            response.selection.expiresAtUnixMs = 0
        }
        return response
    }

    func projectSelectionRange(
        request: Kmgr_V1_ProjectSelectionRangeRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ProjectSelectionRangeResponse {
        selectionRangeRequest = request
        var response = Kmgr_V1_ProjectSelectionRangeResponse()
        response.requestID = request.context.requestID
        response.viewID = request.viewID
        response.generation = request.generation
        response.indexRevision = request.indexRevision
        response.startIndex = request.startIndex
        response.rowsVisible = 7
        response.selection = Self.selectionState(
            generation: request.generation,
            indexRevision: request.indexRevision
        )
        if selectionFault == .projectionOldState {
            response.selection.generation = 7
            response.selection.indexRevision = 8
        } else if selectionFault == .projectionToken {
            response.selection.token = "different-selection-token"
        }
        response.selected = [true, false, true]
        response.anchorOffset = 0
        return response
    }

    func fetchSelectionPage(
        request: Kmgr_V1_FetchSelectionPageRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_FetchSelectionPageResponse {
        selectionPageRequest = request
        var response = Kmgr_V1_FetchSelectionPageResponse()
        response.requestID = request.context.requestID
        response.selection = Self.selectionState(generation: 9, indexRevision: 11)
        response.offset = request.offset
        response.items = [
            Self.selectionPageItem(
                pinnedIndex: 5,
                sessionID: request.context.clusterSessionID,
                name: "worker-0",
                uid: "uid-worker"
            ),
            Self.selectionPageItem(
                pinnedIndex: 6,
                sessionID: request.context.clusterSessionID,
                name: "api-0",
                uid: "uid-api"
            ),
        ]
        if selectionFault == .duplicatePageUID {
            response.items[1].identity.uid = response.items[0].identity.uid
        }
        response.nextOffset = request.offset + UInt64(response.items.count)
        response.done = true
        return response
    }

    func cancelView(
        request: Kmgr_V1_CancelViewRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        cancelRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = request.context.requestID
        response.accepted = true
        return response
    }

    func closeSession(
        request: Kmgr_V1_CloseSessionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_Acknowledgement {
        closeRequest = request
        var response = Kmgr_V1_Acknowledgement()
        response.requestID = request.context.requestID
        response.accepted = true
        return response
    }

    private static func selectionState(
        generation: UInt64,
        indexRevision: UInt64
    ) -> Kmgr_V1_SelectionState {
        var state = Kmgr_V1_SelectionState()
        state.token = "selection-token"
        state.generation = generation
        state.indexRevision = indexRevision
        state.selectedCount = 3
        state.anchor.index = 4
        state.anchor.uid = "uid-anchor"
        state.expiresAtUnixMs = 1_300_000
        return state
    }

    private static func selectionPageItem(
        pinnedIndex: UInt64,
        sessionID: String,
        name: String,
        uid: String
    ) -> Kmgr_V1_SelectionPageItem {
        var item = Kmgr_V1_SelectionPageItem()
        item.pinnedIndex = pinnedIndex
        item.identity.clusterSessionID = sessionID
        item.identity.version = "v1"
        item.identity.resource = "pods"
        item.identity.namespace = "apps"
        item.identity.name = name
        item.identity.uid = uid
        return item
    }
}
