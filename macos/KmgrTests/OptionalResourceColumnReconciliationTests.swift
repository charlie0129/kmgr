import Testing
@testable import KmgrCore

@Suite("Optional resource discovery gate")
struct OptionalResourceDiscoveryGateTests {
    @Test("does not authorize discovery until the base view is usable")
    func waitsForBaseView() throws {
        var gate = OptionalResourceCatalogDiscoveryGate()
        gate.markBaseViewUsable()
        #expect(gate.beginDiscovery() == nil)

        let target = Self.target(resource: Self.pods, generation: 4)
        gate.select(target)
        #expect(!gate.baseViewIsUsable)
        #expect(gate.beginDiscovery() == nil)

        gate.markBaseViewUsable()
        let started = gate.beginDiscovery()
        let ticket = try #require(started)
        #expect(ticket.request.sessionID == "session-one")
        #expect(ticket.request.applicableResource == Self.pods)
        #expect(ticket.targetKey == target.key)
        #expect(gate.hasOutstandingRequest(for: target.key))

        // Refresh cannot overlap the outstanding automatic request.
        #expect(gate.beginDiscovery(refresh: true) == nil)
        let applied = gate.finishSuccess(ticket)
        #expect(applied)
        #expect(!gate.hasOutstandingRequest(for: target.key))
        #expect(gate.automaticDiscoveryCompleted)
        #expect(gate.beginDiscovery() == nil)

        // A later explicit refresh is allowed, still one at a time.
        let startedRefresh = gate.beginDiscovery(refresh: true)
        let refresh = try #require(startedRefresh)
        #expect(gate.beginDiscovery(refresh: true) == nil)
        let released = gate.finishWithoutResult(refresh)
        #expect(released)
        #expect(gate.beginDiscovery(refresh: true) != nil)
    }

    @Test("stale completions cannot apply after the selected target changes")
    func ignoresStaleCompletion() throws {
        var gate = OptionalResourceCatalogDiscoveryGate()
        let podsTarget = Self.target(resource: Self.pods, generation: 8)
        gate.select(podsTarget)
        gate.markBaseViewUsable()
        let startedPods = gate.beginDiscovery()
        let podsTicket = try #require(startedPods)

        let nodesTarget = Self.target(resource: Self.nodes, generation: 9)
        gate.select(nodesTarget)
        #expect(!gate.baseViewIsUsable)
        gate.markBaseViewUsable()
        let startedNodes = gate.beginDiscovery()
        let nodesTicket = try #require(startedNodes)

        let appliedPods = gate.finishSuccess(podsTicket)
        #expect(!appliedPods)
        #expect(!gate.automaticDiscoveryCompleted)
        let appliedNodes = gate.finishSuccess(nodesTicket)
        #expect(appliedNodes)
        #expect(gate.automaticDiscoveryCompleted)
    }

    @Test("returning to an exact target cannot overlap its stale request")
    func sameTargetNeverOverlaps() throws {
        var gate = OptionalResourceCatalogDiscoveryGate()
        let target = Self.target(resource: Self.pods, generation: 12)
        gate.select(target)
        gate.markBaseViewUsable()
        let startedOld = gate.beginDiscovery()
        let oldTicket = try #require(startedOld)

        gate.select(Self.target(resource: Self.nodes, generation: 12))
        gate.select(target)
        gate.markBaseViewUsable()
        #expect(gate.beginDiscovery() == nil)

        let appliedOld = gate.finishSuccess(oldTicket)
        #expect(!appliedOld)
        #expect(gate.beginDiscovery() != nil)
    }

    @Test("view generation is part of the target authority")
    func generationInvalidatesCompletion() throws {
        var gate = OptionalResourceCatalogDiscoveryGate()
        gate.select(Self.target(resource: Self.pods, generation: 2))
        gate.markBaseViewUsable()
        let startedOld = gate.beginDiscovery()
        let old = try #require(startedOld)

        gate.select(Self.target(resource: Self.pods, generation: 3))
        gate.markBaseViewUsable()
        let startedCurrent = gate.beginDiscovery()
        let current = try #require(startedCurrent)
        #expect(old.targetKey != current.targetKey)
        let appliedOld = gate.finishSuccess(old)
        #expect(!appliedOld)
        let appliedCurrent = gate.finishSuccess(current)
        #expect(appliedCurrent)
    }

    @Test("unsupported GVRs never authorize the catalog RPC")
    func rejectsUnsupportedResources() {
        var gate = OptionalResourceCatalogDiscoveryGate()
        gate.select(Self.target(
            resource: DiscoveredResource(
                group: "apps",
                version: "v1",
                resource: "deployments",
                kind: "Deployment",
                namespaced: true
            ),
            generation: 1
        ))
        gate.markBaseViewUsable()
        #expect(gate.beginDiscovery() == nil)
    }

    private static func target(
        resource: DiscoveredResource,
        generation: UInt64
    ) -> OptionalResourceCatalogDiscoveryTarget {
        OptionalResourceCatalogDiscoveryTarget(
            sessionID: "session-one",
            applicableResource: resource,
            viewGeneration: generation
        )
    }

    private static let pods = DiscoveredResource(
        group: "", version: "v1", resource: "pods",
        kind: "Pod", namespaced: true
    )

    private static let nodes = DiscoveredResource(
        group: "", version: "v1", resource: "nodes",
        kind: "Node", namespaced: false
    )
}

@Suite("Optional resource column overlay")
struct OptionalResourceColumnOverlayTests {
    @Test("reconciles exact resources without replacing persisted extractors")
    func persistedDefinitionsWin() throws {
        let configuredGPU = ColumnDefinition(
            id: "my-gpu",
            title: "Production GPU",
            source: .metric,
            value: "resource:nvidia.com/gpu",
            type: .resourceUsage,
            enabled: false
        )
        let persisted = [
            NativeColumnCatalog.descriptor(value: "name")!.definition(),
            configuredGPU,
        ]
        var overlay = OptionalResourceColumnOverlay()
        try overlay.reconcile(
            Self.catalog(resources: [
                Self.entry(
                    key: "ephemeral-storage",
                    category: .ephemeralStorage,
                    present: true,
                    title: "Ephemeral Storage"
                ),
                Self.entry(
                    key: "nvidia.com/gpu",
                    category: .accelerator,
                    present: true,
                    title: "GPU"
                ),
                Self.entry(
                    key: "aliyun.com/ppu",
                    category: .accelerator,
                    present: true,
                    title: "GPU"
                ),
                Self.entry(
                    key: "hugepages-2Mi",
                    category: .hugePage,
                    present: true,
                    title: "Huge Pages (2Mi)"
                ),
            ]),
            applicableResource: Self.pods,
            persistedDefinitions: persisted
        )

        #expect(overlay.ephemeralStorage?.isPresent == true)
        #expect(!overlay.definitions.contains {
            $0.value == "resource:ephemeral-storage"
        })
        #expect(!overlay.definitions.contains {
            $0.value == "resource:nvidia.com/gpu"
        })
        #expect(overlay.definitions.map(\.value) == [
            "resource:aliyun.com/ppu",
            "resource:hugepages-2Mi",
        ])
        #expect(overlay.definitions.map(\.id) == overlay.definitions.map(\.value))
        #expect(overlay.definitions.map(\.title) == ["GPU", "Huge Pages (2Mi)"])
        #expect(overlay.definitions.allSatisfy { $0.isEnabled })

        let applied = overlay.applying(to: persisted)
        #expect(applied.prefix(persisted.count).elementsEqual(persisted))
        #expect(applied.first { $0.value == "resource:nvidia.com/gpu" } == configuredGPU)
        #expect(Set(applied.compactMap(\.nativeExtractorIdentity)).count ==
            applied.compactMap(\.nativeExtractorIdentity).count)
    }

    @Test("configured absence stays selectable but disabled")
    func configuredAbsenceIsDisabled() throws {
        var overlay = OptionalResourceColumnOverlay()
        try overlay.reconcile(
            Self.catalog(resources: [
                Self.entry(
                    key: "custom.example/fpga-card",
                    category: .accelerator,
                    present: false,
                    title: "FPGA Cards",
                    explicitlyConfigured: true
                ),
                Self.entry(
                    key: "example.test/absent-device",
                    category: .accelerator,
                    present: false,
                    title: "Absent"
                ),
            ]),
            applicableResource: Self.pods,
            persistedDefinitions: []
        )

        let definition = try #require(overlay.definitions.first)
        #expect(overlay.definitions.count == 1)
        #expect(definition.value == "resource:custom.example/fpga-card")
        #expect(definition.id == "resource:custom.example/fpga-card")
        #expect(definition.title == "FPGA Cards")
        #expect(!definition.isEnabled)
    }

    @Test("a refresh atomically replaces stale ephemeral definitions")
    func refreshReplacesOverlay() throws {
        var overlay = OptionalResourceColumnOverlay()
        try overlay.reconcile(
            Self.catalog(resources: [Self.entry(
                key: "hugepages-2Mi",
                category: .hugePage,
                present: true,
                title: "Huge Pages (2Mi)"
            )]),
            applicableResource: Self.pods,
            persistedDefinitions: []
        )
        #expect(overlay.definitions.map(\.value) == ["resource:hugepages-2Mi"])

        try overlay.reconcile(
            Self.catalog(resources: [Self.entry(
                key: "hugepages-1Gi",
                category: .hugePage,
                present: true,
                title: "Huge Pages (1Gi)"
            )]),
            applicableResource: Self.pods,
            persistedDefinitions: []
        )
        #expect(overlay.definitions.map(\.value) == ["resource:hugepages-1Gi"])
    }

    @Test("newly persisted definitions override an existing overlay immediately")
    func laterPersistenceWins() throws {
        let entry = Self.entry(
            key: "aliyun.com/ppu",
            category: .accelerator,
            present: true,
            title: "PPU"
        )
        var overlay = OptionalResourceColumnOverlay()
        try overlay.reconcile(
            Self.catalog(resources: [entry]),
            applicableResource: Self.pods,
            persistedDefinitions: []
        )
        #expect(overlay.definitions.count == 1)

        let persisted = ColumnDefinition(
            id: "configured-ppu",
            title: "AI Accelerator",
            source: .metric,
            value: "resource:aliyun.com/ppu",
            type: .resourceUsage,
            enabled: false
        )
        #expect(overlay.applying(to: [persisted]) == [persisted])
    }

    @Test("raw transient wire IDs cannot duplicate persisted IDs or extractors")
    func rawWireIdentityDoesNotDuplicatePersistedColumns() throws {
        let entry = Self.entry(
            key: "aliyun.com/ppu",
            category: .accelerator,
            present: true,
            title: "PPU"
        )
        let rawIDCollision = ColumnDefinition(
            id: "resource:aliyun.com/ppu",
            title: "Unrelated CEL",
            source: .cel,
            expression: "object.metadata.name",
            type: .string
        )
        var overlay = OptionalResourceColumnOverlay()
        try overlay.reconcile(
            Self.catalog(resources: [entry]),
            applicableResource: Self.pods,
            persistedDefinitions: [rawIDCollision]
        )
        #expect(overlay.definitions.isEmpty)

        let extractorCollision = ColumnDefinition(
            id: "configured-ppu",
            title: "Configured PPU",
            source: .metric,
            value: "resource:aliyun.com/ppu",
            type: .resourceUsage
        )
        try overlay.reconcile(
            Self.catalog(resources: [entry]),
            applicableResource: Self.pods,
            persistedDefinitions: [extractorCollision]
        )
        #expect(overlay.definitions.isEmpty)
    }

    @Test("entries for another GVR are ignored")
    func ignoresAnotherGVR() throws {
        var wrong = Self.entry(
            key: "nvidia.com/gpu",
            category: .accelerator,
            present: true,
            title: "GPU"
        )
        wrong.applicableResource = Self.nodes
        var overlay = OptionalResourceColumnOverlay()
        try overlay.reconcile(
            Self.catalog(resources: [wrong]),
            applicableResource: Self.pods,
            persistedDefinitions: []
        )
        #expect(overlay.definitions.isEmpty)
    }

    private static func catalog(
        resources: [OptionalResourceCatalogEntry]
    ) -> OptionalResourceCatalog {
        OptionalResourceCatalog(
            requestID: "catalog-request",
            resources: resources,
            nodesCacheAvailable: false,
            podsCacheAvailable: true,
            nodesSnapshotComplete: false,
            podsSnapshotComplete: true,
            potentiallyIncomplete: true
        )
    }

    private static func entry(
        key: String,
        category: OptionalResourceCategory,
        present: Bool,
        title: String,
        explicitlyConfigured: Bool = false
    ) -> OptionalResourceCatalogEntry {
        OptionalResourceCatalogEntry(
            exactKey: key,
            category: category,
            isPresent: present,
            displayName: title,
            applicableResource: pods,
            isExplicitlyConfigured: explicitlyConfigured
        )
    }

    private static let pods = DiscoveredResource(
        group: "", version: "v1", resource: "pods",
        kind: "Pod", namespaced: true
    )

    private static let nodes = DiscoveredResource(
        group: "", version: "v1", resource: "nodes",
        kind: "Node", namespaced: false
    )
}
