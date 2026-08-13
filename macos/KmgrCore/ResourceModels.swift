import Foundation

/// A Kubernetes UID. A resource table is scoped to one cluster session, so the
/// UID is the authoritative row key inside that table.
public struct ResourceUID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }
}

/// The complete identity carried over IPC for every compact resource row.
///
/// Namespace/name is deliberately presentation metadata, not the key used for
/// selection. Kubernetes may recreate that name with a different UID.
public struct ResourceIdentity: Hashable, Codable, Sendable {
    public var clusterSessionID: String
    public var group: String
    public var version: String
    public var resource: String
    public var namespace: String
    public var name: String
    public var uid: ResourceUID

    public init(
        clusterSessionID: String,
        group: String,
        version: String,
        resource: String,
        namespace: String,
        name: String,
        uid: ResourceUID
    ) {
        self.clusterSessionID = clusterSessionID
        self.group = group
        self.version = version
        self.resource = resource
        self.namespace = namespace
        self.name = name
        self.uid = uid
    }
}

public enum CellSeverity: String, Codable, Sendable, CaseIterable {
    case normal
    case informational
    case warning
    case critical
}

/// Compact, already-computed resource usage sent to the GUI. Quantities used
/// for exact tooltips remain display strings; numeric values are for native
/// rendering and sorting and are never derived again from display text.
public struct ResourceUsageValue: Hashable, Codable, Sendable {
    public var usage: Double?
    public var request: Double?
    public var limit: Double?
    public var sortValue: Double?
    public var unit: String

    public init(
        usage: Double? = nil,
        request: Double? = nil,
        limit: Double? = nil,
        sortValue: Double? = nil,
        unit: String
    ) {
        self.usage = usage
        self.request = request
        self.limit = limit
        self.sortValue = sortValue
        self.unit = unit
    }
}

public enum CellTypedValue: Hashable, Codable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int64)
    case timestampUnixMilliseconds(Int64)
    case usage(ResourceUsageValue)
}

public struct Cell: Hashable, Codable, Sendable {
    public var columnID: String
    public var displayText: String
    public var typedValue: CellTypedValue?
    public var tooltip: String
    public var severity: CellSeverity

    public init(
        columnID: String,
        displayText: String,
        typedValue: CellTypedValue? = nil,
        tooltip: String = "",
        severity: CellSeverity = .normal
    ) {
        self.columnID = columnID
        self.displayText = displayText
        self.typedValue = typedValue
        self.tooltip = tooltip
        self.severity = severity
    }
}

/// A table row contains no raw Kubernetes object. It is small enough to apply
/// in UI batches and remains keyed by its Kubernetes UID.
public struct ResourceRow: Hashable, Codable, Sendable {
    public var identity: ResourceIdentity
    public var cells: [Cell]

    public init(identity: ResourceIdentity, cells: [Cell]) {
        self.identity = identity
        self.cells = cells
    }

    public subscript(columnID: String) -> Cell? {
        cells.first { $0.columnID == columnID }
    }
}
