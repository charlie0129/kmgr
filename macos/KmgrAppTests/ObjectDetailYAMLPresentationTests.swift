import AppKit
import Foundation
import KmgrCore
import Testing
@testable import Kmgr

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

    @Test("YAML scroll view installs a visible line-number ruler and explicit managed-fields control")
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
        let ruler = try #require(scroll.verticalRulerView as? LineNumberRulerView)
        #expect(scroll.hasVerticalRuler)
        #expect(scroll.rulersVisible)
        #expect(ruler.clientView is NSTextView)
        #expect(ruler.ruleThickness > 0)

        let toggle = try #require(descendants(of: root).compactMap { $0 as? NSButton }
            .first { $0.title == "Show Managed Fields" })
        #expect(toggle.state == .off)
        #expect(!descendants(of: root).contains {
            $0.identifier?.rawValue == "secret-yaml-base64-notice"
        })
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

    @Test("Data key table exposes metadata columns without Secret previews")
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
        #expect(table.tableColumns.map(\.title) == ["Key", "Type", "Size", "State"])
        #expect(table.tableColumns.map { $0.identifier.rawValue } == ["key", "type", "size", "state"])
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
        #expect(renderedValues[1] == "text")
        #expect(renderedValues[2].hasSuffix("bytes"))
        #expect(renderedValues[3] == "Saved")
        #expect(!renderedValues.joined(separator: " ").contains(sentinel))

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

    func getObject(identity: ResourceIdentity) async throws -> ObjectDetail { detail }

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
