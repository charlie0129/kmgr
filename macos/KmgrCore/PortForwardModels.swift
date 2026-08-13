import Foundation

public enum PortForwardState: String, Hashable, Codable, Sendable, CaseIterable {
    case starting
    case listening
    case reconnecting
    case failed
    case stopped

    public var isActive: Bool {
        switch self {
        case .starting, .listening, .reconnecting: true
        case .failed, .stopped: false
        }
    }

    public var displayName: String {
        switch self {
        case .starting: "Starting"
        case .listening: "Listening"
        case .reconnecting: "Reconnecting"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// Compact app-wide state for one listener. Kubernetes objects remain owned by
/// the engine; the GUI retains only stable identities and presentation data.
public struct PortForwardRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var clusterSessionID: String
    public var contextName: String
    public var target: ResourceIdentity
    public var resolvedPod: ResourceIdentity?
    public var remotePort: UInt16
    public var localPort: UInt16
    public var bindAddress: String
    public var label: String
    public var state: PortForwardState
    public var startedAt: Date?
    public var updatedAt: Date?
    public var lastIssue: ClusterManagerIssue?
    public var exposesBeyondLocalMachine: Bool

    public init(
        id: String,
        clusterSessionID: String,
        contextName: String,
        target: ResourceIdentity,
        resolvedPod: ResourceIdentity? = nil,
        remotePort: UInt16,
        localPort: UInt16,
        bindAddress: String,
        label: String = "",
        state: PortForwardState,
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        lastIssue: ClusterManagerIssue? = nil,
        exposesBeyondLocalMachine: Bool = false
    ) {
        self.id = id
        self.clusterSessionID = clusterSessionID
        self.contextName = contextName
        self.target = target
        self.resolvedPod = resolvedPod
        self.remotePort = remotePort
        self.localPort = localPort
        self.bindAddress = bindAddress
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastIssue = lastIssue
        self.exposesBeyondLocalMachine = exposesBeyondLocalMachine
    }

    public var address: String? {
        guard localPort > 0 else { return nil }
        let host = bindAddress.isEmpty ? "127.0.0.1" : bindAddress
        return host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]:\(localPort)"
            : "\(host):\(localPort)"
    }
}

public struct StartPortForwardRequest: Hashable, Sendable {
    public var id: String
    public var target: ResourceIdentity
    public var remotePort: UInt16
    public var localPort: UInt16
    public var bindAddress: String
    public var label: String
    public var allowNonLoopback: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        target: ResourceIdentity,
        remotePort: UInt16,
        localPort: UInt16 = 0,
        bindAddress: String = "127.0.0.1",
        label: String = "",
        allowNonLoopback: Bool = false
    ) {
        self.id = id
        self.target = target
        self.remotePort = remotePort
        self.localPort = localPort
        self.bindAddress = bindAddress
        self.label = label
        self.allowNonLoopback = allowNonLoopback
    }
}

public struct PortForwardWatchRequest: Hashable, Sendable {
    public var sessionID: String
    public var streamID: String
    public var generation: UInt64
    public var includeStopped: Bool

    public init(
        sessionID: String,
        streamID: String,
        generation: UInt64,
        includeStopped: Bool = true
    ) {
        self.sessionID = sessionID
        self.streamID = streamID
        self.generation = generation
        self.includeStopped = includeStopped
    }
}

public struct PortForwardDelta: Hashable, Sendable {
    public var upserts: [PortForwardRecord]
    public var removedIDs: Set<String>

    public init(
        upserts: [PortForwardRecord] = [],
        removedIDs: Set<String> = []
    ) {
        self.upserts = upserts
        self.removedIDs = removedIDs
    }
}

public enum PortForwardWatchEvent: Hashable, Sendable {
    case delta(cursor: StreamCursor, value: PortForwardDelta)
    case failure(cursor: StreamCursor, issue: ClusterManagerIssue)

    public var cursor: StreamCursor {
        switch self {
        case .delta(let cursor, _), .failure(let cursor, _): cursor
        }
    }
}

public protocol PortForwardProviding: Sendable {
    func listPortForwards(
        sessionID: String,
        includeStopped: Bool
    ) async throws -> [PortForwardRecord]

    func watchPortForwards(
        request: PortForwardWatchRequest
    ) -> AsyncThrowingStream<PortForwardWatchEvent, Error>

    func startPortForward(_ request: StartPortForwardRequest) async throws -> String
    func stopPortForward(id: String, sessionID: String) async throws
    func restartPortForward(id: String, sessionID: String) async throws
}

/// Pure reducer shared by the app-owned coordinator and focused tests. It
/// bounds retained history and rejects late messages from replaced streams.
public struct PortForwardCollection: Hashable, Sendable {
    public private(set) var recordsByID: [String: PortForwardRecord]
    public private(set) var gate: GenerationSequenceGate
    public let maximumRetainedRecords: Int

    public init(
        records: [PortForwardRecord] = [],
        gate: GenerationSequenceGate = GenerationSequenceGate(),
        maximumRetainedRecords: Int = 512
    ) {
        precondition(maximumRetainedRecords > 0)
        self.recordsByID = Dictionary(
            records.prefix(maximumRetainedRecords).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.gate = gate
        self.maximumRetainedRecords = maximumRetainedRecords
        trimIfNeeded()
    }

    public var records: [PortForwardRecord] {
        recordsByID.values.sorted(by: Self.order)
    }

    public var activeCount: Int {
        recordsByID.values.lazy.filter { $0.state.isActive }.count
    }

    public var hasFailure: Bool {
        recordsByID.values.contains { $0.state == .failed }
    }

    public mutating func replace(with records: [PortForwardRecord]) {
        recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        trimIfNeeded()
    }

    @discardableResult
    public mutating func receive(
        cursor: StreamCursor,
        delta: PortForwardDelta
    ) -> StreamMessageDisposition {
        let disposition = gate.accept(cursor)
        switch disposition {
        case .acceptedNewGeneration, .acceptedNextSequence:
            for id in delta.removedIDs { recordsByID.removeValue(forKey: id) }
            for record in delta.upserts { recordsByID[record.id] = record }
            trimIfNeeded()
        case .ignoredStaleGeneration, .ignoredStaleOrDuplicateSequence:
            break
        }
        return disposition
    }

    @discardableResult
    public mutating func receive(_ event: PortForwardWatchEvent) -> StreamMessageDisposition {
        switch event {
        case .delta(let cursor, let value):
            receive(cursor: cursor, delta: value)
        case .failure(let cursor, _):
            gate.accept(cursor)
        }
    }

    private mutating func trimIfNeeded() {
        guard recordsByID.count > maximumRetainedRecords else { return }
        let orderedForRetention = recordsByID.values.sorted { lhs, rhs in
            if lhs.state.isActive != rhs.state.isActive { return lhs.state.isActive }
            if lhs.state == .failed, rhs.state != .failed { return true }
            if rhs.state == .failed, lhs.state != .failed { return false }
            let lhsDate = lhs.updatedAt ?? lhs.startedAt ?? .distantPast
            let rhsDate = rhs.updatedAt ?? rhs.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
        recordsByID = Dictionary(
            orderedForRetention.prefix(maximumRetainedRecords).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    private static func order(_ lhs: PortForwardRecord, _ rhs: PortForwardRecord) -> Bool {
        let lhsDate = lhs.startedAt ?? .distantPast
        let rhsDate = rhs.startedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id < rhs.id
    }
}
