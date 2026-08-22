import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

extension AppKitTestHarness {
@MainActor
@Suite("Object detail YAML presentation")
struct ObjectDetailYAMLPresentationTests {
    @Test("Relationships table exposes its accessibility label")
    func relationshipTableAccessibilityLabel() throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "apps",
            version: "v1",
            resource: "deployments",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
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

    @Test("a duplicate object resource version does not rebuild Details")
    func duplicateResourceVersionIsIgnored() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let initialYAML = "apiVersion: v1\nkind: Pod\nmetadata:\n  name: api\n"
        let duplicateYAML = initialYAML + "status:\n  phase: Duplicate\n"
        let watch = AsyncThrowingStream<ObjectWatchEvent, Error>.makeStream()
        let probe = YAMLPresentationBuilderProbe()
        probe.releaseBlockedBuild()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
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
            ),
            initialTab: .yaml,
            yamlPresentationBuilder: { probe.build($0) }
        )
        controller.loadView()
        controller.viewDidAppear()
        defer {
            watch.continuation.finish()
            controller.stop()
        }
        let editor = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        try await waitUntil {
            probe.completedBuildCount == 1 && editor.string == initialYAML
        }

        watch.continuation.yield(.updated(
            cursor: StreamCursor(generation: 1, sequence: 1),
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(duplicateYAML.utf8)
            )
        ))
        watch.continuation.yield(.status(
            cursor: StreamCursor(generation: 1, sequence: 2),
            resourceVersion: "rv-1"
        ))
        try await waitUntil {
            controller.workspaceStatus.text == "Watching · resource version rv-1"
        }

        #expect(probe.buildCount == 1)
        #expect(editor.string == initialYAML)
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
            controller.workspaceStatus.text == "Watching · resource version rv-64"
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

    @Test("plain e starts editing from the read-only YAML view")
    func plainEStartsYAMLEditing() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "configmaps",
            namespace: "dev",
            name: "settings",
            uid: ResourceUID("uid")
        )
        let source = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: settings\n"
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
                detail: ObjectDetail(
                    identity: identity,
                    resourceVersion: "rv-1",
                    yamlUTF8: Data(source.utf8)
                ),
                data: ObjectData(
                    identity: identity,
                    resourceVersion: "rv-1",
                    entries: [],
                    secret: false
                )
            ),
            initialTab: .yaml
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let editor = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        let buttons = descendants(of: controller.view).compactMap { $0 as? NSButton }
        let edit = try #require(buttons.first { $0.title == "Edit" })
        let save = try #require(buttons.first { $0.title == "Save" })
        let cancel = try #require(buttons.first { $0.title == "Cancel" })
        try await waitUntil { editor.string == source }

        editor.keyDown(with: try yamlKeyEvent("e", modifiers: [.command]))
        #expect(!editor.isEditable)
        #expect(!edit.isHidden)

        editor.keyDown(with: try yamlKeyEvent("e"))
        #expect(editor.isEditable)
        #expect(edit.isHidden)
        #expect(!save.isHidden)
        #expect(!cancel.isHidden)
    }

    @Test("plain slash searches read-only YAML and types while editing")
    func plainSlashFindRespectsEditing() async throws {
        let identity = ResourceIdentity(
            clusterSessionID: "session", group: "", version: "v1",
            resource: "configmaps", namespace: "dev", name: "settings",
            uid: ResourceUID("uid-find")
        )
        let source = "apiVersion: v1\nkind: ConfigMap\n"
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
                detail: ObjectDetail(
                    identity: identity,
                    resourceVersion: "rv-find",
                    yamlUTF8: Data(source.utf8)
                ),
                data: ObjectData(
                    identity: identity,
                    resourceVersion: "rv-find",
                    entries: [],
                    secret: false
                )
            ),
            initialTab: .yaml
        )
        controller.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.viewDidAppear()
        defer {
            controller.stop()
            window.orderOut(nil)
        }

        let scroll = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-detail-yaml-scroll" })
        let editor = try #require(scroll.documentView as? YAMLTextView)
        let edit = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Edit" })
        try await waitUntil { editor.string == source && edit.isEnabled }

        editor.keyDown(with: try yamlKeyEvent("/"))
        #expect(scroll.isFindBarVisible)
        #expect(editor.string == source)

        scroll.isFindBarVisible = false
        edit.performClick(nil)
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        editor.keyDown(with: try yamlKeyEvent("/"))
        #expect(!scroll.isFindBarVisible)
        #expect(editor.string == source + "/")
    }

    @Test("YAML editing reports only WATCH resource-version changes")
    func yamlEditingWatchConflictRequiresDifferentResourceVersion() async throws {
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
        let watch = ControlledObjectWatch()
        let controller = ObjectDetailViewController(
            identity: identity,
            provider: LoadedObjectDetailProvider(
                detail: ObjectDetail(
                    identity: identity,
                    resourceVersion: "rv-1",
                    yamlUTF8: Data(source.utf8)
                ),
                data: ObjectData(
                    identity: identity,
                    resourceVersion: "rv-1",
                    entries: [],
                    secret: false
                ),
                objectWatch: watch.stream()
            ),
            initialTab: .yaml
        )
        controller.loadView()
        let editor = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Kubernetes object YAML" })
        let edit = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Edit" })
        controller.viewDidAppear()
        defer {
            Task { await watch.finish() }
            controller.stop()
        }
        try await waitUntil {
            editor.string == source
                && controller.workspaceStatus.text == "Resource version rv-1"
        }
        try await waitUntilAsync { await watch.numberOfRequests() == 1 }
        edit.performClick(nil)

        await watch.send(.updated(
            cursor: StreamCursor(generation: 1, sequence: 1),
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                yamlUTF8: Data(source.utf8)
            )
        ))
        try await waitUntilAsync { await watch.numberOfRequests() == 2 }
        #expect(controller.workspaceStatus.text == "Resource version rv-1")
        #expect(controller.workspaceStatus.severity == .informational)

        await watch.send(.updated(
            cursor: StreamCursor(generation: 1, sequence: 2),
            detail: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-2",
                yamlUTF8: Data(source.utf8)
            )
        ))
        try await waitUntilAsync { await watch.numberOfRequests() == 3 }
        #expect(controller.workspaceStatus.text
            == "Server object changed · local YAML edit preserved")
        #expect(controller.workspaceStatus.severity == .warning)
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

        let dataController = ObjectDataViewController(
            identity: identity,
            provider: provider
        )
        dataController.loadView()
        dataController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        dataController.viewDidAppear()
        defer { dataController.stop() }
        dataController.view.layoutSubtreeIfNeeded()
        let keysTable = try #require(descendants(of: dataController.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "ConfigMap or Secret data keys and values" })
        try await waitUntil { keysTable.numberOfRows == 1 }
        let dataScroll = try #require(descendants(of: dataController.view)
            .compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-data-value-scroll" })
        let dataEditor = try #require(dataScroll.documentView as? NSTextView)
        try await waitUntil { dataEditor.string == value }
        dataController.view.layoutSubtreeIfNeeded()
        let dataSplit = try #require(descendants(of: dataController.view)
            .compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "object-data-split" })
        #expect(dataSplit.arrangedSubviews[0].frame.width > 100)
        #expect(dataSplit.arrangedSubviews[1].frame.width > 100)
        #expect(keysTable.frame.width > 100)
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
            controller.workspaceStatus.text == "Resource version rv-1"
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

    @Test("Summary cells copy complete values without text selection")
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
        let transitionTime = Date(timeIntervalSince1970: 1_755_428_985)
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
                    displayText: "True · NewReplicaSetAvailable",
                    transitionTime: transitionTime
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.viewDidAppear()
        defer {
            controller.stop()
            window.orderOut(nil)
            window.contentViewController = nil
            NSPasteboard.general.clearContents()
        }

        let table = try #require(descendants(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Kubernetes object summary" })
        try await waitUntil { table.numberOfRows == 10 }
        #expect(table.tableColumns.map(\.title) == ["Field", "Value"])
        let capturedTable = try #require(table as? CapturedCellTableView)
        #expect(!capturedTable.canCopyCapturedCell)

        let sections = ObjectDetailSummaryPresentation.sections(for: detail)
        #expect(sections.map(\.title) == [
            "Labels", "Annotations", "Status", "Conditions",
        ])
        let localCondition = try #require(
            sections.first { $0.id == "conditions" }?.rows.first?.displayText
        )
        #expect(sections.flatMap(\.rows).map { "\($0.label)\t\($0.displayText)" } == [
            "app\tapi",
            "tier\tfrontend",
            "example.test/note\tfirst second",
            "example.test/payload\tJSON value omitted · \(longJSON.count.formatted()) characters",
            "Available\tTrue",
            "Progressing\t\(localCondition)",
        ])

        let conditionsHeading = try #require(table.view(
            atColumn: 0, row: 8, makeIfNecessary: true
        ) as? NSTextField)
        let conditionField = try #require(table.view(
            atColumn: 0, row: 9, makeIfNecessary: true
        ))
        let conditionValue = try #require(table.view(
            atColumn: 1, row: 9, makeIfNecessary: true
        ))
        #expect(conditionsHeading.stringValue == "Conditions")
        #expect(descendants(of: conditionField).contains {
            ($0 as? NSTextField)?.stringValue == "Progressing"
        })
        #expect(descendants(of: conditionValue).contains {
            ($0 as? NSTextField)?.stringValue == localCondition
        })

        let annotationField = try #require(table.view(
            atColumn: 0, row: 4, makeIfNecessary: true
        ))
        let annotationValue = try #require(table.view(
            atColumn: 1, row: 4, makeIfNecessary: true
        ))
        #expect(descendants(of: annotationField).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "example.test/note" && !$0.isSelectable })
        #expect(descendants(of: annotationValue).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "first second" && !$0.isSelectable })

        let payloadValue = try #require(table.view(
            atColumn: 1, row: 5, makeIfNecessary: true
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

        capturedTable.mouseDown(with: try summaryCellEvent(
            table: capturedTable,
            row: 5,
            column: 1,
            type: .leftMouseDown
        ))
        #expect(capturedTable.tryToPerform(#selector(NSText.copy(_:)), with: nil))
        #expect(NSPasteboard.general.string(forType: .string)
            == longJSON)

        let selectedBeforeContextMenu = capturedTable.selectedRowIndexes
        let contextMenu = try #require(capturedTable.menu(for: try summaryCellEvent(
            table: capturedTable,
            row: 4,
            column: 1,
            type: .rightMouseDown
        )))
        let copyCell = try #require(contextMenu.item(withTitle: "Copy Cell"))
        #expect(copyCell.isEnabled)
        #expect(capturedTable.selectedRowIndexes == selectedBeforeContextMenu)
        #expect(NSApp.sendAction(
            try #require(copyCell.action),
            to: copyCell.target,
            from: copyCell
        ))
        #expect(NSPasteboard.general.string(forType: .string) == "first second")
        #expect(capturedTable.selectedRowIndexes == selectedBeforeContextMenu)
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
        let transitionTime = Date(timeIntervalSince1970: 1_755_427_785.123)
        let now = transitionTime.addingTimeInterval(86_460)
        let sections = ObjectDetailSummaryPresentation.sections(
            for: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                summaryFields: [ObjectSummaryField(
                    sectionID: "conditions",
                    fieldID: "condition:0",
                    label: "Ready",
                    displayText: "True · message since startup",
                    transitionTime: transitionTime
                )]
            ),
            conditionTimeZone: timeZone,
            now: now
        )
        let condition = try #require(sections.first?.rows.first)

        #expect(condition.displayText
            == "True · message since startup · for 1d (since 2025-08-17 18:49:45 +08:00)")
        #expect(condition.copyLabel == "Ready")
        #expect(condition.copyValue == condition.displayText)
        #expect(ObjectDetailSummaryPresentation.compactAge(
            since: transitionTime,
            now: transitionTime.addingTimeInterval(60)
        ) == "1m")
    }

    @Test("Summary sections follow inspection priority with Conditions last")
    func summarySectionPriority() {
        let identity = ResourceIdentity(
            clusterSessionID: "session",
            group: "",
            version: "v1",
            resource: "pods",
            namespace: "dev",
            name: "api",
            uid: ResourceUID("uid")
        )
        let fields = [
            "conditions", "endpoints", "ports", "containers", "selectors", "owners",
            "future-section", "secret", "service", "network", "replicas", "status",
            "identity",
        ].map {
            ObjectSummaryField(
                sectionID: $0,
                fieldID: $0,
                label: $0,
                displayText: $0
            )
        }
        let sections = ObjectDetailSummaryPresentation.sections(for: ObjectDetail(
            identity: identity,
            resourceVersion: "rv",
            summaryFields: fields,
            labels: ["app": "api"],
            annotations: ["owner": "team"]
        ))

        #expect(sections.map(\.id) == [
            "identity", "labels", "annotations", "status", "replicas", "network",
            "service", "secret", "owners", "selectors", "containers", "ports",
            "endpoints", "future-section", "conditions",
        ])
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
        let controller = ObjectDataViewController(
            identity: identity,
            provider: provider
        )
        controller.loadView()
        controller.viewDidAppear()
        defer { controller.stop() }

        let root = controller.view
        let table = try #require(descendants(of: root).compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "ConfigMap or Secret data keys and values" })
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
            .first { $0.title == "Show decoded values" })
        #expect(reveal.state == .off)
        reveal.performClick(nil)
        #expect(reveal.state == .on)
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
        #expect(reveal.state == .off)
        valueCell = try #require(table.view(
            atColumn: valueColumnIndex,
            row: 0,
            makeIfNecessary: true
        ) as? NSTableCellView)
        let concealedValue = valueCell.textField?.stringValue ?? ""
        #expect(concealedValue.contains(sentinel) == false)
        #expect((valueCell.accessibilityValue() as? String)?.contains(sentinel) != true)

        let split = try #require(descendants(of: root).compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "object-data-split" })
        let keyScroll = try #require(descendants(of: root).compactMap { $0 as? NSScrollView }
            .first { $0.identifier?.rawValue == "object-data-keys-scroll" })
        let keyPane = try #require(descendants(of: root)
            .first { $0.identifier?.rawValue == "object-data-keys-pane" })
        #expect(split.isVertical)
        #expect(split.arrangedSubviews.count == 2)
        #expect(split.arrangedSubviews[0] === keyPane)
        #expect(keyScroll.isDescendant(of: keyPane))
        #expect(split.holdingPriorityForSubview(at: 0) == .defaultHigh)
        #expect(split.autosaveName == "kmgr.object-data-master-detail")
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

private actor ControlledObjectWatch {
    private var queued: [ObjectWatchEvent] = []
    private var waiter: CheckedContinuation<ObjectWatchEvent?, Never>?
    private var requestCount = 0
    private var finished = false

    nonisolated func stream() -> AsyncThrowingStream<ObjectWatchEvent, Error> {
        AsyncThrowingStream(unfolding: { await self.next() })
    }

    func send(_ event: ObjectWatchEvent) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else {
            queued.append(event)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: nil)
    }

    func numberOfRequests() -> Int { requestCount }

    private func next() async -> ObjectWatchEvent? {
        requestCount += 1
        if !queued.isEmpty { return queued.removeFirst() }
        guard !finished else { return nil }
        return await withCheckedContinuation { waiter = $0 }
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
private func yamlKeyEvent(
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
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 14
    ))
}

@MainActor
private func summaryCellEvent(
    table: NSTableView,
    row: Int,
    column: Int,
    type: NSEvent.EventType
) throws -> NSEvent {
    let point = table.convert(
        NSPoint(
            x: table.rect(ofColumn: column).midX,
            y: table.rect(ofRow: row).midY
        ),
        to: nil
    )
    return try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: table.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ))
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
