import Foundation
import KmgrCore

public enum EngineTerminationReason: String, Hashable, Sendable {
    case exit
    case uncaughtSignal
    case unknown
}

public struct EngineTermination: Hashable, Sendable {
    public var status: Int32
    public var reason: EngineTerminationReason

    public init(
        status: Int32,
        reason: EngineTerminationReason
    ) {
        self.status = status
        self.reason = reason
    }

    public var summary: String {
        switch reason {
        case .exit:
            "exit status \(status)"
        case .uncaughtSignal:
            "uncaught signal (status \(status))"
        case .unknown:
            "unknown termination (status \(status))"
        }
    }
}

public struct EngineDiagnosticsSnapshot: Hashable, Sendable {
    public var generation: UInt64
    public var startedAt: Date
    public var readyAt: Date?
    public var endedAt: Date?
    public var engineInstanceID: String?
    public var termination: EngineTermination?
    public var unexpected: Bool
    public var isCurrent: Bool
    public var records: [LogRecord]
    public var statistics: LogRecordRingStatistics

    public init(
        generation: UInt64,
        startedAt: Date,
        readyAt: Date? = nil,
        endedAt: Date? = nil,
        engineInstanceID: String? = nil,
        termination: EngineTermination? = nil,
        unexpected: Bool,
        isCurrent: Bool,
        records: [LogRecord],
        statistics: LogRecordRingStatistics
    ) {
        self.generation = generation
        self.startedAt = startedAt
        self.readyAt = readyAt
        self.endedAt = endedAt
        self.engineInstanceID = engineInstanceID
        self.termination = termination
        self.unexpected = unexpected
        self.isCurrent = isCurrent
        self.records = records
        self.statistics = statistics
    }

    public var readyDurationMilliseconds: Int64? {
        guard let readyAt, let endedAt else { return nil }
        return max(0, Int64((endedAt.timeIntervalSince(readyAt) * 1_000).rounded()))
    }
}

/// Retains a bounded stderr tail for the currently running helper and the
/// latest helper generation that ended unexpectedly. The store is independent
/// of AppKit so the process reader never has to wait for a visible window.
public actor EngineDiagnosticsStore {
    public static let defaultRecordLimit = 20_000
    public static let defaultByteLimit = 16 << 20

    private struct ActiveGeneration {
        var number: UInt64
        var startedAt: Date
        var readyAt: Date?
        var engineInstanceID: String?
        var lineIsOpen = false
    }

    private var ring: LogRecordRing
    private var activeGeneration: ActiveGeneration?
    private var latestUnexpected: EngineDiagnosticsSnapshot?
    private var nextGeneration: UInt64 = 0

    public init(
        recordLimit: Int = EngineDiagnosticsStore.defaultRecordLimit,
        byteLimit: Int = EngineDiagnosticsStore.defaultByteLimit
    ) {
        ring = LogRecordRing(
            recordLimit: recordLimit,
            byteLimit: byteLimit
        )
    }

    @discardableResult
    public func beginGeneration(startedAt: Date = Date()) -> UInt64 {
        nextGeneration &+= 1
        ring = LogRecordRing(
            recordLimit: ring.recordLimit,
            byteLimit: ring.byteLimit,
            fragmentByteLimit: ring.fragmentByteLimit
        )
        activeGeneration = ActiveGeneration(
            number: nextGeneration,
            startedAt: startedAt
        )
        return nextGeneration
    }

    public func append(data: Data) {
        guard var activeGeneration, !data.isEmpty else { return }
        var records: [LogRecord] = []
        records.reserveCapacity(4)
        var fragmentStart = data.startIndex
        for index in data.indices where data[index] == 0x0a {
            records.append(LogRecord(
                sourceID: "engine",
                data: data.subdata(in: fragmentStart..<index),
                startsLine: !activeGeneration.lineIsOpen,
                endsWithNewline: true
            ))
            activeGeneration.lineIsOpen = false
            fragmentStart = data.index(after: index)
        }
        if fragmentStart < data.endIndex {
            records.append(LogRecord(
                sourceID: "engine",
                data: data.subdata(in: fragmentStart..<data.endIndex),
                startsLine: !activeGeneration.lineIsOpen,
                endsWithNewline: false
            ))
            activeGeneration.lineIsOpen = true
        }
        ring.append(contentsOf: records)
        self.activeGeneration = activeGeneration
    }

    public func markReady(
        instanceID: String,
        at date: Date = Date()
    ) {
        guard var activeGeneration else { return }
        activeGeneration.readyAt = date
        activeGeneration.engineInstanceID = instanceID
        self.activeGeneration = activeGeneration
    }

    @discardableResult
    public func finishGeneration(
        termination: EngineTermination?,
        unexpected: Bool,
        endedAt: Date = Date()
    ) -> EngineDiagnosticsSnapshot? {
        guard let activeGeneration else { return nil }
        let snapshot = EngineDiagnosticsSnapshot(
            generation: activeGeneration.number,
            startedAt: activeGeneration.startedAt,
            readyAt: activeGeneration.readyAt,
            endedAt: endedAt,
            engineInstanceID: activeGeneration.engineInstanceID,
            termination: termination,
            unexpected: unexpected,
            isCurrent: false,
            records: ring.records,
            statistics: statistics(for: ring)
        )
        if unexpected { latestUnexpected = snapshot }
        self.activeGeneration = nil
        ring = LogRecordRing(
            recordLimit: ring.recordLimit,
            byteLimit: ring.byteLimit,
            fragmentByteLimit: ring.fragmentByteLimit
        )
        return snapshot
    }

    /// The last unexpected generation is preferred because opening the
    /// diagnostics window is normally a response to a restart or crash.
    /// Before any unexpected exit, this returns the current generation.
    public func preferredSnapshot() -> EngineDiagnosticsSnapshot? {
        if let latestUnexpected { return latestUnexpected }
        return currentSnapshot()
    }

    public func currentSnapshot() -> EngineDiagnosticsSnapshot? {
        guard let activeGeneration else { return nil }
        return EngineDiagnosticsSnapshot(
            generation: activeGeneration.number,
            startedAt: activeGeneration.startedAt,
            readyAt: activeGeneration.readyAt,
            endedAt: nil,
            engineInstanceID: activeGeneration.engineInstanceID,
            termination: nil,
            unexpected: false,
            isCurrent: true,
            records: ring.records,
            statistics: statistics(for: ring)
        )
    }

    public func latestUnexpectedSnapshot() -> EngineDiagnosticsSnapshot? {
        latestUnexpected
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
