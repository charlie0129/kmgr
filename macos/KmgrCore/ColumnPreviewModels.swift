import Foundation

/// Immutable Kubernetes context captured when the columns manager opens.
/// A selected object is included only when exactly one resource row was
/// selected, allowing the engine to perform a fresh UID-pinned GET.
public struct ColumnPreviewContext: Hashable, Sendable {
    public var sessionID: String
    public var resource: DiscoveredResource
    public var namespaceScope: NamespaceSelection
    public var selectedObject: ResourceIdentity?

    public init(
        sessionID: String,
        resource: DiscoveredResource,
        namespaceScope: NamespaceSelection,
        selectedObject: ResourceIdentity? = nil
    ) {
        self.sessionID = sessionID
        self.resource = resource
        self.namespaceScope = namespaceScope
        self.selectedObject = selectedObject
    }
}

public struct ColumnPreviewRequest: Hashable, Sendable {
    public var sessionID: String
    public var resource: DiscoveredResource
    public var namespaceScope: NamespaceSelection
    public var column: ColumnDefinition
    public var selectedObject: ResourceIdentity?

    public init(
        sessionID: String,
        resource: DiscoveredResource,
        namespaceScope: NamespaceSelection,
        column: ColumnDefinition,
        selectedObject: ResourceIdentity? = nil
    ) {
        self.sessionID = sessionID
        self.resource = resource
        self.namespaceScope = namespaceScope
        self.column = column
        self.selectedObject = selectedObject
    }

    public init(context: ColumnPreviewContext, column: ColumnDefinition) {
        self.init(
            sessionID: context.sessionID,
            resource: context.resource,
            namespaceScope: context.namespaceScope,
            column: column,
            selectedObject: context.selectedObject
        )
    }
}

public struct ColumnPreviewResult: Hashable, Sendable {
    public var requestID: String
    public var celEnvironment: String
    public var preview: Cell
    public var usedSampleObject: Bool
    public var evaluatedObject: ResourceIdentity?
    /// A preview can contain a useful raw value while still failing the
    /// declared result-type contract. The editor renders this issue beside
    /// the value and keeps Add/Apply disabled until a later draft succeeds.
    public var validationIssue: ClusterManagerIssue?

    public init(
        requestID: String,
        celEnvironment: String,
        preview: Cell,
        usedSampleObject: Bool,
        evaluatedObject: ResourceIdentity? = nil,
        validationIssue: ClusterManagerIssue? = nil
    ) {
        self.requestID = requestID
        self.celEnvironment = celEnvironment
        self.preview = preview
        self.usedSampleObject = usedSampleObject
        self.evaluatedObject = evaluatedObject
        self.validationIssue = validationIssue
    }
}

public protocol ColumnPreviewProviding: Sendable {
    func previewColumn(_ request: ColumnPreviewRequest) async throws -> ColumnPreviewResult
}

public enum ColumnPreviewValidationPhase: Hashable, Sendable {
    case idle
    case localFailure(String)
    case validating
    case succeeded(ColumnPreviewResult)
    case failed(String)
}

/// Pure revision gate for debounced, asynchronous preview validation.
/// Responses from older drafts cannot replace the state of the current draft.
public struct ColumnPreviewValidationState: Hashable, Sendable {
    public private(set) var revision: UInt64
    public private(set) var phase: ColumnPreviewValidationPhase

    public init(
        revision: UInt64 = 0,
        phase: ColumnPreviewValidationPhase = .idle
    ) {
        self.revision = revision
        self.phase = phase
    }

    /// Starts a new revision. A locally valid draft enters the authoritative
    /// validating phase; a local failure invalidates any prior success.
    @discardableResult
    public mutating func beginRevision(localFailure: String? = nil) -> UInt64 {
        revision &+= 1
        phase = localFailure.map(ColumnPreviewValidationPhase.localFailure) ?? .validating
        return revision
    }

    @discardableResult
    public mutating func accept(
        _ result: ColumnPreviewResult,
        for responseRevision: UInt64
    ) -> Bool {
        guard responseRevision == revision, case .validating = phase else { return false }
        phase = .succeeded(result)
        return true
    }

    @discardableResult
    public mutating func reject(
        _ message: String,
        for responseRevision: UInt64
    ) -> Bool {
        guard responseRevision == revision, case .validating = phase else { return false }
        phase = .failed(message)
        return true
    }

    public var canCommit: Bool {
        if case .succeeded(let result) = phase {
            return result.validationIssue == nil
        }
        return false
    }
}
