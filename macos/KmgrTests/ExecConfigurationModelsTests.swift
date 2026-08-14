import Foundation
import Testing
@testable import KmgrCore

@Test func execContainerCatalogUsesFreshSummaryWithoutOfferingDuplicateNames() {
    let fields = [
        ObjectSummaryField(
            sectionID: "containers", fieldID: "ephemeralContainer:debug",
            label: "Ephemeral Container", displayText: "debug"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "container:main",
            label: "Container", displayText: "main"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "initContainer:setup",
            label: "Init Container", displayText: "setup"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "container:debug",
            label: "Container", displayText: "debug"
        ),
        ObjectSummaryField(
            sectionID: "ports", fieldID: "port:TCP:8080:http",
            label: "Port", displayText: "8080/TCP"
        ),
    ]

    #expect(ExecContainerCatalog.candidates(from: fields) == [
        ExecContainerCandidate(name: "debug", kind: .regular),
        ExecContainerCandidate(name: "main", kind: .regular),
        ExecContainerCandidate(name: "setup", kind: .initContainer),
    ])
}

@Test func explicitExecCommandPreservesOneArgumentPerLineWithoutShellParsing() throws {
    let arguments = ExecCommandChoice.arguments(onePerLine: """
        --message
        hello operator
        --selector=app=api
        """)
    let command = try ExecCommandChoice.executable(
        path: " /usr/bin/tool ", arguments: arguments
    ).validatedCommand()

    #expect(command == [
        "/usr/bin/tool", "--message", "hello operator", "--selector=app=api",
    ])
}

@Test func execCommandValidationRejectsLineBreaksAndOversizedCommands() {
    #expect(throws: ExecConfigurationValidationError.invalidArgument) {
        try ExecCommandChoice.executable(
            path: "/bin/echo", arguments: ["unsafe\nargument"]
        ).validatedCommand()
    }
    #expect(throws: ExecConfigurationValidationError.commandTooLarge) {
        try ExecCommandChoice.executable(
            path: "/bin/echo",
            arguments: [String(repeating: "x", count: ExecCommandChoice.maximumUTF8Bytes)]
        ).validatedCommand()
    }
}

@Test func automaticExecHonorsDefaultContainerAndProbesCommonShells() throws {
    let pod = execPlannerPod()
    let fields = [
        ObjectSummaryField(
            sectionID: "containers", fieldID: "container:sidecar",
            label: "Container", displayText: "sidecar"
        ),
        ObjectSummaryField(
            sectionID: "containers", fieldID: "container:api",
            label: "Container", displayText: "api"
        ),
    ]
    let plan = try AutomaticExecLaunchPlanner.plan(
        session: execPlannerSession(),
        target: PodExecTarget(pod: pod),
        detail: ObjectDetail(
            identity: pod,
            resourceVersion: "42",
            summaryFields: fields,
            annotations: [
                AutomaticExecLaunchPlanner.defaultContainerAnnotation: "api",
            ]
        ),
        execSessionID: "exec-1"
    )

    #expect(plan.request.container == "api")
    #expect(plan.request.command == ["/bin/bash"])
    #expect(plan.fallbackShellCommand == ["/bin/sh"])
    #expect(plan.request.pod.uid == ResourceUID("pod-uid"))
    #expect(plan.request.execSessionID == "exec-1")
}

@Test func automaticExecUsesSpecOrderAndPinsExplicitContainerRows() throws {
    let pod = execPlannerPod()
    let detail = ObjectDetail(
        identity: pod,
        resourceVersion: "42",
        summaryFields: [
            ObjectSummaryField(
                sectionID: "containers", fieldID: "ephemeralContainer:debug",
                label: "Ephemeral Container", displayText: "debug"
            ),
            ObjectSummaryField(
                sectionID: "containers", fieldID: "container:sidecar",
                label: "Container", displayText: "sidecar"
            ),
            ObjectSummaryField(
                sectionID: "containers", fieldID: "container:api",
                label: "Container", displayText: "api"
            ),
        ]
    )

    let automatic = try AutomaticExecLaunchPlanner.plan(
        session: execPlannerSession(),
        target: PodExecTarget(pod: pod),
        detail: detail,
        execSessionID: "exec-auto"
    )
    let selected = try AutomaticExecLaunchPlanner.plan(
        session: execPlannerSession(),
        target: PodExecTarget(pod: pod, preferredContainer: "debug"),
        detail: detail,
        execSessionID: "exec-selected"
    )

    #expect(automatic.request.container == "sidecar")
    #expect(selected.request.container == "debug")
}

@Test func automaticExecRejectsReplacementPodsAndVanishedSelectedContainers() {
    let pod = execPlannerPod()
    let replacement = ResourceIdentity(
        clusterSessionID: pod.clusterSessionID,
        group: pod.group,
        version: pod.version,
        resource: pod.resource,
        namespace: pod.namespace,
        name: pod.name,
        uid: ResourceUID("replacement-uid")
    )
    #expect(throws: AutomaticExecLaunchError.objectIdentityMismatch) {
        try AutomaticExecLaunchPlanner.plan(
            session: execPlannerSession(),
            target: PodExecTarget(pod: pod),
            detail: ObjectDetail(
                identity: replacement,
                resourceVersion: "43",
                summaryFields: []
            ),
            execSessionID: "exec-replacement"
        )
    }

    #expect(throws: AutomaticExecLaunchError.preferredContainerUnavailable("old")) {
        try AutomaticExecLaunchPlanner.plan(
            session: execPlannerSession(),
            target: PodExecTarget(pod: pod, preferredContainer: "old"),
            detail: ObjectDetail(
                identity: pod,
                resourceVersion: "44",
                summaryFields: [
                    ObjectSummaryField(
                        sectionID: "containers", fieldID: "container:new",
                        label: "Container", displayText: "new"
                    ),
                ]
            ),
            execSessionID: "exec-vanished"
        )
    }
}

private func execPlannerSession() -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: "cluster-session",
        contextName: "production",
        clusterName: "cluster-a",
        serverHostname: "api.example.test",
        defaultNamespace: "default"
    )
}

private func execPlannerPod() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "cluster-session",
        group: "",
        version: "v1",
        resource: "pods",
        namespace: "team-a",
        name: "api",
        uid: ResourceUID("pod-uid")
    )
}
