import Foundation
import KmgrCore

/// Test providers use the same control/range split as production without each
/// fixture reimplementing a revision-safe sparse backend.
protocol RangeBackedTestWorkspaceProviding: WorkspaceResourceProviding {}

extension RangeBackedTestWorkspaceProviding {
    func fetchViewRange(
        request: ResourceViewRangeRequest
    ) async throws -> ResourceViewRange {
        try TestResourceViewRangeStore.shared.fetch(request)
    }

    func updateMetricInterest(
        request: ResourceMetricInterestRequest
    ) async throws {}
}

func testSnapshotInvalidation(
    request: ResourceViewRequest,
    sequence: UInt64,
    rows: [ResourceRow],
    first: Bool = true,
    observedOptionalResourceKeys: Set<String> = [],
    observedOptionalResourceKeysTruncated: Bool = false
) -> ResourceViewMessage {
    let state = TestResourceViewRangeStore.shared.snapshot(
        request: request,
        rows: rows,
        first: first
    )
    return .invalidation(
        cursor: StreamCursor(generation: request.generation, sequence: sequence),
        invalidation: state.invalidation(
            keys: observedOptionalResourceKeys,
            truncated: observedOptionalResourceKeysTruncated
        )
    )
}

func testDeltaInvalidation(
    request: ResourceViewRequest,
    sequence: UInt64,
    upserts: [ResourceRow] = [],
    removedUIDs: Set<ResourceUID> = [],
    orderedUIDs: [ResourceUID] = [],
    orderIsComplete: Bool = false,
    observedOptionalResourceKeys: Set<String> = [],
    observedOptionalResourceKeysTruncated: Bool = false
) -> ResourceViewMessage {
    let state = TestResourceViewRangeStore.shared.delta(
        request: request,
        upserts: upserts,
        removedUIDs: removedUIDs,
        orderedUIDs: orderedUIDs,
        orderIsComplete: orderIsComplete
    )
    return .invalidation(
        cursor: StreamCursor(generation: request.generation, sequence: sequence),
        invalidation: state.invalidation(
            keys: observedOptionalResourceKeys,
            truncated: observedOptionalResourceKeysTruncated
        )
    )
}

func testReconciliation(
    request: ResourceViewRequest,
    sequence: UInt64
) -> ResourceViewMessage {
    let state = TestResourceViewRangeStore.shared.state(for: request)
    return .reconciled(
        cursor: StreamCursor(generation: request.generation, sequence: sequence),
        reconciliation: ResourceViewReconciliation(
            rowsVisible: UInt64(state.rows.count),
            presentationRevision: state.presentationRevision,
            indexRevision: state.indexRevision
        )
    )
}

private final class TestResourceViewRangeStore: @unchecked Sendable {
    static let shared = TestResourceViewRangeStore()

    struct State: Sendable {
        var rows: [ResourceRow]
        var presentationRevision: UInt64
        var indexRevision: UInt64

        func invalidation(
            keys: Set<String>,
            truncated: Bool
        ) -> ResourceViewInvalidation {
            ResourceViewInvalidation(
                presentationRevision: presentationRevision,
                indexRevision: indexRevision,
                rowsVisible: UInt64(rows.count),
                maxRangeLength:
                    ResourceViewInvalidation.protocolMaximumRangeLength,
                observedOptionalResourceKeys: keys,
                observedOptionalResourceKeysTruncated: truncated
            )
        }
    }

    private struct Key: Hashable {
        var sessionID: String
        var viewID: String
        var generation: UInt64

        init(
            sessionID: String,
            viewID: String,
            generation: UInt64
        ) {
            self.sessionID = sessionID
            self.viewID = viewID
            self.generation = generation
        }

        init(_ request: ResourceViewRequest) {
            self.init(
                sessionID: request.sessionID,
                viewID: request.viewID,
                generation: request.generation
            )
        }
    }

    private let lock = NSLock()
    private var states: [Key: State] = [:]

    func snapshot(
        request: ResourceViewRequest,
        rows: [ResourceRow],
        first: Bool
    ) -> State {
        lock.withLock {
            let key = Key(request)
            let previous = states[key]
            let nextRows = first ? rows : (previous?.rows ?? []) + rows
            let next = State(
                rows: deduplicated(nextRows),
                presentationRevision: (previous?.presentationRevision ?? 0) + 1,
                indexRevision: (previous?.indexRevision ?? 0) + 1
            )
            states[key] = next
            return next
        }
    }

    func delta(
        request: ResourceViewRequest,
        upserts: [ResourceRow],
        removedUIDs: Set<ResourceUID>,
        orderedUIDs: [ResourceUID],
        orderIsComplete: Bool
    ) -> State {
        lock.withLock {
            let key = Key(request)
            var current = states[key] ?? State(
                rows: [], presentationRevision: 1, indexRevision: 1
            )
            guard !upserts.isEmpty || !removedUIDs.isEmpty || orderIsComplete else {
                states[key] = current
                return current
            }
            let previousOrder = current.rows.map(\.identity.uid)
            var byUID = Dictionary(uniqueKeysWithValues: current.rows.map {
                ($0.identity.uid, $0)
            })
            for uid in removedUIDs { byUID.removeValue(forKey: uid) }
            for row in upserts where !removedUIDs.contains(row.identity.uid) {
                byUID[row.identity.uid] = row
            }
            var order = orderIsComplete ? orderedUIDs : previousOrder
            order.removeAll { byUID[$0] == nil }
            for row in upserts where !order.contains(row.identity.uid) {
                order.append(row.identity.uid)
            }
            current.rows = order.compactMap { byUID[$0] }
            current.presentationRevision += 1
            if current.rows.map(\.identity.uid) != previousOrder {
                current.indexRevision += 1
            }
            states[key] = current
            return current
        }
    }

    func state(for request: ResourceViewRequest) -> State {
        lock.withLock {
            states[Key(request)] ?? State(
                rows: [], presentationRevision: 1, indexRevision: 1
            )
        }
    }

    func fetch(_ request: ResourceViewRangeRequest) throws -> ResourceViewRange {
        try lock.withLock {
            let key = Key(
                sessionID: request.sessionID,
                viewID: request.viewID,
                generation: request.revision.generation
            )
            guard let state = states[key],
                request.revision.presentation == state.presentationRevision,
                request.revision.index == state.indexRevision,
                request.startIndex <= UInt64(state.rows.count)
            else {
                throw ClusterManagerIssue(
                    category: .validation,
                    reason: "StaleTestViewRange",
                    message: "The test resource presentation changed.",
                    operation: "fetch test resource range"
                )
            }
            let start = Int(request.startIndex)
            let end = min(state.rows.count, start + request.length)
            return ResourceViewRange(
                viewID: request.viewID,
                revision: request.revision,
                startIndex: request.startIndex,
                rowsVisible: UInt64(state.rows.count),
                rows: Array(state.rows[start..<end])
            )
        }
    }

    private func deduplicated(_ rows: [ResourceRow]) -> [ResourceRow] {
        var seen: Set<ResourceUID> = []
        return Array(rows.reversed()
            .filter { seen.insert($0.identity.uid).inserted }
            .reversed())
    }
}
