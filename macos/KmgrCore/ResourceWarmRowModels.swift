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

/// Pure policy for retaining the GUI's compact UID-keyed rows while a stopped
/// same-view watch is reopened. The engine intentionally starts a cold view
/// with one sealed empty snapshot while its asynchronous LIST is still
/// loading; that transport baseline is not evidence that previously rendered
/// Kubernetes objects disappeared.
public enum ResourceWarmRowPolicy {
    public static func canRetain(
        existingRowCount: Int,
        previousContext: ResourceWarmRowContext?,
        nextContext: ResourceWarmRowContext
    ) -> Bool {
        existingRowCount > 0 && previousContext == nextContext
    }

    /// Identifies only the engine's cold initial placeholder. A later empty
    /// snapshot received after loading has advanced remains authoritative and
    /// must clear rows when the Kubernetes result is genuinely empty.
    public static func preservesRetainedRows(
        for chunk: ResourceSnapshotChunk,
        backendStatus: ResourceViewStatus?,
        isRetainingWarmRows: Bool,
        isFirstSnapshotInStream: Bool
    ) -> Bool {
        isRetainingWarmRows
            && isFirstSnapshotInStream
            && backendStatus?.freshness == .loading
            && chunk.first
            && chunk.last
            && chunk.rows.isEmpty
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

    /// A reconciliation payload received while LIST/WATCH is authoritative
    /// can end the locally retained presentation. Keeping this separate from
    /// payload arrival handles either ordering: WATCHING then delta, or delta
    /// followed by WATCHING.
    public static func statusConfirmsAuthoritativeReconciliation(
        _ status: ResourceViewStatus?
    ) -> Bool {
        switch status?.freshness {
        case .watching, .complete:
            true
        default:
            false
        }
    }
}
