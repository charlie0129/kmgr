import Foundation

/// Pure policy for bounded table-column auto sizing. AppKit remains
/// responsible for measuring text; this type chooses which rows to measure and
/// clamps the result without depending on view geometry or rendered pixels.
public struct TableColumnAutoWidthPolicy: Hashable, Sendable {
    public let maximumSampleCount: Int
    public let maximumWidth: Double

    public init(
        maximumSampleCount: Int = 4_096,
        maximumWidth: Double = 640
    ) {
        self.maximumSampleCount = max(1, maximumSampleCount)
        self.maximumWidth = maximumWidth.isFinite ? max(1, maximumWidth) : 640
    }

    public func sampleIndexes(
        rowCount: Int,
        visibleRows: Range<Int>? = nil
    ) -> IndexSet {
        guard rowCount > 0 else { return [] }
        let allRows = 0..<rowCount
        if rowCount <= maximumSampleCount {
            return IndexSet(integersIn: allRows)
        }

        let visibleRows = visibleRows.flatMap { range -> Range<Int>? in
            let lowerBound = max(allRows.lowerBound, range.lowerBound)
            let upperBound = min(allRows.upperBound, range.upperBound)
            return lowerBound < upperBound ? lowerBound..<upperBound : nil
        }
        if let visibleRows, visibleRows.count >= maximumSampleCount {
            return evenlySpacedIndexes(in: visibleRows, count: maximumSampleCount)
        }

        var result = IndexSet()
        if let visibleRows {
            result.insert(integersIn: visibleRows)
        }
        let remaining = maximumSampleCount - result.count
        for index in evenlySpacedIndexes(in: allRows, count: remaining) {
            result.insert(index)
        }
        return result
    }

    /// Returns an integral point width bounded by both the column and policy.
    /// Invalid measurements collapse safely to the column minimum.
    public func fittedWidth(
        candidateWidth: Double,
        minimumWidth: Double,
        columnMaximumWidth: Double
    ) -> Double {
        let minimum = minimumWidth.isFinite ? max(0, minimumWidth) : 0
        let columnMaximum = columnMaximumWidth.isFinite
            ? max(minimum, columnMaximumWidth)
            : maximumWidth
        let upperBound = max(minimum, min(columnMaximum, maximumWidth))
        let candidate = candidateWidth.isFinite
            ? candidateWidth.rounded(.up)
            : minimum
        return min(max(minimum, candidate), upperBound)
    }

    private func evenlySpacedIndexes(
        in rows: Range<Int>,
        count requestedCount: Int
    ) -> IndexSet {
        let count = min(requestedCount, rows.count)
        guard count > 0 else { return [] }
        if count == 1 {
            return IndexSet(integer: rows.lowerBound + rows.count / 2)
        }
        var result = IndexSet()
        for offset in 0..<count {
            result.insert(
                rows.lowerBound + offset * (rows.count - 1) / (count - 1)
            )
        }
        return result
    }
}

public enum ResourceListTableTopAnchor: Hashable, Sendable {
    case header
    case issueRow
}

/// Presentation state for the optional inline issue row above a resource
/// table. Keeping the anchor choice explicit prevents a hidden label from
/// continuing to reserve an empty row.
public enum ResourceListInlineIssueScope: String, Hashable, Sendable, CaseIterable {
    case stream
    case range
    case selection
    case configuration
    case general
}

/// Presentation state for scoped inline issues. A successful range or
/// selection operation can remove only its own superseded issue while an
/// unrelated stream/configuration problem remains available to the user.
public struct ResourceListInlineIssueState: Hashable, Sendable {
    private struct Entry: Hashable, Sendable {
        var message: String
        var sequence: UInt64
    }

    private var entries: [ResourceListInlineIssueScope: Entry] = [:]
    private var nextSequence: UInt64 = 0

    public var message: String? { activeEntry?.value.message }
    public var scope: ResourceListInlineIssueScope? { activeEntry?.key }

    public init(message: String? = nil) {
        if let message {
            show(message)
        }
    }

    public var isHidden: Bool { message == nil }

    public var tableTopAnchor: ResourceListTableTopAnchor {
        isHidden ? .header : .issueRow
    }

    public mutating func show(
        _ message: String,
        scope: ResourceListInlineIssueScope = .general
    ) {
        nextSequence &+= 1
        entries[scope] = Entry(message: message, sequence: nextSequence)
    }

    public mutating func hide() {
        entries.removeAll(keepingCapacity: true)
    }

    public mutating func hide(scope: ResourceListInlineIssueScope) {
        entries.removeValue(forKey: scope)
    }

    public func contains(scope: ResourceListInlineIssueScope) -> Bool {
        entries[scope] != nil
    }

    private var activeEntry: (key: ResourceListInlineIssueScope, value: Entry)? {
        entries.max { lhs, rhs in lhs.value.sequence < rhs.value.sequence }
    }
}
