import Foundation

/// Tracks whether the operator's most recent input requested terminal EOF.
/// The window may close only after the same exec generation reports a
/// confirmed process exit; disconnects, failures, cancellation, and a later
/// reconnect never inherit the request.
public struct TerminalEOFAutoClosePolicy: Hashable, Sendable {
    private static let eofByte: UInt8 = 0x04
    private var requestedGeneration: UInt64?

    public init() {}

    public mutating func observeInput(_ data: Data, generation: UInt64) {
        if data.count == 1, data.first == Self.eofByte {
            requestedGeneration = generation
        } else if !data.isEmpty, requestedGeneration == generation {
            // More input proves that the earlier Control-D did not end the
            // foreground process (for example, it was consumed by an editor).
            requestedGeneration = nil
        }
    }

    public mutating func beginGeneration(_ generation: UInt64) {
        if requestedGeneration != generation {
            requestedGeneration = nil
        }
    }

    public mutating func shouldClose(
        after status: ExecStatus,
        generation: UInt64
    ) -> Bool {
        guard status.state == .exited,
            requestedGeneration == generation
        else { return false }
        requestedGeneration = nil
        return true
    }
}
