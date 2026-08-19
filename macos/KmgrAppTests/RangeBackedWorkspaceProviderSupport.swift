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

    func applySelectionGesture(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        previousToken: String,
        gesture: ResourceSelectionGesture
    ) async throws -> ResourceSelectionState {
        try TestResourceViewRangeStore.shared.applySelectionGesture(
            sessionID: sessionID,
            viewID: viewID,
            generation: generation,
            indexRevision: indexRevision,
            previousToken: previousToken,
            gesture: gesture
        )
    }

    func projectSelectionRange(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        startIndex: UInt64,
        length: Int,
        token: String
    ) async throws -> ResourceSelectionProjection {
        try TestResourceViewRangeStore.shared.projectSelectionRange(
            sessionID: sessionID,
            viewID: viewID,
            generation: generation,
            indexRevision: indexRevision,
            startIndex: startIndex,
            length: length,
            token: token
        )
    }

    func fetchSelectionPage(
        sessionID: String,
        viewID: String,
        token: String,
        offset: UInt64,
        limit: Int
    ) async throws -> ResourceSelectionPage {
        try TestResourceViewRangeStore.shared.fetchSelectionPage(
            sessionID: sessionID,
            viewID: viewID,
            token: token,
            offset: offset,
            limit: limit
        )
    }
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

        private(set) var rowIndexByUID: [ResourceUID: Int]

        init(
            rows: [ResourceRow],
            presentationRevision: UInt64,
            indexRevision: UInt64
        ) {
            self.rows = rows
            self.presentationRevision = presentationRevision
            self.indexRevision = indexRevision
            rowIndexByUID = Self.makeRowIndex(rows)
        }

        mutating func replaceRows(_ rows: [ResourceRow]) {
            self.rows = rows
            rowIndexByUID = Self.makeRowIndex(rows)
        }

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

        private static func makeRowIndex(
            _ rows: [ResourceRow]
        ) -> [ResourceUID: Int] {
            Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                ($0.element.identity.uid, $0.offset)
            })
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

    private struct SelectionScope: Hashable {
        var sessionID: String
        var viewID: String
    }

    private struct Selection: Sendable {
        var scope: SelectionScope
        var generation: UInt64
        var snapshot: State
        var selectedIndexes: IndexSet
        var anchorIndex: Int?
        var state: ResourceSelectionState
    }

    private let lock = NSLock()
    private var states: [Key: State] = [:]
    private var selections: [String: Selection] = [:]
    private var nextSelectionToken: UInt64 = 0

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
            current.replaceRows(order.compactMap { byUID[$0] })
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

    func applySelectionGesture(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        previousToken: String,
        gesture: ResourceSelectionGesture
    ) throws -> ResourceSelectionState {
        try lock.withLock {
            let scope = SelectionScope(sessionID: sessionID, viewID: viewID)
            let key = Key(
                sessionID: sessionID,
                viewID: viewID,
                generation: generation
            )
            guard let current = states[key], current.indexRevision == indexRevision else {
                throw selectionIssue(
                    reason: "StaleTestSelectionRevision",
                    message: "The test resource ordering changed before the selection gesture was applied.",
                    operation: "apply test resource selection gesture"
                )
            }

            let previous: Selection?
            if previousToken.isEmpty {
                previous = nil
            } else {
                guard let found = selections[previousToken], found.scope == scope else {
                    throw selectionIssue(
                        reason: "MissingTestSelection",
                        message: "The test selection token does not exist in this resource view.",
                        operation: "apply test resource selection gesture"
                    )
                }
                previous = found
            }

            let continuesPrevious = previous.map {
                $0.generation == generation
                    && $0.snapshot.indexRevision == indexRevision
            } ?? false
            let snapshot = continuesPrevious ? previous!.snapshot : current
            var selected = continuesPrevious
                ? previous!.selectedIndexes : IndexSet()
            var anchor = continuesPrevious ? previous!.anchorIndex : nil

            switch gesture.kind {
            case .replace:
                guard !gesture.additive else {
                    throw invalidSelectionGesture()
                }
                let index = try selectionIndex(
                    gesture.index,
                    rowCount: current.rows.count,
                    operation: "replace test resource selection"
                )
                selected = IndexSet(integer: index)
                anchor = index
            case .commandToggle:
                guard !gesture.additive else {
                    throw invalidSelectionGesture()
                }
                let index = try selectionIndex(
                    gesture.index,
                    rowCount: current.rows.count,
                    operation: "toggle test resource selection"
                )
                if selected.contains(index) {
                    selected.remove(index)
                } else {
                    selected.insert(index)
                }
                anchor = index
            case .shiftExtend:
                let index = try selectionIndex(
                    gesture.index,
                    rowCount: current.rows.count,
                    operation: "extend test resource selection"
                )
                let fixed = anchor ?? index
                let extensionIndexes = IndexSet(
                    integersIn: min(fixed, index)..<(max(fixed, index) + 1)
                )
                if gesture.additive {
                    selected.formUnion(extensionIndexes)
                } else {
                    selected = extensionIndexes
                }
                anchor = fixed
            case .commandAll:
                guard gesture.index == nil, !gesture.additive else {
                    throw invalidSelectionGesture()
                }
                selected = IndexSet(integersIn: current.rows.indices)
            case .clear:
                guard gesture.index == nil, !gesture.additive else {
                    throw invalidSelectionGesture()
                }
                selected = []
                anchor = nil
            }

            nextSelectionToken += 1
            let token = "range-backed-selection-\(nextSelectionToken)"
            let revision = ResourceSelectionRevision(
                generation: generation,
                indexRevision: indexRevision
            )
            let state = ResourceSelectionState(
                token: token,
                revision: revision,
                selectedCount: UInt64(selected.count),
                anchor: anchor.map {
                    ResourceSelectionAnchor(
                        index: UInt64($0),
                        uid: snapshot.rows[$0].identity.uid
                    )
                },
                expiresAt: Date().addingTimeInterval(5 * 60)
            )
            selections[token] = Selection(
                scope: scope,
                generation: generation,
                snapshot: snapshot,
                selectedIndexes: selected,
                anchorIndex: anchor,
                state: state
            )
            return state
        }
    }

    func projectSelectionRange(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        startIndex: UInt64,
        length: Int,
        token: String
    ) throws -> ResourceSelectionProjection {
        try lock.withLock {
            let scope = SelectionScope(sessionID: sessionID, viewID: viewID)
            guard let selection = selections[token], selection.scope == scope else {
                throw selectionIssue(
                    reason: "MissingTestSelection",
                    message: "The test selection token does not exist in this resource view.",
                    operation: "project test resource selection"
                )
            }
            let key = Key(
                sessionID: sessionID,
                viewID: viewID,
                generation: generation
            )
            guard let current = states[key], current.indexRevision == indexRevision,
                length > 0,
                length <= ResourceViewInvalidation.protocolMaximumRangeLength,
                startIndex <= UInt64(current.rows.count)
            else {
                throw selectionIssue(
                    reason: "InvalidTestSelectionProjection",
                    message: "The requested test selection projection is stale or invalid.",
                    operation: "project test resource selection"
                )
            }
            let start = Int(startIndex)
            let end = min(current.rows.count, start + length)
            let visibleRows = current.rows[start..<end]
            let selected = visibleRows.map { row in
                guard let pinnedIndex = selection.snapshot.rowIndexByUID[
                    row.identity.uid
                ] else { return false }
                return selection.selectedIndexes.contains(pinnedIndex)
            }
            let anchorUID = selection.state.anchor?.uid
            let anchorOffset = anchorUID.flatMap { uid in
                visibleRows.firstIndex { $0.identity.uid == uid }.map {
                    visibleRows.distance(from: visibleRows.startIndex, to: $0)
                }
            }
            return ResourceSelectionProjection(
                viewID: viewID,
                revision: ResourceSelectionRevision(
                    generation: generation,
                    indexRevision: indexRevision
                ),
                startIndex: startIndex,
                rowsVisible: UInt64(current.rows.count),
                state: selection.state,
                selected: selected,
                anchorOffset: anchorOffset
            )
        }
    }

    func fetchSelectionPage(
        sessionID: String,
        viewID: String,
        token: String,
        offset: UInt64,
        limit: Int
    ) throws -> ResourceSelectionPage {
        try lock.withLock {
            let scope = SelectionScope(sessionID: sessionID, viewID: viewID)
            guard let selection = selections[token], selection.scope == scope else {
                throw selectionIssue(
                    reason: "MissingTestSelection",
                    message: "The test selection token does not exist in this resource view.",
                    operation: "page test resource selection"
                )
            }
            guard (1...ResourceSelectionPage.protocolMaximumPageSize).contains(limit),
                offset <= UInt64(selection.selectedIndexes.count)
            else {
                throw selectionIssue(
                    reason: "InvalidTestSelectionPage",
                    message: "The requested test selection page is invalid.",
                    operation: "page test resource selection"
                )
            }
            let start = Int(offset)
            let indexes = selection.selectedIndexes.dropFirst(start).prefix(limit)
            let items = indexes.map { index in
                ResourceSelectionPageItem(
                    pinnedIndex: UInt64(index),
                    identity: selection.snapshot.rows[index].identity
                )
            }
            let nextOffset = offset + UInt64(items.count)
            return ResourceSelectionPage(
                state: selection.state,
                offset: offset,
                items: items,
                nextOffset: nextOffset,
                done: nextOffset == selection.state.selectedCount
            )
        }
    }

    private func selectionIndex(
        _ requested: UInt64?,
        rowCount: Int,
        operation: String
    ) throws -> Int {
        guard let requested, requested <= UInt64(Int.max),
            Int(requested) < rowCount
        else {
            throw selectionIssue(
                reason: "InvalidTestSelectionGesture",
                message: "The test selection gesture targets a row outside the current ordering.",
                operation: operation
            )
        }
        return Int(requested)
    }

    private func invalidSelectionGesture() -> ClusterManagerIssue {
        selectionIssue(
            reason: "InvalidTestSelectionGesture",
            message: "The test selection gesture is malformed.",
            operation: "apply test resource selection gesture"
        )
    }

    private func selectionIssue(
        reason: String,
        message: String,
        operation: String
    ) -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .validation,
            reason: reason,
            message: message,
            operation: operation
        )
    }

    private func deduplicated(_ rows: [ResourceRow]) -> [ResourceRow] {
        var seen: Set<ResourceUID> = []
        return Array(rows.reversed()
            .filter { seen.insert($0.identity.uid).inserted }
            .reversed())
    }
}
