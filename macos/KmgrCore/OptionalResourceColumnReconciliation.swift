import Foundation

/// The identity the Go projector uses for an optimized native extractor.
/// Display IDs and titles are deliberately excluded so aliases cannot cause
/// two copies of the same exact scheduler resource to be installed.
public struct NativeColumnExtractorIdentity: Hashable, Sendable {
    public var source: ColumnSource
    public var value: String

    public init(source: ColumnSource, value: String) {
        self.source = source
        self.value = value
    }
}

public extension ColumnDefinition {
    var nativeExtractorIdentity: NativeColumnExtractorIdentity? {
        guard source == .builtin || source == .metric,
            let value,
            !value.isEmpty
        else { return nil }
        return NativeColumnExtractorIdentity(source: source, value: value)
    }
}

/// Ephemeral per-view overlay generated from one cache-only discovery result.
///
/// This type is intentionally not Codable. Persisted/user-configured columns
/// are always supplied separately and win by both display ID and authoritative
/// native extractor identity when the two sets are presented together.
public struct OptionalResourceColumnOverlay: Hashable, Sendable {
    public private(set) var catalog: OptionalResourceCatalog?
    public private(set) var definitions: [ColumnDefinition]

    public init(
        catalog: OptionalResourceCatalog? = nil,
        definitions: [ColumnDefinition] = []
    ) {
        self.catalog = catalog
        self.definitions = definitions
    }

    /// The richer built-in `metric:ephemeral-storage` column uses this entry
    /// as availability metadata. It is never duplicated as an exact-resource
    /// `metric:resource:ephemeral-storage` column.
    public var ephemeralStorage: OptionalResourceCatalogEntry? {
        catalog?.resources.first {
            $0.category == .ephemeralStorage && $0.exactKey == "ephemeral-storage"
        }
    }

    public mutating func clear() {
        catalog = nil
        definitions.removeAll(keepingCapacity: true)
    }

    /// Atomically replaces the prior ephemeral overlay. Resources that vanish
    /// from a later catalog therefore vanish from the overlay, while persisted
    /// definitions remain untouched.
    public mutating func reconcile(
        _ catalog: OptionalResourceCatalog,
        applicableResource: DiscoveredResource,
        persistedDefinitions: [ColumnDefinition]
    ) throws {
        let applicableGVR = GVR(
            group: applicableResource.group,
            version: applicableResource.version,
            resource: applicableResource.resource
        )
        var usedIDs = Set(persistedDefinitions.map(\.id))
        var usedExtractors = Set(
            persistedDefinitions.compactMap(\.nativeExtractorIdentity)
        )
        var reconciled: [ColumnDefinition] = []

        for entry in catalog.resources {
            let entryGVR = GVR(
                group: entry.applicableResource.group,
                version: entry.applicableResource.version,
                resource: entry.applicableResource.resource
            )
            guard entryGVR == applicableGVR else { continue }
            guard entry.category != .ephemeralStorage else { continue }
            guard entry.isPresent || entry.isExplicitlyConfigured else { continue }

            var definition = try NativeColumnCatalog.exactResourceDefinition(
                resourceName: entry.exactKey,
                title: entry.displayName,
                group: applicableResource.group,
                version: applicableResource.version,
                resource: applicableResource.resource
            )
            // Unlike persisted definitions, this transient definition is not
            // present in the Go column resolver. Use the raw native extractor
            // as its display/wire ID so the projector's protocol-compatible
            // fallback can evaluate it without an on-disk configuration edit.
            definition.id = definition.value!
            // Detected resources appear after discovery; configured-but-absent
            // resources stay available in Columns without adding an empty
            // visible column automatically.
            definition.enabled = entry.isPresent

            guard let identity = definition.nativeExtractorIdentity,
                !usedIDs.contains(definition.id),
                !usedExtractors.contains(identity)
            else { continue }
            usedIDs.insert(definition.id)
            usedExtractors.insert(identity)
            reconciled.append(definition)
        }

        self.catalog = catalog
        definitions = reconciled
    }

    /// Returns presentation definitions without ever replacing or modifying a
    /// persisted definition. Rechecking conflicts here also makes a newly
    /// persisted former overlay column win before the next catalog refresh.
    public func applying(
        to persistedDefinitions: [ColumnDefinition]
    ) -> [ColumnDefinition] {
        var usedIDs = Set(persistedDefinitions.map(\.id))
        var usedExtractors = Set(
            persistedDefinitions.compactMap(\.nativeExtractorIdentity)
        )
        var result = persistedDefinitions
        for definition in definitions {
            guard let identity = definition.nativeExtractorIdentity,
                !usedIDs.contains(definition.id),
                !usedExtractors.contains(identity)
            else { continue }
            usedIDs.insert(definition.id)
            usedExtractors.insert(identity)
            result.append(definition)
        }
        return result
    }
}

/// Exact identity for one cache-only discovery lifecycle. View generation is
/// part of the key so a completion from a replaced stream cannot affect its
/// successor even when the session and GVR are unchanged.
public struct OptionalResourceCatalogDiscoveryTarget: Hashable, Sendable {
    public struct Key: Hashable, Sendable {
        public var sessionID: String
        public var gvr: GVR
        public var viewGeneration: UInt64

        public init(sessionID: String, gvr: GVR, viewGeneration: UInt64) {
            self.sessionID = sessionID
            self.gvr = gvr
            self.viewGeneration = viewGeneration
        }
    }

    public var sessionID: String
    public var applicableResource: DiscoveredResource
    public var viewGeneration: UInt64

    public init(
        sessionID: String,
        applicableResource: DiscoveredResource,
        viewGeneration: UInt64
    ) {
        self.sessionID = sessionID
        self.applicableResource = applicableResource
        self.viewGeneration = viewGeneration
    }

    public var key: Key {
        Key(
            sessionID: sessionID,
            gvr: GVR(
                group: applicableResource.group,
                version: applicableResource.version,
                resource: applicableResource.resource
            ),
            viewGeneration: viewGeneration
        )
    }
}

/// Opaque authority to apply one asynchronous discovery completion. Callers
/// must return every success, failure, or cancellation to the gate so its
/// in-flight accounting remains exact.
public struct OptionalResourceCatalogDiscoveryTicket: Hashable, Sendable {
    public let request: OptionalResourceCatalogRequest
    public let targetKey: OptionalResourceCatalogDiscoveryTarget.Key

    fileprivate let selectionRevision: UInt64
    fileprivate let requestSequence: UInt64
}

/// Pure scheduling gate for post-base-row optional-resource discovery.
///
/// Selection alone never creates a request. A caller must first report that a
/// base view is usable, after which one automatic request may begin. Explicit
/// refreshes are allowed only after the same condition and never overlap an
/// outstanding request for the exact session/GVR/view-generation key.
public struct OptionalResourceCatalogDiscoveryGate: Sendable {
    public private(set) var activeTarget: OptionalResourceCatalogDiscoveryTarget?
    public private(set) var baseViewIsUsable = false
    public private(set) var automaticDiscoveryCompleted = false

    private var selectionRevision: UInt64 = 0
    private var requestSequence: UInt64 = 0
    private var outstandingByTarget: [
        OptionalResourceCatalogDiscoveryTarget.Key:
            OptionalResourceCatalogDiscoveryTicket
    ] = [:]

    public init() {}

    /// Changes the target and invalidates applicability of prior completions.
    /// Outstanding requests remain accounted for until their caller reports a
    /// success, failure, or cancellation.
    public mutating func select(
        _ target: OptionalResourceCatalogDiscoveryTarget?
    ) {
        guard activeTarget?.key != target?.key else {
            activeTarget = target
            return
        }
        selectionRevision &+= 1
        activeTarget = target
        baseViewIsUsable = false
        automaticDiscoveryCompleted = false
    }

    /// Call only after a base snapshot/chunk has been applied and is usable,
    /// including a completed empty snapshot. This does not itself start work.
    public mutating func markBaseViewUsable() {
        guard activeTarget != nil else { return }
        baseViewIsUsable = true
    }

    /// Returns the only value that authorizes an RPC. `refresh` supports later
    /// cache-fill checks but never bypasses base-view readiness or overlap
    /// protection.
    public mutating func beginDiscovery(
        refresh: Bool = false
    ) -> OptionalResourceCatalogDiscoveryTicket? {
        guard let target = activeTarget,
            baseViewIsUsable,
            NativeColumnCatalog.supportsExactResources(
                group: target.applicableResource.group,
                version: target.applicableResource.version,
                resource: target.applicableResource.resource
            ),
            outstandingByTarget[target.key] == nil,
            refresh || !automaticDiscoveryCompleted
        else { return nil }

        requestSequence &+= 1
        let ticket = OptionalResourceCatalogDiscoveryTicket(
            request: OptionalResourceCatalogRequest(
                sessionID: target.sessionID,
                applicableResource: target.applicableResource
            ),
            targetKey: target.key,
            selectionRevision: selectionRevision,
            requestSequence: requestSequence
        )
        outstandingByTarget[target.key] = ticket
        return ticket
    }

    /// Finishes an authenticated successful request. `true` means the result
    /// still belongs to the selected target and may be reconciled; `false`
    /// means it is stale or was already consumed and must be ignored.
    @discardableResult
    public mutating func finishSuccess(
        _ ticket: OptionalResourceCatalogDiscoveryTicket
    ) -> Bool {
        guard outstandingByTarget[ticket.targetKey] == ticket else { return false }
        outstandingByTarget.removeValue(forKey: ticket.targetKey)
        guard activeTarget?.key == ticket.targetKey,
            selectionRevision == ticket.selectionRevision
        else { return false }
        automaticDiscoveryCompleted = true
        return true
    }

    /// Releases in-flight accounting after failure or cancellation. A current
    /// target may retry automatically; a stale target remains ignored.
    @discardableResult
    public mutating func finishWithoutResult(
        _ ticket: OptionalResourceCatalogDiscoveryTicket
    ) -> Bool {
        guard outstandingByTarget[ticket.targetKey] == ticket else { return false }
        outstandingByTarget.removeValue(forKey: ticket.targetKey)
        return activeTarget?.key == ticket.targetKey &&
            selectionRevision == ticket.selectionRevision
    }

    public func hasOutstandingRequest(
        for key: OptionalResourceCatalogDiscoveryTarget.Key
    ) -> Bool {
        outstandingByTarget[key] != nil
    }
}
