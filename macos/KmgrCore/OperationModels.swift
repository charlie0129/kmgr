import Foundation

public enum DeletePropagationPolicy: String, Hashable, Sendable, CaseIterable {
    case background
    case foreground
    case orphan
}

public struct ResourceDeleteTarget: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var hiddenByFilter: Bool

    public init(identity: ResourceIdentity, hiddenByFilter: Bool = false) {
        self.identity = identity
        self.hiddenByFilter = hiddenByFilter
    }
}

public enum HighImpactDeleteKind: String, Hashable, Sendable, CaseIterable {
    case namespace
    case node
    case customResourceDefinition
    case persistentVolumeClaim
    case clusterRole
    case clusterRoleBinding

    public var displayName: String {
        switch self {
        case .namespace: "Namespace"
        case .node: "Node"
        case .customResourceDefinition: "CustomResourceDefinition"
        case .persistentVolumeClaim: "PersistentVolumeClaim"
        case .clusterRole: "ClusterRole"
        case .clusterRoleBinding: "ClusterRoleBinding"
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .namespace: 0
        case .node: 1
        case .customResourceDefinition: 2
        case .persistentVolumeClaim: 3
        case .clusterRole: 4
        case .clusterRoleBinding: 5
        }
    }
}

public struct HighImpactDeleteSelection: Hashable, Sendable {
    public var kind: HighImpactDeleteKind
    public var count: Int

    public init(kind: HighImpactDeleteKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// Presentation facts derived from the immutable targets captured before a
/// delete confirmation opens. Classification uses exact Kubernetes GVRs so a
/// custom resource with a lookalike plural cannot trigger or evade a warning.
public struct ResourceDeleteConfirmationSummary: Hashable, Sendable {
    public var targetCount: Int
    public var hiddenTargetCount: Int
    public var highImpactSelections: [HighImpactDeleteSelection]

    public init(targets: [ResourceDeleteTarget]) {
        targetCount = targets.count
        hiddenTargetCount = targets.lazy.filter(\.hiddenByFilter).count
        var counts: [HighImpactDeleteKind: Int] = [:]
        for target in targets {
            guard let kind = Self.highImpactKind(for: target.identity) else { continue }
            counts[kind, default: 0] += 1
        }
        highImpactSelections = counts.map {
            HighImpactDeleteSelection(kind: $0.key, count: $0.value)
        }.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    public var selectionText: String {
        let noun = targetCount == 1 ? "resource" : "resources"
        guard hiddenTargetCount > 0 else {
            return "\(targetCount) exact UID-pinned \(noun) selected"
        }
        return "\(targetCount) exact UID-pinned \(noun) selected · \(hiddenTargetCount) hidden by the current filter"
    }

    public var highImpactWarningText: String? {
        guard !highImpactSelections.isEmpty else { return nil }
        let selections = highImpactSelections.map { selection in
            "\(selection.kind.displayName) (\(selection.count))"
        }.joined(separator: ", ")
        return "High-impact selection: \(selections). Deleting these resources can disrupt the cluster, remove stored data, or change cluster-wide access."
    }

    public static func displayedGVR(for identity: ResourceIdentity) -> String {
        let group = identity.group.isEmpty ? "core" : identity.group
        return "\(group)/\(identity.version)/\(identity.resource)"
    }

    public static func highImpactKind(
        for identity: ResourceIdentity
    ) -> HighImpactDeleteKind? {
        switch (identity.group, identity.resource) {
        case ("", "namespaces"):
            .namespace
        case ("", "nodes"):
            .node
        case ("apiextensions.k8s.io", "customresourcedefinitions"):
            .customResourceDefinition
        case ("", "persistentvolumeclaims"):
            .persistentVolumeClaim
        case ("rbac.authorization.k8s.io", "clusterroles"):
            .clusterRole
        case ("rbac.authorization.k8s.io", "clusterrolebindings"):
            .clusterRoleBinding
        default:
            nil
        }
    }
}

public struct ResourceDeleteOptions: Hashable, Sendable {
    public static let defaultMaxConcurrency: UInt32 = 4
    public static let maximumMaxConcurrency: UInt32 = 16

    public var propagationPolicy: DeletePropagationPolicy
    public var gracePeriodSeconds: Int64?
    public var maxConcurrency: UInt32

    public init(
        propagationPolicy: DeletePropagationPolicy = .background,
        gracePeriodSeconds: Int64? = nil,
        maxConcurrency: UInt32 = ResourceDeleteOptions.defaultMaxConcurrency
    ) {
        self.propagationPolicy = propagationPolicy
        self.gracePeriodSeconds = gracePeriodSeconds
        self.maxConcurrency = maxConcurrency
    }
}

/// Immutable engine-owned selection used by bounded confirmation and direct
/// deletion. The client retains no complete identity array for this path.
public struct ResourceSelectionDeleteReference: Hashable, Sendable {
    public var sessionID: String
    public var viewID: String
    public var token: String
    public var selectedCount: UInt64
    public var gvr: GVR

    public init(
        sessionID: String,
        viewID: String,
        token: String,
        selectedCount: UInt64,
        gvr: GVR
    ) {
        self.sessionID = sessionID
        self.viewID = viewID
        self.token = token
        self.selectedCount = selectedCount
        self.gvr = gvr
    }
}

/// Exact, bounded facts for one destructive confirmation. `hiddenCount` was
/// computed by the engine against `currentRevision`; it is never inferred from
/// the bounded preview or the local viewport.
public struct ResourceSelectionDeletePreparation: Hashable, Sendable {
    public var selection: ResourceSelectionDeleteReference
    public var currentRevision: ResourceSelectionRevision
    public var hiddenCount: UInt64
    public var expiresAt: Date
    public var preview: [ResourceDeleteTarget]
    public var previewTruncated: Bool

    public init(
        selection: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision,
        hiddenCount: UInt64,
        expiresAt: Date,
        preview: [ResourceDeleteTarget],
        previewTruncated: Bool
    ) {
        self.selection = selection
        self.currentRevision = currentRevision
        self.hiddenCount = hiddenCount
        self.expiresAt = expiresAt
        self.preview = preview
        self.previewTruncated = previewTruncated
    }
}

public struct ResourceMetadataChanges: Hashable, Sendable {
    public var labels: [String: String]
    public var annotations: [String: String]
    public var removeLabelKeys: [String]
    public var removeAnnotationKeys: [String]

    public init(
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        removeLabelKeys: [String] = [],
        removeAnnotationKeys: [String] = []
    ) {
        self.labels = labels
        self.annotations = annotations
        self.removeLabelKeys = removeLabelKeys
        self.removeAnnotationKeys = removeAnnotationKeys
    }

    public var isEmpty: Bool {
        labels.isEmpty && annotations.isEmpty
            && removeLabelKeys.isEmpty && removeAnnotationKeys.isEmpty
    }
}

/// Mutation operations return a bounded progress stream after the helper has
/// accepted them. The operation ID is present on every progress value and can
/// be passed to `cancelOperation` for an explicit user cancellation.
public protocol ResourceOperationProviding: Sendable {
    func prepareDeleteSelection(
        selection: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision,
        previewLimit: Int
    ) async throws -> ResourceSelectionDeletePreparation

    func deleteSelection(
        selection: ResourceSelectionDeleteReference,
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>

    func deleteResources(
        targets: [ResourceDeleteTarget],
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>

    func scaleResource(
        identity: ResourceIdentity,
        replicas: Int32,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>

    func rolloutRestart(
        identity: ResourceIdentity,
        expectedResourceVersion: String
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>

    func updateMetadata(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>

    func cancelOperation(
        sessionID: String,
        operationID: String,
        cancelNotStartedOnly: Bool
    ) async throws
}

public extension ResourceOperationProviding {
    func prepareDeleteSelection(
        selection: ResourceSelectionDeleteReference,
        currentRevision: ResourceSelectionRevision,
        previewLimit: Int
    ) async throws -> ResourceSelectionDeletePreparation {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "SelectionDeleteUnavailable",
            message: "This operation provider does not support token-backed selection deletion.",
            operation: "prepare selection deletion"
        )
    }

    func deleteSelection(
        selection: ResourceSelectionDeleteReference,
        options: ResourceDeleteOptions
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "SelectionDeleteUnavailable",
            message: "This operation provider does not support token-backed selection deletion.",
            operation: "delete selection"
        )
    }
}
