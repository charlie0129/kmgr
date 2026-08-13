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
