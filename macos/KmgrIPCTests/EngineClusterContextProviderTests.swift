import Foundation
import GRPCCore
import KmgrCore
import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine cluster context provider")
struct EngineClusterContextProviderTests {
    @Test("maps offline context metadata and unsupported authentication")
    func mapsContextMetadata() async throws {
        var supported = Kmgr_V1_KubeconfigContext()
        supported.contextID = "context-source-local"
        supported.name = "local"
        supported.clusterName = "kind-local"
        supported.serverHostname = "127.0.0.1"
        supported.defaultNamespace = "platform"
        supported.sourcePaths = ["/tmp/a", "/tmp/b"]
        supported.current = true
        supported.authenticationHint = "Client certificate"
        supported.authenticationSupported = true

        var unsupported = Kmgr_V1_KubeconfigContext()
        unsupported.name = "cloud"
        unsupported.serverHostname = "api.example.com"
        unsupported.authenticationHint = "auth-provider"
        unsupported.authenticationSupported = false
        var authError = Kmgr_V1_StructuredError()
        authError.category = .unsupported
        authError.reason = "UnsupportedAuthentication"
        authError.message = "Context cloud uses unsupported auth-provider authentication."
        authError.contextName = "cloud"
        authError.safeDetails = ["mechanism": "auth-provider"]
        unsupported.unsupportedAuthenticationError = authError

        var added = Kmgr_V1_AddedKubeconfigSource()
        added.path = "/tmp/team.yaml"
        added.contextCount = 2
        var missing = Kmgr_V1_AddedKubeconfigSource()
        missing.path = "/tmp/missing.yaml"
        missing.error.category = .notFound
        missing.error.reason = "KubeconfigFileMissing"
        missing.error.message = "The kubeconfig file could not be found."
        missing.error.operation = "read added kubeconfig"
        missing.error.retryable = true

        let rpc = FakeClusterRPC(
            contexts: [supported, unsupported],
            addedSources: [added, missing]
        )
        let provider = deterministicProvider(rpc: rpc)
        let catalog = try await provider.listContexts(
            reload: true,
            addedKubeconfigPaths: ["/tmp/team.yaml"]
        )
        let contexts = catalog.contexts

        #expect(contexts.count == 2)
        #expect(contexts[0].name == "local")
        #expect(contexts[0].id == "context-source-local")
        #expect(contexts[0].sourcePaths == ["/tmp/a", "/tmp/b"])
        #expect(contexts[0].authentication.isSupported)
        #expect(contexts[1].authentication.issue?.category == .unsupported)
        #expect(contexts[1].authentication.issue?.safeDetails["mechanism"] == "auth-provider")
        #expect(catalog.addedKubeconfigSources == [
            AddedKubeconfigSourceStatus(path: "/tmp/team.yaml", contextCount: 2),
            AddedKubeconfigSourceStatus(
                path: "/tmp/missing.yaml",
                issue: ClusterManagerIssue(
                    category: .notFound,
                    reason: "KubeconfigFileMissing",
                    message: "The kubeconfig file could not be found.",
                    retryable: true,
                    operation: "read added kubeconfig"
                )
            ),
        ])

        let captured = await rpc.capturedListRequest()
        #expect(captured?.reload == true)
        #expect(captured?.addedKubeconfigPaths == ["/tmp/team.yaml"])
        #expect(captured?.context.requestID == "request-1")
        #expect(captured?.context.deadlineUnixMs == 1_005_000)
    }

    @Test("open returns independent session only after successful probe response")
    func opensSession() async throws {
        let rpc = FakeClusterRPC()
        await rpc.setOpenResult { request in
            var response = Kmgr_V1_OpenSessionResponse()
            response.requestID = request.context.requestID
            response.clusterSessionID = "session-abc"
            response.contextName = "prod-context"
            response.clusterName = "production"
            response.serverHostname = "api.example.com"
            response.defaultNamespace = "apps"
            return response
        }
        let provider = deterministicProvider(rpc: rpc)

        let session = try await provider.openContext(
            reference: "context-source-prod",
            addedKubeconfigPaths: ["/tmp/prod.yaml"]
        )

        #expect(session.sessionID == "session-abc")
        #expect(session.contextName == "prod-context")
        #expect(session.contextReference == "context-source-prod")
        #expect(session.defaultNamespace == "apps")
        let request = await rpc.capturedOpenRequest()
        #expect(request?.contextName == "context-source-prod")
        #expect(request?.addedKubeconfigPaths == ["/tmp/prod.yaml"])
        #expect(request?.context.deadlineUnixMs == 1_010_000)
    }

    @Test("structured probe errors preserve auth TLS and retry metadata")
    func mapsStructuredOpenError() async throws {
        let rpc = FakeClusterRPC()
        await rpc.setOpenResult { request in
            var response = Kmgr_V1_OpenSessionResponse()
            response.requestID = request.context.requestID
            response.error.category = .tls
            response.error.reason = "UnknownAuthority"
            response.error.message = "TLS verification failed for context production."
            response.error.contextName = "production"
            response.error.operation = "probe cluster"
            response.error.retryable = false
            response.error.safeDetails = ["server": "api.example.com"]
            response.error.kubernetesStatus.name = "deploy-api"
            response.error.kubernetesStatus.group = "apps"
            response.error.kubernetesStatus.kind = "Deployment"
            response.error.kubernetesStatus.uid = "uid-1"
            response.error.kubernetesStatus.reason = "Invalid"
            response.error.kubernetesStatus.retryAfterSeconds = 3
            var cause = Kmgr_V1_KubernetesStatusCause()
            cause.reason = "FieldValueInvalid"
            cause.field = "spec.template.spec.containers[0].image"
            response.error.kubernetesStatus.causes = [cause]
            return response
        }
        let provider = deterministicProvider(rpc: rpc)

        await #expect(throws: ClusterManagerIssue.self) {
            try await provider.openContext(
                reference: "production",
                addedKubeconfigPaths: []
            )
        }
        do {
            _ = try await provider.openContext(
                reference: "production",
                addedKubeconfigPaths: []
            )
            Issue.record("Expected structured TLS error")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .tls)
            #expect(issue.reason == "UnknownAuthority")
            #expect(issue.contextName == "production")
            #expect(issue.operation == "probe cluster")
            #expect(issue.safeDetails["server"] == "api.example.com")
            #expect(issue.kubernetesStatus?.name == "deploy-api")
            #expect(issue.kubernetesStatus?.group == "apps")
            #expect(issue.kubernetesStatus?.kind == "Deployment")
            #expect(issue.kubernetesStatus?.uid == "uid-1")
            #expect(issue.kubernetesStatus?.reason == "Invalid")
            #expect(issue.kubernetesStatus?.retryAfterSeconds == 3)
            #expect(issue.kubernetesStatus?.causes == [
                .init(
                    reason: "FieldValueInvalid",
                    field: "spec.template.spec.containers[0].image"
                ),
            ])
        }
    }

    @Test("transport failures become useful retryable chooser issues")
    func mapsTransportFailure() async {
        let rpc = FakeClusterRPC()
        await rpc.setListError(
            RPCError(code: .unavailable, message: "engine socket unavailable")
        )
        let provider = deterministicProvider(rpc: rpc)

        do {
            _ = try await provider.listContexts(
                reload: false,
                addedKubeconfigPaths: []
            )
            Issue.record("Expected unavailable error")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .unavailable)
            #expect(issue.retryable)
            #expect(issue.operation == "list kubeconfig contexts")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("classifies only resource-view stale preconditions as revision races")
    func classifiesStaleResourceViewPrecondition() {
        let stale = EngineClusterContextProvider.issue(
            from: RPCError(
                code: .failedPrecondition,
                message: "resource view revision is stale: requested index 4, current 5"
            ),
            contextName: "",
            operation: "fetch resource view range"
        )
        #expect(stale.reason == ClusterManagerIssue.staleResourceViewRevisionReason)
        #expect(stale.isStaleResourceViewRequest)

        let expired = EngineClusterContextProvider.issue(
            from: RPCError(
                code: .failedPrecondition,
                message: "selection token expired"
            ),
            contextName: "",
            operation: "project resource selection range"
        )
        #expect(expired.reason == RPCError.Code.failedPrecondition.description)
        #expect(!expired.isStaleResourceViewRequest)

        let invalidRange = EngineClusterContextProvider.issue(
            from: RPCError(
                code: .invalidArgument,
                message: "invalid resource view range: start index 101 exceeds row count 100"
            ),
            contextName: "",
            operation: "fetch resource view range"
        )
        #expect(invalidRange.category == .validation)
        #expect(!invalidRange.isStaleResourceViewRequest)
    }

    @Test("restart backoff is bounded and stops after the attempt budget")
    func boundedRestartBackoff() {
        let policy = EngineRestartPolicy(
            maximumAttempts: 5,
            initialDelayMilliseconds: 100,
            maximumDelayMilliseconds: 250
        )
        #expect(policy.delayMilliseconds(afterFailure: 1) == 100)
        #expect(policy.delayMilliseconds(afterFailure: 2) == 200)
        #expect(policy.delayMilliseconds(afterFailure: 3) == 250)
        #expect(policy.delayMilliseconds(afterFailure: 4) == 250)
        #expect(policy.delayMilliseconds(afterFailure: 5) == nil)
    }

    private func deterministicProvider(rpc: FakeClusterRPC) -> EngineClusterContextProvider {
        EngineClusterContextProvider(
            rpc: rpc,
            listTimeout: .seconds(5),
            openTimeout: .seconds(10),
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "request-1" }
        )
    }
}

private actor FakeClusterRPC: ClusterRPC {
    typealias OpenResult = @Sendable (Kmgr_V1_OpenSessionRequest) throws
        -> Kmgr_V1_OpenSessionResponse

    private let contexts: [Kmgr_V1_KubeconfigContext]
    private let addedSources: [Kmgr_V1_AddedKubeconfigSource]
    private var listRequest: Kmgr_V1_ListContextsRequest?
    private var openRequest: Kmgr_V1_OpenSessionRequest?
    private var listError: (any Error)?
    private var openResult: OpenResult?

    init(
        contexts: [Kmgr_V1_KubeconfigContext] = [],
        addedSources: [Kmgr_V1_AddedKubeconfigSource] = []
    ) {
        self.contexts = contexts
        self.addedSources = addedSources
    }

    func setListError(_ error: any Error) {
        listError = error
    }

    func setOpenResult(_ result: @escaping OpenResult) {
        openResult = result
    }

    func capturedListRequest() -> Kmgr_V1_ListContextsRequest? { listRequest }
    func capturedOpenRequest() -> Kmgr_V1_OpenSessionRequest? { openRequest }

    func listContexts(
        request: Kmgr_V1_ListContextsRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_ListContextsResponse {
        listRequest = request
        if let listError { throw listError }
        var response = Kmgr_V1_ListContextsResponse()
        response.requestID = request.context.requestID
        response.contexts = contexts
        response.addedKubeconfigSources = addedSources
        return response
    }

    func openSession(
        request: Kmgr_V1_OpenSessionRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_OpenSessionResponse {
        openRequest = request
        guard let openResult else {
            throw RPCError(code: .unavailable, message: "no open response")
        }
        return try openResult(request)
    }
}
