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
