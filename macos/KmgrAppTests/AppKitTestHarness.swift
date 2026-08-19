import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@Suite("AppKit tests", .serialized)
struct AppKitTestHarness {}

// AppKit fixtures use deterministic opaque identities; production must always
// receive the exact reference published by kubeconfig discovery.
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
        labelSelector: String = "",
        fieldSelector: String = "",
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
            labelSelector: labelSelector,
            fieldSelector: fieldSelector,
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

struct AnyClusterContextProvider: ClusterContextProviding {
    private let listOperation: @Sendable (Bool) async throws -> [ClusterContextSummary]
    private let openOperation: @Sendable (String) async throws -> OpenedClusterSession

    init(
        listContexts: @escaping @Sendable (Bool) async throws -> [ClusterContextSummary],
        openContext: @escaping @Sendable (String) async throws -> OpenedClusterSession
    ) {
        listOperation = listContexts
        openOperation = openContext
    }

    func listContexts(reload: Bool) async throws -> [ClusterContextSummary] {
        try await listOperation(reload)
    }

    func openContext(reference: String) async throws -> OpenedClusterSession {
        try await openOperation(reference)
    }
}
