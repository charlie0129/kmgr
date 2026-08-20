import Foundation

public enum ClusterOperationState: Hashable, Sendable {
    case active
    case finished
    case failed
    case cancelled
    case timedOut
}

/// Metadata for one Kubernetes HTTP operation, including exact decoded server
/// Status details and the original Go error text when available. Exact Unix
/// nanoseconds are retained separately from Date so equal-looking second-level
/// timestamps still sort in their original high-precision order.
public struct ClusterOperationRecord: Identifiable, Hashable, Sendable {
    public var id: UInt64
    public var state: ClusterOperationState
    public var operation: String
    public var group: String
    public var version: String
    public var resource: String
    public var namespace: String
    public var name: String
    public var subresource: String
    public var httpStatusCode: Int
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var startedAtUnixNanos: Int64
    public var finishedAtUnixNanos: Int64?
    public var errorMessage: String?

    public init(
        id: UInt64,
        state: ClusterOperationState,
        operation: String,
        group: String = "",
        version: String = "",
        resource: String,
        namespace: String = "",
        name: String = "",
        subresource: String = "",
        httpStatusCode: Int = 0,
        bytesReceived: UInt64 = 0,
        bytesSent: UInt64 = 0,
        startedAtUnixNanos: Int64,
        finishedAtUnixNanos: Int64? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.state = state
        self.operation = operation
        self.group = group
        self.version = version
        self.resource = resource
        self.namespace = namespace
        self.name = name
        self.subresource = subresource
        self.httpStatusCode = httpStatusCode
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.startedAtUnixNanos = startedAtUnixNanos
        self.finishedAtUnixNanos = finishedAtUnixNanos
        self.errorMessage = errorMessage
    }
}

public struct ClusterOperationBatch: Hashable, Sendable {
    public var cursor: StreamCursor
    /// Replacement snapshot of every currently active operation.
    public var active: [ClusterOperationRecord]
    /// Only operations completed or corrected since the preceding batch.
    public var completed: [ClusterOperationRecord]
    public var droppedCompleted: UInt64

    public init(
        cursor: StreamCursor,
        active: [ClusterOperationRecord],
        completed: [ClusterOperationRecord],
        droppedCompleted: UInt64 = 0
    ) {
        self.cursor = cursor
        self.active = active
        self.completed = completed
        self.droppedCompleted = droppedCompleted
    }
}

public protocol ClusterOperationHistoryProviding: Sendable {
    func watchOperations(
        sessionID: String,
        streamID: String
    ) -> AsyncThrowingStream<ClusterOperationBatch, Error>
}

public struct ClusterOperationHistorySnapshot: Hashable, Sendable {
    public var active: [ClusterOperationRecord]
    public var completed: [ClusterOperationRecord]
    public var droppedCompleted: UInt64

    public init(
        active: [ClusterOperationRecord] = [],
        completed: [ClusterOperationRecord] = [],
        droppedCompleted: UInt64 = 0
    ) {
        self.active = active
        self.completed = completed
        self.droppedCompleted = droppedCompleted
    }
}

/// Incremental mutation returned to a visible history panel. Keeping this
/// separate from the retained snapshot avoids copying and sorting as many as
/// 100,000 completed records whenever active WATCH byte counters advance.
public struct ClusterOperationHistoryChange: Hashable, Sendable {
    public var active: [ClusterOperationRecord]
    public var completed: [ClusterOperationRecord]
    public var evictedCompletedIDs: [UInt64]
    public var droppedCompleted: UInt64

    public init(
        active: [ClusterOperationRecord] = [],
        completed: [ClusterOperationRecord] = [],
        evictedCompletedIDs: [UInt64] = [],
        droppedCompleted: UInt64 = 0
    ) {
        self.active = active
        self.completed = completed
        self.evictedCompletedIDs = evictedCompletedIDs
        self.droppedCompleted = droppedCompleted
    }
}

/// Actor-backed bounded retention for one workspace's current cluster
/// session. Active requests are never subject to the completed-history limit.
public actor ClusterOperationHistoryStore {
    private var completedLimit: Int
    private var activeByID: [UInt64: ClusterOperationRecord] = [:]
    private var completedStorage: [ClusterOperationRecord] = []
    private var completedHead = 0
    private var completedIndexByID: [UInt64: Int] = [:]
    private var droppedCompleted: UInt64 = 0

    public init(completedLimit: Int = 2_000) {
        precondition(completedLimit >= 0)
        self.completedLimit = completedLimit
    }

    public func apply(_ batch: ClusterOperationBatch) -> ClusterOperationHistoryChange {
        activeByID = Dictionary(
            batch.active.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var added: [ClusterOperationRecord] = []
        var addedIndexByID: [UInt64: Int] = [:]
        var evicted: [UInt64] = []
        if completedLimit > 0 {
            added.reserveCapacity(min(completedLimit, batch.completed.count))
            for record in batch.completed {
                if let index = completedIndexByID[record.id], index >= completedHead {
                    guard completedStorage[index] != record else { continue }
                    completedStorage[index] = record
                } else {
                    completedIndexByID[record.id] = completedStorage.count
                    completedStorage.append(record)
                }
                if let changeIndex = addedIndexByID[record.id] {
                    added[changeIndex] = record
                } else {
                    addedIndexByID[record.id] = added.count
                    added.append(record)
                }
            }
            evictCompletedIfNeeded(into: &evicted)
        }
        droppedCompleted = saturatingAdd(droppedCompleted, batch.droppedCompleted)
        return ClusterOperationHistoryChange(
            active: batch.active,
            completed: added,
            evictedCompletedIDs: evicted,
            droppedCompleted: droppedCompleted
        )
    }

    public func setCompletedLimit(_ limit: Int) -> ClusterOperationHistoryChange {
        precondition(limit >= 0)
        completedLimit = limit
        var evicted: [UInt64] = []
        evictCompletedIfNeeded(into: &evicted)
        return ClusterOperationHistoryChange(
            active: Array(activeByID.values),
            evictedCompletedIDs: evicted,
            droppedCompleted: droppedCompleted
        )
    }

    public func reset() {
        activeByID.removeAll(keepingCapacity: true)
        completedStorage.removeAll(keepingCapacity: false)
        completedHead = 0
        completedIndexByID.removeAll(keepingCapacity: false)
        droppedCompleted = 0
    }

    public func snapshot() -> ClusterOperationHistorySnapshot {
        ClusterOperationHistorySnapshot(
            active: Array(activeByID.values),
            completed: Array(completedStorage[completedHead...]),
            droppedCompleted: droppedCompleted
        )
    }

    private func evictCompletedIfNeeded(into evicted: inout [UInt64]) {
        let excess = max(0, completedStorage.count - completedHead - completedLimit)
        guard excess > 0 else { return }
        evicted.reserveCapacity(evicted.count + excess)
        for _ in 0..<excess {
            let id = completedStorage[completedHead].id
            completedIndexByID.removeValue(forKey: id)
            evicted.append(id)
            completedHead += 1
        }
        compactCompletedStorageIfNeeded()
    }

    private func compactCompletedStorageIfNeeded() {
        guard completedHead >= 4_096,
            completedHead >= completedStorage.count / 2
        else { return }
        completedStorage.removeFirst(completedHead)
        completedHead = 0
        completedIndexByID = Dictionary(
            uniqueKeysWithValues: completedStorage.indices.map {
                (completedStorage[$0].id, $0)
            }
        )
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
