import Foundation

/// A display-safe, structured error produced while discovering or opening a
/// kubeconfig context. Providers must not put credentials or kubeconfig
/// contents in these fields.
public struct ClusterManagerIssue: Error, Hashable, Sendable {
    /// Stable reasons used when a revision-pinned resource-view request loses
    /// the race with a newer backend view. These are deliberately distinct
    /// from the broad validation category: malformed requests and expired
    /// tokens must remain visible to the caller.
    public static let staleResourceViewRevisionReason = "StaleResourceViewRevision"
    public static let staleResourceViewGenerationReason = "StaleResourceViewGeneration"

    public struct KubernetesStatus: Hashable, Sendable {
        public struct Cause: Hashable, Sendable {
            public var reason: String
            public var message: String
            public var field: String

            public init(reason: String = "", message: String = "", field: String = "") {
                self.reason = reason
                self.message = message
                self.field = field
            }
        }

        public var name: String
        public var group: String
        public var kind: String
        public var uid: String
        public var reason: String
        public var message: String
        public var retryAfterSeconds: Int32
        public var causes: [Cause]

        public init(
            name: String = "", group: String = "", kind: String = "", uid: String = "",
            reason: String = "", message: String = "", retryAfterSeconds: Int32 = 0,
            causes: [Cause] = []
        ) {
            self.name = name
            self.group = group
            self.kind = kind
            self.uid = uid
            self.reason = reason
            self.message = message
            self.retryAfterSeconds = retryAfterSeconds
            self.causes = causes
        }
    }

    public enum Category: String, Hashable, Sendable, CaseIterable {
        case authentication
        case authorization
        case notFound
        case conflict
        case validation
        case unavailable
        case timeout
        case cancelled
        case tls
        case unsupported
        case internalFailure
        case resourceExhausted
    }

    public var category: Category
    public var reason: String
    public var message: String
    public var httpStatusCode: Int?
    public var retryable: Bool
    public var retryAfterMilliseconds: Int64?
    public var fieldPath: String
    public var contextName: String
    public var operation: String
    public var safeDetails: [String: String]
    public var kubernetesStatus: KubernetesStatus?

    /// True only for the expected revision/generation race of a pinned
    /// resource-view request. Callers may safely discard this one request and
    /// wait for the newer view invalidation; other validation failures are
    /// actionable and must not be folded into this case.
    public var isStaleResourceViewRequest: Bool {
        guard category == .validation else { return false }
        if reason == Self.staleResourceViewRevisionReason
            || reason == Self.staleResourceViewGenerationReason
        {
            return true
        }
        let normalizedMessage = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedMessage.hasPrefix("resource view revision is stale")
            || normalizedMessage.hasPrefix("resource view generation is stale")
    }

    public init(
        category: Category,
        reason: String = "",
        message: String,
        httpStatusCode: Int? = nil,
        retryable: Bool = false,
        retryAfterMilliseconds: Int64? = nil,
        fieldPath: String = "",
        contextName: String = "",
        operation: String = "",
        safeDetails: [String: String] = [:],
        kubernetesStatus: KubernetesStatus? = nil
    ) {
        self.category = category
        self.reason = reason
        self.message = message
        self.httpStatusCode = httpStatusCode
        self.retryable = retryable
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.fieldPath = fieldPath
        self.contextName = contextName
        self.operation = operation
        self.safeDetails = safeDetails
        self.kubernetesStatus = kubernetesStatus
    }

    public var presentationTitle: String {
        switch category {
        case .authentication: "Authentication failed"
        case .authorization: "Access denied"
        case .notFound: "Context not found"
        case .conflict: "Context changed"
        case .validation: "Invalid kubeconfig"
        case .unavailable: "Cluster unavailable"
        case .timeout: "Connection timed out"
        case .cancelled: "Connection cancelled"
        case .tls: "TLS connection failed"
        case .unsupported: "Unsupported authentication"
        case .internalFailure: "Kmgr engine error"
        case .resourceExhausted: "Resource limit reached"
        }
    }

    /// A compact diagnostic suffix suitable for an inline banner. The human
    /// message remains primary; these fields preserve useful structured server
    /// information without exposing payloads.
    public var presentationMetadata: String {
        var parts: [String] = []
        if !reason.isEmpty { parts.append(reason) }
        if let httpStatusCode, httpStatusCode > 0 {
            parts.append("HTTP \(httpStatusCode)")
        }
        if retryable { parts.append("Retryable") }
        return parts.joined(separator: " · ")
    }

    public static func unsupportedAuthentication(
        contextName: String,
        mechanism: String,
        message: String? = nil
    ) -> Self {
        let readableMechanism = mechanism.isEmpty ? "credential plugin" : mechanism
        return Self(
            category: .unsupported,
            reason: "UnsupportedAuthentication",
            message: message
                ?? "Context \(contextName) uses \(readableMechanism), which kmgr v1 does not execute.",
            contextName: contextName,
            operation: "open cluster session",
            safeDetails: ["mechanism": readableMechanism]
        )
    }
}

extension ClusterManagerIssue: LocalizedError {
    public var errorDescription: String? { message }
}

public enum ClusterAuthenticationAvailability: Hashable, Sendable {
    case supported(hint: String)
    case unsupported(mechanism: String, issue: ClusterManagerIssue)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var hint: String {
        switch self {
        case .supported(let hint): hint
        case .unsupported(let mechanism, _): mechanism
        }
    }

    public var issue: ClusterManagerIssue? {
        if case .unsupported(_, let issue) = self { return issue }
        return nil
    }
}

/// Compact kubeconfig provenance returned by the Go engine. Merely listing
/// these values must not contact the Kubernetes API server.
public struct ClusterContextSummary: Identifiable, Hashable, Sendable {
    /// Opaque, deterministic reference binding this row to its exact source
    /// kubeconfig. It can differ between rows with the same display name.
    public var id: String

    public var name: String
    public var clusterName: String
    public var serverHostname: String
    public var defaultNamespace: String
    public var sourcePaths: [String]
    public var isCurrent: Bool
    public var authentication: ClusterAuthenticationAvailability

    public init(
        id: String,
        name: String,
        clusterName: String,
        serverHostname: String,
        defaultNamespace: String,
        sourcePaths: [String],
        isCurrent: Bool = false,
        authentication: ClusterAuthenticationAvailability = .supported(hint: "")
    ) {
        self.id = id
        self.name = name
        self.clusterName = clusterName
        self.serverHostname = serverHostname
        self.defaultNamespace = defaultNamespace
        self.sourcePaths = sourcePaths
        self.isCurrent = isCurrent
        self.authentication = authentication
    }

    public var displayedNamespace: String {
        defaultNamespace.isEmpty ? "default" : defaultNamespace
    }

    public var displayedSourcePath: String {
        guard let first = sourcePaths.first else { return "—" }
        if sourcePaths.count == 1 { return first }
        return "\(first) (+\(sourcePaths.count - 1))"
    }

    fileprivate var searchableText: String {
        ([name, clusterName, serverHostname, displayedNamespace]
            + sourcePaths + [authentication.hint])
            .joined(separator: "\n")
    }
}

public struct OpenedClusterSession: Hashable, Sendable {
    public var sessionID: String
    public var contextName: String
    public var clusterName: String
    public var serverHostname: String
    public var defaultNamespace: String
    public var contextReference: String

    public init(
        sessionID: String,
        contextName: String,
        clusterName: String,
        serverHostname: String,
        defaultNamespace: String,
        contextReference: String
    ) {
        self.sessionID = sessionID
        self.contextName = contextName
        self.clusterName = clusterName
        self.serverHostname = serverHostname
        self.defaultNamespace = defaultNamespace
        self.contextReference = contextReference
    }
}

/// Status for one path explicitly added by the user. Failures are scoped to
/// the file so healthy kubeconfig sources remain usable.
public struct AddedKubeconfigSourceStatus: Hashable, Sendable {
    public var path: String
    public var contextCount: Int
    public var issue: ClusterManagerIssue?

    public init(
        path: String,
        contextCount: Int = 0,
        issue: ClusterManagerIssue? = nil
    ) {
        self.path = path
        self.contextCount = max(0, contextCount)
        self.issue = issue
    }

    public var isUsable: Bool {
        issue == nil && contextCount > 0
    }
}

/// One offline discovery snapshot consumed atomically by Cluster Manager.
public struct ClusterContextCatalog: Hashable, Sendable {
    public var contexts: [ClusterContextSummary]
    public var addedKubeconfigSources: [AddedKubeconfigSourceStatus]

    public init(
        contexts: [ClusterContextSummary] = [],
        addedKubeconfigSources: [AddedKubeconfigSourceStatus] = []
    ) {
        self.contexts = contexts
        self.addedKubeconfigSources = addedKubeconfigSources
    }
}

/// Integration seam between the AppKit chooser and the supervised engine.
/// The concrete implementation maps the generated ClusterService messages to
/// these display-safe values.
public protocol ClusterContextProviding: Sendable {
    func listContexts(
        reload: Bool,
        addedKubeconfigPaths: [String]
    ) async throws -> ClusterContextCatalog
    func openContext(
        reference: String,
        addedKubeconfigPaths: [String]
    ) async throws -> OpenedClusterSession
}

public enum ClusterContextListPhase: Hashable, Sendable {
    case idle
    case loading(reload: Bool)
    case loaded
    case failed(ClusterManagerIssue)
}

/// Pure chooser state. Async responses carry a monotonically increasing load
/// revision so a cancelled or slow reload cannot replace newer kubeconfig
/// discovery results.
public struct ClusterManagerModel: Hashable, Sendable {
    public private(set) var allContexts: [ClusterContextSummary]
    /// The stable projection consumed by AppKit table callbacks. Search work
    /// happens only when the query or discovery snapshot changes; merely
    /// asking for a row must remain constant-time.
    public private(set) var displayedContexts: [ClusterContextSummary]
    public private(set) var searchQuery: String
    public private(set) var selectedContextID: String?
    public var selectedContextName: String? { selectedContext?.name }
    public private(set) var phase: ClusterContextListPhase
    public private(set) var loadRevision: UInt64
    private var foldedSearchableText: [String]?

    public init(
        contexts: [ClusterContextSummary] = [],
        searchQuery: String = "",
        selectedContextName: String? = nil,
        phase: ClusterContextListPhase = .idle
    ) {
        let normalizedContexts = Self.normalized(contexts)
        self.allContexts = normalizedContexts
        self.displayedContexts = normalizedContexts
        self.searchQuery = searchQuery
        self.selectedContextID = selectedContextName.flatMap { name in
            normalizedContexts.first(where: { $0.name == name })?.id
        }
        self.phase = phase
        self.loadRevision = 0
        self.foldedSearchableText = nil
        refreshDisplayedContexts()
        reconcileSelection()
    }

    public var selectedContext: ClusterContextSummary? {
        guard let selectedContextID else { return nil }
        return allContexts.first { $0.id == selectedContextID }
    }

    public var selectedContextIssue: ClusterManagerIssue? {
        selectedContext?.authentication.issue
    }

    public var canOpenSelectedContext: Bool {
        guard case .loading = phase else {
            return selectedContext?.authentication.isSupported == true
        }
        return false
    }

    public var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    @discardableResult
    public mutating func beginLoading(reload: Bool) -> UInt64 {
        loadRevision &+= 1
        phase = .loading(reload: reload)
        if !reload {
            allContexts.removeAll(keepingCapacity: true)
            displayedContexts.removeAll(keepingCapacity: true)
            foldedSearchableText = nil
            selectedContextID = nil
        }
        return loadRevision
    }

    @discardableResult
    public mutating func finishLoading(
        _ contexts: [ClusterContextSummary],
        revision: UInt64
    ) -> Bool {
        guard revision == loadRevision else { return false }
        allContexts = Self.normalized(contexts)
        foldedSearchableText = nil
        refreshDisplayedContexts()
        phase = .loaded
        reconcileSelection()
        return true
    }

    @discardableResult
    public mutating func failLoading(
        with issue: ClusterManagerIssue,
        revision: UInt64
    ) -> Bool {
        guard revision == loadRevision else { return false }
        phase = .failed(issue)
        reconcileSelection()
        return true
    }

    public mutating func setSearchQuery(_ query: String) {
        guard query != searchQuery else { return }
        searchQuery = query
        refreshDisplayedContexts()
        reconcileSelection()
    }

    public mutating func selectContext(named name: String?) {
        guard let name,
            displayedContexts.contains(where: { $0.name == name })
        else {
            selectedContextID = nil
            return
        }
        selectedContextID = displayedContexts.first(where: { $0.name == name })?.id
    }

    public mutating func selectContext(id: String?) {
        guard let id, displayedContexts.contains(where: { $0.id == id }) else {
            selectedContextID = nil
            return
        }
        selectedContextID = id
    }

    private mutating func reconcileSelection() {
        if let selectedContextID,
            displayedContexts.contains(where: { $0.id == selectedContextID })
        {
            return
        }
        selectedContextID = displayedContexts.first(where: \.isCurrent)?.id
            ?? displayedContexts.first?.id
    }

    private mutating func refreshDisplayedContexts() {
        let terms = searchQuery
            .split(whereSeparator: \Character.isWhitespace)
            .map { Self.fold(String($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            displayedContexts = allContexts
            return
        }

        if foldedSearchableText?.count != allContexts.count {
            foldedSearchableText = allContexts.map { Self.fold($0.searchableText) }
        }
        guard let foldedSearchableText else {
            displayedContexts = []
            return
        }

        var matches: [ClusterContextSummary] = []
        matches.reserveCapacity(allContexts.count)
        for index in allContexts.indices
        where terms.allSatisfy({ foldedSearchableText[index].contains($0) }) {
            matches.append(allContexts[index])
        }
        displayedContexts = matches
    }

    private static func normalized(
        _ contexts: [ClusterContextSummary]
    ) -> [ClusterContextSummary] {
        var seen: Set<String> = []
        return contexts
            .filter { !$0.name.isEmpty && !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.sourcePaths.lexicographicallyPrecedes(rhs.sourcePaths)
            }
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}
