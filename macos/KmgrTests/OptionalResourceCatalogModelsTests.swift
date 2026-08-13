import Testing
@testable import KmgrCore

@Suite("Optional resource catalog models")
struct OptionalResourceCatalogModelsTests {
    @Test("exact keys remain authoritative when friendly labels collide")
    func exactKeysRemainAuthoritative() {
        let pods = DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true
        )
        let nvidia = OptionalResourceCatalogEntry(
            exactKey: "nvidia.com/gpu",
            category: .accelerator,
            isPresent: true,
            displayName: "GPU",
            applicableResource: pods
        )
        let amd = OptionalResourceCatalogEntry(
            exactKey: "amd.com/gpu",
            category: .accelerator,
            isPresent: true,
            displayName: "GPU",
            applicableResource: pods
        )

        #expect(nvidia.id != amd.id)
        #expect(Set([nvidia, amd]).count == 2)
        #expect(nvidia.displayName == amd.displayName)
    }

    @Test("configured absence and cache coverage remain independent")
    func configuredAbsenceAndCoverage() {
        let nodes = DiscoveredResource(
            group: "",
            version: "v1",
            resource: "nodes",
            kind: "Node",
            namespaced: false
        )
        let configured = OptionalResourceCatalogEntry(
            exactKey: "custom.example/fpga-card",
            category: .accelerator,
            isPresent: false,
            displayName: "FPGA Cards",
            applicableResource: nodes,
            isExplicitlyConfigured: true
        )
        let catalog = OptionalResourceCatalog(
            requestID: "catalog-request",
            resources: [configured],
            nodesCacheAvailable: true,
            podsCacheAvailable: false,
            nodesSnapshotComplete: false,
            podsSnapshotComplete: false,
            potentiallyIncomplete: true
        )

        #expect(catalog.resources == [configured])
        #expect(!configured.isPresent)
        #expect(configured.isExplicitlyConfigured)
        #expect(catalog.nodesCacheAvailable)
        #expect(!catalog.podsCacheAvailable)
        #expect(!catalog.nodesSnapshotComplete)
        #expect(!catalog.podsSnapshotComplete)
        #expect(catalog.potentiallyIncomplete)
    }
}
