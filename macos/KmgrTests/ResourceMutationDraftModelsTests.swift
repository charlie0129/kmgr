import Foundation
import Testing
@testable import KmgrCore

@Test func metadataParserPreservesAnnotationValuesWithoutCommaOrEqualsAmbiguity() throws {
    let changes = try ResourceMetadataDraftParser.changes(
        labels: """
            app.kubernetes.io/name=api
            team=platform
            empty=
            """,
        annotations: """
            example.com/query=a=b,c=d
            note= free form, including = signs␠
            """,
        removeLabels: "old.example.com/name\nlegacy",
        removeAnnotations: "old.example.com/note"
    )

    #expect(changes.labels == [
        "app.kubernetes.io/name": "api",
        "team": "platform",
        "empty": "",
    ])
    #expect(changes.annotations["example.com/query"] == "a=b,c=d")
    #expect(changes.annotations["note"] == " free form, including = signs␠")
    #expect(changes.removeLabelKeys == ["old.example.com/name", "legacy"])
    #expect(changes.removeAnnotationKeys == ["old.example.com/note"])
}

@Test func metadataParserMatchesKubernetesQualifiedNameAndLabelRules() {
    let invalid: [(String, ResourceMutationDraftError.Reason)] = [
        ("Upper.Example/key=value", .invalidMetadataKey),
        ("example.com/=value", .invalidMetadataKey),
        ("bad key=value", .invalidMetadataKey),
        ("team=contains spaces", .invalidLabelValue),
        ("team=-leading", .invalidLabelValue),
        ("team=trailing-", .invalidLabelValue),
    ]
    for (line, reason) in invalid {
        do {
            _ = try ResourceMetadataDraftParser.changes(
                labels: line,
                annotations: "",
                removeLabels: "",
                removeAnnotations: ""
            )
            Issue.record("Accepted invalid metadata line \(line)")
        } catch let error as ResourceMutationDraftError {
            #expect(error.reason == reason)
        } catch {
            Issue.record("Unexpected error type \(error)")
        }
    }
}

@Test func metadataParserRejectsDuplicatesConflictsAndEmptyDrafts() {
    let cases: [(labels: String, remove: String, reason: ResourceMutationDraftError.Reason)] = [
        ("team=one\nteam=two", "", .duplicateKey),
        ("team=one", "team", .conflictingChange),
        ("", "team\nteam", .duplicateKey),
        ("", "", .noChanges),
    ]
    for value in cases {
        do {
            _ = try ResourceMetadataDraftParser.changes(
                labels: value.labels,
                annotations: "",
                removeLabels: value.remove,
                removeAnnotations: ""
            )
            Issue.record("Accepted invalid metadata draft")
        } catch let error as ResourceMutationDraftError {
            #expect(error.reason == value.reason)
        } catch {
            Issue.record("Unexpected error type \(error)")
        }
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
