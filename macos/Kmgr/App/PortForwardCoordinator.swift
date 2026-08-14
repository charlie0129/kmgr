import Foundation
import KmgrCore

/// One main-actor owner for the app-wide manager state. Cluster workspaces and
/// the manager window observe the same compact snapshot; listener ownership
/// remains in the helper process.
@MainActor
final class PortForwardCoordinator {
    struct Snapshot: Sendable {
        var records: [PortForwardRecord]
        var activeCount: Int
        var hasFailure: Bool
        var connectionIssue: ClusterManagerIssue?
        var isWatching: Bool
        var helperGenerationAvailable: Bool
    }

    private let provider: any PortForwardProviding
    private let streamID = UUID().uuidString.lowercased()
    private var collection: PortForwardCollection
    private var anchorSessionID = ""
    private var generation: UInt64 = 0
    private var watchTask: Task<Void, Never>?
    private var clusterPresentationsBySessionID: [String: ClusterIdentityPresentation] = [:]
    private var observers: [UUID: @MainActor (Snapshot) -> Void] = [:]
    private(set) var connectionIssue: ClusterManagerIssue?
    private(set) var isWatching = false

    init(
        provider: any PortForwardProviding,
        maximumRetainedRecords: Int = 512
    ) {
        self.provider = provider
        self.collection = PortForwardCollection(
            maximumRetainedRecords: maximumRetainedRecords
        )
    }

    var snapshot: Snapshot {
        Snapshot(
            records: collection.records,
            activeCount: collection.activeCount,
            hasFailure: collection.hasFailure,
            connectionIssue: connectionIssue,
            isWatching: isWatching,
            helperGenerationAvailable: !anchorSessionID.isEmpty
        )
    }

    var activeRecords: [PortForwardRecord] {
        collection.records.filter { $0.state.isActive }
    }

    var hasActiveForwards: Bool { collection.activeCount > 0 }

    /// List/Watch are app-wide but the protocol requires a nonempty request
    /// context. Keep the newest opened session as an authorization anchor even
    /// after its workspace closes; independent streams outlive that window.
    func register(session: OpenedClusterSession) {
        clusterPresentationsBySessionID[session.sessionID] = ClusterIdentityPresentation(
            session: session
        )
        register(sessionID: session.sessionID)
    }

    func register(sessionID: String) {
        let value = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        anchorSessionID = value
        guard watchTask == nil else { return }
        startWatching()
    }

    /// Helper-owned listeners are gone after an unexpected process exit and
    /// must never be recreated silently. Keep the records visible as failed
    /// explanations, stop retrying with the dead session, and wait for a fresh
    /// workspace registration before watching the new empty manager.
    func engineDidDisconnect(message: String) {
        watchTask?.cancel()
        watchTask = nil
        anchorSessionID = ""
        isWatching = false
        let issue = ClusterManagerIssue(
            category: .unavailable,
            reason: "EngineRestarted",
            message: "The Kubernetes engine restarted. This port-forward was not restored automatically. \(message)",
            retryable: false,
            operation: "port-forward"
        )
        let failed = collection.records.map { record in
            guard record.state.isActive else { return record }
            var record = record
            record.state = .failed
            record.updatedAt = Date()
            record.lastIssue = issue
            return record
        }
        collection.replace(with: failed)
        connectionIssue = issue
        publish()
    }

    @discardableResult
    func observe(_ observer: @escaping @MainActor (Snapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    func stop(_ record: PortForwardRecord) async throws {
        try await provider.stopPortForward(
            id: record.id,
            sessionID: record.clusterSessionID
        )
    }

    func restart(_ record: PortForwardRecord) async throws {
        if record.lastIssue?.reason == "EngineRestarted" {
            throw ClusterManagerIssue(
                category: .conflict,
                reason: "EngineRestarted",
                message: "This port-forward belonged to the previous engine generation and cannot be restarted. Start a new port-forward from the current object view.",
                retryable: false,
                contextName: record.contextName,
                operation: "restart port-forward"
            )
        }
        try await provider.restartPortForward(
            id: record.id,
            sessionID: record.clusterSessionID
        )
    }

    func start(_ request: StartPortForwardRequest) async throws -> String {
        register(sessionID: request.target.clusterSessionID)
        return try await provider.startPortForward(request)
    }

    func stopAllActive() async {
        for record in activeRecords {
            try? await provider.stopPortForward(
                id: record.id,
                sessionID: record.clusterSessionID
            )
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        isWatching = false
    }

    private func startWatching() {
        watchTask?.cancel()
        guard !anchorSessionID.isEmpty else { return }
        let sessionID = anchorSessionID
        watchTask = Task { [weak self, provider, streamID] in
            var retry = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    isWatching = false
                    let listed = try await provider.listPortForwards(
                        sessionID: sessionID,
                        includeStopped: true
                    )
                    guard !Task.isCancelled else { return }
                    // A fresh helper has no knowledge of listeners owned by
                    // the crashed generation. Retain those explicit failure
                    // tombstones so the user can see what was not restored.
                    let previousGeneration = collection.records.filter {
                        $0.lastIssue?.reason == "EngineRestarted"
                    }
                    collection.replace(with: presented(listed) + previousGeneration)
                    connectionIssue = nil
                    publish()

                    generation &+= 1
                    if generation == 0 { generation = 1 }
                    let request = PortForwardWatchRequest(
                        sessionID: sessionID,
                        streamID: streamID,
                        generation: generation,
                        includeStopped: true
                    )
                    isWatching = true
                    publish()
                    for try await event in provider.watchPortForwards(request: request) {
                        guard !Task.isCancelled else { return }
                        retry = 0
                        receive(event)
                    }
                    guard !Task.isCancelled else { return }
                    throw ClusterManagerIssue(
                        category: .unavailable,
                        reason: "PortForwardWatchEnded",
                        message: "The port-forward manager stream ended. Reconnecting…",
                        retryable: true,
                        operation: "watch port-forwards"
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    isWatching = false
                    connectionIssue = error as? ClusterManagerIssue
                        ?? ClusterManagerIssue(
                            category: .unavailable,
                            reason: "PortForwardWatchUnavailable",
                            message: error.localizedDescription,
                            retryable: true,
                            operation: "watch port-forwards"
                        )
                    publish()
                    let delay = min(5_000, 250 * (1 << min(retry, 4)))
                    retry += 1
                    do {
                        try await Task.sleep(for: .milliseconds(delay))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func receive(_ event: PortForwardWatchEvent) {
        switch event {
        case .delta(let cursor, var delta):
            delta.upserts = presented(delta.upserts)
            let disposition = collection.receive(cursor: cursor, delta: delta)
            guard Self.accepted(disposition) else { return }
            connectionIssue = nil
            publish()
        case .failure(_, let issue):
            let disposition = collection.receive(event)
            guard Self.accepted(disposition) else { return }
            connectionIssue = issue
            publish()
        }
    }

    private func publish() {
        let value = snapshot
        for observer in observers.values { observer(value) }
    }

    private func presented(_ records: [PortForwardRecord]) -> [PortForwardRecord] {
        records.map { record in
            guard let presentation = clusterPresentationsBySessionID[record.clusterSessionID]
            else { return record }
            var record = record
            if record.clusterName.isEmpty {
                record.clusterName = presentation.clusterName
            }
            if record.contextName.isEmpty {
                record.contextName = presentation.contextName
            }
            return record
        }
    }

    private static func accepted(_ disposition: StreamMessageDisposition) -> Bool {
        disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence
    }
}
