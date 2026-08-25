import Foundation

public enum ObjectSummaryTimestamp: Hashable, Sendable {
    case elapsedSince(Date)
    case occurredAt(Date)
}

public struct ObjectSummaryField: Hashable, Sendable {
    public var sectionID: String
    public var fieldID: String
    public var label: String
    public var displayText: String
    public var tooltip: String
    public var severity: CellSeverity
    public var timestamp: ObjectSummaryTimestamp?

    public init(
        sectionID: String,
        fieldID: String,
        label: String,
        displayText: String,
        tooltip: String = "",
        severity: CellSeverity = .normal,
        timestamp: ObjectSummaryTimestamp? = nil
    ) {
        self.sectionID = sectionID
        self.fieldID = fieldID
        self.label = label
        self.displayText = displayText
        self.tooltip = tooltip
        self.severity = severity
        self.timestamp = timestamp
    }
}

public struct PodContainerDetail: Hashable, Sendable {
    public var name: String
    public var kind: ExecContainerKind
    public var status: String
    public var statusTooltip: String
    public var statusSeverity: CellSeverity
    public var ready: Bool
    public var restartCount: Int32
    public var ports: [String]
    public var metrics: [ResourceUsageValue]

    public init(
        name: String,
        kind: ExecContainerKind,
        status: String = "Pending",
        statusTooltip: String = "",
        statusSeverity: CellSeverity = .normal,
        ready: Bool = false,
        restartCount: Int32 = 0,
        ports: [String] = [],
        metrics: [ResourceUsageValue] = []
    ) {
        self.name = name
        self.kind = kind
        self.status = status
        self.statusTooltip = statusTooltip
        self.statusSeverity = statusSeverity
        self.ready = ready
        self.restartCount = restartCount
        self.ports = ports
        self.metrics = metrics
    }

    public func metric(named resourceName: String) -> ResourceUsageValue? {
        metrics.first { $0.resourceName == resourceName }
    }
}

public struct ObjectDetail: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var resourceVersion: String
    public var yamlUTF8: Data
    public var summaryFields: [ObjectSummaryField]
    public var labels: [String: String]
    public var annotations: [String: String]
    public var containers: [PodContainerDetail]
    /// Canonical Kubernetes label selector for Pods related to this supported
    /// built-in workload or Service. Empty means no safe restrictive selector
    /// is available.
    public var podLabelSelector: String

    public init(
        identity: ResourceIdentity,
        resourceVersion: String,
        yamlUTF8: Data = Data(),
        summaryFields: [ObjectSummaryField] = [],
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        containers: [PodContainerDetail] = [],
        podLabelSelector: String = ""
    ) {
        self.identity = identity
        self.resourceVersion = resourceVersion
        self.yamlUTF8 = yamlUTF8
        self.summaryFields = summaryFields
        self.labels = labels
        self.annotations = annotations
        self.containers = containers
        self.podLabelSelector = podLabelSelector
    }
}

public enum ObjectRelationshipKind: String, Hashable, Sendable {
    case owner
    case child
    case related
}

public struct ObjectRelationship: Hashable, Sendable, Identifiable {
    public var kind: ObjectRelationshipKind
    public var identity: ResourceIdentity
    public var label: String
    public var stale: Bool
    public var potentiallyIncomplete: Bool

    public init(
        kind: ObjectRelationshipKind,
        identity: ResourceIdentity,
        label: String,
        stale: Bool = false,
        potentiallyIncomplete: Bool = false
    ) {
        self.kind = kind
        self.identity = identity
        self.label = label
        self.stale = stale
        self.potentiallyIncomplete = potentiallyIncomplete
    }

    public var id: ResourceUID { identity.uid }
}

public struct ObjectRelationships: Hashable, Sendable {
    public var values: [ObjectRelationship]
    public var childrenPotentiallyIncomplete: Bool

    public init(
        values: [ObjectRelationship],
        childrenPotentiallyIncomplete: Bool
    ) {
        self.values = values
        self.childrenPotentiallyIncomplete = childrenPotentiallyIncomplete
    }
}

public struct RelationshipScanProgress: Hashable, Sendable {
    public var resourcesTotal: UInt32
    public var resourcesScanned: UInt32
    public var objectsExamined: UInt64
    public var resourcesFailed: UInt32
    public var currentResource: String
    public var complete: Bool
    public var potentiallyIncomplete: Bool

    public init(
        resourcesTotal: UInt32 = 0,
        resourcesScanned: UInt32 = 0,
        objectsExamined: UInt64 = 0,
        resourcesFailed: UInt32 = 0,
        currentResource: String = "",
        complete: Bool = false,
        potentiallyIncomplete: Bool = false
    ) {
        self.resourcesTotal = resourcesTotal
        self.resourcesScanned = resourcesScanned
        self.objectsExamined = objectsExamined
        self.resourcesFailed = resourcesFailed
        self.currentResource = currentResource
        self.complete = complete
        self.potentiallyIncomplete = potentiallyIncomplete
    }
}

public struct RelationshipScanMessage: Hashable, Sendable {
    public var scanID: String
    public var cursor: StreamCursor
    public var relationships: [ObjectRelationship]
    public var progress: RelationshipScanProgress
    public var warning: ClusterManagerIssue?

    public init(
        scanID: String,
        cursor: StreamCursor,
        relationships: [ObjectRelationship] = [],
        progress: RelationshipScanProgress,
        warning: ClusterManagerIssue? = nil
    ) {
        self.scanID = scanID
        self.cursor = cursor
        self.relationships = relationships
        self.progress = progress
        self.warning = warning
    }
}

/// Maintains the cache-first relationship baseline while an exhaustive scan
/// streams child matches. A failed or cancelled scan therefore never erases
/// useful cached results. A complete scan replaces the cached child subset only
/// when discovery and every resource LIST succeeded; partial results merge with
/// the cache while owner relationships remain intact.
public struct RelationshipScanCollection: Hashable, Sendable {
    public private(set) var values: [ObjectRelationship]
    private let baseline: [ObjectRelationship]
    private var scannedChildren: [ResourceIdentity: ObjectRelationship] = [:]

    public init(baseline: [ObjectRelationship]) {
        self.baseline = baseline
        values = Self.sorted(baseline)
    }

    public mutating func apply(_ message: RelationshipScanMessage) {
        for relationship in message.relationships where relationship.kind == .child {
            scannedChildren[relationship.identity] = relationship
        }
        let ownersAndRelated = baseline.filter { $0.kind != .child }
        if message.progress.complete && !message.progress.potentiallyIncomplete {
            values = Self.sorted(ownersAndRelated + Array(scannedChildren.values))
        } else {
            var merged = Dictionary(
                uniqueKeysWithValues: baseline
                    .filter { $0.kind == .child }
                    .map { ($0.identity, $0) }
            )
            merged.merge(scannedChildren) { _, scanned in scanned }
            values = Self.sorted(ownersAndRelated + Array(merged.values))
        }
    }

    private static func sorted(_ values: [ObjectRelationship]) -> [ObjectRelationship] {
        values.sorted { left, right in
            [
                left.kind.rawValue, left.identity.group, left.identity.version,
                left.identity.resource, left.identity.namespace,
                left.identity.name, left.identity.uid.rawValue,
            ].joined(separator: "\u{0}")
                < [
                    right.kind.rawValue, right.identity.group, right.identity.version,
                    right.identity.resource, right.identity.namespace,
                    right.identity.name, right.identity.uid.rawValue,
                ].joined(separator: "\u{0}")
        }
    }
}

public enum ObjectWatchEvent: Hashable, Sendable {
    case status(cursor: StreamCursor, resourceVersion: String)
    case updated(cursor: StreamCursor, detail: ObjectDetail)
    case deleted(cursor: StreamCursor, detail: ObjectDetail)
    case failure(cursor: StreamCursor, issue: ClusterManagerIssue)

    public var cursor: StreamCursor {
        switch self {
        case .status(let cursor, _), .updated(let cursor, _),
            .deleted(let cursor, _), .failure(let cursor, _):
            cursor
        }
    }
}

public enum DataValueKind: String, Hashable, Sendable {
    case text
    case binary
}

/// Values are deliberately not Codable or printable. Secret and ConfigMap
/// bytes remain transient and cannot enter window restoration by construction.
public final class ObjectDataEntry: @unchecked Sendable, Identifiable {
    public let id: String
    public private(set) var kind: DataValueKind
    public private(set) var value: SensitiveBytes
    public let byteSize: UInt64
    public let contentHash: Data

    public init(
        key: String,
        kind: DataValueKind,
        value: Data,
        byteSize: UInt64,
        contentHash: Data
    ) {
        self.id = key
        self.kind = kind
        self.value = SensitiveBytes(value)
        self.byteSize = byteSize
        self.contentHash = contentHash
    }
}

public struct ObjectData: Sendable {
    public var identity: ResourceIdentity
    public var resourceVersion: String
    public var entries: [ObjectDataEntry]
    public var secret: Bool

    public init(
        identity: ResourceIdentity,
        resourceVersion: String,
        entries: [ObjectDataEntry],
        secret: Bool
    ) {
        self.identity = identity
        self.resourceVersion = resourceVersion
        self.entries = entries
        self.secret = secret
    }
}

/// Secret values are carried only for the transient edit-confirmation flow.
/// They deliberately use `SensitiveBytes`, keeping them out of printable,
/// hashable, codable, and restoration-friendly value models.
public struct SemanticDiffEntry: Sendable {
    public var path: String
    public var beforeSummary: String
    public var afterSummary: String
    public var severity: CellSeverity
    public let beforeDecodedSecretValue: SensitiveBytes?
    public let afterDecodedSecretValue: SensitiveBytes?

    public init(
        path: String,
        beforeSummary: String,
        afterSummary: String,
        severity: CellSeverity = .normal,
        beforeDecodedSecretValue: SensitiveBytes? = nil,
        afterDecodedSecretValue: SensitiveBytes? = nil
    ) {
        self.path = path
        self.beforeSummary = beforeSummary
        self.afterSummary = afterSummary
        self.severity = severity
        self.beforeDecodedSecretValue = beforeDecodedSecretValue
        self.afterDecodedSecretValue = afterDecodedSecretValue
    }
}

public struct PreparedYAMLEdit: Sendable {
    public var normalizedYAMLUTF8: Data
    public var currentResourceVersion: String
    public var diff: [SemanticDiffEntry]
    public var unifiedDiffUTF8: Data
    public var unifiedDiffTruncated: Bool

    public init(
        normalizedYAMLUTF8: Data,
        currentResourceVersion: String,
        diff: [SemanticDiffEntry],
        unifiedDiffUTF8: Data = Data(),
        unifiedDiffTruncated: Bool = false
    ) {
        self.normalizedYAMLUTF8 = normalizedYAMLUTF8
        self.currentResourceVersion = currentResourceVersion
        self.diff = diff
        self.unifiedDiffUTF8 = unifiedDiffUTF8
        self.unifiedDiffTruncated = unifiedDiffTruncated
    }
}

public enum DataMutationKind: Hashable, Sendable {
    case set(key: String, kind: DataValueKind, value: Data, expectedContentHash: Data)
    case delete(key: String, expectedContentHash: Data)
    case rename(key: String, newKey: String, expectedContentHash: Data)
}

public enum OperationState: String, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .pending, .running: false
        case .succeeded, .partiallySucceeded, .failed, .cancelled: true
        }
    }
}

public enum OperationItemState: String, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case skipped
    case cancelled
}

public struct OperationItemResult: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var state: OperationItemState
    public var newResourceVersion: String
    public var issue: ClusterManagerIssue?

    public init(
        identity: ResourceIdentity,
        state: OperationItemState,
        newResourceVersion: String = "",
        issue: ClusterManagerIssue? = nil
    ) {
        self.identity = identity
        self.state = state
        self.newResourceVersion = newResourceVersion
        self.issue = issue
    }
}

public struct OperationProgress: Hashable, Sendable {
    public var cursor: StreamCursor
    public var operationID: String
    public var state: OperationState
    public var completedItems: UInt32
    public var totalItems: UInt32
    public var itemResults: [OperationItemResult]
    public var aggregateOnly: Bool
    /// Non-success details omitted after the engine's bounded aggregate detail
    /// budget was reached. Successful aggregate identities are not counted.
    public var omittedItemResults: UInt32
    public var issue: ClusterManagerIssue?

    public init(
        cursor: StreamCursor,
        operationID: String,
        state: OperationState,
        completedItems: UInt32,
        totalItems: UInt32,
        itemResults: [OperationItemResult],
        aggregateOnly: Bool = false,
        omittedItemResults: UInt32 = 0,
        issue: ClusterManagerIssue? = nil
    ) {
        self.cursor = cursor
        self.operationID = operationID
        self.state = state
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.itemResults = itemResults
        self.aggregateOnly = aggregateOnly
        self.omittedItemResults = omittedItemResults
        self.issue = issue
    }
}

public protocol ObjectDetailProviding: Sendable {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail
    /// Fetches the Pod presentation used by the Return-driven container table.
    /// Ordinary Details deliberately does not opt into Metrics API work.
    func getPodContainerDetail(identity: ResourceIdentity) async throws -> ObjectDetail
    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error>
    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships
    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error>
    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async
    func getData(identity: ResourceIdentity) async throws -> ObjectData
    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit
    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>
    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error>
}

public extension ObjectDetailProviding {
    func getPodContainerDetail(identity: ResourceIdentity) async throws -> ObjectDetail {
        try await getObject(identity: identity)
    }
}
