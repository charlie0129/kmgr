import Foundation
import Testing
@testable import KmgrCore

@Test func restorationModelContainsOnlyAllowListedLightweightState() throws {
    let secretSentinel = "never-persist-this-secret"
    let secret = SensitiveBytes(Data(secretSentinel.utf8))
    let restoration = ClusterWindowRestorationState(
        contextName: "production",
        gvr: GVR(group: "", version: "v1", resource: "secrets"),
        namespaceScope: .namespace("payments"),
        filter: "name:api",
        sort: [SortDescriptorState(columnID: "name", ascending: true)],
        columns: [ColumnPresentationState(columnID: "name", width: 240)],
        scrollAnchor: ScrollAnchor(uid: "uid-1", pixelOffsetFromTop: 6, priorRowIndex: 12)
    )

    let encoded = try JSONEncoder().encode(restoration)
    let json = String(decoding: encoded, as: UTF8.self)
    let decoded = try JSONDecoder().decode(ClusterWindowRestorationState.self, from: encoded)

    #expect(decoded == restoration)
    #expect(secret.count == secretSentinel.utf8.count)
    #expect(json.contains(secretSentinel) == false)
    #expect(json.contains("rawObject") == false)
    #expect(json.contains("rows") == false)
}

@Test func secretDiagnosticRecordsMetadataButNotValue() throws {
    let sentinel = "top-secret-value"
    let diagnostic = KeyValueEditorDiagnostic(
        resourceKind: .secret,
        namespace: "payments",
        name: "database",
        key: "password",
        byteCount: sentinel.utf8.count,
        hasUnsavedChanges: true
    )

    let data = try JSONEncoder().encode(diagnostic)
    let encoded = String(decoding: data, as: UTF8.self)

    #expect(encoded.contains("database"))
    #expect(encoded.contains("password"))
    #expect(encoded.contains(sentinel) == false)
}

@Test func sensitiveBytesCanBeReplacedWithoutExposingStorage() {
    let bytes = SensitiveBytes(Data("old".utf8))
    #expect(bytes.count == 3)
    bytes.replacing(with: Data("replacement".utf8))
    #expect(bytes.count == 11)
}

@Test(arguments: [
    ResponderContext.filterField,
    .yamlEditor,
    .keyValueEditor,
    .terminal,
])
func destructiveTableCommandIsDisabledWhileTyping(responder: ResponderContext) {
    let context = CommandContext(
        firstResponder: responder,
        selectedIdentities: [identity("pod-1")]
    )

    #expect(CommandValidator.isEnabled(.delete, in: context) == false)
}

@Test func selectionCardinalityValidatesCommands() {
    let pod = identity("pod-1")
    let secondPod = identity("pod-2")
    let none = CommandContext(firstResponder: .resourceTable)
    let one = CommandContext(
        firstResponder: .resourceTable,
        selectedIdentities: [pod],
        logCompatibleSelection: true,
        execCompatibleSelection: true,
        portForwardCompatibleSelection: true
    )
    let many = CommandContext(
        firstResponder: .resourceTable,
        selectedIdentities: [pod, secondPod],
        logCompatibleSelection: true,
        execCompatibleSelection: true,
        portForwardCompatibleSelection: true
    )

    #expect(CommandValidator.isEnabled(.delete, in: none) == false)
    #expect(CommandValidator.isEnabled(.delete, in: one))
    #expect(CommandValidator.isEnabled(.delete, in: many))
    #expect(CommandValidator.isEnabled(.openDetails, in: one))
    #expect(CommandValidator.isEnabled(.openDetails, in: many) == false)
    #expect(CommandValidator.isEnabled(.openExec, in: one))
    #expect(CommandValidator.isEnabled(.openExec, in: many) == false)
    #expect(CommandValidator.isEnabled(.startPortForward, in: one))
    #expect(CommandValidator.isEnabled(.startPortForward, in: many) == false)
    #expect(CommandValidator.isEnabled(.openLogs, in: many))
}

@Test func commandSaveBelongsOnlyToActiveDirtyEditor() {
    let dirtyYAML = CommandContext(firstResponder: .yamlEditor, activeEditorHasChanges: true)
    let cleanYAML = CommandContext(firstResponder: .yamlEditor, activeEditorHasChanges: false)
    let table = CommandContext(firstResponder: .resourceTable, activeEditorHasChanges: true)

    #expect(CommandValidator.isEnabled(.save, in: dirtyYAML))
    #expect(CommandValidator.isEnabled(.save, in: cleanYAML) == false)
    #expect(CommandValidator.isEnabled(.save, in: table) == false)
}
