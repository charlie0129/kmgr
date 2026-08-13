import Foundation

/// Scheduler-accounted resource families that may add exact, cluster-specific
/// columns after the base Pod or Node rows are already visible.
public enum OptionalResourceCategory: String, CaseIterable, Hashable, Sendable {
    case ephemeralStorage
    case hugePage
    case accelerator
}

/// One exact Kubernetes ResourceName exposed by the cache-only catalog.
///
/// `exactKey` is authoritative. `displayName` is presentation only: two
/// vendors may deliberately use the same friendly label without their
/// quantities or column identities being merged.
public struct OptionalResourceCatalogEntry: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public var group: String
        public var version: String
        public var resource: String
        public var exactKey: String

        public init(
            group: String,
            version: String,
            resource: String,
            exactKey: String
        ) {
            self.group = group
            self.version = version
            self.resource = resource
            self.exactKey = exactKey
        }
    }

    public var exactKey: String
    public var category: OptionalResourceCategory
    public var isPresent: Bool
    public var displayName: String
    public var applicableResource: DiscoveredResource
    public var isExplicitlyConfigured: Bool

    public init(
        exactKey: String,
        category: OptionalResourceCategory,
        isPresent: Bool,
        displayName: String,
        applicableResource: DiscoveredResource,
        isExplicitlyConfigured: Bool = false
    ) {
        self.exactKey = exactKey
        self.category = category
        self.isPresent = isPresent
        self.displayName = displayName
        self.applicableResource = applicableResource
        self.isExplicitlyConfigured = isExplicitlyConfigured
    }

    public var id: ID {
        ID(
            group: applicableResource.group,
            version: applicableResource.version,
            resource: applicableResource.resource,
            exactKey: exactKey
        )
    }
}

/// Immutable input for a point-in-time, cache-only catalog query.
public struct OptionalResourceCatalogRequest: Hashable, Sendable {
    public var sessionID: String
    public var applicableResource: DiscoveredResource

    public init(
        sessionID: String,
        applicableResource: DiscoveredResource
    ) {
        self.sessionID = sessionID
        self.applicableResource = applicableResource
    }
}

/// The catalog and an honest description of the cache coverage used to build
/// it. These flags are preserved independently because a cache may exist while
/// its initial snapshot is still incomplete.
public struct OptionalResourceCatalog: Hashable, Sendable {
    public var requestID: String
    public var resources: [OptionalResourceCatalogEntry]
    public var nodesCacheAvailable: Bool
    public var podsCacheAvailable: Bool
    public var nodesSnapshotComplete: Bool
    public var podsSnapshotComplete: Bool
    public var potentiallyIncomplete: Bool

    public init(
        requestID: String,
        resources: [OptionalResourceCatalogEntry],
        nodesCacheAvailable: Bool,
        podsCacheAvailable: Bool,
        nodesSnapshotComplete: Bool,
        podsSnapshotComplete: Bool,
        potentiallyIncomplete: Bool
    ) {
        self.requestID = requestID
        self.resources = resources
        self.nodesCacheAvailable = nodesCacheAvailable
        self.podsCacheAvailable = podsCacheAvailable
        self.nodesSnapshotComplete = nodesSnapshotComplete
        self.podsSnapshotComplete = podsSnapshotComplete
        self.potentiallyIncomplete = potentiallyIncomplete
    }
}

public protocol OptionalResourceCatalogProviding: Sendable {
    func discoverOptionalResources(
        _ request: OptionalResourceCatalogRequest
    ) async throws -> OptionalResourceCatalog
}
