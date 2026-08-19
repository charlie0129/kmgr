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
public struct ResourceInvalidationSignpostMetadata: Hashable, Sendable {
    public var generation: UInt64
    public var sequence: UInt64
    public var presentationRevision: UInt64
    public var indexRevision: UInt64
    public var rowsVisible: UInt64

    public init(
        generation: UInt64,
        sequence: UInt64,
        presentationRevision: UInt64,
        indexRevision: UInt64,
        rowsVisible: UInt64
    ) {
        self.generation = generation
        self.sequence = sequence
        self.presentationRevision = presentationRevision
        self.indexRevision = indexRevision
        self.rowsVisible = rowsVisible
    }
}

public extension ResourceViewMessage {
    /// Returns only bounded cardinalities and revisions for performance
    /// correlation. Rows and complete UID order never travel on this stream.
    var resourceInvalidationSignpostMetadata: ResourceInvalidationSignpostMetadata? {
        switch self {
        case .invalidation(let cursor, let invalidation):
            ResourceInvalidationSignpostMetadata(
                generation: cursor.generation,
                sequence: cursor.sequence,
                presentationRevision: invalidation.presentationRevision,
                indexRevision: invalidation.indexRevision,
                rowsVisible: invalidation.rowsVisible
            )
        case .schema, .status, .reconciled, .failure:
            nil
        }
    }
}
