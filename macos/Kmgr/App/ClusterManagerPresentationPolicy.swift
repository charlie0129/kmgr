/// Decides whether closing a cluster workspace should fill the resulting gap
/// with Cluster Manager. The chooser is not created during normal app
/// termination, while another workspace remains, or when it already exists.
/// Independent windows and app-owned listeners do not change this rule: an
/// app with no cluster workspace returns to Cluster Manager.
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
        return true
    }
}
