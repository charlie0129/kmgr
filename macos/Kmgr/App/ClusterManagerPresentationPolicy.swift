/// Decides whether closing a cluster workspace should fill the resulting gap
/// with Cluster Manager. The chooser is not created during normal app
/// termination, and closing the final ordinary window may still use the
/// standard macOS quit behavior. Independent windows and app-owned listeners
/// keep the process alive, so they must not leave it without either a
/// workspace or a chooser.
struct ClusterManagerPresentationPolicy {
    var isTerminating: Bool
    var remainingWorkspaceCount: Int
    var hasClusterManager: Bool
    var hasVisibleIndependentWindow: Bool
    var hasActivePortForward: Bool

    var shouldPresentAfterWorkspaceClose: Bool {
        guard !isTerminating,
            remainingWorkspaceCount == 0,
            !hasClusterManager
        else { return false }
        return hasVisibleIndependentWindow || hasActivePortForward
    }
}
