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
        #expect(items.prefix(4).map(\.itemIdentifier.rawValue) == [
            "workspace.sidebar", "workspace.back", "workspace.forward",
            "workspace.namespace",
        ])
        for identifier in items.prefix(4).map(\.itemIdentifier.rawValue) {
            #expect(try #require(items.first {
                $0.itemIdentifier.rawValue == identifier
            }).isNavigational)
        }
        #expect(!items.contains { $0.itemIdentifier.rawValue == "workspace.cluster" })
        #expect(!items.contains { $0.itemIdentifier.rawValue == "workspace.connection" })
        #expect(items.firstIndex { $0.itemIdentifier == .flexibleSpace }
            == items.firstIndex {
                $0.itemIdentifier.rawValue == "workspace.namespace"
            }.map { $0 + 1 })
        #expect(items.suffix(4).map(\.itemIdentifier.rawValue) == [
            "workspace.palette", "workspace.operations", "workspace.forwards",
            "workspace.actions",
        ])
    }

    @Test("namespace picker returns keyboard focus to the resource list")
    func namespacePickerRestoresResourceListFocus() async throws {
        var didPresentPicker = false
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            namespacePickerPresenter: { control, _ in
                didPresentPicker = true
                control.sendAction(control.action, to: control.target)
            },
            namespacePickerKeyWindowCheck: { _ in true }
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { table.numberOfRows == 1 }
        #expect(window.makeFirstResponder(table))
        controller.chooseNamespace(nil)

        #expect(didPresentPicker)
        #expect(window.firstResponder === table)
    }

    @Test("namespace shortcut requires the active enabled sheet-free picker")
    func namespacePickerMenuValidationMatchesWindowState() async throws {
        var treatsWorkspaceAsKey = false
        let controller = makeWorkspace(
            namespacePickerKeyWindowCheck: { _ in treatsWorkspaceAsKey }
        )
        defer { controller.close() }
        let item = NSMenuItem(
            title: "Choose Namespace…",
            action: #selector(ClusterWorkspaceWindowController.chooseNamespace(_:)),
            keyEquivalent: ""
        )
        #expect(!controller.validateMenuItem(item))

        controller.showWindow(nil)
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        treatsWorkspaceAsKey = true
        #expect(controller.validateMenuItem(item))

        let picker = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.namespace"
        }?.view as? NSPopUpButton)
        picker.isEnabled = false
        #expect(!controller.validateMenuItem(item))
        picker.isEnabled = true

        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.beginSheet(sheet) { _ in }
        defer {
            if window.attachedSheet === sheet { window.endSheet(sheet) }
        }
        try await waitUntil { window.attachedSheet === sheet }
        #expect(!controller.validateMenuItem(item))
    }

    @Test("manual API discovery refresh retains the catalog and active GVR while loading")
    func APIResourceRefreshRetainsActiveView() async throws {
        let refreshGate = RestorationDiscoveryGate()
        let deployment = DiscoveredResource(
            group: "apps", version: "v1", resource: "deployments", kind: "Deployment",
            namespaced: true, verbs: ["list", "watch"]
        )
        let provider = DiscoveryRefreshWorkspaceProvider(
            outcomes: [
                .result(.init(resources: [deployment], revision: "initial")),
                .result(.init(resources: [
                    DiscoveredResource(
                        group: "apps", version: "v1", resource: "deployments",
                        kind: "Deployment", namespaced: true,
                        verbs: ["get", "list", "watch"], shortNames: ["deploy"]
                    ),
                    DiscoveredResource(
                        group: "example.io", version: "v1", resource: "widgets",
                        kind: "Widget", namespaced: true, verbs: ["list", "watch"]
                    ),
                ], revision: "refreshed")),
            ],
            gates: [1: refreshGate]
        )
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let refreshItem = NSMenuItem(
            title: "Refresh API Resources",
            action: #selector(ClusterWorkspaceWindowController.refreshAPIResources(_:)),
            keyEquivalent: ""
        )

        try await waitUntil {
            provider.finishedDiscoveryCount == 1 && provider.streamRequests.count == 1
        }
        #expect(controller.validateMenuItem(refreshItem))
        controller.refreshAPIResources(nil)
        try await waitUntil { provider.discoveryRefreshFlags == [false, true] }

        #expect(!controller.validateMenuItem(refreshItem))
        #expect(provider.streamRequests.count == 1)
        #expect(provider.namespaceRequestCount == 1)
        let outline = try #require(apiResourceOutline(in: window))
        #expect(outline.selectedRow >= 0)
        #expect(apiDiscoveryStatus(in: window)?.stringValue == "Refreshing API resources…")

        refreshGate.open()
        try await waitUntil { provider.finishedDiscoveryCount == 2 }
        #expect(controller.validateMenuItem(refreshItem))
        #expect(outline.selectedRow >= 0)
        #expect(provider.streamRequests.count == 1)
        #expect(provider.namespaceRequestCount == 1)
    }

    @Test("missing GVR after complete or partial discovery never opens a fallback resource")
    func APIResourceRefreshNeverNavigatesOnMissingGVR() async throws {
        for potentiallyIncomplete in [false, true] {
            let provider = DiscoveryRefreshWorkspaceProvider(outcomes: [
                .result(.init(resources: [DiscoveredResource(
                    group: "apps", version: "v1", resource: "deployments",
                    kind: "Deployment", namespaced: true, verbs: ["list", "watch"]
                )])),
                .result(.init(
                    resources: [DiscoveredResource(
                        group: "", version: "v1", resource: "pods", kind: "Pod",
                        namespaced: true, verbs: ["list", "watch"]
                    )],
                    potentiallyIncomplete: potentiallyIncomplete,
                    warning: potentiallyIncomplete ? ClusterManagerIssue(
                        category: .unavailable,
                        reason: "DiscoveryPartiallyFailed",
                        message: "One API group was unavailable.",
                        operation: "discover-resources"
                    ) : nil
                )),
            ])
            let controller = makeWorkspace(provider: provider)
            controller.showWindow(nil)
            let window = try #require(controller.window)
            try await waitUntil {
                provider.finishedDiscoveryCount == 1 && provider.streamRequests.count == 1
            }

            controller.refreshAPIResources(nil)
            try await waitUntil { provider.finishedDiscoveryCount == 2 }

            #expect(provider.streamRequests.count == 1)
            #expect(provider.streamRequests.first?.resource.id == "apps/v1/deployments")
            #expect(provider.namespaceRequestCount == 1)
            #expect(apiResourceOutline(in: window)?.selectedRow == -1)
            let status = apiDiscoveryStatus(in: window)?.stringValue ?? ""
            #expect(status.contains("discovery incomplete") == potentiallyIncomplete)
            controller.close()
        }
    }

    @Test("failed API discovery refresh keeps the previous catalog")
    func failedAPIResourceRefreshKeepsCatalog() async throws {
        let provider = DiscoveryRefreshWorkspaceProvider(outcomes: [
            .result(.init(resources: [DiscoveredResource(
                group: "apps", version: "v1", resource: "deployments", kind: "Deployment",
                namespaced: true, verbs: ["list", "watch"]
            )])),
            .failure(ClusterManagerIssue(
                category: .unavailable,
                reason: "DiscoveryUnavailable",
                message: "API discovery is unavailable.",
                retryable: true,
                operation: "discover-resources"
            )),
        ])
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        try await waitUntil {
            provider.finishedDiscoveryCount == 1 && provider.streamRequests.count == 1
        }

        controller.refreshAPIResources(nil)
        try await waitUntil { provider.finishedDiscoveryCount == 2 }

        #expect(apiResourceOutline(in: window)?.selectedRow ?? -1 >= 0)
        #expect(apiDiscoveryStatus(in: window)?.stringValue.contains("Refresh failed") == true)
        #expect(provider.streamRequests.count == 1)
        #expect(provider.namespaceRequestCount == 1)
    }

    @Test("connection activity stays compact, one-line, and accessible")
    func connectionActivityLabelsDoNotOverlap() throws {
        let view = ClusterConnectionActivityView()
        view.setState(.reconnecting, detail: "Retrying the Kubernetes API")
        view.update(rate: ClusterConnectionRate(
            bytesReceivedPerSecond: 12 * 1_024 * 1_024,
            bytesSentPerSecond: 3 * 1_024 * 1_024,
            receivedActive: true,
            sentActive: true
        ))
        view.frame.size = view.intrinsicContentSize
        view.layoutSubtreeIfNeeded()

        let labels = descendants(of: view).compactMap { $0 as? NSTextField }
        let state = try #require(labels.first { $0.stringValue == "Reconnecting…" })
        let rate = try #require(labels.first { $0.stringValue.hasPrefix("↑↓") })
        let stateFrame = view.convert(state.bounds, from: state)
        let rateFrame = view.convert(rate.bounds, from: rate)

        #expect(!stateFrame.intersects(rateFrame))
        #expect(rateFrame.minX - stateFrame.maxX >= 4)
        #expect(descendants(of: view).allSatisfy { type(of: $0) != NSView.self })
        #expect(!descendants(of: view).contains {
            $0.identifier?.rawValue == "connection-receive-indicator"
                || $0.identifier?.rawValue == "connection-send-indicator"
        })
        let presentation = rate.attributedStringValue
        let downArrow = (presentation.string as NSString).range(of: "↓").location
        let upArrow = (presentation.string as NSString).range(of: "↑").location
        #expect(downArrow != NSNotFound)
        #expect(upArrow != NSNotFound)
        let downColor = try #require(presentation.attribute(
            .foregroundColor,
            at: downArrow,
            effectiveRange: nil
        ) as? NSColor)
        let upColor = try #require(presentation.attribute(
            .foregroundColor,
            at: upArrow,
            effectiveRange: nil
        ) as? NSColor)
        #expect(downColor.isEqual(NSColor.systemGreen))
        #expect(upColor.isEqual(NSColor.systemRed))
        #expect(rate.maximumNumberOfLines == 1)
        #expect(view.intrinsicContentSize.height <= 20)
        let accessibilityValue = view.accessibilityValue() as? String
        #expect(accessibilityValue?.contains("Reconnecting…") == true)
        #expect(accessibilityValue?.contains("Retrying the Kubernetes API") == true)
        #expect(accessibilityValue?.contains("Aggregate 15 MiB/s") == true)
        #expect(accessibilityValue?.contains("download active") == true)
        #expect(accessibilityValue?.contains("upload active") == true)
        #expect(rate.accessibilityLabel() == "Kubernetes API transfer rate")
        #expect(view.accessibilityRole() == .group)
        #expect(view.accessibilityLabel() == "Kubernetes API connection status")
        #expect(view.gestureRecognizers.isEmpty)

        view.update(rate: ClusterConnectionRate(
            bytesReceivedPerSecond: Double(UInt64.max) * 2,
            receivedActive: true
        ))
        view.frame.size = NSSize(width: 176, height: view.intrinsicContentSize.height)
        view.layoutSubtreeIfNeeded()
        let boundedRateFrame = view.convert(rate.bounds, from: rate)
        #expect(rate.stringValue.hasSuffix("EiB/s"))
        #expect(boundedRateFrame.minX >= view.bounds.minX)
        #expect(boundedRateFrame.maxX <= view.bounds.maxX + 0.5)
    }

    @Test("connection arrows reflect each counter interval independently")
    func connectionArrowPresentationResets() async throws {
        let downloadView = ClusterConnectionActivityView()
        downloadView.update(rate: ClusterConnectionRate(
            bytesReceivedPerSecond: 1_024,
            bytesSentPerSecond: 0,
            receivedActive: true,
            sentActive: false
        ))
        let downloadRate = try #require(descendants(of: downloadView)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("↑↓") })
        var colors = try transferArrowColors(in: downloadRate)
        #expect(colors.download.isEqual(NSColor.systemGreen))
        #expect(colors.upload.isEqual(NSColor.secondaryLabelColor))

        let uploadView = ClusterConnectionActivityView()
        uploadView.update(rate: ClusterConnectionRate(
            bytesReceivedPerSecond: 0,
            bytesSentPerSecond: 2_048,
            receivedActive: false,
            sentActive: true
        ))
        let uploadRate = try #require(descendants(of: uploadView)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("↑↓") })
        colors = try transferArrowColors(in: uploadRate)
        #expect(colors.download.isEqual(NSColor.secondaryLabelColor))
        #expect(colors.upload.isEqual(NSColor.systemRed))

        downloadView.update(rate: ClusterConnectionRate())
        colors = try transferArrowColors(in: downloadRate)
        #expect(colors.download.isEqual(NSColor.secondaryLabelColor))
        #expect(colors.upload.isEqual(NSColor.secondaryLabelColor))
        #expect(downloadRate.stringValue == "↑↓ 0 B/s")
        let accessibilityValue = downloadView.accessibilityValue() as? String
        #expect(accessibilityValue?.contains("Aggregate 0 B/s") == true)
        #expect(accessibilityValue?.contains("download idle") == true)
    }

    @Test("connection activity sits at the far right of the persistent workspace status bar")
    func connectionActivityUsesWorkspaceFooter() throws {
        let controller = makeWorkspace()
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()

        let statusBar = try #require(descendants(of: root).first {
            $0.identifier?.rawValue == "workspace-status-bar"
        } as? NSStackView)
        let status = try #require(descendants(of: statusBar).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })
        let activity = try #require(descendants(of: statusBar).first {
            $0.identifier?.rawValue == "cluster-connection-activity"
        })
        statusBar.layoutSubtreeIfNeeded()
        let statusFrame = statusBar.convert(status.bounds, from: status)
        let activityFrame = statusBar.convert(activity.bounds, from: activity)

        #expect(statusFrame.maxX <= activityFrame.minX)
        #expect(abs(statusFrame.midY - activityFrame.midY) < 2)
        #expect(abs(activityFrame.maxX - statusBar.bounds.maxX) < 1)
        #expect(statusBar.fittingSize.height <= 24)
    }

    @Test("Operations toolbar button opens the live operation-history panel")
    func operationsToolbarButtonOpensOperationHistory() async throws {
        let record = ClusterOperationRecord(
            id: 7,
            state: .finished,
            operation: "LIST",
            resource: "pods",
            namespace: "default",
            httpStatusCode: 200,
            bytesReceived: 1_024,
            startedAtUnixNanos: 2_000_000_100,
            finishedAtUnixNanos: 3_000_000_100
        )
        let controller = makeWorkspace(
            operationHistoryProvider: StaticOperationHistoryProvider(completed: [record])
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let item = try #require(controller.window?.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.operations"
        })
        let action = try #require(item.action)

        #expect(item.label == "Operations")
        #expect(item.image != nil)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        try await waitUntil {
            NSApp.windows.contains { window in
                guard window.accessibilityLabel() == "Kubernetes API operation history",
                    let root = window.contentView
                else { return false }
                return descendants(of: root).compactMap { $0 as? NSTableView }
                    .first?.numberOfRows == 1
            }
        }
        let panel = try #require(NSApp.windows.first {
            $0.accessibilityLabel() == "Kubernetes API operation history"
        } as? NSPanel)
        #expect(panel.level == NSWindow.Level.floating)
        #expect(panel.isFloatingPanel)
    }

    @Test("warm-cache telemetry appears in the persistent workspace status bar")
    func warmCacheUsesWorkspaceFooter() async throws {
        let sample = ClusterConnectionActivitySample(
            cursor: StreamCursor(generation: 1, sequence: 1),
            state: .connected,
            observedAt: Date(),
            bytesReceived: 0,
            bytesSent: 0,
            authorityWarmCache: WarmCacheUsage(
                retainedViews: 2,
                retainedObjects: 300,
                retainedBytes: 180 << 20,
                evictableViews: 1,
                evictableObjects: 120,
                evictableBytes: 64 << 20,
                viewLimit: 8,
                objectLimit: 100_000,
                byteLimit: 4 << 30,
                budgetEvictions: 3
            ),
            globalWarmCache: WarmCacheUsage(
                retainedViews: 4,
                retainedObjects: 900,
                retainedBytes: 512 << 20,
                evictableViews: 2,
                evictableObjects: 320,
                evictableBytes: 128 << 20,
                viewLimit: 24,
                objectLimit: 250_000,
                byteLimit: 4 << 30,
                budgetEvictions: 5
            )
        )
        let controller = makeWorkspace(
            connectionActivityProvider: StaticConnectionActivityProvider(sample: sample)
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil {
            status.stringValue.contains("Cache 180 MiB")
        }
        #expect(status.stringValue.contains("global 512 MiB"))
        #expect(status.stringValue.contains("evictions 3/5"))
        #expect(status.toolTip?.contains("not process RSS") == true)
    }

    @Test("sidebar section material spans the full outline row")
    func sidebarSectionRowsHaveBackground() async throws {
        let controller = makeWorkspace(provider: FilterValidationWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let outline = try #require(descendants(of: root).compactMap { $0 as? NSOutlineView }
            .first { $0.accessibilityLabel() == "Kubernetes resource kinds" })

        try await waitUntil { outline.numberOfRows >= 2 }
        let sectionRow = try #require((0..<outline.numberOfRows).first { row in
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)?
                .identifier?.rawValue == "sidebar-section-cell"
        })
        let sectionCell = try #require(outline.view(
            atColumn: 0,
            row: sectionRow,
            makeIfNecessary: true
        ))
        let row = try #require(outline.rowView(atRow: sectionRow, makeIfNecessary: true))
        let background = try #require(descendants(of: row).compactMap { $0 as? NSVisualEffectView }
            .first { $0.identifier?.rawValue == "sidebar-section-background" })
        outline.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        let backgroundFrame = row.convert(background.bounds, from: background)
        let rowFrame = outline.convert(row.bounds, from: row)

        #expect(background.material == .sidebar)
        #expect(background.blendingMode == .withinWindow)
        #expect(background.state == .followsWindowActiveState)
        #expect(abs(backgroundFrame.minX - row.bounds.minX) < 1)
        #expect(abs(backgroundFrame.maxX - row.bounds.maxX) < 1)
        #expect(abs(rowFrame.minX - outline.bounds.minX) < 1)
        #expect(abs(rowFrame.maxX - outline.bounds.maxX) < 1)
        #expect(descendants(of: sectionCell).compactMap { ($0 as? NSTextField)?.stringValue }
            .contains { !$0.isEmpty })
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
        let status = try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Workspace status"
        })
        let progress = try #require(views.compactMap { $0 as? NSProgressIndicator }.first {
            $0.accessibilityLabel() == "Workspace operation in progress"
        })
        let columns = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.title == "Columns…"
        })
        let forwards = try #require(window.toolbar?.items.compactMap { $0.view as? NSButton }
            .first { $0.accessibilityLabel() == "Open app-wide Port Forwards" })

        #expect(window.title.contains("test-cluster — test-context"))
        #expect(window.subtitle == "example.invalid")
        #expect(window.toolbar?.items.contains {
            $0.itemIdentifier.rawValue == "workspace.cluster"
        } == false)
        #expect(outline.accessibilityRole() == .outline)
        #expect(outline.accessibilityLabel() == "Kubernetes resource kinds")
        #expect(table.accessibilityRole() == .table)
        #expect(table.allowsMultipleSelection)
        #expect(filter.accessibilityLabel() == "Filter Kubernetes resources")
        #expect(status.accessibilityLabel() == "Workspace status")
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

    @Test("resource filter grows with the content surface but remains bounded")
    func resourceFilterUsesBoundedProportionalWidth() throws {
        let controller = makeWorkspace()
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let filter = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
        let resourceRoot = try #require(filter.superview?.superview)

        window.setContentSize(NSSize(width: 980, height: 650))
        root.layoutSubtreeIfNeeded()
        let compactWidth = filter.frame.width

        window.setContentSize(NSSize(width: 1_440, height: 650))
        root.layoutSubtreeIfNeeded()
        let expandedWidth = filter.frame.width

        #expect(expandedWidth > compactWidth)
        #expect(expandedWidth <= 560.5)
        #expect(expandedWidth <= resourceRoot.bounds.width * 0.5 + 0.5)
    }

    @Test("resource filter exposes native grammar completions without preselection")
    func resourceFilterOffersUnselectedNativeCompletions() async throws {
        let provider = FilterValidationWorkspaceResourceProvider()
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let filter = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil { provider.streamRequestCount == 1 }
        let editor = NSTextView()
        editor.string = "n"
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let originalSelection = editor.selectedRange()
        var selectedIndex = 0
        let completions = withUnsafeMutablePointer(to: &selectedIndex) { pointer in
            filter.delegate?.control?(
                filter,
                textView: editor,
                completions: ["native-dictionary-word"],
                forPartialWordRange: editor.rangeForUserCompletion,
                indexOfSelectedItem: pointer
            ) ?? []
        }

        #expect(completions.prefix(3) == ["namespace:", "name:", "ns:"])
        #expect(selectedIndex == -1)
        #expect(editor.string == "n")
        #expect(editor.selectedRange() == originalSelection)
        #expect(filter.accessibilityHelp()?.contains("Suggestions are best effort") == true)
        #expect(filter.accessibilityHelp()?.contains("Return applies") == true)
    }

    @Test("field completion replaces only AppKit's relative partial word")
    func resourceFilterCompletesRelativeFieldPath() async throws {
        let provider = FilterValidationWorkspaceResourceProvider()
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let filter = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil { provider.streamRequestCount == 1 }
        let editor = NSTextView()
        editor.string = "field:metadata."
        editor.setSelectedRange(NSRange(
            location: (editor.string as NSString).length,
            length: 0
        ))
        let partialRange = editor.rangeForUserCompletion
        var selectedIndex = 37
        let completions = withUnsafeMutablePointer(to: &selectedIndex) { pointer in
            filter.delegate?.control?(
                filter,
                textView: editor,
                completions: [],
                forPartialWordRange: partialRange,
                indexOfSelectedItem: pointer
            ) ?? []
        }

        #expect(partialRange == NSRange(location: 6, length: 9))
        #expect(completions.first == "metadata.name")
        #expect(completions.contains("metadata.namespace"))
        #expect(completions.contains("status.phase") == false)
        #expect(selectedIndex == -1)
        #expect((editor.string as NSString).replacingCharacters(
            in: partialRange,
            with: try #require(completions.first)
        ) == "field:metadata.name")
        #expect(editor.string == "field:metadata.")
    }

    @Test("automatic completion trigger defers once per nonempty token")
    func resourceFilterCompletionTriggerIsBoundedByToken() {
        var deferred: [ResourceFilterCompletionTrigger.DeferredAction] = []
        var presented: [String] = []
        let trigger = ResourceFilterCompletionTrigger(
            deferAction: { deferred.append($0) },
            present: { presented.append($0.string) }
        )
        let editor = NSTextView()
        let isCurrentEditor: @MainActor (NSTextView) -> Bool = { $0 === editor }
        let hasCandidates: @MainActor (NSTextView) -> Bool = { _ in true }

        editor.string = "n"
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: isCurrentEditor,
            hasCandidates: hasCandidates
        )
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: isCurrentEditor,
            hasCandidates: hasCandidates
        )
        #expect(deferred.count == 1)
        #expect(presented.isEmpty)
        deferred.removeFirst()()
        #expect(presented == ["n"])

        editor.string = "na"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: isCurrentEditor,
            hasCandidates: hasCandidates
        )
        #expect(deferred.isEmpty)

        editor.string = "na "
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: isCurrentEditor,
            hasCandidates: hasCandidates
        )
        editor.string = "na f"
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: isCurrentEditor,
            hasCandidates: hasCandidates
        )
        #expect(deferred.count == 1)
        deferred.removeFirst()()
        #expect(presented == ["n", "na f"])
    }

    @Test("automatic completion trigger revalidates editor state after deferral")
    func resourceFilterCompletionTriggerRejectsStalePresentation() {
        var deferred: [ResourceFilterCompletionTrigger.DeferredAction] = []
        var presentationCount = 0
        let trigger = ResourceFilterCompletionTrigger(
            deferAction: { deferred.append($0) },
            present: { _ in presentationCount += 1 }
        )
        let editor = NSTextView()
        editor.string = "n"
        editor.setSelectedRange(NSRange(location: 1, length: 0))

        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: { _ in false },
            hasCandidates: { _ in true }
        )
        #expect(deferred.count == 1)
        deferred.removeFirst()()
        #expect(presentationCount == 0)

        editor.setSelectedRange(NSRange(location: 0, length: 1))
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: { _ in true },
            hasCandidates: { _ in true }
        )
        #expect(deferred.isEmpty)

        editor.setSelectedRange(NSRange(location: 1, length: 0))
        trigger.textDidChange(
            editor: editor,
            isCurrentEditor: { _ in true },
            hasCandidates: { _ in true }
        )
        #expect(deferred.count == 1)
        trigger.reset()
        deferred.removeFirst()()
        #expect(presentationCount == 0)
    }

    @Test("Return applies a pending resource filter and restores table focus")
    func returnAppliesResourceFilterImmediately() async throws {
        let provider = FilterValidationWorkspaceResourceProvider()
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let filter = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil { provider.streamRequestCount == 1 && table.numberOfRows == 1 }
        controller.focusResourceFilter(nil)
        filter.stringValue = "name:api"
        filter.delegate?.controlTextDidChange?(Notification(
            name: NSControl.textDidChangeNotification,
            object: filter
        ))
        #expect(provider.streamRequestCount == 1)

        let handled = filter.delegate?.control?(
            filter,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled == true)
        #expect(window.firstResponder === table)
        try await waitUntil(timeout: .milliseconds(120)) {
            provider.streamRequestCount == 2
        }
    }

    @Test("native relationship selectors survive filter commits without intermediate streams")
    func nativeSelectorsSurviveCommittedFilter() async throws {
        let provider = FilterValidationWorkspaceResourceProvider()
        let restoration = ClusterWindowRestorationRecord(
            id: "native-selector-filter",
            state: ClusterWindowRestorationState(
                contextName: "test-context",
                gvr: GVR(group: "", version: "v1", resource: "pods"),
                namespaceScope: .namespace("default"),
                labelSelector: "app in (api,worker),!retired",
                fieldSelector: "metadata.namespace=default"
            )
        )
        let controller = makeWorkspace(provider: provider, restoration: restoration)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let field = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil { provider.streamRequestCount == 1 }
        try triggerResourceFilterChange(in: window, value: "status:Running")
        try await Task.sleep(for: .milliseconds(250))
        #expect(provider.streamRequestCount == 1)

        let handled = field.delegate?.control?(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled == true)
        try await waitUntil(timeout: .milliseconds(120)) {
            provider.streamRequestCount == 2
        }
        let requests = provider.streamRequests
        #expect(requests.map(\.labelSelector) == [
            "app in (api,worker),!retired",
            "app in (api,worker),!retired",
        ])
        #expect(requests.map(\.fieldSelector) == [
            "metadata.namespace=default",
            "metadata.namespace=default",
        ])
        #expect(requests.last?.filterExpression == "status:Running")
    }

    @Test("stable filter debounce retains native relationship selectors")
    func nativeSelectorsSurviveStableFilterDebounce() async throws {
        let provider = FilterValidationWorkspaceResourceProvider()
        let controller = makeWorkspace(
            provider: provider,
            restoration: ClusterWindowRestorationRecord(
                id: "native-selector-debounce",
                state: ClusterWindowRestorationState(
                    contextName: "test-context",
                    gvr: GVR(group: "", version: "v1", resource: "pods"),
                    labelSelector: "app=api"
                )
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)

        try await waitUntil { provider.streamRequestCount == 1 }
        try triggerResourceFilterChange(in: window, value: "label:tier==frontend")
        try await Task.sleep(for: .milliseconds(300))
        #expect(provider.streamRequestCount == 1)
        try await waitUntil(timeout: .seconds(1)) {
            provider.streamRequestCount == 2
        }
        #expect(provider.streamRequests.last?.labelSelector == "app=api")
        #expect(provider.streamRequests.last?.filterExpression == "label:tier==frontend")
    }

    @Test("contextual help follows explicit filter focus begin and end")
    func contextualHelpTracksFilterFocus() async throws {
        let controller = makeWorkspace(provider: FilterValidationWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let filter = try #require(descendants(of: root).compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        try await waitUntil {
            controller.contextualShortcutSnapshot?.contextID == "resource-list"
                && controller.contextualShortcutSnapshot?.items.map(\.keys)
                    .contains("L") == true
        }

        controller.focusResourceFilter(nil)
        #expect(controller.contextualShortcutSnapshot == ContextualShortcutCatalog.resourceFilter)

        let handled = filter.delegate?.control?(
            filter,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled == true)
        #expect(window.firstResponder === table)
        #expect(controller.contextualShortcutSnapshot?.contextID == "resource-list")
    }

    @Test("Return on a Pod replaces the resource table with its container list")
    func returnEntersPodContainers() async throws {
        let pod = ResourceIdentity(
            clusterSessionID: "test-session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "default",
            name: "api",
            uid: "pod-api"
        )
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: pod,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "containers",
                    fieldID: "container:api",
                    label: "Container",
                    displayText: "api"
                )],
                containers: [PodContainerDetail(name: "api", kind: .regular)]
            ))
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { resourceTable.numberOfRows == 1 }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)

        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }
        let containerTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Pod containers" })
        #expect(containerTable.numberOfRows == 1)
        #expect(containerTable.tableColumns.map(\.title) == [
            "Container", "Type", "Status", "Ready", "Restarts", "CPU", "Memory", "Ports",
        ])
        #expect(controller.contextualShortcutSnapshot?.contextID == "pod-containers")
    }

    @Test("Return on ConfigMaps and Secrets opens Data with one GET and no Details GET")
    func returnOpensCanonicalDataDirectly() async throws {
        for resource in ["configmaps", "secrets"] {
            let identity = ResourceIdentity(
                clusterSessionID: "test-session",
                group: "",
                version: "v1",
                resource: resource,
                namespace: "default",
                name: "settings",
                uid: ResourceUID("\(resource)-settings")
            )
            let resourceProvider = SingleObjectWorkspaceResourceProvider(
                identity: identity,
                kind: resource == "secrets" ? "Secret" : "ConfigMap"
            )
            let detailProvider = TrackingDataObjectDetailProvider(data: ObjectData(
                identity: identity,
                resourceVersion: "rv-1",
                entries: [],
                secret: resource == "secrets"
            ))
            let controller = makeWorkspace(
                provider: resourceProvider,
                objectDetailProvider: detailProvider,
                restoration: ClusterWindowRestorationRecord(
                    id: "direct-data-\(resource)",
                    state: ClusterWindowRestorationState(
                        contextName: "test-context",
                        gvr: GVR(group: "", version: "v1", resource: resource),
                        namespaceScope: .namespace("default")
                    )
                )
            )
            controller.showWindow(nil)
            do {
                let window = try #require(controller.window)
                let root = try #require(window.contentView)
                let resourceTable = try #require(descendants(of: root)
                    .compactMap { $0 as? NSTableView }
                    .first { $0.accessibilityLabel() == "Kubernetes resources" })
                try await waitUntil { resourceTable.numberOfRows == 1 }
                try await selectResourceRow(0, in: resourceTable)
                #expect(window.makeFirstResponder(resourceTable))
                controller.enterResource(nil)

                try await waitUntil {
                    descendants(of: root).compactMap { $0 as? NSButton }
                        .contains { $0.title == "Add Key" && $0.isEnabled }
                }
                let dataTable = try #require(descendants(of: root)
                    .compactMap { $0 as? NSTableView }
                    .first {
                        $0.accessibilityLabel()
                            == "ConfigMap or Secret data keys and values"
                    })
                #expect(dataTable.numberOfRows == 0)
                #expect(await detailProvider.dataCallCount() == 1)
                #expect(await detailProvider.objectCallCount() == 0)
                #expect(await detailProvider.requestedIdentities() == [identity])
            } catch {
                controller.close()
                throw error
            }
            controller.close()
        }
    }

    @Test("Forward restoration of Data fetches Data directly again")
    func forwardRestoresDataWithoutDetails() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "test-session",
            group: "",
            version: "v1",
            resource: "configmaps",
            namespace: "default",
            name: "settings",
            uid: "configmap-settings"
        )
        let resourceProvider = SingleObjectWorkspaceResourceProvider(
            identity: identity,
            kind: "ConfigMap"
        )
        let value = Data("enabled: true\n".utf8)
        let detailProvider = TrackingDataObjectDetailProvider(data: ObjectData(
            identity: identity,
            resourceVersion: "rv-1",
            entries: [ObjectDataEntry(
                key: "settings.yaml",
                kind: .text,
                value: value,
                byteSize: UInt64(value.count),
                contentHash: Data(repeating: 4, count: 32)
            )],
            secret: false
        ))
        let controller = makeWorkspace(
            provider: resourceProvider,
            objectDetailProvider: detailProvider,
            restoration: ClusterWindowRestorationRecord(
                id: "forward-data",
                state: ClusterWindowRestorationState(
                    contextName: "test-context",
                    gvr: GVR(group: "", version: "v1", resource: "configmaps"),
                    namespaceScope: .namespace("default")
                )
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { resourceTable.numberOfRows == 1 }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntilAsync { await detailProvider.dataCallCount() == 1 }

        controller.navigateBack(nil)
        try await waitUntil { resourceTable.window === window }
        controller.navigateForward(nil)
        try await waitUntilAsync { await detailProvider.dataCallCount() == 2 }
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTextView }
                .contains { $0.string == "enabled: true\n" }
        }

        #expect(await detailProvider.objectCallCount() == 0)
        #expect(await detailProvider.requestedIdentities() == [identity, identity])
    }

    @Test("Back keeps a large Pod list visible through a cold resume placeholder")
    func backRetainsWarmPodRowsUntilAuthoritativeReconciliation() async throws {
        let provider = DelayedWarmResumeWorkspaceResourceProvider(rowCount: 993)
        let pod = provider.firstIdentity
        let controller = makeWorkspace(
            provider: provider,
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: pod,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "containers",
                    fieldID: "container:api",
                    label: "Container",
                    displayText: "api"
                )],
                containers: [PodContainerDetail(name: "api", kind: .regular)]
            ))
        )
        controller.showWindow(nil)
        defer {
            provider.finish()
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let statusLine = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil {
            provider.streamRequestCount == 1
                && resourceTable.numberOfRows == 993
                && statusLine.stringValue.hasSuffix(" · Watching")
                && statusLine.stringValue.hasPrefix("993 objects")
        }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }

        controller.navigateBack(nil)
        try await waitUntil {
            provider.streamRequestCount == 2
                && resourceTable.numberOfRows == 993
                && statusLine.stringValue.contains("Resuming…")
                && statusLine.stringValue.hasPrefix("993 objects")
        }
        #expect(!statusLine.stringValue.hasSuffix(" · Loading…"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(resourceTable.numberOfRows == 993)

        provider.releasePartialRows()
        try await Task.sleep(for: .milliseconds(100))
        #expect(resourceTable.numberOfRows == 993)
        #expect(statusLine.stringValue.contains("Resuming…"))

        provider.releaseAuthoritativeRows()
        try await waitUntil {
            resourceTable.numberOfRows == 993
                && statusLine.stringValue.hasSuffix(" · Watching")
                && statusLine.stringValue.hasPrefix("993 objects")
        }

        provider.removeAllRows()
        try await waitUntil {
            resourceTable.numberOfRows == 0
                && statusLine.stringValue.hasSuffix(" · Watching")
                && statusLine.stringValue.hasPrefix("0 objects")
        }
    }

    @Test("Back progressively resumes an interrupted partial Pod listing")
    func backProgressivelyResumesInterruptedPartialPodListing() async throws {
        let provider = InterruptedPartialResumeWorkspaceResourceProvider(
            initialRowCount: 3,
            resumedRowCount: 5,
            finalRowCount: 8
        )
        let pod = provider.firstIdentity
        let controller = makeWorkspace(
            provider: provider,
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: pod,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "containers",
                    fieldID: "container:api",
                    label: "Container",
                    displayText: "api"
                )],
                containers: [PodContainerDetail(name: "api", kind: .regular)]
            ))
        )
        controller.showWindow(nil)
        defer {
            provider.finish()
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let statusLine = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil {
            provider.streamRequestCount == 1
                && resourceTable.numberOfRows == 3
                && statusLine.stringValue.contains("Relisting…")
        }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }

        controller.navigateBack(nil)
        try await waitUntil {
            provider.streamRequestCount == 2
                && resourceTable.numberOfRows == 0
                && statusLine.stringValue.hasSuffix(" · Loading…")
        }

        provider.releaseResumedRows()
        try await waitUntil {
            resourceTable.numberOfRows == 5
                && statusLine.stringValue.hasPrefix("5 objects")
                && statusLine.stringValue.contains("Relisting…")
        }

        provider.releaseAuthoritativeRows()
        try await waitUntil {
            resourceTable.numberOfRows == 8
                && statusLine.stringValue.hasPrefix("8 objects")
                && statusLine.stringValue.hasSuffix(" · Watching")
        }
    }

    @Test("Back atomically clears cached Pods only after an authoritative empty result")
    func backPromotesAuthoritativeEmptyPodReconciliation() async throws {
        let provider = DelayedWarmResumeWorkspaceResourceProvider(rowCount: 3)
        let pod = provider.firstIdentity
        let controller = makeWorkspace(
            provider: provider,
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: pod,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "containers",
                    fieldID: "container:api",
                    label: "Container",
                    displayText: "api"
                )],
                containers: [PodContainerDetail(name: "api", kind: .regular)]
            ))
        )
        controller.showWindow(nil)
        defer {
            provider.finish()
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let statusLine = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil {
            provider.streamRequestCount == 1
                && resourceTable.numberOfRows == 3
        }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }

        controller.navigateBack(nil)
        try await waitUntil {
            provider.streamRequestCount == 2
                && resourceTable.numberOfRows == 3
                && statusLine.stringValue.contains("Resuming…")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(resourceTable.numberOfRows == 3)

        provider.releaseAuthoritativeEmpty()
        try await waitUntil {
            resourceTable.numberOfRows == 0
                && statusLine.stringValue.hasSuffix(" · Watching")
        }
    }

    @Test("Back preserves UID selection across warm snapshot and catch-up delta")
    func backPreservesSelectionAcrossWarmSnapshotCatchup() async throws {
        let provider = WarmResumeSelectionWorkspaceResourceProvider(rowCount: 993)
        let pod = provider.firstIdentity
        let controller = makeWorkspace(
            provider: provider,
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: pod,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "containers",
                    fieldID: "container:api",
                    label: "Container",
                    displayText: "api"
                )],
                containers: [PodContainerDetail(name: "api", kind: .regular)]
            ))
        )
        controller.showWindow(nil)
        defer {
            provider.finish()
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let statusLine = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil {
            provider.streamRequestCount == 1
                && resourceTable.numberOfRows == 993
                && statusLine.stringValue.hasSuffix(" · Watching")
                && statusLine.stringValue.hasPrefix("993 objects")
        }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }

        controller.navigateBack(nil)
        try await waitUntil {
            provider.streamRequestCount == 2
                && resourceTable.numberOfRows == 993
                && !statusLine.stringValue.hasSuffix(" · Loading…")
                && statusLine.stringValue.hasPrefix("993 objects")
                && statusLine.stringValue.contains("1 selected")
        }
        #expect(resourceTable.selectedRowIndexes == IndexSet(integer: 0))

        // Runtime seals the warm snapshot first, then emits the full same-UID
        // base/metrics catch-up as an ordered delta.
        provider.releaseAuthoritativeRows()
        try await waitUntil {
            resourceTable.numberOfRows == 993
                && statusLine.stringValue.hasSuffix(" · Watching")
                && statusLine.stringValue.hasPrefix("993 objects")
                && statusLine.stringValue.contains("1 selected")
        }
        #expect(resourceTable.selectedRowIndexes == IndexSet(integer: 0))
    }

    @Test("S opens automatic Pod terminal while Shift-S opens configuration")
    func podTerminalShortcutsHaveDistinctLaunchPaths() async throws {
        let pod = toolbarPodIdentity()
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: toolbarPodDetail(pod)
            )
        )
        var opened: TerminalWindowController?
        controller.onOpenTerminalWindow = { opened = $0 }
        controller.showWindow(nil)
        defer {
            if let window = controller.window, let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        table.keyDown(with: try workspaceLetterKey("s"))
        try await waitUntil { opened != nil }

        #expect(opened?.window?.subtitle == "default/api · api")
        #expect(window.attachedSheet == nil)
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("S") == true)
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("\u{21E7}S") == true)

        table.keyDown(with: try workspaceLetterKey("s", modifiers: [.shift]))
        try await waitUntil { window.attachedSheet != nil }
        #expect(window.attachedSheet?.title == "test-cluster — test-context — Configure Terminal")
    }

    @Test("Container view responder commands retain Pod and selected-container context")
    func containerResponderCommandsRouteThroughWorkspace() async throws {
        let pod = toolbarPodIdentity()
        let logs = ResolvingToolbarLogProvider(containers: ["api"])
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            logProvider: logs,
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: toolbarPodDetail(pod)
            )
        )
        var openedLog: LogWindowController?
        var openedTerminal: TerminalWindowController?
        var forwarded: ResourceIdentity?
        controller.onOpenLogWindow = { openedLog = $0 }
        controller.onOpenTerminalWindow = { openedTerminal = $0 }
        controller.onStartPortForward = { forwarded = $0 }
        controller.showWindow(nil)
        defer {
            if let window = controller.window, let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { resourceTable.numberOfRows == 1 }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)

        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }.contains {
                $0.accessibilityLabel() == "Pod containers"
            }
        }
        let containerTable = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Pod containers" })
        containerTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(window.makeFirstResponder(containerTable))
        controller.openResourceLogs(nil)
        try await waitUntil { openedLog != nil }
        controller.openResourceExec(nil)
        try await waitUntil { openedTerminal != nil }
        controller.startResourcePortForward(nil)

        #expect(openedLog?.sources.map(\.container) == ["api"])
        #expect(openedTerminal?.window?.subtitle == "default/api · api")
        #expect(forwarded == pod)

        for action in [
            #selector(ClusterWorkspaceWindowController.openResourceLogs(_:)),
            #selector(ClusterWorkspaceWindowController.openResourceExec(_:)),
            #selector(ClusterWorkspaceWindowController.configureResourceExec(_:)),
            #selector(ClusterWorkspaceWindowController.startResourcePortForward(_:)),
        ] {
            let item = NSMenuItem(title: "Test", action: action, keyEquivalent: "")
            #expect(controller.validateMenuItem(item))
            #expect(!item.isHidden)
        }

        controller.configureResourceExec(nil)
        try await waitUntil { window.attachedSheet != nil }
        #expect(window.attachedSheet?.title == "test-cluster — test-context — Configure Terminal")
    }

    @Test("S opens a Node shell with the cluster image and Shift-S configures it")
    func nodeShellShortcutsUsePerClusterImage() async throws {
        let node = ResourceIdentity(
            clusterSessionID: "test-session",
            group: "", version: "v1", resource: "nodes", namespace: "",
            name: "worker-a", uid: "node-uid"
        )
        let preferences = NodeShellPreferences(
            globalImage: "registry.example/global:1",
            clusterImagesByContextReference: [
                "test-context:test-context": "registry.example/cluster:2",
            ]
        )
        var savedPreferences: NodeShellPreferences?
        let controller = makeWorkspace(
            provider: SingleObjectWorkspaceResourceProvider(identity: node, kind: "Node"),
            nodeShellPreferences: { preferences },
            saveNodeShellPreferences: { savedPreferences = $0 },
            restoration: ClusterWindowRestorationRecord(
                id: "node-shell-shortcut",
                state: ClusterWindowRestorationState(
                    contextName: "test-context",
                    gvr: GVR(group: "", version: "v1", resource: "nodes")
                )
            )
        )
        var opened: TerminalWindowController?
        controller.onOpenTerminalWindow = { opened = $0 }
        controller.showWindow(nil)
        defer {
            if let window = controller.window, let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        table.keyDown(with: try workspaceLetterKey("s"))
        try await waitUntil { opened != nil }
        #expect(opened?.window?.title.contains("worker-a") == true)
        #expect(opened?.window?.subtitle == "Node worker-a · helper namespace default")
        let targetItem = try #require(opened?.window?.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "terminal.identity"
        })
        #expect((targetItem.view as? NSTextField)?.toolTip?
            .contains("registry.example/cluster:2") == true)

        table.keyDown(with: try workspaceLetterKey("s", modifiers: [.shift]))
        try await waitUntil { window.attachedSheet != nil }
        #expect(window.attachedSheet?.title
            == "test-cluster — test-context — Configure Node Shell")
        let sheetRoot = try #require(window.attachedSheet?.contentView)
        let image = try #require(descendants(of: sheetRoot).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "node-shell.image" })
        let saveOverride = try #require(
            descendants(of: sheetRoot).compactMap { $0 as? NSButton }.first {
                $0.accessibilityIdentifier() == "node-shell.save-cluster-image"
            }
        )
        #expect(image.stringValue == "registry.example/cluster:2")
        #expect(saveOverride.state == .on)
        #expect(savedPreferences == nil)
    }

    @Test("Y opens the Details YAML tab and Shift-Y opens a dedicated window")
    func yamlShortcutsHaveDistinctDestinations() async throws {
        let pod = toolbarPodIdentity()
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: toolbarPodDetail(pod)
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))

        table.keyDown(with: try workspaceLetterKey("y"))
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSSegmentedControl }
                .contains { control in
                    control.segmentCount > 1
                        && control.label(forSegment: 1) == "YAML"
                        && control.selectedSegment == 1
                }
                && descendants(of: root).compactMap { $0 as? NSTextView }
                    .contains { $0.accessibilityLabel() == "Kubernetes object YAML"
                        && $0.string.contains("kind: Pod") }
        }
        #expect(controller.openYAMLSnapshotWindows.isEmpty)

        controller.navigateBack(nil)
        try await waitUntil { table.window === window }
        #expect(window.makeFirstResponder(table))
        table.keyDown(with: try workspaceLetterKey("y", modifiers: [.shift]))
        try await waitUntil { controller.openYAMLSnapshotWindows.count == 1 }
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("Y") == true)
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys)
            .contains("\u{21E7}Y") == true)
    }

    @Test("D describes the selected object without changing Return drill-down")
    func describeShortcutOpensDetails() async throws {
        let pod = toolbarPodIdentity()
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: toolbarPodDetail(pod)
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        try await waitUntil {
            controller.contextualShortcutSnapshot?.items.map(\.keys).contains("D") == true
                && controller.contextualShortcutSnapshot?.items.map(\.keys)
                    .contains("\u{2318}Return") == false
        }

        table.keyDown(with: try workspaceLetterKey("d"))
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSSegmentedControl }
                .contains { control in
                    control.segmentCount == 3
                        && control.label(forSegment: 0) == "Summary"
                        && control.selectedSegment == 0
                }
        }
    }

    @Test("a slower Enter cannot replace a newer dedicated YAML window")
    func explicitDetailSupersedesPendingDrillDown() async throws {
        let pod = toolbarPodIdentity()
        let gate = DelayedDetailGate(blockedRequests: [1, 2])
        let detail = toolbarPodDetail(pod)
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: detail,
                gate: gate
            )
        )
        controller.showWindow(nil)
        defer {
            Task { await gate.releaseAll() }
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))

        controller.enterResource(nil)
        try await waitUntilAsync { await gate.requestCount == 1 }
        controller.openResourceYAMLSnapshot(nil)
        try await waitUntilAsync { await gate.requestCount == 2 }
        await gate.releaseAll()

        try await waitUntil {
            guard let yamlRoot = controller.openYAMLSnapshotWindows.first?
                .window?.contentView
            else { return false }
            return descendants(of: yamlRoot).compactMap { $0 as? NSTextView }
                .contains { $0.accessibilityLabel() == "Kubernetes YAML snapshot"
                    && $0.string.contains("kind: Pod") }
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(controller.openYAMLSnapshotWindows.count == 1)
        #expect(descendants(of: root).compactMap { $0 as? NSTableView }
            .contains { $0.accessibilityLabel() == "Pod containers" } == false)
    }

    @Test("Back cancels a pending Forward restoration of a subresource")
    func backSupersedesPendingSubresourceRestoration() async throws {
        let pod = toolbarPodIdentity()
        let gate = DelayedDetailGate(blockedRequests: [2])
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: toolbarPodDetail(pod),
                gate: gate
            )
        )
        controller.showWindow(nil)
        defer {
            Task { await gate.releaseAll() }
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { resourceTable.numberOfRows == 1 }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTableView }
                .contains { $0.accessibilityLabel() == "Pod containers" }
        }

        controller.navigateBack(nil)
        controller.navigateForward(nil)
        try await waitUntilAsync { await gate.requestCount == 2 }
        controller.navigateBack(nil)
        await gate.releaseAll()
        try await Task.sleep(for: .milliseconds(40))

        #expect(descendants(of: root).compactMap { $0 as? NSTableView }
            .contains { $0.accessibilityLabel() == "Kubernetes resources" })
        #expect(descendants(of: root).compactMap { $0 as? NSTableView }
            .contains { $0.accessibilityLabel() == "Pod containers" } == false)
    }

    @Test("Back from Namespace Pods restores the toolbar namespace scope")
    func namespaceDrillDownBackRestoresToolbarScope() async throws {
        let namespace = ResourceIdentity(
            clusterSessionID: "test-session", group: "", version: "v1",
            resource: "namespaces", namespace: "", name: "payments",
            uid: "namespace-payments"
        )
        let restoration = ClusterWindowRestorationRecord(
            id: "namespace-drill-down",
            state: ClusterWindowRestorationState(
                contextName: "test-context",
                gvr: GVR(group: "", version: "v1", resource: "namespaces"),
                namespaceScope: .all
            )
        )
        let controller = makeWorkspace(
            provider: NamespaceDrillDownWorkspaceResourceProvider(namespace: namespace),
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: namespace,
                resourceVersion: "rv-1"
            )),
            restoration: restoration
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let namespaceControl = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue == "workspace.namespace"
        }?.view as? NSPopUpButton)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        controller.enterResource(nil)
        try await waitUntil { namespaceControl.titleOfSelectedItem == "payments" }

        controller.navigateBack(nil)
        try await waitUntil {
            namespaceControl.titleOfSelectedItem == "All namespaces"
                && table.numberOfRows == 1
        }
    }

    @Test("workload drill-down preserves canonical match expressions through history")
    func workloadDrillDownPreservesNativeSelector() async throws {
        let deployment = ResourceIdentity(
            clusterSessionID: "test-session", group: "apps", version: "v1",
            resource: "deployments", namespace: "default", name: "api",
            uid: "deployment-api"
        )
        let provider = RelationshipDrillDownWorkspaceResourceProvider(source: deployment)
        let selector =
            "app=api,debug,!retired,track in (canary,stable),zone notin (east,west)"
        let controller = makeWorkspace(
            provider: provider,
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: deployment,
                resourceVersion: "rv-1",
                summaryFields: [
                    ObjectSummaryField(
                        sectionID: "selectors", fieldID: "selector:0",
                        label: "app", displayText: "api"
                    ),
                    ObjectSummaryField(
                        sectionID: "selectors", fieldID: "selectorExpressions",
                        label: "Match Expressions", displayText: "4 native requirements"
                    ),
                ],
                podLabelSelector: selector
            )),
            restoration: ClusterWindowRestorationRecord(
                id: "workload-selector-drill-down",
                state: ClusterWindowRestorationState(
                    contextName: "test-context",
                    gvr: GVR(group: "apps", version: "v1", resource: "deployments"),
                    namespaceScope: .namespace("default")
                )
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let statusLine = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil { provider.streamRequests.count == 1 && table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        controller.enterResource(nil)

        try await waitUntil { provider.streamRequests.count == 2 }
        var requests = provider.streamRequests
        #expect(requests[1].resource.resource == "pods")
        #expect(requests[1].labelSelector == selector)
        #expect(requests[1].filterExpression == "label:app==api")
        #expect(statusLine.stringValue.contains("Kubernetes selector active"))
        #expect(statusLine.toolTip?.contains("Label selector: \(selector)") == true)

        controller.navigateBack(nil)
        try await waitUntil {
            provider.streamRequests.count == 3
                && table.numberOfRows == 1
                && table.selectedRowIndexes == IndexSet(integer: 0)
        }
        requests = provider.streamRequests
        #expect(requests[2].resource.resource == "deployments")
        #expect(requests[2].labelSelector.isEmpty)

        controller.navigateForward(nil)
        try await waitUntil { provider.streamRequests.count == 4 }
        requests = provider.streamRequests
        #expect(requests[3].resource.resource == "pods")
        #expect(requests[3].labelSelector == selector)
        #expect(requests[3].filterExpression == "label:app==api")
    }

    @Test("clearing a workload drill-down filter restores all Pods and selects Pods")
    func clearingWorkloadDrillDownRestoresPods() async throws {
        let daemonSet = ResourceIdentity(
            clusterSessionID: "test-session", group: "apps", version: "v1",
            resource: "daemonsets", namespace: "default", name: "agent",
            uid: "daemonset-agent"
        )
        let selector = "app=agent,!retired"
        let provider = RelationshipDrillDownWorkspaceResourceProvider(source: daemonSet)
        let controller = makeWorkspace(
            provider: provider,
            objectDetailProvider: NoopToolbarObjectDetailProvider(detail: ObjectDetail(
                identity: daemonSet,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "selectors", fieldID: "selector:0",
                    label: "app", displayText: "agent"
                )],
                podLabelSelector: selector
            )),
            restoration: ClusterWindowRestorationRecord(
                id: "clear-workload-selector",
                state: ClusterWindowRestorationState(
                    contextName: "test-context",
                    gvr: GVR(group: "apps", version: "v1", resource: "daemonsets"),
                    namespaceScope: .namespace("default")
                )
            )
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let outline = try #require(apiResourceOutline(in: window))

        try await waitUntil { provider.streamRequests.count == 1 && table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        controller.enterResource(nil)
        try await waitUntil { provider.streamRequests.count == 2 }
        #expect(provider.streamRequests[1].resource.resource == "pods")
        #expect(provider.streamRequests[1].labelSelector == selector)

        try triggerResourceFilterChange(in: window, value: "")
        try await waitUntil(timeout: .seconds(1)) { provider.streamRequests.count == 3 }
        let restored = provider.streamRequests[2]
        #expect(restored.resource.resource == "pods")
        #expect(restored.labelSelector.isEmpty)
        #expect(restored.fieldSelector.isEmpty)
        #expect(restored.filterExpression.isEmpty)
        let selected = outline.selectedRow >= 0
            ? outline.item(atRow: outline.selectedRow) as? DiscoveredResource
            : nil
        #expect(selected?.resource == "pods")
    }

    @Test("helper recovery refetches a visible subresource with the new session")
    func helperRecoveryRebindsVisibleSubresource() async throws {
        let pod = toolbarPodIdentity()
        let gate = DelayedDetailGate(blockedRequests: [2])
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            objectDetailProvider: NoopToolbarObjectDetailProvider(
                detail: toolbarPodDetail(pod),
                gate: gate,
                rebindIdentityToRequest: true
            )
        )
        controller.showWindow(nil)
        defer {
            Task { await gate.releaseAll() }
            controller.close()
        }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        try await waitUntil { resourceTable.numberOfRows == 1 }
        try await selectResourceRow(0, in: resourceTable)
        #expect(window.makeFirstResponder(resourceTable))
        controller.enterResource(nil)
        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSButton }
                .contains { $0.title == "Open Selected Container Logs" && $0.isEnabled }
        }

        controller.engineDidDisconnect(message: "test helper restart")
        let disabledButton = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Open Selected Container Logs" })
        #expect(!disabledButton.isEnabled)

        controller.recover(with: OpenedClusterSession(
            sessionID: "recovered-session",
            contextName: "test-context",
            clusterName: "test-cluster",
            serverHostname: "example.invalid",
            defaultNamespace: "default"
        ))
        try await waitUntilAsync { await gate.requestCount == 2 }
        let requested = await gate.requestedIdentities
        #expect(requested.map(\.clusterSessionID) == ["test-session", "recovered-session"])
        #expect(requested.map(\.uid) == [pod.uid, pod.uid])
        await gate.releaseAll()

        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSButton }
                .contains { $0.title == "Open Selected Container Logs" && $0.isEnabled }
        }
    }

    @Test("Pod log action resolves all containers and opens no setup sheet")
    func podLogsOpenDirectlyWithAllContainers() async throws {
        let logs = ResolvingToolbarLogProvider()
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            logProvider: logs
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        var opened: LogWindowController?
        controller.onOpenLogWindow = { opened = $0 }

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        table.keyDown(with: try workspaceLetterKey("l"))
        try await waitUntil { opened != nil }

        let resolved = logs.resolvedResources
        #expect(resolved.count == 1)
        let request = try #require(resolved.first)
        #expect(request.resource == "pods")
        #expect(request.uid == ResourceUID("pod-api"))
        #expect(opened?.sources.map(\.container) == ["app", "sidecar"])
        let logWindow = try #require(opened?.window)
        let logRoot = try #require(logWindow.contentView)
        let previous = try #require(descendants(of: logRoot)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Previous" })
        #expect(previous.state == .off)
        #expect(window.attachedSheet == nil)
    }

    @Test("Shift-L opens logs from the previous container instance")
    func previousPodLogsShortcut() async throws {
        let logs = ResolvingToolbarLogProvider()
        let controller = makeWorkspace(
            provider: FilterValidationWorkspaceResourceProvider(),
            logProvider: logs
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        var opened: LogWindowController?
        controller.onOpenLogWindow = { opened = $0 }

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        table.keyDown(with: try workspaceLetterKey("l", modifiers: [.shift]))
        try await waitUntil { opened != nil }

        let logWindow = try #require(opened?.window)
        let logRoot = try #require(logWindow.contentView)
        let previous = try #require(descendants(of: logRoot)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Previous" })
        #expect(previous.state == .on)
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys)
            .contains("\u{21E7}L") == true)
    }

    @Test("Open Events navigates to UID-filtered Events and preserves Back history")
    func openEventsNavigatesToFilteredResourceList() async throws {
        let provider = EventsNavigationWorkspaceResourceProvider()
        let controller = makeWorkspace(provider: provider)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { provider.streamRequests.count == 1 && table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))
        controller.openResourceEvents(nil)

        try await waitUntil { provider.streamRequests.count == 2 }
        var requests = provider.streamRequests
        let events = requests[1]
        #expect(events.resource.group.isEmpty)
        #expect(events.resource.version == "v1")
        #expect(events.resource.resource == "events")
        #expect(!events.allNamespaces)
        #expect(events.namespaces == ["default"])
        #expect(events.filterExpression == "field:involvedObject.uid==pod-api")

        controller.navigateBack(nil)
        try await waitUntil { provider.streamRequests.count == 3 }
        requests = provider.streamRequests
        #expect(requests[2].resource.id == requests[0].resource.id)
        #expect(requests[2].allNamespaces == requests[0].allNamespaces)
        #expect(requests[2].namespaces == requests[0].namespaces)
        #expect(requests[2].filterExpression == requests[0].filterExpression)
    }

    @Test("incompatible resource actions are hidden while valid actions remain")
    func incompatibleMenuActionsAreHidden() async throws {
        let controller = makeWorkspace(provider: ServiceWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { table.numberOfRows == 1 }
        try await selectResourceRow(0, in: table)
        #expect(window.makeFirstResponder(table))

        let logs = NSMenuItem(
            title: "Open Logs…",
            action: #selector(ClusterWorkspaceWindowController.openResourceLogs(_:)),
            keyEquivalent: ""
        )
        let restart = NSMenuItem(
            title: "Rollout Restart…",
            action: #selector(ClusterWorkspaceWindowController.restartResourceSelection(_:)),
            keyEquivalent: ""
        )
        let forward = NSMenuItem(
            title: "Start Port Forward…",
            action: #selector(ClusterWorkspaceWindowController.startResourcePortForward(_:)),
            keyEquivalent: ""
        )

        #expect(!controller.validateMenuItem(logs))
        #expect(logs.isHidden)
        #expect(!controller.validateMenuItem(restart))
        #expect(restart.isHidden)
        #expect(controller.validateMenuItem(forward))
        #expect(!forward.isHidden)

        let menu = try #require(table.menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(menu.item(withTitle: "Open Logs…") == nil)
        #expect(menu.item(withTitle: "Rollout Restart…") == nil)
        #expect(menu.item(withTitle: "Start Port Forward…") != nil)
        #expect(menu.item(withTitle: "Edit Labels / Annotations…") != nil)
    }

    @Test("Edit Select All starts a fresh selection after the filter changes")
    func responderSelectAllStartsFreshAfterFilterChange() async throws {
        let controller = makeWorkspace(provider: SelectAllFilterWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })
        let status = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })

        try await waitUntil { table.numberOfRows == 2 }
        try await selectResourceRow(1, in: table)

        try triggerResourceFilterChange(in: window, value: "name:api")
        try await waitUntil {
            table.numberOfRows == 1
                && status.stringValue.contains("1 selected")
                && table.selectedRowIndexes.isEmpty
        }

        #expect(window.makeFirstResponder(table))
        #expect(table.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil))
        try await waitUntil {
            status.stringValue.contains("1 selected")
                && table.selectedRowIndexes == IndexSet(integer: 0)
        }
        #expect(!status.stringValue.contains("2 selected"))
    }

    @Test("workspace footer shows resource freshness age and background progress")
    func resourceFreshnessFooter() async throws {
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
            .first { $0.identifier?.rawValue == "workspace-status-line" })
        let progress = try #require(descendants(of: root)
            .compactMap { $0 as? NSProgressIndicator }
            .first { $0.identifier?.rawValue == "workspace-status-progress" })

        try await waitUntil { label.stringValue.contains("Reconnecting…") }
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
        let status = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })
        let filter = try #require(descendants(of: root)
            .compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })
        let table = try #require(descendants(of: root)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil {
            status.stringValue.hasSuffix(" · Watching")
                && resourceRowIsMaterialized(0, in: table)
        }
        try triggerResourceFilterChange(
            in: try #require(controller.window),
            value: "unknown:value"
        )
        #expect(provider.streamRequestCount == 1)
        #expect(table.numberOfRows == 1)
        #expect(status.stringValue.contains("Filtering… · last good rows"))
        try await waitUntil(timeout: .milliseconds(120)) {
            provider.cancelRequestCount == 1
        }
        try await waitUntil {
            provider.streamRequestCount == 2
                && descendants(of: root).compactMap { ($0 as? NSTextField)?.stringValue }
                    .contains { $0.contains("Unknown filter term unknown") }
        }

        #expect(filter.stringValue == "unknown:value")
        #expect(table.numberOfRows == 1)
        #expect(status.stringValue.contains("Invalid filter · last good rows"))
        #expect(status.accessibilityValue()?.contains(
            "Invalid filter · last good rows"
        ) == true)
        #expect(status.toolTip?.contains("Operation: compile resource filter") == true)
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
        let status = try #require(descendants(of: root)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "workspace-status-line" })
        let filter = try #require(descendants(of: root)
            .compactMap { $0 as? NSSearchField }
            .first { $0.accessibilityLabel() == "Filter Kubernetes resources" })

        try await waitUntil {
            status.stringValue.contains("Invalid filter")
                && status.stringValue.contains("Unknown filter term unknown")
        }

        #expect(filter.stringValue == "unknown:value")
        #expect(status.accessibilityValue()?.contains("Invalid filter") == true)
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
        let connection = descendants(of: root).first {
            $0.identifier?.rawValue == "cluster-connection-activity"
        }
        let connectionValue = connection?.accessibilityValue() as? String
        #expect(connectionValue?.contains("Reconnecting…") == true)
        #expect(connectionValue?.contains("Opening saved Kubernetes context…") == true)
        #expect(connectionValue?.contains("Aggregate 0 B/s") == true)

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
        #expect(originalWindow.subtitle == "api.production.example")
        #expect(originalWindow.toolbar?.items.contains {
            $0.itemIdentifier.rawValue == "workspace.cluster"
        } == false)
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
        let connection = descendants(of: try #require(originalWindow.contentView)).first {
            $0.identifier?.rawValue == "cluster-connection-activity"
        }
        let connectionValue = connection?.accessibilityValue() as? String
        #expect(connectionValue?.contains("Authentication failed (401).") == true)
        #expect(connectionValue?.contains("Operation: open saved context") == true)
        #expect(connectionValue?.contains("Reason: Unauthorized") == true)
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
    connectionActivityProvider: any ClusterConnectionActivityProviding =
        NoopConnectionActivityProvider(),
    operationHistoryProvider: any ClusterOperationHistoryProviding =
        NoopOperationHistoryProvider(),
    logProvider: any LogStreamProviding = NoopLogProvider(),
    objectDetailProvider: any ObjectDetailProviding = NoopToolbarObjectDetailProvider(),
    execProvider: any ExecSessionProviding = NoopExecProvider(),
    nodeShellPreferences: @escaping @MainActor () -> NodeShellPreferences = {
        NodeShellPreferences()
    },
    saveNodeShellPreferences: @escaping @MainActor (NodeShellPreferences) throws -> Void = {
        _ in
    },
    namespacePickerPresenter: @escaping NamespacePickerPresenter = { control, sender in
        control.performClick(sender)
    },
    namespacePickerKeyWindowCheck: @escaping NamespacePickerKeyWindowCheck = {
        $0.isKeyWindow
    },
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
        connectionActivityProvider: connectionActivityProvider,
        operationHistoryProvider: operationHistoryProvider,
        optionalResourceCatalogProvider: NoopOptionalResourceCatalogProvider(),
        objectSearchProvider: NoopObjectSearchProvider(),
        objectDetailProvider: objectDetailProvider,
        operationProvider: NoopOperationProvider(),
        logProvider: logProvider,
        execProvider: execProvider,
        portForwards: portForwards,
        columnsConfigurationPath: "/tmp/kmgr-toolbar-test-columns.yaml",
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
        nodeShellPreferences: nodeShellPreferences,
        saveNodeShellPreferences: saveNodeShellPreferences,
        namespacePickerPresenter: namespacePickerPresenter,
        namespacePickerKeyWindowCheck: namespacePickerKeyWindowCheck,
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
    objectDetailProvider: (any ObjectDetailProviding)? = nil,
    operationProvider: (any ResourceOperationProviding)? = nil,
    columnsConfigurationPath: String,
    columnConfigurationCoordinator: ColumnConfigurationCoordinator? = nil,
    columnsConfigurationLoader: ColumnConfigurationDocumentLoader = .fileSystem,
    resourceViewportTiming: ResourceViewportTiming = .production,
    tableColumnMutationAllowed: @escaping @MainActor () -> Bool = {
        NSEvent.pressedMouseButtons == 0
    },
    restorationState: ClusterWindowRestorationState? = nil,
    seedFrameAutosaveName: String? = nil
) -> ClusterWorkspaceWindowController {
    let portForwards = PortForwardCoordinator(provider: NoopPortForwardProvider())
    let restoration = restorationState.map {
        ClusterWindowRestorationRecord(
            id: "column-propagation-\(UUID().uuidString)",
            state: $0
        )
    } ?? ClusterWindowRestorationRecord(
        id: "column-propagation-\(UUID().uuidString)",
        contextName: session.contextName,
        contextReference: session.contextReference
    )
    return ClusterWorkspaceWindowController(
        session: session,
        provider: provider,
        connectionActivityProvider: NoopConnectionActivityProvider(),
        optionalResourceCatalogProvider: optionalResourceCatalogProvider,
        objectSearchProvider: NoopObjectSearchProvider(),
        objectDetailProvider:
            objectDetailProvider ?? NoopToolbarObjectDetailProvider(),
        operationProvider: operationProvider ?? NoopOperationProvider(),
        logProvider: NoopLogProvider(),
        execProvider: NoopExecProvider(),
        portForwards: portForwards,
        columnsConfigurationPath: columnsConfigurationPath,
        columnConfigurationCoordinator: columnConfigurationCoordinator,
        columnsConfigurationLoader: columnsConfigurationLoader,
        resourceViewportTiming: resourceViewportTiming,
        tableColumnMutationAllowed: tableColumnMutationAllowed,
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
        restoration: restoration,
        seedFrameAutosaveName: seedFrameAutosaveName,
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

private enum DiscoveryRefreshOutcome: Sendable {
    case result(ResourceDiscoveryResult)
    case failure(ClusterManagerIssue)
}

private final class DiscoveryRefreshWorkspaceProvider: WorkspaceResourceProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let outcomes: [DiscoveryRefreshOutcome]
    private let gates: [Int: RestorationDiscoveryGate]
    private var storedDiscoveryRefreshFlags: [Bool] = []
    private var storedFinishedDiscoveryCount = 0
    private var storedNamespaceRequestCount = 0
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(
        outcomes: [DiscoveryRefreshOutcome],
        gates: [Int: RestorationDiscoveryGate] = [:]
    ) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
        self.gates = gates
    }

    var discoveryRefreshFlags: [Bool] {
        lock.withLock { storedDiscoveryRefreshFlags }
    }

    var finishedDiscoveryCount: Int {
        lock.withLock { storedFinishedDiscoveryCount }
    }

    var namespaceRequestCount: Int {
        lock.withLock { storedNamespaceRequestCount }
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        let (outcome, gate) = lock.withLock { () -> (
            DiscoveryRefreshOutcome, RestorationDiscoveryGate?
        ) in
            let index = storedDiscoveryRefreshFlags.count
            precondition(outcomes.indices.contains(index))
            storedDiscoveryRefreshFlags.append(refresh)
            return (outcomes[index], gates[index])
        }
        await gate?.wait()
        lock.withLock { storedFinishedDiscoveryCount += 1 }
        switch outcome {
        case .result(let result): return result
        case .failure(let issue): throw issue
        }
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        lock.withLock { storedNamespaceRequestCount += 1 }
        return ["default"]
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

private final class WarmResumeSelectionWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding,
    @unchecked Sendable
{
    typealias StreamContinuation = AsyncThrowingStream<
        ResourceViewMessage,
        Error
    >.Continuation

    private let lock = NSLock()
    private let rows: [ResourceRow]
    private var storedStreamRequestCount = 0
    private var resumeRequest: ResourceViewRequest?
    private var resumeContinuation: StreamContinuation?

    init(rowCount: Int) {
        rows = (0..<rowCount).map { index in
            let name = index == 0 ? "api" : "pod-\(index)"
            return ResourceRow(
                identity: ResourceIdentity(
                    clusterSessionID: "test-session",
                    group: "",
                    version: "v1",
                    resource: "pods",
                    namespace: "default",
                    name: name,
                    uid: ResourceUID("pod-\(index)")
                ),
                cells: [Cell(
                    columnID: "name",
                    displayText: name,
                    typedValue: .string(name)
                )]
            )
        }
    }

    var firstIdentity: ResourceIdentity { rows[0].identity }
    var streamRequestCount: Int { lock.withLock { storedStreamRequestCount } }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true,
            verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        let requestNumber = lock.withLock { () -> Int in
            storedStreamRequestCount += 1
            return storedStreamRequestCount
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(testSnapshotInvalidation(
                    request: request,
                    sequence: 1,
                    rows: rows
                ))
                continuation.yield(.status(
                    cursor: StreamCursor(generation: request.generation, sequence: 2),
                    status: ResourceViewStatus(
                        freshness: .watching,
                        rowsVisible: UInt64(rows.count)
                    )
                ))
                continuation.finish()
                return
            }

            lock.withLock {
                resumeRequest = request
                resumeContinuation = continuation
            }
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                status: ResourceViewStatus(
                    freshness: .stale,
                    rowsVisible: UInt64(rows.count),
                    lastSynchronizedAt: Date(timeIntervalSince1970: 100),
                    fromWarmCache: true
                )
            ))
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 2,
                rows: rows
            ))
            continuation.yield(testReconciliation(
                request: request,
                sequence: 3
            ))
        }
    }

    func releaseAuthoritativeRows() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        continuation.yield(testDeltaInvalidation(
            request: request,
            sequence: 4,
            upserts: rows,
            orderedUIDs: rows.map { $0.identity.uid },
            orderIsComplete: true
        ))
        continuation.yield(.status(
            cursor: StreamCursor(generation: request.generation, sequence: 5),
            status: ResourceViewStatus(
                freshness: .watching,
                rowsVisible: UInt64(rows.count)
            )
        ))
    }

    func finish() {
        lock.withLock { resumeContinuation }?.finish()
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private final class InterruptedPartialResumeWorkspaceResourceProvider:
    RangeBackedTestWorkspaceProviding, @unchecked Sendable
{
    typealias StreamContinuation = AsyncThrowingStream<
        ResourceViewMessage,
        Error
    >.Continuation

    private let lock = NSLock()
    private let rows: [ResourceRow]
    private let initialRowCount: Int
    private let resumedRowCount: Int
    private var storedStreamRequestCount = 0
    private var initialContinuation: StreamContinuation?
    private var resumeRequest: ResourceViewRequest?
    private var resumeContinuation: StreamContinuation?

    init(initialRowCount: Int, resumedRowCount: Int, finalRowCount: Int) {
        precondition(initialRowCount > 0)
        precondition(initialRowCount < resumedRowCount)
        precondition(resumedRowCount < finalRowCount)
        self.initialRowCount = initialRowCount
        self.resumedRowCount = resumedRowCount
        rows = (0..<finalRowCount).map { index in
            let name = index == 0 ? "api" : "pod-\(index)"
            return ResourceRow(
                identity: ResourceIdentity(
                    clusterSessionID: "test-session",
                    group: "",
                    version: "v1",
                    resource: "pods",
                    namespace: "default",
                    name: name,
                    uid: ResourceUID("interrupted-pod-\(index)")
                ),
                cells: [Cell(
                    columnID: "name",
                    displayText: name,
                    typedValue: .string(name)
                )]
            )
        }
    }

    var firstIdentity: ResourceIdentity { rows[0].identity }
    var streamRequestCount: Int { lock.withLock { storedStreamRequestCount } }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true,
            verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        let requestNumber = lock.withLock { () -> Int in
            storedStreamRequestCount += 1
            return storedStreamRequestCount
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                lock.withLock { initialContinuation = continuation }
                let initialRows = Array(rows.prefix(initialRowCount))
                continuation.yield(testSnapshotInvalidation(
                    request: request,
                    sequence: 1,
                    rows: initialRows
                ))
                continuation.yield(.status(
                    cursor: StreamCursor(generation: request.generation, sequence: 2),
                    status: ResourceViewStatus(
                        freshness: .relisting,
                        objectsExamined: UInt64(initialRows.count),
                        rowsVisible: UInt64(initialRows.count)
                    )
                ))
                return
            }

            lock.withLock {
                resumeRequest = request
                resumeContinuation = continuation
            }
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                status: ResourceViewStatus(freshness: .loading)
            ))
        }
    }

    func releaseResumedRows() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        let resumedRows = Array(rows.prefix(resumedRowCount))
        continuation.yield(testSnapshotInvalidation(
            request: request,
            sequence: 2,
            rows: resumedRows
        ))
        continuation.yield(.status(
            cursor: StreamCursor(generation: request.generation, sequence: 3),
            status: ResourceViewStatus(
                freshness: .relisting,
                objectsExamined: UInt64(resumedRows.count),
                rowsVisible: UInt64(resumedRows.count)
            )
        ))
    }

    func releaseAuthoritativeRows() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        continuation.yield(testSnapshotInvalidation(
            request: request,
            sequence: 4,
            rows: Array(rows.dropFirst(resumedRowCount)),
            first: false
        ))
        continuation.yield(.status(
            cursor: StreamCursor(generation: request.generation, sequence: 5),
            status: ResourceViewStatus(
                freshness: .watching,
                objectsExamined: UInt64(rows.count),
                rowsVisible: UInt64(rows.count)
            )
        ))
        continuation.yield(testReconciliation(
            request: request,
            sequence: 6
        ))
    }

    func finish() {
        let state = lock.withLock { (initialContinuation, resumeContinuation) }
        state.0?.finish()
        state.1?.finish()
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private final class DelayedWarmResumeWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding,
    @unchecked Sendable
{
    typealias StreamContinuation = AsyncThrowingStream<
        ResourceViewMessage,
        Error
    >.Continuation

    private let lock = NSLock()
    private let rows: [ResourceRow]
    private var storedStreamRequestCount = 0
    private var resumeRequest: ResourceViewRequest?
    private var resumeContinuation: StreamContinuation?

    init(rowCount: Int) {
        rows = (0..<rowCount).map { index in
            let name = index == 0 ? "api" : "pod-\(index)"
            return ResourceRow(
                identity: ResourceIdentity(
                    clusterSessionID: "test-session",
                    group: "",
                    version: "v1",
                    resource: "pods",
                    namespace: "default",
                    name: name,
                    uid: ResourceUID("pod-\(index)")
                ),
                cells: [Cell(
                    columnID: "name",
                    displayText: name,
                    typedValue: .string(name)
                )]
            )
        }
    }

    var firstIdentity: ResourceIdentity { rows[0].identity }
    var streamRequestCount: Int { lock.withLock { storedStreamRequestCount } }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [DiscoveredResource(
            group: "",
            version: "v1",
            resource: "pods",
            kind: "Pod",
            namespaced: true,
            verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        let requestNumber = lock.withLock { () -> Int in
            storedStreamRequestCount += 1
            return storedStreamRequestCount
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(testSnapshotInvalidation(
                    request: request,
                    sequence: 1,
                    rows: rows
                ))
                continuation.yield(.status(
                    cursor: StreamCursor(generation: request.generation, sequence: 2),
                    status: ResourceViewStatus(
                        freshness: .watching,
                        rowsVisible: UInt64(rows.count)
                    )
                ))
                continuation.finish()
                return
            }

            lock.withLock {
                resumeRequest = request
                resumeContinuation = continuation
            }
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                status: ResourceViewStatus(freshness: .loading)
            ))
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 2,
                rows: []
            ))
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 3),
                status: ResourceViewStatus(freshness: .loading)
            ))
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 4,
                rows: []
            ))
        }
    }

    func releasePartialRows() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        let partial = Array(rows.prefix(500))
        continuation.yield(testDeltaInvalidation(
            request: request,
            sequence: 5,
            upserts: partial,
            orderedUIDs: partial.map { $0.identity.uid },
            orderIsComplete: true
        ))
    }

    func releaseAuthoritativeRows() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        continuation.yield(.status(
            cursor: StreamCursor(generation: request.generation, sequence: 6),
            status: ResourceViewStatus(
                freshness: .watching,
                rowsVisible: UInt64(rows.count)
            )
        ))
        continuation.yield(testDeltaInvalidation(
            request: request,
            sequence: 7,
            upserts: Array(rows.dropFirst(500)),
            orderedUIDs: rows.map { $0.identity.uid },
            orderIsComplete: true
        ))
        continuation.yield(testReconciliation(
            request: request,
            sequence: 8
        ))
    }

    func releaseAuthoritativeEmpty() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        continuation.yield(.status(
            cursor: StreamCursor(generation: request.generation, sequence: 5),
            status: ResourceViewStatus(freshness: .watching, rowsVisible: 0)
        ))
        continuation.yield(testDeltaInvalidation(
            request: request,
            sequence: 6,
            removedUIDs: Set(rows.map { $0.identity.uid }),
            orderedUIDs: [],
            orderIsComplete: true
        ))
        continuation.yield(testReconciliation(
            request: request,
            sequence: 7
        ))
    }

    func removeAllRows() {
        let state = lock.withLock { (resumeRequest, resumeContinuation) }
        guard let request = state.0, let continuation = state.1 else { return }
        continuation.yield(testDeltaInvalidation(
            request: request,
            sequence: 9,
            removedUIDs: Set(rows.map { $0.identity.uid }),
            orderedUIDs: [],
            orderIsComplete: true
        ))
    }

    func finish() {
        lock.withLock { resumeContinuation }?.finish()
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private final class FilterValidationWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let initialRequestIsInvalid: Bool
    private var storedStreamRequestCount = 0
    private var storedCancelRequestCount = 0
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(initialRequestIsInvalid: Bool = false) {
        self.initialRequestIsInvalid = initialRequestIsInvalid
    }

    var streamRequestCount: Int { lock.withLock { storedStreamRequestCount } }
    var cancelRequestCount: Int { lock.withLock { storedCancelRequestCount } }
    var streamRequests: [ResourceViewRequest] { lock.withLock { storedStreamRequests } }

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
            storedStreamRequests.append(request)
            return storedStreamRequestCount
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 && !initialRequestIsInvalid {
                let identity = ResourceIdentity(
                    clusterSessionID: request.sessionID,
                    group: "", version: "v1", resource: "pods",
                    namespace: "default", name: "api", uid: "pod-api"
                )
                continuation.yield(testSnapshotInvalidation(
                    request: request,
                    sequence: 1,
                    rows: [ResourceRow(identity: identity, cells: [
                        Cell(
                            columnID: "name", displayText: "api",
                            typedValue: .string("api")
                        ),
                    ])]
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

private struct SingleObjectWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding {
    var identity: ResourceIdentity
    var kind: String

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [DiscoveredResource(
            group: identity.group,
            version: identity.version,
            resource: identity.resource,
            kind: kind,
            namespaced: !identity.namespace.isEmpty,
            verbs: ["get", "list", "watch", "patch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] {
        identity.namespace.isEmpty ? [] : [identity.namespace]
    }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        var rebound = identity
        rebound.clusterSessionID = request.sessionID
        let matches = request.resource.group == rebound.group
            && request.resource.version == rebound.version
            && request.resource.resource == rebound.resource
        let rows = matches ? [ResourceRow(identity: rebound, cells: [
            Cell(
                columnID: "name",
                displayText: rebound.name,
                typedValue: .string(rebound.name)
            ),
        ])] : []
        return AsyncThrowingStream { continuation in
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 1,
                rows: rows
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
}

private final class EventsNavigationWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedStreamRequests: [ResourceViewRequest] = []

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
                group: "", version: "v1", resource: "events", kind: "Event",
                namespaced: true, verbs: ["list", "watch"]
            ),
        ])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { ["default"] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        lock.withLock { storedStreamRequests.append(request) }
        return AsyncThrowingStream { continuation in
            let rows: [ResourceRow]
            if request.resource.resource == "pods" {
                let identity = ResourceIdentity(
                    clusterSessionID: request.sessionID,
                    group: "", version: "v1", resource: "pods",
                    namespace: "default", name: "api", uid: "pod-api"
                )
                rows = [ResourceRow(identity: identity, cells: [
                    Cell(columnID: "name", displayText: "api", typedValue: .string("api")),
                ])]
            } else {
                rows = []
            }
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 1,
                rows: rows
            ))
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 2),
                status: ResourceViewStatus(
                    freshness: .watching, rowsVisible: UInt64(rows.count)
                )
            ))
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private struct NamespaceDrillDownWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding {
    var namespace: ResourceIdentity

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [
            DiscoveredResource(
                group: "", version: "v1", resource: "namespaces", kind: "Namespace",
                namespaced: false, verbs: ["list", "watch"]
            ),
            DiscoveredResource(
                group: "", version: "v1", resource: "pods", kind: "Pod",
                namespaced: true, verbs: ["list", "watch"]
            ),
        ])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { ["payments"] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        let rows: [ResourceRow]
        if request.resource.resource == "namespaces" {
            var rebound = namespace
            rebound.clusterSessionID = request.sessionID
            rows = [ResourceRow(identity: rebound, cells: [
                Cell(columnID: "name", displayText: rebound.name, typedValue: .string(rebound.name)),
            ])]
        } else {
            rows = []
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 1,
                rows: rows
            ))
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 2),
                status: ResourceViewStatus(freshness: .watching, rowsVisible: UInt64(rows.count))
            ))
            if request.stageUntilReconciled {
                continuation.yield(testReconciliation(
                    request: request,
                    sequence: 3
                ))
            }
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private final class RelationshipDrillDownWorkspaceResourceProvider:
    RangeBackedTestWorkspaceProviding, @unchecked Sendable
{
    private let lock = NSLock()
    private let source: ResourceIdentity
    private var storedStreamRequests: [ResourceViewRequest] = []

    init(source: ResourceIdentity) {
        self.source = source
    }

    var streamRequests: [ResourceViewRequest] {
        lock.withLock { storedStreamRequests }
    }

    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult
    {
        .init(resources: [
            DiscoveredResource(
                group: source.group, version: source.version,
                resource: source.resource, kind: "Deployment",
                namespaced: true, verbs: ["list", "watch"]
            ),
            DiscoveredResource(
                group: "", version: "v1", resource: "pods", kind: "Pod",
                namespaced: true, verbs: ["list", "watch"]
            ),
        ])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { ["default"] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error>
    {
        lock.withLock { storedStreamRequests.append(request) }
        var rebound = source
        rebound.clusterSessionID = request.sessionID
        let rows = request.resource.resource == source.resource
            ? [ResourceRow(identity: rebound, cells: [Cell(
                columnID: "name", displayText: rebound.name,
                typedValue: .string(rebound.name)
            )])]
            : []
        return AsyncThrowingStream { continuation in
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 1,
                rows: rows
            ))
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 2),
                status: ResourceViewStatus(
                    freshness: .watching, rowsVisible: UInt64(rows.count)
                )
            ))
            if request.stageUntilReconciled {
                continuation.yield(testReconciliation(
                    request: request,
                    sequence: 3
                ))
            }
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

private struct SelectAllFilterWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding {
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
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 1,
                rows: rows
            ))
            continuation.yield(.status(
                cursor: StreamCursor(generation: request.generation, sequence: 2),
                status: ResourceViewStatus(
                    freshness: .watching,
                    rowsVisible: UInt64(rows.count)
                )
            ))
            if request.stageUntilReconciled {
                continuation.yield(testReconciliation(
                    request: request,
                    sequence: 3
                ))
            }
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

private struct ServiceWorkspaceResourceProvider: RangeBackedTestWorkspaceProviding {
    func discoverResources(sessionID: String, refresh: Bool) async throws
        -> ResourceDiscoveryResult {
        .init(resources: [DiscoveredResource(
            group: "", version: "v1", resource: "services", kind: "Service",
            namespaced: true, verbs: ["list", "watch"]
        )])
    }

    func listNamespaces(sessionID: String) async throws -> [String] { [] }

    func streamView(request: ResourceViewRequest)
        -> AsyncThrowingStream<ResourceViewMessage, Error> {
        let identity = ResourceIdentity(
            clusterSessionID: request.sessionID,
            group: "", version: "v1", resource: "services",
            namespace: "default", name: "api", uid: "service-api"
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(testSnapshotInvalidation(
                request: request,
                sequence: 1,
                rows: [ResourceRow(identity: identity, cells: [Cell(
                    columnID: "name", displayText: "api", typedValue: .string("api")
                )])]
            ))
            if request.stageUntilReconciled {
                continuation.yield(testReconciliation(
                    request: request,
                    sequence: 2
                ))
            }
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
    func closeSession(sessionID: String) async {}
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants(of:))
}

@MainActor
private func apiResourceOutline(in window: NSWindow) -> NSOutlineView? {
    guard let root = window.contentView else { return nil }
    return descendants(of: root)
        .compactMap { $0 as? NSOutlineView }
        .first { $0.accessibilityLabel() == "Kubernetes resource kinds" }
}

@MainActor
private func apiDiscoveryStatus(in window: NSWindow) -> NSTextField? {
    guard let root = window.contentView else { return nil }
    return descendants(of: root)
        .compactMap { $0 as? NSTextField }
        .first { $0.identifier?.rawValue == "workspace-status-line" }
}

@MainActor
private func transferArrowColors(
    in label: NSTextField
) throws -> (download: NSColor, upload: NSColor) {
    let presentation = label.attributedStringValue
    let string = presentation.string as NSString
    let downloadIndex = string.range(of: "↓").location
    let uploadIndex = string.range(of: "↑").location
    try #require(downloadIndex != NSNotFound)
    try #require(uploadIndex != NSNotFound)
    return (
        try #require(presentation.attribute(
            .foregroundColor,
            at: downloadIndex,
            effectiveRange: nil
        ) as? NSColor),
        try #require(presentation.attribute(
            .foregroundColor,
            at: uploadIndex,
            effectiveRange: nil
        ) as? NSColor)
    )
}

private func workspaceLetterKey(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: modifiers.contains(.shift)
            ? characters.uppercased() : characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 1
    ))
}

@MainActor
private func selectResourceRow(
    _ row: Int,
    in table: NSTableView
) async throws {
    let root = try #require(table.window?.contentView)
    let status = try #require(descendants(of: root)
        .compactMap { $0 as? NSTextField }
        .first { $0.identifier?.rawValue == "workspace-status-line" })
    try await waitUntil {
        resourceRowIsMaterialized(row, in: table)
    }
    let delegate = table.delegate
    table.delegate = nil
    table.selectRowIndexes(
        IndexSet(integer: row),
        byExtendingSelection: false
    )
    table.delegate = delegate
    await Task.yield()
    delegate?.tableViewSelectionDidChange?(Notification(
        name: NSTableView.selectionDidChangeNotification,
        object: table
    ))
    try await waitUntil {
        table.selectedRowIndexes == IndexSet(integer: row)
            && status.stringValue.contains("1 selected")
    }
}

@MainActor
private func resourceRowIsMaterialized(
    _ row: Int,
    in table: NSTableView
) -> Bool {
    guard table.numberOfRows > row,
        let cell = table.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ) as? NSTableCellView,
        let text = cell.textField?.stringValue
    else { return false }
    return !text.isEmpty && text != "Loading…"
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

private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw ClusterManagerIssue(
                category: .internalFailure,
                reason: "AppKitAsyncTestTimeout",
                message: "Timed out waiting for an asynchronous test condition.",
                operation: "test cluster workspace navigation"
            )
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func toolbarPodIdentity() -> ResourceIdentity {
    ResourceIdentity(
        clusterSessionID: "test-session", group: "", version: "v1",
        resource: "pods", namespace: "default", name: "api", uid: "pod-api"
    )
}

private func toolbarPodDetail(_ pod: ResourceIdentity) -> ObjectDetail {
    ObjectDetail(
        identity: pod,
        resourceVersion: "rv-1",
        yamlUTF8: Data("apiVersion: v1\nkind: Pod\nmetadata:\n  name: api\n".utf8),
        summaryFields: [ObjectSummaryField(
            sectionID: "containers", fieldID: "container:api",
            label: "Container", displayText: "api"
        )],
        containers: [PodContainerDetail(name: "api", kind: .regular)]
    )
}

private actor DelayedDetailGate {
    private let blockedRequests: Set<Int>
    private var requests = 0
    private var identities: [ResourceIdentity] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blockedRequests: Set<Int>) {
        self.blockedRequests = blockedRequests
    }

    var requestCount: Int { requests }
    var requestedIdentities: [ResourceIdentity] { identities }

    func intercept(_ identity: ResourceIdentity) async {
        requests += 1
        identities.append(identity)
        guard blockedRequests.contains(requests) else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
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

private struct StaticConnectionActivityProvider: ClusterConnectionActivityProviding {
    let sample: ClusterConnectionActivitySample

    func watchConnectionActivity(sessionID: String, streamID: String)
        -> AsyncThrowingStream<ClusterConnectionActivitySample, Error> {
        AsyncThrowingStream {
            $0.yield(sample)
            $0.finish()
        }
    }
}

private struct NoopOperationHistoryProvider: ClusterOperationHistoryProviding {
    func watchOperations(sessionID: String, streamID: String)
        -> AsyncThrowingStream<ClusterOperationBatch, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StaticOperationHistoryProvider: ClusterOperationHistoryProviding {
    let completed: [ClusterOperationRecord]

    func watchOperations(sessionID: String, streamID: String)
        -> AsyncThrowingStream<ClusterOperationBatch, Error> {
        AsyncThrowingStream {
            $0.yield(ClusterOperationBatch(
                cursor: StreamCursor(generation: 1, sequence: 1),
                active: [],
                completed: completed
            ))
            $0.finish()
        }
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
    var detail: ObjectDetail?
    var gate: DelayedDetailGate?
    var rebindIdentityToRequest: Bool

    init(
        detail: ObjectDetail? = nil,
        gate: DelayedDetailGate? = nil,
        rebindIdentityToRequest: Bool = false
    ) {
        self.detail = detail
        self.gate = gate
        self.rebindIdentityToRequest = rebindIdentityToRequest
    }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        await gate?.intercept(identity)
        guard var detail else { throw CancellationError() }
        if rebindIdentityToRequest {
            guard detail.identity.uid == identity.uid,
                detail.identity.group == identity.group,
                detail.identity.version == identity.version,
                detail.identity.resource == identity.resource,
                detail.identity.namespace == identity.namespace,
                detail.identity.name == identity.name
            else { throw CancellationError() }
            detail.identity = identity
            return detail
        }
        guard detail.identity == identity else { throw CancellationError() }
        return detail
    }
    func watchObject(identity: ResourceIdentity, resourceVersion: String)
        -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
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

private actor TrackingDataObjectDetailProvider: ObjectDetailProviding {
    private var data: ObjectData
    private var dataCalls = 0
    private var objectCalls = 0
    private var identities: [ResourceIdentity] = []

    init(data: ObjectData) { self.data = data }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        objectCalls += 1
        return ObjectDetail(identity: identity, resourceVersion: data.resourceVersion)
    }

    nonisolated func watchObject(
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

    nonisolated func scanRelationships(
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
        dataCalls += 1
        identities.append(identity)
        guard identity.uid == data.identity.uid else { throw CancellationError() }
        var rebound = data
        rebound.identity.clusterSessionID = identity.clusterSessionID
        return rebound
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit { throw CancellationError() }

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

    func dataCallCount() -> Int { dataCalls }
    func objectCallCount() -> Int { objectCalls }
    func requestedIdentities() -> [ResourceIdentity] { identities }
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

private final class ResolvingToolbarLogProvider: LogStreamProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let containers: [String]
    private var storedResolvedResources: [ResourceIdentity] = []

    init(containers: [String] = ["sidecar", "app"]) {
        self.containers = containers
    }

    var resolvedResources: [ResourceIdentity] {
        lock.withLock { storedResolvedResources }
    }

    func resolveLogSources(resources: [ResourceIdentity]) async throws -> LogSourceResolution {
        lock.withLock { storedResolvedResources = resources }
        guard resources.count == 1, let pod = resources.first else {
            throw ClusterManagerIssue(
                category: .validation,
                reason: "UnexpectedTestSelection",
                message: "Expected one Pod in the test log resolution.",
                operation: "test direct logs"
            )
        }
        return LogSourceResolution(
            pods: [PodLogSourceInventory(identity: pod, containers: containers)],
            staticWorkloadSnapshot: false
        )
    }

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
