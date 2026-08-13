import Foundation

public enum ClusterConnectionState: Hashable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed
    case closed
}

/// Monotonic Kubernetes API payload totals emitted by the Go helper. The UI
/// derives rates locally so brief bursts remain visible without a chatty IPC
/// stream and no request or response content crosses this model boundary.
public struct ClusterConnectionActivitySample: Hashable, Sendable {
    public var cursor: StreamCursor
    public var state: ClusterConnectionState
    public var observedAt: Date
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var issue: ClusterManagerIssue?

    public init(
        cursor: StreamCursor,
        state: ClusterConnectionState,
        observedAt: Date,
        bytesReceived: UInt64,
        bytesSent: UInt64,
        issue: ClusterManagerIssue? = nil
    ) {
        self.cursor = cursor
        self.state = state
        self.observedAt = observedAt
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.issue = issue
    }
}

public protocol ClusterConnectionActivityProviding: Sendable {
    func watchConnectionActivity(
        sessionID: String,
        streamID: String
    ) -> AsyncThrowingStream<ClusterConnectionActivitySample, Error>
}

public struct ClusterConnectionRate: Hashable, Sendable {
    public var bytesReceivedPerSecond: Double
    public var bytesSentPerSecond: Double
    public var receivedActive: Bool
    public var sentActive: Bool

    public init(
        bytesReceivedPerSecond: Double = 0,
        bytesSentPerSecond: Double = 0,
        receivedActive: Bool = false,
        sentActive: Bool = false
    ) {
        self.bytesReceivedPerSecond = bytesReceivedPerSecond
        self.bytesSentPerSecond = bytesSentPerSecond
        self.receivedActive = receivedActive
        self.sentActive = sentActive
    }
}

/// Pure reducer for monotonic totals. Counter reset (for example after helper
/// restart) establishes a new baseline instead of producing an absurd rate.
public struct ClusterConnectionRateTracker: Hashable, Sendable {
    private var lastSample: ClusterConnectionActivitySample?

    public init() {}

    public mutating func receive(
        _ sample: ClusterConnectionActivitySample
    ) -> ClusterConnectionRate {
        defer { lastSample = sample }
        guard let previous = lastSample,
            sample.observedAt > previous.observedAt,
            sample.bytesReceived >= previous.bytesReceived,
            sample.bytesSent >= previous.bytesSent
        else { return ClusterConnectionRate() }
        let duration = sample.observedAt.timeIntervalSince(previous.observedAt)
        guard duration > 0 else { return ClusterConnectionRate() }
        let received = sample.bytesReceived - previous.bytesReceived
        let sent = sample.bytesSent - previous.bytesSent
        return ClusterConnectionRate(
            bytesReceivedPerSecond: Double(received) / duration,
            bytesSentPerSecond: Double(sent) / duration,
            receivedActive: received > 0,
            sentActive: sent > 0
        )
    }
}
