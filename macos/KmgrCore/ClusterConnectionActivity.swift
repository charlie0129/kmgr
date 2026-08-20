import Foundation

public enum ClusterConnectionState: Hashable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed
    case closed
}

public struct WarmCacheUsage: Hashable, Sendable {
    public var retainedViews: UInt64
    public var retainedObjects: UInt64
    public var retainedBytes: UInt64
    public var evictableViews: UInt64
    public var evictableObjects: UInt64
    public var evictableBytes: UInt64
    public var viewLimit: UInt64
    public var objectLimit: UInt64
    public var byteLimit: UInt64
    public var budgetEvictions: UInt64

    public init(
        retainedViews: UInt64 = 0,
        retainedObjects: UInt64 = 0,
        retainedBytes: UInt64 = 0,
        evictableViews: UInt64 = 0,
        evictableObjects: UInt64 = 0,
        evictableBytes: UInt64 = 0,
        viewLimit: UInt64 = 0,
        objectLimit: UInt64 = 0,
        byteLimit: UInt64 = 0,
        budgetEvictions: UInt64 = 0
    ) {
        self.retainedViews = retainedViews
        self.retainedObjects = retainedObjects
        self.retainedBytes = retainedBytes
        self.evictableViews = evictableViews
        self.evictableObjects = evictableObjects
        self.evictableBytes = evictableBytes
        self.viewLimit = viewLimit
        self.objectLimit = objectLimit
        self.byteLimit = byteLimit
        self.budgetEvictions = budgetEvictions
    }
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
    public var authorityWarmCache: WarmCacheUsage
    public var globalWarmCache: WarmCacheUsage
    public var issue: ClusterManagerIssue?

    public init(
        cursor: StreamCursor,
        state: ClusterConnectionState,
        observedAt: Date,
        bytesReceived: UInt64,
        bytesSent: UInt64,
        authorityWarmCache: WarmCacheUsage = WarmCacheUsage(),
        globalWarmCache: WarmCacheUsage = WarmCacheUsage(),
        issue: ClusterManagerIssue? = nil
    ) {
        self.cursor = cursor
        self.state = state
        self.observedAt = observedAt
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.authorityWarmCache = authorityWarmCache
        self.globalWarmCache = globalWarmCache
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
    ) -> ClusterConnectionRate? {
        guard let previous = lastSample else {
            lastSample = sample
            return nil
        }
        guard sample.observedAt > previous.observedAt,
            sample.bytesReceived >= previous.bytesReceived,
            sample.bytesSent >= previous.bytesSent
        else {
            lastSample = sample
            return ClusterConnectionRate()
        }
        let duration = sample.observedAt.timeIntervalSince(previous.observedAt)
        guard duration > 0 else {
            lastSample = sample
            return ClusterConnectionRate()
        }
        let received = sample.bytesReceived - previous.bytesReceived
        let sent = sample.bytesSent - previous.bytesSent
        lastSample = sample
        return ClusterConnectionRate(
            bytesReceivedPerSecond: Double(received) / duration,
            bytesSentPerSecond: Double(sent) / duration,
            receivedActive: received > 0,
            sentActive: sent > 0
        )
    }
}
