import Foundation
import KmgrCore
import Testing

@Test func podDrillDownUsesBoundedAuthoritativeContainerCatalog() {
    let pod = drillDownIdentity(resource: "pods")
    let containers = [
        PodContainerDetail(name: "api", kind: .regular, status: "Running"),
        PodContainerDetail(name: "migrate", kind: .initContainer, status: "Terminated"),
    ]
    let detail = ObjectDetail(
        identity: pod,
        resourceVersion: "rv-1",
        summaryFields: [
            ObjectSummaryField(
                sectionID: "containers", fieldID: "container:api",
                label: "Container", displayText: "api"
            ),
            ObjectSummaryField(
                sectionID: "containers", fieldID: "initContainer:migrate",
                label: "Init Container", displayText: "migrate"
            ),
        ],
        containers: containers
    )
    #expect(ResourceDrillDownPlanner.plan(for: detail) == .containers(
        pod: pod,
        values: containers
    ))
}

@Test func workloadAndServiceDrillDownWriteNativeQueryToSearchField() {
    for identity in [
        drillDownIdentity(group: "apps", resource: "deployments"),
        drillDownIdentity(resource: "services"),
    ] {
        let detail = ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            summaryFields: [
                ObjectSummaryField(
                    sectionID: "selectors", fieldID: "selector:0",
                    label: "app", displayText: "api"
                ),
                ObjectSummaryField(
                    sectionID: "selectors", fieldID: "selector:1",
                    label: "tier", displayText: "frontend"
                ),
            ],
            podLabelSelector: "app=api,tier=frontend"
        )
        #expect(ResourceDrillDownPlanner.plan(for: detail) == .resource(
            ResourceDrillDownQuery(
                group: "", version: "v1", resource: "pods",
                namespaceScope: .namespace("default"),
                filterExpression:
                    "labelSelector:\"app=api,tier=frontend\""
            )
        ))
    }
}

@Test func workloadMatchExpressionsBecomeVisibleNativeQuery() {
    let deployment = drillDownIdentity(group: "apps", resource: "deployments")
    let detail = ObjectDetail(
        identity: deployment,
        resourceVersion: "rv-1",
        summaryFields: [
            ObjectSummaryField(
                sectionID: "selectors", fieldID: "selector:0",
                label: "app", displayText: "api"
            ),
            ObjectSummaryField(
                sectionID: "selectors", fieldID: "selectorExpressions",
                label: "Match Expressions", displayText: "1 cannot be represented"
            ),
        ],
        podLabelSelector: "app=api,debug,!retired,track in (canary,stable),zone notin (east,west)"
    )
    #expect(ResourceDrillDownPlanner.plan(for: detail) == .resource(
        ResourceDrillDownQuery(
            group: "", version: "v1", resource: "pods",
            namespaceScope: .namespace("default"),
            filterExpression:
                "labelSelector:\"app=api,debug,!retired,track in (canary,stable),zone notin (east,west)\""
        )
    ))
}

@Test func nodeAndNamespaceDrillDownUseSafeTypedTargets() {
    let node = drillDownIdentity(resource: "nodes", namespace: "", name: "worker-1")
    #expect(ResourceDrillDownPlanner.plan(for: ObjectDetail(
        identity: node, resourceVersion: "rv-1"
    )) == .resource(
        ResourceDrillDownQuery(
            group: "", version: "v1", resource: "pods",
            namespaceScope: NamespaceSelection(),
            filterExpression: "fieldSelector:\"spec.nodeName=worker-1\""
        )
    ))

    let namespace = drillDownIdentity(
        resource: "namespaces", namespace: "", name: "payments"
    )
    #expect(ResourceDrillDownPlanner.plan(for: ObjectDetail(
        identity: namespace, resourceVersion: "rv-1"
    )) == .resource(
        ResourceDrillDownQuery(
            group: "", version: "v1", resource: "pods",
            namespaceScope: .namespace("payments"), filterExpression: ""
        )
    ))
}

@Test func nativeFieldQueryEscapesKubernetesAndVisibleQuerySyntax() {
    #expect(ResourceQueryExpression.nativeFieldSelector(
        path: "metadata.name", equals: #"a\b,c=d"#
    ) == #"fieldSelector:"metadata.name=a\\\\b\\,c\\=d""#)
}

@Test func unsupportedAndEmptyResourcesHaveNoDrillDown() {
    let pvc = drillDownIdentity(resource: "persistentvolumeclaims")
    #expect(!ResourceDrillDownPlanner.hasPotentialTarget(pvc))
    #expect(ResourceDrillDownPlanner.plan(for: ObjectDetail(
        identity: pvc, resourceVersion: "rv-1"
    )) == nil)

    let pod = drillDownIdentity(resource: "pods")
    #expect(ResourceDrillDownPlanner.hasPotentialTarget(pod))
    #expect(ResourceDrillDownPlanner.plan(for: ObjectDetail(
        identity: pod, resourceVersion: "rv-1"
    )) == nil)

    #expect(ResourceDrillDownPlanner.plan(for: ObjectDetail(
        identity: pod,
        resourceVersion: "rv-1",
        summaryFields: [
            ObjectSummaryField(
                sectionID: "containers", fieldID: "container:api",
                label: "Container", displayText: "api"
            ),
            ObjectSummaryField(
                sectionID: "containers", fieldID: "containersOmitted",
                label: "Additional Containers", displayText: "1 not shown"
            ),
        ],
        containers: [PodContainerDetail(name: "api", kind: .regular)]
    )) == nil)

    let configMap = drillDownIdentity(resource: "configmaps")
    #expect(ResourceDrillDownPlanner.hasPotentialTarget(configMap))
    #expect(ResourceDrillDownPlanner.plan(for: ObjectDetail(
        identity: configMap, resourceVersion: "rv-1"
    )) == nil)
}

private func drillDownIdentity(
    group: String = "",
    resource: String,
    namespace: String = "default",
    name: String = "selected"
) -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "session", group: group, version: "v1",
        resource: resource, namespace: namespace, name: name,
        uid: ResourceUID("uid-\(resource)")
    )
}
