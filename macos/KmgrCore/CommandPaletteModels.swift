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

public struct CachedObjectSearchRequest: Hashable, Sendable {
    public var sessionID: String
    public var namespaceScope: NamespaceSelection
    public var query: String
    public var resultLimit: UInt32
    public var examinationLimit: UInt32
    public var resourceFilters: [DiscoveredResource]

    public init(
        sessionID: String,
        namespaceScope: NamespaceSelection,
        query: String,
        resultLimit: UInt32 = 40,
        examinationLimit: UInt32 = 50_000,
        resourceFilters: [DiscoveredResource] = []
    ) {
        self.sessionID = sessionID
        self.namespaceScope = namespaceScope
        self.query = query
        self.resultLimit = resultLimit
        self.examinationLimit = examinationLimit
        self.resourceFilters = resourceFilters
    }
}

public struct CachedObjectSearchResponse: Hashable, Sendable {
    public var results: [ObjectSearchResult]
    public var objectsExamined: UInt64
    public var examinationTruncated: Bool

    public init(
        results: [ObjectSearchResult],
        objectsExamined: UInt64,
        examinationTruncated: Bool
    ) {
        self.results = results
        self.objectsExamined = objectsExamined
        self.examinationTruncated = examinationTruncated
    }
}

public struct ObjectSearchResult: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        case authoritative
        case cached
        case recent
    }

    public var identity: ResourceIdentity
    public var displayText: String
    public var detailText: String
    public var rank: Double
    public var stale: Bool
    public var origin: Origin

    public init(
        identity: ResourceIdentity,
        displayText: String,
        detailText: String,
        rank: Double,
        stale: Bool,
        origin: Origin? = nil
    ) {
        self.identity = identity
        self.displayText = displayText
        self.detailText = detailText
        self.rank = rank
        self.stale = stale
        self.origin = origin ?? (stale ? .cached : .authoritative)
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
    func searchCachedObjects(
        request: CachedObjectSearchRequest
    ) async throws -> CachedObjectSearchResponse
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

public struct RecentObject: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var openedAt: Date

    public init(identity: ResourceIdentity, openedAt: Date) {
        self.identity = identity
        self.openedAt = openedAt
    }
}

/// Process-local, session-scoped recents. It stores identities only—never raw
/// objects, Secret values, YAML, or mutable row data—and evicts by recency.
public actor RecentObjectStore {
    public static let shared = RecentObjectStore()

    private let maximumPerSession: Int
    private var valuesBySession: [String: [RecentObject]] = [:]

    public init(maximumPerSession: Int = 100) {
        precondition(maximumPerSession > 0)
        self.maximumPerSession = maximumPerSession
    }

    public func record(_ identity: ResourceIdentity, openedAt: Date = Date()) {
        guard !identity.clusterSessionID.isEmpty,
            !identity.version.isEmpty,
            !identity.resource.isEmpty,
            !identity.name.isEmpty,
            !identity.uid.rawValue.isEmpty
        else { return }
        let sessionID = identity.clusterSessionID
        var values = valuesBySession[sessionID, default: []]
        values.removeAll { Self.key($0.identity) == Self.key(identity) }
        values.insert(RecentObject(identity: identity, openedAt: openedAt), at: 0)
        if values.count > maximumPerSession {
            values.removeLast(values.count - maximumPerSession)
        }
        valuesBySession[sessionID] = values
    }

    public func recent(sessionID: String) -> [RecentObject] {
        valuesBySession[sessionID] ?? []
    }

    public func rebind(from oldSessionID: String, to newSessionID: String) {
        guard oldSessionID != newSessionID,
            var oldValues = valuesBySession.removeValue(forKey: oldSessionID)
        else { return }
        oldValues = oldValues.map { value in
            var rebound = value
            rebound.identity.clusterSessionID = newSessionID
            return rebound
        }
        var combined = oldValues + valuesBySession[newSessionID, default: []]
        combined.sort { $0.openedAt > $1.openedAt }
        var seen: Set<String> = []
        combined = combined.filter { seen.insert(Self.key($0.identity)).inserted }
        valuesBySession[newSessionID] = Array(combined.prefix(maximumPerSession))
    }

    private static func key(_ identity: ResourceIdentity) -> String {
        [identity.group, identity.version, identity.resource, identity.uid.rawValue]
            .joined(separator: "\u{0}")
    }
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

/// Destination requested when activating a command-palette item. Command-
/// Return deliberately means the alternate window destination while plain
/// Return keeps the historical in-place behavior.
public enum PaletteActivationDestination: Hashable, Sendable {
    case currentWorkspace
    case alternateWindow
}

/// A resource operation shown by the command palette. The operation carries
/// no live UI reference; activation is paired with the immutable
/// ``CommandContext`` captured before the palette opens.
public enum PaletteOperation: CaseIterable, Hashable, Sendable {
    case openDetails
    case openYAML
    case openEvents
    case openLogs
    case openExec
    case startPortForward
    case delete
    case scale
    case restart
    case editLabels
    case editAnnotations
    case copyName
    case copyNamespacedName
    case copyReference
    /// Kept after the existing operations so the established ⌘1…⌘9 order does
    /// not change when this searchable command is added.
    case editYAML

    public var commandID: CommandID {
        switch self {
        case .openDetails: .openDetails
        case .openYAML: .openYAML
        case .openEvents: .openEvents
        case .openLogs: .openLogs
        case .openExec: .openExec
        case .startPortForward: .startPortForward
        case .delete: .delete
        case .scale: .scale
        case .restart: .restart
        case .editLabels: .editLabels
        case .editAnnotations: .editAnnotations
        case .copyName: .copyName
        case .copyNamespacedName: .copyNamespacedName
        case .copyReference: .copyReference
        case .editYAML: .editYAMLInNewWindow
        }
    }

    public var title: String {
        switch self {
        case .openDetails: "Open Details"
        case .openYAML: "Open YAML in Details"
        case .openEvents: "Open Events"
        case .openLogs: "Open Logs…"
        case .openExec: "Open Terminal"
        case .startPortForward: "Start Port Forward…"
        case .delete: "Delete…"
        case .scale: "Scale…"
        case .restart: "Rollout Restart…"
        case .editLabels: "Edit Labels…"
        case .editAnnotations: "Edit Annotations…"
        case .copyName: "Copy Name"
        case .copyNamespacedName: "Copy Namespace/Name"
        case .copyReference: "Copy kubectl Reference"
        case .editYAML: "Edit YAML in New Window"
        }
    }

    fileprivate var searchTerms: [String] {
        switch self {
        case .openDetails: ["open details", "details", "inspect", "view"]
        case .openYAML: ["open yaml", "yaml", "manifest"]
        case .openEvents: ["open events", "events"]
        case .openLogs: ["open logs", "logs", "log"]
        case .openExec: ["open terminal", "terminal", "exec", "shell"]
        case .startPortForward: ["start port forward", "port forward", "port-forward", "forward"]
        case .delete: ["delete", "remove"]
        case .scale: ["scale", "replicas"]
        case .restart: ["rollout restart", "restart", "rollout"]
        case .editLabels: ["edit labels", "metadata labels", "labels"]
        case .editAnnotations: ["edit annotations", "metadata annotations", "annotations"]
        case .copyName: ["copy name", "name"]
        case .copyNamespacedName: ["copy namespace name", "namespace/name", "namespaced name"]
        case .copyReference: ["copy kubectl reference", "kubectl", "reference"]
        case .editYAML: ["edit yaml", "edit manifest", "yaml edit"]
        }
    }
}

public enum PaletteOperationRanking {
    /// Returns only operations valid for the captured responder and full
    /// identity selection. Stable declaration order is the empty-query rank;
    /// typed queries prefer exact terms, then prefixes, then substrings.
    public static func operations(
        query: String,
        context: CommandContext,
        limit: Int = 20
    ) -> [PaletteOperation] {
        let needle = normalized(query)
        let ranked = PaletteOperation.allCases.compactMap { operation -> (Int, PaletteOperation)? in
            guard CommandValidator.isEnabled(operation.commandID, in: context) else { return nil }
            guard !needle.isEmpty else { return (0, operation) }
            let terms = operation.searchTerms.map { normalized($0) }
            let score: Int
            if terms.contains(needle) {
                score = 1_000
            } else if terms.contains(where: { $0.hasPrefix(needle) }) {
                score = 800
            } else if terms.contains(where: { $0.contains(needle) }) {
                score = 500
            } else {
                return nil
            }
            return (score, operation)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            guard
                let lhs = PaletteOperation.allCases.firstIndex(of: $0.1),
                let rhs = PaletteOperation.allCases.firstIndex(of: $1.1)
            else { return $0.1.title < $1.1.title }
            return lhs < rhs
        }
        return ranked.prefix(max(0, limit)).map(\.1)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
            .joined(separator: " ")
    }
}

public enum PaletteRanking {
    public static func recentObjects(
        query: String,
        values: [RecentObject],
        matchingResources: [DiscoveredResource] = [],
        limit: Int = 20
    ) -> [PaletteResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let matchingGVRs = Set(matchingResources.map(resourceKey))
        return values.compactMap { value -> (Int, RecentObject)? in
            let name = value.identity.name.lowercased()
            let qualified = value.identity.namespace.isEmpty
                ? name : "\(value.identity.namespace.lowercased())/\(name)"
            let score: Int
            if name == needle { score = 1_000 }
            else if qualified == needle { score = 990 }
            else if name.hasPrefix(needle) { score = 900 }
            else if qualified.hasPrefix(needle) { score = 890 }
            else if name.contains(needle) { score = 700 }
            else if qualified.contains(needle) { score = 690 }
            else if matchingGVRs.contains(resourceKey(value.identity)) { score = 600 }
            else { return nil }
            return (score, value)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return $0.1.openedAt > $1.1.openedAt
        }.prefix(max(0, limit)).map { score, value in
            .object(ObjectSearchResult(
                identity: value.identity,
                displayText: value.identity.name,
                detailText: [
                    value.identity.namespace.isEmpty ? "cluster-scoped" : value.identity.namespace,
                    value.identity.resource,
                    "Recent",
                ].joined(separator: " · "),
                rank: Double(score) + 0.5,
                stale: true,
                origin: .recent
            ))
        }
    }

    public static func mergingObjects(
        recent: [PaletteResult],
        cached: [ObjectSearchResult],
        limit: Int = 30
    ) -> [PaletteResult] {
        var byIdentity: [String: ObjectSearchResult] = [:]
        for case .object(let value) in recent {
            byIdentity[identityKey(value.identity)] = value
        }
        for value in cached {
            let key = identityKey(value.identity)
            if byIdentity[key] == nil { byIdentity[key] = value }
        }
        return objects(Array(byIdentity.values), limit: limit)
    }

    private static func identityKey(_ identity: ResourceIdentity) -> String {
        [identity.group, identity.version, identity.resource, identity.uid.rawValue]
            .joined(separator: "\u{0}")
    }

    public static func resources(
        query: String,
        resources: [DiscoveredResource],
        limit: Int = 30
    ) -> [PaletteResult] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            return resources.prefix(limit).map(PaletteResult.resource)
        }
        return matchingResources(
            query: query,
            resources: resources,
            limit: max(0, limit / 2)
        ).flatMap { resource in
            [PaletteResult.resource(resource), PaletteResult.searchResource(resource)]
        }.prefix(limit).map { $0 }
    }

    /// Exact discovered resources matched by a root-palette kind query. The
    /// same list scopes supplemental recent/cache matches so entering a kind
    /// such as `pods` can show Pod `api` without turning into an all-resource
    /// network search.
    public static func matchingResources(
        query: String,
        resources: [DiscoveredResource],
        limit: Int = 15
    ) -> [DiscoveredResource] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
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
        }
        return ranked.prefix(max(0, limit)).map(\.1)
    }

    private static func resourceKey(_ value: DiscoveredResource) -> String {
        [value.group, value.version, value.resource].joined(separator: "\u{0}")
    }

    private static func resourceKey(_ value: ResourceIdentity) -> String {
        [value.group, value.version, value.resource].joined(separator: "\u{0}")
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
        var byIdentity: [String: ObjectSearchResult] = [:]
        for value in values { byIdentity[identityKey(value.identity)] = value }
        return byIdentity.values.sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.identity.namespace != $1.identity.namespace {
                return $0.identity.namespace < $1.identity.namespace
            }
            if $0.identity.name != $1.identity.name {
                return $0.identity.name < $1.identity.name
            }
            if $0.identity.group != $1.identity.group {
                return $0.identity.group < $1.identity.group
            }
            if $0.identity.version != $1.identity.version {
                return $0.identity.version < $1.identity.version
            }
            if $0.identity.resource != $1.identity.resource {
                return $0.identity.resource < $1.identity.resource
            }
            return $0.identity.uid.rawValue < $1.identity.uid.rawValue
        }.prefix(max(0, limit)).map(PaletteResult.object)
    }
}
