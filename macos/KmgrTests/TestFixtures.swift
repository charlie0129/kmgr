import KmgrTestSupport
@testable import KmgrCore

typealias TestUserDefaults = InMemoryUserDefaults

// Test fixtures use deterministic opaque references while production APIs
// require callers to carry the exact kubeconfig context identity explicitly.
extension ClusterContextSummary {
    init(
        name: String,
        clusterName: String,
        serverHostname: String,
        defaultNamespace: String,
        sourcePaths: [String] = [],
        isCurrent: Bool = false,
        authentication: ClusterAuthenticationAvailability = .supported(hint: "")
    ) {
        self.init(
            id: "test-context:\(name)",
            name: name,
            clusterName: clusterName,
            serverHostname: serverHostname,
            defaultNamespace: defaultNamespace,
            sourcePaths: sourcePaths,
            isCurrent: isCurrent,
            authentication: authentication
        )
    }
}

extension OpenedClusterSession {
    init(
        sessionID: String,
        contextName: String,
        clusterName: String,
        serverHostname: String,
        defaultNamespace: String
    ) {
        self.init(
            sessionID: sessionID,
            contextName: contextName,
            clusterName: clusterName,
            serverHostname: serverHostname,
            defaultNamespace: defaultNamespace,
            contextReference: "test-context:\(contextName)"
        )
    }
}

extension ClusterWindowRestorationState {
    init(
        contextName: String,
        gvr: GVR? = nil,
        namespaceScope: NamespaceScope = .all,
        filter: String = "",
        sort: [SortDescriptorState] = [],
        isSidebarVisible: Bool = true,
        scrollAnchor: ScrollAnchor? = nil
    ) {
        self.init(
            contextName: contextName,
            contextReference: "test-context:\(contextName)",
            gvr: gvr,
            namespaceScope: namespaceScope,
            filter: filter,
            sort: sort,
            isSidebarVisible: isSidebarVisible,
            scrollAnchor: scrollAnchor
        )
    }
}

extension ClusterWindowRestorationRecord {
    init(id: String = "test-window", contextName: String) {
        self.init(
            id: id,
            contextName: contextName,
            contextReference: "test-context:\(contextName)"
        )
    }
}

func identity(
    _ uid: ResourceUID,
    name: String? = nil,
    namespace: String = "default",
    resource: String = "pods"
) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session-1",
        group: "",
        version: "v1",
        resource: resource,
        namespace: namespace,
        name: name ?? uid.rawValue,
        uid: uid
    )
}

func row(
    _ uid: ResourceUID,
    name: String? = nil,
    namespace: String = "default",
    status: String = "Running"
) -> ResourceRow {
    ResourceRow(
        identity: identity(uid, name: name, namespace: namespace),
        cells: [
            Cell(
                columnID: "name",
                displayText: name ?? uid.rawValue,
                typedValue: .string(name ?? uid.rawValue)
            ),
            Cell(
                columnID: "status",
                displayText: status,
                typedValue: .string(status)
            ),
        ]
    )
}
