import Foundation

public struct ActiveViewDescriptor: Hashable, Codable, Sendable {
    public var clusterSessionID: String
    public var viewID: String

    public init(clusterSessionID: String, viewID: String) {
        self.clusterSessionID = clusterSessionID
        self.viewID = viewID
    }
}

public enum WorkspaceConnectivity: String, Hashable, Codable, Sendable {
    case connected
    case helperDisconnected
    case reopeningViews
    case closed
}

public enum WorkspaceLifecycleEffect: Hashable, Sendable {
    case cancelView(viewID: String)
    case cancelAllCancellableWork
    case reopenView(ActiveViewDescriptor)
}

public struct WorkspaceLifecycleModel: Hashable, Sendable {
    public private(set) var connectivity: WorkspaceConnectivity
    public private(set) var activeView: ActiveViewDescriptor?
    public private(set) var cancellableWorkIDs: Set<String>
    public private(set) var pendingMutations: Set<String>
    public private(set) var activeExecSessions: Set<String>
    /// Port forwards belong to the app-wide manager. Their IDs are tracked only
    /// to make the non-restart policy explicit; closing a workspace never stops
    /// them and helper recovery never silently recreates them.
    public private(set) var activePortForwards: Set<String>

    public init(
        connectivity: WorkspaceConnectivity = .connected,
        activeView: ActiveViewDescriptor? = nil,
        cancellableWorkIDs: Set<String> = [],
        pendingMutations: Set<String> = [],
        activeExecSessions: Set<String> = [],
        activePortForwards: Set<String> = []
    ) {
        self.connectivity = connectivity
        self.activeView = activeView
        self.cancellableWorkIDs = cancellableWorkIDs
        self.pendingMutations = pendingMutations
        self.activeExecSessions = activeExecSessions
        self.activePortForwards = activePortForwards
    }

    @discardableResult
    public mutating func windowWillClose() -> [WorkspaceLifecycleEffect] {
        guard connectivity != .closed else { return [] }
        var effects: [WorkspaceLifecycleEffect] = []
        if let activeView {
            effects.append(.cancelView(viewID: activeView.viewID))
        }
        if !cancellableWorkIDs.isEmpty {
            effects.append(.cancelAllCancellableWork)
        }
        activeView = nil
        cancellableWorkIDs.removeAll()
        pendingMutations.removeAll()
        activeExecSessions.removeAll()
        // Deliberately leave app-wide port forwards untouched.
        connectivity = .closed
        return effects
    }

    public mutating func helperDidExitUnexpectedly() {
        guard connectivity != .closed else { return }
        connectivity = .helperDisconnected
        cancellableWorkIDs.removeAll()
        // These operations have unknown outcomes and are not restartable.
        pendingMutations.removeAll()
        activeExecSessions.removeAll()
        activePortForwards.removeAll()
    }

    @discardableResult
    public mutating func helperDidRestart() -> [WorkspaceLifecycleEffect] {
        guard connectivity == .helperDisconnected else { return [] }
        guard let activeView else {
            connectivity = .connected
            return []
        }
        connectivity = .reopeningViews
        return [.reopenView(activeView)]
    }

    public mutating func reopenedViewDidConnect() {
        guard connectivity == .reopeningViews else { return }
        connectivity = .connected
    }
}
