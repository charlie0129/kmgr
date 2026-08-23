import Foundation
import Testing
@testable import KmgrCore

@Test func metadataDraftBuildsOneSparseKindSpecificMutation() throws {
    var draft = ResourceMetadataDraft(
        kind: .labels,
        baselineValues: ["team": "platform", "legacy": "true"]
    )
    draft.setValue("runtime", for: "team")
    draft.removeKey("legacy")
    try draft.addKey("app", value: "api")
    try draft.renameKey("app", to: "app.kubernetes.io/name")

    let changes = try draft.changes()
    #expect(changes.labels == [
        "app.kubernetes.io/name": "api",
        "team": "runtime",
    ])
    #expect(changes.removeLabelKeys == ["legacy"])
    #expect(changes.annotations.isEmpty)
    #expect(changes.removeAnnotationKeys.isEmpty)
}

@Test func labelsAndAnnotationsKeepSameNamedKeysIndependent() throws {
    var labels = ResourceMetadataDraft(
        kind: .labels,
        baselineValues: ["owner": "platform"]
    )
    var annotations = ResourceMetadataDraft(
        kind: .annotations,
        baselineValues: ["owner": "Platform Team"]
    )
    labels.setValue("runtime", for: "owner")
    annotations.setValue("Runtime Team\nOn-call: SRE=a,b", for: "owner")

    let labelChanges = try labels.changes()
    let annotationChanges = try annotations.changes()
    #expect(labelChanges.labels == ["owner": "runtime"])
    #expect(labelChanges.annotations.isEmpty)
    #expect(annotationChanges.labels.isEmpty)
    #expect(annotationChanges.annotations == [
        "owner": "Runtime Team\nOn-call: SRE=a,b",
    ])
}

@Test func metadataDraftSupportsRenameDeleteAndPerKeyRevert() throws {
    var draft = ResourceMetadataDraft(
        kind: .annotations,
        baselineValues: ["old.example.com/note": "before", "keep": "same"]
    )
    try draft.renameKey("old.example.com/note", to: "example.com/note")
    #expect(draft.isRenamed("example.com/note"))
    #expect(!draft.isAdded("example.com/note"))
    #expect(draft.changeList == [.init(
        beforeKey: "old.example.com/note",
        afterKey: "example.com/note",
        beforeValue: "before",
        afterValue: "before"
    )])
    try draft.renameKey("example.com/note", to: "old.example.com/note")
    #expect(!draft.hasChanges)
    try draft.renameKey("old.example.com/note", to: "example.com/note")
    draft.revertKey("example.com/note")
    #expect(!draft.hasChanges)
    #expect(throws: ResourceMutationDraftError.self) { try draft.changes() }
}

@Test func metadataDraftAllowsReusingKeysRemovedByStagedChanges() throws {
    var draft = ResourceMetadataDraft(
        kind: .annotations,
        baselineValues: ["old.example.com/a": "a", "old.example.com/b": "b"]
    )
    try draft.renameKey("old.example.com/a", to: "example.com/a")
    try draft.renameKey("old.example.com/b", to: "old.example.com/a")
    #expect(try draft.changes().annotations == [
        "example.com/a": "a",
        "old.example.com/a": "b",
    ])
    #expect(try draft.changes().removeAnnotationKeys == ["old.example.com/b"])

    draft.removeKey("old.example.com/a")
    try draft.addKey("old.example.com/a", value: "replacement")
    #expect(try draft.changes().annotations == [
        "example.com/a": "a",
        "old.example.com/a": "replacement",
    ])
    #expect(try draft.changes().removeAnnotationKeys == ["old.example.com/b"])
}

@Test func metadataDraftRejectsInvalidKeysDuplicatesAndValues() throws {
    for key in ["Upper.Example/key", "example.com/", "bad key"] {
        var draft = ResourceMetadataDraft(kind: .labels)
        do {
            try draft.addKey(key)
            Issue.record("Accepted invalid Kubernetes metadata key \(key)")
        } catch let error as ResourceMutationDraftError {
            #expect(error.reason == .invalidMetadataKey)
        }
    }

    var labels = ResourceMetadataDraft(
        kind: .labels,
        baselineValues: ["team": "platform"]
    )
    #expect(throws: ResourceMutationDraftError.self) {
        try labels.addKey("team")
    }
    for value in ["contains spaces", "-leading", "trailing-"] {
        labels.setValue(value, for: "team")
        do {
            _ = try labels.changes()
            Issue.record("Accepted invalid Kubernetes label value \(value)")
        } catch let error as ResourceMutationDraftError {
            #expect(error.reason == .invalidLabelValue)
        }
    }

    var annotations = ResourceMetadataDraft(kind: .annotations)
    try annotations.addKey("example.com/note", value: "bad\0value")
    do {
        _ = try annotations.changes()
        Issue.record("Accepted a NUL annotation value")
    } catch let error as ResourceMutationDraftError {
        #expect(error.reason == .invalidAnnotationValue)
    }
}

@Test func replicaParserAcceptsOnlyCanonicalBoundedWholeNumbers() throws {
    #expect(try ResourceMutationDraftValidator.replicaCount(" 0 ") == 0)
    #expect(try ResourceMutationDraftValidator.replicaCount("2147483647") == Int32.max)
    for invalid in ["", "-1", "+1", "1.0", "1e3", "2_000", "2147483648"] {
        #expect(throws: ResourceMutationDraftError.self) {
            try ResourceMutationDraftValidator.replicaCount(invalid)
        }
    }
}

@Test func optimisticMutationTargetPinsFreshDetailToSelectedUIDAndResourceVersion() throws {
    let selected = identity(uid: "old-uid")
    let detail = ObjectDetail(identity: selected, resourceVersion: "rv-42")
    let target = try OptimisticResourceMutationTarget(
        selectedIdentity: selected,
        authoritativeDetail: detail
    )
    #expect(target.identity == selected)
    #expect(target.expectedResourceVersion == "rv-42")

    var replacement = selected
    replacement.uid = "new-uid"
    do {
        _ = try OptimisticResourceMutationTarget(
            selectedIdentity: selected,
            authoritativeDetail: ObjectDetail(identity: replacement, resourceVersion: "rv-1")
        )
        Issue.record("Same-name replacement was accepted")
    } catch let error as ResourceMutationDraftError {
        #expect(error.reason == .identityChanged)
    } catch {
        Issue.record("Unexpected error type \(error)")
    }

    #expect(throws: ResourceMutationDraftError.self) {
        try OptimisticResourceMutationTarget(
            selectedIdentity: selected,
            authoritativeDetail: ObjectDetail(identity: selected, resourceVersion: "")
        )
    }
}

@Test func rolloutRestartValidationAcceptsOnlySupportedWorkloads() throws {
    for resource in ["deployments", "statefulsets", "daemonsets"] {
        var value = identity(uid: "uid")
        value.resource = resource
        try ResourceMutationDraftValidator.validateRolloutRestart(value)
    }
    var replicaSet = identity(uid: "uid")
    replicaSet.resource = "replicasets"
    #expect(throws: ResourceMutationDraftError.self) {
        try ResourceMutationDraftValidator.validateRolloutRestart(replicaSet)
    }
}

@Test func deleteConfirmationClassifiesOnlyExactHighImpactGVRs() {
    let values: [(String, String, HighImpactDeleteKind)] = [
        ("", "namespaces", .namespace),
        ("", "nodes", .node),
        ("apiextensions.k8s.io", "customresourcedefinitions", .customResourceDefinition),
        ("", "persistentvolumeclaims", .persistentVolumeClaim),
        ("rbac.authorization.k8s.io", "clusterroles", .clusterRole),
        ("rbac.authorization.k8s.io", "clusterrolebindings", .clusterRoleBinding),
    ]
    for (group, resource, expected) in values {
        var value = identity(uid: ResourceUID(expected.rawValue))
        value.group = group
        value.resource = resource
        #expect(ResourceDeleteConfirmationSummary.highImpactKind(for: value) == expected)
    }

    var lookalike = identity(uid: "custom-node")
    lookalike.group = "example.com"
    lookalike.resource = "nodes"
    #expect(ResourceDeleteConfirmationSummary.highImpactKind(for: lookalike) == nil)
}

@Test func deleteConfirmationReportsCountHiddenTargetsAndHighImpactKinds() {
    var node = identity(uid: "node-1")
    node.group = ""
    node.resource = "nodes"
    node.namespace = ""
    node.name = "worker-a"
    var binding = identity(uid: "binding-1")
    binding.group = "rbac.authorization.k8s.io"
    binding.resource = "clusterrolebindings"
    binding.namespace = ""
    let summary = ResourceDeleteConfirmationSummary(targets: [
        ResourceDeleteTarget(identity: node, hiddenByFilter: true),
        ResourceDeleteTarget(identity: binding),
    ])

    #expect(summary.targetCount == 2)
    #expect(summary.hiddenTargetCount == 1)
    #expect(summary.selectionText.contains("2 exact UID-pinned resources"))
    #expect(summary.selectionText.contains("1 hidden"))
    #expect(summary.highImpactWarningText?.contains("Node (1)") == true)
    #expect(summary.highImpactWarningText?.contains("ClusterRoleBinding (1)") == true)
    #expect(ResourceDeleteConfirmationSummary.displayedGVR(for: node) == "core/v1/nodes")
}

private func identity(uid: ResourceUID) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "production",
        name: "api",
        uid: uid
    )
}
