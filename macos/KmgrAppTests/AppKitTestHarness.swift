import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@Suite("AppKit tests", .serialized)
struct AppKitTestHarness {}

@MainActor
func expectPreciseScrollingLayout(
    _ textView: NSTextView,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    // Check TextKit 2 first: reading layoutManager below would itself switch
    // an incorrectly configured view to TextKit 1 and could mask a regression.
    #expect(textView.textLayoutManager == nil, sourceLocation: sourceLocation)
    #expect(
        textView.layoutManager?.allowsNonContiguousLayout == true,
        sourceLocation: sourceLocation
    )
}

@MainActor
func expectWhitespaceVisualization(
    _ textView: NSTextView,
    enabled: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let layoutManager = textView.layoutManager as? WhitespaceLayoutManager
    #expect(layoutManager != nil, sourceLocation: sourceLocation)
    #expect(
        layoutManager?.whitespaceVisualizationEnabled == enabled,
        sourceLocation: sourceLocation
    )
    #expect(
        layoutManager?.showsInvisibleCharacters == false,
        sourceLocation: sourceLocation
    )
    #expect(
        layoutManager?.showsControlCharacters == false,
        sourceLocation: sourceLocation
    )
}

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

struct AnyClusterContextProvider: ClusterContextProviding {
    private let listOperation: @Sendable (Bool, [String]) async throws
        -> ClusterContextCatalog
    private let openOperation: @Sendable (String, [String]) async throws
        -> OpenedClusterSession

    init(
        listContexts: @escaping @Sendable (Bool) async throws -> [ClusterContextSummary],
        openContext: @escaping @Sendable (String) async throws -> OpenedClusterSession
    ) {
        listOperation = { reload, _ in
            ClusterContextCatalog(contexts: try await listContexts(reload))
        }
        openOperation = { reference, _ in try await openContext(reference) }
    }

    init(
        listCatalog: @escaping @Sendable (Bool, [String]) async throws
            -> ClusterContextCatalog,
        openContext: @escaping @Sendable (String, [String]) async throws
            -> OpenedClusterSession
    ) {
        listOperation = listCatalog
        openOperation = openContext
    }

    func listContexts(
        reload: Bool,
        addedKubeconfigPaths: [String]
    ) async throws -> ClusterContextCatalog {
        try await listOperation(reload, addedKubeconfigPaths)
    }

    func openContext(
        reference: String,
        addedKubeconfigPaths: [String]
    ) async throws -> OpenedClusterSession {
        try await openOperation(reference, addedKubeconfigPaths)
    }
}
