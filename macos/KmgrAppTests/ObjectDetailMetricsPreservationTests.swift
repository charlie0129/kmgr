import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@Suite("Object detail metrics presentation")
struct ObjectDetailMetricsPreservationTests {
    @Test("Watch updates retain metrics fetched by the authoritative detail request")
    func watchUpdateRetainsFetchedMetrics() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "nodes",
            namespace: "",
            name: "node-a",
            uid: ResourceUID("node-uid")
        )
        let metric = ResourceUsageValue(
            usage: 0.75,
            capacity: 4,
            unit: "cores",
            resourceName: "cpu",
            provider: "metrics.k8s.io/v1beta1",
            measurementScope: "node"
        )
        let initial = ObjectDetail(
            identity: identity,
            resourceVersion: "10",
            yamlUTF8: Data("initial".utf8),
            metrics: [metric]
        )
        let watchUpdate = ObjectDetail(
            identity: identity,
            resourceVersion: "11",
            yamlUTF8: Data("updated".utf8),
            metrics: []
        )

        let merged = ObjectDetailWatchPresentation.merging(watchUpdate, previous: initial)

        #expect(merged.resourceVersion == "11")
        #expect(merged.yamlUTF8 == Data("updated".utf8))
        #expect(merged.metrics == [metric])
    }

    @Test("A future watch payload with metrics supersedes the prior values")
    func explicitWatchMetricsSupersedePriorValues() {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "team-a",
            name: "api",
            uid: ResourceUID("pod-uid")
        )
        let oldMetric = ResourceUsageValue(usage: 0.25, unit: "cores", resourceName: "cpu")
        let newMetric = ResourceUsageValue(usage: 0.5, unit: "cores", resourceName: "cpu")
        let initial = ObjectDetail(
            identity: identity, resourceVersion: "20", metrics: [oldMetric]
        )
        let watchUpdate = ObjectDetail(
            identity: identity, resourceVersion: "21", metrics: [newMetric]
        )

        let merged = ObjectDetailWatchPresentation.merging(watchUpdate, previous: initial)

        #expect(merged.metrics == [newMetric])
    }
}
