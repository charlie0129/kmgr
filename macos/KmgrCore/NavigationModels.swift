import Foundation

public struct NamespaceSelection: Hashable, Codable, Sendable {
    public var allNamespaces: Bool
    public var namespaces: [String]

    public init(allNamespaces: Bool = true, namespaces: [String] = []) {
        self.allNamespaces = allNamespaces
        self.namespaces = Array(Set(namespaces.filter { !$0.isEmpty })).sorted()
        if allNamespaces { self.namespaces = [] }
    }

    public static func namespace(_ value: String) -> Self {
        Self(allNamespaces: false, namespaces: [value])
    }

    public var presentation: String {
        if allNamespaces { return "All namespaces" }
        if namespaces.count == 1 { return namespaces[0] }
        return "\(namespaces.count) namespaces"
    }
}

public struct ResourceNavigationState: Hashable, Codable, Sendable {
    public var group: String
    public var version: String
    public var resource: String
    public var kind: String
    public var namespaced: Bool
    public var namespaceSelection: NamespaceSelection
    public var filter: String
    public var sortColumnID: String?
    public var sortDescending: Bool
    public var columns: [ColumnPresentationState]
    public var columnMoveOverrides: [ColumnMoveState]?
    public var columnMeasurementOverrides: [ColumnPresentationState]?
    public var selectedUIDs: Set<ResourceUID>
    public var scrollAnchor: ScrollAnchor?

    public init(
        group: String,
        version: String,
        resource: String,
        kind: String,
        namespaced: Bool = true,
        namespaceSelection: NamespaceSelection,
        filter: String = "",
        sortColumnID: String? = nil,
        sortDescending: Bool = false,
        columns: [ColumnPresentationState] = [],
        columnMoveOverrides: [ColumnMoveState]? = nil,
        columnMeasurementOverrides: [ColumnPresentationState]? = nil,
        selectedUIDs: Set<ResourceUID> = [],
        scrollAnchor: ScrollAnchor? = nil
    ) {
        self.group = group
        self.version = version
        self.resource = resource
        self.kind = kind
        self.namespaced = namespaced
        self.namespaceSelection = namespaceSelection
        self.filter = filter
        self.sortColumnID = sortColumnID
        self.sortDescending = sortDescending
        self.columns = columns
        self.columnMoveOverrides = columnMoveOverrides
        self.columnMeasurementOverrides = columnMeasurementOverrides
        self.selectedUIDs = selectedUIDs
        self.scrollAnchor = scrollAnchor
    }
}

public enum WorkspaceDestination: Hashable, Codable, Sendable {
    case resource(ResourceNavigationState)
    case object(ResourceIdentity, returnState: ResourceNavigationState)
    case subresource(ResourceIdentity, returnState: ResourceNavigationState)
}

/// Per-window filter memory keyed by exact Kubernetes resource identity. An
/// unseen GVR intentionally starts with an empty filter so a filter from Pods,
/// for example, cannot silently carry into Nodes.
public struct ResourceFilterMemory: Hashable, Sendable {
    public private(set) var filtersByGVR: [GVR: String]

    public init(filtersByGVR: [GVR: String] = [:]) {
        self.filtersByGVR = filtersByGVR
    }

    public mutating func switchResource(
        from currentGVR: GVR?,
        currentFilter: String,
        to nextGVR: GVR
    ) -> String {
        if let currentGVR {
            filtersByGVR[currentGVR] = currentFilter
        }
        return filtersByGVR[nextGVR] ?? ""
    }

    public mutating func remember(_ filter: String, for gvr: GVR) {
        filtersByGVR[gvr] = filter
    }

    public func filter(for gvr: GVR) -> String {
        filtersByGVR[gvr] ?? ""
    }
}

/// Finder-like per-window history. Replacing the current state is used while
/// the user edits filter/sort/selection; navigating pushes one entry and drops
/// only the forward branch.
public struct WorkspaceNavigationHistory: Hashable, Codable, Sendable {
    public private(set) var entries: [WorkspaceDestination]
    public private(set) var index: Int?

    public init(initial: WorkspaceDestination? = nil) {
        if let initial {
            entries = [initial]
            index = 0
        } else {
            entries = []
            index = nil
        }
    }

    public var current: WorkspaceDestination? {
        guard let index, entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    public var canGoBack: Bool { (index ?? 0) > 0 }
    public var canGoForward: Bool {
        guard let index else { return false }
        return index + 1 < entries.count
    }

    public mutating func replaceCurrent(with destination: WorkspaceDestination) {
        guard let index, entries.indices.contains(index) else {
            entries = [destination]
            self.index = 0
            return
        }
        entries[index] = destination
    }

    public mutating func navigate(to destination: WorkspaceDestination) {
        if let index, index + 1 < entries.count {
            entries.removeSubrange((index + 1)...)
        }
        if current == destination { return }
        entries.append(destination)
        index = entries.count - 1
    }

    @discardableResult
    public mutating func goBack() -> WorkspaceDestination? {
        guard canGoBack, let index else { return nil }
        self.index = index - 1
        return current
    }

    @discardableResult
    public mutating func goForward() -> WorkspaceDestination? {
        guard canGoForward, let index else { return nil }
        self.index = index + 1
        return current
    }

    /// Helper generations issue new cluster-session IDs. Navigation identity
    /// remains pinned to Kubernetes UID, but every future GET/mutation must use
    /// the freshly authenticated session rather than a dead helper's ID.
    public mutating func rebindClusterSessionID(_ sessionID: String) {
        entries = entries.map { destination in
            switch destination {
            case .resource:
                return destination
            case .object(var identity, let returnState):
                identity.clusterSessionID = sessionID
                return .object(identity, returnState: returnState)
            case .subresource(var identity, let returnState):
                identity.clusterSessionID = sessionID
                return .subresource(identity, returnState: returnState)
            }
        }
    }
}

public struct SidebarPin: Hashable, Codable, Sendable, Identifiable {
    public var group: String
    public var version: String
    public var resource: String

    public init(group: String, version: String, resource: String) {
        self.group = group
        self.version = version
        self.resource = resource
    }

    public var id: String { "\(group)/\(version)/\(resource)" }
}

public enum DefaultSidebarPins {
    public static let values: [SidebarPin] = [
        .init(group: "", version: "v1", resource: "pods"),
        .init(group: "apps", version: "v1", resource: "deployments"),
        .init(group: "apps", version: "v1", resource: "statefulsets"),
        .init(group: "apps", version: "v1", resource: "daemonsets"),
        .init(group: "", version: "v1", resource: "services"),
        .init(group: "", version: "v1", resource: "nodes"),
        .init(group: "", version: "v1", resource: "events"),
        .init(group: "", version: "v1", resource: "configmaps"),
        .init(group: "", version: "v1", resource: "secrets"),
    ]
}
