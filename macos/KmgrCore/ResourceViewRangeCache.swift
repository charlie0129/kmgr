import Foundation

public enum ResourceViewInvalidationDisposition: Hashable, Sendable {
    case installed
    case advanced(indexChanged: Bool)
    case hintsOnly
    case rejectedStale
    case rejectedInvalid
}

public enum ResourceViewRangeReception: Hashable, Sendable {
    case installed(Range<UInt64>)
    case rejectedRace
    case rejectedInvalid
}

/// Plans one bounded table window from AppKit's absolute visible row indexes.
/// The retained range includes a configurable number of viewports before and
/// after the visible rows, while preserving bounded per-view memory.
public enum ResourceViewViewportPlanner {
    public static let defaultOverscanScreensPerSide = 10

    public static func retainedRange(
        visibleRows: Range<UInt64>,
        rowsVisible: UInt64,
        maximumRows: Int = ResourceViewInvalidation.maximumRetainedRowCount,
        overscanScreensPerSide: Int = defaultOverscanScreensPerSide
    ) -> Range<UInt64> {
        guard rowsVisible > 0, maximumRows > 0 else { return 0..<0 }

        let maximum = min(UInt64(maximumRows), rowsVisible)
        let visibleLower = min(visibleRows.lowerBound, rowsVisible - 1)
        let visibleUpper = min(
            rowsVisible,
            max(visibleLower + 1, visibleRows.upperBound)
        )
        let visibleCount = min(maximum, visibleUpper - visibleLower)
        let overscanCount = visibleCount.multipliedReportingOverflow(
            by: UInt64(max(0, overscanScreensPerSide))
        )
        let totalOverscan: UInt64
        if overscanCount.overflow || overscanCount.partialValue > maximum / 2 {
            totalOverscan = maximum
        } else {
            totalOverscan = min(maximum, overscanCount.partialValue * 2)
        }
        let desiredCount = min(
            maximum,
            visibleCount + min(maximum - visibleCount, totalOverscan)
        )
        let extra = desiredCount - visibleCount
        let preferredBefore = extra / 2
        var lower = visibleLower > preferredBefore
            ? visibleLower - preferredBefore
            : 0
        var upper = min(rowsVisible, lower + desiredCount)
        if upper - lower < desiredCount {
            lower = upper > desiredCount ? upper - desiredCount : 0
            upper = min(rowsVisible, lower + desiredCount)
        }
        return lower..<upper
    }
}

/// A bounded sparse cache for the currently visible resource-table window.
///
/// It deliberately stores rows by numeric index only for one exact
/// generation/presentation/index triple. It never materializes the complete
/// UID order, and changing any revision drops rows before an old response can
/// be rebound to a new presentation.
public struct ResourceViewRangeCache: Sendable {
    public let sessionID: String
    public let viewID: String
    public let generation: UInt64
    public let maximumCachedRows: Int

    public private(set) var revision: ResourceViewRevision?
    public private(set) var rowsVisible: UInt64 = 0
    public private(set) var maxRangeLength =
        ResourceViewInvalidation.protocolMaximumRangeLength
    public private(set) var retainedRange: Range<UInt64>?

    private var rowByIndex: [UInt64: ResourceRow] = [:]
    private var pendingRequests: Set<ResourceViewRangeRequest> = []

    public init(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        maximumCachedRows: Int = ResourceViewInvalidation.maximumRetainedRowCount
    ) {
        precondition(!sessionID.isEmpty)
        precondition(!viewID.isEmpty)
        precondition(generation > 0)
        precondition(maximumCachedRows > 0)
        self.sessionID = sessionID
        self.viewID = viewID
        self.generation = generation
        self.maximumCachedRows = maximumCachedRows
    }

    public var cachedRowCount: Int { rowByIndex.count }

    public func row(at index: UInt64) -> ResourceRow? {
        guard index < rowsVisible else { return nil }
        return rowByIndex[index]
    }

    /// Returns a complete contiguous slice only when every requested numeric
    /// index is resident for the current exact revision. Callers never need to
    /// materialize the backend's complete UID order to project this window.
    public func rows(in range: Range<UInt64>) -> [ResourceRow]? {
        guard range.lowerBound <= range.upperBound,
            range.upperBound <= rowsVisible
        else { return nil }
        var rows: [ResourceRow] = []
        rows.reserveCapacity(Int(range.count))
        for index in range {
            guard let row = rowByIndex[index] else { return nil }
            rows.append(row)
        }
        return rows
    }

    public func containsPendingRequest(_ request: ResourceViewRangeRequest) -> Bool {
        pendingRequests.contains(request)
    }

    /// Applies one control-stream invalidation. Identical revisions preserve
    /// cached rows because the event can be a keys-only advisory update.
    @discardableResult
    public mutating func receive(
        cursor: StreamCursor,
        invalidation: ResourceViewInvalidation
    ) -> ResourceViewInvalidationDisposition {
        guard cursor.generation == generation,
            invalidation.hasValidRangeContract
        else { return .rejectedInvalid }

        let nextRevision = invalidation.revision(generation: generation)
        guard let current = revision else {
            revision = nextRevision
            rowsVisible = invalidation.rowsVisible
            maxRangeLength = invalidation.maxRangeLength
            trimRetentionToVisibleRows()
            return .installed
        }

        if nextRevision == current {
            guard invalidation.rowsVisible == rowsVisible,
                invalidation.maxRangeLength == maxRangeLength
            else { return .rejectedInvalid }
            return .hintsOnly
        }

        guard nextRevision.presentation > current.presentation,
            nextRevision.index >= current.index
        else { return .rejectedStale }
        guard nextRevision.index > current.index
                || invalidation.rowsVisible == rowsVisible
        else { return .rejectedInvalid }

        let indexChanged = nextRevision.index != current.index
        revision = nextRevision
        rowsVisible = invalidation.rowsVisible
        maxRangeLength = invalidation.maxRangeLength
        rowByIndex.removeAll(keepingCapacity: true)
        pendingRequests.removeAll(keepingCapacity: true)
        trimRetentionToVisibleRows()
        return .advanced(indexChanged: indexChanged)
    }

    /// Keeps only the visible/overscan window and returns bounded requests for
    /// chunks that are neither cached nor already in flight.
    @discardableResult
    public mutating func retain(
        _ requestedRange: Range<UInt64>
    ) -> [ResourceViewRangeRequest] {
        guard let revision else {
            retainedRange = nil
            return []
        }

        let bounded = boundedRetentionRange(requestedRange)
        retainedRange = bounded
        rowByIndex = rowByIndex.filter { bounded.contains($0.key) }
        pendingRequests = pendingRequests.filter {
            requestRange($0).overlaps(bounded)
        }
        guard !bounded.isEmpty else { return [] }

        var requests: [ResourceViewRangeRequest] = []
        var index = bounded.lowerBound
        while index < bounded.upperBound {
            if rowByIndex[index] != nil || isPending(index) {
                index += 1
                continue
            }

            let chunkStart = index
            while index < bounded.upperBound,
                index - chunkStart < UInt64(maxRangeLength),
                rowByIndex[index] == nil,
                !isPending(index)
            {
                index += 1
            }
            let chunkLength = index - chunkStart
            guard chunkLength > 0 else { continue }
            let request = ResourceViewRangeRequest(
                sessionID: sessionID,
                viewID: viewID,
                revision: revision,
                startIndex: chunkStart,
                length: Int(chunkLength)
            )
            pendingRequests.insert(request)
            requests.append(request)
        }
        return requests
    }

    /// Releases an in-flight marker after a transport failure so the current
    /// viewport can retry it without changing revisions.
    public mutating func release(_ request: ResourceViewRangeRequest) {
        pendingRequests.remove(request)
    }

    /// Installs a range only when it is the exact response to one current,
    /// outstanding request. Late generation or revision responses are ignored.
    @discardableResult
    public mutating func receive(
        _ response: ResourceViewRange,
        for request: ResourceViewRangeRequest
    ) -> ResourceViewRangeReception {
        guard pendingRequests.remove(request) != nil else {
            return .rejectedRace
        }
        guard let revision,
            request.sessionID == sessionID,
            request.viewID == viewID,
            request.revision == revision,
            response.viewID == viewID,
            response.revision == revision
        else { return .rejectedRace }
        guard request.hasValidLength,
            response.startIndex == request.startIndex,
            response.rowsVisible == rowsVisible,
            response.startIndex <= rowsVisible
        else { return .rejectedInvalid }

        let available = rowsVisible - response.startIndex
        let expectedCount = min(UInt64(request.length), available)
        guard UInt64(response.rows.count) == expectedCount else {
            return .rejectedInvalid
        }
        let responseEnd = response.startIndex + expectedCount
        let installedRange = response.startIndex..<responseEnd
        if let retainedRange {
            for (offset, row) in response.rows.enumerated() {
                let index = response.startIndex + UInt64(offset)
                if retainedRange.contains(index) {
                    rowByIndex[index] = row
                }
            }
        }
        return .installed(installedRange)
    }

    /// Produces the metric-interest hint for the retained window. Empty tables
    /// have no valid nonzero range and therefore produce no hint.
    public var metricInterest: ResourceMetricInterestRequest? {
        guard let revision, let retainedRange, !retainedRange.isEmpty else {
            return nil
        }
        return ResourceMetricInterestRequest(
            sessionID: sessionID,
            viewID: viewID,
            generation: generation,
            indexRevision: revision.index,
            startIndex: retainedRange.lowerBound,
            length: Int(retainedRange.count)
        )
    }

    /// A reconciliation is usable only while its exact presentation is still
    /// current. A later invalidation intentionally makes this return false.
    public func matches(
        cursor: StreamCursor,
        reconciliation: ResourceViewReconciliation
    ) -> Bool {
        cursor.generation == generation
            && reconciliation.rowsVisible == rowsVisible
            && reconciliation.revision(generation: generation) == revision
    }

    private mutating func trimRetentionToVisibleRows() {
        guard let retainedRange else { return }
        let bounded = boundedRetentionRange(retainedRange)
        self.retainedRange = bounded
        rowByIndex = rowByIndex.filter { bounded.contains($0.key) }
        pendingRequests = pendingRequests.filter {
            requestRange($0).overlaps(bounded)
        }
    }

    private func boundedRetentionRange(
        _ range: Range<UInt64>
    ) -> Range<UInt64> {
        let lower = min(range.lowerBound, rowsVisible)
        var upper = min(range.upperBound, rowsVisible)
        let maximum = UInt64(maximumCachedRows)
        if upper - lower > maximum {
            upper = lower + maximum
        }
        return lower..<upper
    }

    private func requestRange(
        _ request: ResourceViewRangeRequest
    ) -> Range<UInt64> {
        let length = UInt64(max(0, request.length))
        let (upper, overflow) = request.startIndex.addingReportingOverflow(length)
        return request.startIndex..<(overflow ? UInt64.max : upper)
    }

    private func isPending(_ index: UInt64) -> Bool {
        pendingRequests.contains { requestRange($0).contains(index) }
    }
}

public extension WorkspaceResourceProviding {
    func fetchViewRange(
        request: ResourceViewRangeRequest
    ) async throws -> ResourceViewRange {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "ViewRangeUnavailable",
            message: "This workspace provider does not expose range-backed resource rows.",
            retryable: false,
            operation: "fetch resource view range"
        )
    }

    func updateMetricInterest(
        request: ResourceMetricInterestRequest
    ) async throws {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "MetricInterestUnavailable",
            message: "This workspace provider does not accept metric viewport hints.",
            retryable: false,
            operation: "update metric interest"
        )
    }
}
