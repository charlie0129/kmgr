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

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async
    func closeSession(sessionID: String) async
}

public struct AnyWorkspaceResourceProvider: WorkspaceResourceProviding {
    private let discoverOperation: @Sendable (String, Bool) async throws -> ResourceDiscoveryResult
    private let namespacesOperation: @Sendable (String) async throws -> [String]
    private let streamOperation: @Sendable (ResourceViewRequest) -> AsyncThrowingStream<ResourceViewMessage, Error>
    private let cancelOperation: @Sendable (String, String, UInt64) async -> Void
    private let closeOperation: @Sendable (String) async -> Void

    public init<P: WorkspaceResourceProviding>(_ provider: P) {
        discoverOperation = provider.discoverResources
        namespacesOperation = provider.listNamespaces
        streamOperation = provider.streamView
        cancelOperation = provider.cancelView
        closeOperation = provider.closeSession
    }

    public func discoverResources(sessionID: String, refresh: Bool) async throws -> ResourceDiscoveryResult {
        try await discoverOperation(sessionID, refresh)
    }

    public func listNamespaces(sessionID: String) async throws -> [String] {
        try await namespacesOperation(sessionID)
    }

    public func streamView(request: ResourceViewRequest) -> AsyncThrowingStream<ResourceViewMessage, Error> {
        streamOperation(request)
    }

    public func cancelView(sessionID: String, viewID: String, generation: UInt64) async {
        await cancelOperation(sessionID, viewID, generation)
    }

    public func closeSession(sessionID: String) async {
        await closeOperation(sessionID)
    }
}

public struct ResourceViewRequest: Hashable, Sendable {
    public var sessionID: String
    public var viewID: String
    public var generation: UInt64
    public var resource: DiscoveredResource
    public var allNamespaces: Bool
    public var namespaces: [String]
    public var filterExpression: String
    public var filterRevision: UInt64
    public var columnIDs: [String]
    public var sort: [ResourceSortDescriptor]

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
        sort: [ResourceSortDescriptor] = []
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
        self.sort = sort
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
    case status(cursor: StreamCursor, status: ResourceViewStatus)
    case snapshot(cursor: StreamCursor, chunk: ResourceSnapshotChunk)
    case delta(cursor: StreamCursor, delta: ResourceRowDelta)
    case failure(cursor: StreamCursor, issue: ClusterManagerIssue)

    public var cursor: StreamCursor {
        switch self {
        case .status(let cursor, _), .snapshot(let cursor, _),
            .delta(let cursor, _), .failure(let cursor, _): cursor
        }
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

    public init(
        freshness: Freshness,
        objectsExamined: UInt64 = 0,
        rowsVisible: UInt64 = 0,
        lastSynchronizedAt: Date? = nil,
        fromWarmCache: Bool = false
    ) {
        self.freshness = freshness
        self.objectsExamined = objectsExamined
        self.rowsVisible = rowsVisible
        self.lastSynchronizedAt = lastSynchronizedAt
        self.fromWarmCache = fromWarmCache
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

public struct ResourceSnapshotChunk: Hashable, Sendable {
    public var rows: [ResourceRow]
    public var first: Bool
    public var last: Bool
    public var index: UInt64
    public var estimatedTotalRows: UInt64

    public init(
        rows: [ResourceRow],
        first: Bool,
        last: Bool,
        index: UInt64,
        estimatedTotalRows: UInt64
    ) {
        self.rows = rows
        self.first = first
        self.last = last
        self.index = index
        self.estimatedTotalRows = estimatedTotalRows
    }
}

public struct ResourceRowDelta: Hashable, Sendable {
    public var upserts: [ResourceRow]
    public var removedUIDs: Set<ResourceUID>
    public var orderedUIDs: [ResourceUID]
    public var orderIsComplete: Bool

    public init(
        upserts: [ResourceRow] = [],
        removedUIDs: Set<ResourceUID> = [],
        orderedUIDs: [ResourceUID] = [],
        orderIsComplete: Bool = false
    ) {
        self.upserts = upserts
        self.removedUIDs = removedUIDs
        self.orderedUIDs = orderedUIDs
        self.orderIsComplete = orderIsComplete
    }
}
