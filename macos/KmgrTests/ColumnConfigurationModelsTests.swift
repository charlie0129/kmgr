import Foundation
import Testing
@testable import KmgrCore

@Test func validColumnConfigurationRoundTripsWithBackendSchemaNames() throws {
    let document = ColumnsConfigurationDocument(
        views: [ResourceColumnConfiguration(
            match: ColumnResourceMatch(version: "v1", resource: "pods"),
            columns: [
                ColumnDefinition(
                    id: "team",
                    title: "Team",
                    source: .cel,
                    expression: #"object.?metadata.?labels[?"team"].orValue("—")"#,
                    type: .string,
                    alignment: .leading,
                    missing: "—",
                    width: 120,
                    listJoiner: " · "
                ),
                ColumnDefinition(
                    id: "cpu",
                    title: "CPU",
                    source: .metric,
                    value: "pod.cpu.usageRequestLimit",
                    type: .resourceUsage
                ),
            ]
        )],
        accelerators: AcceleratorColumnConfiguration(
            autoDetectSuffixes: ["/gpu", "/ppu", "/dcu"],
            resources: [
                "aliyun.com/ppu": AcceleratorResourceConfiguration(displayName: "PPU"),
            ]
        )
    )
    #expect(document.validationIssues().isEmpty)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["apiVersion"] as? String == ColumnConfigurationSchema.apiVersion)
    #expect(object["celEnvironment"] as? String == ColumnConfigurationSchema.celEnvironment)
    let accelerators = try #require(object["accelerators"] as? [String: Any])
    let resources = try #require(accelerators["resources"] as? [String: Any])
    #expect(resources["aliyun.com/ppu"] != nil)
    #expect(try JSONDecoder().decode(ColumnsConfigurationDocument.self, from: data) == document)
}

@Test func columnConfigurationRejectsVersionDriftAndStructuralAmbiguity() {
    let badColumn = ColumnDefinition(
        id: "duplicate",
        title: "",
        source: .cel,
        expression: "",
        value: "not-allowed",
        type: .string,
        width: -.infinity
    )
    let match = ColumnResourceMatch(version: "", resource: "")
    let document = ColumnsConfigurationDocument(
        apiVersion: "future",
        celEnvironment: "future",
        views: [
            ResourceColumnConfiguration(match: match, columns: [badColumn, badColumn]),
            ResourceColumnConfiguration(match: match, columns: []),
        ]
    )
    let paths = Set(document.validationIssues().map(\.path))
    #expect(paths.contains("apiVersion"))
    #expect(paths.contains("celEnvironment"))
    #expect(paths.contains("views[0].match.version"))
    #expect(paths.contains("views[0].match.resource"))
    #expect(paths.contains("views[0].columns[0].expression"))
    #expect(paths.contains("views[0].columns[0].value"))
    #expect(paths.contains("views[0].columns[0].width"))
    #expect(paths.contains("views[0].columns[1].id"))
    #expect(paths.contains("views[1].match"))
}

@Test func resourceColumnDraftEnablesReordersAddsAndResetsWithoutTouchingIdentity() throws {
    let name = ColumnDefinition(
        id: "name", title: "Name", source: .cel,
        expression: "object.metadata.name", type: .string
    )
    let status = ColumnDefinition(
        id: "status", title: "Status", source: .builtin,
        value: "pod.status", type: .string
    )
    let match = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
    var draft = ResourceColumnDraft(match: match, columns: [name, status])
    let enabled = draft.setEnabled(false, columnID: "status")
    #expect(enabled)
    let moved = draft.move(columnID: "status", to: 0)
    #expect(moved)
    try draft.appendCEL(ColumnDefinition(
        id: "node", title: "Node", source: .cel,
        expression: #"object.?spec.?nodeName.orValue("—")"#, type: .string
    ))
    #expect(draft.match == match)
    #expect(draft.columns.map(\.id) == ["status", "name", "node"])
    #expect(!draft.columns[0].isEnabled)
    #expect(throws: ColumnDraftError.invalidOrDuplicateCELColumn) {
        try draft.appendCEL(name)
    }
    draft.reset(to: [name])
    #expect(draft.columns == [name])
    #expect(draft.match == match)
}

@Test func resourceColumnDraftAddsDisabledNativeColumnsByExactExtractorIdentity() throws {
    let match = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
    let cpu = try #require(NativeColumnCatalog.descriptor(source: .metric, value: "cpu"))
        .definition(enabled: false)
    var draft = ResourceColumnDraft(match: match, columns: [])
    #expect(draft.canAppendNative(cpu))
    try draft.appendNative(cpu)
    #expect(draft.columns == [cpu])
    #expect(!draft.columns[0].isEnabled)
    #expect(draft.containsNativeColumn(source: .metric, value: "cpu"))

    let aliasedCPU = ColumnDefinition(
        id: "processor", title: "Processor", source: .metric,
        value: "cpu", type: .resourceUsage, enabled: false
    )
    #expect(!draft.canAppendNative(aliasedCPU))
    #expect(throws: ColumnDraftError.invalidOrDuplicateNativeColumn) {
        try draft.appendNative(aliasedCPU)
    }

    let ppu = try NativeColumnCatalog.exactResourceDefinition(
        resourceName: "aliyun.com/ppu", title: "PPU",
        group: "", version: "v1", resource: "pods"
    )
    let gpu = try NativeColumnCatalog.exactResourceDefinition(
        resourceName: "nvidia.com/gpu", title: "GPU",
        group: "", version: "v1", resource: "pods"
    )
    try draft.appendNative(ppu)
    try draft.appendNative(gpu)
    #expect(draft.columns.map(\.value) == [
        "cpu", "resource:aliyun.com/ppu", "resource:nvidia.com/gpu",
    ])
    #expect(Set(draft.columns.map(\.id)).count == 3)
}
