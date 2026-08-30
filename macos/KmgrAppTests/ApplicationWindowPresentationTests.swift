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
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(
            preferencesStore: store,
            utilityWindowFrameCoordinator: UtilityWindowFrameCoordinator(
                store: UtilityWindowFrameStore(defaults: defaults)
            )
        )
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
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(
            preferencesStore: store,
            utilityWindowFrameCoordinator: UtilityWindowFrameCoordinator(
                store: UtilityWindowFrameStore(defaults: defaults)
            )
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
        let connectionTimeout = try field(
            "settings.performance.clusterConnectionTimeoutSeconds"
        )
        let requestTimeout = try field(
            "settings.performance.kubernetesRequestTimeoutSeconds"
        )
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
        let logQueueRecords = try field("settings.performance.logQueueRecordLimit")
        let logQueueMiB = try field("settings.performance.logQueueByteLimitMiB")
        #expect(globalMemory.integerValue == 20)
        #expect(overscan.integerValue == 10)
        #expect(viewReleaseGrace.integerValue == 3)
        #expect(authorityMemory.integerValue == 20)
        #expect(listPageSize.integerValue == 500)
        #expect(connectionTimeout.integerValue == 10)
        #expect(requestTimeout.integerValue == 30)
        #expect(idleProviders.integerValue == 8)
        #expect(idleSamples.integerValue == 100_000)
        #expect(exactEntries.integerValue == 100_000)
        #expect(exactSamples.integerValue == 100_000)
        #expect(exactDetails.integerValue == 256)
        #expect(exactConcurrency.integerValue == 16)
        #expect(logOpenConcurrency.integerValue == 16)
        #expect(logQueueRecords.integerValue == 4_096)
        #expect(logQueueMiB.integerValue == 8)
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
        connectionTimeout.stringValue = "45"
        requestTimeout.stringValue = "75"
        idleProviders.stringValue = "5"
        idleSamples.stringValue = "75000"
        exactEntries.stringValue = "80000"
        exactSamples.stringValue = "70000"
        exactDetails.stringValue = "128"
        exactConcurrency.stringValue = "12"
        logOpenConcurrency.stringValue = "9"
        logQueueRecords.stringValue = "8192"
        logQueueMiB.stringValue = "12"
        let apply = try #require(button(titled: "Apply", beneath: root))
        apply.performClick(nil)

        #expect(store.current.advancedPerformance.globalWarmCacheMemoryPercent == 30)
        #expect(store.current.advancedPerformance.viewportOverscanScreensPerSide == 17)
        #expect(store.current.advancedPerformance.viewReleaseGraceSeconds == 45)
        #expect(store.current.advancedPerformance.authorityWarmCacheMemoryPercent == 10)
        #expect(store.current.advancedPerformance.kubernetesQPS == 12.5)
        #expect(store.current.advancedPerformance.kubernetesBurst == 37)
        #expect(store.current.advancedPerformance.kubernetesListPageSize == 750)
        #expect(store.current.advancedPerformance.clusterConnectionTimeoutSeconds == 45)
        #expect(store.current.advancedPerformance.kubernetesRequestTimeoutSeconds == 75)
        #expect(store.current.advancedPerformance.idleMetricProviderLimit == 5)
        #expect(store.current.advancedPerformance.idleMetricSampleLimit == 75_000)
        #expect(store.current.advancedPerformance.exactPodMetricsEntryLimit == 80_000)
        #expect(store.current.advancedPerformance.exactPodMetricsSampleLimit == 70_000)
        #expect(store.current.advancedPerformance.exactPodMetricsDetailEntryLimit == 128)
        #expect(store.current.advancedPerformance.exactPodMetricsGETConcurrency == 12)
        #expect(store.current.advancedPerformance.logSourceOpenConcurrency == 9)
        #expect(store.current.advancedPerformance.logQueueRecordLimit == 8_192)
        #expect(store.current.advancedPerformance.logQueueByteLimit == 12 << 20)
    }

    @Test("log and diagnostic display limits persist from Settings")
    func displayAndDiagnosticSettings() throws {
        let suite = "kmgr-app-display-settings-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppPreferencesStore(defaults: defaults)
        let settings = SettingsWindowController(
            preferencesStore: store,
            utilityWindowFrameCoordinator: UtilityWindowFrameCoordinator(
                store: UtilityWindowFrameStore(defaults: defaults)
            )
        )
        let root = try #require(settings.window?.contentView)
        let fields = descendants(of: root).compactMap { $0 as? NSTextField }
        let lineLimit = try #require(fields.first {
            $0.accessibilityIdentifier() == "settings.logs.maximumDisplayedLineSize"
        })
        let renderedLimit = try #require(fields.first {
            $0.accessibilityIdentifier() == "settings.logs.maximumRenderedTextMiB"
        })
        let historyLimit = try #require(fields.first {
            $0.accessibilityIdentifier() ==
                "settings.diagnostics.completedOperationHistoryLimit"
        })
        let deleteConcurrency = try #require(fields.first {
            $0.accessibilityIdentifier() == "settings.operations.defaultDeleteConcurrency"
        })

        #expect(fields.contains { $0.stringValue == "Raw log buffer" })
        #expect(fields.contains { $0.stringValue == "Viewer text budget" })
        #expect(fields.contains { $0.stringValue == "Visible line limit" })
        #expect(fields.contains {
            $0.stringValue.contains("decoded, filtered text")
                && $0.stringValue.contains("cannot exceed that buffer")
        })
        #expect(lineLimit.stringValue == "16 KiB")
        #expect(renderedLimit.integerValue == 16)
        #expect(historyLimit.integerValue == 2_000)
        #expect(deleteConcurrency.integerValue == 4)
        lineLimit.stringValue = "256 B"
        renderedLimit.stringValue = "12"
        historyLimit.stringValue = "3500"
        deleteConcurrency.stringValue = "12"
        try #require(button(titled: "Apply", beneath: root)).performClick(nil)

        #expect(store.current.logs.maximumDisplayedLineUTF8Bytes == 256)
        #expect(store.current.logs.maximumRenderedUTF8Bytes == 12 << 20)
        #expect(store.current.diagnostics.completedOperationHistoryLimit == 3_500)
        #expect(store.current.resourceOperations.defaultDeleteConcurrency == 12)
    }

    @Test("Settings persists its geometry when reopened and recreated")
    func settingsFramePersistence() async throws {
        let suite = "kmgr-app-settings-utility-frame-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let utilityStore = UtilityWindowFrameStore(
            defaults: defaults,
            persistenceDelay: .seconds(60)
        )
        let visibleFrames = [NSRect(x: 0, y: 0, width: 1_600, height: 1_000)]
        let frameCoordinator = UtilityWindowFrameCoordinator(
            store: utilityStore,
            visibleFramesProvider: { visibleFrames },
            initialProtectionDelay: .milliseconds(1),
            initialProtectionSettleDelay: .milliseconds(1)
        )
        let first = SettingsWindowController(
            preferencesStore: AppPreferencesStore(defaults: defaults),
            utilityWindowFrameCoordinator: frameCoordinator
        )
        let firstWindow = try #require(first.window)
        first.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))

        let requested = NSRect(x: 140, y: 190, width: 1_000, height: 700)
        firstWindow.setFrame(requested, display: false)
        NotificationCenter.default.post(
            name: NSWindow.didMoveNotification,
            object: firstWindow
        )
        let saved = try #require(WorkspaceWindowFrame(appKitFrame: firstWindow.frame))
        #expect(utilityStore.frame(for: .settings) == saved)

        firstWindow.orderOut(nil)
        first.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(firstWindow.frame == saved.appKitFrame)

        first.close()
        let second = SettingsWindowController(
            preferencesStore: AppPreferencesStore(defaults: defaults),
            utilityWindowFrameCoordinator: frameCoordinator
        )
        second.showWindow(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(second.window?.frame == saved.appKitFrame)

        second.close()
        frameCoordinator.prepareForTermination()
        #expect(frameCoordinator.flushPendingSave())
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

    @Test("fresh workspaces share the global last size")
    func freshWorkspacesUseGlobalSize() throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-global-window-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let state = bookmarkState(filter: "name:remembered")
        let rememberedSize = ClusterWorkspaceWindowSize(width: 960, height: 640)

        let first = makeColumnPropagationWorkspace(
            session: bookmarkSession(),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: state,
            initialWindowFrameSize: rememberedSize
        )
        let second = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "bookmark-session-2"),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: state,
            initialWindowFrameSize: rememberedSize
        )
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        defer {
            first.close()
            second.close()
        }

        let visibleSize = NSScreen.main?.visibleFrame.size
        let expectedWidth = max(
            firstWindow.minSize.width,
            min(
                CGFloat(rememberedSize.width),
                visibleSize?.width ?? CGFloat(rememberedSize.width)
            )
        )
        let expectedHeight = max(
            firstWindow.minSize.height,
            min(
                CGFloat(rememberedSize.height),
                visibleSize?.height ?? CGFloat(rememberedSize.height)
            )
        )
        #expect(firstWindow.frame.size == secondWindow.frame.size)
        #expect(abs(firstWindow.frame.width - expectedWidth) < 0.5)
        #expect(abs(firstWindow.frame.height - expectedHeight) < 0.5)
    }

    @Test("restored workspaces keep each record's independent frame")
    func restoredWorkspacesKeepIndependentFrames() throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-independent-frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let visible = NSScreen.screens.last?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let frameA = NSRect(
            x: visible.minX + 20,
            y: visible.minY + 70,
            width: 860,
            height: 560
        )
        let frameB = NSRect(
            x: visible.minX + 210,
            y: visible.minY + 150,
            width: 980,
            height: 660
        )
        let recordA = ClusterWindowRestorationRecord(
            id: "restored-frame-a-\(UUID().uuidString)",
            state: bookmarkState(filter: "frame-a"),
            frame: WorkspaceWindowFrame(
                x: Double(frameA.minX),
                y: Double(frameA.minY),
                width: Double(frameA.width),
                height: Double(frameA.height)
            )
        )
        let recordB = ClusterWindowRestorationRecord(
            id: "restored-frame-b-\(UUID().uuidString)",
            state: bookmarkState(filter: "frame-b"),
            frame: WorkspaceWindowFrame(
                x: Double(frameB.minX),
                y: Double(frameB.minY),
                width: Double(frameB.width),
                height: Double(frameB.height)
            )
        )

        let first = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "restored-frame-session-a"),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("a.yaml").path,
            restoration: recordA,
            initialWindowFrameSize: ClusterWorkspaceWindowSize(width: 1_200, height: 800),
            placement: .restored,
            occupiedWindowFrames: []
        )
        let second = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "restored-frame-session-b"),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("b.yaml").path,
            restoration: recordB,
            initialWindowFrameSize: ClusterWorkspaceWindowSize(width: 1_200, height: 800),
            placement: .restored,
            occupiedWindowFrames: []
        )
        defer {
            first.window?.delegate = nil
            second.window?.delegate = nil
            first.close()
            second.close()
        }

        #expect(first.window?.frame.size == frameA.size)
        #expect(second.window?.frame.size == frameB.size)
        #expect(first.window?.frame.origin != second.window?.frame.origin)
        #expect(first.window?.frame != second.window?.frame)
    }

    @Test("an unreachable raw workspace frame uses a visible fallback")
    func unreachableRawWorkspaceFrameUsesVisibleFallback() throws {
        let visibleFrames = WorkspaceWindowPlacement.visibleFrames()
        guard !visibleFrames.isEmpty else { return }
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-offscreen-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let record = ClusterWindowRestorationRecord(
            id: "offscreen-frame-\(UUID().uuidString)",
            state: bookmarkState(filter: "offscreen"),
            frame: WorkspaceWindowFrame(
                x: 20_000,
                y: 20_000,
                width: 900,
                height: 600
            )
        )

        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "offscreen-frame-session"),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restoration: record,
            placement: .restored,
            occupiedWindowFrames: []
        )
        defer { controller.close() }

        let resolved = try #require(controller.window?.frame)
        #expect(resolved != NSRect(
            x: 20_000, y: 20_000, width: 900, height: 600
        ))
        #expect(WorkspaceWindowPlacement.isReachable(resolved, in: visibleFrames))
    }

    @Test("a same-context fresh workspace seeds its context frame bookmark")
    func freshSameContextWorkspaceUsesFrameBookmark() throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-context-frame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let suite = "kmgr-context-frame-store-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceFrameBookmarkStore(defaults: defaults)
        let contextReference = bookmarkSession().contextReference
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let rememberedFrame = NSRect(
            x: visible.minX + 90,
            y: visible.minY + 90,
            width: 900,
            height: 600
        )
        let rememberedRawFrame = WorkspaceWindowFrame(
            x: Double(rememberedFrame.minX),
            y: Double(rememberedFrame.minY),
            width: Double(rememberedFrame.width),
            height: Double(rememberedFrame.height)
        )
        let bookmark = try store.activate(
            contextReference: contextReference,
            sourceWindowID: "source-window",
            frame: rememberedRawFrame
        )

        let record = ClusterWindowRestorationRecord(
            id: "fresh-context-frame-\(UUID().uuidString)",
            state: bookmarkState(filter: "fresh")
        )
        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "fresh-context-frame-session"),
            provider: BookmarkWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restoration: record,
            placement: .contextBookmark(
                frame: bookmark.frame
            ),
            occupiedWindowFrames: []
        )
        defer {
            controller.window?.delegate = nil
            controller.close()
        }

        #expect(controller.window?.frame == rememberedFrame)
        #expect(controller.restorationRecord.frame == rememberedRawFrame)
        #expect(store.bookmark(for: contextReference) == bookmark)
    }

    @Test("saved navigation survives reload and seeds a same-context window")
    func savedNavigationSurvivesReloadAndSeedsNewWindow() async throws {
        let suite = "kmgr-app-navigation-restoration-\(UUID().uuidString)"
        let defaults = try #require(TestUserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-navigation-restoration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }

        let namespaceGate = BookmarkAsyncGate()
        let firstProvider = BookmarkNavigationWorkspaceProvider(
            namespaceGate: namespaceGate
        )
        let expected = ClusterWindowRestorationState(
            contextName: "shared",
            contextReference: bookmarkSession().contextReference,
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceScope: .namespace("team-a"),
            filter: "name:remembered"
        )
        let store = WorkspaceRestorationStore(defaults: defaults)
        let first = makeColumnPropagationWorkspace(
            session: bookmarkSession(),
            provider: firstProvider,
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: expected
        )
        first.onRestorationCheckpoint = { record in
            try? store.activate(record)
        }
        first.showWindow(nil)
        defer { first.close() }

        try await waitForBookmarkCondition {
            firstProvider.streamRequests.last.map {
                $0.resource.id == "apps/v1/deployments"
                    && !$0.allNamespaces
                    && $0.namespaces == ["team-a"]
                    && $0.filterExpression == "name:remembered"
            } == true
        }
        namespaceGate.open()
        let firstNamespaceControl = try #require(first.window?.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.namespace"
        }?.view as? NSPopUpButton)
        try await waitForBookmarkCondition {
            firstNamespaceControl.titleOfSelectedItem == "team-a"
        }

        let liveState = first.checkpointActiveWorkspace()
        #expect(liveState.gvr == expected.gvr)
        #expect(liveState.namespaceScope == expected.namespaceScope)
        #expect(liveState.filter == expected.filter)

        // A new store instance is the process-relaunch boundary. Both the
        // restorable window and the same-context starting state must contain
        // the live presentation, not the startup defaults.
        let reloaded = WorkspaceRestorationStore(defaults: defaults)
        #expect(reloaded.windows.contains { $0.state == liveState })
        let inherited = try #require(reloaded.lastState(
            for: bookmarkSession().contextReference
        ))
        #expect(inherited == liveState)

        let secondProvider = BookmarkNavigationWorkspaceProvider()
        let second = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "bookmark-session-2"),
            provider: secondProvider,
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: inherited
        )
        second.showWindow(nil)
        defer { second.close() }
        try await waitForBookmarkCondition {
            secondProvider.streamRequests.last.map {
                $0.resource.id == "apps/v1/deployments"
                    && !$0.allNamespaces
                    && $0.namespaces == ["team-a"]
                    && $0.filterExpression == "name:remembered"
            } == true
        }
        let secondNamespaceControl = try #require(second.window?.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.namespace"
        }?.view as? NSPopUpButton)
        try await waitForBookmarkCondition {
            secondNamespaceControl.titleOfSelectedItem == "team-a"
        }
    }

    @Test("pre-presentation activation cannot erase saved navigation")
    func activationBeforePresentationDoesNotCheckpointEmptyDefaults() async throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-pre-presentation-activation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let provider = BookmarkNavigationWorkspaceProvider()
        let expected = ClusterWindowRestorationState(
            contextName: "shared",
            contextReference: bookmarkSession().contextReference,
            gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
            namespaceScope: .namespace("team-a"),
            filter: "name:remembered"
        )
        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(),
            provider: provider,
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: expected
        )
        let window = try #require(controller.window)
        var checkpoints: [ClusterWindowRestorationRecord] = []
        controller.onRestorationCheckpoint = { checkpoints.append($0) }

        // This models the AppKit notification that a real application window
        // can deliver synchronously while it is first being presented.
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        controller.windowDidResignKey(Notification(
            name: NSWindow.didResignKeyNotification,
            object: window
        ))
        #expect(checkpoints.isEmpty)

        controller.showWindow(nil)
        defer {
            controller.onRestorationCheckpoint = nil
            controller.close()
        }
        try await waitForBookmarkCondition {
            provider.streamRequests.last.map {
                $0.resource.id == "apps/v1/deployments"
                    && !$0.allNamespaces
                    && $0.namespaces == ["team-a"]
                    && $0.filterExpression == "name:remembered"
            } == true
        }
        let liveState = controller.checkpointActiveWorkspace()
        #expect(liveState.gvr == expected.gvr)
        #expect(liveState.namespaceScope == expected.namespaceScope)
        #expect(liveState.filter == expected.filter)
    }

    @Test("initial activation repair restores the saved raw frame")
    func initialActivationRepairRestoresSavedRawFrame() async throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-initial-frame-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let visible = try #require(NSScreen.main?.visibleFrame)
        let target = NSRect(
            x: visible.minX + 80,
            y: visible.minY + 80,
            width: 900,
            height: 600
        )
        let provisional = target.offsetBy(dx: 240, dy: 120)
        let targetRawFrame = WorkspaceWindowFrame(
            x: Double(target.minX),
            y: Double(target.minY),
            width: Double(target.width),
            height: Double(target.height)
        )
        let record = ClusterWindowRestorationRecord(
            id: "initial-frame-repair-\(UUID().uuidString)",
            state: bookmarkState(filter: "initial-frame-repair"),
            frame: targetRawFrame
        )
        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "initial-frame-repair-session"),
            provider: BookmarkStalledWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restoration: record,
            placement: .restored,
            suppressInitialActivation: true,
            occupiedWindowFrames: []
        )
        let window = try #require(controller.window)
        var checkpoints: [ClusterWindowRestorationRecord] = []
        var frameCheckpoints: [ClusterWindowRestorationRecord] = []
        controller.onRestorationCheckpoint = { checkpoints.append($0) }
        controller.onFrameCheckpoint = { frameCheckpoints.append($0) }

        controller.showWindow(nil)
        checkpoints.removeAll(keepingCapacity: true)
        frameCheckpoints.removeAll(keepingCapacity: true)

        // Model AppKit's provisional move to the active launch display. The
        // restoration record must still expose the frame chosen before order.
        window.setFrame(provisional, display: false)
        controller.windowDidMove(Notification(
            name: NSWindow.didMoveNotification,
            object: window
        ))
        #expect(window.frame == target)
        controller.checkpointRestoration()
        #expect(controller.restorationRecord.frame == targetRawFrame)
        #expect(checkpoints.last?.frame == targetRawFrame)

        controller.completeInitialPresentation()
        controller.repairInitialPlacementAfterActivation()

        // A lifecycle checkpoint is not proof of user intent. If AppKit has
        // supplied another provisional frame just before Command-N or quit,
        // the saved target must remain authoritative.
        window.delegate = nil
        window.setFrame(provisional, display: false)
        window.delegate = controller
        _ = controller.checkpointActiveWorkspace()
        #expect(window.frame == target)
        #expect(controller.restorationRecord.frame == targetRawFrame)
        try await Task.sleep(for: .milliseconds(800))

        #expect(window.frame == target)
        #expect(controller.restorationRecord.frame == targetRawFrame)
        #expect(frameCheckpoints.last?.frame == targetRawFrame)

        controller.onRestorationCheckpoint = nil
        controller.onFrameCheckpoint = nil
        window.delegate = nil
        controller.close()
    }

    @Test("a user resize during initial placement remains authoritative")
    func userResizeDuringInitialPlacementIsPreserved() async throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-user-frame-change-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let visible = try #require(NSScreen.main?.visibleFrame)
        let target = NSRect(
            x: visible.minX + 80,
            y: visible.minY + 80,
            width: 900,
            height: 600
        )
        let targetRawFrame = WorkspaceWindowFrame(
            x: Double(target.minX),
            y: Double(target.minY),
            width: Double(target.width),
            height: Double(target.height)
        )
        let record = ClusterWindowRestorationRecord(
            id: "user-frame-change-\(UUID().uuidString)",
            state: bookmarkState(filter: "user-frame-change"),
            frame: targetRawFrame
        )
        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(sessionID: "user-frame-change-session"),
            provider: BookmarkStalledWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restoration: record,
            placement: .restored,
            suppressInitialActivation: true,
            occupiedWindowFrames: []
        )
        let window = try #require(controller.window)
        var frameCheckpoints: [ClusterWindowRestorationRecord] = []
        controller.onFrameCheckpoint = { frameCheckpoints.append($0) }

        controller.showWindow(nil)
        controller.completeInitialPresentation()
        controller.repairInitialPlacementAfterActivation()

        let userFrame = NSRect(
            x: target.minX + 37,
            y: target.minY - 29,
            width: target.width + 80,
            height: target.height + 40
        )
        // Set the frame without delivering the intermediate AppKit callbacks;
        // the explicit end-live-resize callback below models the user gesture.
        window.delegate = nil
        window.setFrame(userFrame, display: false)
        window.delegate = controller
        controller.windowDidEndLiveResize(Notification(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        ))
        let userRawFrame = WorkspaceWindowFrame(
            x: Double(userFrame.minX),
            y: Double(userFrame.minY),
            width: Double(userFrame.width),
            height: Double(userFrame.height)
        )

        #expect(controller.restorationRecord.frame == userRawFrame)
        // Allow the coalesced frame checkpoint to run after any automatic
        // move checkpoint queued by the initial presentation.
        try await Task.sleep(for: .milliseconds(600))
        #expect(frameCheckpoints.last?.frame == userRawFrame)
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.frame == userFrame)

        controller.onFrameCheckpoint = nil
        window.delegate = nil
        controller.close()
    }

    @Test("activation checkpoints exact context and global size changes debounce")
    func activationAndWindowSizeCheckpointPolicy() async throws {
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
        var checkpoints: [ClusterWindowRestorationRecord] = []
        var frameCheckpoints: [ClusterWindowRestorationRecord] = []
        var sizeCheckpoints: [ClusterWorkspaceWindowSize] = []
        controller.onRestorationCheckpoint = { checkpoints.append($0) }
        controller.onFrameCheckpoint = { frameCheckpoints.append($0) }
        controller.onWindowSizeCheckpoint = { sizeCheckpoints.append($0) }
        controller.showWindow(nil)
        window.orderOut(nil)
        checkpoints.removeAll(keepingCapacity: true)
        frameCheckpoints.removeAll(keepingCapacity: true)
        sizeCheckpoints.removeAll(keepingCapacity: true)

        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        #expect(checkpoints.count == 1)
        #expect(checkpoints.first?.state.contextReference == bookmarkSession().contextReference)
        #expect(checkpoints.first?.state.filter == "name:active")
        #expect(checkpoints.first?.frame != nil)
        #expect(sizeCheckpoints.count == 1)

        controller.windowDidResignKey(Notification(
            name: NSWindow.didResignKeyNotification,
            object: window
        ))
        #expect(checkpoints.last?.state.filter == "name:active")

        sizeCheckpoints.removeAll(keepingCapacity: true)
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        try await Task.sleep(for: .milliseconds(350))
        #expect(sizeCheckpoints.count == 1)
        #expect(abs((sizeCheckpoints.last?.width ?? 0) - window.frame.width) < 0.5)
        #expect(abs((sizeCheckpoints.last?.height ?? 0) - window.frame.height) < 0.5)

        let movedFrame = window.frame.offsetBy(dx: -37, dy: 29)
        window.setFrame(movedFrame, display: false)
        controller.windowDidMove(Notification(
            name: NSWindow.didMoveNotification,
            object: window
        ))
        try await Task.sleep(for: .milliseconds(350))
        let expectedFrame = WorkspaceWindowFrame(
            x: Double(window.frame.minX),
            y: Double(window.frame.minY),
            width: Double(window.frame.width),
            height: Double(window.frame.height)
        )
        #expect(checkpoints.last?.frame == expectedFrame)
        #expect(frameCheckpoints.last?.frame == expectedFrame)

        controller.onRestorationCheckpoint = nil
        controller.onFrameCheckpoint = nil
        controller.onWindowSizeCheckpoint = nil
        controller.close()
    }

    @Test("closed workspace ignores trailing restoration callbacks")
    func closedWorkspaceCannotRecreateItsRestoreRecord() throws {
        let columnsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-closed-workspace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: columnsDirectory) }
        let controller = makeColumnPropagationWorkspace(
            session: bookmarkSession(),
            provider: BookmarkStalledWorkspaceProvider(),
            optionalResourceCatalogProvider: BookmarkOptionalResourceProvider(),
            columnsConfigurationPath: columnsDirectory.appendingPathComponent("columns.yaml").path,
            restorationState: bookmarkState(filter: "name:closed")
        )
        let window = try #require(controller.window)
        var checkpoints: [ClusterWindowRestorationRecord] = []
        controller.onRestorationCheckpoint = { checkpoints.append($0) }
        controller.showWindow(nil)
        checkpoints.removeAll(keepingCapacity: true)
        #expect(controller.isOpenForRestoration)

        controller.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: window
        ))
        #expect(checkpoints.count == 1)
        #expect(!controller.isOpenForRestoration)

        controller.windowDidResignKey(Notification(
            name: NSWindow.didResignKeyNotification,
            object: window
        ))
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        #expect(checkpoints.count == 1)

        controller.onRestorationCheckpoint = nil
        window.delegate = nil
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

private final class BookmarkAsyncGate: @unchecked Sendable {
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

private final class BookmarkNavigationWorkspaceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let namespaceGate: BookmarkAsyncGate?
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(namespaceGate: BookmarkAsyncGate? = nil) {
        self.namespaceGate = namespaceGate
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [
            DiscoveredResource(
                group: "", version: "v1", resource: "pods", kind: "Pod",
                namespaced: true, verbs: ["list", "watch"]
            ),
            DiscoveredResource(
                group: "apps", version: "v1", resource: "deployments",
                kind: "Deployment", namespaced: true, verbs: ["list", "watch"]
            ),
        ])
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        await namespaceGate?.wait()
        return ["default", "team-a"]
    }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        lock.withLock { storedStreamRequests.append(request) }
        return AsyncThrowingStream { $0.finish() }
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

private struct BookmarkConditionTimeout: Error {}

@MainActor
private func waitForBookmarkCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if condition() { return }
    throw BookmarkConditionTimeout()
}
