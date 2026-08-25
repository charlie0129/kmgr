import Foundation

public enum LogResourceCompatibility {
    public static func supportsStaticPodResolution(_ identity: ResourceIdentity) -> Bool {
        guard !identity.namespace.isEmpty else { return false }
        if identity.group.isEmpty, identity.version == "v1", identity.resource == "pods" {
            return true
        }
        if identity.group == "apps", identity.version == "v1" {
            return ["deployments", "statefulsets", "daemonsets", "replicasets"]
                .contains(identity.resource)
        }
        return identity.group == "batch" && identity.version == "v1"
            && ["jobs", "cronjobs"].contains(identity.resource)
    }

    public static func supportsSelection(_ identities: [ResourceIdentity]) -> Bool {
        !identities.isEmpty && identities.count <= 128
            && identities.allSatisfy(supportsStaticPodResolution)
    }
}

public struct LogSource: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var container: String
    public var sourceID: String
    public var label: String

    public init(
        identity: ResourceIdentity,
        container: String,
        sourceID: String,
        label: String
    ) {
        self.identity = identity
        self.container = container
        self.sourceID = sourceID
        self.label = label
    }
}

public struct PodLogSourceInventory: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var containers: [String]

    public init(identity: ResourceIdentity, containers: [String]) {
        self.identity = identity
        self.containers = containers
    }
}

public struct LogSourceResolution: Hashable, Sendable {
    public var pods: [PodLogSourceInventory]
    public var staticWorkloadSnapshot: Bool

    public init(
        pods: [PodLogSourceInventory],
        staticWorkloadSnapshot: Bool
    ) {
        self.pods = pods
        self.staticWorkloadSnapshot = staticWorkloadSnapshot
    }
}

public enum PodLogContainerSelection: Hashable, Sendable {
    case all
    case named(String)

    public var title: String {
        switch self {
        case .all: "All Containers"
        case .named(let name): name
        }
    }
}

/// Typed launch intent for a log window. Resource and workload views request
/// every regular container, while a virtual Container row can preserve its
/// exact parent Pod UID and opt into one named container.
public struct LogOpenRequest: Hashable, Sendable {
    public var resources: [ResourceIdentity]
    public var containerSelection: PodLogContainerSelection
    public var previous: Bool

    public init(
        resources: [ResourceIdentity],
        containerSelection: PodLogContainerSelection = .all,
        previous: Bool = false
    ) {
        self.resources = resources
        self.containerSelection = containerSelection
        self.previous = previous
    }

    public static func allContainers(
        for resources: [ResourceIdentity],
        previous: Bool = false
    ) -> Self {
        Self(
            resources: resources,
            containerSelection: .all,
            previous: previous
        )
    }

    public static func namedContainer(
        _ name: String,
        in pod: ResourceIdentity,
        previous: Bool = false
    ) -> Self {
        Self(
            resources: [pod],
            containerSelection: .named(name),
            previous: previous
        )
    }
}

public struct ResolvedLogOpenRequest: Hashable, Sendable {
    public var sources: [LogSource]
    public var availableSources: [LogSource]
    public var staticWorkloadSnapshot: Bool

    public init(
        sources: [LogSource],
        availableSources: [LogSource],
        staticWorkloadSnapshot: Bool
    ) {
        self.sources = sources
        self.availableSources = availableSources
        self.staticWorkloadSnapshot = staticWorkloadSnapshot
    }
}

/// Converts one authenticated, UID-pinned resolution into a bounded stream
/// launch. The helper independently enforces the same 128-source ceiling; this
/// UI-side check prevents an oversized default from being presented as active.
public enum LogOpenPlanner {
    public static let maximumSources = 128

    public static func plan(
        request: LogOpenRequest,
        resolution: LogSourceResolution
    ) throws -> ResolvedLogOpenRequest {
        guard LogResourceCompatibility.supportsSelection(request.resources),
            let sessionID = request.resources.first?.clusterSessionID,
            request.resources.allSatisfy({ $0.clusterSessionID == sessionID })
        else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "InvalidLogSourceSelection",
                message: "Select between 1 and 128 compatible resources from one cluster session.",
                operation: "open Pod logs"
            )
        }
        if case .named(let name) = request.containerSelection,
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "InvalidLogContainer",
                message: "A named log container cannot be empty.",
                operation: "open Pod logs"
            )
        }
        guard !resolution.pods.isEmpty else {
            throw ClusterManagerIssue(
                category: .notFound,
                reason: "NoWorkloadPods",
                message: "The static snapshot contains no Pods. The workload may be scaled to zero or have no current Jobs.",
                operation: "open Pod logs"
            )
        }
        guard resolution.pods.count <= maximumSources,
            resolution.pods.allSatisfy({ inventory in
                let identity = inventory.identity
                return identity.clusterSessionID == sessionID
                    && identity.group.isEmpty && identity.version == "v1"
                    && identity.resource == "pods" && !identity.namespace.isEmpty
                    && !identity.name.isEmpty && !identity.uid.rawValue.isEmpty
            })
        else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "InvalidResolvedLogSources",
                message: "The engine returned an invalid Pod log snapshot.",
                operation: "open Pod logs"
            )
        }

        let available = PodLogSourcePlanner.sources(for: resolution.pods, selection: .all)
        let selected = PodLogSourcePlanner.sources(
            for: resolution.pods,
            selection: request.containerSelection
        )
        guard !selected.isEmpty else {
            throw ClusterManagerIssue(
                category: .notFound,
                reason: "LogContainerNotFound",
                message: "The selected container is not present in the resolved Pod snapshot.",
                operation: "open Pod logs"
            )
        }
        guard selected.count <= maximumSources else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "TooManyLogSources",
                message: "The selection expands to more than 128 container log streams. Narrow the resource selection or open one container.",
                operation: "open Pod logs"
            )
        }
        return ResolvedLogOpenRequest(
            sources: selected,
            availableSources: available,
            staticWorkloadSnapshot: resolution.staticWorkloadSnapshot
        )
    }
}

/// Pure planning for the log configuration sheet. Multi-Pod selections always
/// retain an aggregate option, even when Pods do not share a container name.
/// A common named container remains available as a narrower convenience.
public enum PodLogSourcePlanner {
    public static func selections(
        for inventories: [PodLogSourceInventory]
    ) -> [PodLogContainerSelection] {
        guard !inventories.isEmpty else { return [] }
        let normalized = inventories.map { inventory in
            Array(Set(inventory.containers.filter { !$0.isEmpty })).sorted()
        }
        guard normalized.allSatisfy({ !$0.isEmpty }) else { return [] }

        let common = normalized.dropFirst().reduce(Set(normalized[0])) {
            $0.intersection($1)
        }.sorted()
        let onlyOneSourcePerPod = normalized.allSatisfy { $0.count == 1 }
        let allShareOnlyNamedChoice = common.count == 1 && onlyOneSourcePerPod
        var result: [PodLogContainerSelection] = []
        if !allShareOnlyNamedChoice { result.append(.all) }
        result.append(contentsOf: common.map(PodLogContainerSelection.named))
        return result
    }

    public static func sources(
        for inventories: [PodLogSourceInventory],
        selection: PodLogContainerSelection
    ) -> [LogSource] {
        inventories.flatMap { inventory in
            let containers: [String] = switch selection {
            case .all:
                Array(Set(inventory.containers.filter { !$0.isEmpty })).sorted()
            case .named(let name):
                inventory.containers.contains(name) ? [name] : []
            }
            return containers.map { container in
                LogSource(
                    identity: inventory.identity,
                    container: container,
                    sourceID: "\(inventory.identity.uid.rawValue)/\(container)",
                    label: "\(inventory.identity.namespace)/\(inventory.identity.name)/\(container)"
                )
            }
        }
    }
}

public enum LogSourcePresentation {
    public static let maximumToolbarSummaryCharacters = 800

    public static func titleSummary(for sources: [LogSource]) -> String {
        sources.count == 1 ? displaySafe(sources[0].label) : "\(sources.count) sources"
    }

    public static func toolbarSummary(
        contextName: String,
        sources: [LogSource]
    ) -> String {
        toolbarSummary(
            contextName: contextName,
            sources: sources,
            maximumCharacters: maximumToolbarSummaryCharacters
        )
    }

    /// The complete source list for a tooltip or accessibility value. The
    /// visible toolbar summary is intentionally bounded so source cardinality
    /// cannot become a window-size input.
    public static func fullToolbarSummary(
        contextName: String,
        sources: [LogSource]
    ) -> String {
        toolbarSummary(contextName: contextName, sources: sources, maximumCharacters: .max)
    }

    /// A single Pod can use the concise container name requested by the UI.
    /// Multi-Pod streams keep the Pod-qualified label so equal container names
    /// never become ambiguous.
    public static func prefixLabels(for sources: [LogSource]) -> [String: String] {
        let podUIDs = Set(sources.map(\.identity.uid))
        return Dictionary(
            sources.map { source in
                (source.sourceID, podUIDs.count == 1 ? source.container : source.label)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func displaySafe(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined()
    }

    private static func toolbarSummary(
        contextName: String,
        sources: [LogSource],
        maximumCharacters: Int
    ) -> String {
        let prefix = "Context: \(displaySafe(contextName)) · Sources: "
        let labels = sources.map { displaySafe($0.label) }
        guard maximumCharacters < .max else {
            return prefix + labels.joined(separator: ", ")
        }
        guard prefix.count < maximumCharacters else {
            return middleTruncated(prefix, to: maximumCharacters)
        }

        var result = prefix
        for (index, label) in labels.enumerated() {
            let separator = index == 0 ? "" : ", "
            let remainingAfter = labels.count - index - 1
            let nextMarker = remainingAfter == 0 ? "" : ", … +\(remainingAfter) more"
            if result.count + separator.count + label.count + nextMarker.count
                <= maximumCharacters
            {
                result.append(separator)
                result.append(label)
                continue
            }
            let omitted = labels.count - index
            let marker = omitted == 1 ? "…" : "… +\(omitted) more"
            let available = maximumCharacters - result.count
            let suffix = separator + marker
            result.append(suffix.count <= available
                ? suffix
                : middleTruncated(suffix, to: available))
            break
        }
        return result
    }

    private static func middleTruncated(_ value: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard value.count > limit else { return value }
        guard limit > 1 else { return "…" }
        let characters = Array(value)
        let leadingCount = (limit - 1 + 1) / 2
        let trailingCount = limit - 1 - leadingCount
        return String(characters.prefix(leadingCount))
            + "…"
            + String(characters.suffix(trailingCount))
    }
}

public struct LogOptions: Hashable, Sendable {
    public var follow: Bool
    public var previous: Bool
    public var timestamps: Bool
    public var since: Date?
    public var sinceSeconds: Int64?
    public var tailLines: Int64?
    public var byteLimit: Int64?

    public init(
        follow: Bool = true,
        previous: Bool = false,
        timestamps: Bool = false,
        since: Date? = nil,
        sinceSeconds: Int64? = nil,
        tailLines: Int64? = 500,
        byteLimit: Int64? = nil
    ) {
        self.follow = follow
        self.previous = previous
        self.timestamps = timestamps
        self.since = since
        self.sinceSeconds = sinceSeconds
        self.tailLines = tailLines
        self.byteLimit = byteLimit
    }
}

public struct LogStreamRequest: Hashable, Sendable {
    public var sessionID: String
    public var streamID: String
    public var generation: UInt64
    public var sources: [LogSource]
    public var options: LogOptions

    public init(
        sessionID: String,
        streamID: String,
        generation: UInt64,
        sources: [LogSource],
        options: LogOptions = LogOptions()
    ) {
        self.sessionID = sessionID
        self.streamID = streamID
        self.generation = generation
        self.sources = sources
        self.options = options
    }
}

public struct LogRecord: Hashable, Sendable {
    public var sourceID: String
    public var data: Data
    public var timestampUnixMilliseconds: Int64?
    public var startsLine: Bool
    public var endsWithNewline: Bool

    public init(
        sourceID: String,
        data: Data,
        timestampUnixMilliseconds: Int64? = nil,
        startsLine: Bool = true,
        endsWithNewline: Bool
    ) {
        self.sourceID = sourceID
        self.data = data
        self.timestampUnixMilliseconds = timestampUnixMilliseconds
        self.startsLine = startsLine
        self.endsWithNewline = endsWithNewline
    }
}

fileprivate struct SequencedLogRecord: Sendable {
    var sequence: UInt64
    var record: LogRecord
}

public enum LogStreamState: String, Hashable, Sendable {
    case connecting
    case streaming
    case reconnecting
    case completed
    case cancelled
    case failed
}

public struct LogStatus: Hashable, Sendable {
    public var state: LogStreamState
    public var sourceID: String
    public var droppedRecords: UInt64
    public var droppedBytes: UInt64
    public var issue: ClusterManagerIssue?

    public init(
        state: LogStreamState,
        sourceID: String = "",
        droppedRecords: UInt64 = 0,
        droppedBytes: UInt64 = 0,
        issue: ClusterManagerIssue? = nil
    ) {
        self.state = state
        self.sourceID = sourceID
        self.droppedRecords = droppedRecords
        self.droppedBytes = droppedBytes
        self.issue = issue
    }
}

public enum LogStreamMessage: Hashable, Sendable {
    case records(cursor: StreamCursor, records: [LogRecord], totalBytes: UInt64)
    case status(cursor: StreamCursor, status: LogStatus)
    case failure(cursor: StreamCursor, issue: ClusterManagerIssue)

    public var cursor: StreamCursor {
        switch self {
        case .records(let cursor, _, _), .status(let cursor, _), .failure(let cursor, _):
            cursor
        }
    }
}

public protocol LogStreamProviding: Sendable {
    func resolveLogSources(resources: [ResourceIdentity]) async throws -> LogSourceResolution
    func streamLogs(request: LogStreamRequest) -> AsyncThrowingStream<LogStreamMessage, Error>
    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async
}

public extension LogStreamProviding {
    func resolveLogSources(resources: [ResourceIdentity]) async throws -> LogSourceResolution {
        throw ClusterManagerIssue(
            category: .internalFailure,
            reason: "LogSourceResolutionUnavailable",
            message: "This log provider cannot resolve the selected resources to Pods.",
            operation: "resolve workload logs"
        )
    }
}

/// Owns the active log generation and admits messages only after their cursor
/// has passed both exact-generation and monotonic-sequence checks. Calling
/// `begin` before replacing a stream prevents a late callback from the canceled
/// stream becoming the first accepted message of the new stream.
public struct LogStreamGenerationGate: Hashable, Sendable {
    public private(set) var expectedGeneration: UInt64?
    public private(set) var sequenceGate = GenerationSequenceGate()

    public init() {}

    public mutating func begin(generation: UInt64) {
        precondition(generation > 0)
        expectedGeneration = generation
        sequenceGate = GenerationSequenceGate()
    }

    @discardableResult
    public mutating func accept(_ cursor: StreamCursor) -> StreamMessageDisposition {
        guard cursor.generation == expectedGeneration else {
            return .ignoredStaleGeneration
        }
        guard cursor.sequence > 0 else {
            return .ignoredStaleOrDuplicateSequence
        }
        return sequenceGate.accept(cursor)
    }
}

/// A byte-bounded ring which never assumes one Kubernetes log record is a
/// complete UTF-8 line. Oldest records are discarded first under pressure.
public struct LogRecordRing: Sendable {
    public private(set) var recordLimit: Int
    public private(set) var byteLimit: Int
    public private(set) var fragmentByteLimit: Int
    private var storage: [SequencedLogRecord] = []
    private var head = 0
    private var nextSequence: UInt64 = 1
    public private(set) var byteCount = 0
    public private(set) var droppedRecords: UInt64 = 0
    public private(set) var droppedBytes: UInt64 = 0

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        fragmentByteLimit: Int = 64 << 10
    ) {
        precondition(recordLimit > 0 && byteLimit > 0 && fragmentByteLimit > 0)
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        self.fragmentByteLimit = min(fragmentByteLimit, byteLimit)
    }

    public var records: [LogRecord] {
        head == storage.count ? [] : storage[head...].map(\.record)
    }

    public var recordCount: Int { storage.count - head }

    fileprivate var firstSequence: UInt64 {
        head == storage.count ? nextSequence : storage[head].sequence
    }

    fileprivate var sequencedRecords: ArraySlice<SequencedLogRecord> {
        storage[head...]
    }

    public mutating func append(contentsOf newRecords: [LogRecord]) {
        for record in newRecords {
            if record.data.isEmpty {
                appendOne(record)
                continue
            }
            var offset = 0
            while offset < record.data.count {
                let end = min(offset + fragmentByteLimit, record.data.count)
                var fragment = record
                fragment.data = record.data.subdata(in: offset..<end)
                fragment.startsLine = record.startsLine && offset == 0
                fragment.endsWithNewline = record.endsWithNewline && end == record.data.count
                appendOne(fragment)
                offset = end
            }
        }
    }

    public mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        byteCount = 0
        droppedRecords = 0
        droppedBytes = 0
    }

    /// Applies new bounds in place so stable record sequences survive a live
    /// Settings update. Only the oldest records are evicted.
    public mutating func resize(recordLimit: Int, byteLimit: Int) {
        precondition(recordLimit > 0 && byteLimit > 0)
        guard recordLimit != self.recordLimit || byteLimit != self.byteLimit else { return }
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        fragmentByteLimit = min(fragmentByteLimit, byteLimit)
        while recordCount > 0 && (recordCount > recordLimit || byteCount > byteLimit) {
            evictFirst()
        }
        compactStorageIfNeeded()
    }

    private mutating func appendOne(_ record: LogRecord) {
        let size = record.data.count
        while recordCount > 0 && (recordCount >= recordLimit || byteCount + size > byteLimit) {
            evictFirst()
        }
        storage.append(SequencedLogRecord(sequence: nextSequence, record: record))
        nextSequence &+= 1
        byteCount += size
        compactStorageIfNeeded()
    }

    private mutating func evictFirst() {
        let removed = storage[head]
        storage[head] = SequencedLogRecord(
            sequence: removed.sequence,
            record: LogRecord(sourceID: "", data: Data(), endsWithNewline: false)
        )
        head += 1
        byteCount -= removed.record.data.count
        droppedRecords &+= 1
        droppedBytes &+= UInt64(removed.record.data.count)
    }

    /// Eviction advances an index instead of repeatedly shifting every record.
    /// Periodic compaction keeps allocation bounded under sustained streams.
    private mutating func compactStorageIfNeeded() {
        guard head >= 4_096, head >= storage.count / 2 else { return }
        storage.removeFirst(head)
        head = 0
    }
}

public struct LogRecordRingStatistics: Hashable, Sendable {
    public var recordCount: Int
    public var byteCount: Int
    public var droppedRecords: UInt64
    public var droppedBytes: UInt64

    public init(
        recordCount: Int,
        byteCount: Int,
        droppedRecords: UInt64,
        droppedBytes: UInt64
    ) {
        self.recordCount = recordCount
        self.byteCount = byteCount
        self.droppedRecords = droppedRecords
        self.droppedBytes = droppedBytes
    }
}

public struct LogDisplayConfiguration: Hashable, Sendable {
    public static let `default` = Self()

    public var recordLimit: Int
    public var byteLimit: Int
    public var renderBatchMilliseconds: Int
    public var maximumRenderedUTF8Bytes: Int
    public var maximumDisplayedLineUTF8Bytes: Int

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        renderBatchMilliseconds: Int = 40,
        maximumRenderedUTF8Bytes: Int = LogDisplayPreferences
            .defaultMaximumRenderedUTF8Bytes,
        maximumDisplayedLineUTF8Bytes: Int = LogDisplayPreferences
            .defaultMaximumDisplayedLineUTF8Bytes
    ) {
        precondition(
            recordLimit > 0 && byteLimit > 0 && renderBatchMilliseconds > 0
                && maximumRenderedUTF8Bytes > 0 && maximumDisplayedLineUTF8Bytes > 0
        )
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        self.renderBatchMilliseconds = renderBatchMilliseconds
        self.maximumRenderedUTF8Bytes = maximumRenderedUTF8Bytes
        self.maximumDisplayedLineUTF8Bytes = maximumDisplayedLineUTF8Bytes
    }

    public init(preferences: LogDisplayPreferences) {
        self.init(
            recordLimit: preferences.recordLimit,
            byteLimit: preferences.byteLimit,
            renderBatchMilliseconds: preferences.renderBatchMilliseconds,
            maximumRenderedUTF8Bytes: preferences.maximumRenderedUTF8Bytes,
            maximumDisplayedLineUTF8Bytes: preferences.maximumDisplayedLineUTF8Bytes
        )
    }
}

public struct LogRecordRingSnapshot: Sendable {
    public var records: [LogRecord]
    public var statistics: LogRecordRingStatistics

    public init(records: [LogRecord], statistics: LogRecordRingStatistics) {
        self.records = records
        self.statistics = statistics
    }
}

/// Immutable display inputs for one log window. A change intentionally starts
/// a new display revision; sustained rendering otherwise consumes only records
/// appended since the previous pass.
public struct LogDisplayRenderConfiguration: Equatable, Sendable {
    public var sourceLabels: [String: String]
    public var showSourceLabels: Bool
    public var filter: String
    public var maximumOutputUTF8Bytes: Int
    public var maximumDisplayedLineUTF8Bytes: Int

    public init(
        sourceLabels: [String: String],
        showSourceLabels: Bool,
        filter: String,
        maximumOutputUTF8Bytes: Int,
        maximumDisplayedLineUTF8Bytes: Int
    ) {
        precondition(maximumOutputUTF8Bytes > 0 && maximumDisplayedLineUTF8Bytes > 0)
        self.sourceLabels = sourceLabels
        self.showSourceLabels = showSourceLabels
        self.filter = filter
        self.maximumOutputUTF8Bytes = maximumOutputUTF8Bytes
        self.maximumDisplayedLineUTF8Bytes = maximumDisplayedLineUTF8Bytes
    }
}

public struct LogDisplayCursor: Hashable, Sendable {
    public var revision: UInt64
    public var firstSequence: UInt64?
    public var lastSequence: UInt64?

    public init(
        revision: UInt64,
        firstSequence: UInt64?,
        lastSequence: UInt64?
    ) {
        self.revision = revision
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
    }
}

/// One independently evictable screen fragment. Adjacent fragments retain
/// their display-line state, so an oversized logical line is still truncated
/// and indexed as one line.
public struct LogDisplayItem: Hashable, Sendable {
    public var sequence: UInt64
    public var text: String
    /// Shared immutable bytes used only when the user explicitly saves the
    /// currently installed display snapshot.
    public var record: LogRecord

    public init(sequence: UInt64, text: String, record: LogRecord) {
        self.sequence = sequence
        self.text = text
        self.record = record
    }
}

public struct LogDisplayUpdate: Sendable {
    /// A replacement occurs for the first render, a display-configuration
    /// change, or when deferred rendering falls behind the bounded raw ring.
    public var replacesAll: Bool
    /// Current first displayed sequence. An incremental consumer removes its
    /// installed prefix up to this sequence before appending `items`.
    public var firstSequence: UInt64?
    /// All items for a replacement, otherwise only the appended suffix.
    public var items: [LogDisplayItem]
    public var cursor: LogDisplayCursor
    public var renderedRecords: Int
    public var omittedRecords: Int
    public var omittedSourceBytes: UInt64
    public var outputUTF8Bytes: Int
    public var displayOutputUTF8Bytes: Int
    public var displayTruncatedLines: Int
    /// Records decoded or filter-tested by this pass. This is an enduring
    /// diagnostic contract for sustained-stream regression tests.
    public var processedRecordCount: Int
}

/// Serializes ring mutations away from AppKit's main actor. The actor never
/// performs AppKit work. Its display cache decodes only the newly appended
/// suffix during normal tailing and remains bounded by the raw and rendered
/// limits.
public actor LogRecordStore {
    private var ring: LogRecordRing
    private var latestConfigurationRevision: UInt64 = 0
    private var contentRevision: UInt64 = 1
    private var nextDisplayRevision: UInt64 = 1
    private var displayCache: LogDisplayCache?

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        fragmentByteLimit: Int = 64 << 10
    ) {
        ring = LogRecordRing(
            recordLimit: recordLimit,
            byteLimit: byteLimit,
            fragmentByteLimit: fragmentByteLimit
        )
    }

    @discardableResult
    public func append(contentsOf records: [LogRecord]) -> LogRecordRingStatistics {
        ring.append(contentsOf: records)
        return statistics(for: ring)
    }

    @discardableResult
    public func clear() -> LogRecordRingStatistics {
        ring.clear()
        contentRevision &+= 1
        displayCache = nil
        return statistics(for: ring)
    }

    public func statistics() -> LogRecordRingStatistics {
        statistics(for: ring)
    }

    @discardableResult
    public func resize(recordLimit: Int, byteLimit: Int) -> LogRecordRingStatistics {
        ring.resize(recordLimit: recordLimit, byteLimit: byteLimit)
        return statistics(for: ring)
    }

    /// Revisioned variant used by live Settings propagation. Once a newer
    /// configuration has reached the actor, a delayed older request cannot
    /// overwrite it.
    @discardableResult
    public func resize(
        recordLimit: Int,
        byteLimit: Int,
        revision: UInt64
    ) -> LogRecordRingStatistics {
        guard revision > latestConfigurationRevision else { return statistics(for: ring) }
        latestConfigurationRevision = revision
        ring.resize(recordLimit: recordLimit, byteLimit: byteLimit)
        return statistics(for: ring)
    }

    public func snapshot() -> LogRecordRingSnapshot {
        LogRecordRingSnapshot(records: ring.records, statistics: statistics(for: ring))
    }

    public func renderDisplay(
        configuration: LogDisplayRenderConfiguration,
        after cursor: LogDisplayCursor?
    ) throws -> LogDisplayUpdate {
        if displayCache?.configuration != configuration
            || displayCache?.contentRevision != contentRevision
        {
            displayCache = LogDisplayCache(
                configuration: configuration,
                contentRevision: contentRevision,
                revision: nextDisplayRevision
            )
            nextDisplayRevision &+= 1
        }
        guard let cache = displayCache else { preconditionFailure("display cache") }
        let processed = try cache.synchronize(with: ring)
        return cache.makeUpdate(after: cursor, processedRecordCount: processed)
    }

    private func statistics(for ring: LogRecordRing) -> LogRecordRingStatistics {
        LogRecordRingStatistics(
            recordCount: ring.recordCount,
            byteCount: ring.byteCount,
            droppedRecords: ring.droppedRecords,
            droppedBytes: ring.droppedBytes
        )
    }
}

public struct RenderedLogText: Hashable, Sendable {
    /// Logical chunks preserve visible records exactly for lossless Save.
    public var chunks: [String]
    /// Display chunks cap each logical line while retaining stable chunk
    /// boundaries for incremental viewport indexing and drawing.
    public var displayChunks: [String]
    public var renderedRecords: Int
    public var omittedRecords: Int
    public var omittedSourceBytes: UInt64
    public var outputUTF8Bytes: Int
    public var displayOutputUTF8Bytes: Int
    public var displayTruncatedLines: Int

    public init(
        chunks: [String],
        displayChunks: [String],
        renderedRecords: Int,
        omittedRecords: Int,
        omittedSourceBytes: UInt64,
        outputUTF8Bytes: Int,
        displayOutputUTF8Bytes: Int,
        displayTruncatedLines: Int
    ) {
        self.chunks = chunks
        self.displayChunks = displayChunks
        self.renderedRecords = renderedRecords
        self.omittedRecords = omittedRecords
        self.omittedSourceBytes = omittedSourceBytes
        self.outputUTF8Bytes = outputUTF8Bytes
        self.displayOutputUTF8Bytes = displayOutputUTF8Bytes
        self.displayTruncatedLines = displayTruncatedLines
    }

    public var text: String { chunks.joined() }
    public var displayText: String { displayChunks.joined() }
}

/// A minimal streaming edit from one rendered log snapshot to the next. Log
/// rings evolve by dropping an old prefix and appending a new suffix, so the
/// virtual viewport can retain indexed chunks. A filter change simply
/// degenerates to a bounded replace.
public struct LogTextInstallPlan: Hashable, Sendable {
    public var removePrefixUTF16Length: Int
    public var resultUTF16Length: Int
    /// Number of unchanged chunks at the end of the previous projection and
    /// the beginning of the replacement. View renderers reuse their retained
    /// line indexes instead of rescanning unchanged text.
    public var retainedChunkCount: Int
    public var appendedChunkCount: Int
    public var appendedUTF8Length: Int

    public init(
        removePrefixUTF16Length: Int,
        resultUTF16Length: Int,
        retainedChunkCount: Int,
        appendedChunkCount: Int,
        appendedUTF8Length: Int
    ) {
        self.removePrefixUTF16Length = removePrefixUTF16Length
        self.resultUTF16Length = resultUTF16Length
        self.retainedChunkCount = retainedChunkCount
        self.appendedChunkCount = appendedChunkCount
        self.appendedUTF8Length = appendedUTF8Length
    }

    public func remapSelection(_ selection: NSRange) -> NSRange {
        let oldEnd = selection.location.addingReportingOverflow(selection.length)
        let safeOldEnd = oldEnd.overflow ? Int.max : oldEnd.partialValue
        let location = max(0, selection.location - removePrefixUTF16Length)
        let end = max(0, safeOldEnd - removePrefixUTF16Length)
        let clampedLocation = min(location, resultUTF16Length)
        let clampedEnd = min(max(clampedLocation, end), resultUTF16Length)
        return NSRange(location: clampedLocation, length: clampedEnd - clampedLocation)
    }
}

public enum LogTextInstallPlanner {
    public static func plan(
        previousChunks: [String],
        currentChunks: [String]
    ) -> LogTextInstallPlan {
        let overlap = suffixPrefixOverlap(previousChunks, currentChunks)
        let removed = previousChunks.dropLast(overlap).reduce(into: 0) {
            $0 += $1.utf16.count
        }
        let retained = previousChunks.suffix(overlap).reduce(into: 0) {
            $0 += $1.utf16.count
        }
        var appendedUTF16Length = 0
        var appendedUTF8Length = 0
        for chunk in currentChunks.dropFirst(overlap) {
            appendedUTF16Length += chunk.utf16.count
            appendedUTF8Length += chunk.utf8.count
        }
        return LogTextInstallPlan(
            removePrefixUTF16Length: removed,
            resultUTF16Length: retained + appendedUTF16Length,
            retainedChunkCount: overlap,
            appendedChunkCount: currentChunks.count - overlap,
            appendedUTF8Length: appendedUTF8Length
        )
    }

    /// KMP finds the longest suffix(previous) == prefix(current) in linear
    /// chunk comparisons, avoiding an O(n²) scan for large retained buffers.
    private static func suffixPrefixOverlap(
        _ previous: [String],
        _ current: [String]
    ) -> Int {
        guard !previous.isEmpty, !current.isEmpty else { return 0 }
        enum Token: Equatable {
            case chunk(String)
            case separator
        }
        let sequence = current.map(Token.chunk) + [.separator] + previous.map(Token.chunk)
        var prefix = Array(repeating: 0, count: sequence.count)
        for index in 1..<sequence.count {
            var candidate = prefix[index - 1]
            while candidate > 0, sequence[index] != sequence[candidate] {
                candidate = prefix[candidate - 1]
            }
            if sequence[index] == sequence[candidate] { candidate += 1 }
            prefix[index] = candidate
        }
        return min(prefix.last ?? 0, previous.count, current.count)
    }
}

/// Pure, cancellation-aware renderer used from a detached task. It retains the
/// newest matching records when source labels or UTF-8 replacement expansion
/// would exceed the configured visible-text budget.
public enum LogTextRenderer {
    public static let defaultMaximumDisplayedLineUTF8Bytes = LogDisplayPreferences
        .defaultMaximumDisplayedLineUTF8Bytes
    public static let displayTruncationMarker =
        "… [line truncated; Save preserves full line]"
    public static let retainedBufferDisplayTruncationMarker =
        "… [line truncated for display; additional text retained in memory]"

    private struct Candidate {
        var record: LogRecord
        var decoded: String
        var recordIndex: Int
        var sourcePrefix: String
        var timestampPrefix: String
        var decodedUTF8Bytes: Int
    }

    public static func render(
        records: [LogRecord],
        sourceLabels: [String: String],
        showSourceLabels: Bool,
        filter: String,
        maximumOutputUTF8Bytes: Int,
        maximumDisplayedLineUTF8Bytes: Int = defaultMaximumDisplayedLineUTF8Bytes,
        displayTruncationMarker: String = LogTextRenderer.displayTruncationMarker
    ) throws -> RenderedLogText {
        precondition(
            maximumOutputUTF8Bytes > 0 && maximumDisplayedLineUTF8Bytes > 0
                && !displayTruncationMarker.isEmpty
        )
        let foldedFilter = filter.lowercased()
        var candidates: [Candidate] = []
        candidates.reserveCapacity(min(records.count, 4_096))
        var estimatedOutputBytes = 0
        var omittedRecords = 0
        var omittedBytes: UInt64 = 0
        let timestampFormatter: ISO8601DateFormatter? = records.contains {
            $0.timestampUnixMilliseconds != nil
        } ? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter
        }() : nil
        var cachedSourcePrefixes: [String: String] = [:]

        for (offset, index) in records.indices.reversed().enumerated() {
            if offset & 63 == 0 { try Task.checkCancellation() }
            let record = records[index]
            let decoded = String(decoding: record.data, as: UTF8.self)
            let decodedUTF8Bytes = decoded.utf8.count
            if !foldedFilter.isEmpty && !decoded.lowercased().contains(foldedFilter) {
                continue
            }
            let sourcePrefix: String
            if showSourceLabels {
                if let cached = cachedSourcePrefixes[record.sourceID] {
                    sourcePrefix = cached
                } else {
                    let label = sourceLabels[record.sourceID] ?? record.sourceID
                    let value = "[\(displaySafeLabel(label))] "
                    cachedSourcePrefixes[record.sourceID] = value
                    sourcePrefix = value
                }
            } else {
                sourcePrefix = ""
            }
            let timestampPrefix: String
            if let milliseconds = record.timestampUnixMilliseconds,
                let timestampFormatter
            {
                timestampPrefix = timestampFormatter.string(
                    from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                ) + " "
            } else {
                timestampPrefix = ""
            }
            // A continuation may become the first logical fragment after
            // filtering, ring eviction, or byte-budget omission. Reserve its
            // restored source/timestamp context, truncation ellipsis, possible
            // segment separator, and own newline conservatively.
            let estimate = sourcePrefix.utf8.count + timestampPrefix.utf8.count
                + (record.startsLine ? 0 : "… ".utf8.count)
                + decodedUTF8Bytes
                // Reserve both a visual separator before a disjoint segment
                // and the record's own newline. Most records use only one;
                // the conservative bound keeps interleaving byte-safe.
                + 1 + (record.endsWithNewline ? 1 : 0)
            if estimate > maximumOutputUTF8Bytes - estimatedOutputBytes {
                omittedRecords += 1
                omittedBytes &+= UInt64(record.data.count)
                continue
            }
            candidates.append(Candidate(
                record: record,
                decoded: decoded,
                recordIndex: index,
                sourcePrefix: sourcePrefix,
                timestampPrefix: timestampPrefix,
                decodedUTF8Bytes: decodedUTF8Bytes
            ))
            estimatedOutputBytes += estimate
        }
        try Task.checkCancellation()
        var chunks: [String] = []
        chunks.reserveCapacity(candidates.count * 3)
        var outputBytes = 0
        var previousVisibleSourceID: String?
        var previousVisibleIndex = -1
        var previousVisibleLineOpen = false
        for (offset, candidate) in candidates.reversed().enumerated() {
            if offset & 63 == 0 { try Task.checkCancellation() }
            let record = candidate.record
            let continuesPreviousVisibleFragment = !record.startsLine
                && previousVisibleLineOpen
                && previousVisibleSourceID == record.sourceID
                && previousVisibleIndex == candidate.recordIndex - 1
            let truncatedStart = !record.startsLine && !continuesPreviousVisibleFragment
            let beginsVisibleSegment = record.startsLine || truncatedStart
            let separator = previousVisibleLineOpen && !continuesPreviousVisibleFragment
                ? "\n" : ""
            let prefix = beginsVisibleSegment ? candidate.sourcePrefix : ""
            let timestamp = beginsVisibleSegment ? candidate.timestampPrefix : ""
            let truncation = truncatedStart ? "… " : ""
            let logicalPrefix = separator + prefix + timestamp + truncation
            if !logicalPrefix.isEmpty { chunks.append(logicalPrefix) }
            chunks.append(candidate.decoded)
            if record.endsWithNewline { chunks.append("\n") }
            outputBytes += logicalPrefix.utf8.count + candidate.decoded.utf8.count
                + (record.endsWithNewline ? 1 : 0)

            previousVisibleSourceID = record.sourceID
            previousVisibleIndex = candidate.recordIndex
            previousVisibleLineOpen = !record.endsWithNewline
        }
        let display = try makeDisplayProjection(
            chunks: chunks,
            maximumLineUTF8Bytes: maximumDisplayedLineUTF8Bytes,
            truncationMarker: displayTruncationMarker
        )
        return RenderedLogText(
            chunks: chunks,
            displayChunks: display.chunks,
            renderedRecords: candidates.count,
            omittedRecords: omittedRecords,
            omittedSourceBytes: omittedBytes,
            outputUTF8Bytes: outputBytes,
            displayOutputUTF8Bytes: display.outputUTF8Bytes,
            displayTruncatedLines: display.truncatedLines
        )
    }

    /// Reconstructs the exact logical text for an already selected display
    /// snapshot. Stable sequences preserve gaps introduced by filtering,
    /// retention, or the rendered-byte budget without doing this work during
    /// normal streaming.
    public static func exportText(
        items: [LogDisplayItem],
        sourceLabels: [String: String],
        showSourceLabels: Bool
    ) throws -> String {
        var chunks: [String] = []
        chunks.reserveCapacity(items.count * 3)
        var cachedSourcePrefixes: [String: String] = [:]
        let timestampFormatter: ISO8601DateFormatter? = items.contains {
            $0.record.timestampUnixMilliseconds != nil
        } ? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter
        }() : nil
        var previousSourceID: String?
        var previousSequence: UInt64?
        var previousLineOpen = false

        for (offset, item) in items.enumerated() {
            if offset & 63 == 0 { try Task.checkCancellation() }
            let record = item.record
            let continuesPreviousFragment = !record.startsLine
                && previousLineOpen
                && previousSourceID == record.sourceID
                && previousSequence.map { $0 &+ 1 == item.sequence } == true
            let truncatedStart = !record.startsLine && !continuesPreviousFragment
            let beginsSegment = record.startsLine || truncatedStart
            if previousLineOpen && !continuesPreviousFragment { chunks.append("\n") }
            if beginsSegment, showSourceLabels {
                if let cached = cachedSourcePrefixes[record.sourceID] {
                    chunks.append(cached)
                } else {
                    let label = sourceLabels[record.sourceID] ?? record.sourceID
                    let prefix = "[\(displaySafeLabel(label))] "
                    cachedSourcePrefixes[record.sourceID] = prefix
                    chunks.append(prefix)
                }
            }
            if beginsSegment,
                let milliseconds = record.timestampUnixMilliseconds,
                let timestampFormatter
            {
                chunks.append(timestampFormatter.string(
                    from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
                ) + " ")
            }
            if truncatedStart { chunks.append("… ") }
            chunks.append(String(decoding: record.data, as: UTF8.self))
            if record.endsWithNewline { chunks.append("\n") }

            previousSourceID = record.sourceID
            previousSequence = item.sequence
            previousLineOpen = !record.endsWithNewline
        }
        try Task.checkCancellation()
        return chunks.joined()
    }

    fileprivate struct DisplayProjection {
        var chunks: [String]
        var outputUTF8Bytes: Int
        var truncatedLines: Int
    }

    fileprivate struct DisplayProjectionState: Equatable {
        var displayedLineUTF8Bytes = 0
        var lineIsTruncated = false
    }

    /// Produces a bounded screen projection without joining or reshaping a
    /// pathological logical line. Newline controls remain exact so Save can
    /// use the untouched logical chunks and the viewport can retain stable
    /// display chunks between streaming updates.
    fileprivate static func makeDisplayProjection(
        chunks: [String],
        maximumLineUTF8Bytes: Int,
        truncationMarker: String
    ) throws -> DisplayProjection {
        var state = DisplayProjectionState()
        return try appendDisplayProjection(
            chunks: chunks,
            state: &state,
            maximumLineUTF8Bytes: maximumLineUTF8Bytes,
            truncationMarker: truncationMarker
        )
    }

    fileprivate static func appendDisplayProjection(
        chunks: [String],
        state: inout DisplayProjectionState,
        maximumLineUTF8Bytes: Int,
        truncationMarker: String
    ) throws -> DisplayProjection {
        var result: [String] = []
        result.reserveCapacity(chunks.count)
        var outputUTF8Bytes = 0
        var truncatedLines = 0
        let newlineCharacters = CharacterSet.newlines

        func append(_ value: String) {
            guard !value.isEmpty else { return }
            result.append(value)
            outputUTF8Bytes += value.utf8.count
        }

        for (chunkIndex, chunk) in chunks.enumerated() {
            if chunkIndex & 63 == 0 { try Task.checkCancellation() }
            let value = chunk as NSString
            var cursor = 0
            while cursor < value.length {
                let newline = value.rangeOfCharacter(
                    from: newlineCharacters,
                    options: [],
                    range: NSRange(location: cursor, length: value.length - cursor)
                )
                let segmentEnd = newline.location == NSNotFound
                    ? value.length
                    : newline.location
                if segmentEnd > cursor, !state.lineIsTruncated {
                    let segment = cursor == 0 && segmentEnd == value.length
                        ? chunk
                        : value.substring(with: NSRange(
                            location: cursor,
                            length: segmentEnd - cursor
                        ))
                    let segmentUTF8Bytes = segment.utf8.count
                    let remaining = max(
                        0,
                        maximumLineUTF8Bytes - state.displayedLineUTF8Bytes
                    )
                    if segmentUTF8Bytes <= remaining {
                        append(segment)
                        state.displayedLineUTF8Bytes += segmentUTF8Bytes
                    } else {
                        let prefix = utf8Prefix(segment, maximumBytes: remaining)
                        append(prefix)
                        state.displayedLineUTF8Bytes += prefix.utf8.count
                        if state.displayedLineUTF8Bytes > 0 { append(" ") }
                        append(truncationMarker)
                        state.lineIsTruncated = true
                        truncatedLines += 1
                    }
                }

                guard newline.location != NSNotFound else { break }
                append(value.substring(with: newline))
                state.displayedLineUTF8Bytes = 0
                state.lineIsTruncated = false
                cursor = NSMaxRange(newline)
            }
        }
        return DisplayProjection(
            chunks: result,
            outputUTF8Bytes: outputUTF8Bytes,
            truncatedLines: truncatedLines
        )
    }

    fileprivate static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        let utf8 = value.utf8
        guard utf8.count > maximumBytes else { return value }
        var end = utf8.index(utf8.startIndex, offsetBy: maximumBytes)
        while end > utf8.startIndex, String.Index(end, within: value) == nil {
            end = utf8.index(before: end)
        }
        guard let stringEnd = String.Index(end, within: value) else { return "" }
        return String(value[..<stringEnd])
    }

    fileprivate static func displaySafeLabel(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined().prefix(512))
    }
}

/// Actor-confined incremental screen projection. Candidate records advance in
/// one direction, so normal updates consist only of a prefix eviction and a
/// formatted suffix append. Arrays use advancing heads to avoid shifting the
/// retained history on every batch.
private final class LogDisplayCache {
    private struct ProcessedRecord {
        var sequence: UInt64
        var matched: Bool
        var sourceBytes: Int
    }

    private struct Candidate {
        var sequence: UInt64
        var item: LogDisplayItem
        var estimatedOutputUTF8Bytes: Int
        var logicalOutputUTF8Bytes: Int
        var displayOutputUTF8Bytes: Int
        var displayTruncatedLines: Int
        var displayState: LogTextRenderer.DisplayProjectionState
        var dependsOnPrevious: Bool
    }

    let configuration: LogDisplayRenderConfiguration
    let contentRevision: UInt64
    private(set) var revision: UInt64
    private let foldedFilter: String
    private var processedRecords: [ProcessedRecord] = []
    private var processedHead = 0
    private var candidates: [Candidate] = []
    private var candidateHead = 0
    private var candidatePrefixNeedsRepair = false
    private var lastProcessedSequence: UInt64?
    private var matchingRecordCount = 0
    private var matchingSourceBytes: UInt64 = 0
    private var candidateSourceBytes: UInt64 = 0
    private var candidateEstimatedOutputUTF8Bytes = 0
    private var candidateLogicalOutputUTF8Bytes = 0
    private var candidateDisplayOutputUTF8Bytes = 0
    private var candidateDisplayTruncatedLines = 0
    private var sourcePrefixes: [String: String] = [:]
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(
        configuration: LogDisplayRenderConfiguration,
        contentRevision: UInt64,
        revision: UInt64
    ) {
        self.configuration = configuration
        self.contentRevision = contentRevision
        self.revision = revision << 32
        foldedFilter = configuration.filter.lowercased()
    }

    func synchronize(with ring: LogRecordRing) throws -> Int {
        if let lastProcessedSequence,
            lastProcessedSequence &+ 1 < ring.firstSequence
        {
            resetContents()
        }

        discardRecords(olderThan: ring.firstSequence)
        var processedCount = 0
        let after = lastProcessedSequence ?? 0
        for entry in ring.sequencedRecords where entry.sequence > after {
            if processedCount & 63 == 0 { try Task.checkCancellation() }
            try append(entry)
            lastProcessedSequence = entry.sequence
            processedCount += 1
        }
        if candidatePrefixNeedsRepair {
            if candidateHead < candidates.count,
                candidates[candidateHead].dependsOnPrevious
            {
                try repairCandidatePrefix()
            }
            candidatePrefixNeedsRepair = false
        }
        compactIfNeeded()
        return processedCount
    }

    func makeUpdate(
        after cursor: LogDisplayCursor?,
        processedRecordCount: Int
    ) -> LogDisplayUpdate {
        let activeCount = candidates.count - candidateHead
        let firstSequence = activeCount == 0 ? nil : candidates[candidateHead].sequence
        let lastSequence = activeCount == 0 ? nil : candidates[candidates.count - 1].sequence
        let currentCursor = LogDisplayCursor(
            revision: revision,
            firstSequence: firstSequence,
            lastSequence: lastSequence
        )

        let replacesAll: Bool
        let items: [LogDisplayItem]
        if cursor?.revision != revision {
            replacesAll = true
            items = candidates[candidateHead...].map(\.item)
        } else if activeCount == 0 {
            replacesAll = false
            items = []
        } else if let installedLast = cursor?.lastSequence,
            let overlapIndex = candidateIndex(for: installedLast)
        {
            replacesAll = false
            let suffixStart = overlapIndex + 1
            items = suffixStart < candidates.count
                ? candidates[suffixStart...].map(\.item)
                : []
        } else {
            replacesAll = true
            items = candidates[candidateHead...].map(\.item)
        }

        return LogDisplayUpdate(
            replacesAll: replacesAll,
            firstSequence: firstSequence,
            items: items,
            cursor: currentCursor,
            renderedRecords: activeCount,
            omittedRecords: max(0, matchingRecordCount - activeCount),
            omittedSourceBytes: matchingSourceBytes >= candidateSourceBytes
                ? matchingSourceBytes - candidateSourceBytes : 0,
            outputUTF8Bytes: candidateLogicalOutputUTF8Bytes,
            displayOutputUTF8Bytes: candidateDisplayOutputUTF8Bytes,
            displayTruncatedLines: candidateDisplayTruncatedLines,
            processedRecordCount: processedRecordCount
        )
    }

    private func append(_ entry: SequencedLogRecord) throws {
        let record = entry.record
        let decoded = String(decoding: record.data, as: UTF8.self)
        let matches = foldedFilter.isEmpty
            || decoded.lowercased().contains(foldedFilter)
        guard matches else {
            processedRecords.append(ProcessedRecord(
                sequence: entry.sequence,
                matched: false,
                sourceBytes: record.data.count
            ))
            return
        }

        let sourcePrefix = sourcePrefix(for: record.sourceID)
        let timestampPrefix = timestampPrefix(for: record)
        let continuationPrefix = record.startsLine ? "" : "… "
        let logical = sourcePrefix + timestampPrefix + continuationPrefix + decoded
        // Preserve the renderer's conservative budget while allowing the
        // actual display formatter below to join contiguous line fragments.
        let estimate = logical.utf8.count + 1
            + (record.endsWithNewline ? 1 : 0)
        if estimate > configuration.maximumOutputUTF8Bytes {
            processedRecords.append(ProcessedRecord(
                sequence: entry.sequence,
                matched: true,
                sourceBytes: record.data.count
            ))
            matchingRecordCount += 1
            matchingSourceBytes &+= UInt64(record.data.count)
            return
        }

        let candidate = try makeCandidate(
            sequence: entry.sequence,
            record: record,
            decoded: decoded,
            estimate: estimate,
            previous: candidateHead < candidates.count ? candidates.last : nil
        )
        processedRecords.append(ProcessedRecord(
            sequence: entry.sequence,
            matched: true,
            sourceBytes: record.data.count
        ))
        matchingRecordCount += 1
        matchingSourceBytes &+= UInt64(record.data.count)
        candidates.append(candidate)
        candidateSourceBytes &+= UInt64(record.data.count)
        candidateEstimatedOutputUTF8Bytes += estimate
        candidateLogicalOutputUTF8Bytes += candidate.logicalOutputUTF8Bytes
        candidateDisplayOutputUTF8Bytes += candidate.displayOutputUTF8Bytes
        candidateDisplayTruncatedLines += candidate.displayTruncatedLines

        while candidateHead < candidates.count,
            candidateEstimatedOutputUTF8Bytes > configuration.maximumOutputUTF8Bytes
        {
            discardFirstCandidate()
        }
    }

    private func makeCandidate(
        sequence: UInt64,
        record: LogRecord,
        decoded: String,
        estimate: Int,
        previous: Candidate?
    ) throws -> Candidate {
        let previousRecord = previous?.item.record
        let previousLineOpen = previousRecord.map { !$0.endsWithNewline } ?? false
        let continuesPreviousVisibleFragment = !record.startsLine
            && previousLineOpen
            && previousRecord?.sourceID == record.sourceID
            && previous?.sequence == sequence - 1
        let truncatedStart = !record.startsLine && !continuesPreviousVisibleFragment
        let beginsVisibleSegment = record.startsLine || truncatedStart
        let separator = previousLineOpen && !continuesPreviousVisibleFragment
            ? "\n" : ""
        let prefix = beginsVisibleSegment ? sourcePrefix(for: record.sourceID) : ""
        let timestamp = beginsVisibleSegment ? timestampPrefix(for: record) : ""
        let truncation = truncatedStart ? "… " : ""
        let logicalPrefix = separator + prefix + timestamp + truncation
        var chunks: [String] = []
        if !logicalPrefix.isEmpty { chunks.append(logicalPrefix) }
        chunks.append(decoded)
        if record.endsWithNewline { chunks.append("\n") }

        var displayState = previous?.displayState
            ?? LogTextRenderer.DisplayProjectionState()
        let display = try LogTextRenderer.appendDisplayProjection(
            chunks: chunks,
            state: &displayState,
            maximumLineUTF8Bytes: configuration.maximumDisplayedLineUTF8Bytes,
            truncationMarker: LogTextRenderer.displayTruncationMarker
        )
        return Candidate(
            sequence: sequence,
            item: LogDisplayItem(
                sequence: sequence,
                text: display.chunks.joined(),
                record: record
            ),
            estimatedOutputUTF8Bytes: estimate,
            logicalOutputUTF8Bytes: chunks.reduce(into: 0) {
                $0 += $1.utf8.count
            },
            displayOutputUTF8Bytes: display.outputUTF8Bytes,
            displayTruncatedLines: display.truncatedLines,
            displayState: displayState,
            dependsOnPrevious: previousLineOpen
        )
    }

    /// Prefix eviction can expose a fragment whose old screen chunk depended
    /// on an evicted open line. Reformat only through that logical line; the
    /// first newline resets every downstream display dependency.
    private func repairCandidatePrefix() throws {
        var previous: Candidate?
        var changed = false
        var index = candidateHead
        while index < candidates.count {
            let old = candidates[index]
            let rebuilt = try makeCandidate(
                sequence: old.sequence,
                record: old.item.record,
                decoded: String(decoding: old.item.record.data, as: UTF8.self),
                estimate: old.estimatedOutputUTF8Bytes,
                previous: previous
            )
            candidateLogicalOutputUTF8Bytes += rebuilt.logicalOutputUTF8Bytes
                - old.logicalOutputUTF8Bytes
            candidateDisplayOutputUTF8Bytes += rebuilt.displayOutputUTF8Bytes
                - old.displayOutputUTF8Bytes
            candidateDisplayTruncatedLines += rebuilt.displayTruncatedLines
                - old.displayTruncatedLines
            if rebuilt.item.text != old.item.text
                || rebuilt.displayState != old.displayState
                || rebuilt.logicalOutputUTF8Bytes != old.logicalOutputUTF8Bytes
            {
                changed = true
            }
            candidates[index] = rebuilt
            previous = rebuilt
            index += 1
            if rebuilt.item.record.endsWithNewline { break }
        }
        if changed { revision &+= 1 }
    }

    private func sourcePrefix(for sourceID: String) -> String {
        guard configuration.showSourceLabels else { return "" }
        if let cached = sourcePrefixes[sourceID] { return cached }
        let label = configuration.sourceLabels[sourceID] ?? sourceID
        let prefix = "[\(LogTextRenderer.displaySafeLabel(label))] "
        sourcePrefixes[sourceID] = prefix
        return prefix
    }

    private func timestampPrefix(for record: LogRecord) -> String {
        guard let milliseconds = record.timestampUnixMilliseconds else { return "" }
        return timestampFormatter.string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        ) + " "
    }

    private func discardRecords(olderThan firstSequence: UInt64) {
        while processedHead < processedRecords.count,
            processedRecords[processedHead].sequence < firstSequence
        {
            let removed = processedRecords[processedHead]
            processedHead += 1
            if removed.matched {
                matchingRecordCount -= 1
                matchingSourceBytes -= UInt64(removed.sourceBytes)
            }
        }
        while candidateHead < candidates.count,
            candidates[candidateHead].sequence < firstSequence
        {
            discardFirstCandidate()
        }
    }

    private func discardFirstCandidate() {
        let removed = candidates[candidateHead]
        candidateHead += 1
        candidateSourceBytes -= UInt64(removed.item.record.data.count)
        candidateEstimatedOutputUTF8Bytes -= removed.estimatedOutputUTF8Bytes
        candidateLogicalOutputUTF8Bytes -= removed.logicalOutputUTF8Bytes
        candidateDisplayOutputUTF8Bytes -= removed.displayOutputUTF8Bytes
        candidateDisplayTruncatedLines -= removed.displayTruncatedLines
        candidatePrefixNeedsRepair = true
    }

    private func candidateIndex(for sequence: UInt64) -> Int? {
        var low = candidateHead
        var high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if candidates[middle].sequence < sequence {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < candidates.count && candidates[low].sequence == sequence
            ? low : nil
    }

    private func resetContents() {
        processedRecords.removeAll(keepingCapacity: true)
        processedHead = 0
        candidates.removeAll(keepingCapacity: true)
        candidateHead = 0
        candidatePrefixNeedsRepair = false
        lastProcessedSequence = nil
        matchingRecordCount = 0
        matchingSourceBytes = 0
        candidateSourceBytes = 0
        candidateEstimatedOutputUTF8Bytes = 0
        candidateLogicalOutputUTF8Bytes = 0
        candidateDisplayOutputUTF8Bytes = 0
        candidateDisplayTruncatedLines = 0
    }

    private func compactIfNeeded() {
        if processedHead >= 4_096, processedHead >= processedRecords.count / 2 {
            processedRecords.removeFirst(processedHead)
            processedHead = 0
        }
        if candidateHead >= 4_096, candidateHead >= candidates.count / 2 {
            candidates.removeFirst(candidateHead)
            candidateHead = 0
        }
    }
}
