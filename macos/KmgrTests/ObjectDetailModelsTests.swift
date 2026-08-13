import Foundation
import Testing
@testable import KmgrCore

@Test func relationshipScanCollectionKeepsCachedChildrenUntilComplete() {
    let owner = relationship(.owner, resource: "deployments", name: "api", uid: "owner")
    let cached = relationship(.child, resource: "replicasets", name: "cached", uid: "cached")
    let scanned = relationship(.child, resource: "pods", name: "scanned", uid: "scanned")
    var collection = RelationshipScanCollection(baseline: [owner, cached])

    collection.apply(RelationshipScanMessage(
        scanID: "scan",
        cursor: StreamCursor(generation: 1, sequence: 1),
        relationships: [scanned],
        progress: RelationshipScanProgress()
    ))
    #expect(Set(collection.values.map(\.identity.uid)) == ["owner", "cached", "scanned"])

    collection.apply(RelationshipScanMessage(
        scanID: "scan",
        cursor: StreamCursor(generation: 1, sequence: 2),
        progress: RelationshipScanProgress(complete: true)
    ))
    #expect(Set(collection.values.map(\.identity.uid)) == ["owner", "scanned"])
}

@Test func relationshipScanCollectionDeduplicatesByFullIdentity() {
    let cached = relationship(.child, resource: "pods", name: "api", uid: "shared")
    var otherSession = cached
    otherSession.identity.clusterSessionID = "other-session"
    var replacement = cached
    replacement.label = "authoritative scan"
    replacement.potentiallyIncomplete = false
    var collection = RelationshipScanCollection(baseline: [cached, otherSession])

    collection.apply(RelationshipScanMessage(
        scanID: "scan",
        cursor: StreamCursor(generation: 1, sequence: 1),
        relationships: [replacement],
        progress: RelationshipScanProgress()
    ))

    #expect(collection.values.count == 2)
    #expect(collection.values.first {
        $0.identity.clusterSessionID == "session"
    }?.label == "authoritative scan")
}

private func relationship(
    _ kind: ObjectRelationshipKind,
    resource: String,
    name: String,
    uid: ResourceUID
) -> ObjectRelationship {
    ObjectRelationship(
        kind: kind,
        identity: ResourceIdentity(
            clusterSessionID: "session", group: "", version: "v1",
            resource: resource, namespace: "apps", name: name, uid: uid
        ),
        label: name,
        potentiallyIncomplete: kind == .child
    )
}

@Test func objectDataValueCannotEnterRestorationSchema() throws {
    let sensitive = Data("plain secret".utf8)
    let entry = ObjectDataEntry(
        key: "token", kind: .text, value: sensitive,
        byteSize: UInt64(sensitive.count), contentHash: Data([1, 2, 3])
    )
    #expect(entry.value.count == sensitive.count)

    let restoration = ClusterWindowRestorationState(contextName: "prod")
    let encoded = try JSONEncoder().encode(restoration)
    #expect(!encoded.contains(sensitive))
}

@Test func operationTerminalClassificationIsExplicit() {
    #expect(!OperationState.pending.isTerminal)
    #expect(!OperationState.running.isTerminal)
    #expect(OperationState.succeeded.isTerminal)
    #expect(OperationState.partiallySucceeded.isTerminal)
    #expect(OperationState.failed.isTerminal)
    #expect(OperationState.cancelled.isTerminal)
}
