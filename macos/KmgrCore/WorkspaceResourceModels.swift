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

public protocol WorkspaceResourceProviding: Sendable {
    func discoverResources(sessionID: String, refresh: Bool) async throws -> [DiscoveredResource]
    func listNamespaces(sessionID: String) async throws -> [String]

    func streamView(
        request: ResourceViewRequest
    ) -> AsyncThrowingStream<ResourceViewMessage, Error>

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async
    func closeSession(sessionID: String) async
}

public struct AnyWorkspaceResourceProvider: WorkspaceResourceProviding {
    private let discoverOperation: @Sendable (String, Bool) async throws -> [DiscoveredResource]
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

    public func discoverResources(sessionID: String, refresh: Bool) async throws -> [DiscoveredResource] {
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

    public var presentation: String {
        switch freshness {
        case .loading: "Loading…"
        case .stale: "Cached"
        case .resuming: "Resuming…"
        case .relisting: objectsExamined > 0 ? "Relisting… \(objectsExamined.formatted()) loaded" : "Relisting…"
        case .watching: "Watching"
        case .reconnecting: "Reconnecting…"
        case .failed: "Failed"
        case .complete: "Complete"
        }
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
