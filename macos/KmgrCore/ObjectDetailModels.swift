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

/// The bounded owner-reference projection used by parent navigation. It is
/// part of the authoritative object detail response rather than a separate
/// relationship surface; child discovery and relationship scans are not
/// supported.
public struct ObjectOwnerReference: Hashable, Sendable {
    public var group: String
    public var version: String
    public var kind: String
    public var name: String
    public var uid: ResourceUID
    public var controller: Bool
    public var stale: Bool

    public init(
        group: String,
        version: String,
        kind: String,
        name: String,
        uid: ResourceUID,
        controller: Bool = false,
        stale: Bool = false
    ) {
        self.group = group
        self.version = version
        self.kind = kind
        self.name = name
        self.uid = uid
        self.controller = controller
        self.stale = stale
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
    public var owners: [ObjectOwnerReference]
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
        owners: [ObjectOwnerReference] = [],
        podLabelSelector: String = ""
    ) {
        self.identity = identity
        self.resourceVersion = resourceVersion
        self.yamlUTF8 = yamlUTF8
        self.summaryFields = summaryFields
        self.labels = labels
        self.annotations = annotations
        self.containers = containers
        self.owners = owners
        self.podLabelSelector = podLabelSelector
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
