import KmgrCore
import Testing

@Suite("Cluster manager model")
struct ClusterManagerModelsTests {
    @Test("current context is first and selected after discovery")
    func currentContextIsPreferred() {
        var model = ClusterManagerModel()
        let revision = model.beginLoading(reload: false)

        #expect(
            model.finishLoading(
                [
                    context(name: "zeta"),
                    context(name: "beta", current: true),
                    context(name: "alpha")
                ],
                revision: revision
            )
        )

        #expect(model.allContexts.map(\.name) == ["beta", "alpha", "zeta"])
        #expect(model.selectedContextName == "beta")
        #expect(model.canOpenSelectedContext)
    }

    @Test("search is folded, multi-term, and covers provenance")
    func searchableFields() {
        var model = ClusterManagerModel(
            contexts: [
                context(
                    name: "Dévelopment",
                    cluster: "kind-local",
                    host: "127.0.0.1",
                    namespace: "platform",
                    sources: ["/Users/operator/.kube/dev.yaml"]
                ),
                context(
                    name: "production",
                    cluster: "corp",
                    host: "api.example.com",
                    namespace: "default",
                    sources: ["/etc/kube/prod.yaml"]
                )
            ]
        )

        model.setSearchQuery("development platform")
        #expect(model.displayedContexts.map(\.name) == ["Dévelopment"])

        model.setSearchQuery("DEV.YAML kind")
        #expect(model.displayedContexts.map(\.name) == ["Dévelopment"])

        model.setSearchQuery("example default")
        #expect(model.displayedContexts.map(\.name) == ["production"])
    }

    @Test("selection moves only when filtering hides it")
    func selectionFollowsFilter() {
        var model = ClusterManagerModel(
            contexts: [context(name: "alpha"), context(name: "beta")],
            selectedContextName: "beta",
            phase: .loaded
        )

        model.setSearchQuery("alpha")
        #expect(model.selectedContextName == "alpha")

        model.setSearchQuery("")
        #expect(model.selectedContextName == "alpha")
    }

    @Test("unsupported authentication is structured and cannot open")
    func unsupportedAuthentication() {
        let issue = ClusterManagerIssue.unsupportedAuthentication(
            contextName: "cloud",
            mechanism: "exec credential plugin"
        )
        let cloud = context(
            name: "cloud",
            authentication: .unsupported(
                mechanism: "exec credential plugin",
                issue: issue
            )
        )
        let model = ClusterManagerModel(
            contexts: [cloud],
            phase: .loaded
        )

        #expect(!model.canOpenSelectedContext)
        #expect(model.selectedContextIssue?.category == .unsupported)
        #expect(model.selectedContextIssue?.contextName == "cloud")
        #expect(model.selectedContextIssue?.safeDetails["mechanism"] == "exec credential plugin")
        #expect(model.selectedContextIssue?.message.contains("cloud") == true)
    }

    @Test("stale async discovery cannot replace a newer reload")
    func staleDiscoveryIsIgnored() {
        var model = ClusterManagerModel()
        let firstRevision = model.beginLoading(reload: false)
        let secondRevision = model.beginLoading(reload: true)

        #expect(!model.finishLoading([context(name: "stale")], revision: firstRevision))
        #expect(model.allContexts.isEmpty)
        #expect(model.finishLoading([context(name: "fresh")], revision: secondRevision))
        #expect(model.allContexts.map(\.name) == ["fresh"])
    }

    @Test("failed reload keeps the last useful context list")
    func failedReloadKeepsContexts() {
        var model = ClusterManagerModel(
            contexts: [context(name: "local")],
            phase: .loaded
        )
        let revision = model.beginLoading(reload: true)
        let issue = ClusterManagerIssue(
            category: .validation,
            message: "One kubeconfig file is malformed."
        )

        #expect(model.failLoading(with: issue, revision: revision))
        #expect(model.allContexts.map(\.name) == ["local"])
        #expect(model.selectedContextName == "local")
        #expect(model.canOpenSelectedContext)
        #expect(model.phase == .failed(issue))
    }

    @Test("source provenance summarizes merged files without losing paths")
    func mergedSourceDisplay() {
        let summary = context(
            name: "merged",
            sources: ["/tmp/primary.yaml", "/tmp/secondary.yaml", "/tmp/team.yaml"]
        )

        #expect(summary.displayedSourcePath == "/tmp/primary.yaml (+2)")
        #expect(summary.sourcePaths.count == 3)
        #expect(summary.displayedNamespace == "default")
    }

    private func context(
        name: String,
        cluster: String = "cluster",
        host: String = "api.local",
        namespace: String = "",
        sources: [String] = ["/tmp/config"],
        current: Bool = false,
        authentication: ClusterAuthenticationAvailability = .supported(hint: "static")
    ) -> ClusterContextSummary {
        ClusterContextSummary(
            name: name,
            clusterName: cluster,
            serverHostname: host,
            defaultNamespace: namespace,
            sourcePaths: sources,
            isCurrent: current,
            authentication: authentication
        )
    }
}
