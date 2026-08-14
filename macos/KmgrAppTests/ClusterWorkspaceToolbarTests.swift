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
        let rate = try #require(labels.first { $0.stringValue.hasPrefix("↓") })
        let receive = try #require(descendants(of: view).first {
            $0.identifier?.rawValue == "connection-receive-indicator"
        })
        let send = try #require(descendants(of: view).first {
            $0.identifier?.rawValue == "connection-send-indicator"
        })
        let stateFrame = view.convert(state.bounds, from: state)
        let rateFrame = view.convert(rate.bounds, from: rate)
        let receiveFrame = view.convert(receive.bounds, from: receive)
        let sendFrame = view.convert(send.bounds, from: send)

        #expect(!stateFrame.intersects(rateFrame))
        #expect(rateFrame.minX - stateFrame.maxX >= 4)
        #expect(receiveFrame.maxX < sendFrame.minX)
        #expect(abs(receiveFrame.midY - stateFrame.midY) < 2)
        #expect(abs(sendFrame.midY - stateFrame.midY) < 2)
        #expect(view.intrinsicContentSize.height <= 20)
        let accessibilityValue = view.accessibilityValue() as? String
        #expect(accessibilityValue?.contains("Reconnecting…") == true)
        #expect(accessibilityValue?.contains("Retrying the Kubernetes API") == true)
        #expect(accessibilityValue?.contains("Download 12 MiB/s") == true)
        #expect(accessibilityValue?.contains("upload 3.0 MiB/s") == true)
        #expect(rate.accessibilityLabel() == "Kubernetes API transfer rate")
    }

    @Test("connection activity sits at the far right of the resource status bar")
    func connectionActivityUsesResourceFooter() throws {
        let controller = makeWorkspace()
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        root.layoutSubtreeIfNeeded()

        let statusBar = try #require(descendants(of: root).first {
            $0.identifier?.rawValue == "resource-status-bar"
        } as? NSStackView)
        let status = try #require(descendants(of: statusBar).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "resource-status-line" })
        let activity = try #require(descendants(of: statusBar).first {
            $0.accessibilityLabel() == "Kubernetes API connection activity"
        })
        statusBar.layoutSubtreeIfNeeded()
        let statusFrame = statusBar.convert(status.bounds, from: status)
        let activityFrame = statusBar.convert(activity.bounds, from: activity)

        #expect(statusFrame.maxX <= activityFrame.minX)
        #expect(abs(statusFrame.midY - activityFrame.midY) < 2)
        #expect(abs(activityFrame.maxX - statusBar.bounds.maxX) < 1)
        #expect(statusBar.fittingSize.height <= 20)
    }

    @Test("floating sidebar section rows supply a native vibrant background")
    func sidebarSectionRowsHaveBackground() async throws {
        let controller = makeWorkspace(provider: FilterValidationWorkspaceResourceProvider())
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try #require(controller.window?.contentView)
        let outline = try #require(descendants(of: root).compactMap { $0 as? NSOutlineView }
            .first { $0.accessibilityLabel() == "Kubernetes resource kinds" })

        try await waitUntil { outline.numberOfRows >= 2 }
        let sectionRow = try #require((0..<outline.numberOfRows).first { row in
            outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                is NSVisualEffectView
        })
        let section = try #require(outline.view(
            atColumn: 0,
            row: sectionRow,
            makeIfNecessary: true
        ) as? NSVisualEffectView)

        #expect(section.material == .sidebar)
        #expect(section.blendingMode == .withinWindow)
        #expect(section.state == .followsWindowActiveState)
        #expect(descendants(of: section).compactMap { ($0 as? NSTextField)?.stringValue }
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
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(window.makeFirstResponder(table))
        #expect(controller.contextualShortcutSnapshot?.contextID == "resource-list")
        #expect(controller.contextualShortcutSnapshot?.items.map(\.keys).contains("L") == true)

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
                )]
            ))
        )
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let root = try #require(window.contentView)
        let resourceTable = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes resources" })

        try await waitUntil { resourceTable.numberOfRows == 1 }
        resourceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
        #expect(containerTable.tableColumns.map(\.title) == ["Container", "Type"])
        #expect(controller.contextualShortcutSnapshot?.contextID == "pod-containers")
    }

    @Test("a slower Enter cannot replace a newer explicit YAML view")
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
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(window.makeFirstResponder(table))

        controller.enterResource(nil)
        try await waitUntilAsync { await gate.requestCount == 1 }
        controller.openResourceYAML(nil)
        try await waitUntilAsync { await gate.requestCount == 2 }
        await gate.releaseAll()

        try await waitUntil {
            descendants(of: root).compactMap { $0 as? NSTextView }
                .contains {
                    $0.accessibilityLabel() == "Kubernetes object YAML"
                        && $0.string.contains("kind: Pod")
                }
        }
        try await Task.sleep(for: .milliseconds(40))
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
        resourceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(window.makeFirstResponder(table))
        controller.enterResource(nil)
        try await waitUntil { namespaceControl.titleOfSelectedItem == "payments" }

        controller.navigateBack(nil)
        try await waitUntil {
            namespaceControl.titleOfSelectedItem == "All namespaces"
                && table.numberOfRows == 1
        }
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
        resourceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(window.makeFirstResponder(table))
        controller.openResourceLogs(nil)
        try await waitUntil { opened != nil }

        let resolved = logs.resolvedResources
        #expect(resolved.count == 1)
        let request = try #require(resolved.first)
        #expect(request.resource == "pods")
        #expect(request.uid == ResourceUID("pod-api"))
        #expect(opened?.sources.map(\.container) == ["app", "sidecar"])
        #expect(window.attachedSheet == nil)
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
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
                    .contains { $0.contains("Unknown filter term unknown") }
        }

        #expect(filter.stringValue == "unknown:value")
        #expect(table.numberOfRows == 1)
        #expect(freshness.stringValue == "Invalid filter · last good rows")
        #expect(freshness.accessibilityValue() == "Invalid filter · last good rows")
        let issueLabel = try #require(descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.contains("Unknown filter term unknown") })
        #expect(issueLabel.toolTip?.contains("Operation: compile resource filter") == true)
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
                    .contains { $0.contains("Unknown filter term unknown") }
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
        let connection = descendants(of: root).first {
            $0.accessibilityLabel() == "Kubernetes API connection activity"
        }
        let connectionValue = connection?.accessibilityValue() as? String
        #expect(connectionValue?.contains("Reconnecting…") == true)
        #expect(connectionValue?.contains("Opening saved Kubernetes context…") == true)
        #expect(connectionValue?.contains("Download 0 B/s, upload 0 B/s") == true)

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
            $0.accessibilityLabel() == "Kubernetes API connection activity"
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
    logProvider: any LogStreamProviding = NoopLogProvider(),
    objectDetailProvider: any ObjectDetailProviding = NoopToolbarObjectDetailProvider(),
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
        connectionActivityProvider: NoopConnectionActivityProvider(),
        optionalResourceCatalogProvider: NoopOptionalResourceCatalogProvider(),
        objectSearchProvider: NoopObjectSearchProvider(),
        objectDetailProvider: objectDetailProvider,
        operationProvider: NoopOperationProvider(),
        logProvider: logProvider,
        execProvider: NoopExecProvider(),
        portForwards: portForwards,
        columnsConfigurationPath: "/tmp/kmgr-toolbar-test-columns.yaml",
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
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
    columnsConfigurationPath: String,
    columnsConfigurationLoader: ColumnConfigurationDocumentLoader = .fileSystem,
    restorationState: ClusterWindowRestorationState? = nil
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
        objectDetailProvider: NoopToolbarObjectDetailProvider(),
        operationProvider: NoopOperationProvider(),
        logProvider: NoopLogProvider(),
        execProvider: NoopExecProvider(),
        portForwards: portForwards,
        columnsConfigurationPath: columnsConfigurationPath,
        columnsConfigurationLoader: columnsConfigurationLoader,
        logDisplayConfiguration: .default,
        confirmationPreferences: { ConfirmationPreferences() },
        restoration: restoration,
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

private struct NamespaceDrillDownWorkspaceResourceProvider: WorkspaceResourceProviding {
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
                status: ResourceViewStatus(freshness: .watching, rowsVisible: UInt64(rows.count))
            ))
            continuation.finish()
        }
    }

    func cancelView(sessionID: String, viewID: String, generation: UInt64) async {}
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

private struct ServiceWorkspaceResourceProvider: WorkspaceResourceProviding {
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
            continuation.yield(.snapshot(
                cursor: StreamCursor(generation: request.generation, sequence: 1),
                chunk: ResourceSnapshotChunk(
                    rows: [ResourceRow(identity: identity, cells: [Cell(
                        columnID: "name", displayText: "api", typedValue: .string("api")
                    )])],
                    first: true,
                    last: true,
                    index: 0,
                    estimatedTotalRows: 1
                )
            ))
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
        )]
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

private final class ResolvingToolbarLogProvider: LogStreamProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedResolvedResources: [ResourceIdentity] = []

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
            pods: [PodLogSourceInventory(identity: pod, containers: ["sidecar", "app"])],
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
