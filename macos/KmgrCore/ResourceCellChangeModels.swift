import Foundation

/// Stable identity for one rendered resource-table cell. Kubernetes object
/// names are deliberately absent: a same-name replacement has a different UID
/// and must not inherit transient presentation state from the deleted object.
public struct ResourceCellAddress: Hashable, Sendable {
    public var uid: ResourceUID
    public var columnID: String

    public init(uid: ResourceUID, columnID: String) {
        self.uid = uid
        self.columnID = columnID
    }
}

/// Semantic weight for a transient changed-cell highlight. Warning is used
/// for restart increases and warning Pod states; regression is intentionally
/// narrow and reserved for critical Pod state transitions.
public enum ResourceCellChangeEmphasis: String, Hashable, Sendable {
    case neutral
    case warning
    case regression
}

public struct ResourceCellChange: Hashable, Sendable {
    public var address: ResourceCellAddress
    public var emphasis: ResourceCellChangeEmphasis

    public init(
        address: ResourceCellAddress,
        emphasis: ResourceCellChangeEmphasis = .neutral
    ) {
        self.address = address
        self.emphasis = emphasis
    }
}

/// Pure row comparison configured once for the current column projection.
///
/// Rows normally arrive with cells in the requested column order, so the hot
/// path compares the two arrays directly without allocating an index. A small
/// bounded fallback handles reordered projections. Very wide malformed or
/// incompatible projections are ignored instead of allocating an unbounded
/// dictionary on the update path.
public struct ResourceRowChangeDetector: Hashable, Sendable {
    public static let maximumFallbackColumnCount = 64

    private var restartColumnIDs: Set<String>
    private var podStateColumnIDs: Set<String>

    public init(columnDefinitions: [ColumnDefinition]) {
        var seenColumnIDs: Set<String> = []
        var ambiguousColumnIDs: Set<String> = []
        var restartColumnIDs: Set<String> = []
        var podStateColumnIDs: Set<String> = []

        for definition in columnDefinitions {
            guard seenColumnIDs.insert(definition.id).inserted else {
                ambiguousColumnIDs.insert(definition.id)
                restartColumnIDs.remove(definition.id)
                podStateColumnIDs.remove(definition.id)
                continue
            }
            if definition.source == .builtin, definition.value == "restarts" {
                restartColumnIDs.insert(definition.id)
            }
            if definition.source == .builtin,
                definition.value == "ready" || definition.value == "status"
            {
                podStateColumnIDs.insert(definition.id)
            }
        }
        restartColumnIDs.subtract(ambiguousColumnIDs)
        podStateColumnIDs.subtract(ambiguousColumnIDs)
        self.restartColumnIDs = restartColumnIDs
        self.podStateColumnIDs = podStateColumnIDs
    }

    /// Returns changes in incoming-column order. A missing prior row or a UID
    /// mismatch establishes a new identity baseline and never flashes cells.
    /// Rendered `displayText` drives ordinary changes. Projected severity also
    /// participates for the two native Pod-state columns so an unchanged
    /// "Running" status can still expose a readiness regression.
    public func changes(
        from previous: ResourceRow?,
        to incoming: ResourceRow
    ) -> [ResourceCellChange] {
        guard let previous,
            previous.identity.uid == incoming.identity.uid
        else { return [] }
        let isPod = Self.isPod(incoming.identity)

        if previous.cells.count == incoming.cells.count {
            var result: [ResourceCellChange] = []
            result.reserveCapacity(min(incoming.cells.count, 8))
            for index in incoming.cells.indices {
                let oldCell = previous.cells[index]
                let newCell = incoming.cells[index]
                guard oldCell.columnID == newCell.columnID else {
                    return fallbackChanges(
                        from: previous,
                        to: incoming,
                        isPod: isPod
                    )
                }
                appendChange(
                    from: oldCell,
                    to: newCell,
                    uid: incoming.identity.uid,
                    isPod: isPod,
                    into: &result
                )
            }
            return result
        }

        return fallbackChanges(from: previous, to: incoming, isPod: isPod)
    }

    private func fallbackChanges(
        from previous: ResourceRow,
        to incoming: ResourceRow,
        isPod: Bool
    ) -> [ResourceCellChange] {
        guard previous.cells.count <= Self.maximumFallbackColumnCount,
            incoming.cells.count <= Self.maximumFallbackColumnCount
        else { return [] }

        var previousCellsByID: [String: Cell] = [:]
        previousCellsByID.reserveCapacity(previous.cells.count)
        for cell in previous.cells {
            // Duplicate IDs make a UID/column address ambiguous. Treat the
            // malformed row as a new baseline rather than guessing.
            guard previousCellsByID.updateValue(cell, forKey: cell.columnID) == nil
            else { return [] }
        }

        var incomingColumnIDs: Set<String> = []
        incomingColumnIDs.reserveCapacity(incoming.cells.count)
        var result: [ResourceCellChange] = []
        result.reserveCapacity(min(incoming.cells.count, 8))
        for newCell in incoming.cells {
            guard incomingColumnIDs.insert(newCell.columnID).inserted else {
                return []
            }
            guard let oldCell = previousCellsByID[newCell.columnID] else {
                // A newly installed column has no prior rendered value and
                // should not make every existing row flash.
                continue
            }
            appendChange(
                from: oldCell,
                to: newCell,
                uid: incoming.identity.uid,
                isPod: isPod,
                into: &result
            )
        }
        return result
    }

    private func appendChange(
        from previous: Cell,
        to incoming: Cell,
        uid: ResourceUID,
        isPod: Bool,
        into changes: inout [ResourceCellChange]
    ) {
        let isPodState = isPod && podStateColumnIDs.contains(incoming.columnID)
        guard previous.displayText != incoming.displayText
                || (isPodState && previous.severity != incoming.severity)
        else { return }
        let emphasis: ResourceCellChangeEmphasis
        if isRestartIncrease(from: previous, to: incoming) {
            emphasis = .warning
        } else if isPodState {
            emphasis = switch incoming.severity {
            case .critical: .regression
            case .warning: .warning
            default: .neutral
            }
        } else {
            emphasis = .neutral
        }
        changes.append(ResourceCellChange(
            address: ResourceCellAddress(uid: uid, columnID: incoming.columnID),
            emphasis: emphasis
        ))
    }

    private static func isPod(_ identity: ResourceIdentity) -> Bool {
        identity.group.isEmpty && identity.resource == "pods"
    }

    private func isRestartIncrease(from previous: Cell, to incoming: Cell) -> Bool {
        guard restartColumnIDs.contains(incoming.columnID),
            let oldCount = Self.restartCount(previous.typedValue),
            let newCount = Self.restartCount(incoming.typedValue)
        else { return false }
        return newCount > oldCount
    }

    /// Restart counts are non-negative integers. Reject non-finite,
    /// fractional, negative, or out-of-range numeric payloads so malformed
    /// data cannot acquire a red semantic highlight.
    private static func restartCount(_ value: CellTypedValue?) -> Int64? {
        switch value {
        case .integer(let count) where count >= 0:
            return count
        case .number(let count) where count.isFinite && count >= 0:
            return Int64(exactly: count)
        default:
            return nil
        }
    }
}

/// Framework-neutral rendering state for one active highlight. `strength` is
/// one during the hold and then falls linearly to zero.
public struct ResourceCellHighlightPresentation: Hashable, Sendable {
    public var emphasis: ResourceCellChangeEmphasis
    public var strength: Double

    public init(emphasis: ResourceCellChangeEmphasis, strength: Double) {
        self.emphasis = emphasis
        self.strength = strength
    }
}

/// Bounded transient highlight state driven exclusively by a monotonic clock.
/// Callers can use one coalesced timer: query `nextRefreshDelay`, reload the
/// currently visible affected cells, expire the store, and schedule again.
public struct ResourceCellHighlightStore: Sendable {
    public static let defaultMaximumRecordCount = 4_096
    public static let holdDuration: Duration = .milliseconds(150)
    public static let totalDuration: Duration = .milliseconds(1_500)
    public static let defaultFadeFrameInterval: Duration = .milliseconds(33)

    private struct Record: Sendable {
        var emphasis: ResourceCellChangeEmphasis
        var changedAt: ContinuousClock.Instant
        var sequence: UInt64
    }

    public let maximumRecordCount: Int
    private var recordsByAddress: [ResourceCellAddress: Record] = [:]
    private var latestObservedInstant: ContinuousClock.Instant?
    private var nextSequence: UInt64 = 0

    public init(maximumRecordCount: Int = Self.defaultMaximumRecordCount) {
        self.maximumRecordCount = max(1, maximumRecordCount)
        recordsByAddress.reserveCapacity(min(self.maximumRecordCount, 256))
    }

    public var count: Int { recordsByAddress.count }
    public var isEmpty: Bool { recordsByAddress.isEmpty }
    public var addresses: Set<ResourceCellAddress> {
        Set(recordsByAddress.keys)
    }

    /// Records or resets the supplied addresses at one monotonic instant.
    /// When capacity is exceeded, visible UIDs win over non-visible UIDs and
    /// the newest record wins within each visibility class.
    ///
    /// The return value contains every address whose presentation may have
    /// changed, including records evicted or expired during this operation.
    @discardableResult
    public mutating func record(
        _ changes: [ResourceCellChange],
        at instant: ContinuousClock.Instant,
        visibleUIDs: Set<ResourceUID> = []
    ) -> Set<ResourceCellAddress> {
        let instant = observe(instant)
        var affected = expireWithoutObserving(at: instant)
        affected.reserveCapacity(affected.count + changes.count)

        // Keep temporary growth bounded even if a very large delta is passed
        // in one call. The externally observable store never exceeds the
        // configured maximum.
        let trimThreshold = maximumRecordCount > Int.max / 2
            ? Int.max
            : maximumRecordCount * 2
        for change in changes {
            affected.insert(change.address)
            recordsByAddress[change.address] = Record(
                emphasis: change.emphasis,
                changedAt: instant,
                sequence: takeSequence()
            )
            if recordsByAddress.count >= trimThreshold {
                affected.formUnion(trimToCapacity(visibleUIDs: visibleUIDs))
            }
        }
        affected.formUnion(trimToCapacity(visibleUIDs: visibleUIDs))
        return affected
    }

    /// Removes all highlights belonging to confirmed-deleted Kubernetes UIDs.
    @discardableResult
    public mutating func removeAll(
        forUIDs removedUIDs: Set<ResourceUID>
    ) -> Set<ResourceCellAddress> {
        guard !removedUIDs.isEmpty else { return [] }
        var removed: Set<ResourceCellAddress> = []
        for address in recordsByAddress.keys where removedUIDs.contains(address.uid) {
            removed.insert(address)
        }
        for address in removed {
            recordsByAddress.removeValue(forKey: address)
        }
        return removed
    }

    /// Clears context-scoped state when the generation, GVR, namespace scope,
    /// or cluster session changes.
    @discardableResult
    public mutating func removeAll() -> Set<ResourceCellAddress> {
        let removed = addresses
        recordsByAddress.removeAll(keepingCapacity: true)
        return removed
    }

    /// Removes highlights whose complete hold-and-fade lifetime has elapsed.
    @discardableResult
    public mutating func expire(
        at instant: ContinuousClock.Instant
    ) -> Set<ResourceCellAddress> {
        expireWithoutObserving(at: observe(instant))
    }

    public func presentation(
        for address: ResourceCellAddress,
        at instant: ContinuousClock.Instant
    ) -> ResourceCellHighlightPresentation? {
        guard let record = recordsByAddress[address] else { return nil }
        let elapsed = nonnegativeDuration(from: record.changedAt, to: instant)
        guard elapsed < Self.totalDuration else { return nil }
        if elapsed <= Self.holdDuration {
            return ResourceCellHighlightPresentation(
                emphasis: record.emphasis,
                strength: 1
            )
        }

        let fadeElapsed = elapsed - Self.holdDuration
        let fadeDuration = Self.totalDuration - Self.holdDuration
        let strength = 1 - Self.seconds(fadeElapsed) / Self.seconds(fadeDuration)
        return ResourceCellHighlightPresentation(
            emphasis: record.emphasis,
            strength: min(1, max(0, strength))
        )
    }

    /// Delay until the next useful coalesced repaint. During the fixed hold it
    /// targets the first fade boundary; during a fade it uses a bounded frame
    /// cadence without scheduling past the record's expiry.
    public func nextRefreshDelay(
        at instant: ContinuousClock.Instant,
        fadeFrameInterval: Duration = Self.defaultFadeFrameInterval
    ) -> Duration? {
        guard !recordsByAddress.isEmpty else { return nil }
        let frameInterval = fadeFrameInterval > .zero
            ? fadeFrameInterval
            : Self.defaultFadeFrameInterval
        var nextDelay: Duration?

        for record in recordsByAddress.values {
            let elapsed = nonnegativeDuration(from: record.changedAt, to: instant)
            let candidate: Duration
            if elapsed >= Self.totalDuration {
                candidate = .zero
            } else if elapsed < Self.holdDuration {
                candidate = Self.holdDuration - elapsed
            } else {
                candidate = min(frameInterval, Self.totalDuration - elapsed)
            }
            nextDelay = nextDelay.map { min($0, candidate) } ?? candidate
        }
        return nextDelay
    }

    /// Delay until the earliest highlight reaches its normal expiry. Reduced
    /// motion callers use this instead of the fade cadence so the steady tint
    /// costs exactly one wake-up to remove, regardless of how many cells are
    /// currently highlighted.
    public func nextExpiryDelay(
        at instant: ContinuousClock.Instant
    ) -> Duration? {
        var nextDelay: Duration?
        for record in recordsByAddress.values {
            let elapsed = nonnegativeDuration(from: record.changedAt, to: instant)
            let candidate = elapsed >= Self.totalDuration
                ? Duration.zero : Self.totalDuration - elapsed
            nextDelay = nextDelay.map { min($0, candidate) } ?? candidate
        }
        return nextDelay
    }

    private mutating func observe(
        _ candidate: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        if let latestObservedInstant, candidate < latestObservedInstant {
            return latestObservedInstant
        }
        latestObservedInstant = candidate
        return candidate
    }

    private mutating func expireWithoutObserving(
        at instant: ContinuousClock.Instant
    ) -> Set<ResourceCellAddress> {
        var expired: Set<ResourceCellAddress> = []
        for (address, record) in recordsByAddress
        where nonnegativeDuration(from: record.changedAt, to: instant) >= Self.totalDuration {
            expired.insert(address)
        }
        for address in expired {
            recordsByAddress.removeValue(forKey: address)
        }
        return expired
    }

    private mutating func trimToCapacity(
        visibleUIDs: Set<ResourceUID>
    ) -> Set<ResourceCellAddress> {
        let overflow = recordsByAddress.count - maximumRecordCount
        guard overflow > 0 else { return [] }

        let victims = recordsByAddress.sorted { lhs, rhs in
            let lhsVisible = visibleUIDs.contains(lhs.key.uid)
            let rhsVisible = visibleUIDs.contains(rhs.key.uid)
            if lhsVisible != rhsVisible {
                return !lhsVisible
            }
            if lhs.value.sequence != rhs.value.sequence {
                return lhs.value.sequence < rhs.value.sequence
            }
            if lhs.key.uid.rawValue != rhs.key.uid.rawValue {
                return lhs.key.uid.rawValue < rhs.key.uid.rawValue
            }
            return lhs.key.columnID < rhs.key.columnID
        }.prefix(overflow).map(\.key)

        let removed = Set(victims)
        for address in removed {
            recordsByAddress.removeValue(forKey: address)
        }
        return removed
    }

    private mutating func takeSequence() -> UInt64 {
        if nextSequence == .max {
            // Preserve relative recency across the theoretical wrap boundary.
            let orderedAddresses = recordsByAddress.sorted {
                $0.value.sequence < $1.value.sequence
            }.map(\.key)
            for (offset, address) in orderedAddresses.enumerated() {
                recordsByAddress[address]?.sequence = UInt64(offset)
            }
            nextSequence = UInt64(orderedAddresses.count)
        }
        defer { nextSequence += 1 }
        return nextSequence
    }

    private func nonnegativeDuration(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Duration {
        max(.zero, start.duration(to: end))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
