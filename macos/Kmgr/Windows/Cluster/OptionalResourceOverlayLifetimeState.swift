import KmgrCore

/// Owns the transient overlay and its helper-session/GVR lifetime. Stream
/// generation is intentionally absent: each generation gets fresh discovery
/// authority from `OptionalResourceCatalogDiscoveryGate`, while an already
/// installed overlay remains visible across a same-target stream reopen.
struct OptionalResourceOverlayLifetimeState: Hashable, Sendable {
    private struct Scope: Hashable, Sendable {
        var sessionID: String
        var gvr: GVR
    }

    private(set) var overlay = OptionalResourceColumnOverlay()
    private var installedScope: Scope?

    @discardableResult
    mutating func clearIfScopeChanged(sessionID: String, gvr: GVR) -> Bool {
        guard let installedScope,
            installedScope != Scope(sessionID: sessionID, gvr: gvr)
        else { return false }
        clear()
        return true
    }

    mutating func install(
        _ overlay: OptionalResourceColumnOverlay,
        sessionID: String,
        gvr: GVR
    ) {
        self.overlay = overlay
        installedScope = Scope(sessionID: sessionID, gvr: gvr)
    }

    mutating func clear() {
        overlay.clear()
        installedScope = nil
    }

    func applies(sessionID: String, gvr: GVR) -> Bool {
        installedScope == Scope(sessionID: sessionID, gvr: gvr)
    }

    func applying(
        to persistedDefinitions: [ColumnDefinition],
        sessionID: String,
        gvr: GVR
    ) -> [ColumnDefinition] {
        guard applies(sessionID: sessionID, gvr: gvr) else {
            return persistedDefinitions
        }
        return overlay.applying(to: persistedDefinitions)
    }
}
