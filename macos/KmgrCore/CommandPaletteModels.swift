import Foundation

public struct ObjectSearchRequest: Hashable, Sendable {
    public var sessionID: String
    public var searchID: String
    public var generation: UInt64
    public var queryRevision: UInt64
    public var resource: DiscoveredResource
    public var namespaceScope: NamespaceSelection
    public var query: String
    public var resultLimit: UInt32
    public var allowPaginatedList: Bool

    public init(
        sessionID: String,
        searchID: String,
        generation: UInt64,
        queryRevision: UInt64,
        resource: DiscoveredResource,
        namespaceScope: NamespaceSelection,
        query: String,
        resultLimit: UInt32 = 100,
        allowPaginatedList: Bool = true
    ) {
        self.sessionID = sessionID
        self.searchID = searchID
        self.generation = generation
        self.queryRevision = queryRevision
        self.resource = resource
        self.namespaceScope = namespaceScope
        self.query = query
        self.resultLimit = resultLimit
        self.allowPaginatedList = allowPaginatedList
    }
}

public struct ObjectSearchResult: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var displayText: String
    public var detailText: String
    public var rank: Double
    public var stale: Bool

    public init(
        identity: ResourceIdentity,
        displayText: String,
        detailText: String,
        rank: Double,
        stale: Bool
    ) {
        self.identity = identity
        self.displayText = displayText
        self.detailText = detailText
        self.rank = rank
        self.stale = stale
    }
}

public struct ObjectSearchProgress: Hashable, Sendable {
    public var queryRevision: UInt64
    public var objectsExamined: UInt64
    public var complete: Bool
    public var usedDirectGet: Bool
    public var reusableSnapshotAvailable: Bool

    public init(
        queryRevision: UInt64,
        objectsExamined: UInt64,
        complete: Bool,
        usedDirectGet: Bool,
        reusableSnapshotAvailable: Bool
    ) {
        self.queryRevision = queryRevision
        self.objectsExamined = objectsExamined
        self.complete = complete
        self.usedDirectGet = usedDirectGet
        self.reusableSnapshotAvailable = reusableSnapshotAvailable
    }
}

public struct ObjectSearchMessage: Hashable, Sendable {
    public var cursor: StreamCursor
    public var queryRevision: UInt64
    public var results: [ObjectSearchResult]
    public var progress: ObjectSearchProgress
    public var issue: ClusterManagerIssue?

    public init(
        cursor: StreamCursor,
        queryRevision: UInt64,
        results: [ObjectSearchResult],
        progress: ObjectSearchProgress,
        issue: ClusterManagerIssue? = nil
    ) {
        self.cursor = cursor
        self.queryRevision = queryRevision
        self.results = results
        self.progress = progress
        self.issue = issue
    }
}

public protocol ObjectSearchProviding: Sendable {
    func searchObjects(
        request: ObjectSearchRequest
    ) -> AsyncThrowingStream<ObjectSearchMessage, Error>
    func cancelSearch(
        sessionID: String,
        searchID: String,
        generation: UInt64,
        queryRevision: UInt64
    ) async
}

public enum PaletteResult: Hashable, Sendable {
    case resource(DiscoveredResource)
    case searchResource(DiscoveredResource)
    case namespace(String)
    case object(ObjectSearchResult)

    public var title: String {
        switch self {
        case .resource(let value): "Go to \(value.kind.isEmpty ? value.resource : value.kind)"
        case .searchResource(let value): "Search \(value.kind.isEmpty ? value.resource : value.kind)…"
        case .namespace(let value): "Use namespace \(value)"
        case .object(let value): value.displayText
        }
    }
}

public enum PaletteRanking {
    public static func resources(
        query: String,
        resources: [DiscoveredResource],
        limit: Int = 30
    ) -> [PaletteResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return resources.prefix(limit).map(PaletteResult.resource)
        }
        let ranked = resources.compactMap { resource -> (Int, DiscoveredResource)? in
            let kind = resource.kind.lowercased()
            let plural = resource.resource.lowercased()
            let aliases = resource.shortNames.map { $0.lowercased() }
            let values = [kind, plural] + aliases
            let score: Int
            if values.contains(needle) {
                score = 1_000
            } else if values.contains(where: { $0.hasPrefix(needle) }) {
                score = 800
            } else if values.contains(where: { $0.contains(needle) }) {
                score = 500
            } else {
                return nil
            }
            return (score, resource)
        }.sorted {
            $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 > $1.0
        }.prefix(max(0, limit / 2))
        return ranked.flatMap { _, resource in
            [PaletteResult.resource(resource), PaletteResult.searchResource(resource)]
        }.prefix(limit).map { $0 }
    }

    public static func namespaces(
        query: String,
        namespaces: [String],
        limit: Int = 10
    ) -> [PaletteResult] {
        var needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["namespace ", "namespace:", "ns ", "ns:"]
            where needle.hasPrefix(prefix)
        {
            needle = String(needle.dropFirst(prefix.count))
            break
        }
        guard !needle.isEmpty else { return [] }
        let ranked = Set(namespaces).compactMap { namespace -> (Int, String)? in
            let value = namespace.lowercased()
            let score: Int
            if value == needle { score = 1_000 }
            else if value.hasPrefix(needle) { score = 800 }
            else if value.contains(needle) { score = 500 }
            else { return nil }
            return (score, namespace)
        }.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0
        }
        return ranked.prefix(max(0, limit)).map { .namespace($0.1) }
    }

    public static func objects(
        _ values: [ObjectSearchResult],
        limit: Int = 100
    ) -> [PaletteResult] {
        var byUID: [ResourceUID: ObjectSearchResult] = [:]
        for value in values { byUID[value.identity.uid] = value }
        return byUID.values.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.identity.namespace != $1.identity.namespace {
                return $0.identity.namespace < $1.identity.namespace
            }
            if $0.identity.name != $1.identity.name {
                return $0.identity.name < $1.identity.name
            }
            return $0.identity.uid.rawValue < $1.identity.uid.rawValue
        }.prefix(max(0, limit)).map(PaletteResult.object)
    }
}
