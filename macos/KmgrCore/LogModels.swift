import Foundation

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
    public var endsWithNewline: Bool

    public init(
        sourceID: String,
        data: Data,
        timestampUnixMilliseconds: Int64? = nil,
        endsWithNewline: Bool
    ) {
        self.sourceID = sourceID
        self.data = data
        self.timestampUnixMilliseconds = timestampUnixMilliseconds
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
    func streamLogs(request: LogStreamRequest) -> AsyncThrowingStream<LogStreamMessage, Error>
    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async
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
    public var text: String
    public var renderedRecords: Int
    public var omittedRecords: Int
    public var omittedSourceBytes: UInt64
    public var outputUTF8Bytes: Int

    public init(
        text: String,
        renderedRecords: Int,
        omittedRecords: Int,
        omittedSourceBytes: UInt64,
        outputUTF8Bytes: Int
    ) {
        self.text = text
        self.renderedRecords = renderedRecords
        self.omittedRecords = omittedRecords
        self.omittedSourceBytes = omittedSourceBytes
        self.outputUTF8Bytes = outputUTF8Bytes
    }
}

/// Pure, cancellation-aware renderer used from a detached task. It retains the
/// newest matching records when source labels or UTF-8 replacement expansion
/// would exceed the configured visible-text budget.
public enum LogTextRenderer {
    public static func render(
        records: [LogRecord],
        sourceLabels: [String: String],
        showSourceLabels: Bool,
        filter: String,
        maximumOutputUTF8Bytes: Int
    ) throws -> RenderedLogText {
        precondition(maximumOutputUTF8Bytes > 0)
        let foldedFilter = filter.lowercased()
        var chunks: [String] = []
        chunks.reserveCapacity(min(records.count, 4_096))
        var outputBytes = 0
        var omittedRecords = 0
        var omittedBytes: UInt64 = 0

        for (offset, record) in records.reversed().enumerated() {
            if offset & 63 == 0 { try Task.checkCancellation() }
            let decoded = String(decoding: record.data, as: UTF8.self)
            if !foldedFilter.isEmpty && !decoded.lowercased().contains(foldedFilter) {
                continue
            }
            let prefix: String
            if showSourceLabels, let label = sourceLabels[record.sourceID] {
                prefix = "[\(displaySafeLabel(label))] "
            } else {
                prefix = ""
            }
            let chunk = prefix + decoded + (record.endsWithNewline ? "\n" : "")
            let chunkBytes = chunk.utf8.count
            if chunkBytes > maximumOutputUTF8Bytes - outputBytes {
                omittedRecords += 1
                omittedBytes &+= UInt64(record.data.count)
                continue
            }
            chunks.append(chunk)
            outputBytes += chunkBytes
        }
        try Task.checkCancellation()
        return RenderedLogText(
            text: chunks.reversed().joined(),
            renderedRecords: chunks.count,
            omittedRecords: omittedRecords,
            omittedSourceBytes: omittedBytes,
            outputUTF8Bytes: outputBytes
        )
    }

    private static func displaySafeLabel(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
        }.joined().prefix(512))
    }
}
