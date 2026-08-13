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
