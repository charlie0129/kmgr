import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Cluster identity presentation", .serialized)
struct ClusterIdentityPresentationTests {
    @Test("shared formatter preserves exact cluster context and target identity")
    func sharedFormatter() {
        let presentation = ClusterIdentityPresentation(session: identitySession())

        #expect(presentation.titlePrefix == "cluster-a — production/admin@corp")
        #expect(presentation.labeledInline ==
            "Cluster: cluster-a · Context: production/admin@corp")
        #expect(presentation.targetDetails(deploymentIdentity()) == """
        Cluster: cluster-a
        Context: production/admin@corp
        Namespace: team-a
        Target: apps/v1/deployments · team-a/api
        UID: deployment-uid
        """)

        var clusterScoped = deploymentIdentity()
        clusterScoped.namespace = ""
        clusterScoped.name = "global-config"
        #expect(presentation.targetDetails(clusterScoped).contains(
            "Namespace: (cluster scoped)"
        ))
        #expect(presentation.targetDetails(clusterScoped).contains(
            "Target: apps/v1/deployments · global-config"
        ))
    }

    @Test("cluster-specific configuration sheets show cluster and exact context")
    func configurationSheetTitlesAndContent() throws {
        let session = identitySession()
        let pod = podIdentity()
        let objectProvider = IdentityNoopObjectDetailProvider()

        let exec = ExecConfigurationWindowController(
            session: session,
            podIdentity: pod,
            objectDetailProvider: objectProvider,
            execProvider: IdentityNoopExecProvider()
        )
        let forward = PortForwardConfigurationWindowController(
            session: session,
            targetIdentity: pod,
            objectDetailProvider: objectProvider,
            coordinator: PortForwardCoordinator(provider: IdentityNoopPortForwardProvider())
        )
        let nodeShell = NodeShellConfigurationWindowController(
            session: session,
            target: NodeShellTarget(node: nodeIdentity()),
            image: "registry.example/helper:1",
            namespace: "team-a",
            usesClusterImageOverride: false,
            execProvider: IdentityNoopExecProvider(),
            saveClusterImage: { _ in }
        )

        #expect(exec.window?.title == "cluster-a — production/admin@corp — Configure Terminal")
        #expect(forward.window?.title ==
            "cluster-a — production/admin@corp — Start Port Forward")
        #expect(nodeShell.window?.title ==
            "cluster-a — production/admin@corp — Configure Node Shell")

        for controller in [exec, forward, nodeShell] as [NSWindowController] {
            let root = try #require(controller.window?.contentView)
            let values = identityDescendants(of: root)
                .compactMap { ($0 as? NSTextField)?.stringValue }
            #expect(values.contains { $0.contains("cluster-a") })
            #expect(values.contains { $0.contains("production/admin@corp") })
        }

        let execRoot = try #require(exec.window?.contentView)
        let arguments = try #require(identityDescendants(of: execRoot)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Remote command arguments, one per line" })
        expectPreciseScrollingLayout(arguments)

        let forwardRoot = try #require(forward.window?.contentView)
        forwardRoot.layoutSubtreeIfNeeded()
        let forwardViews = identityDescendants(of: forwardRoot)
        let clusterLabel = try #require(forwardViews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "port-forward-label-cluster" })
        let declaredLabel = try #require(forwardViews.compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "port-forward-label-declared-port" })
        let declaredPort = try #require(forwardViews.compactMap { $0 as? NSPopUpButton }
            .first { $0.identifier?.rawValue == "port-forward-declared-port" })
        #expect(clusterLabel.alignment == .left)
        #expect(declaredLabel.alignment == .left)
        #expect(declaredPort.frame.width >= 260)
    }

    @Test("port-forward form stays compact and follows the remote port by default")
    func portForwardFormLayoutAndDefaultLocalPort() throws {
        let controller = PortForwardConfigurationWindowController(
            session: identitySession(),
            targetIdentity: podIdentity(),
            objectDetailProvider: IdentityNoopObjectDetailProvider(),
            coordinator: PortForwardCoordinator(provider: IdentityNoopPortForwardProvider())
        )
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        #expect(root.bounds.height < 500)
        let grids = identityDescendants(of: root).compactMap { $0 as? NSGridView }
        #expect(grids.count == 2)
        #expect(grids.allSatisfy { $0.frame.height < 180 })

        let fields = identityDescendants(of: root).compactMap { $0 as? NSTextField }
        let remote = try #require(fields.first { $0.accessibilityLabel() == "Remote port" })
        let local = try #require(fields.first { $0.accessibilityLabel() == "Local port" })
        remote.stringValue = "8080"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: remote
        ))
        #expect(local.stringValue == "8080")

        local.stringValue = "19090"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: local
        ))
        remote.stringValue = "8081"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: remote
        ))
        #expect(local.stringValue == "19090")
    }

    @Test("node shell form shares columns and stays compact")
    func nodeShellFormLayout() throws {
        let nodeShell = NodeShellConfigurationWindowController(
            session: identitySession(),
            target: NodeShellTarget(node: nodeIdentity()),
            image: "registry.example/helper:1",
            namespace: "team-a",
            usesClusterImageOverride: false,
            execProvider: IdentityNoopExecProvider(),
            saveClusterImage: { _ in }
        )

        let nodeShellRoot = try #require(nodeShell.window?.contentView)
        nodeShellRoot.layoutSubtreeIfNeeded()
        let nodeShellLabels = identityDescendants(of: nodeShellRoot)
            .compactMap { $0 as? NSTextField }
        let helperImageLabel = try #require(nodeShellLabels.first {
            $0.stringValue == "Helper image"
        })
        let helperNamespaceLabel = try #require(nodeShellLabels.first {
            $0.stringValue == "Helper namespace"
        })
        let clusterValue = try #require(nodeShellLabels.first {
            $0.stringValue == "cluster-a"
        })
        let imageField = try #require(nodeShellLabels.first {
            $0.accessibilityIdentifier() == "node-shell.image"
        })
        let warning = try #require(nodeShellLabels.first {
            $0.stringValue.hasPrefix("This creates a temporary privileged Pod")
        })
        let validation = try #require(nodeShellLabels.first {
            $0.accessibilityIdentifier() == "node-shell.validation"
        })
        let buttons = identityDescendants(of: nodeShellRoot).compactMap { $0 as? NSButton }
        let cancel = try #require(buttons.first { $0.title == "Cancel" })
        let connect = try #require(buttons.first {
            $0.accessibilityIdentifier() == "node-shell.connect"
        })

        #expect(helperImageLabel.alignment == .left)
        #expect(helperNamespaceLabel.alignment == .left)
        let helperImageFrame = nodeShellRoot.convert(
            helperImageLabel.bounds,
            from: helperImageLabel
        )
        let helperNamespaceFrame = nodeShellRoot.convert(
            helperNamespaceLabel.bounds,
            from: helperNamespaceLabel
        )
        #expect(helperImageFrame.minY > helperNamespaceFrame.maxY)
        #expect(helperImageFrame.minY - helperNamespaceFrame.maxY <= 20)

        let clusterValueFrame = nodeShellRoot.convert(clusterValue.bounds, from: clusterValue)
        let imageFieldFrame = nodeShellRoot.convert(imageField.bounds, from: imageField)
        let clusterValueLeading = clusterValueFrame.minX
            + clusterValue.alignmentRectInsets.left
        let imageFieldLeading = imageFieldFrame.minX
            + imageField.alignmentRectInsets.left
        #expect(abs(clusterValueLeading - imageFieldLeading) <= 1)

        let warningFrame = nodeShellRoot.convert(warning.bounds, from: warning)
        let cancelFrame = nodeShellRoot.convert(cancel.bounds, from: cancel)
        #expect(warningFrame.minY > cancelFrame.maxY)
        #expect(warningFrame.minY - cancelFrame.maxY <= 20)
        #expect(nodeShellRoot.bounds.height < 520)

        let compactHeight = nodeShellRoot.bounds.height
        imageField.stringValue = ""
        nodeShell.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: imageField
        ))
        nodeShellRoot.layoutSubtreeIfNeeded()
        #expect(!validation.isHidden)
        #expect(!connect.isEnabled)
        #expect(nodeShellRoot.bounds.height > compactHeight)

        imageField.stringValue = "registry.example/helper:1"
        nodeShell.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: imageField
        ))
        nodeShellRoot.layoutSubtreeIfNeeded()
        #expect(validation.isHidden)
        #expect(connect.isEnabled)
        #expect(abs(nodeShellRoot.bounds.height - compactHeight) <= 1)
    }

    @Test("mutation and conflict presentations include full immutable identity")
    func mutationConfirmations() throws {
        let session = identitySession()
        let identity = deploymentIdentity()
        let expected = ClusterIdentityPresentation(session: session).targetDetails(identity)
        #expect(ResourceMutationWindowController.confirmationInformativeText(
            session: session,
            identity: identity,
            note: "Scale after refreshing."
        ).contains(expected))
        #expect(PortForwardConfigurationWindowController
            .nonLoopbackConfirmationInformativeText(
                session: session,
                target: identity,
                bindAddress: "0.0.0.0"
            ).contains(expected))

        let conflict = DataConflictWindowController(
            session: session,
            identity: identity,
            key: "settings",
            resourceVersion: "rv-2",
            local: .missing("Local draft"),
            current: .missing("Current value"),
            canCopyLocal: false,
            retryUnavailableReason: nil,
            completion: { _ in }
        )
        #expect(conflict.window?.title ==
            "cluster-a — production/admin@corp — Resolve Key Conflict")
        let conflictRoot = try #require(conflict.window?.contentView)
        let conflictText = identityDescendants(of: conflictRoot)
            .compactMap { ($0 as? NSTextField)?.stringValue }
            .joined(separator: "\n")
        #expect(conflictText.contains(expected))
        let conflictValues = identityDescendants(of: conflictRoot)
            .compactMap { $0 as? NSTextView }
        #expect(conflictValues.count == 2)
        for value in conflictValues {
            expectPreciseScrollingLayout(value)
        }
    }

    @Test("terminal and app-wide forward records retain cluster context")
    func independentWindowIdentity() throws {
        let request = identityExecRequest()
        let terminal = TerminalWindowController(
            request: request,
            provider: IdentityNoopExecProvider()
        )
        let window = try #require(terminal.window)
        #expect(window.title ==
            "cluster-a — production/admin@corp — Terminal — api")
        #expect(window.subtitle == "team-a/api · app")

        let closeText = TerminalWindowController.closeConfirmationInformativeText(
            for: request
        )
        #expect(closeText.contains("Cluster: cluster-a"))
        #expect(closeText.contains("Context: production/admin@corp"))
        #expect(closeText.contains("Namespace: team-a"))
        #expect(closeText.contains("Target: v1/pods · team-a/api"))
        #expect(closeText.contains("UID: pod-uid"))
        #expect(closeText.contains("Container: app"))

        let record = PortForwardRecord(
            id: "forward",
            clusterSessionID: "session",
            contextName: "production/admin@corp",
            clusterName: "cluster-a",
            target: podIdentity(),
            remotePort: 8080,
            localPort: 18080,
            bindAddress: "127.0.0.1",
            state: .listening
        )
        #expect(PortForwardsWindowController.clusterContextText(for: record) ==
            "cluster-a — production/admin@corp")
    }

    @Test("port-forward coordinator enriches engine records from the exact session")
    func coordinatorEnrichesForwardRecords() async throws {
        let engineRecord = PortForwardRecord(
            id: "forward",
            clusterSessionID: "session",
            contextName: "",
            target: podIdentity(),
            remotePort: 8080,
            localPort: 18080,
            bindAddress: "127.0.0.1",
            state: .listening
        )
        let coordinator = PortForwardCoordinator(
            provider: IdentityListedPortForwardProvider(record: engineRecord)
        )
        coordinator.register(session: identitySession())
        defer { coordinator.stopWatching() }

        for _ in 0..<100 where coordinator.snapshot.records.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let record = try #require(coordinator.snapshot.records.first)
        #expect(record.clusterName == "cluster-a")
        #expect(record.contextName == "production/admin@corp")
        #expect(PortForwardsWindowController.clusterContextText(for: record) ==
            "cluster-a — production/admin@corp")
    }

    @Test("Port Forwards callback runs only after a successful start dismissal")
    func portForwardStartCompletionCallback() async throws {
        let successCoordinator = PortForwardCoordinator(
            provider: IdentityNoopPortForwardProvider()
        )
        defer { successCoordinator.stopWatching() }
        let success = PortForwardConfigurationWindowController(
            session: identitySession(),
            targetIdentity: podIdentity(),
            objectDetailProvider: IdentityNoopObjectDetailProvider(),
            coordinator: successCoordinator
        )
        var successEvents: [String] = []
        success.onDismiss = { successEvents.append("dismiss") }
        success.onStartSucceeded = { successEvents.append("success") }
        try startIdentityPortForward(success)
        for _ in 0..<100 where successEvents.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(successEvents == ["dismiss", "success"])

        let cancelled = PortForwardConfigurationWindowController(
            session: identitySession(),
            targetIdentity: podIdentity(),
            objectDetailProvider: IdentityNoopObjectDetailProvider(),
            coordinator: PortForwardCoordinator(provider: IdentityNoopPortForwardProvider())
        )
        var cancelEvents: [String] = []
        cancelled.onDismiss = { cancelEvents.append("dismiss") }
        cancelled.onStartSucceeded = { cancelEvents.append("success") }
        try identityButton("Cancel", in: cancelled).performClick(nil)
        #expect(cancelEvents == ["dismiss"])

        let failureCoordinator = PortForwardCoordinator(
            provider: IdentityFailingPortForwardProvider()
        )
        defer { failureCoordinator.stopWatching() }
        let failed = PortForwardConfigurationWindowController(
            session: identitySession(),
            targetIdentity: podIdentity(),
            objectDetailProvider: IdentityNoopObjectDetailProvider(),
            coordinator: failureCoordinator
        )
        var failureEvents: [String] = []
        failed.onDismiss = { failureEvents.append("dismiss") }
        failed.onStartSucceeded = { failureEvents.append("success") }
        try startIdentityPortForward(failed)
        for _ in 0..<100 where !identityText(in: failed).contains("Port-forward failed") {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(failureEvents.isEmpty)
        try identityButton("Cancel", in: failed).performClick(nil)
        #expect(failureEvents == ["dismiss"])
    }
}
}

@MainActor
private func startIdentityPortForward(
    _ controller: PortForwardConfigurationWindowController
) throws {
    let root = try #require(controller.window?.contentView)
    let remotePort = try #require(identityDescendants(of: root)
        .compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Remote port" })
    remotePort.stringValue = "8080"
    controller.controlTextDidChange(Notification(
        name: NSControl.textDidChangeNotification,
        object: remotePort
    ))
    try identityButton("Start", in: controller).performClick(nil)
}

@MainActor
private func identityButton(
    _ title: String,
    in controller: NSWindowController
) throws -> NSButton {
    let root = try #require(controller.window?.contentView)
    return try #require(identityDescendants(of: root)
        .compactMap { $0 as? NSButton }
        .first { $0.title == title })
}

@MainActor
private func identityText(in controller: NSWindowController) -> String {
    guard let root = controller.window?.contentView else { return "" }
    return identityDescendants(of: root)
        .compactMap { ($0 as? NSTextField)?.stringValue }
        .joined(separator: "\n")
}

private func identitySession() -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: "session",
        contextName: "production/admin@corp",
        clusterName: "cluster-a",
        serverHostname: "api.example.invalid",
        defaultNamespace: "team-a"
    )
}

private func deploymentIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "team-a",
        name: "api",
        uid: ResourceUID("deployment-uid")
    )
}

private func podIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "",
        version: "v1",
        resource: "pods",
        namespace: "team-a",
        name: "api",
        uid: ResourceUID("pod-uid")
    )
}

private func nodeIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session",
        group: "",
        version: "v1",
        resource: "nodes",
        namespace: "",
        name: "worker-a",
        uid: ResourceUID("node-uid")
    )
}

private func identityExecRequest() -> ExecSessionRequest {
    ExecSessionRequest(
        sessionID: "session",
        execSessionID: "exec",
        generation: 1,
        target: .pod(PodExecDestination(pod: podIdentity(), container: "app")),
        contextName: "production/admin@corp",
        clusterName: "cluster-a",
        command: ["/bin/sh"]
    )
}

@MainActor
private func identityDescendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(identityDescendants(of:))
}

private struct IdentityNoopExecProvider: ExecSessionProviding {
    func startExec(request: ExecSessionRequest) async throws -> any ExecSession {
        throw CancellationError()
    }
}

private struct IdentityNoopPortForwardProvider: PortForwardProviding {
    func listPortForwards(
        sessionID: String,
        includeStopped: Bool
    ) async throws -> [PortForwardRecord] { [] }

    func watchPortForwards(
        request: PortForwardWatchRequest
    ) -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        request.id
    }

    func stopPortForward(id: String, sessionID: String) async throws {}
    func restartPortForward(id: String, sessionID: String) async throws {}
}

private struct IdentityFailingPortForwardProvider: PortForwardProviding {
    func listPortForwards(
        sessionID: String,
        includeStopped: Bool
    ) async throws -> [PortForwardRecord] { [] }

    func watchPortForwards(
        request: PortForwardWatchRequest
    ) -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        throw ClusterManagerIssue(
            category: .unavailable,
            reason: "TestStartFailed",
            message: "The test forward could not start."
        )
    }

    func stopPortForward(id: String, sessionID: String) async throws {}
    func restartPortForward(id: String, sessionID: String) async throws {}
}

private struct IdentityListedPortForwardProvider: PortForwardProviding {
    var record: PortForwardRecord

    func listPortForwards(
        sessionID: String,
        includeStopped: Bool
    ) async throws -> [PortForwardRecord] { [record] }

    func watchPortForwards(
        request: PortForwardWatchRequest
    ) -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        AsyncThrowingStream { _ in }
    }

    func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        request.id
    }

    func stopPortForward(id: String, sessionID: String) async throws {}
    func restartPortForward(id: String, sessionID: String) async throws {}
}

private struct IdentityNoopObjectDetailProvider: ObjectDetailProviding {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        throw CancellationError()
    }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}
