import AppKit
import Foundation
import KmgrCore

/// Builds a terminal window without presenting configuration UI. The fresh
/// object read is both the container-discovery source and the first UID guard;
/// the engine repeats that guard immediately before Kubernetes exec.
@MainActor
enum AutomaticExecWindowFactory {
    static func makeWindow(
        session: OpenedClusterSession,
        target: PodExecTarget,
        objectDetailProvider: any ObjectDetailProviding,
        execProvider: any ExecSessionProviding,
        utilityWindowFrameCoordinator: UtilityWindowFrameCoordinator? = nil,
        preferredWindowFrame: NSRect? = nil
    ) async throws -> TerminalWindowController {
        let detail = try await objectDetailProvider.getObject(identity: target.pod)
        try Task.checkCancellation()
        let plan = try AutomaticExecLaunchPlanner.plan(
            session: session,
            target: target,
            detail: detail,
            execSessionID: UUID().uuidString.lowercased()
        )
        try Task.checkCancellation()
        return TerminalWindowController(
            request: plan.request,
            provider: execProvider,
            fallbackShellCommand: plan.fallbackShellCommand,
            utilityWindowFrameCoordinator: utilityWindowFrameCoordinator,
            preferredWindowFrame: preferredWindowFrame
        )
    }
}
