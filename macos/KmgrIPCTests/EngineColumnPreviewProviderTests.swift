import Foundation
import KmgrCore
import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine column preview provider")
struct EngineColumnPreviewProviderTests {
    @Test("maps the complete selected-object preview request and rendered response")
    func mapsSelectedObjectPreview() async throws {
        var response = Kmgr_V1_PreviewColumnResponse()
        response.requestID = "preview-request"
        response.celEnvironment = "kmgr.cel/v1"
        response.usedSampleObject = false
        response.evaluatedObject.clusterSessionID = "session-one"
        response.evaluatedObject.group = "apps"
        response.evaluatedObject.version = "v1"
        response.evaluatedObject.resource = "deployments"
        response.evaluatedObject.namespace = "apps"
        response.evaluatedObject.name = "api"
        response.evaluatedObject.uid = "uid-api"
        response.preview.columnID = "available"
        response.preview.displayText = "9007199254740993"
        response.preview.integerValue = 9_007_199_254_740_993
        response.preview.tooltip = "Available replicas"
        response.preview.severity = .warning

        let rpc = FakeColumnPreviewRPC(response: response)
        let provider = deterministicProvider(rpc: rpc)
        let result = try await provider.previewColumn(ColumnPreviewRequest(
            sessionID: "session-one",
            resource: DiscoveredResource(
                group: "apps",
                version: "v1",
                resource: "deployments",
                kind: "Deployment",
                namespaced: true
            ),
            namespaceScope: NamespaceSelection(
                allNamespaces: false,
                namespaces: ["staging", "apps"]
            ),
            column: ColumnDefinition(
                id: "available",
                title: "Available",
                source: .cel,
                expression: "object.status.availableReplicas",
                type: .integer,
                missing: "—",
                listJoiner: " · "
            ),
            selectedObject: ResourceIdentity(
                clusterSessionID: "session-one",
                group: "apps",
                version: "v1",
                resource: "deployments",
                namespace: "apps",
                name: "api",
                uid: "uid-api"
            )
        ))

        #expect(result.requestID == "preview-request")
        #expect(result.celEnvironment == "kmgr.cel/v1")
        #expect(!result.usedSampleObject)
        #expect(result.preview == Cell(
            columnID: "available",
            displayText: "9007199254740993",
            typedValue: .integer(9_007_199_254_740_993),
            tooltip: "Available replicas",
            severity: .warning
        ))
        #expect(result.evaluatedObject == ResourceIdentity(
            clusterSessionID: "session-one",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "apps",
            name: "api",
            uid: "uid-api"
        ))

        let captured = await rpc.capturedRequest()
        #expect(captured?.context.requestID == "preview-request")
        #expect(captured?.context.clusterSessionID == "session-one")
        #expect(captured?.context.deadlineUnixMs == 1_007_000)
        #expect(captured?.resource.group == "apps")
        #expect(captured?.resource.version == "v1")
        #expect(captured?.resource.resource == "deployments")
        #expect(captured?.resource.kind == "Deployment")
        #expect(captured?.resource.namespaced == true)
        #expect(captured?.namespaceScope.allNamespaces == false)
        #expect(captured?.namespaceScope.namespaces == ["apps", "staging"])
        #expect(captured?.column.id == "available")
        #expect(captured?.column.title == "Available")
        #expect(captured?.column.expression == "object.status.availableReplicas")
        #expect(captured?.column.resultType == "integer")
        #expect(captured?.column.missing == "—")
        #expect(captured?.column.listJoiner == " · ")
        #expect(captured?.hasSelectedObject == true)
        #expect(captured?.selectedObject.clusterSessionID == "session-one")
        #expect(captured?.selectedObject.group == "apps")
        #expect(captured?.selectedObject.version == "v1")
        #expect(captured?.selectedObject.resource == "deployments")
        #expect(captured?.selectedObject.namespace == "apps")
        #expect(captured?.selectedObject.name == "api")
        #expect(captured?.selectedObject.uid == "uid-api")
        #expect(await rpc.capturedTimeout() == .seconds(7))
    }

    @Test("maps exact quantity previews and absent usage components")
    func mapsTypedQuantityAndUsagePresence() async throws {
        var response = Kmgr_V1_PreviewColumnResponse()
        response.requestID = "preview-request"
        response.celEnvironment = "kmgr.cel/v1"
        response.preview.columnID = "memory"
        response.preview.displayText = "1Gi"
        response.preview.quantityValue.exact = "1Gi"
        response.preview.quantityValue.display = "1Gi"
        response.preview.quantityValue.sortValue = 1_073_741_824

        let quantityResult = try await deterministicProvider(
            rpc: FakeColumnPreviewRPC(response: response)
        ).previewColumn(Self.request())
        #expect(quantityResult.preview.typedValue == .quantity(
            KubernetesQuantityValue(
                exact: "1Gi", display: "1Gi", sortValue: 1_073_741_824
            )
        ))

        var usageResponse = response
        usageResponse.preview.typedValue = nil
        usageResponse.preview.usage.used = 0
        usageResponse.preview.usage.usageAvailable = true
        usageResponse.preview.usage.requested = 0
        usageResponse.preview.usage.sortValue = 0
        let usageResult = try await deterministicProvider(
            rpc: FakeColumnPreviewRPC(response: usageResponse)
        ).previewColumn(Self.request())
        guard case .usage(let usage)? = usageResult.preview.typedValue else {
            Issue.record("Expected usage value")
            return
        }
        #expect(usage.usage == 0)
        #expect(usage.request == 0)
        #expect(usage.limit == nil)
        #expect(usage.capacity == nil)
        #expect(usage.sortValue == 0)

        usageResponse.preview.usage.clearRequested()
        usageResponse.preview.usage.clearSortValue()
        usageResponse.preview.usage.usageAvailable = false
        let absentResult = try await deterministicProvider(
            rpc: FakeColumnPreviewRPC(response: usageResponse)
        ).previewColumn(Self.request())
        guard case .usage(let absent)? = absentResult.preview.typedValue else {
            Issue.record("Expected absent usage value")
            return
        }
        #expect(absent.usage == nil)
        #expect(absent.request == nil)
        #expect(absent.sortValue == nil)
    }

    @Test("omits selected identity and maps a sample-object usage cell")
    func mapsSamplePreview() async throws {
        var usage = Kmgr_V1_ResourceUsageValue()
        usage.used = 0.75
        usage.requested = 0.5
        usage.limit = 1
        usage.capacity = 8
        usage.unit = "cores"
        usage.resourceName = "cpu"
        usage.measuredAtUnixMs = 1_234_000
        usage.provider = "metrics.k8s.io"
        usage.measurementScope = "pod"
        usage.usageAvailable = true
        usage.sortValue = 0.75

        var response = Kmgr_V1_PreviewColumnResponse()
        response.requestID = "preview-request"
        response.celEnvironment = "kmgr.cel/v1"
        response.usedSampleObject = true
        response.preview.columnID = "cpu"
        response.preview.displayText = "750m"
        response.preview.usage = usage
        response.preview.severity = .muted

        let rpc = FakeColumnPreviewRPC(response: response)
        let result = try await deterministicProvider(rpc: rpc).previewColumn(
            ColumnPreviewRequest(
                sessionID: "session-one",
                resource: DiscoveredResource(
                    group: "", version: "v1", resource: "pods",
                    kind: "Pod", namespaced: true
                ),
                namespaceScope: NamespaceSelection(),
                column: ColumnDefinition(
                    id: "cpu",
                    title: "CPU",
                    source: .cel,
                    expression: "metrics.resources['cpu']",
                    type: .resourceUsage
                )
            )
        )

        let captured = await rpc.capturedRequest()
        #expect(captured?.namespaceScope.allNamespaces == true)
        #expect(captured?.namespaceScope.namespaces.isEmpty == true)
        #expect(captured?.column.resultType == "resourceUsage")
        #expect(captured?.column.missing.isEmpty == true)
        #expect(captured?.column.listJoiner.isEmpty == true)
        #expect(captured?.hasSelectedObject == false)
        #expect(result.usedSampleObject)
        #expect(result.evaluatedObject == nil)
        #expect(result.preview.severity == .muted)
        guard case .usage(let mappedUsage)? = result.preview.typedValue else {
            Issue.record("Expected a typed usage preview")
            return
        }
        #expect(mappedUsage.usage == 0.75)
        #expect(mappedUsage.request == 0.5)
        #expect(mappedUsage.limit == 1)
        #expect(mappedUsage.capacity == 8)
        #expect(mappedUsage.sortValue == 0.75)
        #expect(mappedUsage.unit == "cores")
        #expect(mappedUsage.resourceName == "cpu")
        #expect(mappedUsage.measuredAtUnixMilliseconds == 1_234_000)
        #expect(mappedUsage.provider == "metrics.k8s.io")
        #expect(mappedUsage.measurementScope == "pod")
    }

    @Test("rejects a mismatched response identity")
    func rejectsResponseMismatch() async {
        var response = Self.successfulResponse()
        response.requestID = "another-request"
        let provider = deterministicProvider(
            rpc: FakeColumnPreviewRPC(response: response)
        )

        do {
            _ = try await provider.previewColumn(Self.request())
            Issue.record("Expected request ID mismatch")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
            #expect(issue.reason == "RequestIDMismatch")
            #expect(issue.operation == "preview CEL column")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("maps authoritative compile failures without erasing their details")
    func mapsStructuredFailure() async {
        var response = Kmgr_V1_PreviewColumnResponse()
        response.requestID = "preview-request"
        response.celEnvironment = "kmgr.cel/v1"
        response.error.category = .validation
        response.error.reason = "CELCompileFailed"
        response.error.message = "unexpected token at line 1"
        response.error.fieldPath = "column.expression"
        response.error.operation = "compile CEL column"
        response.error.safeDetails = ["line": "1"]
        let provider = deterministicProvider(
            rpc: FakeColumnPreviewRPC(response: response)
        )

        do {
            _ = try await provider.previewColumn(Self.request())
            Issue.record("Expected structured compile failure")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .validation)
            #expect(issue.reason == "CELCompileFailed")
            #expect(issue.message == "unexpected token at line 1")
            #expect(issue.fieldPath == "column.expression")
            #expect(issue.operation == "compile CEL column")
            #expect(issue.safeDetails["line"] == "1")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("keeps a raw value beside a declared-type validation failure")
    func mapsInvalidValueWithPreview() async throws {
        var response = Self.successfulResponse()
        response.preview.columnID = "metadata"
        response.preview.displayText = "name: sample\nnamespace: default"
        response.preview.typedValue = nil
        response.preview.tooltip = "Evaluated CEL value · type map · YAML"
        response.preview.severity = .warning
        response.error.category = .validation
        response.error.reason = "CELEvaluationFailed"
        response.error.message = "column \"metadata\": result type is map, declared string"
        response.error.operation = "evaluate CEL column"

        let result = try await deterministicProvider(
            rpc: FakeColumnPreviewRPC(response: response)
        ).previewColumn(Self.request())

        #expect(result.preview.displayText.contains("sample"))
        #expect(result.preview.typedValue == nil)
        #expect(result.preview.severity == .warning)
        #expect(result.validationIssue?.reason == "CELEvaluationFailed")
        #expect(result.validationIssue?.message.contains("declared string") == true)
    }

    private func deterministicProvider(
        rpc: FakeColumnPreviewRPC
    ) -> EngineColumnPreviewProvider {
        EngineColumnPreviewProvider(
            rpc: rpc,
            timeout: .seconds(7),
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "preview-request" }
        )
    }

    private static func request() -> ColumnPreviewRequest {
        ColumnPreviewRequest(
            sessionID: "session-one",
            resource: DiscoveredResource(
                group: "", version: "v1", resource: "pods",
                kind: "Pod", namespaced: true
            ),
            namespaceScope: .namespace("apps"),
            column: ColumnDefinition(
                id: "name",
                title: "Name",
                source: .cel,
                expression: "object.metadata.name",
                type: .string
            )
        )
    }

    private static func successfulResponse() -> Kmgr_V1_PreviewColumnResponse {
        var response = Kmgr_V1_PreviewColumnResponse()
        response.requestID = "preview-request"
        response.celEnvironment = "kmgr.cel/v1"
        response.usedSampleObject = true
        response.preview.columnID = "name"
        response.preview.displayText = "sample"
        response.preview.stringValue = "sample"
        return response
    }
}

private actor FakeColumnPreviewRPC: ColumnPreviewRPC {
    private let response: Kmgr_V1_PreviewColumnResponse
    private var request: Kmgr_V1_PreviewColumnRequest?
    private var timeout: Duration?

    init(response: Kmgr_V1_PreviewColumnResponse) {
        self.response = response
    }

    func capturedRequest() -> Kmgr_V1_PreviewColumnRequest? { request }
    func capturedTimeout() -> Duration? { timeout }

    func previewColumn(
        request: Kmgr_V1_PreviewColumnRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PreviewColumnResponse {
        self.request = request
        self.timeout = timeout
        return response
    }
}
