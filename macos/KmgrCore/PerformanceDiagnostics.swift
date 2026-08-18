/// Stable, privacy-safe names used by Kmgr's Instruments signposts. Keep the
/// vocabulary small so recordings from different releases remain comparable.
public enum PerformanceSignpostCatalog {
    public static let subsystem = Product.bundleIdentifier

    public static let workspaceStreamCategory = "workspace-stream"
    public static let resourceTableCategory = "resource-table"
    public static let logsCategory = "logs"

    public static let viewEventDecode: StaticString = "ViewEventDecode"
    public static let resourceProjectionRequest: StaticString = "ResourceProjectionRequest"
    public static let resourceModelApply: StaticString = "ResourceModelApply"
    public static let resourceTableReload: StaticString = "ResourceTableReload"
    public static let logStoreAppend: StaticString = "LogStoreAppend"
    public static let logTextFormat: StaticString = "LogTextFormat"
    public static let logTextInstall: StaticString = "LogTextInstall"
}

/// The only streamed resource metadata admitted to model/table signposts.
/// Object names, namespaces, UIDs, cell values, selectors, and filter text are
/// deliberately absent.
public struct ResourceBatchSignpostMetadata: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case snapshot
        case delta
    }

    public var kind: Kind
    public var generation: UInt64
    public var sequence: UInt64
    public var upsertCount: Int
    public var removalCount: Int
    public var orderCount: Int
    public var replacesOrder: Bool

    public init(
        kind: Kind,
        generation: UInt64,
        sequence: UInt64,
        upsertCount: Int,
        removalCount: Int,
        orderCount: Int,
        replacesOrder: Bool
    ) {
        self.kind = kind
        self.generation = generation
        self.sequence = sequence
        self.upsertCount = upsertCount
        self.removalCount = removalCount
        self.orderCount = orderCount
        self.replacesOrder = replacesOrder
    }
}

public extension ResourceViewMessage {
    /// Returns bounded cardinalities and stream revisions for performance
    /// correlation. Status and error events do not mutate the table model.
    var resourceBatchSignpostMetadata: ResourceBatchSignpostMetadata? {
        switch self {
        case .snapshot(let cursor, let chunk):
            ResourceBatchSignpostMetadata(
                kind: .snapshot,
                generation: cursor.generation,
                sequence: cursor.sequence,
                upsertCount: chunk.rows.count,
                removalCount: 0,
                orderCount: chunk.rows.count,
                replacesOrder: chunk.last
            )
        case .delta(let cursor, let delta):
            ResourceBatchSignpostMetadata(
                kind: .delta,
                generation: cursor.generation,
                sequence: cursor.sequence,
                upsertCount: delta.upserts.count,
                removalCount: delta.removedUIDs.count,
                orderCount: delta.orderedUIDs.count,
                replacesOrder: delta.orderIsComplete
            )
        case .status, .reconciled, .failure:
            nil
        }
    }
}
