import Foundation

public struct ObjectSummaryField: Hashable, Sendable {
    public var sectionID: String
    public var fieldID: String
    public var label: String
    public var displayText: String
    public var tooltip: String
    public var severity: CellSeverity

    public init(
        sectionID: String,
        fieldID: String,
        label: String,
        displayText: String,
        tooltip: String = "",
        severity: CellSeverity = .normal
    ) {
        self.sectionID = sectionID
        self.fieldID = fieldID
        self.label = label
        self.displayText = displayText
        self.tooltip = tooltip
        self.severity = severity
    }
}

public struct ObjectDetail: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var resourceVersion: String
    public var yamlUTF8: Data
    public var summaryFields: [ObjectSummaryField]
    public var labels: [String: String]
    public var annotations: [String: String]
    public var metrics: [ResourceUsageValue]

    public init(
        identity: ResourceIdentity,
        resourceVersion: String,
        yamlUTF8: Data = Data(),
        summaryFields: [ObjectSummaryField] = [],
        labels: [String: String] = [:],
        annotations: [String: String] = [:],
        metrics: [ResourceUsageValue] = []
    ) {
        self.identity = identity
        self.resourceVersion = resourceVersion
        self.yamlUTF8 = yamlUTF8
        self.summaryFields = summaryFields
        self.labels = labels
        self.annotations = annotations
        self.metrics = metrics
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

public struct SemanticDiffEntry: Hashable, Sendable {
    public var path: String
    public var beforeSummary: String
    public var afterSummary: String
    public var severity: CellSeverity

    public init(
        path: String,
        beforeSummary: String,
        afterSummary: String,
        severity: CellSeverity = .normal
    ) {
        self.path = path
        self.beforeSummary = beforeSummary
        self.afterSummary = afterSummary
        self.severity = severity
    }
}

public struct PreparedYAMLEdit: Hashable, Sendable {
    public var normalizedYAMLUTF8: Data
    public var currentResourceVersion: String
    public var diff: [SemanticDiffEntry]

    public init(
        normalizedYAMLUTF8: Data,
        currentResourceVersion: String,
        diff: [SemanticDiffEntry]
    ) {
        self.normalizedYAMLUTF8 = normalizedYAMLUTF8
        self.currentResourceVersion = currentResourceVersion
        self.diff = diff
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

public struct OperationItemResult: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var state: OperationState
    public var newResourceVersion: String
    public var issue: ClusterManagerIssue?

    public init(
        identity: ResourceIdentity,
        state: OperationState,
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
    public var issue: ClusterManagerIssue?

    public init(
        cursor: StreamCursor,
        operationID: String,
        state: OperationState,
        completedItems: UInt32,
        totalItems: UInt32,
        itemResults: [OperationItemResult],
        issue: ClusterManagerIssue? = nil
    ) {
        self.cursor = cursor
        self.operationID = operationID
        self.state = state
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.itemResults = itemResults
        self.issue = issue
    }
}

public protocol ObjectDetailProviding: Sendable {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail
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
