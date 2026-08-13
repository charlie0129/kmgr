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
    }

    private let provider: any PortForwardProviding
    private let streamID = UUID().uuidString.lowercased()
    private var collection: PortForwardCollection
    private var anchorSessionID = ""
    private var generation: UInt64 = 0
    private var watchTask: Task<Void, Never>?
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
            isWatching: isWatching
        )
    }

    var activeRecords: [PortForwardRecord] {
        collection.records.filter { $0.state.isActive }
    }

    var hasActiveForwards: Bool { collection.activeCount > 0 }

    /// List/Watch are app-wide but the protocol requires a nonempty request
    /// context. Keep the newest opened session as an authorization anchor even
    /// after its workspace closes; independent streams outlive that window.
    func register(sessionID: String) {
        let value = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard value != anchorSessionID || watchTask == nil else { return }
        anchorSessionID = value
        startWatching()
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
                    collection.replace(with: listed)
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
                    try? await Task.sleep(for: .milliseconds(delay))
                }
            }
        }
    }

    private func receive(_ event: PortForwardWatchEvent) {
        switch event {
        case .delta(let cursor, let delta):
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

    private static func accepted(_ disposition: StreamMessageDisposition) -> Bool {
        disposition == .acceptedNewGeneration || disposition == .acceptedNextSequence
    }
}
