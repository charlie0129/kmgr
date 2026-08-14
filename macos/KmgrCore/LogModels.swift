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

    public init(
        resources: [ResourceIdentity],
        containerSelection: PodLogContainerSelection = .all
    ) {
        self.resources = resources
        self.containerSelection = containerSelection
    }

    public static func allContainers(
        for resources: [ResourceIdentity]
    ) -> Self {
        Self(resources: resources, containerSelection: .all)
    }

    public static func namedContainer(
        _ name: String,
        in pod: ResourceIdentity
    ) -> Self {
        Self(resources: [pod], containerSelection: .named(name))
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
    public static func titleSummary(for sources: [LogSource]) -> String {
        sources.count == 1 ? displaySafe(sources[0].label) : "\(sources.count) sources"
    }

    public static func toolbarSummary(
        contextName: String,
        sources: [LogSource]
    ) -> String {
        let labels = sources.map { displaySafe($0.label) }.joined(separator: ", ")
        return "Context: \(displaySafe(contextName)) · Sources: \(labels)"
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
    public let recordLimit: Int
    public let byteLimit: Int
    public let fragmentByteLimit: Int
    private var storage: [LogRecord] = []
    private var head = 0
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
        head == storage.count ? [] : Array(storage[head...])
    }

    public var recordCount: Int { storage.count - head }

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
    }

    /// Rebuilds the ring under new bounds so an already-open log view can
    /// adopt saved preferences. Appending oldest-to-newest retains the newest
    /// possible records (and newest fragments of an oversized record), while
    /// seeding the counters preserves all drops observed before the resize.
    public mutating func resize(recordLimit: Int, byteLimit: Int) {
        precondition(recordLimit > 0 && byteLimit > 0)
        guard recordLimit != self.recordLimit || byteLimit != self.byteLimit else { return }

        var replacement = LogRecordRing(
            recordLimit: recordLimit,
            byteLimit: byteLimit,
            fragmentByteLimit: fragmentByteLimit
        )
        replacement.droppedRecords = droppedRecords
        replacement.droppedBytes = droppedBytes
        replacement.append(contentsOf: records)
        self = replacement
    }

    private mutating func appendOne(_ record: LogRecord) {
        let size = record.data.count
        while recordCount > 0 && (recordCount >= recordLimit || byteCount + size > byteLimit) {
            let removed = storage[head]
            storage[head] = LogRecord(sourceID: "", data: Data(), endsWithNewline: false)
            head += 1
            byteCount -= removed.data.count
            droppedRecords &+= 1
            droppedBytes &+= UInt64(removed.data.count)
        }
        storage.append(record)
        byteCount += size
        compactStorageIfNeeded()
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

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        renderBatchMilliseconds: Int = 40
    ) {
        precondition(recordLimit > 0 && byteLimit > 0 && renderBatchMilliseconds > 0)
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        self.renderBatchMilliseconds = renderBatchMilliseconds
    }

    public init(preferences: LogDisplayPreferences) {
        self.init(
            recordLimit: preferences.recordLimit,
            byteLimit: preferences.byteLimit,
            renderBatchMilliseconds: preferences.renderBatchMilliseconds
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

/// Serializes ring mutations away from AppKit's main actor. The actor never
/// decodes log bytes and exposes only bounded snapshots for batched rendering.
public actor LogRecordStore {
    private var ring: LogRecordRing
    private var latestConfigurationRevision: UInt64 = 0

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
    /// Logical chunks preserve the visible records exactly. In particular,
    /// fragments of one oversized Kubernetes log line remain joined so saving
    /// the visible buffer does not introduce display-only line breaks.
    public var chunks: [String]
    /// TextKit-facing chunks may contain explicit continuation boundaries.
    /// NSTextView cannot lazily lay out the tail of a multi-megabyte paragraph;
    /// bounded physical paragraphs let noncontiguous layout skip directly to
    /// the visible region while retaining `chunks` for lossless export.
    public var displayChunks: [String]
    public var renderedRecords: Int
    public var omittedRecords: Int
    public var omittedSourceBytes: UInt64
    public var outputUTF8Bytes: Int
    public var displayOutputUTF8Bytes: Int
    public var displayContinuationBreaks: Int

    public init(
        chunks: [String],
        displayChunks: [String],
        renderedRecords: Int,
        omittedRecords: Int,
        omittedSourceBytes: UInt64,
        outputUTF8Bytes: Int,
        displayOutputUTF8Bytes: Int,
        displayContinuationBreaks: Int
    ) {
        self.chunks = chunks
        self.displayChunks = displayChunks
        self.renderedRecords = renderedRecords
        self.omittedRecords = omittedRecords
        self.omittedSourceBytes = omittedSourceBytes
        self.outputUTF8Bytes = outputUTF8Bytes
        self.displayOutputUTF8Bytes = displayOutputUTF8Bytes
        self.displayContinuationBreaks = displayContinuationBreaks
    }

    public var text: String { chunks.joined() }
    public var displayText: String { displayChunks.joined() }
}

/// A minimal streaming edit from one rendered log snapshot to the next. Log
/// rings evolve by dropping an old prefix and appending a new suffix, so the
/// AppKit layer can normally retain the shared middle without replacing the
/// full text storage. A filter change simply degenerates to a bounded replace.
public struct LogTextInstallPlan: Hashable, Sendable {
    public var previousUTF16Length: Int
    public var removePrefixUTF16Length: Int
    public var appendText: String
    public var resultUTF16Length: Int

    public init(
        previousUTF16Length: Int,
        removePrefixUTF16Length: Int,
        appendText: String,
        resultUTF16Length: Int
    ) {
        self.previousUTF16Length = previousUTF16Length
        self.removePrefixUTF16Length = removePrefixUTF16Length
        self.appendText = appendText
        self.resultUTF16Length = resultUTF16Length
    }

    public func applying(to previous: String) -> String {
        let value = previous as NSString
        let remove = min(max(0, removePrefixUTF16Length), value.length)
        return value.substring(from: remove) + appendText
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
        let append = currentChunks.dropFirst(overlap).joined()
        return LogTextInstallPlan(
            previousUTF16Length: removed + retained,
            removePrefixUTF16Length: removed,
            appendText: append,
            resultUTF16Length: retained + append.utf16.count
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
    /// Every bounded continuation fragment gets an independent display
    /// paragraph. The marker makes the projection unambiguous when Wrap is
    /// disabled; the logical/export projection omits it.
    public static let displayContinuationMarker = "↪ "

    private struct Candidate {
        var record: LogRecord
        var decoded: String
        var recordIndex: Int
        var sourcePrefix: String
        var timestampPrefix: String
    }

    public static func render(
        records: [LogRecord],
        sourceLabels: [String: String],
        showSourceLabels: Bool,
        filter: String,
        maximumOutputUTF8Bytes: Int
    ) throws -> RenderedLogText {
        precondition(maximumOutputUTF8Bytes > 0)
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
            // filtering, ring eviction, or byte-budget omission. Its display
            // paragraph also repeats source/timestamp context plus a marker.
            // Ellipsis and marker have equal UTF-8 width, so this one estimate
            // conservatively bounds both projections.
            let estimate = sourcePrefix.utf8.count + timestampPrefix.utf8.count
                + (record.startsLine ? 0 : "… ".utf8.count)
                + decoded.utf8.count
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
                timestampPrefix: timestampPrefix
            ))
            estimatedOutputBytes += estimate
        }
        try Task.checkCancellation()
        var chunks: [String] = []
        chunks.reserveCapacity(candidates.count * 3)
        var displayChunks: [String] = []
        displayChunks.reserveCapacity(candidates.count * 3)
        var outputBytes = 0
        var displayOutputBytes = 0
        var displayContinuationBreaks = 0
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

            // Unlike the logical projection, each record's display depends
            // only on that record. Evicting an old fragment therefore leaves
            // the retained suffix byte-for-byte stable and lets the AppKit
            // installer remove/append instead of replacing the whole buffer.
            let displayPrefix = candidate.sourcePrefix + candidate.timestampPrefix
                + (record.startsLine ? "" : displayContinuationMarker)
            if !displayPrefix.isEmpty { displayChunks.append(displayPrefix) }
            displayChunks.append(candidate.decoded)
            displayChunks.append("\n")
            displayOutputBytes += displayPrefix.utf8.count + candidate.decoded.utf8.count + 1
            if !record.startsLine {
                displayContinuationBreaks += 1
            }
            previousVisibleSourceID = record.sourceID
            previousVisibleIndex = candidate.recordIndex
            previousVisibleLineOpen = !record.endsWithNewline
        }
        return RenderedLogText(
            chunks: chunks,
            displayChunks: displayChunks,
            renderedRecords: candidates.count,
            omittedRecords: omittedRecords,
            omittedSourceBytes: omittedBytes,
            outputUTF8Bytes: outputBytes,
            displayOutputUTF8Bytes: displayOutputBytes,
            displayContinuationBreaks: displayContinuationBreaks
        )
    }

    private static func displaySafeLabel(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined().prefix(512))
    }
}
