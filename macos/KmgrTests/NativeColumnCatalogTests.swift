import Foundation
import Testing
@testable import KmgrCore

@Test func sharedNativeColumnContractMatchesSwiftCatalog() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tests/fixtures/native-columns-contract.json")
    let fixture = try JSONDecoder().decode(
        ColumnsConfigurationDocument.self,
        from: Data(contentsOf: fixtureURL)
    )

    struct Contract: Hashable {
        var source: ColumnSource
        var value: String
        var type: ColumnResultType
    }
    let fixtureContracts = Set(fixture.views.flatMap(\.columns).compactMap { column in
        column.value.map { Contract(source: column.source, value: $0, type: column.type) }
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
    #expect(nodes.contains(where: { $0.value == "cpu" && $0.type == .resourceUsage }))
    #expect(nodes.first(where: { $0.value == "ephemeral-storage" })?.isEnabled == false)
    #expect(!nodes.contains(where: { $0.value == "ready" || $0.value == "node" }))

    let custom = NativeColumnCatalog.defaultDefinitions(
        group: "example.test", version: "v1", resource: "pods", namespaced: true
    )
    #expect(custom.map(\.value) == ["namespace", "name", "status", "age"])
}

@Test func legacyNativeTypeMigrationIsNarrowAndIdempotent() {
    var document = ColumnsConfigurationDocument(views: [
        ResourceColumnConfiguration(
            match: ColumnResourceMatch(version: "v1", resource: "pods"),
            columns: [
                ColumnDefinition(
                    id: "ready", title: "Ready", source: .builtin,
                    value: "ready", type: .number
                ),
                ColumnDefinition(
                    id: "age", title: "Age", source: .builtin,
                    value: "age", type: .timestamp
                ),
                ColumnDefinition(
                    id: "custom-ready", title: "Custom", source: .builtin,
                    value: "ready", type: .number
                ),
            ]
        ),
    ])
    #expect(NativeColumnCatalog.normalizeLegacyTypes(in: &document))
    #expect(document.views[0].columns[0].type == .string)
    #expect(document.views[0].columns[1].type == .duration)
    #expect(document.views[0].columns[2].type == .number)
    #expect(!NativeColumnCatalog.normalizeLegacyTypes(in: &document))
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
    #expect(nodeValues.contains("pod-count"))
    #expect(!nodeValues.contains("ready"))

    let customValues = Set(NativeColumnCatalog.items(
        group: "example.test", version: "v1", resource: "widgets", existingColumns: []
    ).map(\.descriptor.value))
    #expect(customValues.contains("name"))
    #expect(!customValues.contains("cpu"))
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
