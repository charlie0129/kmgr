import Foundation

/// Resource kinds on which one optimized native extractor is valid.
public enum NativeColumnResourceScope: Hashable, Sendable {
    case any
    case pods
    case nodes
    case podsAndNodes
    case replicaWorkloads

    public func supports(group: String, version: String, resource: String) -> Bool {
        let isPod = group.isEmpty && version == "v1" && resource == "pods"
        let isNode = group.isEmpty && version == "v1" && resource == "nodes"
        return switch self {
        case .any: true
        case .pods: isPod
        case .nodes: isNode
        case .podsAndNodes: isPod || isNode
        case .replicaWorkloads:
            Self.isReplicaWorkload(
                group: group,
                version: version,
                resource: resource
            )
        }
    }

    private static func isReplicaWorkload(
        group: String,
        version: String,
        resource: String
    ) -> Bool {
        guard version == "v1" else { return false }
        if group == "apps" {
            return switch resource {
            case "deployments", "statefulsets", "daemonsets", "replicasets": true
            default: false
            }
        }
        return group.isEmpty && resource == "replicationcontrollers"
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

/// One resource-filtered catalog entry and whether the current draft already
/// contains its display ID or exact native extractor identity.
public struct NativeColumnCatalogItem: Hashable, Sendable {
    public var descriptor: NativeColumnDescriptor
    public var isAlreadyAdded: Bool

    public init(descriptor: NativeColumnDescriptor, isAlreadyAdded: Bool) {
        self.descriptor = descriptor
        self.isAlreadyAdded = isAlreadyAdded
    }

    public var exactIdentity: String {
        "\(descriptor.source.rawValue):\(descriptor.value)"
    }
}

public enum NativeColumnCatalogError: Error, Hashable, Sendable, LocalizedError {
    case exactResourcesUnsupported
    case invalidExactResourceName(String)

    public var errorDescription: String? {
        switch self {
        case .exactResourcesUnsupported:
            "Exact scheduler resources are supported only for core/v1 Pods and Nodes."
        case .invalidExactResourceName(let value):
            "\(value.debugDescription) is not a valid Kubernetes qualified resource name."
        }
    }
}

public enum NativeColumnCatalog {
    public static let descriptors: [NativeColumnDescriptor] = [
        builtin("namespace", "Namespace", .string, .leading, 150, .any),
        builtin("name", "Name", .string, .leading, 280, .any),
        builtin("kind", "Kind", .string, .leading, 120, .any),
        builtin("status", "Status", .string, .leading, 130, .any),
        builtin("roles", "Roles", .string, .leading, 160, .nodes),
        builtin("taints", "Taints", .integer, .trailing, 75, .nodes),
        builtin("ip", "IP", .string, .leading, 220, .nodes),
        builtin(
            "replicas", "Replicas (A/R/T)", .string, .center, 120,
            .replicaWorkloads
        ),
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

    public static func items(
        group: String,
        version: String,
        resource: String,
        existingColumns: [ColumnDefinition]
    ) -> [NativeColumnCatalogItem] {
        let usedIDs = Set(existingColumns.map(\.id))
        return descriptors.compactMap { descriptor -> NativeColumnCatalogItem? in
            guard descriptor.resourceScope.supports(
                group: group,
                version: version,
                resource: resource
            ) else { return nil }
            let defaultDefinition = descriptor.definition()
            let alreadyAdded = usedIDs.contains(defaultDefinition.id) ||
                existingColumns.contains { definition in
                    definition.source == descriptor.source && definition.value == descriptor.value
                }
            return NativeColumnCatalogItem(
                descriptor: descriptor,
                isAlreadyAdded: alreadyAdded
            )
        }
    }

    public static func supportsExactResources(
        group: String,
        version: String,
        resource: String
    ) -> Bool {
        group.isEmpty && version == "v1" && (resource == "pods" || resource == "nodes")
    }

    /// Builds a disabled definition for one exact scheduler resource. The full
    /// qualified name is retained in the extractor value. The stable UI ID is
    /// derived reversibly from that value, so even characters AppKit reserves
    /// for identifier paths cannot weaken or conflate the resource identity.
    public static func exactResourceDefinition(
        resourceName input: String,
        title inputTitle: String? = nil,
        group: String,
        version: String,
        resource: String
    ) throws -> ColumnDefinition {
        guard supportsExactResources(group: group, version: version, resource: resource) else {
            throw NativeColumnCatalogError.exactResourcesUnsupported
        }
        let resourceName = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KubernetesQualifiedName.isValid(resourceName) else {
            throw NativeColumnCatalogError.invalidExactResourceName(resourceName)
        }
        let preferredTitle = inputTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = "resource:\(resourceName)"
        return ColumnDefinition(
            id: exactResourceColumnID(resourceName: resourceName),
            title: preferredTitle?.isEmpty == false ? preferredTitle! : resourceName,
            source: .metric,
            value: value,
            type: .resourceUsage,
            alignment: .trailing,
            width: 230,
            enabled: false
        )
    }

    public static func exactResourceColumnID(resourceName: String) -> String {
        "resource-" + Data(resourceName.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
            values += [
                "status", "roles", "taints", "ip",
                "cpu", "memory", "ephemeral-storage", "age",
            ]
        } else if NativeColumnResourceScope.replicaWorkloads.supports(
            group: group,
            version: version,
            resource: resource
        ) {
            values += ["replicas", "status", "age"]
        } else {
            values += ["status", "age"]
        }
        return values.compactMap { value in
            // Ephemeral storage remains in the default definition set so it
            // is immediately discoverable and can be enabled in Columns, but
            // does not consume table width or activate a provider by default.
            descriptor(value: value)?.definition(
                enabled: value != "ephemeral-storage"
            )
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

/// Kubernetes qualified-name validation shared by exact resource entry and
/// other GUI-side inputs. It mirrors `validation.IsQualifiedName`: an optional
/// lowercase DNS subdomain prefix and one 63-byte alphanumeric-delimited name.
public enum KubernetesQualifiedName {
    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return validName(String(parts[0]))
        case 2:
            return validDNSSubdomain(String(parts[0])) && validName(String(parts[1]))
        default:
            return false
        }
    }

    /// Mirrors Kubernetes' `IsExtendedResourceName`: unqualified and
    /// kubernetes.io names are native resources, `requests.` is reserved for
    /// quota names, and the quota form must itself remain a qualified name.
    public static func isValidExtendedResource(_ value: String) -> Bool {
        value.contains("/") &&
            !value.contains("kubernetes.io/") &&
            !value.hasPrefix("requests.") &&
            isValid("requests." + value)
    }

    private static func validName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 63 && isAlphaNumeric(bytes[0]) &&
            isAlphaNumeric(bytes[bytes.count - 1]) && bytes.allSatisfy(isNameByte)
    }

    private static func validDNSSubdomain(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 253 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { segment in
            let segmentBytes = Array(segment.utf8)
            return !segmentBytes.isEmpty && segmentBytes.count <= 63 &&
                isLowerAlphaNumeric(segmentBytes[0]) &&
                isLowerAlphaNumeric(segmentBytes[segmentBytes.count - 1]) &&
                segmentBytes.allSatisfy { isLowerAlphaNumeric($0) || $0 == 45 }
        }
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        isLowerAlphaNumeric(byte) || (65...90).contains(byte)
    }

    private static func isLowerAlphaNumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }
}
