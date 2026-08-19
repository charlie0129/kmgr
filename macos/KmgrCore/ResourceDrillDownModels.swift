import Foundation

public struct ResourceDrillDownQuery: Hashable, Sendable {
    public var group: String
    public var version: String
    public var resource: String
    public var namespaceScope: NamespaceSelection
    public var filterExpression: String

    public init(
        group: String,
        version: String,
        resource: String,
        namespaceScope: NamespaceSelection,
        filterExpression: String
    ) {
        self.group = group
        self.version = version
        self.resource = resource
        self.namespaceScope = namespaceScope
        self.filterExpression = filterExpression
    }
}

public enum ResourceDrillDownPlan: Hashable, Sendable {
    case resource(ResourceDrillDownQuery)
    case containers(pod: ResourceIdentity, values: [PodContainerDetail])
}

/// Maps a freshly fetched, UID-authoritative object to the useful child view
/// entered by Return. The planner deliberately refuses selectors that the
/// bounded resource-filter grammar cannot represent without broadening them.
public enum ResourceDrillDownPlanner {
    public static func hasPotentialTarget(_ identity: ResourceIdentity) -> Bool {
        switch (identity.group, identity.version, identity.resource) {
        case ("", "v1", "pods"),
            ("", "v1", "nodes"),
            ("", "v1", "namespaces"),
            ("", "v1", "configmaps"),
            ("", "v1", "secrets"),
            ("", "v1", "services"),
            ("", "v1", "replicationcontrollers"),
            ("apps", "v1", "deployments"),
            ("apps", "v1", "statefulsets"),
            ("apps", "v1", "daemonsets"),
            ("apps", "v1", "replicasets"),
            ("batch", "v1", "jobs"):
            true
        default:
            false
        }
    }

    public static func plan(for detail: ObjectDetail) -> ResourceDrillDownPlan? {
        let identity = detail.identity
        switch (identity.group, identity.version, identity.resource) {
        case ("", "v1", "pods"):
            guard !detail.summaryFields.contains(where: {
                $0.sectionID == "containers" && $0.fieldID == "containersOmitted"
            }) else { return nil }
            let containers = ExecContainerCatalog.orderedDetails(from: detail.containers)
            return containers.isEmpty ? nil : .containers(pod: identity, values: containers)
        case ("", "v1", "nodes"):
            guard let filter = fieldFilter(path: "spec.nodeName", value: identity.name) else {
                return nil
            }
            return .resource(podQuery(
                scope: NamespaceSelection(),
                filterExpression: filter
            ))
        case ("", "v1", "namespaces"):
            guard !identity.name.isEmpty else { return nil }
            return .resource(podQuery(
                scope: .namespace(identity.name),
                filterExpression: ""
            ))
        case ("", "v1", "services"),
            ("", "v1", "replicationcontrollers"),
            ("apps", "v1", "deployments"),
            ("apps", "v1", "statefulsets"),
            ("apps", "v1", "daemonsets"),
            ("apps", "v1", "replicasets"),
            ("batch", "v1", "jobs"):
            guard let filter = selectorFilter(from: detail.summaryFields) else { return nil }
            let scope = identity.namespace.isEmpty
                ? NamespaceSelection() : .namespace(identity.namespace)
            return .resource(podQuery(scope: scope, filterExpression: filter))
        default:
            return nil
        }
    }

    private static func podQuery(
        scope: NamespaceSelection,
        filterExpression: String
    ) -> ResourceDrillDownQuery {
        ResourceDrillDownQuery(
            group: "",
            version: "v1",
            resource: "pods",
            namespaceScope: scope,
            filterExpression: filterExpression
        )
    }

    private static func selectorFilter(from fields: [ObjectSummaryField]) -> String? {
        let selectors = fields.filter { $0.sectionID == "selectors" }
        guard !selectors.isEmpty,
            !selectors.contains(where: {
                $0.fieldID == "selectorExpressions" || $0.fieldID == "selectorsOmitted"
            })
        else { return nil }

        let terms = selectors.compactMap { field -> String? in
            guard field.fieldID.hasPrefix("selector:"),
                safeFilterToken(field.label), safeFilterToken(field.displayText)
            else { return nil }
            return "label:\(field.label)==\(field.displayText)"
        }
        guard terms.count == selectors.count, !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
    }

    private static func fieldFilter(path: String, value: String) -> String? {
        guard safeFilterToken(path), safeFilterToken(value) else { return nil }
        return "field:\(path)==\(value)"
    }

    private static func safeFilterToken(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains(where: { $0.isWhitespace })
            && !value.contains("=")
            && !value.contains("\\")
            && !value.contains("\"")
            && !value.contains("'")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
