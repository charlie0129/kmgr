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

        let resources = try await provider.discoverResources(
            sessionID: "session-one",
            refresh: true
        )
        let namespaces = try await provider.listNamespaces(sessionID: "session-one")

        #expect(resources == [DiscoveredResource(
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

    @Test("maps streamed request, compact rows, status, deltas, and structured failures")
    func mapsViewStream() async throws {
        let rpc = FakeWorkspaceRPC(streamEvents: Self.viewEvents())
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
            filterExpression: "status:Running",
            filterRevision: 4,
            columnIDs: ["name", "ready", "cpu", "debug", "sort"],
            sort: [
                ResourceSortDescriptor(
                    columnID: "ready",
                    direction: .descending,
                    nullsFirst: true
                ),
            ]
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

        guard case .snapshot(let snapshotCursor, let snapshot) = messages[1],
            let row = snapshot.rows.first
        else {
            Issue.record("Expected snapshot event")
            return
        }
        #expect(snapshotCursor == StreamCursor(generation: 7, sequence: 2))
        #expect(snapshot.first && snapshot.last)
        #expect(snapshot.index == 0)
        #expect(snapshot.estimatedTotalRows == 1)
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
        #expect(usage.resourceName == "cpu")
        #expect(usage.measuredAtUnixMilliseconds == 1_234_000)
        #expect(usage.provider == "metrics.k8s.io")
        #expect(usage.measurementScope == "pod")

        guard case .delta(_, let delta) = messages[2] else {
            Issue.record("Expected delta event")
            return
        }
        #expect(delta.removedUIDs == ["uid-old"])
        #expect(delta.orderedUIDs == ["uid-api"])
        #expect(delta.orderIsComplete)

        guard case .failure(_, let issue) = messages[3] else {
            Issue.record("Expected structured stream failure")
            return
        }
        #expect(issue.category == .authorization)
        #expect(issue.reason == "PodsForbidden")
        #expect(issue.httpStatusCode == 403)
        #expect(issue.operation == "watch pods")
        #expect(issue.safeDetails["resource"] == "pods")

        let captured = await rpc.capturedStreamRequest()
        #expect(captured?.context.clusterSessionID == "session-one")
        #expect(captured?.context.deadlineUnixMs == 87_400_000)
        #expect(captured?.viewID == "view-pods")
        #expect(captured?.generation == 7)
        #expect(captured?.spec.resource.resource == "pods")
        #expect(captured?.spec.namespaceScope.namespaces == ["apps"])
        #expect(captured?.spec.filterExpression == "status:Running")
        #expect(captured?.spec.filterRevision == 4)
        #expect(captured?.spec.columnIds == ["name", "ready", "cpu", "debug", "sort"])
        #expect(captured?.spec.sort.first?.direction == .descending)
        #expect(captured?.spec.sort.first?.nullsFirst == true)
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

        var snapshot = Kmgr_V1_ViewEvent()
        snapshot.cursor = cursor(sequence: 2)
        snapshot.snapshot.firstChunk = true
        snapshot.snapshot.lastChunk = true
        snapshot.snapshot.chunkIndex = 0
        snapshot.snapshot.estimatedTotalRows = 1
        snapshot.snapshot.rows = [resourceRow()]

        var delta = Kmgr_V1_ViewEvent()
        delta.cursor = cursor(sequence: 3)
        delta.delta.removedUids = ["uid-old"]
        delta.delta.orderedUids = ["uid-api"]
        delta.delta.orderIsComplete = true

        var failure = Kmgr_V1_ViewEvent()
        failure.cursor = cursor(sequence: 4)
        failure.error.category = .authorization
        failure.error.reason = "PodsForbidden"
        failure.error.message = "Watching Pods is forbidden."
        failure.error.httpStatusCode = 403
        failure.error.operation = "watch pods"
        failure.error.safeDetails = ["resource": "pods"]
        return [status, snapshot, delta, failure]
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

        row.cells = [name, ready, created, usage, debug, sort]
        return row
    }
}

private actor FakeWorkspaceRPC: WorkspaceRPC {
    private let resources: [Kmgr_V1_ApiResource]
    private let namespaces: [String]
    private let streamEvents: [Kmgr_V1_ViewEvent]
    private let discoveryError: Kmgr_V1_StructuredError?

    private var discoverRequest: Kmgr_V1_DiscoverRequest?
    private var namespaceRequest: Kmgr_V1_ListNamespacesRequest?
    private var streamRequest: Kmgr_V1_OpenViewRequest?
    private var cancelRequest: Kmgr_V1_CancelViewRequest?
    private var closeRequest: Kmgr_V1_CloseSessionRequest?

    init(
        resources: [Kmgr_V1_ApiResource] = [],
        namespaces: [String] = [],
        streamEvents: [Kmgr_V1_ViewEvent] = [],
        discoveryError: Kmgr_V1_StructuredError? = nil
    ) {
        self.resources = resources
        self.namespaces = namespaces
        self.streamEvents = streamEvents
        self.discoveryError = discoveryError
    }

    func capturedDiscoverRequest() -> Kmgr_V1_DiscoverRequest? { discoverRequest }
    func capturedNamespaceRequest() -> Kmgr_V1_ListNamespacesRequest? { namespaceRequest }
    func capturedStreamRequest() -> Kmgr_V1_OpenViewRequest? { streamRequest }
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
        if let discoveryError { response.error = discoveryError }
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
}
