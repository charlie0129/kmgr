import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Object detail YAML presentation")
struct ObjectDetailYAMLPresentationTests {
    @Test("automatic details route ConfigMaps and Secrets directly to Data")
    func automaticDataTabRouting() {
        #expect(ObjectDetailInitialTab.automatic.segment(
            supportsDataEditor: true,
            supportsMetrics: false
        ) == 5)
        #expect(ObjectDetailInitialTab.automatic.segment(
            supportsDataEditor: false,
            supportsMetrics: false
        ) == 0)
        #expect(ObjectDetailInitialTab.data.segment(
            supportsDataEditor: false,
            supportsMetrics: false
        ) == 0)
    }

    @Test("Events and Relationships tables expose distinct accessibility labels")
    func eventAndRelationshipTableAccessibilityLabels() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let eventsController = ObjectDetailViewController(
            identity: identity,
            provider: NoopObjectDetailProvider(),
            initialTab: .events
        )
        eventsController.loadView()
        let eventsTable = try #require(descendants(of: eventsController.view)
            .compactMap { $0 as? NSTableView }
            .first)

        #expect(eventsTable.accessibilityRole() == .table)
        #expect(eventsTable.accessibilityLabel() == "Kubernetes object events")

        let relationshipsController = ObjectDetailViewController(
            identity: identity,
            provider: NoopObjectDetailProvider(),
            initialTab: .relationships
        )
        relationshipsController.loadView()
        let relationshipsTable = try #require(descendants(of: relationshipsController.view)
            .compactMap { $0 as? NSTableView }
            .first)

        #expect(relationshipsTable.accessibilityRole() == .table)
        #expect(relationshipsTable.accessibilityLabel()
            == "Kubernetes object relationships")
    }

    @Test("Relationships default to potentially incomplete with an explicit expensive scan")
    func relationshipCoverageAndScanAction() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
                detail: ObjectDetail(identity: identity, resourceVersion: "rv-1"),
                data: ObjectData(
                    identity: identity,
                    resourceVersion: "rv-1",
                    entries: [],
                    secret: false
                )
            ),
            initialTab: .relationships
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        try await waitUntil {
            descendants(of: controller.view).contains {
                ($0 as? NSTextField)?.stringValue
                    == "Cached children · potentially incomplete"
            }
        }
        let buttons = descendants(of: controller.view).compactMap { $0 as? NSButton }
        let scan = try #require(buttons.first { $0.title == "Scan All Resources…" })
        let cancel = try #require(buttons.first { $0.title == "Cancel Scan" })

        #expect(!scan.isHidden)
        #expect(scan.isEnabled)
        #expect(scan.target === controller)
        #expect(scan.action != nil)
        #expect(cancel.isHidden)
    }

    @Test("managed fields are hidden by default without changing complete YAML")
    func managedFieldsPresentation() throws {
        let source = #"""
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: settings
              namespace: dev
              managedFields:
                - manager: kube-controller-manager
                  operation: Update
              labels:
                app: kmgr
            data:
              managedFields: application-value
              mode: fast
            """#

        let presentation = YAMLManagedFieldsPresentation(yamlUTF8: Data(source.utf8))

        #expect(presentation.hasManagedFields)
        #expect(presentation.text(showingManagedFields: true) == source)
        let hidden = presentation.text(showingManagedFields: false)
        #expect(!hidden.contains("kube-controller-manager"))
        #expect(hidden.contains("managedFields: application-value"))
        #expect(hidden.contains("labels:"))
        #expect(hidden.contains("mode: fast"))
    }

    @Test("missing or malformed managed fields never cause heuristic source removal")
    func safeFallbacks() {
        let ordinary = "apiVersion: v1\nmetadata:\n  name: demo\n"
        let unchanged = YAMLManagedFieldsPresentation(yamlUTF8: Data(ordinary.utf8))
        #expect(!unchanged.hasManagedFields)
        #expect(unchanged.text(showingManagedFields: false) == ordinary)

        let malformed = "metadata:\n  managedFields: [\nimportant: keep-me\n"
        let fallback = YAMLManagedFieldsPresentation(yamlUTF8: Data(malformed.utf8))
        #expect(!fallback.hasManagedFields)
        #expect(fallback.text(showingManagedFields: false) == malformed)
    }

    @Test("a canceled queued preparation never enters the YAML builder")
    func canceledBeforeStartSkipsBuilder() async {
        let probe = YAMLPresentationBuilderProbe()
        probe.releaseBlockedBuild()
        let task = Task {
            try await ObjectDetailViewController.prepareYAMLPresentation(
                Data("metadata:\n  name: skipped\n".utf8),
                using: { probe.build($0) }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected queued YAML preparation to be canceled")
        } catch is CancellationError {
            // Expected: the synchronous builder was never entered.
        } catch {
            Issue.record("Unexpected preparation error: \(error)")
        }
        #expect(probe.buildCount == 0)
    }

    @Test("managed-fields preparation runs off main and rejects stale results")
    func managedFieldsPreparationConcurrency() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let initialYAML = #"""
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: api
              managedFields:
                - manager: stale-manager
            spec:
              revision: stale
            """#
        let latestYAML = #"""
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: api
              managedFields:
                - manager: latest-manager
            spec:
              revision: latest
            """#
        let watch = AsyncThrowingStream<ObjectWatchEvent, Error>.makeStream()
        let provider = LoadedObjectDetailProvider(
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(initialYAML.utf8)
            ),
            data: ObjectData(
                identity: identity,
                resourceVersion: "rv-1",
                entries: [],
                secret: false
            ),
            objectWatch: watch.stream
        )
        let probe = YAMLPresentationBuilderProbe()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .yaml,
            yamlPresentationBuilder: { probe.build($0) }
        )
        controller.loadView()
        controller.viewDidAppear()
        defer {
            probe.releaseBlockedBuild()
            watch.continuation.finish()
            controller.stop()
        }

        let editor = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        try await waitUntil { probe.buildCount == 1 }

        watch.continuation.yield(.updated(
            cursor: StreamCursor(generation: 1, sequence: 1),
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-2",
                yamlUTF8: Data(latestYAML.utf8)
            )
        ))
        try await Task.sleep(for: .milliseconds(30))
        #expect(editor.string.contains("revision: stale"))
        #expect(editor.string.contains("stale-manager"))
        #expect(probe.buildCount == 1)

        probe.releaseBlockedBuild()
        try await waitUntil { probe.buildCount == 2 }
        try await waitUntil {
            editor.string.contains("revision: latest")
                && !editor.string.contains("latest-manager")
        }

        #expect(probe.allBuildsRanOffMain)
        #expect(probe.maximumConcurrentBuilds == 1)

        // The first synchronous builder ignores cancellation until released.
        // Its late presentation must not replace the newer watch generation.
        try await waitUntil { probe.completedBuildCount == 2 }
        try await Task.sleep(for: .milliseconds(30))

        #expect(probe.firstBuildObservedCancellation == true)
        #expect(editor.string.contains("revision: latest"))
        #expect(!editor.string.contains("stale-manager"))
        #expect(!editor.string.contains("latest-manager"))
    }

    @Test("rapid YAML updates stay coherent and coalesce to the latest presentation")
    func rapidManagedFieldsUpdatesStayCoherentAndBounded() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        func source(revision: String) -> String {
            """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: api
              managedFields:
                - manager: manager-\(revision)
            spec:
              revision: \(revision)

            """
        }
        let initialYAML = source(revision: "initial")
        let finalYAML = source(revision: "burst-64")
        let watch = AsyncThrowingStream<ObjectWatchEvent, Error>.makeStream()
        let provider = LoadedObjectDetailProvider(
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-initial",
                yamlUTF8: Data(initialYAML.utf8)
            ),
            data: ObjectData(
                identity: identity,
                resourceVersion: "rv-initial",
                entries: [],
                secret: false
            ),
            objectWatch: watch.stream
        )
        let probe = YAMLPresentationBuilderProbe(blockedBuildOrdinal: 2)
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .yaml,
            yamlPresentationBuilder: { probe.build($0) }
        )
        controller.loadView()
        controller.viewDidAppear()
        defer {
            probe.releaseBlockedBuild()
            watch.continuation.finish()
            controller.stop()
        }

        let editor = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        let toggle = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Show Managed Fields" })
        let edit = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Edit" })
        let cancel = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Cancel" })
        try await waitUntil {
            probe.completedBuildCount == 1
                && editor.string.contains("revision: initial")
                && !editor.string.contains("manager-initial")
        }
        #expect(!toggle.isHidden)

        watch.continuation.yield(.updated(
            cursor: StreamCursor(generation: 9, sequence: 1),
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(source(revision: "burst-1").utf8)
            )
        ))
        try await waitUntil { probe.buildCount == 2 }
        for revision in 2...64 {
            watch.continuation.yield(.updated(
                cursor: StreamCursor(generation: 9, sequence: UInt64(revision)),
                detail: ObjectDetail(
                    identity: identity,
                    resourceVersion: "rv-\(revision)",
                    yamlUTF8: Data(source(revision: "burst-\(revision)").utf8)
                )
            ))
        }
        try await waitUntil {
            descendants(of: controller.view).contains {
                ($0 as? NSTextField)?.stringValue
                    == "Watching · resource version rv-64"
            }
        }

        // A busy watch must leave the last complete presentation and its
        // toolbar state untouched while the replacement is prepared.
        #expect(editor.string.contains("revision: initial"))
        #expect(!editor.string.contains("manager-initial"))
        #expect(!toggle.isHidden)
        #expect(probe.buildCount == 2)
        #expect(probe.maximumConcurrentBuilds == 1)

        // Read-only presentation stability must not make Edit stale.
        edit.performClick(nil)
        #expect(editor.string.contains("revision: burst-64"))
        #expect(editor.string.contains("manager-burst-64"))
        cancel.performClick(nil)
        #expect(editor.string.contains("revision: initial"))
        #expect(!editor.string.contains("manager-initial"))
        #expect(!toggle.isHidden)

        probe.releaseBlockedBuild()
        try await waitUntil { probe.completedBuildCount == 3 }
        try await waitUntil {
            editor.string.contains("revision: burst-64")
                && !editor.string.contains("manager-burst-64")
        }

        #expect(!toggle.isHidden)
        #expect(probe.buildCount == 3)
        #expect(probe.maximumConcurrentBuilds == 1)
        #expect(probe.builtYAML == [
            initialYAML, source(revision: "burst-1"), finalYAML,
        ])
    }

    @Test("WATCH and managed-fields refreshes preserve the YAML viewport and selection")
    func yamlRefreshPreservesViewport() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        func source(revision: String, manager: String) -> String {
            let values = (0..<180).map { index in
                "  key\(String(format: "%03d", index)): value-\(index)"
            }.joined(separator: "\n")
            return """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: api
              annotations:
                revision: \(revision)
              managedFields:
                - manager: \(manager)
                  operation: Update
            data:
            \(values)

            """
        }
        let initialYAML = source(revision: "first1", manager: "manager-one")
        let latestYAML = source(revision: "second", manager: "manager-two")
        let watch = AsyncThrowingStream<ObjectWatchEvent, Error>.makeStream()
        let provider = LoadedObjectDetailProvider(
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(initialYAML.utf8)
            ),
            data: ObjectData(
                identity: identity,
                resourceVersion: "rv-1",
                entries: [],
                secret: false
            ),
            objectWatch: watch.stream
        )
        let probe = YAMLPresentationBuilderProbe()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .yaml,
            yamlPresentationBuilder: { probe.build($0) }
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.viewDidAppear()
        defer {
            probe.releaseBlockedBuild()
            watch.continuation.finish()
            controller.stop()
        }

        let scroll = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-yaml-scroll" })
        let editor = try #require(scroll.documentView as? NSTextView)
        try await waitUntil {
            probe.buildCount == 1 && editor.string.contains("revision: first1")
        }
        probe.releaseBlockedBuild()
        try await waitUntil {
            probe.completedBuildCount == 1
                && !editor.string.contains("manager-one")
        }
        controller.view.layoutSubtreeIfNeeded()
        #expect(editor.frame.height > scroll.contentSize.height)

        let clipView = scroll.contentView
        clipView.scroll(to: NSPoint(x: 0, y: 620))
        scroll.reflectScrolledClipView(clipView)
        let stringRange = try #require(editor.string.range(of: "key080"))
        let selection = NSRange(stringRange, in: editor.string)
        editor.setSelectedRange(selection)
        let preservedOrigin = clipView.bounds.origin

        watch.continuation.yield(.updated(
            cursor: StreamCursor(generation: 7, sequence: 1),
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-2",
                yamlUTF8: Data(latestYAML.utf8)
            )
        ))
        try await waitUntil { editor.string.contains("revision: second") }
        #expect(abs(clipView.bounds.origin.y - preservedOrigin.y) <= 1)
        #expect(editor.selectedRange() == selection)

        try await waitUntil { probe.completedBuildCount == 2 }
        try await waitUntil {
            editor.string.contains("revision: second")
                && !editor.string.contains("manager-two")
        }
        #expect(abs(clipView.bounds.origin.y - preservedOrigin.y) <= 1)
        #expect(editor.selectedRange() == selection)
    }

    @Test("YAML tab uses AppKit's plain document without custom ruler geometry")
    func detailYAMLControls() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "configmaps",
            namespace: "dev",
            name: "settings",
            uid: ResourceUID("uid")
        )
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: NoopObjectDetailProvider(),
            initialTab: .yaml
        )
        controller.loadView()

        let root = controller.view
        let scroll = try #require(descendants(of: root).compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-yaml-scroll" })
        let textView = try #require(scroll.documentView as? NSTextView)
        #expect(scroll.hasVerticalRuler == false)
        #expect(scroll.rulersVisible == false)
        #expect(scroll.verticalRulerView == nil)
        #expect(textView.isRichText == false)
        #expect(textView.usesFindBar)

        let toggle = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Show Managed Fields" })
        #expect(toggle.state == .off)
        #expect(!descendants(of: root).contains {
            $0.identifier?.rawValue == "secret-yaml-base64-notice"
        })
    }

    @Test("detail scroll documents receive visible geometry instead of remaining zero-sized")
    func detailDocumentGeometry() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "configmaps",
            namespace: "dev",
            name: "settings",
            uid: ResourceUID("uid")
        )
        let yaml = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\n"
        let value = "visible-value"
        let provider = LoadedObjectDetailProvider(
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(yaml.utf8),
                summaryFields: [ObjectSummaryField(
                    sectionID: "metadata",
                    fieldID: "name",
                    label: "Name",
                    displayText: "settings"
                )]
            ),
            data: ObjectData(
                identity: identity,
                resourceVersion: "rv-1",
                entries: [ObjectDataEntry(
                    key: "config",
                    kind: .text,
                    value: Data(value.utf8),
                    byteSize: UInt64(value.utf8.count),
                    contentHash: Data(repeating: 3, count: 32)
                )],
                secret: false
            )
        )
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .yaml
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.viewDidAppear()
        defer { controller.stop() }

        let segmented = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSSegmentedControl }.first)
        let yamlScroll = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-yaml-scroll" })
        let yamlEditor = try #require(yamlScroll.documentView as? NSTextView)
        try await waitUntil { yamlEditor.string.contains("kind: ConfigMap") }
        controller.view.layoutSubtreeIfNeeded()
        #expect(yamlScroll.contentSize.width > 100)
        #expect(yamlEditor.frame.width > 100)
        #expect(yamlEditor.frame.height >= yamlScroll.contentSize.height)
        let yamlTextRect = try #require(laidOutTextRect(in: yamlEditor))
        #expect(yamlTextRect.width > 0)
        #expect(yamlTextRect.height > 0)
        #expect(yamlTextRect.intersects(yamlEditor.visibleRect))
        #expect(yamlEditor.frame.intersects(yamlScroll.contentView.bounds))

        segmented.selectedSegment = 0
        _ = segmented.sendAction(segmented.action, to: segmented.target)
        controller.view.layoutSubtreeIfNeeded()
        let summaryScroll = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-summary-scroll" })
        let summaryDocument = try #require(summaryScroll.documentView as? NSTableView)
        #expect(summaryScroll.contentSize.width > 100)
        #expect(summaryDocument.frame.width > 100)
        #expect(summaryDocument.frame.height > 0)
        #expect(summaryDocument.accessibilityLabel() == "Kubernetes object summary")
        #expect(summaryDocument.numberOfRows == 2)
        let summaryField = try #require(summaryDocument.view(
            atColumn: 0, row: 1, makeIfNecessary: true
        ))
        let summaryValue = try #require(summaryDocument.view(
            atColumn: 1, row: 1, makeIfNecessary: true
        ))
        #expect(descendants(of: summaryField).contains {
            ($0 as? NSTextField)?.stringValue == "Name"
        })
        #expect(descendants(of: summaryValue).contains {
            ($0 as? NSTextField)?.stringValue == "settings"
        })
        controller.view.setFrameSize(NSSize(width: 520, height: 600))
        controller.view.layoutSubtreeIfNeeded()
        #expect(summaryDocument.frame.width <= summaryScroll.contentSize.width + 1)

        segmented.selectedSegment = 5
        _ = segmented.sendAction(segmented.action, to: segmented.target)
        controller.view.layoutSubtreeIfNeeded()
        let keysTable = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "ConfigMap and Secret data keys" })
        try await waitUntil { keysTable.numberOfRows == 1 }
        keysTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let dataScroll = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-data-value-scroll" })
        let dataEditor = try #require(dataScroll.documentView as? NSTextView)
        try await waitUntil { dataEditor.string == value }
        controller.view.layoutSubtreeIfNeeded()
        #expect(dataScroll.contentSize.width > 100)
        #expect(dataEditor.frame.width > 100)
        #expect(dataEditor.frame.height > 0)
    }

    @Test("YAML loaded behind Summary becomes visible when attached in a split window")
    func detachedYAMLBecomesVisibleAfterTabSwitch() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let yaml = """
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: api
          namespace: dev
        spec:
          replicas: 3

        """
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
                detail: ObjectDetail(
                    identity: identity,
                    resourceVersion: "rv-1",
                    yamlUTF8: Data(yaml.utf8)
                ),
                data: ObjectData(
                    identity: identity,
                    resourceVersion: "rv-1",
                    entries: [],
                    secret: false
                )
            ),
            initialTab: .summary
        )
        let sidebar = NSViewController()
        sidebar.view = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 640))
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 160
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: controller))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.stop()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }

        let segmented = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSSegmentedControl }.first)
        try await waitUntil {
            descendants(of: controller.view).contains {
                ($0 as? NSTextField)?.stringValue == "Resource version rv-1"
            }
        }
        #expect(segmented.selectedSegment == 0)

        segmented.selectedSegment = 1
        _ = segmented.sendAction(segmented.action, to: segmented.target)
        let yamlScroll = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-yaml-scroll" })
        let yamlEditor = try #require(yamlScroll.documentView as? NSTextView)

        // The attach action itself owns this contract. Do not grant the test
        // an external window-layout pass that could accidentally repair the
        // old zero-sized detached document after `show` returns.
        #expect(yamlScroll.window === window)
        #expect(yamlEditor.string.contains("kind: Deployment"))
        #expect(yamlScroll.contentSize.width > 100)
        let attachedGlyphRect = try #require(firstVisibleGlyphRect(in: yamlEditor))
        #expect(attachedGlyphRect.intersects(yamlEditor.visibleRect))
        #expect(yamlScroll.contentView.bounds.intersects(
            yamlEditor.convert(attachedGlyphRect, to: yamlScroll.contentView)
        ))

        window.contentView?.layoutSubtreeIfNeeded()

        try await waitUntil {
            yamlScroll.window === window
                && firstVisibleGlyphRect(in: yamlEditor) != nil
        }
        let glyphRect = try #require(firstVisibleGlyphRect(in: yamlEditor))
        #expect(!yamlEditor.string.isEmpty)
        #expect(glyphRect.width > 0)
        #expect(glyphRect.height > 0)
        #expect(glyphRect.intersects(yamlEditor.visibleRect))
        #expect(yamlScroll.contentView.bounds.intersects(
            yamlEditor.convert(glyphRect, to: yamlScroll.contentView)
        ))
    }

    @Test("Secret YAML clearly labels Kubernetes base64 encoding")
    func secretYAMLEncodingNotice() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "secrets",
            namespace: "dev",
            name: "credentials",
            uid: ResourceUID("uid")
        )
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: NoopObjectDetailProvider(),
            initialTab: .yaml
        )
        controller.loadView()

        let notice = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "secret-yaml-base64-notice" })
        #expect(notice.stringValue.localizedCaseInsensitiveContains("base64"))
        #expect(notice.stringValue.contains("Data"))
    }

    @Test("Summary uses copyable sectioned rows for conditions and metadata")
    func summaryMetadataRendering() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let longJSON = "{\"payload\":\"\(String(repeating: "x", count: 2_000))\"}"
        let serverCondition = "True · NewReplicaSetAvailable · since 2026-08-17T10:49:45Z"
        let localCondition = ObjectDetailSummaryPresentation.localizedConditionText(
            serverCondition,
            timeZone: .current
        )
        let detail = ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            summaryFields: [
                ObjectSummaryField(
                    sectionID: "status",
                    fieldID: "available",
                    label: "Available",
                    displayText: "True"
                ),
                ObjectSummaryField(
                    sectionID: "conditions",
                    fieldID: "condition:0",
                    label: "Progressing",
                    displayText: serverCondition
                ),
            ],
            labels: ["tier": "frontend", "app": "api"],
            annotations: [
                "example.test/note": "first\n  second",
                "example.test/payload": longJSON,
            ]
        )
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
                detail: detail,
                data: ObjectData(
                    identity: identity,
                    resourceVersion: "rv-1",
                    entries: [],
                    secret: false
                )
            ),
            initialTab: .summary
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let table = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes object summary" })
        try await waitUntil { table.numberOfRows == 10 }
        #expect(table.tableColumns.map(\.title) == ["Field", "Value"])
        #expect(table is CopyableSummaryTableView)

        let sections = ObjectDetailSummaryPresentation.sections(for: detail)
        #expect(sections.map(\.title) == [
            "Status", "Conditions", "Labels", "Annotations",
        ])
        #expect(sections.flatMap(\.rows).map { "\($0.label)\t\($0.displayText)" } == [
            "Available\tTrue",
            "Progressing\t\(localCondition)",
            "app\tapi",
            "tier\tfrontend",
            "example.test/note\tfirst second",
            "example.test/payload\tJSON value omitted · \(longJSON.count.formatted()) characters",
        ])

        let conditionsHeading = try #require(table.view(
            atColumn: 0, row: 2, makeIfNecessary: true
        ) as? NSTextField)
        let conditionField = try #require(table.view(
            atColumn: 0, row: 3, makeIfNecessary: true
        ))
        let conditionValue = try #require(table.view(
            atColumn: 1, row: 3, makeIfNecessary: true
        ))
        #expect(conditionsHeading.stringValue == "Conditions")
        #expect(descendants(of: conditionField).contains {
            ($0 as? NSTextField)?.stringValue == "Progressing"
        })
        #expect(descendants(of: conditionValue).contains {
            ($0 as? NSTextField)?.stringValue == localCondition
        })

        let annotationField = try #require(table.view(
            atColumn: 0, row: 8, makeIfNecessary: true
        ))
        let annotationValue = try #require(table.view(
            atColumn: 1, row: 8, makeIfNecessary: true
        ))
        #expect(descendants(of: annotationField).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "example.test/note" && $0.isSelectable })
        #expect(descendants(of: annotationValue).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "first second" && $0.isSelectable })

        let payloadValue = try #require(table.view(
            atColumn: 1, row: 9, makeIfNecessary: true
        ))
        #expect(descendants(of: payloadValue).compactMap { $0 as? NSTextField }
            .contains {
                $0.stringValue == "JSON value omitted · \(longJSON.count.formatted()) characters"
                    && $0.maximumNumberOfLines == 1
            })
        controller.view.setFrameSize(NSSize(width: 520, height: 500))
        controller.view.layoutSubtreeIfNeeded()
        let summaryScroll = try #require(table.enclosingScrollView)
        #expect(table.frame.width <= summaryScroll.contentSize.width + 1)

        let copyableTable = try #require(table as? CopyableSummaryTableView)
        copyableTable.selectRowIndexes(IndexSet(integer: 9), byExtendingSelection: false)
        #expect(copyableTable.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        #expect(NSPasteboard.general.string(forType: .string)
            == "Annotations\texample.test/payload\t\(longJSON)")
        NSPasteboard.general.clearContents()
    }

    @Test("Summary condition timestamps use local time")
    func summaryConditionLocalTime() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let serverValue = "True · message since startup · since 2026-08-17T10:49:45.123Z"
        let sections = ObjectDetailSummaryPresentation.sections(
            for: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "conditions",
                    fieldID: "condition:0",
                    label: "Ready",
                    displayText: serverValue
                )]
            ),
            conditionTimeZone: timeZone
        )
        let condition = try #require(sections.first?.rows.first)

        #expect(condition.displayText
            == "True · message since startup · since 2026-08-17 18:49:45 +08:00")
        #expect(condition.copyValue == condition.displayText)
        #expect(ObjectDetailSummaryPresentation.copyText(for: [condition])
            == "Conditions\tReady\tTrue · message since startup · since 2026-08-17 18:49:45 +08:00")
        #expect(ObjectDetailSummaryPresentation.localizedConditionText(
            "True · since not-a-timestamp",
            timeZone: timeZone
        ) == "True · since not-a-timestamp")
    }

    @Test("Summary omits long JSON and bounds metadata entry counts")
    func boundedSummaryMetadata() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let labels = Dictionary(uniqueKeysWithValues:
            (0..<(ObjectDetailSummaryPresentation.maximumMetadataEntriesPerSection + 10))
                .map { (String(format: "key-%03d", $0), "value-\($0)") }
        )
        let longJSON = "{\"payload\":\"\(String(repeating: "x", count: 2_000))\"}"
        let sections = ObjectDetailSummaryPresentation.sections(for: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            labels: labels,
            annotations: ["long": longJSON]
        ))
        let labelFields = try #require(sections.first { $0.id == "labels" }).rows
        let annotation = try #require(sections.first { $0.id == "annotations" }?.rows.first)

        #expect(labelFields.count
            == ObjectDetailSummaryPresentation.maximumMetadataEntriesPerSection + 1)
        #expect(labelFields.last?.displayText == "10 not shown")
        #expect(annotation.displayText
            == "JSON value omitted · \(longJSON.count.formatted()) characters")
        #expect(!annotation.displayText.contains(String(repeating: "x", count: 100)))
        #expect(annotation.tooltip.contains("Command-C"))
        #expect(annotation.copyValue == longJSON)
        #expect(ObjectDetailSummaryPresentation.copyText(for: [annotation])
            == "Annotations\tlong\t\(longJSON)")
    }

    @Test("Summary metadata removes control characters")
    func summaryMetadataControlCharacters() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let sections = ObjectDetailSummaryPresentation.sections(for: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            labels: ["unsafe\u{0000}key": "first\u{0007}\nsecond"],
            annotations: [:]
        ))
        let label = try #require(sections.first { $0.id == "labels" }?.rows.first)

        #expect(label.label == "unsafe key")
        #expect(label.displayText == "first second")
        #expect(!label.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        #expect(!label.displayText.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }

    @Test("line-number geometry grows at digit boundaries")
    func lineNumberGeometry() {
        #expect(LineNumberRulerView.lineCount(in: "") == 1)
        #expect(LineNumberRulerView.lineCount(in: "one\ntwo") == 2)
        #expect(LineNumberRulerView.lineCount(in: "one\n") == 2)
        #expect(LineNumberRulerView.requiredWidth(forLineCount: 100)
            > LineNumberRulerView.requiredWidth(forLineCount: 99))

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        let ruler = LineNumberRulerView(textView: textView, scrollView: scroll)
        let originalWidth = ruler.ruleThickness
        textView.string = (1...100).map(String.init).joined(separator: "\n")
        ruler.textDidChange()
        #expect(ruler.ruleThickness > originalWidth)
    }

    @Test("line-number ruler lays out and draws empty trailing and scrolled documents")
    func lineNumberDrawSmoke() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_200))
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let ruler = LineNumberRulerView(textView: textView, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()

        for source in ["", "one\n", "one\n\n", (1...200).map(String.init).joined(separator: "\n") + "\n"] {
            textView.string = source
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            ruler.textDidChange()
            let image = NSImage(size: ruler.bounds.size)
            image.lockFocus()
            ruler.drawHashMarksAndLabels(in: ruler.bounds)
            image.unlockFocus()
        }

        let beforeScroll = try #require(ruler.rulerY(forTextViewY: 300))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 240))
        scroll.reflectScrolledClipView(scroll.contentView)
        let afterScroll = try #require(ruler.rulerY(forTextViewY: 300))
        #expect(afterScroll < beforeScroll)

        let image = NSImage(size: ruler.bounds.size)
        image.lockFocus()
        ruler.drawHashMarksAndLabels(in: ruler.bounds)
        image.unlockFocus()
    }

    @Test("Data key table conceals then reveals decoded Secret previews")
    func secretDataKeyTableColumnsAndConcealment() async throws {
        let sentinel = "do-not-render-this-secret-value"
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "secrets",
            namespace: "dev",
            name: "credentials",
            uid: ResourceUID("uid")
        )
        let provider = LoadedObjectDetailProvider(
            detail: ObjectDetail(identity: identity, resourceVersion: "rv-1"),
            data: ObjectData(
                identity: identity,
                resourceVersion: "rv-1",
                entries: [ObjectDataEntry(
                    key: "token",
                    kind: .text,
                    value: Data(sentinel.utf8),
                    byteSize: UInt64(sentinel.utf8.count),
                    contentHash: Data(repeating: 7, count: 32)
                )],
                secret: true
            )
        )
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .data
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let root = controller.view
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "ConfigMap and Secret data keys" })
        try await waitUntil { table.numberOfRows == 1 }

        #expect(table.headerView != nil)
        #expect(table.tableColumns.map(\.title) == ["Key", "Value", "Type", "Size", "State"])
        #expect(table.tableColumns.map { $0.identifier.rawValue }
            == ["key", "value", "type", "size", "state"])
        #expect(table.allowsMultipleSelection == false)

        var renderedValues: [String] = []
        for columnIndex in table.tableColumns.indices {
            let cell = try #require(table.view(
                atColumn: columnIndex,
                row: 0,
                makeIfNecessary: true
            ) as? NSTableCellView)
            renderedValues.append(cell.textField?.stringValue ?? "")
            #expect((cell.accessibilityValue() as? String)?.contains(sentinel) != true)
        }
        #expect(renderedValues[0] == "token")
        #expect(renderedValues[1] == "Secret concealed · \(sentinel.utf8.count) bytes")
        #expect(renderedValues[2] == "text")
        #expect(renderedValues[3].hasSuffix("bytes"))
        #expect(renderedValues[4] == "Saved")
        #expect(!renderedValues.joined(separator: " ").contains(sentinel))

        let valueColumnIndex = try #require(table.tableColumns.firstIndex {
            $0.identifier.rawValue == "value"
        })
        let valueColumn = table.tableColumns[valueColumnIndex]
        #expect(valueColumn.resizingMask.contains(.userResizingMask))
        let resizedWidth = valueColumn.width + 37
        valueColumn.width = resizedWidth
        #expect(valueColumn.width == resizedWidth)

        var valueCell = try #require(table.view(
            atColumn: valueColumnIndex,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        #expect(valueCell.accessibilityLabel() == "Value")
        #expect(valueCell.accessibilityValue() as? String
            == "Secret value concealed, \(sentinel.utf8.count) bytes")

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: table
        ))
        let reveal = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Reveal" })
        reveal.performClick(nil)
        valueCell = try #require(table.view(
            atColumn: valueColumnIndex,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        #expect(valueCell.textField?.stringValue == sentinel)
        #expect(valueCell.accessibilityValue() as? String == "Text value: \(sentinel)")
        let revealedValue = valueCell.textField?.stringValue ?? ""
        #expect(revealedValue.contains(Data(sentinel.utf8).base64EncodedString()) == false)

        reveal.performClick(nil)
        valueCell = try #require(table.view(
            atColumn: valueColumnIndex,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        let concealedValue = valueCell.textField?.stringValue ?? ""
        #expect(concealedValue.contains(sentinel) == false)
        #expect((valueCell.accessibilityValue() as? String)?.contains(sentinel) != true)

        let split = try #require(descendants(of: root).compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "object-detail-data-split" })
        let keyScroll = try #require(descendants(of: root).compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-data-keys-scroll" })
        #expect(split.isVertical)
        #expect(split.arrangedSubviews.count == 2)
        #expect(split.arrangedSubviews[0] === keyScroll)
        #expect(split.holdingPriorityForSubview(at: 0) == .defaultHigh)
        #expect(keyScroll.hasHorizontalScroller)
    }

    @Test("YAML saves serialize and restore editing controls after failure and success")
    func yamlSaveLifecycle() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let source = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api\n"
        let provider = YAMLSaveObjectDetailProvider(detail: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            yamlUTF8: Data(source.utf8)
        ))
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: provider,
            initialTab: .yaml
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let buttons = descendants(of: controller.view).compactMap { $0 as? NSButton }
        let edit = try #require(buttons.first { $0.title == "Edit" })
        let save = try #require(buttons.first { $0.title == "Save" })
        let cancel = try #require(buttons.first { $0.title == "Cancel" })
        let editor = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        try await waitUntil { editor.string == source }

        edit.performClick(nil)
        editor.string += "spec:\n  replicas: 2\n"
        controller.saveDocument(nil)
        try await waitUntilAsync { await provider.numberOfApplyCalls() == 1 }

        #expect(!save.isEnabled)
        #expect(!cancel.isEnabled)
        #expect(!editor.isEditable)

        controller.saveDocument(nil)
        controller.saveDocument(nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await provider.numberOfPrepareCalls() == 1)
        #expect(await provider.numberOfApplyCalls() == 1)
        #expect(await provider.maximumConcurrentApplies() == 1)

        await provider.failCurrentApply()
        try await waitUntil { save.isEnabled && cancel.isEnabled && editor.isEditable }

        controller.saveDocument(nil)
        try await waitUntilAsync { await provider.numberOfApplyCalls() == 2 }
        #expect(await provider.maximumConcurrentApplies() == 1)
        await provider.succeedCurrentApply()
        try await waitUntil { !edit.isHidden && edit.isEnabled }

        #expect(save.isHidden)
        #expect(cancel.isHidden)
        #expect(!editor.isEditable)
    }
}
}

private actor YAMLSaveObjectDetailProvider: ObjectDetailProviding {
    private let detail: ObjectDetail
    private var prepareCalls = 0
    private var applyCalls = 0
    private var concurrentApplies = 0
    private var maximumApplies = 0
    private var pendingApply: AsyncThrowingStream<OperationProgress, Error>.Continuation?

    init(detail: ObjectDetail) {
        self.detail = detail
    }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }

    nonisolated func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent]
    {
        []
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
        throw CancellationError()
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        prepareCalls += 1
        return PreparedYAMLEdit(
            normalizedYAMLUTF8: yamlUTF8,
            currentResourceVersion: expectedResourceVersion,
            diff: []
        )
    }

    func applyYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        let pair = AsyncThrowingStream<OperationProgress, Error>.makeStream()
        pendingApply = pair.continuation
        applyCalls += 1
        concurrentApplies += 1
        maximumApplies = max(maximumApplies, concurrentApplies)
        return pair.stream
    }

    func updateData(
        identity: ResourceIdentity,
        expectedResourceVersion: String,
        mutations: [DataMutationKind]
    ) async throws -> AsyncThrowingStream<OperationProgress, Error> {
        throw CancellationError()
    }

    func numberOfPrepareCalls() -> Int { prepareCalls }

    func numberOfApplyCalls() -> Int { applyCalls }

    func maximumConcurrentApplies() -> Int { maximumApplies }

    func failCurrentApply() {
        pendingApply?.yield(OperationProgress(
            cursor: StreamCursor(generation: UInt64(applyCalls), sequence: 1),
            operationID: "yaml-save-\(applyCalls)",
            state: .failed,
            completedItems: 0,
            totalItems: 1,
            itemResults: [],
            issue: ClusterManagerIssue(
                category: .conflict,
                reason: "Conflict",
                message: "The object changed on the server.",
                operation: "apply YAML"
            )
        ))
        finishCurrentApply()
    }

    func succeedCurrentApply() {
        pendingApply?.yield(OperationProgress(
            cursor: StreamCursor(generation: UInt64(applyCalls), sequence: 1),
            operationID: "yaml-save-\(applyCalls)",
            state: .succeeded,
            completedItems: 1,
            totalItems: 1,
            itemResults: []
        ))
        finishCurrentApply()
    }

    private func finishCurrentApply() {
        pendingApply?.finish()
        pendingApply = nil
        concurrentApplies -= 1
    }
}

private final class YAMLPresentationBuilderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let blockedBuildGate = DispatchSemaphore(value: 0)
    private let blockedBuildOrdinal: Int
    private var storedBuildCount = 0
    private var storedCompletedBuildCount = 0
    private var storedActiveBuildCount = 0
    private var storedMaximumConcurrentBuilds = 0
    private var storedRanOnMainThread: [Bool] = []
    private var storedBuiltYAML: [String] = []
    private var storedFirstBuildObservedCancellation: Bool?

    var buildCount: Int { lock.withLock { storedBuildCount } }
    var completedBuildCount: Int { lock.withLock { storedCompletedBuildCount } }
    var maximumConcurrentBuilds: Int {
        lock.withLock { storedMaximumConcurrentBuilds }
    }
    var builtYAML: [String] { lock.withLock { storedBuiltYAML } }
    var allBuildsRanOffMain: Bool {
        lock.withLock {
            !storedRanOnMainThread.isEmpty
                && storedRanOnMainThread.allSatisfy { !$0 }
        }
    }
    var firstBuildObservedCancellation: Bool? {
        lock.withLock { storedFirstBuildObservedCancellation }
    }

    init(blockedBuildOrdinal: Int = 1) {
        self.blockedBuildOrdinal = blockedBuildOrdinal
    }

    func build(_ yamlUTF8: Data) -> YAMLManagedFieldsPresentation {
        let ordinal = lock.withLock {
            storedBuildCount += 1
            storedActiveBuildCount += 1
            storedMaximumConcurrentBuilds = max(
                storedMaximumConcurrentBuilds,
                storedActiveBuildCount
            )
            storedRanOnMainThread.append(Thread.isMainThread)
            storedBuiltYAML.append(String(decoding: yamlUTF8, as: UTF8.self))
            return storedBuildCount
        }
        defer {
            lock.withLock {
                storedActiveBuildCount -= 1
                storedCompletedBuildCount += 1
            }
        }
        if ordinal == blockedBuildOrdinal {
            blockedBuildGate.wait()
            if ordinal == 1 {
                lock.withLock {
                    storedFirstBuildObservedCancellation = Task.isCancelled
                }
            }
        }
        return YAMLManagedFieldsPresentation(yamlUTF8: yamlUTF8)
    }

    func releaseBlockedBuild() { blockedBuildGate.signal() }
}

private struct NoopObjectDetailProvider: ObjectDetailProviding {
    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail {
        throw CancellationError()
    }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent]
    {
        []
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    func scanRelationships(
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
        throw CancellationError()
    }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

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
}

private struct LoadedObjectDetailProvider: ObjectDetailProviding {
    var detail: ObjectDetail
    var data: ObjectData
    var objectWatch = AsyncThrowingStream<ObjectWatchEvent, Error> { $0.finish() }

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }

    func watchObject(
        identity: ResourceIdentity,
        resourceVersion: String
    ) -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        objectWatch
    }

    func getEvents(identity: ResourceIdentity, limit: UInt32) async throws
        -> [KubernetesObjectEvent]
    {
        []
    }

    func getRelationships(
        identity: ResourceIdentity,
        includeChildren: Bool
    ) async throws -> ObjectRelationships {
        ObjectRelationships(values: [], childrenPotentiallyIncomplete: true)
    }

    func scanRelationships(
        identity: ResourceIdentity
    ) -> AsyncThrowingStream<RelationshipScanMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func cancelRelationshipScan(
        sessionID: String,
        scanID: String,
        generation: UInt64
    ) async {}

    func getData(identity: ResourceIdentity) async throws -> ObjectData { data }

    func prepareYAML(
        identity: ResourceIdentity,
        yamlUTF8: Data,
        expectedResourceVersion: String,
        forceFieldOwnership: Bool
    ) async throws -> PreparedYAMLEdit {
        throw CancellationError()
    }

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
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants(of:))
}

@MainActor
private func laidOutTextRect(in textView: NSTextView) -> NSRect? {
    guard let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer
    else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).offsetBy(
        dx: textView.textContainerOrigin.x,
        dy: textView.textContainerOrigin.y
    )
}

@MainActor
private func firstVisibleGlyphRect(in textView: NSTextView) -> NSRect? {
    guard let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer,
        (textView.textStorage?.length ?? 0) > 0
    else { return nil }
    let characterRange = NSRange(
        location: 0,
        length: min(64, textView.textStorage?.length ?? 0)
    )
    layoutManager.ensureLayout(forCharacterRange: characterRange)
    var actualCharacterRange = NSRange()
    let glyphRange = layoutManager.glyphRange(
        forCharacterRange: characterRange,
        actualCharacterRange: &actualCharacterRange
    )
    guard glyphRange.length > 0 else { return nil }
    return layoutManager.boundingRect(
        forGlyphRange: glyphRange,
        in: textContainer
    ).offsetBy(
        dx: textView.textContainerOrigin.x,
        dy: textView.textContainerOrigin.y
    )
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
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
