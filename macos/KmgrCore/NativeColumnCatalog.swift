import Foundation

/// Resource kinds on which one optimized native extractor is valid.
public enum NativeColumnResourceScope: Hashable, Sendable {
    case any
    case pods
    case nodes
    case podsAndNodes

    public func supports(group: String, version: String, resource: String) -> Bool {
        let isPod = group.isEmpty && version == "v1" && resource == "pods"
        let isNode = group.isEmpty && version == "v1" && resource == "nodes"
        return switch self {
        case .any: true
        case .pods: isPod
        case .nodes: isNode
        case .podsAndNodes: isPod || isNode
        }
    }
}

/// The GUI-side half of the native-column contract. The shared contract
/// fixture is also parsed by the Go engine tests, so a type emitted here cannot
/// silently drift from the extractor type accepted by the engine.
public struct NativeColumnDescriptor: Hashable, Sendable {
    public var value: String
    public var title: String
    public var source: ColumnSource
    public var type: ColumnResultType
    public var alignment: ColumnAlignment
    public var width: Double
    public var resourceScope: NativeColumnResourceScope

    public init(
        value: String,
        title: String,
        source: ColumnSource,
        type: ColumnResultType,
        alignment: ColumnAlignment,
        width: Double,
        resourceScope: NativeColumnResourceScope
    ) {
        self.value = value
        self.title = title
        self.source = source
        self.type = type
        self.alignment = alignment
        self.width = width
        self.resourceScope = resourceScope
    }

    public func definition(id: String? = nil, enabled: Bool = true) -> ColumnDefinition {
        ColumnDefinition(
            id: id ?? value,
            title: title,
            source: source,
            value: value,
            type: type,
            alignment: alignment,
            width: width,
            enabled: enabled
        )
    }
}

public enum NativeColumnCatalog {
    public static let descriptors: [NativeColumnDescriptor] = [
        builtin("namespace", "Namespace", .string, .leading, 150, .any),
        builtin("name", "Name", .string, .leading, 280, .any),
        builtin("kind", "Kind", .string, .leading, 120, .any),
        builtin("status", "Status", .string, .leading, 130, .any),
        builtin("node", "Node", .string, .leading, 180, .pods),
        builtin("ready", "Ready", .string, .center, 70, .pods),
        builtin("restarts", "Restarts", .integer, .trailing, 75, .pods),
        builtin("age", "Age", .duration, .trailing, 75, .any),
        builtin("created", "Created", .timestamp, .trailing, 170, .any),
        builtin("resourceVersion", "Resource Version", .string, .leading, 160, .any),

        metric("cpu", "CPU", 190, .podsAndNodes),
        metric("memory", "Memory", 210, .podsAndNodes),
        metric("ephemeral-storage", "Ephemeral Storage", 230, .podsAndNodes),
        metric("cpu-requests", "CPU Requests", 200, .nodes),
        metric("cpu-limits", "CPU Limits", 200, .nodes),
        metric("memory-requests", "Memory Requests", 220, .nodes),
        metric("memory-limits", "Memory Limits", 220, .nodes),
        metric("ephemeral-storage-requests", "Ephemeral Storage Requests", 250, .nodes),
        metric("ephemeral-storage-limits", "Ephemeral Storage Limits", 250, .nodes),
        metric("pod-count", "Pods", 110, .nodes),
    ]

    public static func descriptor(source: ColumnSource, value: String) -> NativeColumnDescriptor? {
        descriptors.first { $0.source == source && $0.value == value }
    }

    public static func descriptor(value: String) -> NativeColumnDescriptor? {
        descriptors.first { $0.value == value }
    }

    /// Useful native defaults for a resource list. Optional exact resources
    /// such as huge pages and accelerators are added separately after cluster
    /// discovery or explicit user configuration.
    public static func defaultDefinitions(
        group: String,
        version: String,
        resource: String,
        namespaced: Bool
    ) -> [ColumnDefinition] {
        var values = namespaced ? ["namespace", "name"] : ["name"]
        if group.isEmpty && version == "v1" && resource == "pods" {
            values += [
                "ready", "status", "restarts", "node",
                "cpu", "memory", "ephemeral-storage", "age",
            ]
        } else if group.isEmpty && version == "v1" && resource == "nodes" {
            values += ["status", "cpu", "memory", "ephemeral-storage", "age"]
        } else {
            values += ["status", "age"]
        }
        return values.compactMap { value in
            descriptor(value: value)?.definition()
        }
    }

    /// Kmgr versions before the native contract was centralized wrote two
    /// incorrect declared types in their built-in layouts. Normalize only the
    /// exact definitions emitted by those versions; unrelated invalid custom
    /// definitions remain errors instead of being silently reinterpreted.
    @discardableResult
    public static func normalizeLegacyTypes(in document: inout ColumnsConfigurationDocument) -> Bool {
        var changed = false
        for viewIndex in document.views.indices {
            for columnIndex in document.views[viewIndex].columns.indices {
                var column = document.views[viewIndex].columns[columnIndex]
                guard column.source == .builtin, column.id == column.value else { continue }
                switch (column.value, column.type) {
                case ("ready", .number):
                    column.type = .string
                case ("age", .timestamp):
                    column.type = .duration
                default:
                    continue
                }
                document.views[viewIndex].columns[columnIndex] = column
                changed = true
            }
        }
        return changed
    }

    private static func builtin(
        _ value: String,
        _ title: String,
        _ type: ColumnResultType,
        _ alignment: ColumnAlignment,
        _ width: Double,
        _ scope: NativeColumnResourceScope
    ) -> NativeColumnDescriptor {
        NativeColumnDescriptor(
            value: value,
            title: title,
            source: .builtin,
            type: type,
            alignment: alignment,
            width: width,
            resourceScope: scope
        )
    }

    private static func metric(
        _ value: String,
        _ title: String,
        _ width: Double,
        _ scope: NativeColumnResourceScope
    ) -> NativeColumnDescriptor {
        NativeColumnDescriptor(
            value: value,
            title: title,
            source: .metric,
            type: .resourceUsage,
            alignment: .trailing,
            width: width,
            resourceScope: scope
        )
    }
}
