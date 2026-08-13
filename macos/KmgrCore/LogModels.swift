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

/// A byte-bounded ring which never assumes one Kubernetes log record is a
/// complete UTF-8 line. Oldest records are discarded first under pressure.
public struct LogRecordRing: Sendable {
    public let recordLimit: Int
    public let byteLimit: Int
    public private(set) var records: [LogRecord] = []
    public private(set) var byteCount = 0
    public private(set) var droppedRecords: UInt64 = 0
    public private(set) var droppedBytes: UInt64 = 0

    public init(recordLimit: Int = 20_000, byteLimit: Int = 16 << 20) {
        precondition(recordLimit > 0 && byteLimit > 0)
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
    }

    public mutating func append(contentsOf newRecords: [LogRecord]) {
        for record in newRecords {
            let size = record.data.count
            guard size <= byteLimit else {
                droppedRecords &+= 1
                droppedBytes &+= UInt64(size)
                continue
            }
            while !records.isEmpty && (records.count >= recordLimit || byteCount + size > byteLimit) {
                let removed = records.removeFirst()
                byteCount -= removed.data.count
                droppedRecords &+= 1
                droppedBytes &+= UInt64(removed.data.count)
            }
            records.append(record)
            byteCount += size
        }
    }

    public mutating func clear() {
        records.removeAll(keepingCapacity: true)
        byteCount = 0
    }
}
