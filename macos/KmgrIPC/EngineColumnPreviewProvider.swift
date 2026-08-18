import Foundation
import GRPCCore
import KmgrCore
import KmgrProto

/// Narrow RPC seam for testing column-preview protobuf mapping without an
/// engine process or Kubernetes cluster.
public protocol ColumnPreviewRPC: Sendable {
    func previewColumn(
        request: Kmgr_V1_PreviewColumnRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PreviewColumnResponse
}

public struct EngineColumnPreviewRPC: ColumnPreviewRPC {
    private let connection: EngineConnection

    public init(connection: EngineConnection) {
        self.connection = connection
    }

    public func previewColumn(
        request: Kmgr_V1_PreviewColumnRequest,
        timeout: Duration
    ) async throws -> Kmgr_V1_PreviewColumnResponse {
        var options = CallOptions.defaults
        options.timeout = timeout
        options.waitForReady = false
        return try await connection.viewClient().previewColumn(
            request,
            options: options
        )
    }
}

public struct EngineColumnPreviewProvider: ColumnPreviewProviding {
    private let rpc: any ColumnPreviewRPC
    private let timeout: Duration
    private let now: @Sendable () -> Date
    private let requestID: @Sendable () -> String

    public init(
        connection: EngineConnection,
        timeout: Duration = .seconds(10)
    ) {
        self.init(
            rpc: EngineColumnPreviewRPC(connection: connection),
            timeout: timeout
        )
    }

    public init(
        rpc: any ColumnPreviewRPC,
        timeout: Duration = .seconds(10),
        now: @escaping @Sendable () -> Date = Date.init,
        requestID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.rpc = rpc
        self.timeout = timeout
        self.now = now
        self.requestID = requestID
    }

    public func previewColumn(
        _ request: ColumnPreviewRequest
    ) async throws -> ColumnPreviewResult {
        let rpcRequest = makeRequest(from: request)
        do {
            let response = try await rpc.previewColumn(
                request: rpcRequest,
                timeout: timeout
            )
            guard response.requestID == rpcRequest.context.requestID else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "RequestIDMismatch",
                    message: "The engine returned a response for a different column-preview request.",
                    operation: "preview CEL column"
                )
            }
            // The engine may return both a display-only raw cell and a
            // validation error when the expression evaluated but does not
            // match the draft's declared type. Preserve both so the editor
            // can teach the user from the value instead of replacing it with
            // an opaque failure banner.
            let validationIssue = response.hasError
                ? EngineClusterContextProvider.issue(from: response.error) : nil
            if let validationIssue, !response.hasPreview {
                throw validationIssue
            }
            guard response.hasPreview else {
                throw ClusterManagerIssue(
                    category: .internalFailure,
                    reason: "MissingColumnPreview",
                    message: "The engine returned a successful column preview without a rendered value.",
                    operation: "preview CEL column"
                )
            }
            return ColumnPreviewResult(
                requestID: response.requestID,
                celEnvironment: response.celEnvironment,
                preview: Self.cell(from: response.preview),
                usedSampleObject: response.usedSampleObject,
                evaluatedObject: response.hasEvaluatedObject
                    ? Self.identity(from: response.evaluatedObject) : nil,
                validationIssue: validationIssue
            )
        } catch {
            throw EngineClusterContextProvider.issue(
                from: error,
                contextName: "",
                operation: "preview CEL column"
            )
        }
    }

    private func makeRequest(
        from request: ColumnPreviewRequest
    ) -> Kmgr_V1_PreviewColumnRequest {
        var result = Kmgr_V1_PreviewColumnRequest()
        result.context.requestID = requestID()
        result.context.clusterSessionID = request.sessionID
        result.context.deadlineUnixMs = Int64(
            (now().timeIntervalSince1970 + Self.seconds(timeout)) * 1_000
        )

        result.resource.group = request.resource.group
        result.resource.version = request.resource.version
        result.resource.resource = request.resource.resource
        result.resource.kind = request.resource.kind
        result.resource.namespaced = request.resource.namespaced

        result.namespaceScope.allNamespaces = request.namespaceScope.allNamespaces
        result.namespaceScope.namespaces = request.namespaceScope.namespaces

        result.column.id = request.column.id
        result.column.title = request.column.title
        result.column.expression = request.column.expression ?? ""
        result.column.resultType = request.column.type.rawValue
        result.column.missing = request.column.missing ?? ""
        result.column.listJoiner = request.column.listJoiner ?? ""

        if let selectedObject = request.selectedObject {
            result.selectedObject = Self.identity(from: selectedObject)
        }
        return result
    }

    private static func identity(
        from value: ResourceIdentity
    ) -> Kmgr_V1_ResourceIdentity {
        var result = Kmgr_V1_ResourceIdentity()
        result.clusterSessionID = value.clusterSessionID
        result.group = value.group
        result.version = value.version
        result.resource = value.resource
        result.namespace = value.namespace
        result.name = value.name
        result.uid = value.uid.rawValue
        return result
    }

    private static func identity(
        from value: Kmgr_V1_ResourceIdentity
    ) -> ResourceIdentity {
        ResourceIdentity(
            clusterSessionID: value.clusterSessionID,
            group: value.group,
            version: value.version,
            resource: value.resource,
            namespace: value.namespace,
            name: value.name,
            uid: ResourceUID(value.uid)
        )
    }

    private static func cell(from value: Kmgr_V1_Cell) -> Cell {
        let typedValue: CellTypedValue? = switch value.typedValue {
        case .stringValue(let string): .string(string)
        case .numberValue(let number): .number(number)
        case .integerValue(let integer): .integer(integer)
        case .quantityValue(let quantity): .quantity(KubernetesQuantityValue(
            exact: quantity.exact,
            display: quantity.display,
            sortValue: quantity.sortValue
        ))
        case .timestampUnixMs(let milliseconds):
            .timestampUnixMilliseconds(milliseconds)
        case .usage(let usage): .usage(ResourceUsageValue(
            usage: usage.usageAvailable ? usage.used : nil,
            request: usage.hasRequested ? usage.requested : nil,
            limit: usage.hasLimit ? usage.limit : nil,
            capacity: usage.hasCapacity ? usage.capacity : nil,
            sortValue: usageSortValue(usage),
            unit: usage.unit,
            resourceName: usage.resourceName,
            measuredAtUnixMilliseconds: usage.measuredAtUnixMs > 0
                ? usage.measuredAtUnixMs : nil,
            provider: usage.provider,
            measurementScope: usage.measurementScope
        ))
        case .boolValue(let boolean): .boolean(boolean)
        case .opaqueSortValue(let data): .opaqueSortValue(data)
        case nil: nil
        }
        let severity: CellSeverity = switch value.severity {
        case .info: .informational
        case .warning: .warning
        case .error: .critical
        case .muted: .muted
        case .unspecified, .normal, .UNRECOGNIZED: .normal
        }
        return Cell(
            columnID: value.columnID,
            displayText: value.displayText,
            typedValue: typedValue,
            tooltip: value.tooltip,
            severity: severity
        )
    }

    private static func usageSortValue(
        _ value: Kmgr_V1_ResourceUsageValue
    ) -> Double? {
        if value.usageAvailable { return value.used }
        if value.hasRequested { return value.requested }
        if value.hasLimit { return value.limit }
        if value.hasCapacity { return value.capacity }
        return nil
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
