import Foundation
import Testing
@testable import KmgrCore

@Suite("Port-forward core models")
struct PortForwardModelsTests {
    @Test("collection rejects stale generations and duplicate sequences")
    func generationGateProtectsCollection() {
        var collection = PortForwardCollection()
        let listening = record(id: "one", state: .listening)
        let failed = record(id: "one", state: .failed)

        #expect(collection.receive(
            cursor: StreamCursor(generation: 2, sequence: 1),
            delta: PortForwardDelta(upserts: [listening])
        ) == .acceptedNewGeneration)
        #expect(collection.receive(
            cursor: StreamCursor(generation: 1, sequence: 99),
            delta: PortForwardDelta(upserts: [failed])
        ) == .ignoredStaleGeneration)
        #expect(collection.receive(
            cursor: StreamCursor(generation: 2, sequence: 1),
            delta: PortForwardDelta(upserts: [failed])
        ) == .ignoredStaleOrDuplicateSequence)
        #expect(collection.recordsByID["one"]?.state == .listening)
    }

    @Test("new generations replace sequencing and apply removals")
    func appliesNewGenerationAndRemoval() {
        var collection = PortForwardCollection(records: [record(id: "old", state: .stopped)])
        collection.receive(
            cursor: StreamCursor(generation: 4, sequence: 8),
            delta: PortForwardDelta(upserts: [record(id: "live", state: .starting)])
        )
        collection.receive(
            cursor: StreamCursor(generation: 5, sequence: 1),
            delta: PortForwardDelta(removedIDs: ["old"])
        )
        #expect(collection.recordsByID["old"] == nil)
        #expect(collection.activeCount == 1)
    }

    @Test("active and failure summaries ignore exposure metadata")
    func computesPresentationSummary() {
        let exposure = ClusterManagerIssue(
            category: .internalFailure,
            reason: "NonLoopbackBind",
            message: "Accessible beyond this Mac.",
            safeDetails: ["exposure_warning": "non_loopback_bind"]
        )
        var broad = record(id: "broad", state: .listening)
        broad.exposesBeyondLocalMachine = true
        broad.lastIssue = exposure
        let collection = PortForwardCollection(records: [
            broad,
            record(id: "retry", state: .reconnecting),
            record(id: "failed", state: .failed),
            record(id: "stopped", state: .stopped),
        ])

        #expect(collection.activeCount == 2)
        #expect(collection.hasFailure)
        #expect(collection.recordsByID["broad"]?.address == "127.0.0.1:8080")
    }

    @Test("retention stays bounded and prioritizes active records")
    func boundedRetention() {
        var collection = PortForwardCollection(maximumRetainedRecords: 2)
        collection.receive(
            cursor: StreamCursor(generation: 1, sequence: 1),
            delta: PortForwardDelta(upserts: [
                record(id: "old-stopped", state: .stopped, updatedAt: 1),
                record(id: "new-stopped", state: .stopped, updatedAt: 3),
                record(id: "active", state: .listening, updatedAt: 2),
            ])
        )
        #expect(collection.recordsByID.count == 2)
        #expect(collection.recordsByID["active"] != nil)
        #expect(collection.recordsByID["new-stopped"] != nil)
    }

    private func record(
        id: String,
        state: PortForwardState,
        updatedAt: TimeInterval = 2
    ) -> PortForwardRecord {
        PortForwardRecord(
            id: id,
            clusterSessionID: "session-one",
            contextName: "production",
            target: ResourceIdentity(
                clusterSessionID: "session-one",
                group: "",
                version: "v1",
                resource: "services",
                namespace: "apps",
                name: "api",
                uid: "uid-api"
            ),
            remotePort: 80,
            localPort: 8080,
            bindAddress: "127.0.0.1",
            state: state,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
