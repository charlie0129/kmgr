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

public struct ResourceDeleteOptions: Hashable, Sendable {
    public var propagationPolicy: DeletePropagationPolicy
    public var gracePeriodSeconds: Int64?
    public var maxConcurrency: UInt32

    public init(
        propagationPolicy: DeletePropagationPolicy = .background,
        gracePeriodSeconds: Int64? = nil,
        maxConcurrency: UInt32 = 4
    ) {
        self.propagationPolicy = propagationPolicy
        self.gracePeriodSeconds = gracePeriodSeconds
        self.maxConcurrency = maxConcurrency
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
