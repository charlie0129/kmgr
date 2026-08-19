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
    #expect(json.contains("columns") == false)
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
    #expect(CommandValidator.isEnabled(.editMetadata, in: one))
    #expect(CommandValidator.isEnabled(.editMetadata, in: many) == false)
    #expect(CommandValidator.isEnabled(.copyName, in: many))
    #expect(CommandValidator.isEnabled(.copyNamespacedName, in: none) == false)
    #expect(CommandValidator.isEnabled(.copyReference, in: many))
}

@Test func workloadCommandsValidateExactResourceCompatibility() {
    var deployment = identity("deployment")
    deployment.group = "apps"
    deployment.resource = "deployments"
    var daemonSet = deployment
    daemonSet.resource = "daemonsets"
    var pod = identity("pod")
    pod.resource = "pods"

    let context: (ResourceIdentity) -> CommandContext = { value in
        CommandContext(firstResponder: .resourceTable, selectedIdentities: [value])
    }
    #expect(CommandValidator.isEnabled(.scale, in: context(deployment)))
    #expect(CommandValidator.isEnabled(.restart, in: context(deployment)))
    #expect(CommandValidator.isEnabled(.scale, in: context(daemonSet)) == false)
    #expect(CommandValidator.isEnabled(.restart, in: context(daemonSet)))
    #expect(CommandValidator.isEnabled(.scale, in: context(pod)) == false)
    #expect(CommandValidator.isEnabled(.restart, in: context(pod)) == false)
}

@Test func commandSaveBelongsOnlyToActiveDirtyEditor() {
    let dirtyYAML = CommandContext(firstResponder: .yamlEditor, activeEditorHasChanges: true)
    let cleanYAML = CommandContext(firstResponder: .yamlEditor, activeEditorHasChanges: false)
    let table = CommandContext(firstResponder: .resourceTable, activeEditorHasChanges: true)

    #expect(CommandValidator.isEnabled(.save, in: dirtyYAML))
    #expect(CommandValidator.isEnabled(.save, in: cleanYAML) == false)
    #expect(CommandValidator.isEnabled(.save, in: table) == false)
}
