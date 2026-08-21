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
/// which input rejected retention without logging opaque equality results or
/// duplicating the policy in the AppKit layer.
public struct ResourceWarmRowDecision: Hashable, Sendable {
    public var hasExistingRows: Bool
    public var previousRowsWereSynchronized: Bool
    public var hasPreviousContext: Bool
    public var sameSession: Bool
    public var sameResource: Bool
    public var sameNamespaceSelection: Bool

    public init(
        hasExistingRows: Bool,
        previousRowsWereSynchronized: Bool,
        hasPreviousContext: Bool,
        sameSession: Bool,
        sameResource: Bool,
        sameNamespaceSelection: Bool
    ) {
        self.hasExistingRows = hasExistingRows
        self.previousRowsWereSynchronized = previousRowsWereSynchronized
        self.hasPreviousContext = hasPreviousContext
        self.sameSession = sameSession
        self.sameResource = sameResource
        self.sameNamespaceSelection = sameNamespaceSelection
    }

    public var canRetain: Bool {
        hasExistingRows
            && previousRowsWereSynchronized
            && hasPreviousContext
            && sameSession
            && sameResource
            && sameNamespaceSelection
    }
}

/// Pure policy for retaining the GUI's compact UID-keyed rows while a stopped
/// same-view watch is reopened. Only a completed prior ordering is safe to
/// hold atomically; an interrupted LIST must expose its replacement batches
/// progressively instead of waiting for final reconciliation.
public enum ResourceWarmRowPolicy {
    public static func decision(
        existingRowCount: Int,
        previousContext: ResourceWarmRowContext?,
        previousFreshness: ResourceViewStatus.Freshness?,
        nextContext: ResourceWarmRowContext
    ) -> ResourceWarmRowDecision {
        let previousRowsWereSynchronized = switch previousFreshness {
        case .watching?, .complete?: true
        default: false
        }
        return ResourceWarmRowDecision(
            hasExistingRows: existingRowCount > 0,
            previousRowsWereSynchronized: previousRowsWereSynchronized,
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
        previousFreshness: ResourceViewStatus.Freshness?,
        nextContext: ResourceWarmRowContext
    ) -> Bool {
        decision(
            existingRowCount: existingRowCount,
            previousContext: previousContext,
            previousFreshness: previousFreshness,
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
