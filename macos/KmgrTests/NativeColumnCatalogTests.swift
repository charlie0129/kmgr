import Foundation
import Testing
@testable import KmgrCore

@Test func sharedNativeColumnContractMatchesSwiftCatalog() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/native-columns-contract.json")
    struct Fixture: Decodable {
        struct Column: Decodable {
            var source: ColumnSource
            var value: String
            var type: ColumnResultType
        }
        var columns: [Column]
    }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))

    struct Contract: Hashable {
        var source: ColumnSource
        var value: String
        var type: ColumnResultType
    }
    let fixtureContracts = Set(fixture.columns.map { column in
        Contract(source: column.source, value: column.value, type: column.type)
    })
    let catalogContracts = Set(NativeColumnCatalog.descriptors.map {
        Contract(source: $0.source, value: $0.value, type: $0.type)
    })
    #expect(fixtureContracts == catalogContracts)
}

@Test func nativeDefaultLayoutsUseCanonicalTypesAndResourceScopes() throws {
    let pods = NativeColumnCatalog.defaultDefinitions(
        group: "", version: "v1", resource: "pods", namespaced: true
    )
    #expect(pods.first(where: { $0.value == "ready" })?.type == .string)
    #expect(pods.first(where: { $0.value == "age" })?.type == .duration)
    #expect(pods.first(where: { $0.value == "ephemeral-storage" })?.isEnabled == false)
    #expect(pods.allSatisfy { definition in
        guard let value = definition.value,
            let descriptor = NativeColumnCatalog.descriptor(
                source: definition.source, value: value
            )
        else { return false }
        return descriptor.type == definition.type && descriptor.resourceScope.supports(
            group: "", version: "v1", resource: "pods"
        )
    })

    let nodes = NativeColumnCatalog.defaultDefinitions(
        group: "", version: "v1", resource: "nodes", namespaced: false
    )
    #expect(nodes.filter(\.isEnabled).map(\.value) == [
        "name", "status", "roles", "taints", "internal-ip", "kubelet-version",
        "cpu", "memory", "age",
    ])
    #expect(nodes.first(where: { $0.value == "roles" })?.type == .string)
    #expect(nodes.first(where: { $0.value == "taints" })?.type == .integer)
    #expect(nodes.first(where: { $0.value == "internal-ip" })?.type == .string)
    #expect(nodes.contains(where: { $0.value == "cpu" && $0.type == .resourceUsage }))
    #expect(nodes.first(where: { $0.value == "ephemeral-storage" })?.isEnabled == false)
    #expect(nodes.first(where: { $0.value == "os-image" })?.isEnabled == false)
    #expect(!nodes.contains(where: { $0.value == "ready" || $0.value == "node" }))

    let deployments = NativeColumnCatalog.defaultDefinitions(
        group: "apps", version: "v1", resource: "deployments", namespaced: true
    )
    #expect(deployments.filter(\.isEnabled).map(\.value) == [
        "namespace", "name", "ready", "up-to-date", "available", "age",
    ])
    #expect(deployments.first(where: { $0.value == "selector" })?.isEnabled == false)

    let custom = NativeColumnCatalog.defaultDefinitions(
        group: "example.test", version: "v1", resource: "widgets", namespaced: true
    )
    #expect(custom.filter(\.isEnabled).map(\.value) == ["namespace", "name", "age"])
    #expect(!NativeColumnCatalog.hasCuratedDefinitions(
        group: "example.test", version: "v1", resource: "widgets"
    ))

    let oneNamespace = NativeColumnCatalog.defaultDefinitions(
        group: "", version: "v1", resource: "pods", namespaced: true,
        showNamespace: false
    )
    #expect(oneNamespace.first(where: { $0.value == "namespace" })?.isEnabled == false)
}

@Test func nativePickerCatalogFiltersByExactGVRAndMarksExtractorDuplicates() {
    let existing = [
        ColumnDefinition(
            id: "cpu-custom-id", title: "Processor", source: .metric,
            value: "cpu", type: .resourceUsage
        ),
        ColumnDefinition(
            id: "status", title: "Custom Status", source: .cel,
            expression: "object.status.phase", type: .string
        ),
    ]
    let podItems = NativeColumnCatalog.items(
        group: "", version: "v1", resource: "pods", existingColumns: existing
    )
    #expect(podItems.contains { $0.descriptor.value == "ready" })
    #expect(!podItems.contains { $0.descriptor.value == "pod-count" })
    #expect(podItems.first { $0.descriptor.value == "cpu" }?.isAlreadyAdded == true)
    #expect(podItems.first { $0.descriptor.value == "status" }?.isAlreadyAdded == true)
    #expect(podItems.first { $0.descriptor.value == "memory" }?.isAlreadyAdded == false)
    #expect(podItems.first { $0.descriptor.value == "memory" }?.exactIdentity == "metric:memory")

    let nodeValues = Set(NativeColumnCatalog.items(
        group: "", version: "v1", resource: "nodes", existingColumns: []
    ).map(\.descriptor.value))
    #expect(!nodeValues.contains("pod-count"))
    #expect(nodeValues.isSuperset(of: ["roles", "taints", "internal-ip", "os-image"]))
    #expect(!nodeValues.contains("ready"))

    let deploymentValues = Set(NativeColumnCatalog.items(
        group: "apps", version: "v1", resource: "deployments", existingColumns: []
    ).map(\.descriptor.value))
    #expect(deploymentValues.contains("ready"))
    #expect(!deploymentValues.contains("replicas"))

    let customValues = Set(NativeColumnCatalog.items(
        group: "example.test", version: "v1", resource: "widgets", existingColumns: []
    ).map(\.descriptor.value))
    #expect(customValues.contains("name"))
    #expect(!customValues.contains("cpu"))
    #expect(!customValues.contains("desired"))
}

@Test func exactResourceDefinitionsValidateAndPreserveFullQualifiedIdentity() throws {
    let resources = [
        "hugepages-2Mi",
        "hugepages-1Gi",
        "nvidia.com/gpu",
        "aliyun.com/ppu",
        "example.com/vendor_gpu.v2",
    ]
    var definitions: [ColumnDefinition] = []
    for resourceName in resources {
        let definition = try NativeColumnCatalog.exactResourceDefinition(
            resourceName: "  \(resourceName)  ",
            group: "", version: "v1", resource: "pods"
        )
        #expect(definition.id == NativeColumnCatalog.exactResourceColumnID(
            resourceName: resourceName
        ))
        #expect(definition.title == resourceName)
        #expect(definition.source == .metric)
        #expect(definition.value == "resource:\(resourceName)")
        #expect(definition.type == .resourceUsage)
        #expect(!definition.isEnabled)
        definitions.append(definition)
    }
    #expect(Set(definitions.map(\.id)).count == resources.count)

    let titled = try NativeColumnCatalog.exactResourceDefinition(
        resourceName: "aliyun.com/ppu", title: "PPU",
        group: "", version: "v1", resource: "nodes"
    )
    #expect(titled.title == "PPU")
    #expect(titled.id == NativeColumnCatalog.exactResourceColumnID(
        resourceName: "aliyun.com/ppu"
    ))
    #expect(titled.value == "resource:aliyun.com/ppu")
    #expect(
        NativeColumnCatalog.exactResourceColumnID(resourceName: "vendor-a.example/gpu") !=
            NativeColumnCatalog.exactResourceColumnID(resourceName: "vendor-b.example/gpu")
    )
}

@Test func exactResourceValidationMatchesKubernetesQualifiedNameBoundaries() {
    let valid = [
        "cpu", "hugepages-2Mi", "nvidia.com/gpu", "example.io/a_b.c-D",
        String(repeating: "a", count: 63),
        "\(String(repeating: "a", count: 63)).\(String(repeating: "b", count: 63)).com/gpu",
    ]
    for value in valid {
        #expect(KubernetesQualifiedName.isValid(value), "Expected valid: \(value)")
    }
    let invalid = [
        "", "/gpu", "nvidia.com/", "bad/resource/name", "Upper.Example/gpu",
        "nvidia.com/-gpu", "nvidia.com/gpu-", "nvidia_com/gpu", "has space",
        String(repeating: "a", count: 64),
        "\(String(repeating: "a", count: 64)).com/gpu",
    ]
    for value in invalid {
        #expect(!KubernetesQualifiedName.isValid(value), "Expected invalid: \(value)")
        #expect(throws: NativeColumnCatalogError.self) {
            try NativeColumnCatalog.exactResourceDefinition(
                resourceName: value,
                group: "", version: "v1", resource: "pods"
            )
        }
    }
    #expect(throws: NativeColumnCatalogError.exactResourcesUnsupported) {
        try NativeColumnCatalog.exactResourceDefinition(
            resourceName: "nvidia.com/gpu",
            group: "apps", version: "v1", resource: "deployments"
        )
    }
}
