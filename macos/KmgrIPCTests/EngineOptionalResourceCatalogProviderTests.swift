import Foundation
import KmgrCore
import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine optional resource catalog provider")
struct EngineOptionalResourceCatalogProviderTests {
    @Test("maps exact resources, configured labels, GVR, and coverage flags")
    func mapsCatalog() async throws {
        var response = Kmgr_V1_DiscoverOptionalResourcesResponse()
        response.requestID = "catalog-request"
        response.nodesCacheAvailable = true
        response.podsCacheAvailable = false
        response.nodesSnapshotComplete = true
        response.podsSnapshotComplete = false
        response.potentiallyIncomplete = true
        response.resources = [
            Self.resource(
                key: "ephemeral-storage",
                category: .ephemeralStorage,
                present: true,
                displayName: "Ephemeral Storage"
            ),
            Self.resource(
                key: "hugepages-2Mi",
                category: .hugePage,
                present: true,
                displayName: "Huge Pages (2Mi)"
            ),
            Self.resource(
                key: "custom.example/fpga-card",
                category: .accelerator,
                present: false,
                displayName: "FPGA Cards",
                explicitlyConfigured: true
            ),
        ]

        let rpc = FakeOptionalResourceCatalogRPC(response: response)
        let result = try await Self.provider(rpc: rpc).discoverOptionalResources(
            OptionalResourceCatalogRequest(
                sessionID: "session-one",
                applicableResource: Self.nodes
            )
        )

        #expect(result.requestID == "catalog-request")
        #expect(result.nodesCacheAvailable)
        #expect(!result.podsCacheAvailable)
        #expect(result.nodesSnapshotComplete)
        #expect(!result.podsSnapshotComplete)
        #expect(result.potentiallyIncomplete)
        #expect(result.resources.map(\.exactKey) == [
            "ephemeral-storage",
            "hugepages-2Mi",
            "custom.example/fpga-card",
        ])
        #expect(result.resources.map(\.category) == [
            .ephemeralStorage,
            .hugePage,
            .accelerator,
        ])
        #expect(result.resources[2].displayName == "FPGA Cards")
        #expect(!result.resources[2].isPresent)
        #expect(result.resources[2].isExplicitlyConfigured)
        #expect(result.resources[2].applicableResource == Self.nodes)

        let captured = await rpc.capturedRequest()
        #expect(captured?.context.requestID == "catalog-request")
        #expect(captured?.context.clusterSessionID == "session-one")
        #expect(captured?.context.deadlineUnixMs == 1_004_000)
        #expect(captured?.applicableResource.group.isEmpty == true)
        #expect(captured?.applicableResource.version == "v1")
        #expect(captured?.applicableResource.resource == "nodes")
        #expect(captured?.applicableResource.kind == "Node")
        #expect(captured?.applicableResource.namespaced == false)
        #expect(await rpc.capturedTimeout() == .seconds(4))
    }

    @Test("keeps equal friendly labels separate by exact key")
    func keepsEqualLabelsSeparate() async throws {
        var response = Kmgr_V1_DiscoverOptionalResourcesResponse()
        response.requestID = "catalog-request"
        response.resources = [
            Self.resource(
                key: "nvidia.com/gpu",
                category: .accelerator,
                present: true,
                displayName: "GPU"
            ),
            Self.resource(
                key: "amd.com/gpu",
                category: .accelerator,
                present: true,
                displayName: "GPU"
            ),
        ]

        let result = try await Self.provider(
            rpc: FakeOptionalResourceCatalogRPC(response: response)
        ).discoverOptionalResources(.init(
            sessionID: "session-one",
            applicableResource: Self.nodes
        ))

        #expect(result.resources.count == 2)
        #expect(result.resources[0].displayName == result.resources[1].displayName)
        #expect(result.resources[0].id != result.resources[1].id)
    }

    @Test("rejects a mismatched authenticated request identity")
    func rejectsResponseMismatch() async {
        var response = Kmgr_V1_DiscoverOptionalResourcesResponse()
        response.requestID = "another-request"
        let provider = Self.provider(
            rpc: FakeOptionalResourceCatalogRPC(response: response)
        )

        do {
            _ = try await provider.discoverOptionalResources(.init(
                sessionID: "session-one",
                applicableResource: Self.nodes
            ))
            Issue.record("Expected request ID mismatch")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
            #expect(issue.reason == "RequestIDMismatch")
            #expect(issue.operation == "discover optional scheduler resources")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("maps structured backend failures without losing details")
    func mapsStructuredFailure() async {
        var response = Kmgr_V1_DiscoverOptionalResourcesResponse()
        response.requestID = "catalog-request"
        response.error.category = .notFound
        response.error.reason = "ClusterSessionNotFound"
        response.error.message = "The cluster session is no longer available."
        response.error.operation = "discover optional resources"
        response.error.safeDetails = ["scope": "cache-only"]

        do {
            _ = try await Self.provider(
                rpc: FakeOptionalResourceCatalogRPC(response: response)
            ).discoverOptionalResources(.init(
                sessionID: "expired-session",
                applicableResource: Self.nodes
            ))
            Issue.record("Expected structured failure")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .notFound)
            #expect(issue.reason == "ClusterSessionNotFound")
            #expect(issue.message == "The cluster session is no longer available.")
            #expect(issue.operation == "discover optional resources")
            #expect(issue.safeDetails["scope"] == "cache-only")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("rejects categories outside the typed catalog contract")
    func rejectsUnknownCategory() async {
        var response = Kmgr_V1_DiscoverOptionalResourcesResponse()
        response.requestID = "catalog-request"
        response.resources = [Self.resource(
            key: "vendor.example/device",
            category: .UNRECOGNIZED(91),
            present: true,
            displayName: "Device"
        )]

        do {
            _ = try await Self.provider(
                rpc: FakeOptionalResourceCatalogRPC(response: response)
            ).discoverOptionalResources(.init(
                sessionID: "session-one",
                applicableResource: Self.nodes
            ))
            Issue.record("Expected invalid catalog response")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.category == .internalFailure)
            #expect(issue.reason == "InvalidOptionalResourceCatalog")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("rejects duplicate exact identities")
    func rejectsDuplicateIdentity() async {
        var response = Kmgr_V1_DiscoverOptionalResourcesResponse()
        response.requestID = "catalog-request"
        response.resources = [
            Self.resource(
                key: "nvidia.com/gpu",
                category: .accelerator,
                present: true,
                displayName: "GPU"
            ),
            Self.resource(
                key: "nvidia.com/gpu",
                category: .accelerator,
                present: false,
                displayName: "Configured GPU",
                explicitlyConfigured: true
            ),
        ]

        do {
            _ = try await Self.provider(
                rpc: FakeOptionalResourceCatalogRPC(response: response)
            ).discoverOptionalResources(.init(
                sessionID: "session-one",
                applicableResource: Self.nodes
            ))
            Issue.record("Expected duplicate identity rejection")
        } catch let issue as ClusterManagerIssue {
            #expect(issue.reason == "InvalidOptionalResourceCatalog")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private static let nodes = DiscoveredResource(
        group: "",
        version: "v1",
        resource: "nodes",
        kind: "Node",
        namespaced: false
    )

    private static func provider(
        rpc: FakeOptionalResourceCatalogRPC
    ) -> EngineOptionalResourceCatalogProvider {
        EngineOptionalResourceCatalogProvider(
            rpc: rpc,
            timeout: .seconds(4),
            now: { Date(timeIntervalSince1970: 1_000) },
            requestID: { "catalog-request" }
        )
    }

    private static func resource(
        key: String,
        category: Kmgr_V1_OptionalResourceCategory,
        present: Bool,
        displayName: String,
        explicitlyConfigured: Bool = false
    ) -> Kmgr_V1_OptionalResource {
        var result = Kmgr_V1_OptionalResource()
        result.exactKey = key
        result.category = category
        result.present = present
        result.displayName = displayName
        result.applicableResource.version = "v1"
        result.applicableResource.resource = "nodes"
        result.applicableResource.kind = "Node"
        result.applicableResource.namespaced = false
        result.explicitlyConfigured = explicitlyConfigured
        return result
    }
}

private actor FakeOptionalResourceCatalogRPC: OptionalResourceCatalogRPC {
    private let response: Kmgr_V1_DiscoverOptionalResourcesResponse
    private var request: Kmgr_V1_DiscoverOptionalResourcesRequest?
    private var timeout: Duration?

    init(response: Kmgr_V1_DiscoverOptionalResourcesResponse) {
        self.response = response
    }

    func capturedRequest() -> Kmgr_V1_DiscoverOptionalResourcesRequest? { request }
    func capturedTimeout() -> Duration? { timeout }

    func discoverOptionalResources(
        request: Kmgr_V1_DiscoverOptionalResourcesRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_DiscoverOptionalResourcesResponse {
        self.request = request
        self.timeout = timeout
        return response
    }
}
