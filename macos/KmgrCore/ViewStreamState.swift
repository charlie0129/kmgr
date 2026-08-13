import Foundation

public struct StreamCursor: Hashable, Codable, Sendable {
    public var generation: UInt64
    public var sequence: UInt64

    public init(generation: UInt64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }
}

public enum StreamMessageDisposition: Hashable, Sendable {
    case acceptedNewGeneration
    case acceptedNextSequence
    case ignoredStaleGeneration
    case ignoredStaleOrDuplicateSequence
}

/// Guards an individual long-running view stream. A new generation supersedes
/// all messages from an older stream, and sequence numbers must increase
/// monotonically inside one generation.
public struct GenerationSequenceGate: Hashable, Codable, Sendable {
    public private(set) var lastAccepted: StreamCursor?

    public init(lastAccepted: StreamCursor? = nil) {
        self.lastAccepted = lastAccepted
    }

    @discardableResult
    public mutating func accept(_ cursor: StreamCursor) -> StreamMessageDisposition {
        guard let lastAccepted else {
            self.lastAccepted = cursor
            return .acceptedNewGeneration
        }

        if cursor.generation < lastAccepted.generation {
            return .ignoredStaleGeneration
        }
        if cursor.generation > lastAccepted.generation {
            self.lastAccepted = cursor
            return .acceptedNewGeneration
        }
        guard cursor.sequence > lastAccepted.sequence else {
            return .ignoredStaleOrDuplicateSequence
        }
        self.lastAccepted = cursor
        return .acceptedNextSequence
    }

    public mutating func reset() {
        lastAccepted = nil
    }
}

public enum ViewFreshnessEvent: Hashable, Sendable {
    /// A process-memory warm cache was installed synchronously.
    case warmRowsInstalled(lastSynchronizedAt: Date)
    /// A view without usable warm rows begins a progressive LIST.
    case initialListStarted
    /// A warm view attempts WATCH continuity from its cached resourceVersion.
    case resumeStarted
    /// Resume cannot prove continuity; cached rows remain usable while LIST
    /// chunks arrive in the background.
    case relistStarted(initialLoaded: Int = 0)
    case relistProgress(loaded: Int)
    /// A LIST or resumed WATCH has established a consistent live stream.
    case watchEstablished(synchronizedAt: Date)
    /// Keep the last good rows visible while reconnecting.
    case connectionLost(lastSynchronizedAt: Date?)
}

public enum ViewFreshness: Hashable, Sendable {
    case empty
    case cached(lastSynchronizedAt: Date)
    case resuming(lastSynchronizedAt: Date)
    case relisting(loaded: Int, cachedSince: Date?)
    case watching(synchronizedAt: Date)
    case reconnecting(lastSynchronizedAt: Date?)

    public var hasUsableRows: Bool {
        switch self {
        case .empty:
            false
        case .cached, .resuming, .relisting(_, .some), .watching, .reconnecting(.some):
            true
        case .relisting(_, .none), .reconnecting(.none):
            false
        }
    }

    public var statusName: String {
        switch self {
        case .empty: "Loading"
        case .cached: "Cached"
        case .resuming: "Resuming"
        case .relisting: "Relisting"
        case .watching: "Watching"
        case .reconnecting: "Reconnecting"
        }
    }

    public func statusText(now: Date = Date()) -> String {
        switch self {
        case .empty:
            return "Loading…"
        case .cached(let date):
            return "Cached · \(Self.ageText(since: date, now: now)) old"
        case .resuming:
            return "Resuming…"
        case .relisting(let loaded, _):
            return loaded > 0 ? "Relisting… \(loaded.formatted()) loaded" : "Relisting…"
        case .watching:
            return "Watching"
        case .reconnecting:
            return "Reconnecting…"
        }
    }

    public func reducing(_ event: ViewFreshnessEvent) -> ViewFreshness {
        switch event {
        case .warmRowsInstalled(let lastSynchronizedAt):
            return .cached(lastSynchronizedAt: lastSynchronizedAt)
        case .initialListStarted:
            return .relisting(loaded: 0, cachedSince: nil)
        case .resumeStarted:
            switch self {
            case .cached(let date), .resuming(let date):
                return .resuming(lastSynchronizedAt: date)
            case .relisting(_, let date?), .watching(let date):
                return .resuming(lastSynchronizedAt: date)
            case .reconnecting(let date?):
                return .resuming(lastSynchronizedAt: date)
            case .empty, .relisting(_, nil), .reconnecting(nil):
                return .relisting(loaded: 0, cachedSince: nil)
            }
        case .relistStarted(let initialLoaded):
            return .relisting(
                loaded: max(0, initialLoaded),
                cachedSince: lastSynchronizedAt
            )
        case .relistProgress(let loaded):
            let currentLoaded: Int
            let cachedSince: Date?
            if case .relisting(let existing, let date) = self {
                currentLoaded = existing
                cachedSince = date
            } else {
                currentLoaded = 0
                cachedSince = lastSynchronizedAt
            }
            return .relisting(loaded: max(currentLoaded, loaded), cachedSince: cachedSince)
        case .watchEstablished(let synchronizedAt):
            return .watching(synchronizedAt: synchronizedAt)
        case .connectionLost(let suppliedDate):
            return .reconnecting(lastSynchronizedAt: suppliedDate ?? lastSynchronizedAt)
        }
    }

    public var lastSynchronizedAt: Date? {
        switch self {
        case .cached(let date), .resuming(let date), .watching(let date):
            date
        case .relisting(_, let date), .reconnecting(let date):
            date
        case .empty:
            nil
        }
    }

    private static func ageText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

public struct ViewStreamModel: Hashable, Sendable {
    public private(set) var gate: GenerationSequenceGate
    public private(set) var freshness: ViewFreshness

    public init(
        gate: GenerationSequenceGate = GenerationSequenceGate(),
        freshness: ViewFreshness = .empty
    ) {
        self.gate = gate
        self.freshness = freshness
    }

    /// Freshness changes only for an accepted message, so a late reconnect or
    /// canceled stream cannot roll the current UI backward.
    @discardableResult
    public mutating func receive(
        cursor: StreamCursor,
        event: ViewFreshnessEvent
    ) -> StreamMessageDisposition {
        let disposition = gate.accept(cursor)
        switch disposition {
        case .acceptedNewGeneration, .acceptedNextSequence:
            freshness = freshness.reducing(event)
        case .ignoredStaleGeneration, .ignoredStaleOrDuplicateSequence:
            break
        }
        return disposition
    }
}
