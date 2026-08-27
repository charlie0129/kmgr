import Foundation

public struct DiscoveredResource: Hashable, Sendable {
    public var group: String
    public var version: String
    public var resource: String
    public var kind: String
    public var namespaced: Bool
    public var verbs: Set<String>
    public var shortNames: [String]
    public var categories: [String]
    public var preferredVersion: Bool

    public init(
        group: String,
        version: String,
        resource: String,
        kind: String,
        namespaced: Bool,
        verbs: Set<String> = [],
        shortNames: [String] = [],
        categories: [String] = [],
        preferredVersion: Bool = false
    ) {
        self.group = group
        self.version = version
        self.resource = resource
        self.kind = kind
        self.namespaced = namespaced
        self.verbs = verbs
        self.shortNames = shortNames
        self.categories = categories
        self.preferredVersion = preferredVersion
    }

    public var id: String { "\(group)/\(version)/\(resource)" }
}

/// One usable discovery snapshot. `resources` intentionally remains available
/// when `potentiallyIncomplete` is true; callers should render it while also
/// surfacing `warning` instead of replacing the sidebar with an error state.
public struct ResourceDiscoveryResult: Hashable, Sendable {
    public var resources: [DiscoveredResource]
    public var revision: String
    public var potentiallyIncomplete: Bool
    public var warning: ClusterManagerIssue?

    public init(
        resources: [DiscoveredResource],
        revision: String = "",
        potentiallyIncomplete: Bool = false,
        warning: ClusterManagerIssue? = nil
    ) {
        self.resources = resources
        self.revision = revision
        self.potentiallyIncomplete = potentiallyIncomplete
        self.warning = warning
    }
}

public protocol WorkspaceResourceProviding: Sendable {
    func discoverResources(sessionID: String, refresh: Bool) async throws -> ResourceDiscoveryResult
    func listNamespaces(sessionID: String) async throws -> [String]

    func streamView(
        request: ResourceViewRequest
    ) -> AsyncThrowingStream<ResourceViewMessage, Error>

    func fetchViewRange(
        request: ResourceViewRangeRequest
    ) async throws -> ResourceViewRange

    func updateMetricInterest(
        request: ResourceMetricInterestRequest
    ) async throws

    func applySelectionGesture(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        previousToken: String,
        gesture: ResourceSelectionGesture
    ) async throws -> ResourceSelectionState

    func projectSelectionRange(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        startIndex: UInt64,
        length: Int,
        token: String
    ) async throws -> ResourceSelectionProjection

    func fetchSelectionPage(
        sessionID: String,
        viewID: String,
        token: String,
        offset: UInt64,
        limit: Int
    ) async throws -> ResourceSelectionPage

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async
    func closeSession(sessionID: String) async
}

public struct ResourceViewRequest: Hashable, Sendable {
    public var sessionID: String
    public var viewID: String
    public var generation: UInt64
    public var resource: DiscoveredResource
    public var allNamespaces: Bool
    public var namespaces: [String]
    /// The complete query visible in the resource search field. Kubernetes
    /// selectors are derived from its explicit labelSelector:/fieldSelector:
    /// clauses by the engine; column-qualified terms resolve against the
    /// selected column IDs below.
    public var filterExpression: String
    public var filterRevision: UInt64
    public var columnIDs: [String]
    /// Stable content identity for the persisted column document used by the
    /// engine. It prevents an Open racing an atomic save from silently
    /// resolving the previous CEL program under a newly visible column ID.
    public var columnConfigurationVersion: String
    public var sort: [ResourceSortDescriptor]
    /// Keep a compatible rendered table visible while this generation builds
    /// its replacement. The stream will emit `.reconciled` after all payloads
    /// needed for one complete replacement have arrived.
    public var stageUntilReconciled: Bool
    /// Discard the retained resourceVersion and perform a fresh LIST/WATCH.
    /// This is used by the resource-local Restart Resource Stream action.
    public var forceRelist: Bool

    public init(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        resource: DiscoveredResource,
        allNamespaces: Bool,
        namespaces: [String],
        filterExpression: String = "",
        filterRevision: UInt64 = 0,
        columnIDs: [String] = [],
        columnConfigurationVersion: String = "",
        sort: [ResourceSortDescriptor] = [],
        stageUntilReconciled: Bool = false,
        forceRelist: Bool = false
    ) {
        self.sessionID = sessionID
        self.viewID = viewID
        self.generation = generation
        self.resource = resource
        self.allNamespaces = allNamespaces
        self.namespaces = namespaces
        self.filterExpression = filterExpression
        self.filterRevision = filterRevision
        self.columnIDs = columnIDs
        self.columnConfigurationVersion = columnConfigurationVersion
        self.sort = sort
        self.stageUntilReconciled = stageUntilReconciled
        self.forceRelist = forceRelist
    }
}

public struct ResourceSortDescriptor: Hashable, Sendable {
    public enum Direction: Hashable, Sendable { case ascending, descending }

    public var columnID: String
    public var direction: Direction
    public var nullsFirst: Bool

    public init(columnID: String, direction: Direction, nullsFirst: Bool = false) {
        self.columnID = columnID
        self.direction = direction
        self.nullsFirst = nullsFirst
    }
}

public enum ResourceViewMessage: Hashable, Sendable {
    case schema(cursor: StreamCursor, schema: ResourceViewSchema)
    case status(cursor: StreamCursor, status: ResourceViewStatus)
    case invalidation(cursor: StreamCursor, invalidation: ResourceViewInvalidation)
    case reconciled(cursor: StreamCursor, reconciliation: ResourceViewReconciliation)
    case failure(cursor: StreamCursor, issue: ClusterManagerIssue)

    public var cursor: StreamCursor {
        switch self {
        case .schema(let cursor, _), .status(let cursor, _),
            .invalidation(let cursor, _), .reconciled(let cursor, _),
            .failure(let cursor, _): cursor
        }
    }
}

/// The exact backend presentation named by a control-stream invalidation.
/// Numeric row indexes are meaningful only while all three revisions match.
public struct ResourceViewRevision: Hashable, Sendable {
    public var generation: UInt64
    public var presentation: UInt64
    public var index: UInt64

    public init(generation: UInt64, presentation: UInt64, index: UInt64) {
        self.generation = generation
        self.presentation = presentation
        self.index = index
    }

    public var isValid: Bool {
        generation > 0 && presentation > 0 && index > 0
    }
}

/// Announces a revision-pinned backend presentation without transporting its
/// complete rows or UID order. Repeated identical revisions carry hints only.
public struct ResourceViewInvalidation: Hashable, Sendable {
    /// One FetchViewRange response remains deliberately small so viewport
    /// retention can be filled by bounded IPC messages.
    public static let protocolMaximumRangeLength = 512
    /// Client-side retention may span several bounded range responses. This
    /// ceiling prevents an extreme viewport/overscan combination from
    /// retaining an unbounded projected-row window.
    public static let maximumRetainedRowCount = 8_192

    public var presentationRevision: UInt64
    public var indexRevision: UInt64
    public var rowsVisible: UInt64
    public var maxRangeLength: Int
    public var observedOptionalResourceKeys: Set<String>
    public var observedOptionalResourceKeysTruncated: Bool

    public init(
        presentationRevision: UInt64,
        indexRevision: UInt64,
        rowsVisible: UInt64,
        maxRangeLength: Int,
        observedOptionalResourceKeys: Set<String> = [],
        observedOptionalResourceKeysTruncated: Bool = false
    ) {
        self.presentationRevision = presentationRevision
        self.indexRevision = indexRevision
        self.rowsVisible = rowsVisible
        self.maxRangeLength = maxRangeLength
        self.observedOptionalResourceKeys = observedOptionalResourceKeys
        self.observedOptionalResourceKeysTruncated =
            observedOptionalResourceKeysTruncated
    }

    public func revision(generation: UInt64) -> ResourceViewRevision {
        ResourceViewRevision(
            generation: generation,
            presentation: presentationRevision,
            index: indexRevision
        )
    }

    public var hasValidRangeContract: Bool {
        presentationRevision > 0
            && indexRevision > 0
            && (1...Self.protocolMaximumRangeLength).contains(maxRangeLength)
    }
}

/// One bounded, immutable slice of a resource presentation.
public struct ResourceViewRange: Hashable, Sendable {
    public var viewID: String
    public var revision: ResourceViewRevision
    public var startIndex: UInt64
    public var rowsVisible: UInt64
    public var rows: [ResourceRow]

    public init(
        viewID: String,
        revision: ResourceViewRevision,
        startIndex: UInt64,
        rowsVisible: UInt64,
        rows: [ResourceRow]
    ) {
        self.viewID = viewID
        self.revision = revision
        self.startIndex = startIndex
        self.rowsVisible = rowsVisible
        self.rows = rows
    }
}

public struct ResourceViewRangeRequest: Hashable, Sendable {
    public var sessionID: String
    public var viewID: String
    public var revision: ResourceViewRevision
    public var startIndex: UInt64
    public var length: Int

    public init(
        sessionID: String,
        viewID: String,
        revision: ResourceViewRevision,
        startIndex: UInt64,
        length: Int
    ) {
        self.sessionID = sessionID
        self.viewID = viewID
        self.revision = revision
        self.startIndex = startIndex
        self.length = length
    }

    public var hasValidLength: Bool {
        (1...ResourceViewInvalidation.protocolMaximumRangeLength).contains(length)
    }
}

/// A debounced viewport hint for metric-backed display columns. Its numeric
/// range is pinned to one index revision and must never be silently rebound.
public struct ResourceMetricInterestRequest: Hashable, Sendable {
    public var sessionID: String
    public var viewID: String
    public var generation: UInt64
    public var indexRevision: UInt64
    public var startIndex: UInt64
    public var length: Int

    public init(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        startIndex: UInt64,
        length: Int
    ) {
        self.sessionID = sessionID
        self.viewID = viewID
        self.generation = generation
        self.indexRevision = indexRevision
        self.startIndex = startIndex
        self.length = length
    }

    public var hasValidRange: Bool {
        generation > 0
            && indexRevision > 0
            && (1...ResourceViewInvalidation.maximumRetainedRowCount).contains(length)
    }
}

/// One user selection action against an exact resource-view ordering.
public struct ResourceSelectionGesture: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case replace
        case commandToggle
        case shiftExtend
        case commandAll
        case clear
    }

    public var kind: Kind
    /// Required by row-targeting gestures and absent for command-all/clear.
    public var index: UInt64?
    /// Command-Shift extension. Meaningful only for `shiftExtend`.
    public var additive: Bool
    /// UID-authoritative target for a gesture captured from stale warm rows.
    public var targetUID: ResourceUID?
    /// UID-authoritative Shift anchor paired with `targetUID`.
    public var anchorUID: ResourceUID?

    public init(
        kind: Kind,
        index: UInt64? = nil,
        additive: Bool = false,
        targetUID: ResourceUID? = nil,
        anchorUID: ResourceUID? = nil
    ) {
        self.kind = kind
        self.index = index
        self.additive = additive
        self.targetUID = targetUID
        self.anchorUID = anchorUID
    }
}

public struct ResourceSelectionRevision: Hashable, Sendable {
    public var generation: UInt64
    public var indexRevision: UInt64

    public init(generation: UInt64, indexRevision: UInt64) {
        self.generation = generation
        self.indexRevision = indexRevision
    }

    public var isValid: Bool { generation > 0 && indexRevision > 0 }
}

public struct ResourceSelectionAnchor: Hashable, Sendable {
    public var index: UInt64
    public var uid: ResourceUID

    public init(index: UInt64, uid: ResourceUID) {
        self.index = index
        self.uid = uid
    }
}

/// Immutable token metadata returned after every selection gesture.
public struct ResourceSelectionState: Hashable, Sendable {
    public var token: String
    public var revision: ResourceSelectionRevision
    public var selectedCount: UInt64
    public var anchor: ResourceSelectionAnchor?
    public var expiresAt: Date?

    public init(
        token: String,
        revision: ResourceSelectionRevision,
        selectedCount: UInt64,
        anchor: ResourceSelectionAnchor? = nil,
        expiresAt: Date? = nil
    ) {
        self.token = token
        self.revision = revision
        self.selectedCount = selectedCount
        self.anchor = anchor
        self.expiresAt = expiresAt
    }

    public var generation: UInt64 { revision.generation }
    public var indexRevision: UInt64 { revision.indexRevision }
}

/// UID-based membership for one bounded range of the current view.
public struct ResourceSelectionProjection: Hashable, Sendable {
    public var viewID: String
    public var revision: ResourceSelectionRevision
    public var startIndex: UInt64
    public var rowsVisible: UInt64
    public var state: ResourceSelectionState
    public var selected: [Bool]
    /// Offset in `selected` when the token anchor is visible in this range.
    public var anchorOffset: Int?

    public init(
        viewID: String,
        revision: ResourceSelectionRevision,
        startIndex: UInt64,
        rowsVisible: UInt64,
        state: ResourceSelectionState,
        selected: [Bool],
        anchorOffset: Int? = nil
    ) {
        self.viewID = viewID
        self.revision = revision
        self.startIndex = startIndex
        self.rowsVisible = rowsVisible
        self.state = state
        self.selected = selected
        self.anchorOffset = anchorOffset
    }
}

public struct ResourceSelectionPageItem: Hashable, Sendable {
    public var pinnedIndex: UInt64
    public var identity: ResourceIdentity

    public init(pinnedIndex: UInt64, identity: ResourceIdentity) {
        self.pinnedIndex = pinnedIndex
        self.identity = identity
    }
}

/// One bounded page of identities from an immutable selection token.
public struct ResourceSelectionPage: Hashable, Sendable {
    public static let protocolMaximumPageSize = 1_024

    public var state: ResourceSelectionState
    public var offset: UInt64
    public var items: [ResourceSelectionPageItem]
    public var nextOffset: UInt64
    public var done: Bool

    public init(
        state: ResourceSelectionState,
        offset: UInt64,
        items: [ResourceSelectionPageItem],
        nextOffset: UInt64,
        done: Bool
    ) {
        self.state = state
        self.offset = offset
        self.items = items
        self.nextOffset = nextOffset
        self.done = done
    }
}

public extension WorkspaceResourceProviding {
    func applySelectionGesture(
        sessionID: String,
        viewID: String,
        generation: UInt64,
        indexRevision: UInt64,
        previousToken: String,
        gesture: ResourceSelectionGesture
    ) async throws -> ResourceSelectionState {
        throw selectionUnavailable(operation: "apply resource selection gesture")
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
        throw selectionUnavailable(operation: "project resource selection range")
    }

    func fetchSelectionPage(
        sessionID: String,
        viewID: String,
        token: String,
        offset: UInt64,
        limit: Int
    ) async throws -> ResourceSelectionPage {
        throw selectionUnavailable(operation: "fetch resource selection page")
    }

    private func selectionUnavailable(operation: String) -> ClusterManagerIssue {
        ClusterManagerIssue(
            category: .unavailable,
            reason: "SelectionTransportUnavailable",
            message: "This workspace provider does not expose token-backed resource selection.",
            retryable: false,
            operation: operation
        )
    }
}

/// Marks the ordered end of a complete replacement presentation for one
/// resource-view generation. A later invalidation may supersede it before the
/// client fetches a range, so consumers must still compare all revisions.
public struct ResourceViewReconciliation: Hashable, Sendable {
    public var rowsVisible: UInt64
    public var presentationRevision: UInt64
    public var indexRevision: UInt64

    public init(
        rowsVisible: UInt64,
        presentationRevision: UInt64,
        indexRevision: UInt64
    ) {
        self.rowsVisible = rowsVisible
        self.presentationRevision = presentationRevision
        self.indexRevision = indexRevision
    }

    public func revision(generation: UInt64) -> ResourceViewRevision {
        ResourceViewRevision(
            generation: generation,
            presentation: presentationRevision,
            index: indexRevision
        )
    }
}

public struct ResourceViewSchema: Hashable, Sendable {
    public var columns: [ColumnDefinition]
    public var serverTable: Bool
    public var revision: String

    public init(
        columns: [ColumnDefinition],
        serverTable: Bool,
        revision: String
    ) {
        self.columns = columns
        self.serverTable = serverTable
        self.revision = revision
    }
}

public struct ResourceViewStatus: Hashable, Sendable {
    public enum Freshness: Hashable, Sendable {
        case loading
        case stale
        case resuming
        case relisting
        case watching
        case reconnecting
        case failed
        case complete
    }

    public var freshness: Freshness
    public var objectsExamined: UInt64
    public var rowsVisible: UInt64
    public var lastSynchronizedAt: Date?
    public var fromWarmCache: Bool
    public var metricsReconciling: Bool

    public init(
        freshness: Freshness,
        objectsExamined: UInt64 = 0,
        rowsVisible: UInt64 = 0,
        lastSynchronizedAt: Date? = nil,
        fromWarmCache: Bool = false,
        metricsReconciling: Bool = false
    ) {
        self.freshness = freshness
        self.objectsExamined = objectsExamined
        self.rowsVisible = rowsVisible
        self.lastSynchronizedAt = lastSynchronizedAt
        self.fromWarmCache = fromWarmCache
        self.metricsReconciling = metricsReconciling
    }

    /// Whether continuity work is happening in the background. The resource
    /// table stays usable while this is true; callers should pair the text with
    /// a small indeterminate progress indicator instead of covering the rows.
    public var showsProgress: Bool {
        switch freshness {
        case .loading, .resuming, .relisting, .reconnecting:
            true
        case .stale, .watching, .failed, .complete:
            false
        }
    }

    /// Stale rows remain useful, but their age must remain visible and advance
    /// even when the server emits no further status messages.
    public var needsAgeRefresh: Bool {
        guard lastSynchronizedAt != nil else { return false }
        return switch freshness {
        case .stale, .resuming, .relisting, .reconnecting, .failed:
            true
        case .loading, .watching, .complete:
            false
        }
    }

    /// Wait only until the text shown by `presentation(now:)` can change.
    /// Ages use seconds for the first minute, then minute/hour/day buckets, so
    /// continuing to wake every second after those boundaries wastes idle CPU.
    public func nextAgeRefreshDelay(now: Date = Date()) -> Duration? {
        guard needsAgeRefresh, let lastSynchronizedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(lastSynchronizedAt))
        let bucket: TimeInterval
        switch elapsed {
        case ..<60:
            bucket = 1
        case ..<3_600:
            bucket = 60
        case ..<86_400:
            bucket = 3_600
        default:
            bucket = 86_400
        }
        let nextBoundary = (floor(elapsed / bucket) + 1) * bucket
        let milliseconds = max(1, Int64(ceil((nextBoundary - elapsed) * 1_000)))
        return .milliseconds(milliseconds)
    }

    public var presentation: String { presentation(now: Date()) }

    public func presentation(now: Date) -> String {
        let age = lastSynchronizedAt.map {
            "\(Self.ageText(since: $0, now: now)) old"
        }
        switch freshness {
        case .loading:
            return "Loading…"
        case .stale:
            return age.map { "Cached · \($0)" } ?? "Cached · age unavailable"
        case .resuming:
            return age.map { "Resuming… · cached \($0)" } ?? "Resuming…"
        case .relisting:
            let progress = objectsExamined > 0
                ? "Relisting… \(objectsExamined.formatted()) loaded"
                : "Relisting…"
            return age.map { "\(progress) · cached \($0)" } ?? progress
        case .watching:
            return "Watching"
        case .reconnecting:
            return age.map { "Reconnecting… · last synchronized \($0)" }
                ?? "Reconnecting… · last synchronization unknown"
        case .failed:
            return age.map { "Failed · last synchronized \($0)" } ?? "Failed"
        case .complete:
            return "Complete"
        }
    }

    private static func ageText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
