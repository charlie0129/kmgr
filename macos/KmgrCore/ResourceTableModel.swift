import Foundation

public struct ScrollAnchor: Hashable, Codable, Sendable {
    public var uid: ResourceUID
    public var pixelOffsetFromTop: Double
    public var priorRowIndex: Int

    public init(uid: ResourceUID, pixelOffsetFromTop: Double, priorRowIndex: Int) {
        self.uid = uid
        self.pixelOffsetFromTop = pixelOffsetFromTop
        self.priorRowIndex = priorRowIndex
    }
}

public enum ScrollRestorationPrecision: String, Codable, Sendable {
    case exactIdentity
    case nearestSurvivingIdentity
    case clampedRow
}

public struct ScrollRestorationPlan: Hashable, Codable, Sendable {
    public var uid: ResourceUID
    public var rowIndex: Int
    public var pixelOffsetFromTop: Double
    public var precision: ScrollRestorationPrecision

    public init(
        uid: ResourceUID,
        rowIndex: Int,
        pixelOffsetFromTop: Double,
        precision: ScrollRestorationPrecision
    ) {
        self.uid = uid
        self.rowIndex = rowIndex
        self.pixelOffsetFromTop = pixelOffsetFromTop
        self.precision = precision
    }
}

public enum ScrollRestorationPlanner {
    /// Plans an identity-based restoration. If the exact top row was deleted,
    /// the next old neighbor is preferred, then the preceding neighbor. This
    /// avoids silently jumping to an unrelated row merely because it inherited
    /// the same numeric index.
    public static func plan(
        anchor: ScrollAnchor?,
        previousOrder: [ResourceUID],
        newOrder: [ResourceUID]
    ) -> ScrollRestorationPlan? {
        guard anchor != nil, !newOrder.isEmpty else { return nil }
        var newIndexes: [ResourceUID: Int] = [:]
        newIndexes.reserveCapacity(newOrder.count)
        for (index, uid) in newOrder.enumerated() {
            newIndexes[uid] = index
        }
        return plan(
            anchor: anchor,
            previousOrder: previousOrder,
            newOrder: newOrder,
            newIndexes: newIndexes
        )
    }

    /// The table model already maintains this index. Accepting it here avoids
    /// rebuilding a second full-size dictionary for every reordered batch.
    static func plan(
        anchor: ScrollAnchor?,
        previousOrder: [ResourceUID],
        newOrder: [ResourceUID],
        newIndexes: [ResourceUID: Int]
    ) -> ScrollRestorationPlan? {
        guard let anchor, !newOrder.isEmpty else { return nil }

        if let rowIndex = newIndexes[anchor.uid] {
            return ScrollRestorationPlan(
                uid: anchor.uid,
                rowIndex: rowIndex,
                pixelOffsetFromTop: anchor.pixelOffsetFromTop,
                precision: .exactIdentity
            )
        }

        let oldIndex = previousOrder.firstIndex(of: anchor.uid) ?? anchor.priorRowIndex
        if previousOrder.indices.contains(oldIndex) {
            if oldIndex + 1 < previousOrder.endIndex {
                for candidate in previousOrder[(oldIndex + 1)...] {
                    if let rowIndex = newIndexes[candidate] {
                        return ScrollRestorationPlan(
                            uid: candidate,
                            rowIndex: rowIndex,
                            pixelOffsetFromTop: anchor.pixelOffsetFromTop,
                            precision: .nearestSurvivingIdentity
                        )
                    }
                }
            }

            if oldIndex > previousOrder.startIndex {
                for candidate in previousOrder[..<oldIndex].reversed() {
                    if let rowIndex = newIndexes[candidate] {
                        return ScrollRestorationPlan(
                            uid: candidate,
                            rowIndex: rowIndex,
                            pixelOffsetFromTop: anchor.pixelOffsetFromTop,
                            precision: .nearestSurvivingIdentity
                        )
                    }
                }
            }
        }

        let rowIndex = min(max(anchor.priorRowIndex, 0), newOrder.count - 1)
        return ScrollRestorationPlan(
            uid: newOrder[rowIndex],
            rowIndex: rowIndex,
            pixelOffsetFromTop: 0,
            precision: .clampedRow
        )
    }
}

public enum VisibleOrderUpdate: Hashable, Sendable {
    /// Leave existing visible rows in place (explicit removals are still
    /// removed). This is useful for cell-only deltas.
    case unchanged
    /// Replace the visible ordering after a backend sort/filter projection.
    case replace([ResourceUID])
    /// Append a progressive snapshot chunk without duplicating existing UIDs.
    case append([ResourceUID])
}

public struct ResourceRowBatch: Hashable, Sendable {
    public var upserts: [ResourceRow]
    /// Only UIDs in this set are confirmed deleted from the current store.
    /// Merely omitting a UID from `visibleOrder` means filtered/hidden, not
    /// deleted, and must not clear its selection.
    public var removedUIDs: Set<ResourceUID>
    public var visibleOrder: VisibleOrderUpdate

    public init(
        upserts: [ResourceRow] = [],
        removedUIDs: Set<ResourceUID> = [],
        visibleOrder: VisibleOrderUpdate = .unchanged
    ) {
        self.upserts = upserts
        self.removedUIDs = removedUIDs
        self.visibleOrder = visibleOrder
    }
}

public struct ResourceTableUpdateCapture: Hashable, Sendable {
    public var selectedUIDs: Set<ResourceUID>
    public var selectionAnchorUID: ResourceUID?
    public var previousOrder: [ResourceUID]
    public var scrollAnchor: ScrollAnchor?

    public init(
        selectedUIDs: Set<ResourceUID>,
        selectionAnchorUID: ResourceUID?,
        previousOrder: [ResourceUID],
        scrollAnchor: ScrollAnchor?
    ) {
        self.selectedUIDs = selectedUIDs
        self.selectionAnchorUID = selectionAnchorUID
        self.previousOrder = previousOrder
        self.scrollAnchor = scrollAnchor
    }
}

public struct ResourceTableUpdatePlan: Hashable, Sendable {
    /// Row indexes to project into `NSTableView.selectedRowIndexes` while UI
    /// selection callbacks are suppressed.
    public var selectedRowIndexes: [Int]
    public var scrollRestoration: ScrollRestorationPlan?
    public var contentUpdate: ResourceTableContentUpdate

    public init(
        selectedRowIndexes: [Int],
        scrollRestoration: ScrollRestorationPlan?,
        contentUpdate: ResourceTableContentUpdate = .reloadAll
    ) {
        self.selectedRowIndexes = selectedRowIndexes
        self.scrollRestoration = scrollRestoration
        self.contentUpdate = contentUpdate
    }
}

public enum ResourceTableContentUpdate: Hashable, Sendable {
    /// Row membership or ordering changed, so AppKit must rebuild its row map.
    case reloadAll
    /// Membership and ordering are unchanged; only these visible rows need
    /// their reusable cells refreshed. An empty array requires no data reload.
    case reloadRows([Int])
}

public struct SelectionCounts: Hashable, Sendable {
    public var selected: Int
    public var visible: Int
    public var hidden: Int

    public init(selected: Int, visible: Int, hidden: Int) {
        self.selected = selected
        self.visible = visible
        self.hidden = hidden
    }
}

/// Pure, AppKit-independent table state. `NSTableView` indexes are always a
/// projection of this model and are never authoritative.
public struct ResourceTableModel: Hashable, Sendable {
    public private(set) var selectedUIDs: Set<ResourceUID>
    public private(set) var selectionAnchorUID: ResourceUID?
    public private(set) var orderedVisibleUIDs: [ResourceUID]
    public private(set) var rowByUID: [ResourceUID: ResourceRow]
    private var visibleIndexByUID: [ResourceUID: Int]

    public init(
        rows: [ResourceRow] = [],
        orderedVisibleUIDs: [ResourceUID]? = nil,
        selectedUIDs: Set<ResourceUID> = [],
        selectionAnchorUID: ResourceUID? = nil
    ) {
        var rowByUID: [ResourceUID: ResourceRow] = [:]
        var insertionOrder: [ResourceUID] = []
        for row in rows {
            let uid = row.identity.uid
            if rowByUID[uid] == nil { insertionOrder.append(uid) }
            rowByUID[uid] = row
        }
        self.rowByUID = rowByUID
        let projection = Self.validatedProjection(
            orderedVisibleUIDs ?? insertionOrder,
            rowByUID: rowByUID
        )
        self.orderedVisibleUIDs = projection.order
        self.visibleIndexByUID = projection.indexByUID
        self.selectedUIDs = selectedUIDs.filter { rowByUID[$0] != nil }
        if let selectionAnchorUID, rowByUID[selectionAnchorUID] != nil {
            self.selectionAnchorUID = selectionAnchorUID
        } else {
            self.selectionAnchorUID = nil
        }
    }

    public var selectionCounts: SelectionCounts {
        let visible = selectedUIDs.lazy.filter { visibleIndexByUID[$0] != nil }.count
        return SelectionCounts(
            selected: selectedUIDs.count,
            visible: visible,
            hidden: selectedUIDs.count - visible
        )
    }

    public var selectedIdentities: [ResourceIdentity] {
        selectedUIDs.compactMap { rowByUID[$0]?.identity }
            .sorted {
                ($0.namespace, $0.name, $0.uid.rawValue) <
                    ($1.namespace, $1.name, $1.uid.rawValue)
            }
    }

    public func captureUpdate(
        topVisibleUID: ResourceUID?,
        pixelOffsetFromTop: Double = 0
    ) -> ResourceTableUpdateCapture {
        let scrollAnchor = topVisibleUID.flatMap { uid in
            visibleIndexByUID[uid].map {
                ScrollAnchor(uid: uid, pixelOffsetFromTop: pixelOffsetFromTop, priorRowIndex: $0)
            }
        }
        return ResourceTableUpdateCapture(
            selectedUIDs: selectedUIDs,
            selectionAnchorUID: selectionAnchorUID,
            previousOrder: orderedVisibleUIDs,
            scrollAnchor: scrollAnchor
        )
    }

    @discardableResult
    public mutating func apply(
        _ batch: ResourceRowBatch,
        capture suppliedCapture: ResourceTableUpdateCapture? = nil
    ) -> ResourceTableUpdatePlan {
        let capture = suppliedCapture ?? captureUpdate(topVisibleUID: nil)

        // Restore the captured source-of-truth selection before applying the
        // model mutation; an AppKit selection callback during row updates must
        // not be able to replace it with transient row indexes.
        selectedUIDs = capture.selectedUIDs
        selectionAnchorUID = capture.selectionAnchorUID

        for uid in batch.removedUIDs {
            rowByUID.removeValue(forKey: uid)
            selectedUIDs.remove(uid)
            if selectionAnchorUID == uid { selectionAnchorUID = nil }
        }
        for row in batch.upserts where !batch.removedUIDs.contains(row.identity.uid) {
            rowByUID[row.identity.uid] = row
        }

        var orderChanged = false
        var installedUpdatedIndex = false
        switch batch.visibleOrder {
        case .unchanged:
            if batch.removedUIDs.contains(where: { visibleIndexByUID[$0] != nil }) {
                orderedVisibleUIDs.removeAll { batch.removedUIDs.contains($0) }
                orderChanged = true
            }
        case .replace(let uids):
            if batch.removedUIDs.isEmpty, uids == orderedVisibleUIDs {
                break
            }
            if batch.removedUIDs.isEmpty, installPermutation(uids) {
                orderChanged = true
                installedUpdatedIndex = true
                break
            }
            let replacement = Self.validatedProjection(uids, rowByUID: rowByUID)
            orderChanged = replacement.order != orderedVisibleUIDs
            if orderChanged {
                orderedVisibleUIDs = replacement.order
                visibleIndexByUID = replacement.indexByUID
                installedUpdatedIndex = true
            }
        case .append(let uids):
            var surviving = orderedVisibleUIDs
            if batch.removedUIDs.contains(where: { visibleIndexByUID[$0] != nil }) {
                surviving.removeAll { batch.removedUIDs.contains($0) }
            }
            let appended = Self.validatedProjection(surviving + uids, rowByUID: rowByUID)
            orderChanged = appended.order != orderedVisibleUIDs
            if orderChanged {
                orderedVisibleUIDs = appended.order
                visibleIndexByUID = appended.indexByUID
                installedUpdatedIndex = true
            }
        }
        if orderChanged, !installedUpdatedIndex {
            visibleIndexByUID = Self.indexes(for: orderedVisibleUIDs)
        }

        // Selection is retained when a row merely becomes invisible. Only an
        // explicit store removal above is allowed to delete it.
        selectedUIDs = selectedUIDs.filter { rowByUID[$0] != nil }
        if let anchor = selectionAnchorUID, rowByUID[anchor] == nil {
            selectionAnchorUID = nil
        }

        return makeUpdatePlan(
            capture: capture,
            orderChanged: orderChanged,
            upsertedUIDs: batch.upserts.lazy.map(\.identity.uid)
        )
    }

    public mutating func selectExclusively(_ uid: ResourceUID) {
        guard rowByUID[uid] != nil, visibleIndexByUID[uid] != nil else { return }
        selectedUIDs = [uid]
        selectionAnchorUID = uid
    }

    /// Implements a Command-click toggle. The clicked identity becomes the
    /// Shift anchor even when the click toggles it off, matching native range
    /// selection behavior while keeping the anchor independent of row indexes.
    public mutating func toggleSelection(of uid: ResourceUID) {
        guard rowByUID[uid] != nil, visibleIndexByUID[uid] != nil else { return }
        if selectedUIDs.contains(uid) {
            selectedUIDs.remove(uid)
        } else {
            selectedUIDs.insert(uid)
        }
        selectionAnchorUID = uid
    }

    public mutating func extendSelection(to uid: ResourceUID, additive: Bool = false) {
        guard let clickedIndex = visibleIndexByUID[uid] else { return }
        guard
            let anchor = selectionAnchorUID,
            let anchorIndex = visibleIndexByUID[anchor]
        else {
            if additive {
                selectedUIDs.insert(uid)
            } else {
                selectedUIDs = [uid]
            }
            selectionAnchorUID = uid
            return
        }

        let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
        let rangeUIDs = Set(orderedVisibleUIDs[range])
        if additive {
            selectedUIDs.formUnion(rangeUIDs)
        } else {
            selectedUIDs = rangeUIDs
        }
        // Intentionally keep the anchor attached to the same UID.
    }

    /// Selects every currently visible row without losing selected objects that
    /// are transiently hidden by a filter.
    public mutating func selectAllVisible() {
        selectedUIDs.formUnion(orderedVisibleUIDs)
        if selectionAnchorUID == nil {
            selectionAnchorUID = orderedVisibleUIDs.first
        }
    }

    public mutating func replaceSelectionFromVisibleRows(
        indexes: [Int],
        anchorIndex: Int?
    ) {
        let uids = indexes.compactMap { index in
            orderedVisibleUIDs.indices.contains(index) ? orderedVisibleUIDs[index] : nil
        }
        selectedUIDs = Set(uids)
        if let anchorIndex, orderedVisibleUIDs.indices.contains(anchorIndex) {
            selectionAnchorUID = orderedVisibleUIDs[anchorIndex]
        } else if selectedUIDs.isEmpty {
            selectionAnchorUID = nil
        }
    }

    /// Applies a modifier selection gesture against UID truth. AppKit delegates
    /// plain selection, but Command/Shift gestures come through this seam so a
    /// numeric row anchor can never replace the UID anchor after a reorder.
    public mutating func applySelectionGesture(
        clickedIndex: Int?,
        modifiers: ResourceTableSelectionModifiers
    ) -> Bool {
        guard let clickedIndex, orderedVisibleUIDs.indices.contains(clickedIndex) else {
            return false
        }
        let uid = orderedVisibleUIDs[clickedIndex]
        if modifiers.contains(.shift) {
            let hiddenSelection = selectedUIDs.subtracting(orderedVisibleUIDs)
            extendSelection(to: uid, additive: modifiers.contains(.command))
            selectedUIDs.formUnion(hiddenSelection)
        } else if modifiers.contains(.command) {
            toggleSelection(of: uid)
        } else {
            selectExclusively(uid)
        }
        return true
    }

    /// Returns the next row for a Shift-Up/Down gesture. The active end of a
    /// native range is opposite its UID anchor, so reversing direction first
    /// contracts the range instead of repeatedly targeting AppKit's selected
    /// row (which is commonly the greatest selected index).
    public func selectionExtensionDestinationIndex(movingDown: Bool) -> Int? {
        guard !orderedVisibleUIDs.isEmpty else { return nil }

        let step = movingDown ? 1 : -1
        guard
            let anchor = selectionAnchorUID,
            let anchorIndex = visibleIndexByUID[anchor]
        else {
            return movingDown ? 0 : orderedVisibleUIDs.count - 1
        }

        let selectedIndexes = selectedUIDs.compactMap { visibleIndexByUID[$0] }.sorted()
        let lowerBound = selectedIndexes.first ?? anchorIndex
        let upperBound = selectedIndexes.last ?? anchorIndex
        let activeIndex: Int
        if selectedUIDs.contains(anchor), lowerBound == anchorIndex, upperBound > anchorIndex {
            activeIndex = upperBound
        } else if selectedUIDs.contains(anchor), lowerBound < anchorIndex, upperBound == anchorIndex {
            activeIndex = lowerBound
        } else {
            activeIndex = anchorIndex
        }

        return min(max(activeIndex + step, 0), orderedVisibleUIDs.count - 1)
    }

    /// Restores a captured UID selection when reopening a navigation entry.
    /// Missing UIDs are ignored; a same-name object with a new UID cannot
    /// inherit selection.
    public mutating func restoreSelection(
        uids: Set<ResourceUID>,
        anchorUID: ResourceUID? = nil
    ) {
        selectedUIDs = uids.filter { rowByUID[$0] != nil }
        if let anchorUID, selectedUIDs.contains(anchorUID) {
            selectionAnchorUID = anchorUID
        } else {
            selectionAnchorUID = selectedUIDs.first
        }
    }

    public mutating func clearSelection() {
        selectedUIDs.removeAll(keepingCapacity: true)
        selectionAnchorUID = nil
    }

    /// Explicit navigation to another cluster/session/GVR/scope calls this
    /// after saving the current navigation entry.
    @discardableResult
    public mutating func clearSelectionForNavigation() -> Set<ResourceUID> {
        let saved = selectedUIDs
        clearSelection()
        return saved
    }

    /// Compact cached rows survive a helper restart only as presentation
    /// state. Rebind their request identity before enabling actions so no
    /// operation can carry the previous helper generation's session ID.
    public mutating func rebindClusterSessionID(_ sessionID: String) {
        for uid in Array(rowByUID.keys) {
            guard var row = rowByUID[uid] else { continue }
            row.identity.clusterSessionID = sessionID
            rowByUID[uid] = row
        }
    }

    private func makeUpdatePlan(
        capture: ResourceTableUpdateCapture,
        orderChanged: Bool,
        upsertedUIDs: some Sequence<ResourceUID>
    ) -> ResourceTableUpdatePlan {
        let selectedRowIndexes = selectedUIDs.compactMap { visibleIndexByUID[$0] }.sorted()
        let scrollRestoration: ScrollRestorationPlan?
        if !orderChanged,
            let anchor = capture.scrollAnchor,
            let rowIndex = visibleIndexByUID[anchor.uid]
        {
            scrollRestoration = ScrollRestorationPlan(
                uid: anchor.uid,
                rowIndex: rowIndex,
                pixelOffsetFromTop: anchor.pixelOffsetFromTop,
                precision: .exactIdentity
            )
        } else {
            scrollRestoration = ScrollRestorationPlanner.plan(
                anchor: capture.scrollAnchor,
                previousOrder: capture.previousOrder,
                newOrder: orderedVisibleUIDs,
                newIndexes: visibleIndexByUID
            )
        }
        let contentUpdate: ResourceTableContentUpdate = orderChanged
            ? .reloadAll
            : .reloadRows(Array(Set(upsertedUIDs.compactMap { visibleIndexByUID[$0] })).sorted())
        return ResourceTableUpdatePlan(
            selectedRowIndexes: selectedRowIndexes,
            scrollRestoration: scrollRestoration,
            contentUpdate: contentUpdate
        )
    }

    private static func indexes(for order: [ResourceUID]) -> [ResourceUID: Int] {
        var result: [ResourceUID: Int] = [:]
        result.reserveCapacity(order.count)
        for (index, uid) in order.enumerated() {
            result[uid] = index
        }
        return result
    }

    /// Most complete backend projections only reorder the current visible
    /// membership. Validate that common case against the existing index, then
    /// update its integer values in place instead of allocating and hashing a
    /// second 100,000-entry dictionary. A malformed or membership-changing
    /// proposal falls back to the fully validating projection below.
    private mutating func installPermutation(_ proposed: [ResourceUID]) -> Bool {
        guard proposed.count == orderedVisibleUIDs.count else { return false }

        var seenPriorIndexes = [Bool](repeating: false, count: proposed.count)
        for uid in proposed {
            guard
                let priorIndex = visibleIndexByUID[uid],
                seenPriorIndexes.indices.contains(priorIndex),
                !seenPriorIndexes[priorIndex]
            else {
                return false
            }
            seenPriorIndexes[priorIndex] = true
        }

        for (newIndex, uid) in proposed.enumerated() {
            visibleIndexByUID[uid] = newIndex
        }
        orderedVisibleUIDs = proposed
        return true
    }

    private static func validatedProjection(
        _ proposed: [ResourceUID],
        rowByUID: [ResourceUID: ResourceRow]
    ) -> (order: [ResourceUID], indexByUID: [ResourceUID: Int]) {
        let capacity = min(proposed.count, rowByUID.count)
        var order: [ResourceUID] = []
        order.reserveCapacity(capacity)
        var indexByUID: [ResourceUID: Int] = [:]
        indexByUID.reserveCapacity(capacity)
        for uid in proposed where rowByUID[uid] != nil {
            let proposedIndex = order.count
            if let existingIndex = indexByUID.updateValue(proposedIndex, forKey: uid) {
                // `updateValue` performs one hash-table lookup on the common
                // unique-UID path. Restore the original index only for an
                // invalid duplicate, which is deliberately omitted.
                indexByUID[uid] = existingIndex
                continue
            }
            order.append(uid)
        }
        return (order, indexByUID)
    }
}

public struct ResourceTableSelectionModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
}

/// Tracks which cached row UIDs have been observed from the freshly opened
/// helper generation. Until a complete first snapshot arrives, callers must
/// not use rebound cached identities for Kubernetes operations.
public struct RecoveredResourceTrust: Hashable, Sendable {
    public private(set) var requiresValidation = false
    public private(set) var hasCompleteSnapshot = true
    private var sawFirstSnapshotChunk = false
    private var pendingSnapshotUIDs: Set<ResourceUID> = []
    private var trustedUIDs: Set<ResourceUID> = []

    public init() {}

    public mutating func requireValidation() {
        requiresValidation = true
        hasCompleteSnapshot = false
        sawFirstSnapshotChunk = false
        pendingSnapshotUIDs.removeAll(keepingCapacity: true)
        trustedUIDs.removeAll(keepingCapacity: true)
    }

    public mutating func receiveSnapshot(
        uids: some Sequence<ResourceUID>,
        first: Bool,
        last: Bool
    ) {
        guard requiresValidation else { return }
        let uids = Array(uids)
        if hasCompleteSnapshot {
            // Later authenticated relists may reveal rows that were absent
            // from the recovery snapshot because of filtering.
            trustedUIDs.formUnion(uids)
            return
        }
        if first {
            sawFirstSnapshotChunk = true
            pendingSnapshotUIDs.removeAll(keepingCapacity: true)
        }
        guard sawFirstSnapshotChunk else { return }
        pendingSnapshotUIDs.formUnion(uids)
        guard last else { return }
        trustedUIDs = pendingSnapshotUIDs
        pendingSnapshotUIDs.removeAll(keepingCapacity: true)
        hasCompleteSnapshot = true
    }

    public mutating func receiveDelta(
        upsertedUIDs: some Sequence<ResourceUID>,
        removedUIDs: Set<ResourceUID>
    ) {
        guard requiresValidation, hasCompleteSnapshot else { return }
        trustedUIDs.formUnion(upsertedUIDs)
        trustedUIDs.subtract(removedUIDs)
    }

    public func permitsNetworkActions(for identities: [ResourceIdentity]) -> Bool {
        guard requiresValidation else { return true }
        return hasCompleteSnapshot
            && identities.allSatisfy { trustedUIDs.contains($0.uid) }
    }
}
