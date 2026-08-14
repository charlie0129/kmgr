import Foundation
import KmgrCore
import Testing

@Suite("Cluster manager performance")
struct ClusterManagerPerformanceTests {
    @Test("large context searches keep one stable displayed projection")
    func largeContextSearchProjection() {
        let contextCount = 20_000
        let repeatedProjectionReads = 40
        let diagnosticsEnabled =
            ProcessInfo.processInfo.environment["KMGR_PERF_DIAGNOSTICS"] == "1"
        let budgetsEnabled =
            ProcessInfo.processInfo.environment["KMGR_PERF_BUDGETS"] == "1"
        let clock = ContinuousClock()
        let contexts = (0..<contextCount).map { index in
            ClusterContextSummary(
                id: "source-\(index)",
                name: String(format: "context-%05d", contextCount - index),
                clusterName: "cluster-\(index % 100)",
                serverHostname: "api-\(index).example.test",
                defaultNamespace: index.isMultiple(of: 2) ? "default" : "platform",
                sourcePaths: ["/tmp/kubeconfigs/team-\(index % 20).yaml"],
                authentication: .supported(hint: "static token")
            )
        }

        let loadStarted = clock.now
        var model = ClusterManagerModel(contexts: contexts, phase: .loaded)
        let loadDuration = clock.now - loadStarted

        let searchStarted = clock.now
        model.setSearchQuery("context-09999 platform")
        let searchDuration = clock.now - searchStarted
        #expect(model.displayedContexts.map(\.name) == ["context-09999"])

        let repeatedReadsStarted = clock.now
        var checksum = 0
        for _ in 0..<repeatedProjectionReads {
            checksum += model.displayedContexts.count
        }
        let repeatedReadsDuration = clock.now - repeatedReadsStarted
        #expect(checksum == repeatedProjectionReads)

        if diagnosticsEnabled || budgetsEnabled {
            let loadMilliseconds = milliseconds(loadDuration)
            let searchMilliseconds = milliseconds(searchDuration)
            let repeatedReadsMilliseconds = milliseconds(repeatedReadsDuration)
            print(String(format:
                "kmgr cluster-manager diagnostic: load/sort %d contexts %.3f ms; search %.3f ms; %d displayed-projection reads %.3f ms",
                contextCount,
                loadMilliseconds,
                searchMilliseconds,
                repeatedProjectionReads,
                repeatedReadsMilliseconds
            ))

            if budgetsEnabled {
                #expect(
                    searchMilliseconds <= 250,
                    "A 20,000-context search exceeded the release diagnostic budget."
                )
                #expect(
                    repeatedReadsMilliseconds <= 5,
                    "Reading a stable displayed-context projection must remain constant-time."
                )
            }
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
