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
        guard let anchor, !newOrder.isEmpty else { return nil }

        let newIndexes = Dictionary(uniqueKeysWithValues: newOrder.enumerated().map { ($1, $0) })
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

    public init(selectedRowIndexes: [Int], scrollRestoration: ScrollRestorationPlan?) {
        self.selectedRowIndexes = selectedRowIndexes
        self.scrollRestoration = scrollRestoration
    }
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
        self.orderedVisibleUIDs = Self.validatedOrder(
            orderedVisibleUIDs ?? insertionOrder,
            rowByUID: rowByUID
        )
        self.selectedUIDs = selectedUIDs.filter { rowByUID[$0] != nil }
        if let selectionAnchorUID, rowByUID[selectionAnchorUID] != nil {
            self.selectionAnchorUID = selectionAnchorUID
        } else {
            self.selectionAnchorUID = nil
        }
    }

    public var selectionCounts: SelectionCounts {
        let visibleSet = Set(orderedVisibleUIDs)
        let visible = selectedUIDs.intersection(visibleSet).count
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
            orderedVisibleUIDs.firstIndex(of: uid).map {
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

        let survivingOldOrder = orderedVisibleUIDs.filter {
            rowByUID[$0] != nil && !batch.removedUIDs.contains($0)
        }
        switch batch.visibleOrder {
        case .unchanged:
            orderedVisibleUIDs = survivingOldOrder
        case .replace(let uids):
            orderedVisibleUIDs = Self.validatedOrder(uids, rowByUID: rowByUID)
        case .append(let uids):
            let appended = survivingOldOrder + uids
            orderedVisibleUIDs = Self.validatedOrder(appended, rowByUID: rowByUID)
        }

        // Selection is retained when a row merely becomes invisible. Only an
        // explicit store removal above is allowed to delete it.
        selectedUIDs = selectedUIDs.filter { rowByUID[$0] != nil }
        if let anchor = selectionAnchorUID, rowByUID[anchor] == nil {
            selectionAnchorUID = nil
        }

        return makeUpdatePlan(capture: capture)
    }

    public mutating func selectExclusively(_ uid: ResourceUID) {
        guard rowByUID[uid] != nil, orderedVisibleUIDs.contains(uid) else { return }
        selectedUIDs = [uid]
        selectionAnchorUID = uid
    }

    /// Implements a Command-click toggle. The clicked identity becomes the
    /// Shift anchor even when the click toggles it off, matching native range
    /// selection behavior while keeping the anchor independent of row indexes.
    public mutating func toggleSelection(of uid: ResourceUID) {
        guard rowByUID[uid] != nil, orderedVisibleUIDs.contains(uid) else { return }
        if selectedUIDs.contains(uid) {
            selectedUIDs.remove(uid)
        } else {
            selectedUIDs.insert(uid)
        }
        selectionAnchorUID = uid
    }

    public mutating func extendSelection(to uid: ResourceUID, additive: Bool = false) {
        guard let clickedIndex = orderedVisibleUIDs.firstIndex(of: uid) else { return }
        guard
            let anchor = selectionAnchorUID,
            let anchorIndex = orderedVisibleUIDs.firstIndex(of: anchor)
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

    private func makeUpdatePlan(capture: ResourceTableUpdateCapture) -> ResourceTableUpdatePlan {
        let selectedRowIndexes = orderedVisibleUIDs.enumerated().compactMap {
            selectedUIDs.contains($0.element) ? $0.offset : nil
        }
        return ResourceTableUpdatePlan(
            selectedRowIndexes: selectedRowIndexes,
            scrollRestoration: ScrollRestorationPlanner.plan(
                anchor: capture.scrollAnchor,
                previousOrder: capture.previousOrder,
                newOrder: orderedVisibleUIDs
            )
        )
    }

    private static func validatedOrder(
        _ proposed: [ResourceUID],
        rowByUID: [ResourceUID: ResourceRow]
    ) -> [ResourceUID] {
        var seen: Set<ResourceUID> = []
        return proposed.filter { uid in
            rowByUID[uid] != nil && seen.insert(uid).inserted
        }
    }
}
