import Foundation

public struct NativeColumnResourcePattern: Hashable, Sendable {
    public var group: String
    public var version: String?
    public var resource: String
}

/// Exact Kubernetes resources on which one optimized native extractor is
/// valid. A nil pattern set is the deliberately small common metadata surface.
public struct NativeColumnResourceScope: Hashable, Sendable {
    private var patterns: Set<NativeColumnResourcePattern>?

    public static let any = Self(patterns: nil)

    public static func core(_ resources: String...) -> Self {
        exact(group: "", version: "v1", resources: resources)
    }

    public static func exact(
        group: String,
        version: String? = "v1",
        resources: [String]
    ) -> Self {
        Self(patterns: Set(resources.map {
            NativeColumnResourcePattern(group: group, version: version, resource: $0)
        }))
    }

    public static func combining(_ scopes: Self...) -> Self {
        guard !scopes.contains(where: { $0.patterns == nil }) else { return .any }
        return Self(patterns: Set(scopes.flatMap { $0.patterns ?? [] }))
    }

    public func supports(group: String, version: String, resource: String) -> Bool {
        guard let patterns else { return true }
        return patterns.contains {
            $0.group == group && $0.resource == resource
                && ($0.version == nil || $0.version == version)
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
    private static let pods = NativeColumnResourceScope.core("pods")
    private static let nodes = NativeColumnResourceScope.core("nodes")
    private static let podsAndNodes = NativeColumnResourceScope.combining(pods, nodes)
    private static let apps = NativeColumnResourceScope.exact(
        group: "apps",
        resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    )
    private static let replicaControllers = NativeColumnResourceScope.core(
        "replicationcontrollers"
    )
    private static let replicaWorkloads = NativeColumnResourceScope.combining(
        apps, replicaControllers
    )
    private static let podTemplates = NativeColumnResourceScope.combining(
        apps,
        replicaControllers,
        .exact(group: "batch", resources: ["jobs", "cronjobs"])
    )

    public static let descriptors: [NativeColumnDescriptor] = [
        builtin("namespace", "Namespace", .string, .leading, 150, .any),
        builtin("name", "Name", .string, .leading, 280, .any),
        builtin("kind", "Kind", .string, .leading, 120, .any),
        builtin("labels", "Labels", .string, .leading, 240, .any),
        builtin("age", "Age", .duration, .trailing, 75, .any),
        builtin("created", "Created", .timestamp, .trailing, 170, .any),
        builtin("resourceVersion", "Resource Version", .string, .leading, 160, .any),

        builtin("status", "Status", .string, .leading, 130, .combining(
            pods, nodes,
            .core("namespaces", "persistentvolumes", "persistentvolumeclaims"),
            .exact(group: "batch", resources: ["jobs"])
        )),

        // Pods and Nodes. Metrics API use is lazy; every other value comes
        // from the row object itself and never opens another resource stream.
        builtin("ready", "Ready", .string, .center, 80, .combining(
            pods,
            .exact(group: "apps", resources: ["deployments", "statefulsets"])
        )),
        builtin("restarts", "Restarts", .integer, .trailing, 75, pods),
        builtin("pod-ip", "IP", .string, .leading, 150, pods),
        builtin("node", "Node", .string, .leading, 180, pods),
        builtin("last-restart", "Last Restart", .timestamp, .trailing, 170, pods),
        builtin("service-account", "Service Account", .string, .leading, 160, pods),
        builtin("qos-class", "QoS", .string, .leading, 100, pods),
        builtin("readiness-gates", "Readiness Gates", .string, .leading, 180, pods),
        builtin("nominated-node", "Nominated Node", .string, .leading, 180, pods),
        builtin("roles", "Roles", .string, .leading, 160, nodes),
        builtin("taints", "Taints", .integer, .trailing, 75, nodes),
        builtin("internal-ip", "Internal IP", .string, .leading, 150, nodes),
        builtin("external-ip", "External IP", .string, .leading, 150, nodes),
        builtin("kubelet-version", "Kubelet Version", .string, .leading, 140, nodes),
        builtin("architecture", "Architecture", .string, .leading, 110, nodes),
        builtin("os-image", "OS Image", .string, .leading, 220, nodes),
        builtin("kernel-version", "Kernel", .string, .leading, 180, nodes),
        metric("cpu", "CPU", 190, podsAndNodes),
        metric("memory", "Memory", 210, podsAndNodes),
        metric("ephemeral-storage", "Ephemeral Storage", 230, podsAndNodes),

        // Workload controllers.
        builtin("up-to-date", "Up-to-date", .integer, .trailing, 95, .exact(
            group: "apps", resources: ["deployments", "daemonsets"]
        )),
        builtin("available", "Available", .integer, .trailing, 85, .exact(
            group: "apps", resources: ["deployments", "daemonsets"]
        )),
        builtin("desired", "Desired", .integer, .trailing, 75, .combining(
            .exact(group: "apps", resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]),
            replicaControllers
        )),
        builtin("current", "Current", .integer, .trailing, 75, .combining(
            .exact(group: "apps", resources: ["statefulsets", "daemonsets", "replicasets"]),
            replicaControllers
        )),
        builtin("updated", "Updated", .integer, .trailing, 80, .exact(
            group: "apps", resources: ["statefulsets"]
        )),
        builtin("ready-count", "Ready", .integer, .trailing, 75, .combining(
            .exact(group: "apps", resources: ["daemonsets", "replicasets"]),
            replicaControllers,
            .exact(group: "discovery.k8s.io", resources: ["endpointslices"])
        )),
        builtin("service", "Service", .string, .leading, 160, .exact(
            group: "apps", resources: ["statefulsets"]
        )),
        builtin("selector", "Selector", .string, .leading, 240, replicaWorkloads),
        builtin("containers", "Containers", .string, .leading, 180, podTemplates),
        builtin("images", "Images", .string, .leading, 260, podTemplates),

        // Batch and autoscaling/policy.
        builtin("completions", "Completions", .string, .center, 100, .exact(
            group: "batch", resources: ["jobs"]
        )),
        builtin("duration", "Duration", .duration, .trailing, 90, .exact(
            group: "batch", resources: ["jobs"]
        )),
        builtin("active", "Active", .integer, .trailing, 70, .exact(
            group: "batch", resources: ["jobs", "cronjobs"]
        )),
        builtin("succeeded", "Succeeded", .integer, .trailing, 85, .exact(
            group: "batch", resources: ["jobs"]
        )),
        builtin("failed", "Failed", .integer, .trailing, 70, .exact(
            group: "batch", resources: ["jobs"]
        )),
        builtin("schedule", "Schedule", .string, .leading, 140, .exact(
            group: "batch", resources: ["cronjobs"]
        )),
        builtin("suspended", "Suspended", .boolean, .center, 90, .exact(
            group: "batch", resources: ["cronjobs"]
        )),
        builtin("last-schedule", "Last Schedule", .timestamp, .trailing, 170, .exact(
            group: "batch", resources: ["cronjobs"]
        )),
        builtin("time-zone", "Time Zone", .string, .leading, 120, .exact(
            group: "batch", resources: ["cronjobs"]
        )),
        builtin("last-successful", "Last Successful", .timestamp, .trailing, 170, .exact(
            group: "batch", resources: ["cronjobs"]
        )),
        builtin("reference", "Reference", .string, .leading, 180, .exact(
            group: "autoscaling", version: nil, resources: ["horizontalpodautoscalers"]
        )),
        builtin("targets", "Targets", .string, .leading, 200, .exact(
            group: "autoscaling", version: nil, resources: ["horizontalpodautoscalers"]
        )),
        builtin("minimum", "Min", .integer, .trailing, 65, .exact(
            group: "autoscaling", version: nil, resources: ["horizontalpodautoscalers"]
        )),
        builtin("maximum", "Max", .integer, .trailing, 65, .exact(
            group: "autoscaling", version: nil, resources: ["horizontalpodautoscalers"]
        )),
        builtin("current-replicas", "Replicas", .integer, .trailing, 75, .exact(
            group: "autoscaling", version: nil, resources: ["horizontalpodautoscalers"]
        )),
        builtin("conditions", "Conditions", .string, .leading, 240, .exact(
            group: "autoscaling", version: nil, resources: ["horizontalpodautoscalers"]
        )),
        builtin("min-available", "Min Available", .string, .leading, 110, .exact(
            group: "policy", resources: ["poddisruptionbudgets"]
        )),
        builtin("max-unavailable", "Max Unavailable", .string, .leading, 120, .exact(
            group: "policy", resources: ["poddisruptionbudgets"]
        )),
        builtin("disruptions-allowed", "Allowed", .integer, .trailing, 75, .exact(
            group: "policy", resources: ["poddisruptionbudgets"]
        )),
        builtin("current-healthy", "Current Healthy", .integer, .trailing, 105, .exact(
            group: "policy", resources: ["poddisruptionbudgets"]
        )),
        builtin("desired-healthy", "Desired Healthy", .integer, .trailing, 105, .exact(
            group: "policy", resources: ["poddisruptionbudgets"]
        )),
        builtin("expected-pods", "Expected", .integer, .trailing, 80, .exact(
            group: "policy", resources: ["poddisruptionbudgets"]
        )),

        // Networking and discovery.
        builtin("service-type", "Type", .string, .leading, 110, .core("services")),
        builtin("cluster-ip", "Cluster IP", .string, .leading, 150, .core("services")),
        builtin("external-address", "External IP", .string, .leading, 180, .core("services")),
        builtin("ports", "Ports", .string, .leading, 220, .combining(
            .core("services", "endpoints"),
            .exact(group: "discovery.k8s.io", resources: ["endpointslices"]),
            .exact(group: "networking.k8s.io", resources: ["ingresses"])
        )),
        builtin("service-selector", "Selector", .string, .leading, 220, .core("services")),
        builtin("ip-families", "IP Families", .string, .leading, 120, .core("services")),
        builtin("session-affinity", "Session Affinity", .string, .leading, 130, .core("services")),
        builtin("external-traffic-policy", "External Traffic Policy", .string, .leading, 170, .core("services")),
        builtin("internal-traffic-policy", "Internal Traffic Policy", .string, .leading, 170, .core("services")),
        builtin("endpoint-count", "Endpoints", .integer, .trailing, 85, .combining(
            .core("endpoints"),
            .exact(group: "discovery.k8s.io", resources: ["endpointslices"])
        )),
        builtin("addresses", "Addresses", .string, .leading, 280, .combining(
            .core("endpoints"),
            .exact(group: "discovery.k8s.io", resources: ["endpointslices"])
        )),
        builtin("ingress-class", "Class", .string, .leading, 120, .exact(
            group: "networking.k8s.io", resources: ["ingresses"]
        )),
        builtin("hosts", "Hosts", .string, .leading, 240, .exact(
            group: "networking.k8s.io", resources: ["ingresses"]
        )),
        builtin("address", "Address", .string, .leading, 180, .exact(
            group: "networking.k8s.io", resources: ["ingresses"]
        )),
        builtin("tls", "TLS", .string, .leading, 180, .exact(
            group: "networking.k8s.io", resources: ["ingresses"]
        )),
        builtin("pod-selector", "Pod Selector", .string, .leading, 220, .exact(
            group: "networking.k8s.io", resources: ["networkpolicies"]
        )),
        builtin("policy-types", "Policy Types", .string, .leading, 140, .exact(
            group: "networking.k8s.io", resources: ["networkpolicies"]
        )),
        builtin("ingress-rules", "Ingress Rules", .integer, .trailing, 100, .exact(
            group: "networking.k8s.io", resources: ["networkpolicies"]
        )),
        builtin("egress-rules", "Egress Rules", .integer, .trailing, 95, .exact(
            group: "networking.k8s.io", resources: ["networkpolicies"]
        )),

        // Storage.
        builtin("capacity", "Capacity", .quantity, .trailing, 110, .core(
            "persistentvolumes", "persistentvolumeclaims"
        )),
        builtin("access-modes", "Access Modes", .string, .leading, 130, .core(
            "persistentvolumes", "persistentvolumeclaims"
        )),
        builtin("reclaim-policy", "Reclaim Policy", .string, .leading, 120, .combining(
            .core("persistentvolumes"),
            .exact(group: "storage.k8s.io", resources: ["storageclasses"])
        )),
        builtin("claim", "Claim", .string, .leading, 180, .core("persistentvolumes")),
        builtin("storage-class", "Storage Class", .string, .leading, 160, .core(
            "persistentvolumes", "persistentvolumeclaims"
        )),
        builtin("volume", "Volume", .string, .leading, 180, .core("persistentvolumeclaims")),
        builtin("reason", "Reason", .string, .leading, 220, .combining(
            .core("persistentvolumes", "persistentvolumeclaims", "events")
        )),
        builtin("volume-mode", "Volume Mode", .string, .leading, 115, .core(
            "persistentvolumes", "persistentvolumeclaims"
        )),
        builtin("provisioner", "Provisioner", .string, .leading, 220, .exact(
            group: "storage.k8s.io", resources: ["storageclasses"]
        )),
        builtin("binding-mode", "Binding Mode", .string, .leading, 170, .exact(
            group: "storage.k8s.io", resources: ["storageclasses"]
        )),
        builtin("allow-expansion", "Allow Expansion", .boolean, .center, 115, .exact(
            group: "storage.k8s.io", resources: ["storageclasses"]
        )),
        builtin("parameters", "Parameters", .string, .leading, 280, .exact(
            group: "storage.k8s.io", resources: ["storageclasses"]
        )),

        // RBAC, CRDs, Events, and small core resources.
        builtin("rule-count", "Rules", .integer, .trailing, 70, .exact(
            group: "rbac.authorization.k8s.io", resources: ["roles", "clusterroles"]
        )),
        builtin("rules-summary", "Rule Summary", .string, .leading, 300, .exact(
            group: "rbac.authorization.k8s.io", resources: ["roles", "clusterroles"]
        )),
        builtin("role-ref", "Role", .string, .leading, 190, .exact(
            group: "rbac.authorization.k8s.io", resources: ["rolebindings", "clusterrolebindings"]
        )),
        builtin("subject-kinds", "Subject Kinds", .string, .leading, 140, .exact(
            group: "rbac.authorization.k8s.io", resources: ["rolebindings", "clusterrolebindings"]
        )),
        builtin("subjects", "Subjects", .string, .leading, 280, .exact(
            group: "rbac.authorization.k8s.io", resources: ["rolebindings", "clusterrolebindings"]
        )),
        builtin("crd-group", "Group", .string, .leading, 180, .exact(
            group: "apiextensions.k8s.io", resources: ["customresourcedefinitions"]
        )),
        builtin("crd-kind", "Kind", .string, .leading, 150, .exact(
            group: "apiextensions.k8s.io", resources: ["customresourcedefinitions"]
        )),
        builtin("served-versions", "Served Versions", .string, .leading, 180, .exact(
            group: "apiextensions.k8s.io", resources: ["customresourcedefinitions"]
        )),
        builtin("scope", "Scope", .string, .leading, 100, .exact(
            group: "apiextensions.k8s.io", resources: ["customresourcedefinitions"]
        )),
        builtin("short-names", "Short Names", .string, .leading, 150, .exact(
            group: "apiextensions.k8s.io", resources: ["customresourcedefinitions"]
        )),
        builtin("categories", "Categories", .string, .leading, 150, .exact(
            group: "apiextensions.k8s.io", resources: ["customresourcedefinitions"]
        )),
        builtin("last-seen", "Last Seen", .timestamp, .trailing, 110, .core("events")),
        builtin("event-type", "Type", .string, .leading, 85, .core("events")),
        builtin("involved-object", "Object", .string, .leading, 220, .core("events")),
        builtin("message", "Message", .string, .leading, 420, .core("events")),
        builtin("event-source", "Source", .string, .leading, 180, .core("events")),
        builtin("subobject", "Subobject", .string, .leading, 180, .core("events")),
        builtin("first-seen", "First Seen", .timestamp, .trailing, 110, .core("events")),
        builtin("event-count", "Count", .integer, .trailing, 65, .core("events")),
        builtin("event-name", "Event Name", .string, .leading, 260, .core("events")),
        builtin("key-count", "Keys", .integer, .trailing, 65, .core("configmaps")),
        builtin("secret-type", "Type", .string, .leading, 180, .core("secrets")),
        builtin("data-key-count", "Data Keys", .integer, .trailing, 80, .core("secrets")),
        builtin("secret-refs", "Secret Refs", .integer, .trailing, 90, .core("serviceaccounts")),
        builtin("image-pull-secret-refs", "Image Pull Secrets", .integer, .trailing, 130, .core("serviceaccounts")),
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

    public static func hasCuratedDefinitions(
        group: String,
        version: String,
        resource: String
    ) -> Bool {
        curatedLayouts[resourceKey(group: group, version: version, resource: resource)] != nil
            || curatedLayouts[resourceKey(group: group, version: "*", resource: resource)] != nil
    }

    /// Curated definitions include both the compact visible layout and useful
    /// disabled columns. Disabled definitions do no backend work until enabled.
    public static func defaultDefinitions(
        group: String,
        version: String,
        resource: String,
        namespaced: Bool,
        showNamespace: Bool = true
    ) -> [ColumnDefinition] {
        let key = resourceKey(group: group, version: version, resource: resource)
        let layout = curatedLayouts[key]
            ?? curatedLayouts[resourceKey(group: group, version: "*", resource: resource)]
        var columns: [(String, Bool)] = []
        if namespaced {
            columns.append(("namespace", showNamespace))
        }
        columns.append(("name", true))
        columns += layout ?? [("age", true), ("labels", false), ("created", false),
            ("resourceVersion", false), ("kind", false)]
        return columns.compactMap { value, enabled in
            descriptor(value: value)?.definition(enabled: enabled)
        }
    }

    private static func resourceKey(group: String, version: String, resource: String) -> String {
        "\(group)/\(version)/\(resource)"
    }

    private static let metadataHidden: [(String, Bool)] = [
        ("labels", false), ("created", false), ("resourceVersion", false), ("kind", false),
    ]

    private static func layout(
        _ visible: [String],
        hidden: [String] = []
    ) -> [(String, Bool)] {
        visible.map { ($0, true) } + hidden.map { ($0, false) } + metadataHidden
    }

    private static let curatedLayouts: [String: [(String, Bool)]] = [
        "/v1/pods": layout(
            ["ready", "status", "restarts", "pod-ip", "node", "cpu", "memory", "age"],
            hidden: ["last-restart", "service-account", "qos-class", "readiness-gates", "nominated-node", "ephemeral-storage"]
        ),
        "/v1/nodes": layout(
            ["status", "roles", "taints", "internal-ip", "kubelet-version", "cpu", "memory", "age"],
            hidden: ["external-ip", "architecture", "os-image", "kernel-version", "ephemeral-storage"]
        ),
        "apps/v1/deployments": layout(
            ["ready", "up-to-date", "available", "age"],
            hidden: ["desired", "selector", "containers", "images"]
        ),
        "apps/v1/statefulsets": layout(
            ["ready", "service", "age"],
            hidden: ["desired", "current", "updated", "selector", "containers", "images"]
        ),
        "apps/v1/daemonsets": layout(
            ["desired", "current", "ready-count", "up-to-date", "available", "age"],
            hidden: ["selector", "containers", "images"]
        ),
        "apps/v1/replicasets": layout(
            ["desired", "current", "ready-count", "age"],
            hidden: ["selector", "containers", "images"]
        ),
        "/v1/replicationcontrollers": layout(
            ["desired", "current", "ready-count", "age"],
            hidden: ["selector", "containers", "images"]
        ),
        "batch/v1/jobs": layout(
            ["status", "completions", "duration", "age"],
            hidden: ["active", "succeeded", "failed", "containers", "images"]
        ),
        "batch/v1/cronjobs": layout(
            ["schedule", "suspended", "active", "last-schedule", "age"],
            hidden: ["time-zone", "last-successful", "containers", "images"]
        ),
        "autoscaling/*/horizontalpodautoscalers": layout(
            ["reference", "targets", "minimum", "maximum", "current-replicas", "age"],
            hidden: ["conditions"]
        ),
        "policy/v1/poddisruptionbudgets": layout(
            ["min-available", "max-unavailable", "disruptions-allowed", "current-healthy", "desired-healthy", "age"],
            hidden: ["expected-pods"]
        ),
        "/v1/services": layout(
            ["service-type", "cluster-ip", "external-address", "ports", "age"],
            hidden: ["service-selector", "ip-families", "session-affinity", "external-traffic-policy", "internal-traffic-policy"]
        ),
        "/v1/endpoints": layout(
            ["endpoint-count", "ports", "age"], hidden: ["addresses"]
        ),
        "discovery.k8s.io/v1/endpointslices": layout(
            ["endpoint-count", "ready-count", "ports", "age"], hidden: ["addresses"]
        ),
        "networking.k8s.io/v1/ingresses": layout(
            ["ingress-class", "hosts", "address", "ports", "age"], hidden: ["tls"]
        ),
        "networking.k8s.io/v1/networkpolicies": layout(
            ["pod-selector", "policy-types", "age"], hidden: ["ingress-rules", "egress-rules"]
        ),
        "/v1/persistentvolumes": layout(
            ["capacity", "access-modes", "reclaim-policy", "status", "claim", "storage-class", "age"],
            hidden: ["reason", "volume-mode"]
        ),
        "/v1/persistentvolumeclaims": layout(
            ["status", "volume", "capacity", "access-modes", "storage-class", "age"],
            hidden: ["reason", "volume-mode"]
        ),
        "storage.k8s.io/v1/storageclasses": layout(
            ["provisioner", "reclaim-policy", "binding-mode", "allow-expansion", "age"],
            hidden: ["parameters"]
        ),
        "rbac.authorization.k8s.io/v1/roles": layout(["rule-count", "age"], hidden: ["rules-summary"]),
        "rbac.authorization.k8s.io/v1/clusterroles": layout(["rule-count", "age"], hidden: ["rules-summary"]),
        "rbac.authorization.k8s.io/v1/rolebindings": layout(["role-ref", "subject-kinds", "subjects", "age"]),
        "rbac.authorization.k8s.io/v1/clusterrolebindings": layout(["role-ref", "subject-kinds", "subjects", "age"]),
        "apiextensions.k8s.io/v1/customresourcedefinitions": layout(
            ["crd-group", "crd-kind", "served-versions", "scope", "age"],
            hidden: ["short-names", "categories"]
        ),
        "/v1/events": layout(
            ["last-seen", "event-type", "reason", "involved-object", "message"],
            hidden: ["event-source", "subobject", "first-seen", "event-count", "event-name"]
        ),
        "/v1/configmaps": layout(["key-count", "age"]),
        "/v1/secrets": layout(["secret-type", "data-key-count", "age"]),
        "/v1/serviceaccounts": layout(["age"], hidden: ["secret-refs", "image-pull-secret-refs"]),
        "/v1/namespaces": layout(["status", "age"]),
    ]

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
