import AppKit
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Cluster workspace toolbar", .serialized)
struct ClusterWorkspaceToolbarTests {
    @Test("navigation items stay in the leading toolbar group")
    func navigationItemsAreLeading() throws {
        let controller = makeWorkspace()
        let window = try #require(controller.window)
        let items = try #require(window.toolbar?.items)

        #expect(window.toolbarStyle == .unified)
        #expect(items.prefix(5).map(\.itemIdentifier.rawValue) == [
            "workspace.sidebar", "workspace.back", "workspace.forward",
            "workspace.cluster", "workspace.namespace",
        ])
        for identifier in items.prefix(5).map(\.itemIdentifier.rawValue) {
            #expect(try #require(items.first {
                $0.itemIdentifier.rawValue == identifier
            }).isNavigational)
        }
        #expect(items.firstIndex { $0.itemIdentifier == .flexibleSpace }
            == items.firstIndex {
                $0.itemIdentifier.rawValue == "workspace.namespace"
            }.map { $0 + 1 })
    }

    @Test("Port Forwards button gives its title and arrows separate geometry")
    func portForwardsButtonGeometry() throws {
        let controller = makeWorkspace()
        let item = try #require(controller.window?.toolbar?.items.first {
            $0.label == "Port Forwards"
        })
        let button = try #require(item.view as? NSButton)

        #expect(button.title == "Forwards 0")
        #expect(button.image != nil)
        #expect(button.imagePosition == .imageLeading)
        #expect(button.imageHugsTitle)
        button.sizeToFit()
        #expect(button.frame.width >= button.intrinsicContentSize.width)
    }

    @Test("resource navigation exposes native accessibility roles and text alternatives")
    func resourceNavigationAccessibility() throws {
        let controller = makeWorkspace()
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let views = descendants(of: root)
        let outline = try #require(views.compactMap { $0 as? NSOutlineView }.first)
        let table = try #require(views.compactMap { $0 as? NSTableView }.first {
            $0.accessibilityLabel() == "Kubernetes resources"
        })
        let filter = try #require(views.compactMap { $0 as? NSSearchField }.first {
            $0.accessibilityLabel() == "Filter Kubernetes resources"
        })
        let freshness = try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Resource freshness"
        })
        let progress = try #require(views.compactMap { $0 as? NSProgressIndicator }.first {
            $0.accessibilityLabel() == "Resource view update in progress"
        })
        let columns = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.title == "Columns…"
        })
        let forwards = try #require(window.toolbar?.items.compactMap { $0.view as? NSButton }
            .first { $0.accessibilityLabel() == "Open app-wide Port Forwards" })
        let cluster = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.cluster"
        }?.view as? NSButton)

        #expect(window.title.contains("test-cluster — test-context"))
        #expect(cluster.title == "test-cluster — test-context")
        #expect(outline.accessibilityRole() == .outline)
        #expect(outline.accessibilityLabel() == "Kubernetes resource kinds")
        #expect(table.accessibilityRole() == .table)
        #expect(table.allowsMultipleSelection)
        #expect(filter.accessibilityLabel() == "Filter Kubernetes resources")
        #expect(freshness.accessibilityLabel() == "Resource freshness")
        #expect(progress.accessibilityRole() == .busyIndicator)
        #expect(columns.title == "Columns…")
        #expect(forwards.title.contains("Forwards"))
    }

    @Test("unmodified table shortcuts are disabled while editing filter text")
    func tableMenuCommandsRespectTextInputFocus() async throws {
        let controller = makeWorkspace(provider: FilterValidationWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let filter = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
        let actions = [
            #selector(ClusterWorkspaceWindowController.focusResourceFilter(_:)),
            #selector(ClusterWorkspaceWindowController.moveResourceSelectionUp(_:)),
            #selector(ClusterWorkspaceWindowController.moveResourceSelectionDown(_:)),
            #selector(ClusterWorkspaceWindowController.extendResourceSelectionUp(_:)),
            #selector(ClusterWorkspaceWindowController.extendResourceSelectionDown(_:)),
        ]

        try await waitUntil { table.numberOfRows == 1 }
        #expect(window.makeFirstResponder(table))
        #expect(window.firstResponder === table)
        for action in actions {
            let item = NSMenuItem(title: "test", action: action, keyEquivalent: "")
            #expect(controller.validateMenuItem(item))
        }

        controller.focusResourceFilter(nil)
        #expect(window.firstResponder !== table)
        #expect(window.firstResponder === filter || filter.currentEditor() != nil)
        for action in actions {
            let item = NSMenuItem(title: "test", action: action, keyEquivalent: "")
            #expect(!controller.validateMenuItem(item))
        }
    }

    @Test("Edit Select All retains selection hidden by the active filter")
    func responderSelectAllRetainsHiddenSelection() async throws {
        let controller = makeWorkspace(provider: SelectAllFilterWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "resource-status-line" })

        try await waitUntil { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await waitUntil { status.stringValue.contains("1 selected") }

        try triggerResourceFilterChange(in: window, value: "name:api")
        try await waitUntil {
            table.numberOfRows == 1
                && status.stringValue.contains("1 selected (1 hidden by filter)")
        }

        #expect(window.makeFirstResponder(table))
        #expect(table.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil))
        #expect(status.stringValue.contains("2 selected (1 hidden by filter)"))
        #expect(table.selectedRowIndexes == IndexSet(integer: 0))
    }

    @Test("resource freshness header shows cached age and background progress")
    func resourceFreshnessHeader() async throws {
        let synchronizedAt = Date(timeIntervalSinceNow: -18)
        let provider = HeaderStatusWorkspaceResourceProvider(
            statuses: [
                ResourceViewStatus(
                    freshness: .stale,
                    rowsVisible: 7,
                    lastSynchronizedAt: synchronizedAt,
                    fromWarmCache: true
                ),
                ResourceViewStatus(
                    freshness: .reconnecting,
                    rowsVisible: 7,
                    lastSynchronizedAt: synchronizedAt,
                    fromWarmCache: true
                ),
            ]
        )
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let label = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Resource freshness" })
        let progress = try #require(descendants(of: root)
            .compactMap { $0 as? NSProgressIndicator }
            .first { $0.accessibilityLabel() == "Resource view update in progress" })

        try await waitUntil { label.stringValue.hasPrefix("Reconnecting…") }
        #expect(label.stringValue.contains("last synchronized"))
        #expect(label.stringValue.contains("old"))
        #expect(!progress.isHidden)
        #expect(!progress.isDisplayedWhenStopped)
        #expect(label.accessibilityValue() == label.stringValue)
    }

    @Test("invalid filter keeps last good rows without claiming they are watched")
    func invalidFilterPreservesRowsAndFreshness() async throws {
        let provider = FilterValidationWorkspaceResourceProvider()
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let freshness = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Resource freshness" })
        let filter = try #require(descendants(of: root)
            .compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
        let table = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil {
            freshness.stringValue == "Watching" && table.numberOfRows == 1
        }
        try triggerResourceFilterChange(
            in: try #require(controller.window),
            value: "unknown:value"
        )
        #expect(provider.streamRequestCount == 1)
        #expect(table.numberOfRows == 1)
        #expect(freshness.stringValue == "Filtering… · last good rows")
        try await waitUntil(timeout: .milliseconds(120)) {
            provider.cancelRequestCount == 1
        }
        try await waitUntil {
            provider.streamRequestCount == 2
                && descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
                    .contains("Unknown filter term unknown")
        }

        #expect(filter.stringValue == "unknown:value")
        #expect(table.numberOfRows == 1)
        #expect(freshness.stringValue == "Invalid filter · last good rows")
        #expect(freshness.accessibilityValue() == "Invalid filter · last good rows")
    }

    @Test("invalid initial filter never presents as loading or disconnected")
    func invalidInitialFilterHasLocalFreshnessState() async throws {
        let provider = FilterValidationWorkspaceResourceProvider(initialRequestIsInvalid: true)
        let restoration = ClusterWindowRestorationRecord(
            id: "invalid-initial-filter",
            state: ClusterWindowRestorationState(
                contextName: "test-context",
                gvr: GVR(group: "", version: "v1", resource: "pods"),
                namespaceScope: .all,
                filter: "unknown:value"
            )
        )
        let controller = makeWorkspace(
            provider: provider,
            restoration: restoration
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let freshness = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Resource freshness" })
        let filter = try #require(descendants(of: root)
            .compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil {
            freshness.stringValue == "Invalid filter"
                && descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
                    .contains("Unknown filter term unknown")
        }

        #expect(filter.stringValue == "unknown:value")
        #expect(freshness.accessibilityValue() == "Invalid filter")
    }
}

@MainActor
@Suite("Lazy workspace restoration", .serialized)
struct LazyWorkspaceRestorationTests {
    @Test("stalled authentication leaves a responsive metadata-only shell")
    func stalledAuthenticationShowsShellWithoutWorkspaceRequests() async throws {
        let provider = RecordingRestorationWorkspaceProvider()
        let record = restoredWorkspaceRecord()
        let shell = RestoredWorkspaceShell(record: record)
        let controller = makeWorkspace(
            session: shell.session,
            provider: provider,
            restoration: record,
            startsAuthenticated: false
        )
        let attempt = RestoredWorkspaceConnectionAttempt(
            provider: StallingRestorationContextProvider(),
            contextReference: record.state.contextReference
        )
        controller.showWindow(nil)
        attempt.start()
        defer {
            attempt.cancel()
            controller.close()
        }

        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let textValues = descendants(of: root).compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        let searchFields = descendants(of: root).compactMap { $0 as? NSSearchField }
        let resourceTable = descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" }
        #expect(window.isVisible)
        #expect(!controller.isAuthenticated)
        #expect(textValues.contains("Deployment"))
        #expect(searchFields.contains { $0.stringValue == "name:api" })
        #expect(resourceTable?.numberOfRows == 0)
        #expect(window.toolbar?.items.compactMap { $0.view as? NSPopUpButton }
            .first?.titleOfSelectedItem == "payments")
        let connectionItem = window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.connection"
        }
        #expect(connectionItem?.view?.accessibilityValue() as? String ==
            "Reconnecting…, Opening saved Kubernetes context…")

        try await Task.sleep(for: .milliseconds(40))
        #expect(provider.events.isEmpty)
    }

    @Test("authenticated discovery validates the saved GVR before streaming in the same window")
    func successfulAuthenticationRecoversSameWindowAfterDiscovery() async throws {
        let discoveryGate = RestorationDiscoveryGate()
        let provider = RecordingRestorationWorkspaceProvider(discoveryGates: [discoveryGate])
        let record = restoredWorkspaceRecord()
        let shell = RestoredWorkspaceShell(record: record)
        let controller = makeWorkspace(
            session: shell.session,
            provider: provider,
            restoration: record,
            startsAuthenticated: false
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let originalWindow = try #require(controller.window)
        #expect(provider.events.isEmpty)

        controller.recover(with: OpenedClusterSession(
            sessionID: "authenticated-session",
            contextName: "production",
            clusterName: "production-cluster",
            serverHostname: "api.production.example",
            defaultNamespace: "payments",
            contextReference: record.state.contextReference
        ))
        try await waitUntil { provider.discoverySessionIDs == ["authenticated-session"] }
        try triggerResourceFilterChange(in: originalWindow, value: "name:changed-before-discovery")
        try await Task.sleep(for: .milliseconds(240))
        #expect(provider.streamRequests.isEmpty)

        discoveryGate.open()
        try await waitUntil { provider.streamRequests.count == 1 }

        #expect(controller.window === originalWindow)
        #expect(controller.isAuthenticated)
        #expect(originalWindow.title.contains("production-cluster — production"))
        let clusterButton = try #require(originalWindow.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.cluster"
        }?.view as? NSButton)
        #expect(clusterButton.title == "production-cluster — production")
        #expect(provider.discoverySessionIDs == ["authenticated-session"])
        #expect(provider.streamRequests.count == 1)
        let request = try #require(provider.streamRequests.first)
        #expect(request.sessionID == "authenticated-session")
        #expect(request.resource.id == "apps/v1/deployments")
        #expect(request.filterExpression == "name:changed-before-discovery")
        #expect(provider.events.firstIndex(of: "discover:authenticated-session")! <
            provider.events.firstIndex(of: "stream:authenticated-session:apps/v1/deployments")!)
        #expect(!provider.events.contains { $0.contains("restoring-") })
    }

    @Test("helper restart ignores pre-restart discovery and revalidates the shell")
    func helperRestartDuringRestoredDiscoveryUsesOnlyNewSession() async throws {
        let oldGate = RestorationDiscoveryGate()
        let newGate = RestorationDiscoveryGate()
        let provider = RecordingRestorationWorkspaceProvider(
            discoveryGates: [oldGate, newGate]
        )
        let record = restoredWorkspaceRecord()
        let shell = RestoredWorkspaceShell(record: record)
        let controller = makeWorkspace(
            session: shell.session,
            provider: provider,
            restoration: record,
            startsAuthenticated: false
        )
        controller.showWindow(nil)
        defer {
            oldGate.open()
            newGate.open()
            controller.close()
        }

        controller.recover(with: authenticatedRestorationSession(
            for: record,
            sessionID: "pre-restart-session"
        ))
        try await waitUntil { provider.discoverySessionIDs == ["pre-restart-session"] }
        controller.engineDidDisconnect(message: "helper restarted")
        controller.recover(with: authenticatedRestorationSession(
            for: record,
            sessionID: "post-restart-session"
        ))
        try await waitUntil {
            provider.discoverySessionIDs == ["pre-restart-session", "post-restart-session"]
        }

        oldGate.open()
        try await Task.sleep(for: .milliseconds(80))
        #expect(provider.streamRequests.isEmpty)

        newGate.open()
        try await waitUntil { provider.streamRequests.count == 1 }
        #expect(provider.streamRequests.first?.sessionID == "post-restart-session")
        #expect(provider.streamRequests.first?.resource.id == "apps/v1/deployments")
        #expect(!provider.events.contains { $0.contains("restoring-") })
    }

    @Test("empty authenticated discovery never authorizes the saved target")
    func emptyDiscoveryKeepsZeroRowsWithoutStreamingSavedGVR() async throws {
        let provider = RecordingRestorationWorkspaceProvider(
            discoveryOutcome: .resources([])
        )
        let record = restoredWorkspaceRecord()
        let shell = RestoredWorkspaceShell(record: record)
        let controller = makeWorkspace(
            session: shell.session,
            provider: provider,
            restoration: record,
            startsAuthenticated: false
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)

        controller.recover(with: authenticatedRestorationSession(for: record))
        try await waitUntil { provider.discoveryFinished }
        try triggerResourceFilterChange(in: window, value: "name:after-empty-discovery")
        try await Task.sleep(for: .milliseconds(240))

        let table = descendants(of: try #require(window.contentView))
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" }
        #expect(table?.numberOfRows == 0)
        #expect(provider.streamRequests.isEmpty)
        #expect(provider.discoverySessionIDs == ["authenticated-session"])
        #expect(!provider.events.contains { $0.contains("restoring-") })
    }

    @Test("discovery error revokes the synthetic saved target")
    func discoveryErrorKeepsSavedGVRUnrequestable() async throws {
        let provider = RecordingRestorationWorkspaceProvider(
            discoveryOutcome: .failure(ClusterManagerIssue(
                category: .unavailable,
                reason: "DiscoveryFailed",
                message: "Discovery unavailable.",
                retryable: true,
                operation: "discover restored resources"
            ))
        )
        let record = restoredWorkspaceRecord()
        let shell = RestoredWorkspaceShell(record: record)
        let controller = makeWorkspace(
            session: shell.session,
            provider: provider,
            restoration: record,
            startsAuthenticated: false
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)

        controller.recover(with: authenticatedRestorationSession(for: record))
        try await waitUntil { provider.discoveryFinished }
        try triggerResourceFilterChange(in: window, value: "name:after-discovery-error")
        try await Task.sleep(for: .milliseconds(240))

        #expect(provider.streamRequests.isEmpty)
        #expect(provider.discoverySessionIDs == ["authenticated-session"])
        #expect(!provider.events.contains { $0.contains("restoring-") })
        let values = descendants(of: try #require(window.contentView))
            .compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(values.contains { $0.contains("Discovery unavailable") })
    }

    @Test("authentication failure keeps the same offline shell with no workspace requests")
    func failedAuthenticationKeepsOfflineShell() throws {
        let provider = RecordingRestorationWorkspaceProvider()
        let record = restoredWorkspaceRecord()
        let shell = RestoredWorkspaceShell(record: record)
        let controller = makeWorkspace(
            session: shell.session,
            provider: provider,
            restoration: record,
            startsAuthenticated: false
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let originalWindow = try #require(controller.window)

        controller.engineRecoveryFailed(ClusterManagerIssue(
            category: .authentication,
            reason: "Unauthorized",
            message: "Authentication failed (401).",
            retryable: false,
            operation: "open saved context"
        ))

        #expect(controller.window === originalWindow)
        #expect(originalWindow.isVisible)
        #expect(!controller.isAuthenticated)
        #expect(provider.events.isEmpty)
        let values = descendants(of: try #require(originalWindow.contentView))
            .compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(values.contains { $0.contains("Authentication failed (401).") })
        let connectionItem = originalWindow.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.connection"
        }
        #expect(connectionItem?.view?.accessibilityValue() as? String ==
            "Connection failed, Authentication failed (401).")
    }
}
}

@MainActor
private func makeWorkspace(
    session: OpenedClusterSession = OpenedClusterSession(
        sessionID: "test-session",
        contextName: "test-context",
        clusterName: "test-cluster",
        serverHostname: "example.invalid",
        defaultNamespace: "default"
    ),
    provider: any WorkspaceResourceProviding = NoopWorkspaceResourceProvider(),
    restoration: ClusterWindowRestorationRecord = ClusterWindowRestorationRecord(
        id: "toolbar-test",
        contextName: "test-context"
    ),
    startsAuthenticated: Bool = true
) -> ClusterWorkspaceWindowController {
    let portForwards = PortForwardCoordinator(provider: NoopPortForwardProvider())
    return ClusterWorkspaceWindowController(
        session: session,
        provider: provider,
        connectionActivityProvider: NoopConnectionActivityProvider(),
        optionalResourceCatalogProvider: NoopOptionalResourceCatalogProvider(),
        objectSearchProvider: NoopObjectSearchProvider(),
        objectDetailProvider: NoopToolbarObjectDetailProvider(),
        operationProvider: NoopOperationProvider(),
        logProvider: NoopLogProvider(),
        execProvider: NoopExecProvider(),
        portForwards: portForwards,
        columnsConfigurationPath: "/tmp/kmgr-toolbar-test-columns.yaml",
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
        restoration: restoration,
        startsAuthenticated: startsAuthenticated,
        onShowPortForwards: {}
    )
}

/// Shared construction boundary for focused multi-window AppKit tests. The
/// inert collaborators stay private to this file; callers provide only the
/// resource streams that their scenario needs to observe.
@MainActor
func makeColumnPropagationWorkspace(
    session: OpenedClusterSession,
    provider: any WorkspaceResourceProviding,
    optionalResourceCatalogProvider: any OptionalResourceCatalogProviding,
    columnsConfigurationPath: String
) -> ClusterWorkspaceWindowController {
    let portForwards = PortForwardCoordinator(provider: NoopPortForwardProvider())
    return ClusterWorkspaceWindowController(
        session: session,
        provider: provider,
        connectionActivityProvider: NoopConnectionActivityProvider(),
        optionalResourceCatalogProvider: optionalResourceCatalogProvider,
        objectSearchProvider: NoopObjectSearchProvider(),
        objectDetailProvider: NoopToolbarObjectDetailProvider(),
        operationProvider: NoopOperationProvider(),
        logProvider: NoopLogProvider(),
        execProvider: NoopExecProvider(),
        portForwards: portForwards,
        columnsConfigurationPath: columnsConfigurationPath,
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
        restoration: ClusterWindowRestorationRecord(
            id: "column-propagation-\(UUID().uuidString)",
            contextName: session.contextName,
            contextReference: session.contextReference
        ),
        onShowPortForwards: {}
    )
}

private func restoredWorkspaceRecord() -> ClusterWindowRestorationRecord {
    ClusterWindowRestorationRecord(
        id: "saved-production",
        state: ClusterWindowRestorationState(
            contextName: "production",
            contextReference: "/configs/production.yaml#production",
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceScope: .namespace("payments"),
            filter: "name:api"
        )
    )
}

private func authenticatedRestorationSession(
    for record: ClusterWindowRestorationRecord,
    sessionID: String = "authenticated-session"
) -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: sessionID,
        contextName: "production",
        clusterName: "production-cluster",
        serverHostname: "api.production.example",
        defaultNamespace: "payments",
        contextReference: record.state.contextReference
    )
}

private enum RestorationDiscoveryOutcome: Sendable {
    case resources([DiscoveredResource])
    case failure(ClusterManagerIssue)
}

private final class RestorationDiscoveryGate: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func wait() async {
        for await _ in stream { return }
    }

    func open() {
        continuation.yield(())
        continuation.finish()
    }
}

private final class RecordingRestorationWorkspaceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let discoveryOutcome: RestorationDiscoveryOutcome
    private let discoveryGates: [RestorationDiscoveryGate]
    private var discoveryCallCount = 0
    private var storedEvents: [String] = []
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(
        discoveryOutcome: RestorationDiscoveryOutcome = .resources([DiscoveredResource(
            group: "apps", version: "v1", resource: "deployments", kind: "Deployment",
            namespaced: true, verbs: ["list", "watch"]
        )]),
        discoveryGates: [RestorationDiscoveryGate] = []
    ) {
        self.discoveryOutcome = discoveryOutcome
        self.discoveryGates = discoveryGates
    }

    var events: [String] { lock.withLock { storedEvents } }
    var streamRequests: [ResourceViewRequest] { lock.withLock { storedStreamRequests } }
    var discoveryFinished: Bool {
        events.contains { $0.hasPrefix("discover-finished:") }
    }
    var discoverySessionIDs: [String] {
        events.compactMap { event in
            event.hasPrefix("discover:") ? String(event.dropFirst("discover:".count)) : nil
        }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        let gate = lock.withLock { () -> RestorationDiscoveryGate? in
            storedEvents.append("discover:\(sessionID)")
            defer { discoveryCallCount += 1 }
            return discoveryGates.indices.contains(discoveryCallCount)
                ? discoveryGates[discoveryCallCount]
                : nil
        }
        await gate?.wait()
        lock.withLock { storedEvents.append("discover-finished:\(sessionID)") }
        switch discoveryOutcome {
        case .resources(let resources): return .init(resources: resources)
        case .failure(let error): throw error
        }
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        lock.withLock { storedEvents.append("namespaces:\(sessionID)") }
        return ["payments"]
    }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        lock.withLock {
            storedEvents.append("stream:\(request.sessionID):\(request.resource.id)")
            storedStreamRequests.append(request)
        }
        return AsyncThrowingStream { $0.finish() }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {
        lock.withLock { storedEvents.append("cancel:\(sessionID)") }
    }

    func closeSession(sessionID: String) async {
        lock.withLock { storedEvents.append("close:\(sessionID)") }
    }
}

@MainActor
private func triggerResourceFilterChange(in window: NSWindow, value: String) throws {
    let root = try #require(window.contentView)
    let field = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
        .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
    field.stringValue = value
    field.delegate?.controlTextDidChange?(Notification(
        name: NSControl.textDidChangeNotification,
        object: field
    ))
}

private struct StallingRestorationContextProvider: ClusterContextProviding {
    func listContexts(reload: Bool) async throws -> [ClusterContextSummary] { [] }

    func openContext(reference: String) async throws -> OpenedClusterSession {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private struct HeaderStatusWorkspaceResourceProvider: WorkspaceResourceProviding {
    let statuses: [ResourceViewStatus]

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: [DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { continuation in
            for (index, status) in statuses.enumerated() {
                continuation.yield(.status(
                    cursor: StreamCursor(
                        generation: request.generation,
                        sequence: UInt64(index + 1)
                    ),
                    status: status
                ))
            }
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private final class FilterValidationWorkspaceResourceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let initialRequestIsInvalid: Bool
    private var storedStreamRequestCount = 0
    private var storedCancelRequestCount = 0

    init(initialRequestIsInvalid: Bool = false) {
        self.initialRequestIsInvalid = initialRequestIsInvalid
    }

    var streamRequestCount: Int { lock.withLock { storedStreamRequestCount } }
    var cancelRequestCount: Int { lock.withLock { storedCancelRequestCount } }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: [DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        let requestNumber = lock.withLock { () -> Int in
            storedStreamRequestCount += 1
            return storedStreamRequestCount
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 && !initialRequestIsInvalid {
                let identity = ResourceIdentity(
                    clusterSessionID: request.sessionID,
                    group: "", version: "v1", resource: "pods",
                    namespace: "default", name: "api", uid: "pod-api"
                )
                continuation.yield(.snapshot(
                    cursor: StreamCursor(generation: request.generation, sequence: 1),
                    chunk: ResourceSnapshotChunk(
                        rows: [ResourceRow(identity: identity, cells: [
                            Cell(
                                columnID: "name", displayText: "api",
                                typedValue: .string("api")
                            ),
                        ])],
                        first: true,
                        last: true,
                        index: 0,
                        estimatedTotalRows: 1
                    )
                ))
                continuation.yield(.status(
                    cursor: StreamCursor(generation: request.generation, sequence: 2),
                    status: ResourceViewStatus(
                        freshness: .watching,
                        rowsVisible: 1
                    )
                ))
            } else {
                continuation.finish(throwing: ClusterManagerIssue(
                    category: .validation,
                    reason: "InvalidFilter",
                    message: "Unknown filter term unknown",
                    operation: "compile resource filter"
                ))
                return
            }
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {
        lock.withLock { storedCancelRequestCount += 1 }
    }
    func closeSession(sessionID: String) async {}
}

private struct SelectAllFilterWorkspaceResourceProvider: WorkspaceResourceProviding {
    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: [DiscoveredResource(
            group: "", version: "v1", resource: "pods", kind: "Pod",
            namespaced: true, verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        let api = row(name: "api", uid: "pod-api", sessionID: request.sessionID)
        let worker = row(name: "worker", uid: "pod-worker", sessionID: request.sessionID)
        let rows = request.filterExpression.isEmpty ? [api, worker] : [api]
        return AsyncThrowingStream { continuation in
            continuation.yield(.snapshot(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                chunk: ResourceSnapshotChunk(
                    rows: rows,
                    first: true,
                    last: true,
                    index: 0,
                    estimatedTotalRows: UInt64(rows.count)
                )
            ))
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 2),
                status: ResourceViewStatus(
                    freshness: .watching,
                    rowsVisible: UInt64(rows.count)
                )
            ))
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}

    private func row(name: String, uid: ResourceUID, sessionID: String) -> ResourceRow {
        ResourceRow(
            identity: ResourceIdentity(
                clusterSessionID: sessionID,
                group: "", version: "v1", resource: "pods",
                namespace: "default", name: name, uid: uid
            ),
            cells: [Cell(
                columnID: "name",
                displayText: name,
                typedValue: .string(name)
            )]
        )
    }
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants(of:))
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitTestTimeout",
                message: "Timed out waiting for the resource freshness header.",
                operation: "test resource freshness header"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct NoopWorkspaceResourceProvider: WorkspaceResourceProviding {
    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult { .init(resources: []) }
    func listNamespaces(sessionID: String) async throws -> [String] { [] }
    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private struct NoopConnectionActivityProvider: ClusterConnectionActivityProviding {
    func watchConnectionActivity(sessionID: String, streamID: String)
        -> AsyncThrowingStream<ClusterConnectionActivitySample, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct NoopOptionalResourceCatalogProvider: OptionalResourceCatalogProviding {
    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog { throw CancellationError() }
}

private struct NoopObjectSearchProvider: ObjectSearchProviding {
    func searchCachedObjects(request: CachedObjectSearchRequest) async throws
        -> CachedObjectSearchResponse { throw CancellationError() }
    func searchObjects(request: ObjectSearchRequest)
        -> AsyncThrowingStream<ObjectSearchMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelSearch(
        sessionID: String, searchID: String, generation: UInt64, queryRevision: UInt64
    ) async {}
}

private struct NoopToolbarObjectDetailProvider: ObjectDetailProviding {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        throw CancellationError()
    }
    func watchObject(identity: ResourceIdentity, resourceVersion: String)
        -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent] { [] }
    func getRelationships(identity: ResourceIdentity, includeChildren: Bool) async throws
        -> ObjectRelationships { .init(values: [], childrenPotentiallyIncomplete: true) }
    func scanRelationships(identity: ResourceIdentity)
        -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelRelationshipScan(
        sessionID: String, scanID: String, generation: UInt64
    ) async {}
    func getData(identity: ResourceIdentity) async throws -> ObjectData {
        throw CancellationError()
    }
    func prepareYAML(
        identity: ResourceIdentity, yamlUTF8: Data,
        expectedResourceVersion: String, forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit { throw CancellationError() }
    func applyYAML(
        identity: ResourceIdentity, yamlUTF8: Data,
        expectedResourceVersion: String, forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
    func updateData(
        identity: ResourceIdentity, expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }
}

private struct NoopOperationProvider: ResourceOperationProviding {
    func deleteResources(targets: [ResourceDeleteTarget], options: ResourceDeleteOptions)
        async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func scaleResource(identity: ResourceIdentity, replicas: Int32, expectedResourceVersion: String)
        async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func rolloutRestart(identity: ResourceIdentity, expectedResourceVersion: String)
        async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func updateMetadata(
        identity: ResourceIdentity, expectedResourceVersion: String,
        changes: ResourceMetadataChanges
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> { throw CancellationError() }
    func cancelOperation(
        sessionID: String, operationID: String, cancelNotStartedOnly: Bool
    ) async throws {}
}

private struct NoopLogProvider: LogStreamProviding {
    func streamLogs(request: LogStreamRequest)
        -> AsyncThrowingStream<LogStreamMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelLogs(sessionID: String, streamID: String, generation: UInt64) async {}
}

private struct NoopExecProvider: ExecSessionProviding {
    func startExec(request: ExecSessionRequest) async throws -> any ExecSession {
        throw CancellationError()
    }
}

private struct NoopPortForwardProvider: PortForwardProviding {
    func listPortForwards(sessionID: String, includeStopped: Bool) async throws
        -> [PortForwardRecord] { [] }
    func watchPortForwards(request: PortForwardWatchRequest)
        -> AsyncThrowingStream<PortForwardWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func startPortForward(_ request: StartPortForwardRequest) async throws -> String {
        throw CancellationError()
    }
    func stopPortForward(id: String, sessionID: String) async throws {}
    func restartPortForward(id: String, sessionID: String) async throws {}
}
