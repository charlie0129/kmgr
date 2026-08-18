import Foundation

/// Exact session/GVR/scope data context for rows retained by the AppKit
/// resource list. Filter, sort, and column reprojections deliberately share
/// this context so the last usable rows can remain visible while their
/// replacement projection loads. A helper session is included deliberately:
/// rows must never cross a cluster-session boundary merely because two
/// sessions expose the same GVR and scope.
public struct ResourceWarmRowContext: Hashable, Sendable {
    public var sessionID: String
    public var gvr: GVR
    public var namespaceSelection: NamespaceSelection

    public init(
        sessionID: String,
        gvr: GVR,
        namespaceSelection: NamespaceSelection
    ) {
        self.sessionID = sessionID
        self.gvr = gvr
        self.namespaceSelection = namespaceSelection
    }
}

/// Explains the exact local decision made before a replacement resource
/// stream opens. Keeping the comparison structured lets diagnostics identify
/// which context component rejected retention without logging opaque equality
/// results or duplicating the policy in the AppKit layer.
public struct ResourceWarmRowDecision: Hashable, Sendable {
    public var hasExistingRows: Bool
    public var hasPreviousContext: Bool
    public var sameSession: Bool
    public var sameResource: Bool
    public var sameNamespaceSelection: Bool

    public init(
        hasExistingRows: Bool,
        hasPreviousContext: Bool,
        sameSession: Bool,
        sameResource: Bool,
        sameNamespaceSelection: Bool
    ) {
        self.hasExistingRows = hasExistingRows
        self.hasPreviousContext = hasPreviousContext
        self.sameSession = sameSession
        self.sameResource = sameResource
        self.sameNamespaceSelection = sameNamespaceSelection
    }

    public var canRetain: Bool {
        hasExistingRows
            && hasPreviousContext
            && sameSession
            && sameResource
            && sameNamespaceSelection
    }
}

/// Builds a replacement table without mutating the table currently rendered
/// by AppKit. Loading snapshots may be empty or contain only the LIST pages
/// received so far; neither is a reason to remove retained rows before the
/// engine's ordered reconciliation barrier arrives.
public struct ResourceStagedReconciliation: Hashable, Sendable {
    public private(set) var model = ResourceTableModel()
    public private(set) var confirmedRemovedUIDs: Set<ResourceUID> = []
    public private(set) var observedOptionalResourceKeys: Set<String> = []
    public private(set) var observedOptionalResourceKeysTruncated = false
    private var snapshotUIDs: [ResourceUID] = []

    public init() {}

    public mutating func receive(_ chunk: ResourceSnapshotChunk) {
        if chunk.first {
            snapshotUIDs.removeAll(keepingCapacity: true)
        }
        let chunkUIDs = chunk.rows.map(\.identity.uid)
        snapshotUIDs.append(contentsOf: chunkUIDs)
        model.apply(ResourceRowBatch(
            upserts: chunk.rows,
            visibleOrder: chunk.last ? .replace(snapshotUIDs) : .append(chunkUIDs)
        ))
        observe(
            keys: chunk.observedOptionalResourceKeys,
            truncated: chunk.observedOptionalResourceKeysTruncated
        )
    }

    public mutating func receive(_ delta: ResourceRowDelta) {
        confirmedRemovedUIDs.formUnion(delta.removedUIDs)
        confirmedRemovedUIDs.subtract(delta.upserts.lazy
            .map(\.identity.uid)
            .filter { !delta.removedUIDs.contains($0) })
        model.apply(ResourceRowBatch(
            upserts: delta.upserts,
            removedUIDs: delta.removedUIDs,
            visibleOrder: delta.orderIsComplete
                ? .replace(delta.orderedUIDs) : .unchanged
        ))
        observe(
            keys: delta.observedOptionalResourceKeys,
            truncated: delta.observedOptionalResourceKeysTruncated
        )
    }

    public var visibleRowCount: Int { model.orderedVisibleUIDs.count }

    public func matches(_ reconciliation: ResourceViewReconciliation) -> Bool {
        UInt64(visibleRowCount) == reconciliation.rowsVisible
    }

    /// One mutation against the rendered model installs every staged cell and
    /// the final visible order. Only explicit Kubernetes tombstones remove
    /// hidden identities, preserving selection across filter changes.
    public var promotionBatch: ResourceRowBatch {
        ResourceRowBatch(
            upserts: model.rowByUID.values.sorted {
                $0.identity.uid.rawValue < $1.identity.uid.rawValue
            },
            removedUIDs: confirmedRemovedUIDs,
            visibleOrder: .replace(model.orderedVisibleUIDs)
        )
    }

    private mutating func observe(keys: Set<String>, truncated: Bool) {
        observedOptionalResourceKeys.formUnion(keys)
        observedOptionalResourceKeysTruncated =
            observedOptionalResourceKeysTruncated || truncated
    }
}

/// Pure policy for retaining the GUI's compact UID-keyed rows while a stopped
/// same-view watch is reopened.
public enum ResourceWarmRowPolicy {
    public static func decision(
        existingRowCount: Int,
        previousContext: ResourceWarmRowContext?,
        nextContext: ResourceWarmRowContext
    ) -> ResourceWarmRowDecision {
        ResourceWarmRowDecision(
            hasExistingRows: existingRowCount > 0,
            hasPreviousContext: previousContext != nil,
            sameSession: previousContext?.sessionID == nextContext.sessionID,
            sameResource: previousContext?.gvr == nextContext.gvr,
            sameNamespaceSelection:
                previousContext?.namespaceSelection == nextContext.namespaceSelection
        )
    }

    public static func canRetain(
        existingRowCount: Int,
        previousContext: ResourceWarmRowContext?,
        nextContext: ResourceWarmRowContext
    ) -> Bool {
        decision(
            existingRowCount: existingRowCount,
            previousContext: previousContext,
            nextContext: nextContext
        ).canRetain
    }

    /// Keeps the retained row count and synchronization age honest while the
    /// replacement snapshot is pending. A backend `watching` status can arrive
    /// just before its authoritative snapshot, so it remains visually
    /// `resuming` until that snapshot has actually reconciled the local rows.
    public static func refreshingStatus(
        backendStatus: ResourceViewStatus?,
        retainedRowCount: Int,
        lastSynchronizedAt: Date?
    ) -> ResourceViewStatus {
        var status = backendStatus ?? ResourceViewStatus(freshness: .loading)
        switch status.freshness {
        case .loading, .stale, .watching, .complete:
            status.freshness = .resuming
        case .resuming, .relisting, .reconnecting, .failed:
            break
        }
        status.rowsVisible = UInt64(max(0, retainedRowCount))
        status.lastSynchronizedAt = status.lastSynchronizedAt ?? lastSynchronizedAt
        status.fromWarmCache = true
        return status
    }
}
