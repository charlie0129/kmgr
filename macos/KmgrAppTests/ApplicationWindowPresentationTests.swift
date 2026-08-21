import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Application window presentation", .serialized)
struct ApplicationWindowPresentationTests {
    @Test("restoration setting is default-on and persists from Settings")
    func restorationSetting() throws {
        let suite = "kmgr-app-restoration-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(preferencesStore: store)
        let root = try #require(settings.window?.contentView)
        let restore = try #require(button(
            withAccessibilityIdentifier: "settings.restoreOpenClusterWindows",
            beneath: root
        ))

        #expect(restore.state == .on)
        restore.state = .off
        #expect(restore.state == .off)
        let apply = try #require(button(titled: "Apply", beneath: root))
        #expect(apply.isEnabled)
        apply.performClick(nil)

        #expect(!store.current.restoreOpenClusterWindows)
        #expect(!AppPreferencesStore(defaults: defaults).current.restoreOpenClusterWindows)
    }

    @Test("Advanced Performance exposes cache and Kubernetes engine tunables")
    func advancedPerformanceSettings() throws {
        let suite = "kmgr-app-performance-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(
            preferencesStore: store,
            frameAutosaveName: "Settings-performance-\(UUID().uuidString)"
        )
        let root = try #require(settings.window?.contentView)
        let fields = descendants(of: root).compactMap { $0 as? NSTextField }
        func field(_ identifier: String) throws -> NSTextField {
            try #require(fields.first { $0.accessibilityIdentifier() == identifier })
        }

        let globalMemory = try field(
            "settings.performance.globalWarmMemoryPercent"
        )
        let overscan = try field(
            "settings.performance.viewportOverscanScreensPerSide"
        )
        let viewReleaseGrace = try field(
            "settings.performance.viewReleaseGraceSeconds"
        )
        let authorityMemory = try field(
            "settings.performance.authorityWarmMemoryPercent"
        )
        let qps = try field("settings.performance.kubernetesQPS")
        let burst = try field("settings.performance.kubernetesBurst")
        let listPageSize = try field("settings.performance.kubernetesListPageSize")
        let idleProviders = try field("settings.performance.idleMetricProviders")
        let idleSamples = try field("settings.performance.idleMetricSamples")
        let exactEntries = try field("settings.performance.exactPodMetricsEntries")
        let exactSamples = try field("settings.performance.exactPodMetricsSamples")
        let exactDetails = try field("settings.performance.exactPodMetricsDetails")
        let exactConcurrency = try field(
            "settings.performance.exactPodMetricsGETConcurrency"
        )
        let logOpenConcurrency = try field(
            "settings.performance.logSourceOpenConcurrency"
        )
        #expect(globalMemory.integerValue == 20)
        #expect(overscan.integerValue == 10)
        #expect(viewReleaseGrace.integerValue == 3)
        #expect(authorityMemory.integerValue == 20)
        #expect(listPageSize.integerValue == 500)
        #expect(idleProviders.integerValue == 8)
        #expect(idleSamples.integerValue == 100_000)
        #expect(exactEntries.integerValue == 100_000)
        #expect(exactSamples.integerValue == 100_000)
        #expect(exactDetails.integerValue == 256)
        #expect(exactConcurrency.integerValue == 16)
        #expect(logOpenConcurrency.integerValue == 16)
        #expect(fields.first {
            $0.accessibilityIdentifier() == "settings.performance.relaunchWarning"
        }?.stringValue.contains("relaunching") == true)

        globalMemory.stringValue = "30"
        overscan.stringValue = "17"
        viewReleaseGrace.stringValue = "45"
        authorityMemory.stringValue = "10"
        qps.stringValue = "12.5"
        burst.stringValue = "37"
        listPageSize.stringValue = "750"
        idleProviders.stringValue = "5"
        idleSamples.stringValue = "75000"
        exactEntries.stringValue = "80000"
        exactSamples.stringValue = "70000"
        exactDetails.stringValue = "128"
        exactConcurrency.stringValue = "12"
        logOpenConcurrency.stringValue = "9"
        let apply = try #require(button(titled: "Apply", beneath: root))
        apply.performClick(nil)

        #expect(store.current.advancedPerformance.globalWarmCacheMemoryPercent == 30)
        #expect(store.current.advancedPerformance.viewportOverscanScreensPerSide == 17)
        #expect(store.current.advancedPerformance.viewReleaseGraceSeconds == 45)
        #expect(store.current.advancedPerformance.authorityWarmCacheMemoryPercent == 10)
        #expect(store.current.advancedPerformance.kubernetesQPS == 12.5)
        #expect(store.current.advancedPerformance.kubernetesBurst == 37)
        #expect(store.current.advancedPerformance.kubernetesListPageSize == 750)
        #expect(store.current.advancedPerformance.idleMetricProviderLimit == 5)
        #expect(store.current.advancedPerformance.idleMetricSampleLimit == 75_000)
        #expect(store.current.advancedPerformance.exactPodMetricsEntryLimit == 80_000)
        #expect(store.current.advancedPerformance.exactPodMetricsSampleLimit == 70_000)
        #expect(store.current.advancedPerformance.exactPodMetricsDetailEntryLimit == 128)
        #expect(store.current.advancedPerformance.exactPodMetricsGETConcurrency == 12)
        #expect(store.current.advancedPerformance.logSourceOpenConcurrency == 9)
    }

    @Test("log and diagnostic display limits persist from Settings")
    func displayAndDiagnosticSettings() throws {
        let suite = "kmgr-app-display-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(
            preferencesStore: store,
            frameAutosaveName: "Settings-display-\(UUID().uuidString)"
        )
        let root = try #require(settings.window?.contentView)
        let fields = descendants(of: root).compactMap { $0 as? NSTextField }
        let lineLimit = try #require(fields.first {
            $0.accessibilityIdentifier() == "settings.logs.maximumDisplayedLineKiB"
        })
        let historyLimit = try #require(fields.first {
            $0.accessibilityIdentifier() ==
                "settings.diagnostics.completedOperationHistoryLimit"
        })

        #expect(lineLimit.integerValue == 4)
        #expect(historyLimit.integerValue == 2_000)
        lineLimit.stringValue = "12"
        historyLimit.stringValue = "3500"
        try #require(button(titled: "Apply", beneath: root)).performClick(nil)

        #expect(store.current.logs.maximumDisplayedLineUTF8Bytes == 12 << 10)
        #expect(store.current.diagnostics.completedOperationHistoryLimit == 3_500)
    }

    @Test("Settings preserves its frame when reopened and when restored")
    func settingsFrameAutosaveIsNotOverriddenByCentering() throws {
        let preferencesSuite = "kmgr-app-settings-frame-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: preferencesSuite))
        defer { defaults.removePersistentDomain(forName: preferencesSuite) }
        let frameName = "Settings-test-\(UUID().uuidString)"
        NSWindow.removeFrame(usingName: frameName)
        defer { NSWindow.removeFrame(usingName: frameName) }

        let first = SettingsWindowController(
            preferencesStore: AppPreferencesStore(defaults: defaults),
            frameAutosaveName: frameName
        )
        let firstWindow = try #require(first.window)
        first.showWindow(nil)
        let movedFrame = firstWindow.frame.offsetBy(dx: 37, dy: -29)
        firstWindow.setFrame(movedFrame, display: false)
        firstWindow.orderOut(nil)

        first.showWindow(nil)
        #expect(firstWindow.frame == movedFrame)

        firstWindow.saveFrame(usingName: frameName)
        firstWindow.setFrameAutosaveName("")
        first.close()

        let restored = SettingsWindowController(
            preferencesStore: AppPreferencesStore(defaults: defaults),
            frameAutosaveName: frameName
        )
        let restoredWindow = try #require(restored.window)
        let frameBeforeFirstPresentation = restoredWindow.frame
        restored.showWindow(nil)
        defer {
            restoredWindow.setFrameAutosaveName("")
            restored.close()
        }

        #expect(restoredWindow.frame == frameBeforeFirstPresentation)
    }

    @Test("last workspace always returns to Cluster Manager")
    func lastWorkspaceClosePolicy() {
        #expect(policy().shouldPresentAfterWorkspaceClose)
        #expect(policy(independent: true).shouldPresentAfterWorkspaceClose)
        #expect(policy(forward: true).shouldPresentAfterWorkspaceClose)

        #expect(!policy(workspaces: 1, independent: true).shouldPresentAfterWorkspaceClose)
        #expect(!policy(chooser: true, independent: true).shouldPresentAfterWorkspaceClose)
        #expect(!policy(terminating: true, independent: true).shouldPresentAfterWorkspaceClose)
    }

    @Test("passive shortcut panel does not suppress application reopen")
    func passivePanelDoesNotCountForReopen() {
        #expect(ApplicationReopenPresentationPolicy(
            appKitHasVisibleWindows: true,
            hasVisibleReopenTarget: false,
            hasActivePortForward: false
        ).destination == .clusterManager)
        #expect(ApplicationReopenPresentationPolicy(
            appKitHasVisibleWindows: true,
            hasVisibleReopenTarget: false,
            hasActivePortForward: true
        ).destination == .portForwards)
        #expect(ApplicationReopenPresentationPolicy(
            appKitHasVisibleWindows: true,
            hasVisibleReopenTarget: true,
            hasActivePortForward: false
        ).destination == .none)
    }

    @Test("cluster chooser surfaces a workspace restoration load failure")
    func restorationLoadFailureNotice() throws {
        let provider = AnyClusterContextProvider(
            listContexts: { _ in [] },
            openContext: { _ in throw CancellationError() }
        )
        let controller = ClusterManagerWindowController(
            provider: provider,
            initialNotice: ClusterManagerInitialNotice(
                title: "Workspace restoration skipped",
                message: "Saved cluster windows use an unsupported version and will not be reopened."
            )
        )
        let root = try #require(controller.window?.contentView)
        let fields = descendants(of: root).compactMap { $0 as? NSTextField }

        #expect(fields.first {
            $0.identifier?.rawValue == "cluster-manager-issue-title"
        }?.stringValue == "Workspace restoration skipped")
        #expect(fields.first {
            $0.identifier?.rawValue == "cluster-manager-issue-message"
        }?.stringValue.contains("unsupported version") == true)
    }

    @Test("a fresh workspace copies the exact-context bookmark frame once")
    func freshWorkspaceSeedsIndependentFrame() throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-bookmark-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let bookmarkFrameName = "ClusterWorkspaceBookmark-test-\(UUID().uuidString)"
        NSWindow.removeFrame(usingName: bookmarkFrameName)
        defer { NSWindow.removeFrame(usingName: bookmarkFrameName) }
        let state = bookmarkState(filter: "name:remembered")

        let source = makeColumnPropagationWorkspace(
            session: bookmarkSession(),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: state
        )
        let sourceWindow = try #require(source.window)
        let rememberedFrame = sourceWindow.frame.offsetBy(dx: 43, dy: -31)
        sourceWindow.setFrame(rememberedFrame, display: false)
        sourceWindow.saveFrame(usingName: bookmarkFrameName)
        sourceWindow.setFrameAutosaveName("")
        source.close()

        let fresh = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "bookmark-session-2"),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: state,
            seedFrameAutosaveName: bookmarkFrameName
        )
        let freshWindow = try #require(fresh.window)
        defer {
            freshWindow.setFrameAutosaveName("")
            fresh.close()
        }

        #expect(freshWindow.frame == rememberedFrame)
        #expect(freshWindow.frameAutosaveName != bookmarkFrameName)
    }

    @Test("activation checkpoints carry exact context and frame changes debounce")
    func activationAndFrameCheckpointPolicy() async throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-bookmark-callbacks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(),
            provider: BookmarkStalledWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: bookmarkState(filter: "name:active")
        )
        let window = try #require(controller.window)
        var activations: [ClusterWindowRestorationRecord] = []
        var frameCheckpoints: [ClusterWindowRestorationRecord] = []
        controller.onActivationCheckpoint = { activations.append($0) }
        controller.onFrameCheckpoint = { frameCheckpoints.append($0) }
        controller.showWindow(nil)
        window.orderOut(nil)
        activations.removeAll(keepingCapacity: true)

        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        #expect(activations.count == 1)
        #expect(activations.first?.state.contextReference == bookmarkSession().contextReference)
        #expect(activations.first?.state.filter == "name:active")

        controller.windowDidMove(Notification(
            name: NSWindow.didMoveNotification,
            object: window
        ))
        controller.windowDidMove(Notification(
            name: NSWindow.didMoveNotification,
            object: window
        ))
        try await Task.sleep(for: .milliseconds(350))
        #expect(frameCheckpoints.count == 1)

        controller.onActivationCheckpoint = nil
        controller.onFrameCheckpoint = nil
        window.setFrameAutosaveName("")
        controller.close()
    }

    private func policy(
        terminating: Bool = false,
        workspaces: Int = 0,
        chooser: Bool = false,
        independent: Bool = false,
        forward: Bool = false
    ) -> ClusterManagerPresentationPolicy {
        ClusterManagerPresentationPolicy(
            isTerminating: terminating,
            remainingWorkspaceCount: workspaces,
            hasClusterManager: chooser,
            hasVisibleIndependentWindow: independent,
            hasActivePortForward: forward
        )
    }
}
}

private func bookmarkSession(
    sessionID: String = "bookmark-session"
) -> OpenedClusterSession {
    OpenedClusterSession(
        sessionID: sessionID,
        contextName: "shared",
        clusterName: "cluster",
        serverHostname: "example.invalid",
        defaultNamespace: "default",
        contextReference: "/configs/a.yaml#shared"
    )
}

private func bookmarkState(filter: String) -> ClusterWindowRestorationState {
    ClusterWindowRestorationState(
        contextName: "shared",
        contextReference: "/configs/a.yaml#shared",
        gvr: GVR(group: "", version: "v1", resource: "pods"),
        namespaceScope: .namespace("team-a"),
        filter: filter
    )
}

private struct BookmarkWorkspaceProvider: WorkspaceResourceProviding {
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

private struct BookmarkStalledWorkspaceProvider: WorkspaceResourceProviding {
    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        try await Task.sleep(for: .seconds(30))
        return .init(resources: [])
    }
    func listNamespaces(sessionID: String) async throws -> [String] { [] }
    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private struct BookmarkOptionalResourceProvider: OptionalResourceCatalogProviding {
    func discoverOptionalResources(_ request: OptionalResourceCatalogRequest) async throws
        -> OptionalResourceCatalog { throw CancellationError() }
}

@MainActor
private func button(
    withAccessibilityIdentifier identifier: String,
    beneath root: NSView
) -> NSButton? {
    descendants(of: root).compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
private func button(titled title: String, beneath root: NSView) -> NSButton? {
    descendants(of: root).compactMap { $0 as? NSButton }.first { $0.title == title }
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}
