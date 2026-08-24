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
    }

    @Test("mutation and conflict presentations include full immutable identity")
    func mutationConfirmations() throws {
        let session = identitySession()
        let identity = deploymentIdentity()
        let expected = ClusterIdentityPresentation(session: session).targetDetails(identity)
        let detail = ObjectDetailViewController(
            identity: identity,
            provider: IdentityNoopObjectDetailProvider(),
            initialTab: .yaml,
            session: session
        )

        #expect(detail.mutationConfirmationIdentityText == expected)
        #expect(detail.confirmationInformativeText(note: "Delete key settings?") ==
            "\(expected)\n\nDelete key settings?")
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
        let toolbarIdentity = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "terminal.identity"
        }?.view as? NSTextField)
        #expect(toolbarIdentity.stringValue.contains(
            "cluster-a — production/admin@corp"
        ))
        #expect(toolbarIdentity.stringValue.contains("team-a/api · app"))

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
}
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

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

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
